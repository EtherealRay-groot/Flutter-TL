import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/protocol/commands.dart';
import '../core/protocol/logistics_info.dart';
import '../core/protocol/record_entry.dart';
import 'ble_transport.dart';

/// 单台设备的 GATT 连接、命令、通知分发与历史记录批次管理。
///
/// 与原 Kotlin `BluetoothLeConnectionManager` 一一对应。回调闭包只属于
/// 本实例，调用方按 deviceId 绑定，避免多设备串线。
class DeviceConnection {
  DeviceConnection({
    required this.deviceId,
    required this.transport,
  });

  final String deviceId;
  final BleTransport transport;

  static const int batchIdleTimeoutMs = 500;
  static const int recordingStatusMarker = 0x01;

  // 回调
  void Function(bool connected)? onConnected;
  void Function(String error)? onConnError;
  void Function(bool ok, String? error)? onPwdResult;
  void Function(bool ok, String? error, String? suffix)? onParamResult;
  void Function(bool ok, String? message)? onCmdResult;
  void Function(List<RecordEntry> records)? onRecordsResult;
  void Function(int interval)? onRecordIntervalResult;
  void Function(bool isRecording)? onRecordingStatus;
  void Function(int startTs, int count, int intervalSec, bool isRecording)?
      onDeviceInfo;
  void Function(int current, int total)? onReadProgress;
  void Function(LogisticsInfo? info)? onLogisticsRead;
  void Function(bool ok)? onLogisticsWritten;

  final Map<String, BleServiceRef> _services = {};
  bool _connected = false;
  bool _closing = false;
  int mtu = 23;

  StreamSubscription<bool>? _connSub;
  Timer? _readTimer;

  final List<RecordEntry> _accumulatedRecords = [];
  bool _hasReceivedRecords = false;
  bool _recordsFinalized = false;
  int _expectedReadTotal = 0;

  bool get isConnected => _connected;

  /// 已发现的服务 UUID（用于诊断界面）。
  List<String> get serviceUuids =>
      _services.keys.toList(growable: false);

  BleCharacteristicRef? _characteristic(String service, String char) {
    final s = _services[service];
    if (s == null) return null;
    for (final c in s.characteristics) {
      if (c.uuid == char) return c;
    }
    return null;
  }

  /// 连接 → 发现服务 → 请求 MTU → 开启 FFC4/FFD2 通知。
  ///
  /// Android status=133 重连一次（与原实现一致）。
  Future<void> connect() async {
    _closing = false;
    try {
      await transport.connect(deviceId);
    } catch (_) {
      // Android 上 133（GATT_ERROR）常见于刚断开后立刻重连。
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        await transport.connect(deviceId);
      } catch (e) {
        onConnected?.call(false);
        onConnError?.call('连接失败: $e');
        return;
      }
    }

    _connSub = transport.connectionState(deviceId).listen((connected) {
      if (!connected && !_closing && _connected) {
        onConnError?.call('连接已断开');
        _release();
        onConnected?.call(false);
      }
    });

    List<BleServiceRef> discovered;
    try {
      discovered = await transport.discoverServices(deviceId);
    } catch (e) {
      onConnError?.call('服务发现失败');
      await close();
      onConnected?.call(false);
      return;
    }
    _services
      ..clear()
      ..addEntries(discovered.map((s) => MapEntry(s.uuid, s)));

    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      mtu = await transport.requestMtu(deviceId, 512);
    } catch (_) {
      mtu = 23;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await _enableNotifications();
    _connected = true;
    onConnected?.call(true);
  }

  Future<void> _enableNotifications() async {
    // 不依赖 characteristic properties 判定：原 Android 实现是直接
    // setCharacteristicNotification + 写 CCCD，固件属性表偶尔不完整。
    // 这里同样「先尝试，失败再容错」，避免因属性缺失导致完全收不到通知。
    final ffc4 = _characteristic(BleUuids.ffc0, BleUuids.ffc4);
    if (ffc4 != null) {
      try {
        await transport.setNotifiable(
          deviceId,
          BleUuids.ffc0,
          BleUuids.ffc4,
          enabled: true,
          onValue: _onFfc4,
        );
      } catch (_) {
        // 原实现同样容错：没有 CCCD 时继续连接。
      }
    }
    final ffd2 = _characteristic(BleUuids.ffd0, BleUuids.ffd2);
    if (ffd2 != null) {
      try {
        await transport.setNotifiable(
          deviceId,
          BleUuids.ffd0,
          BleUuids.ffd2,
          enabled: true,
          onValue: _onFfd2,
        );
      } catch (_) {
        // 继续连接，后续命令可能收不到通知。
      }
    }
  }

  Future<void> close() async {
    _closing = true;
    _release();
    try {
      await transport.disconnect(deviceId);
    } catch (_) {}
    _connected = false;
  }

  void _release() {
    _closing = true;
    _readTimer?.cancel();
    _readTimer = null;
    _connSub?.cancel();
    _connSub = null;
    _accumulatedRecords.clear();
    _hasReceivedRecords = false;
    _recordsFinalized = false;
    _expectedReadTotal = 0;
    _services.clear();
    _connected = false;
  }

  // ======== 密码 ========
  Future<void> verifyPwd(String pwd) async {
    final ok = await _write(
      BleUuids.ffc0,
      BleUuids.ffc3,
      TlCommands.verifyPassword(pwd),
    );
    if (!ok) onPwdResult?.call(false, '写入失败');
  }

  // ======== 设备名称（FFC2，裸 UTF-8） ========
  Future<void> writeName(String name) async {
    await _writeParam(
      BleUuids.ffc0,
      BleUuids.ffc2,
      TlCommands.writeName(name),
      'C2',
      'Name',
    );
  }

  // ======== 参数写入（FFAx，0x24 前缀） ========
  Future<void> writeInterval(int code) => _writeParam(
        BleUuids.ffa0,
        BleUuids.ffa6,
        TlCommands.writeInterval(code),
        'A6',
        'Interval',
      );

  Future<void> writeTxPwr(int value) => _writeParam(
        BleUuids.ffa0,
        BleUuids.ffa7,
        TlCommands.writeTxPower(value),
        'A7',
        'TxPower',
      );

  Future<void> writeUuid(String hex32) async {
    if (hex32.length != 32) {
      onParamResult?.call(false, 'UUID 格式错误', 'A1');
      return;
    }
    await _writeParam(
      BleUuids.ffa0,
      BleUuids.ffa1,
      TlCommands.writeUuid(hex32),
      'A1',
      'Uuid',
    );
  }

  Future<void> writeMajor(int value) => _writeParam(
        BleUuids.ffa0,
        BleUuids.ffa2,
        TlCommands.writeMajor(value),
        'A2',
        'Major',
      );

  Future<void> writeMinor(int value) => _writeParam(
        BleUuids.ffa0,
        BleUuids.ffa3,
        TlCommands.writeMinor(value),
        'A3',
        'Minor',
      );

  Future<void> writeCompanyId(int value) => _writeParam(
        BleUuids.ffa0,
        BleUuids.ffa5,
        TlCommands.writeCompany(value),
        'A5',
        'Company',
      );

  Future<void> writeRssi1m(int value) => _writeParam(
        BleUuids.ffa0,
        BleUuids.ffa8,
        TlCommands.writeRssi(value),
        'A8',
        'Rssi',
      );

  Future<void> _writeParam(
    String service,
    String char,
    Uint8List data,
    String suffix,
    String tag,
  ) async {
    if (_characteristic(service, char) == null) {
      onParamResult?.call(false, '未找到 $tag 特征', suffix);
      return;
    }
    final ok = await _write(service, char, data);
    if (!ok) onParamResult?.call(false, '写入失败', suffix);
  }

  // ======== 记录命令 ========
  Future<void> startRec(int intervalSec) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _sendCmd(
      TlCommands.startRecording(ts, intervalSec),
      '未找到命令特征',
    );
  }

  Future<void> stopRec() =>
      _sendCmd(TlCommands.stopRecording(), '未找到命令特征');

  Future<void> getInfo() =>
      _sendCmd(TlCommands.getInfo(), '未找到命令特征');

  Future<void> cancelStream() async {
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd1) == null) return;
    await _write(BleUuids.ffd0, BleUuids.ffd1, TlCommands.cancelStream());
  }

  Future<void> _sendCmd(Uint8List data, String missingError) async {
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd1) == null) {
      onCmdResult?.call(false, missingError);
      return;
    }
    final ok = await _write(BleUuids.ffd0, BleUuids.ffd1, data);
    if (!ok) onCmdResult?.call(false, '写入失败');
  }

  void _resetReadState() {
    _accumulatedRecords.clear();
    _hasReceivedRecords = false;
    _recordsFinalized = false;
    _expectedReadTotal = 0;
    _readTimer?.cancel();
    _readTimer = null;
  }

  void _scheduleFallbackTimer() {
    _readTimer?.cancel();
    _readTimer = Timer(
      const Duration(milliseconds: batchIdleTimeoutMs),
      () {
        if (_recordsFinalized) return;
        _recordsFinalized = true;
        _readTimer = null;
        final result = List<RecordEntry>.of(_accumulatedRecords);
        _accumulatedRecords.clear();
        _hasReceivedRecords = false;
            onRecordsResult?.call(result);
      },
    );
  }

  Future<void> readRecentRecords(int count) async {
    _resetReadState();
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd1) == null) {
      onCmdResult?.call(false, '未找到命令特征');
      return;
    }
    final ok = await _write(
      BleUuids.ffd0,
      BleUuids.ffd1,
      TlCommands.readRecent(count),
    );
    if (!ok) onCmdResult?.call(false, '写入失败');
  }

  Future<void> readAllRecordsStream({int expectedTotal = 0}) async {
    _resetReadState();
    _expectedReadTotal = expectedTotal;
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd1) == null) {
      onCmdResult?.call(false, '未找到命令特征');
      return;
    }
    final ok = await _write(
      BleUuids.ffd0,
      BleUuids.ffd1,
      TlCommands.readAll(),
    );
    if (!ok) onCmdResult?.call(false, '写入失败');
  }

  Future<void> readRecordsChunk(int startIndex, int count) async {
    _resetReadState();
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd1) == null) {
      onCmdResult?.call(false, '未找到命令特征');
      return;
    }
    final ok = await _write(
      BleUuids.ffd0,
      BleUuids.ffd1,
      TlCommands.readChunk(startIndex, count),
    );
    if (!ok) onCmdResult?.call(false, '写入失败');
  }

  Future<void> readRecordsByTime(int startEpochSec, int endEpochSec) async {
    _resetReadState();
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd1) == null) {
      onCmdResult?.call(false, '未找到命令特征');
      return;
    }
    final ok = await _write(
      BleUuids.ffd0,
      BleUuids.ffd1,
      TlCommands.readByTime(startEpochSec, endEpochSec),
    );
    if (!ok) onCmdResult?.call(false, '写入失败');
  }

  Future<void> clearDeviceRecords() async {
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd1) == null) {
      onCmdResult?.call(false, '未找到命令特征');
      return;
    }
    final ok = await _write(
      BleUuids.ffd0,
      BleUuids.ffd1,
      TlCommands.clearRecords(),
    );
    if (!ok) onCmdResult?.call(false, '写入失败');
  }

  Future<void> readRecordInterval() async {
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd4) == null) return;
    try {
      final raw = await transport.readCharacteristic(
        deviceId,
        BleUuids.ffd0,
        BleUuids.ffd4,
      );
      if (raw.length >= 2) {
        onRecordIntervalResult?.call((raw[0] << 8) | raw[1]);
      }
    } catch (_) {
      // 与原实现一致：读取失败不回调。
    }
  }

  Future<void> readRecordingStatus() async {
    if (_characteristic(BleUuids.ffd0, BleUuids.ffd3) == null) {
      onRecordingStatus?.call(false);
      return;
    }
    try {
      final raw = await transport.readCharacteristic(
        deviceId,
        BleUuids.ffd0,
        BleUuids.ffd3,
      );
      onRecordingStatus?.call(
        raw.isNotEmpty && raw[0] == recordingStatusMarker,
      );
    } catch (_) {
      onRecordingStatus?.call(false);
    }
  }

  Future<void> readLogisticsInfo() async {
    if (_characteristic(BleUuids.ffc0, BleUuids.ffc5) == null) {
      onLogisticsRead?.call(null);
      return;
    }
    try {
      final raw = await transport.readCharacteristic(
        deviceId,
        BleUuids.ffc0,
        BleUuids.ffc5,
      );
      onLogisticsRead?.call(LogisticsInfo.decode(raw));
    } catch (_) {
      onLogisticsRead?.call(null);
    }
  }

  /// 逐槽写入 11 个字段；失败也继续（与原实现一致），最后统一回调。
  Future<void> writeLogisticsInfo(LogisticsInfo info) async {
    final c = _characteristic(BleUuids.ffc0, BleUuids.ffc5);
    if (c == null) {
      onLogisticsWritten?.call(false);
      return;
    }
    final packets = LogisticsInfo.packetsFor(info);
    var failed = false;
    for (final packet in packets) {
      final ok = await _write(
        BleUuids.ffc0,
        BleUuids.ffc5,
        packet,
        withResponse: !c.canWriteWithoutResponse,
      );
      if (!ok) failed = true;
    }
    onLogisticsWritten?.call(!failed);
  }

  // ======== 通知处理 ========
  void _onFfc4(Uint8List raw) {
    final s = ascii.decode(raw, allowInvalid: true).trim();
    final ok = s.contains('@');
    final err = ok ? null : '设备拒绝: $s';
    if (s.endsWith('C3')) {
      onPwdResult?.call(ok, err);
      return;
    }
    const suffixes = ['C2', 'A1', 'A2', 'A3', 'A5', 'A6', 'A7', 'A8'];
    for (final suffix in suffixes) {
      if (s.endsWith(suffix)) {
        onParamResult?.call(ok, err, suffix);
        return;
      }
    }
  }

  void _onFfd2(Uint8List raw) {
    if (raw.isEmpty) return;
    final cmd = raw[0];
    final ok = raw.length > 1 && raw[1] == 0;
    if (!ok) {
      onCmdResult?.call(false, '命令 0x${cmd.toRadixString(16).padLeft(2, '0')} 失败');
      return;
    }

    if ((cmd == 0x07 || cmd == 0x08 || cmd == 0x0A) && raw.length >= 4) {
      final dataLen = (raw[2] << 8) | raw[3];
      if (dataLen == 0) {
        if ((cmd == 0x08 || cmd == 0x0A) && !_hasReceivedRecords) {
          // 流式推送可能先发空 ack 包，忽略首次 data_len=0。
          return;
        }
        if (_recordsFinalized) return;
        // data_len=0 表示批次边界，重置空闲计时器等待下一批。
        _scheduleFallbackTimer();
        return;
      }
      if (_recordsFinalized) return;
        var off = 4;
      while (off + 8 <= raw.length) {
        final ts = raw[off] |
            (raw[off + 1] << 8) |
            (raw[off + 2] << 16) |
            (raw[off + 3] << 24);
        var tempRaw = raw[off + 4] | (raw[off + 5] << 8);
        if (tempRaw >= 0x8000) tempRaw -= 0x10000;
        final temp = tempRaw / 100.0;
        final hum = raw[off + 6];
        _accumulatedRecords.add(
          RecordEntry(timestamp: ts, temperature: temp, humidity: hum),
        );
        _hasReceivedRecords = true;
        off += 8;
      }
      if (_expectedReadTotal > 0) {
        onReadProgress?.call(_accumulatedRecords.length, _expectedReadTotal);
      } else {
        onReadProgress?.call(_accumulatedRecords.length, 0);
      }
      _scheduleFallbackTimer();
      return;
    }

    if (cmd == 0x01 && raw.length >= 13) {
      // [0]=0x01 [1]=status [2-3]=data_len(BE) [4-7]=start_timestamp(LE)
      // [8-9]=record_count(BE) [10-11]=interval_seconds(BE) [12]=state
      final startTs = raw[4] | (raw[5] << 8) | (raw[6] << 16) | (raw[7] << 24);
      final recCount = (raw[8] << 8) | raw[9];
      final interval = (raw[10] << 8) | raw[11];
      final recording = raw[12] == 1;
      onDeviceInfo?.call(startTs, recCount, interval, recording);
      onCmdResult?.call(true, '设备信息已获取');
      return;
    }

    onCmdResult?.call(
      true,
      '命令 0x${cmd.toRadixString(16).padLeft(2, '0')} 成功',
    );
  }

  // ======== 写入 ========
  Future<bool> _write(
    String service,
    String char,
    Uint8List data, {
    bool withResponse = true,
  }) async {
    final c = _characteristic(service, char);
    final supportsNoRsp = c?.canWriteWithoutResponse ?? false;

    Future<bool> attempt(bool response) async {
      try {
        await transport.writeCharacteristic(
          deviceId,
          service,
          char,
          data,
          withResponse: response,
        );
        return true;
      } catch (_) {
        return false;
      }
    }

    var ok = await attempt(withResponse);
    if (!ok && withResponse && supportsNoRsp) {
      ok = await attempt(false);
    }
    return ok;
  }
}
