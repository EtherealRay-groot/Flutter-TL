import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../ble/ble_transport.dart';
import '../ble/device_connection.dart';
import '../ble/universal_ble_transport.dart';
import '../core/protocol/ibeacon_codec.dart';
import '../core/protocol/logistics_info.dart';
import '../core/protocol/record_entry.dart';
import '../core/protocol/sensor_data.dart';
import '../export/csv_exporter.dart';
import '../export/export_service.dart';
import '../export/pdf_fonts.dart';
import '../export/pdf_report_builder.dart';
import 'app_state.dart';

final bleTransportProvider = Provider<BleTransport>((ref) {
  final transport = UniversalBleTransport();
  ref.onDispose(transport.dispose);
  return transport;
});

final appControllerProvider =
    NotifierProvider<AppController, AppState>(AppController.new);

/// 原 Kotlin `BluetoothLeViewModel` 的 Dart 版。
///
/// 与旧实现的差异：连接池按不透明 deviceId 索引；所有回调闭包捕获自己的
/// deviceId；`Handler.postDelayed` 换成 `Timer`。
class AppController extends Notifier<AppState> {
  static const int scanPeriodMs = 30000;
  static const int chunkSize = 30;
  static const int paramAckTimeoutMs = 2500;
  static const int paramOpGapMs = 120;
  static const int connectTimeoutMs = 15000;

  static const Map<String, String> paramTitles = {
    'C2': '设备名称',
    'A1': 'iBeacon UUID',
    'A2': 'Major',
    'A3': 'Minor',
    'A5': 'Company ID',
    'A6': '广播间隔',
    'A7': '发射功率',
    'A8': 'RSSI@1m',
  };

  final Map<String, DeviceConnection> _connections = {};
  StreamSubscription<BleScanResult>? _scanSub;
  Timer? _scanTimer;
  final Map<String, Timer> _connectTimers = {};

  // 多步流程标志位（与原实现同名）
  bool _pendingClearAfterPwd = false;
  bool _pendingStartAfterLogistics = false;
  bool _pendingCheckFlashBeforeStart = false;
  bool _pendingTimeRangePick = false;

  // 参数串行写队列
  final List<_ParamOp> _paramOps = [];
  Timer? _paramAckTimer;
  String? _paramOpAddress;
  final List<BeaconFieldResult> _paramResults = [];

  // 分块读取（保留原实现字段）
  final List<RecordEntry> _chunkAccumulator = [];
  int _chunkNextIndex = 0;
  int _chunkExpectedTotal = 0;
  String? _chunkAddress;

  BleTransport get _transport => ref.read(bleTransportProvider);

  @override
  AppState build() {
    ref.onDispose(() {
      _scanTimer?.cancel();
      for (final t in _connectTimers.values) {
        t.cancel();
      }
      _connectTimers.clear();
      _paramAckTimer?.cancel();
      _scanSub?.cancel();
      for (final c in _connections.values) {
        c.close();
      }
    });
    return const AppState();
  }

  // ======== 状态辅助 ========
  DeviceState? _device(String id) => state.devices[id];

  void _updateDevice(String id, DeviceState Function(DeviceState) update) {
    final current = state.devices[id];
    if (current == null) return;
    final devices = Map<String, DeviceState>.from(state.devices);
    devices[id] = update(current);
    state = state.copyWith(devices: devices);
  }

  void _sortDevices() {
    final ids = state.devices.keys.toList()
      ..sort((a, b) {
        final ra = state.devices[a]!.rssi;
        final rb = state.devices[b]!.rssi;
        return rb.compareTo(ra);
      });
    state = state.copyWith(deviceOrder: ids);
  }

  void _showError(String message) {
    state = state.copyWith(errorMessage: message);
  }

  // ======== 初始化 / 权限 ========
  Future<void> initialize() async {
    try {
      final enabled = await _transport.isBluetoothAvailable();
      var granted = await _transport.hasPermissions();
      if (!granted) {
        try {
          await _transport.requestPermissions();
          granted = await _transport.hasPermissions();
        } catch (e) {
          _showError('权限申请失败: $e');
        }
      }
      state = state.copyWith(
        bluetoothEnabled: enabled,
        permissionGranted: granted,
        bluetoothLeSupported: true,
      );
    } catch (e) {
      state = state.copyWith(
        bluetoothLeSupported: false,
        errorMessage: '蓝牙初始化失败: $e',
      );
    }
  }

  Future<void> refreshBluetoothState() async {
    try {
      final enabled = await _transport.isBluetoothAvailable();
      state = state.copyWith(bluetoothEnabled: enabled);
    } catch (_) {
      state = state.copyWith(bluetoothEnabled: false);
    }
  }

  Future<void> enableBluetooth() async {
    try {
      await _transport.enableBluetooth();
    } catch (_) {
      // 用户拒绝或平台不支持时保持原状，界面会继续显示未开启。
    }
    await refreshBluetoothState();
  }

  void onDeviceSelected(String deviceId) {
    if (state.selectedDeviceId == deviceId) {
      state = state.copyWith(clearSelected: true);
    } else {
      state = state.copyWith(selectedDeviceId: deviceId);
    }
  }

  // ======== 扫描 ========
  Future<void> startScan() async {
    if (state.isScanning) return;
    // 保留已连接设备的扫描记录
    final kept = <String, DeviceState>{};
    for (final e in state.devices.entries) {
      if (e.value.connected || e.value.connecting) kept[e.key] = e.value;
    }
    state = state.copyWith(
      isScanning: true,
      devices: kept,
      clearError: true,
    );
    _sortDevices();
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(milliseconds: scanPeriodMs), stopScan);

    await _scanSub?.cancel();
    _scanSub = _transport.scan().listen(
      _onScanResult,
      onError: (Object e) {
        state = state.copyWith(isScanning: false, errorMessage: '扫描错误: $e');
      },
    );
  }

  void _onScanResult(BleScanResult result) {
    final sensor = SensorDataParser.parseSensorData(result.rawScanRecord);
    final ibeacon = IBeaconCodec.parseConfig(result.rawScanRecord);
    final hasTl = SensorDataParser.hasTLDeviceData(result.rawScanRecord);
    final name = result.name ??
        SensorDataParser.parseDeviceNameFromScanRecord(result.rawScanRecord);

    // 与原 App 相同：必须有 TL 广播段。名称过滤保留 TL 前缀；
    // iOS 拿不到 Scan Response 名称时放行，避免完全扫不到设备。
    if (!hasTl) return;
    if (name != null && !name.startsWith('TL')) return;

    final prev = state.devices[result.deviceId];
    final now = DateTime.now().millisecondsSinceEpoch;
    final devices = Map<String, DeviceState>.from(state.devices);
    devices[result.deviceId] = (prev ?? DeviceState(deviceId: result.deviceId))
        .copyWith(
      name: name ?? prev?.name,
      rssi: result.rssi,
      timestamp: now,
      sensor: sensor,
      ibeacon: ibeacon,
      hasTlData: hasTl,
    );
    state = state.copyWith(devices: devices);
    _sortDevices();
  }

  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _transport.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    state = state.copyWith(isScanning: false);
  }

  // ======== 连接 ========
  bool _isConnecting(DeviceState? d) => d?.connecting ?? false;

  Future<void> connect(String deviceId) async {
    final existing = _device(deviceId);
    if (_isConnecting(existing) || (existing?.connected ?? false)) return;
    if (state.isScanning) await stopScan();

    // 关闭旧连接
    await _connections.remove(deviceId)?.close();

    _updateDevice(
      deviceId,
      (d) => d.copyWith(connecting: true, connected: false),
    );
    state = state.copyWith(clearError: true);

    final conn = DeviceConnection(deviceId: deviceId, transport: _transport);
    _connections[deviceId] = conn;
    _wireConnection(conn);

    _connectTimers.remove(deviceId)?.cancel();
    _connectTimers[deviceId] = Timer(
      const Duration(milliseconds: connectTimeoutMs),
      () {
        _connectTimers.remove(deviceId);
        final d = _device(deviceId);
        if (d != null && d.connecting) {
          _connections.remove(deviceId)?.close();
          _updateDevice(
            deviceId,
            (x) => x.copyWith(connecting: false, connected: false),
          );
          _showError('连接超时');
        }
      },
    );

    await conn.connect();
  }

  void _wireConnection(DeviceConnection conn) {
    final id = conn.deviceId;

    conn.onConnected = (connected) {
      _connectTimers.remove(id)?.cancel();
      if (connected) {
        _updateDevice(
          id,
          (d) => d.copyWith(connecting: false, connected: true),
        );
        state = state.copyWith(
          activeDeviceId: id,
          showPasswordDialog: true,
          passwordError: null,
          clearError: true,
        );
        Timer(const Duration(milliseconds: 300), () {
          conn.readRecordingStatus();
          conn.readRecordInterval();
        });
      } else {
        _connections.remove(id);
        _updateDevice(
          id,
          (d) => d.copyWith(
            connecting: false,
            connected: false,
            authenticated: false,
          ),
        );
        if (state.activeDeviceId == id) {
          state = state.copyWith(
            showPasswordDialog: false,
            showParamDialog: false,
            showRecordDialog: false,
            showLogisticsDialog: false,
            showStartConfirmDialog: false,
          );
        }
      }
    };

    conn.onConnError = (error) => _showError(error);

    conn.onPwdResult = (ok, error) {
      if (ok) {
        _updateDevice(id, (d) => d.copyWith(authenticated: true));
        state = state.copyWith(
          showPasswordDialog: false,
          clearPasswordError: true,
        );
        if (_pendingClearAfterPwd) {
          _pendingClearAfterPwd = false;
          executeClearRecords();
        }
      } else {
        state = state.copyWith(passwordError: error ?? '密码错误，请重试');
      }
    };

    conn.onCmdResult = (ok, message) {
      final isStart = message?.contains('0x02') == true;
      final isStop = message?.contains('0x03') == true;
      final isClear = message?.contains('0x05') == true;
      final isRead = message?.contains('0x07') == true ||
          message?.contains('0x08') == true;
      final friendly = switch (true) {
        _ when isStart => '开始记录',
        _ when isStop => '停止记录',
        _ when isClear && ok => '数据已清空',
        _ when isClear => '清除数据失败',
        _ when isRead && !ok => '设备没有数据',
        _ => message ?? '',
      };
      state = state.copyWith(recordResult: ok ? '✅ $friendly' : '❌ $friendly');
      if (isStart) {
        _updateDevice(id, (d) => d.copyWith(isRecording: ok));
      } else if (isStop) {
        _updateDevice(id, (d) => d.copyWith(isRecording: !ok));
      }
      if (isStart && ok) conn.readRecordInterval();
      if (isStop && ok) {
        Timer(const Duration(milliseconds: 300), conn.getInfo);
      }
      if (isClear && ok && _pendingStartAfterLogistics) {
        state = state.copyWith(showLogisticsDialog: true);
      }
    };

    conn.onDeviceInfo = (startTs, count, interval, recording) {
      _updateDevice(
        id,
        (d) => d.copyWith(
          firstTime: startTs,
          recordCount: count,
          deviceInterval: interval,
          isRecording: recording,
        ),
      );
      if (_pendingCheckFlashBeforeStart) {
        _pendingCheckFlashBeforeStart = false;
        if (count == 0) {
          _pendingStartAfterLogistics = true;
          state = state.copyWith(showLogisticsDialog: true);
        } else {
          startRecordingDirectly();
        }
      }
    };

    conn.onRecordIntervalResult = (interval) {
      _updateDevice(id, (d) => d.copyWith(deviceInterval: interval));
      final d = _device(id);
      if (d != null && d.isRecording && interval > 0) {
        _updateDevice(id, (x) => x.copyWith(deviceInterval: interval));
      }
    };

    conn.onRecordingStatus = (recording) {
      _updateDevice(id, (d) => d.copyWith(isRecording: recording));
    };

    conn.onReadProgress = (current, total) {
      _updateDevice(
        id,
        (d) => d.copyWith(readCurrent: current, readTotal: total),
      );
    };

    conn.onRecordsResult = (records) {
      if (_chunkAddress == id) {
        _onChunkReceived(id, records);
        return;
      }
      _updateDevice(
        id,
        (d) => d.copyWith(
          records: records,
          recordCount: records.length,
          readCurrent: 0,
          readTotal: 0,
        ),
      );
      final minTs = records.isEmpty
          ? 0
          : records.map((r) => r.timestamp).reduce((a, b) => a < b ? a : b);
      final maxTs = records.isEmpty
          ? 0
          : records.map((r) => r.timestamp).reduce((a, b) => a > b ? a : b);
      final showPicker = _pendingTimeRangePick;
      _pendingTimeRangePick = false;
      state = state.copyWith(
        recordResult: '✅ 共 ${records.length} 条',
        timeRangeMin: minTs,
        timeRangeMax: maxTs,
        showTimeRangePicker: showPicker,
        clearFilters: true,
      );
    };

    conn.onLogisticsRead = (info) {
      _updateDevice(id, (d) => d.copyWith(logistics: info));
    };

    conn.onLogisticsWritten = (ok) {
      if (ok) {
        Timer(const Duration(milliseconds: 500), conn.readLogisticsInfo);
      }
      if (_pendingStartAfterLogistics) {
        _pendingStartAfterLogistics = false;
        if (!ok) {
          state = state.copyWith(
            recordResult: '⚠️ 物流信息未保存到设备，但已开始记录',
          );
        }
        startRecordingDirectly();
      }
    };

    conn.onParamResult = (ok, error, suffix) {
      onParamAck(id, ok, error, suffix);
    };
  }

  Future<void> disconnect(String deviceId) async {
    await _connections.remove(deviceId)?.close();
    _updateDevice(
      deviceId,
      (d) => d.copyWith(
        connected: false,
        connecting: false,
        authenticated: false,
      ),
    );
    if (_chunkAddress == deviceId) {
      _chunkAccumulator.clear();
      _chunkNextIndex = 0;
      _chunkExpectedTotal = 0;
      _chunkAddress = null;
    }
    if (state.activeDeviceId == deviceId) {
      state = state.copyWith(
        showPasswordDialog: false,
        showParamDialog: false,
        showRecordDialog: false,
        showLogisticsDialog: false,
        showStartConfirmDialog: false,
      );
    }
  }

  // ======== 密码 ========
  void showPasswordDialog() {
    state = state.copyWith(showPasswordDialog: true, clearPasswordError: true);
  }

  void dismissPasswordDialog() {
    state = state.copyWith(showPasswordDialog: false);
  }

  Future<void> verifyPassword(String password) async {
    if (password.length < 4) {
      state = state.copyWith(passwordError: '密码至少4位');
      return;
    }
    final id = state.activeDeviceId;
    if (id == null) return;
    state = state.copyWith(clearPasswordError: true);
    await _connections[id]?.verifyPwd(password);
  }

  // ======== 设置 ========
  void updateAlarmThresholdLow(String value) {
    state = state.copyWith(alarmThresholdLow: value);
  }

  void updateAlarmThresholdHigh(String value) {
    state = state.copyWith(alarmThresholdHigh: value);
  }

  void toggleTemperatureUnit() {
    state = state.copyWith(
      temperatureUnit: state.temperatureUnit == TemperatureUnit.celsius
          ? TemperatureUnit.fahrenheit
          : TemperatureUnit.celsius,
    );
  }

  double? get alarmThresholdLowC {
    final v = double.tryParse(state.alarmThresholdLow.trim());
    return (v != null && v.isFinite) ? v : null;
  }

  double? get alarmThresholdHighC {
    final v = double.tryParse(state.alarmThresholdHigh.trim());
    return (v != null && v.isFinite) ? v : null;
  }

  String formatTemperature(double celsius) {
    final value = state.temperatureUnit == TemperatureUnit.celsius
        ? celsius
        : celsius * 9 / 5 + 32;
    return value.toStringAsFixed(2);
  }

  // ======== 参数编辑 ========
  void showParamEditor(String deviceId) {
    final d = _device(deviceId);
    if (d == null) return;
    final cached = d.beaconConfig;
    final beacon = cached ?? d.ibeacon;
    final name = d.cachedName ?? d.name ?? '';
    final sensor = d.sensor;
    state = state.copyWith(
      activeDeviceId: deviceId,
      showParamDialog: true,
      beaconName: name,
      beaconUuidHex: beacon?.uuidHex ?? IBeaconCodec.defaultUuidHex,
      beaconMajor: beacon?.major ?? IBeaconCodec.defaultMajor,
      beaconMinor: beacon?.minor ?? IBeaconCodec.defaultMinor,
      beaconCompany: beacon?.companyId ?? IBeaconCodec.defaultCompany,
      beaconRssi1m: beacon?.rssi1m ?? IBeaconCodec.defaultRssi1m,
      beaconParsed: beacon != null,
      currentIntervalCode: sensor?.intervalCode ?? 5,
      currentTxPower: sensor?.txPowerLevel ?? 4,
      paramFieldResults: const [],
      clearEditResult: true,
      paramBusy: false,
    );
  }

  void dismissParamDialog() {
    cancelParamWrite();
    state = state.copyWith(showParamDialog: false);
  }

  Future<void> writeAllParams({
    required int intervalCode,
    required int txPower,
    required String nameInput,
    required String uuidInput,
    required String majorInput,
    required String minorInput,
    required String companyInput,
    required String rssiInput,
  }) async {
    final id = state.activeDeviceId;
    if (id == null || state.paramBusy) return;
    final conn = _connections[id];
    if (conn == null) return;

    _paramResults.clear();
    _paramOpAddress = id;

    final normalizedName = IBeaconCodec.normalizeDeviceName(nameInput);
    if (normalizedName == null) {
      _paramResults.add(BeaconFieldResult(
        suffix: 'C2',
        title: paramTitles['C2']!,
        ok: false,
        detail:
            '名称不能为空且不超过 ${IBeaconCodec.deviceNameMaxBytes} 字节（中文 3 字节/字）',
      ));
    }
    final normalizedUuid = IBeaconCodec.normalizeUuidHex(uuidInput);
    if (normalizedUuid == null) {
      _paramResults.add(BeaconFieldResult(
        suffix: 'A1',
        title: paramTitles['A1']!,
        ok: false,
        detail: 'UUID 需为 32 位十六进制',
      ));
    }
    final major = IBeaconCodec.parseU16(majorInput.trim());
    if (major == null) {
      _paramResults.add(BeaconFieldResult(
        suffix: 'A2',
        title: paramTitles['A2']!,
        ok: false,
        detail: 'Major 需为 0-65535',
      ));
    }
    final minor = IBeaconCodec.parseU16(minorInput.trim());
    if (minor == null) {
      _paramResults.add(BeaconFieldResult(
        suffix: 'A3',
        title: paramTitles['A3']!,
        ok: false,
        detail: 'Minor 需为 0-65535',
      ));
    }
    final company = IBeaconCodec.parseCompany(companyInput);
    if (company == null) {
      _paramResults.add(BeaconFieldResult(
        suffix: 'A5',
        title: paramTitles['A5']!,
        ok: false,
        detail: 'Company ID 需为 0-65535（如 0x004C）',
      ));
    }
    final rssi = IBeaconCodec.parseSigned8(rssiInput.trim());
    if (rssi == null) {
      _paramResults.add(BeaconFieldResult(
        suffix: 'A8',
        title: paramTitles['A8']!,
        ok: false,
        detail: 'RSSI@1m 需为 -128..127',
      ));
    }

    final s = state;
    final ops = <_ParamOp>[];
    if (normalizedName != null && normalizedName != s.beaconName) {
      ops.add(_ParamOp(
        'C2',
        () => conn.writeName(normalizedName),
        () => state = state.copyWith(beaconName: normalizedName),
      ));
    }
    if (normalizedUuid != null && normalizedUuid != s.beaconUuidHex) {
      ops.add(_ParamOp(
        'A1',
        () => conn.writeUuid(normalizedUuid),
        () => state = state.copyWith(beaconUuidHex: normalizedUuid),
      ));
    }
    if (major != null && major != s.beaconMajor) {
      ops.add(_ParamOp(
        'A2',
        () => conn.writeMajor(major),
        () => state = state.copyWith(beaconMajor: major),
      ));
    }
    if (minor != null && minor != s.beaconMinor) {
      ops.add(_ParamOp(
        'A3',
        () => conn.writeMinor(minor),
        () => state = state.copyWith(beaconMinor: minor),
      ));
    }
    if (company != null && company != s.beaconCompany) {
      ops.add(_ParamOp(
        'A5',
        () => conn.writeCompanyId(company),
        () => state = state.copyWith(beaconCompany: company),
      ));
    }
    if (intervalCode != s.currentIntervalCode) {
      ops.add(_ParamOp(
        'A6',
        () => conn.writeInterval(intervalCode),
        () => state = state.copyWith(currentIntervalCode: intervalCode),
      ));
    }
    if (txPower != s.currentTxPower) {
      ops.add(_ParamOp(
        'A7',
        () => conn.writeTxPwr(txPower),
        () => state = state.copyWith(currentTxPower: txPower),
      ));
    }
    if (rssi != null && rssi != s.beaconRssi1m) {
      ops.add(_ParamOp(
        'A8',
        () => conn.writeRssi1m(rssi),
        () => state = state.copyWith(beaconRssi1m: rssi),
      ));
    }

    if (ops.isEmpty) {
      _paramOpAddress = null;
      state = state.copyWith(
        paramFieldResults: List.of(_paramResults),
        editResult: _paramResults.isEmpty
            ? '无改动，未写入'
            : '❌ ${_paramResults.length} 项校验失败，未写入',
      );
      return;
    }

    state = state.copyWith(
      paramBusy: true,
      paramFieldResults: List.of(_paramResults),
      editResult: '正在写入 ${ops.length} 项...',
    );
    _paramOps
      ..clear()
      ..addAll(ops);
    _dispatchNextParamOp();
  }

  void _dispatchNextParamOp() {
    if (_paramOps.isEmpty) {
      _finishParamWrite();
      return;
    }
    final op = _paramOps.first;
    final id = _paramOpAddress;
    if (id == null) return;

    _paramAckTimer?.cancel();
    _paramAckTimer = Timer(
      const Duration(milliseconds: paramAckTimeoutMs),
      () => onParamAck(id, false, '超时无应答', op.suffix),
    );
    Timer(Duration.zero, op.send);
  }

  void onParamAck(
    String address,
    bool ok,
    String? error,
    String? suffix,
  ) {
    if (address != _paramOpAddress) return;
    if (_paramOps.isEmpty || suffix == null) return;
    if (_paramOps.first.suffix != suffix) return;

    _paramAckTimer?.cancel();
    _paramAckTimer = null;
    final op = _paramOps.removeAt(0);
    _paramResults.add(BeaconFieldResult(
      suffix: suffix,
      title: paramTitles[suffix] ?? suffix,
      ok: ok,
      detail: ok ? '写入成功' : (error ?? '写入失败'),
    ));
    if (ok) op.commit();
    state = state.copyWith(paramFieldResults: List.of(_paramResults));

    if (_paramOps.isNotEmpty) {
      Timer(const Duration(milliseconds: paramOpGapMs), _dispatchNextParamOp);
    } else {
      _finishParamWrite();
    }
  }

  void _finishParamWrite() {
    final id = _paramOpAddress;
    _paramOps.clear();
    _paramAckTimer?.cancel();
    _paramAckTimer = null;
    final results = List<BeaconFieldResult>.of(_paramResults);
    _paramResults.clear();

    if (id != null) {
      _updateDevice(
        id,
        (d) => d.copyWith(
          beaconConfig: IBeaconConfig(
            uuidHex: state.beaconUuidHex,
            major: state.beaconMajor,
            minor: state.beaconMinor,
            companyId: state.beaconCompany,
            rssi1m: state.beaconRssi1m,
          ),
          cachedName: results.any((r) => r.suffix == 'C2' && r.ok)
              ? state.beaconName
              : d.cachedName,
        ),
      );
    }
    _paramOpAddress = null;
    final okCount = results.where((r) => r.ok).length;
    final failCount = results.length - okCount;
    final summary = results.isEmpty
        ? '无改动'
        : failCount == 0
            ? '✅ 全部写入成功'
            : okCount == 0
                ? '❌ 写入失败'
                : '✅ $okCount 项成功，❌ $failCount 项失败';
    state = state.copyWith(
      paramBusy: false,
      editResult: summary,
      paramFieldResults: results,
    );
  }

  void cancelParamWrite() {
    _paramAckTimer?.cancel();
    _paramAckTimer = null;
    _paramOps.clear();
    _paramOpAddress = null;
    _paramResults.clear();
  }

  // ======== 记录 ========
  void showRecordDialog(String deviceId) {
    final d = _device(deviceId);
    if (d == null) return;
    state = state.copyWith(
      activeDeviceId: deviceId,
      showRecordDialog: true,
      clearRecordResult: true,
      hasSelectedInterval: false,
      recordInterval: 0,
      recordDeviceName: d.displayName,
      recordDeviceAddress: deviceId,
      clearFilters: true,
    );
    _updateDevice(deviceId, (x) => x.copyWith(records: d.records));
    _connections[deviceId]?.getInfo();
    _connections[deviceId]?.readLogisticsInfo();
  }

  void dismissRecordDialog() {
    state = state.copyWith(showRecordDialog: false, clearExportResult: true);
  }

  void setRecordInterval(int seconds) {
    state = state.copyWith(
      recordInterval: seconds.clamp(1, 3600),
      hasSelectedInterval: true,
    );
  }

  void startRecording() {
    if (!state.hasSelectedInterval) {
      state = state.copyWith(recordResult: '请选择记录间隔');
      return;
    }
    state = state.copyWith(showStartConfirmDialog: true);
  }

  void startRecordingDirectly() {
    final id = state.activeDeviceId;
    if (id == null) return;
    final interval = state.recordInterval;
    _updateDevice(
      id,
      (d) => d.copyWith(isRecording: true, deviceInterval: interval),
    );
    state = state.copyWith(recordResult: '正在开始记录...');
    Timer(const Duration(milliseconds: 100), () {
      _connections[id]?.startRec(interval);
    });
  }

  void onConfirmClearAndStart() {
    state = state.copyWith(showStartConfirmDialog: false);
    _pendingStartAfterLogistics = true;
    clearRecords();
  }

  void onRejectClearAndStart() {
    state = state.copyWith(showStartConfirmDialog: false);
    final id = state.activeDeviceId;
    if (id == null) return;
    _pendingCheckFlashBeforeStart = true;
    _connections[id]?.getInfo();
  }

  void dismissStartConfirmDialog() {
    state = state.copyWith(showStartConfirmDialog: false);
  }

  void onSubmitLogisticsInfo(LogisticsInfo info) {
    final id = state.activeDeviceId;
    state = state.copyWith(showLogisticsDialog: false);
    if (id == null) return;
    _updateDevice(id, (d) => d.copyWith(logistics: info));
    _connections[id]?.writeLogisticsInfo(info);
  }

  void dismissLogisticsDialog() {
    _pendingStartAfterLogistics = false;
    state = state.copyWith(showLogisticsDialog: false);
  }

  void skipLogisticsDialog() {
    _pendingStartAfterLogistics = false;
    state = state.copyWith(showLogisticsDialog: false);
    startRecordingDirectly();
  }

  Future<void> readRecentRecords() async {
    final id = state.activeDeviceId;
    if (id == null) return;
    state = state.copyWith(recordResult: '正在读取最近10条记录...');
    await _connections[id]?.readRecentRecords(10);
  }

  Future<void> readAllRecords() async {
    final id = state.activeDeviceId;
    if (id == null) return;
    _chunkAddress = null;
    final d = _device(id);
    final total = d?.recordCount ?? 0;
    state = state.copyWith(
      recordResult: '正在读取所有记录...',
      clearFilters: true,
      showTimeRangePicker: false,
    );
    _updateDevice(id, (x) => x.copyWith(readCurrent: 0, readTotal: total));
    await _connections[id]?.readAllRecordsStream(expectedTotal: total);
  }

  Future<void> readAllRecordsForTimeRange() async {
    final id = state.activeDeviceId;
    if (id == null) return;
    final d = _device(id);
    final total = d?.recordCount ?? 0;
    _chunkAddress = null;
    _pendingTimeRangePick = true;
    state = state.copyWith(
      recordResult: '正在读取记录...',
      clearFilters: true,
      showTimeRangePicker: false,
    );
    _updateDevice(id, (x) => x.copyWith(readCurrent: 0, readTotal: total));
    await _connections[id]?.readAllRecordsStream(expectedTotal: total);
  }

  void _onChunkReceived(String id, List<RecordEntry> records) {
    _chunkAccumulator.addAll(records);
    _chunkNextIndex += records.length;
    final accumulated = _chunkAccumulator.length;
    final continueRead = records.length >= chunkSize &&
        (_chunkExpectedTotal == 0 || accumulated < _chunkExpectedTotal);
    if (continueRead) {
      state = state.copyWith(recordResult: '正在读取... ($accumulated 条)');
      _connections[id]?.readRecordsChunk(_chunkNextIndex, chunkSize);
      return;
    }
    final result = List<RecordEntry>.of(_chunkAccumulator);
    _chunkAccumulator.clear();
    _chunkNextIndex = 0;
    _chunkExpectedTotal = 0;
    _chunkAddress = null;
    _updateDevice(
      id,
      (d) => d.copyWith(records: result, recordCount: result.length),
    );
    state = state.copyWith(recordResult: '✅ 共 ${result.length} 条');
  }

  void applyTimeRangeFilter(int startTime, int endTime) {
    state = state.copyWith(
      filterStartTime: startTime,
      filterEndTime: endTime,
      showTimeRangePicker: false,
      clearRecordResult: true,
    );
  }

  void cancelTimeRangePick() {
    _pendingTimeRangePick = false;
    state = state.copyWith(showTimeRangePicker: false);
  }

  Future<void> readRecordsByTime(int startEpochSec, int endEpochSec) async {
    final id = state.activeDeviceId;
    if (id == null) return;
    state = state.copyWith(
      recordResult: '正在按时间段读取...',
      filterStartTime: startEpochSec,
      filterEndTime: endEpochSec,
    );
    await _connections[id]?.readRecordsByTime(startEpochSec, endEpochSec);
  }

  void clearRecords() {
    final id = state.activeDeviceId;
    if (id == null) {
      state = state.copyWith(recordResult: '✅ 数据已清空');
      return;
    }
    _pendingClearAfterPwd = true;
    state = state.copyWith(showPasswordDialog: true, clearPasswordError: true);
  }

  void executeClearRecords() {
    _pendingClearAfterPwd = false;
    final id = state.activeDeviceId;
    if (id == null) return;
    _updateDevice(
      id,
      (d) => d.copyWith(records: const [], recordCount: 0),
    );
    state = state.copyWith(
      recordResult: '正在清除设备数据...',
      showPasswordDialog: false,
      clearPasswordError: true,
      clearFilters: true,
      showTimeRangePicker: false,
    );
    Timer(const Duration(milliseconds: 200), () {
      _connections[id]?.clearDeviceRecords();
    });
  }

  Future<void> stopRecording() async {
    final id = state.activeDeviceId;
    if (id == null) return;
    _updateDevice(
      id,
      (d) => d.copyWith(isRecording: false, deviceInterval: 0),
    );
    state = state.copyWith(
      recordResult: '正在停止记录...',
      recordInterval: 0,
      hasSelectedInterval: false,
    );
    await _connections[id]?.stopRec();
  }

  // ======== 导出 ========
  Future<void> savePdfToDownloads() async {
    if (state.isExporting) return;
    final id = state.activeDeviceId;
    final device = id == null ? null : _device(id);
    final records = device?.records ?? const <RecordEntry>[];
    if (records.isEmpty) {
      state = state.copyWith(exportResult: '❌ 没有记录可导出');
      return;
    }

    state = state.copyWith(
      isExporting: true,
      exportProgress: 0,
      clearExportResult: true,
    );
    try {
      final deviceName = state.recordDeviceName.isNotEmpty
          ? state.recordDeviceName
          : (device?.displayName ?? 'TL-Device');
      final deviceAddress = state.recordDeviceAddress.isNotEmpty
          ? state.recordDeviceAddress
          : (id ?? 'Unknown');
      final fonts = await AppPdfFonts.load();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = '$deviceName-$stamp.pdf';
      final bytes = await PdfReportBuilder.build(
        records: records,
        deviceName: deviceName,
        deviceAddress: deviceAddress,
        unit: state.temperatureUnit,
        thresholdLowC: double.tryParse(state.alarmThresholdLow.trim()),
        thresholdHighC: double.tryParse(state.alarmThresholdHigh.trim()),
        logistics: device?.logistics,
        filterStartTime: state.filterStartTime,
        filterEndTime: state.filterEndTime,
        font: fonts.regular,
        boldFont: fonts.bold,
        fileName: fileName,
        onProgress: (p) => state = state.copyWith(exportProgress: p),
      );
      await ExportService.savePdf(fileName, bytes);
      state = state.copyWith(
        exportResult: '✅ PDF 已保存到下载目录',
        isExporting: false,
        exportProgress: 1,
      );
    } catch (e) {
      state = state.copyWith(
        exportResult: '❌ PDF 保存失败: $e',
        isExporting: false,
        exportProgress: 0,
      );
    }
  }

  Future<void> saveCsvToDownloads() async {
    if (state.isExporting) return;
    final id = state.activeDeviceId;
    final device = id == null ? null : _device(id);
    final records = device?.records ?? const <RecordEntry>[];
    if (records.isEmpty) {
      state = state.copyWith(exportResult: '❌ 没有记录可导出');
      return;
    }

    state = state.copyWith(
      isExporting: true,
      exportProgress: 0,
      clearExportResult: true,
    );
    try {
      final deviceName = state.recordDeviceName.isNotEmpty
          ? state.recordDeviceName
          : (device?.displayName ?? 'TL-Device');
      final deviceAddress = state.recordDeviceAddress.isNotEmpty
          ? state.recordDeviceAddress
          : (id ?? 'Unknown');
      final csv = CsvExporter.build(
        records: records,
        deviceName: deviceName,
        deviceAddress: deviceAddress,
        unit: state.temperatureUnit,
        thresholdLowC: double.tryParse(state.alarmThresholdLow.trim()),
        thresholdHighC: double.tryParse(state.alarmThresholdHigh.trim()),
        logistics: device?.logistics,
        filterStartTime: state.filterStartTime,
        filterEndTime: state.filterEndTime,
      );
      state = state.copyWith(exportProgress: 0.95);
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = '$deviceName-$stamp.csv';
      await ExportService.saveCsv(
        fileName,
        Uint8List.fromList(utf8.encode(csv)),
      );
      state = state.copyWith(
        exportResult: '✅ CSV 已保存到下载目录',
        isExporting: false,
        exportProgress: 1,
      );
    } catch (e) {
      state = state.copyWith(
        exportResult: '❌ CSV 保存失败: $e',
        isExporting: false,
        exportProgress: 0,
      );
    }
  }
}

class _ParamOp {
  _ParamOp(this.suffix, this.send, this.commit);

  final String suffix;
  final Future<void> Function() send;
  final void Function() commit;
}
