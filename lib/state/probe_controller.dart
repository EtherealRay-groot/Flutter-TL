import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/ble_transport.dart';
import '../ble/device_connection.dart';
import '../ble/universal_ble_transport.dart';
import '../core/protocol/ibeacon_codec.dart';
import '../core/protocol/logistics_info.dart';
import '../core/protocol/record_entry.dart';
import '../core/protocol/sensor_data.dart';

/// 扫描到的 TL 设备及其解析结果。
class ProbeDevice {
  const ProbeDevice({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.sensor,
    required this.ibeacon,
    required this.hasTlData,
    required this.manufacturerData,
    required this.serviceData,
    required this.services,
  });

  final String deviceId;
  final String? name;
  final int rssi;
  final SensorData? sensor;
  final IBeaconConfig? ibeacon;
  final bool hasTlData;
  final Map<int, Uint8List> manufacturerData;
  final Map<String, Uint8List> serviceData;
  final List<String> services;

  ProbeDevice copyWith({int? rssi, SensorData? sensor, String? name}) =>
      ProbeDevice(
        deviceId: deviceId,
        name: name ?? this.name,
        rssi: rssi ?? this.rssi,
        sensor: sensor ?? this.sensor,
        ibeacon: ibeacon,
        hasTlData: hasTlData,
        manufacturerData: manufacturerData,
        serviceData: serviceData,
        services: services,
      );
}

class ProbeState {
  const ProbeState({
    this.scanning = false,
    this.bluetoothOn = false,
    this.permissionGranted = false,
    this.error,
    this.devices = const [],
    this.connectedId,
    this.connectingId,
    this.mtu,
    this.services = const [],
    this.status = '未连接',
    this.logs = const [],
    this.records = const [],
    this.recordCount,
    this.startTimestamp,
    this.recordInterval,
    this.recording,
    this.logistics,
    this.readProgressCurrent = 0,
    this.readProgressTotal = 0,
  });

  final bool scanning;
  final bool bluetoothOn;
  final bool permissionGranted;
  final String? error;
  final List<ProbeDevice> devices;
  final String? connectedId;
  final String? connectingId;
  final int? mtu;
  final List<String> services;
  final String status;
  final List<String> logs;
  final List<RecordEntry> records;
  final int? recordCount;
  final int? startTimestamp;
  final int? recordInterval;
  final bool? recording;
  final LogisticsInfo? logistics;
  final int readProgressCurrent;
  final int readProgressTotal;

  ProbeState copyWith({
    bool? scanning,
    bool? bluetoothOn,
    bool? permissionGranted,
    String? error,
    bool clearError = false,
    List<ProbeDevice>? devices,
    String? connectedId,
    bool clearConnected = false,
    String? connectingId,
    bool clearConnecting = false,
    int? mtu,
    List<String>? services,
    String? status,
    List<String>? logs,
    List<RecordEntry>? records,
    int? recordCount,
    int? startTimestamp,
    int? recordInterval,
    bool? recording,
    LogisticsInfo? logistics,
    int? readProgressCurrent,
    int? readProgressTotal,
  }) =>
      ProbeState(
        scanning: scanning ?? this.scanning,
        bluetoothOn: bluetoothOn ?? this.bluetoothOn,
        permissionGranted: permissionGranted ?? this.permissionGranted,
        error: clearError ? null : (error ?? this.error),
        devices: devices ?? this.devices,
        connectedId: clearConnected ? null : (connectedId ?? this.connectedId),
        connectingId:
            clearConnecting ? null : (connectingId ?? this.connectingId),
        mtu: mtu ?? this.mtu,
        services: services ?? this.services,
        status: status ?? this.status,
        logs: logs ?? this.logs,
        records: records ?? this.records,
        recordCount: recordCount ?? this.recordCount,
        startTimestamp: startTimestamp ?? this.startTimestamp,
        recordInterval: recordInterval ?? this.recordInterval,
        recording: recording ?? this.recording,
        logistics: logistics ?? this.logistics,
        readProgressCurrent:
            readProgressCurrent ?? this.readProgressCurrent,
        readProgressTotal: readProgressTotal ?? this.readProgressTotal,
      );
}

final probeControllerProvider =
    NotifierProvider<ProbeController, ProbeState>(ProbeController.new);

/// 真机 BLE 验证控制器（扫描 → 连接 → 读设备信息/记录/物流）。
///
/// 这个界面是 Phase 3 的风险闸门，用来验证 universal_ble 在真实 TL 设备上
/// 能否拿到广播字段、完成连接、长读 FFC5、接收 FFD2 通知。
class ProbeController extends Notifier<ProbeState> {
  final BleTransport _transport = UniversalBleTransport();
  final Map<String, ProbeDevice> _deviceMap = {};
  final Map<String, DeviceConnection> _connections = {};

  StreamSubscription<BleScanResult>? _scanSub;
  Timer? _scanTimer;
  DeviceConnection? _active;

  @override
  ProbeState build() {
    ref.onDispose(() {
      _scanTimer?.cancel();
      _scanSub?.cancel();
      _transport.dispose();
    });
    return const ProbeState();
  }

  void _log(String line) {
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(11, 19);
    final logs = [...state.logs, '$stamp  $line'];
    state = state.copyWith(
      logs: logs.length > 300 ? logs.sublist(logs.length - 300) : logs,
    );
  }

  Future<void> initialize() async {
    try {
      final bluetoothOn = await _transport.isBluetoothAvailable();
      var granted = await _transport.hasPermissions();
      if (!granted) {
        try {
          await _transport.requestPermissions();
          granted = await _transport.hasPermissions();
        } catch (e) {
          _log('权限申请失败: $e');
        }
      }
      state = state.copyWith(
        bluetoothOn: bluetoothOn,
        permissionGranted: granted,
        status: bluetoothOn ? (granted ? '就绪' : '缺少权限') : '蓝牙未开启',
      );
      _log('蓝牙可用=$bluetoothOn 权限=$granted');
    } catch (e) {
      state = state.copyWith(error: '初始化失败: $e');
      _log('初始化失败: $e');
    }
  }

  Future<void> startScan() async {
    if (state.scanning) return;
    _deviceMap.clear();
    state = state.copyWith(
      scanning: true,
      devices: const [],
      clearError: true,
      status: '扫描中...',
    );
    _log('开始扫描');
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 30), () {
      _log('扫描超时（30s），自动停止');
      stopScan();
    });

    _scanSub?.cancel();
    _scanSub = _transport.scan().listen(
      (result) {
        final sensor = SensorDataParser.parseSensorData(result.rawScanRecord);
        final ibeacon = IBeaconCodec.parseConfig(result.rawScanRecord);
        final hasTl = SensorDataParser.hasTLDeviceData(result.rawScanRecord);
        final name = result.name ??
            SensorDataParser.parseDeviceNameFromScanRecord(
              result.rawScanRecord,
            );
        // 与原 App 相同的两道过滤：带 TL 广播段 + 名称以 TL 开头。
        // K 系列等产品会复用同一 Service Data，仅靠 UUID 无法区分。
        if (!hasTl) return;
        if (name == null || !name.startsWith('TL')) return;
        if (!_deviceMap.containsKey(result.deviceId)) {
          _log(
            '发现 TL 设备 $name '
            'rssi=${result.rssi} sensor=${sensor != null} '
            'ibeacon=${ibeacon != null} '
            'mfr=${result.manufacturerData.keys.map((k) => "0x${k.toRadixString(16).padLeft(4, "0").toUpperCase()}").join(",")}',
          );
        }
        _deviceMap[result.deviceId] = ProbeDevice(
          deviceId: result.deviceId,
          name: name,
          rssi: result.rssi,
          sensor: sensor,
          ibeacon: ibeacon,
          hasTlData: hasTl,
          manufacturerData: result.manufacturerData,
          serviceData: result.serviceData,
          services: result.services,
        );
        final devices = _deviceMap.values.toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
        state = state.copyWith(devices: devices);
      },
      onError: (Object e) {
        _log('扫描错误: $e');
        state = state.copyWith(scanning: false, error: '扫描错误: $e');
      },
    );

  }

  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _transport.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    state = state.copyWith(scanning: false, status: '扫描已停止');
    _log('停止扫描，发现 ${state.devices.length} 台设备');
  }

  Future<void> connect(String deviceId) async {
    if (state.connectingId != null) return;
    // universal_ble 建议连接前停止扫描，Android 上边扫边连容易卡在 connecting。
    if (state.scanning) await stopScan();
    await disconnect();
    state = ProbeState(
      scanning: state.scanning,
      bluetoothOn: state.bluetoothOn,
      permissionGranted: state.permissionGranted,
      devices: state.devices,
      logs: state.logs,
      connectingId: deviceId,
      status: '连接中 $deviceId',
    );
    _log('连接 $deviceId');

    final conn = DeviceConnection(deviceId: deviceId, transport: _transport);
    _connections[deviceId] = conn;
    _active = conn;
    _wire(conn);

    await conn.connect();
  }

  void _wire(DeviceConnection conn) {
    conn.onConnected = (connected) {
      if (connected) {
        state = state.copyWith(
          connectedId: conn.deviceId,
          clearConnecting: true,
          mtu: conn.mtu,
          services: conn.serviceUuids,
          status: '已连接',
        );
        _log('已连接，MTU=${conn.mtu}');
        Timer(const Duration(milliseconds: 300), () {
          conn.getInfo();
          conn.readRecordingStatus();
          conn.readRecordInterval();
          conn.readLogisticsInfo();
        });
      } else {
        state = state.copyWith(
          clearConnected: true,
          clearConnecting: true,
          status: '已断开',
        );
        _log('连接断开');
      }
    };
    conn.onConnError = (e) {
      _log('连接错误: $e');
      state = state.copyWith(error: e, status: '连接错误');
    };
    conn.onCmdResult = (ok, message) {
      _log('命令 ${ok ? '成功' : '失败'}: $message');
    };
    conn.onPwdResult = (ok, error) {
      _log('密码验证: $ok ${error ?? ''}');
    };
    conn.onParamResult = (ok, error, suffix) {
      _log('参数 $suffix: $ok ${error ?? ''}');
    };
    conn.onDeviceInfo = (startTs, count, interval, recording) {
      state = state.copyWith(
        startTimestamp: startTs,
        recordCount: count,
        recordInterval: interval,
        recording: recording,
      );
      _log('设备信息: 起始=$startTs 条数=$count 间隔=${interval}s 记录中=$recording');
    };
    conn.onRecordingStatus = (recording) {
      state = state.copyWith(recording: recording);
      _log('记录状态: $recording');
    };
    conn.onRecordIntervalResult = (interval) {
      state = state.copyWith(recordInterval: interval);
      _log('记录间隔: ${interval}s');
    };
    conn.onReadProgress = (current, total) {
      state = state.copyWith(
        readProgressCurrent: current,
        readProgressTotal: total,
      );
    };
    conn.onRecordsResult = (records) {
      state = state.copyWith(
        records: records,
        recordCount: records.length,
        readProgressCurrent: records.length,
        status: '已读取 ${records.length} 条记录',
      );
      _log('读取完成: ${records.length} 条');
    };
    conn.onLogisticsRead = (info) {
      state = state.copyWith(logistics: info);
      _log('物流信息: ${info == null ? "null" : "公司=${info.company} 单号=${info.goodsNo}"}');
    };
    conn.onLogisticsWritten = (ok) {
      _log('物流写入: $ok');
    };
  }

  Future<void> disconnect() async {
    final active = _active;
    _active = null;
    if (active != null) {
      _connections.remove(active.deviceId);
      await active.close();
    }
    state = state.copyWith(
      clearConnected: true,
      clearConnecting: true,
      status: '未连接',
    );
  }

  Future<void> readAllRecords() async {
    final conn = _active;
    if (conn == null) return;
    state = state.copyWith(
      records: const [],
      readProgressCurrent: 0,
      readProgressTotal: state.recordCount ?? 0,
      status: '读取全部记录...',
    );
    _log('读取全部记录（预期 ${state.recordCount ?? "未知"} 条）');
    await conn.readAllRecordsStream(expectedTotal: state.recordCount ?? 0);
  }

  Future<void> readDeviceInfo() async {
    final conn = _active;
    if (conn == null) return;
    _log('读取设备信息');
    await conn.getInfo();
  }

  /// 文档默认密码 1234；FFD0 命令（尤其 0x02/0x05/0x08）需要先认证。
  Future<void> verifyDefaultPassword() async {
    final conn = _active;
    if (conn == null) return;
    _log('验证密码 1234');
    await conn.verifyPwd('1234');
  }

  /// 验证用：以 1 秒间隔开始记录。会写入设备 Flash。
  Future<void> startRecording() async {
    final conn = _active;
    if (conn == null) return;
    _log('开始记录（间隔 1s）');
    await conn.startRec(1);
  }

  Future<void> stopRecording() async {
    final conn = _active;
    if (conn == null) return;
    _log('停止记录');
    await conn.stopRec();
  }

  Future<void> readLogistics() async {
    final conn = _active;
    if (conn == null) return;
    _log('读取物流信息');
    await conn.readLogisticsInfo();
  }

  void clearLogs() {
    state = state.copyWith(logs: const []);
  }
}
