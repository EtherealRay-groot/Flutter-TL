import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tl_app/ble/ble_transport.dart';
import 'package:tl_app/ble/device_connection.dart';
import 'package:tl_app/core/protocol/logistics_info.dart';
import 'package:tl_app/core/protocol/record_entry.dart';

import 'fake_ble_transport.dart';

Future<DeviceConnection> connectedDevice(FakeBleTransport t) async {
  final conn = DeviceConnection(deviceId: 'AA:BB:CC:DD:EE:FF', transport: t);
  await conn.connect();
  return conn;
}

void main() {
  test('connect discovers services, requests MTU and enables notifications',
      () async {
    final t = fullDevice();
    final conn = DeviceConnection(deviceId: 'dev', transport: t);
    var connected = false;
    conn.onConnected = (v) => connected = v;

    await conn.connect();

    expect(connected, isTrue);
    expect(conn.isConnected, isTrue);
    expect(conn.mtu, 247);
    // FFC4 与 FFD2 都应注册通知
    expect(
      () => t.emit(BleUuids.ffc0, BleUuids.ffc4, '24@C3'.codeUnits),
      returnsNormally,
    );
    expect(
      () => t.emit(BleUuids.ffd0, BleUuids.ffd2, [0x03, 0x00]),
      returnsNormally,
    );
  });

  test('FFC4 routes password and parameter acks by suffix', () async {
    final t = fullDevice();
    final conn = await connectedDevice(t);

    String? pwd;
    final paramResults = <String>[];
    conn.onPwdResult = (ok, err) => pwd = 'ok=$ok err=$err';
    conn.onParamResult = (ok, err, suffix) {
      paramResults.add('$suffix:$ok');
    };

    t.emit(BleUuids.ffc0, BleUuids.ffc4, '24@C3'.codeUnits);
    t.emit(BleUuids.ffc0, BleUuids.ffc4, '24@0A1'.codeUnits);
    t.emit(BleUuids.ffc0, BleUuids.ffc4, '24@0C2'.codeUnits);

    expect(pwd, 'ok=true err=null');
    expect(paramResults, ['A1:true', 'C2:true']);
  });

  test('FFC4 rejection reports error', () async {
    final t = fullDevice();
    final conn = await connectedDevice(t);

    String? error;
    conn.onPwdResult = (ok, err) => error = err;

    t.emit(BleUuids.ffc0, BleUuids.ffc4, 'NOC3'.codeUnits);

    expect(error, '设备拒绝: NOC3');
  });

  test('FFD2 parses little-endian records and finalizes after idle timeout',
      () async {
    final t = fullDevice();
    final conn = await connectedDevice(t);

    List<RecordEntry>? received;
    var progress = 0;
    conn.onRecordsResult = (records) => received = records;
    conn.onReadProgress = (current, total) => progress = current;

    // 0x08 成功，data_len=8，一条记录：ts=0x01020304 LE，-5.25C LE，hum=50，flag=0
    t.emit(BleUuids.ffd0, BleUuids.ffd2, [
      0x08, 0x00, 0x00, 0x08,
      0x04, 0x03, 0x02, 0x01,
      0xF3, 0xFD,
      0x32, 0x00,
    ]);

    expect(progress, 1);
    expect(received, isNull);

    await Future<void>.delayed(
      const Duration(milliseconds: DeviceConnection.batchIdleTimeoutMs + 120),
    );

    expect(received, isNotNull);
    expect(received!.length, 1);
    expect(received!.first.timestamp, 0x01020304);
    expect(received!.first.temperature, closeTo(-5.25, 0.001));
    expect(received!.first.humidity, 50);
  });

  test('first empty ack for streaming is ignored', () async {
    final t = fullDevice();
    final conn = await connectedDevice(t);
    var calls = 0;
    conn.onRecordsResult = (_) => calls++;

    // 0x08, ok, data_len=0 → 首次空包，忽略
    t.emit(BleUuids.ffd0, BleUuids.ffd2, [0x08, 0x00, 0x00, 0x00]);
    await Future<void>.delayed(
      const Duration(milliseconds: DeviceConnection.batchIdleTimeoutMs + 120),
    );

    expect(calls, 0);
  });

  test('GET_INFO response fills device info', () async {
    final t = fullDevice();
    final conn = await connectedDevice(t);

    int? startTs;
    int? count;
    int? interval;
    bool? recording;
    conn.onDeviceInfo = (s, c, i, r) {
      startTs = s;
      count = c;
      interval = i;
      recording = r;
    };

    // [0x01][status=0][data_len=0x000D][start LE=0x01020304]
    // [count BE=0x000A][interval BE=0x003C][state=1]
    t.emit(BleUuids.ffd0, BleUuids.ffd2, [
      0x01, 0x00, 0x00, 0x0D,
      0x04, 0x03, 0x02, 0x01,
      0x00, 0x0A,
      0x00, 0x3C,
      0x01,
    ]);

    expect(startTs, 0x01020304);
    expect(count, 10);
    expect(interval, 60);
    expect(recording, isTrue);
  });

  test('reads recording status and record interval', () async {
    final t = fullDevice();
    final conn = await connectedDevice(t);

    bool? status;
    conn.onRecordingStatus = (v) => status = v;
    t.readResponses['${BleUuids.shorten(BleUuids.ffd0)}/'
            '${BleUuids.shorten(BleUuids.ffd3)}'] =
        Uint8List.fromList([0x01]);
    await conn.readRecordingStatus();
    expect(status, isTrue);

    int? interval;
    conn.onRecordIntervalResult = (v) => interval = v;
    t.readResponses['${BleUuids.shorten(BleUuids.ffd0)}/'
            '${BleUuids.shorten(BleUuids.ffd4)}'] =
        Uint8List.fromList([0x00, 0x3C]);
    await conn.readRecordInterval();
    expect(interval, 60);
  });

  test('reads and decodes logistics info', () async {
    final t = fullDevice();
    final conn = await connectedDevice(t);

    LogisticsInfo? info;
    conn.onLogisticsRead = (v) => info = v;
    t.readResponses['${BleUuids.shorten(BleUuids.ffc0)}/'
            '${BleUuids.shorten(BleUuids.ffc5)}'] =
        LogisticsInfo.encode(const LogisticsInfo(company: '顺丰', quantity: 2));

    await conn.readLogisticsInfo();

    expect(info, isNotNull);
    expect(info!.company, '顺丰');
    expect(info!.quantity, 2);
  });

  test('writes all 11 logistics field packets', () async {
    final t = fullDevice();
    final conn = await connectedDevice(t);

    bool? written;
    conn.onLogisticsWritten = (v) => written = v;

    await conn.writeLogisticsInfo(const LogisticsInfo(company: '顺丰'));

    expect(written, isTrue);
    final ffc5Writes =
        t.writeLog.where((w) => w.startsWith('ffc0/ffc5:')).toList();
    expect(ffc5Writes.length, 11);
    expect(ffc5Writes.first.split(':').last, startsWith('01'));
  });
}
