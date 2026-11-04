import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tl_app/core/protocol/ibeacon_codec.dart';
import 'package:tl_app/core/protocol/sensor_data.dart';

void main() {
  test('parseSensorData decodes negative v2 temperature', () {
    final scanRecord = Uint8List.fromList([
      0x02, 0x01, 0x06,
      0x0E, 0xFF, 0x4C, 0x4B,
      0x01, 0x00, 0x00, 0x78,
      0x00, 0x00,
      0xFD, 0xF3, // -5.25 C x100, signed big-endian
      0x32,
      0x0B, 0xB8,
    ]);

    final sensorData = SensorDataParser.parseSensorData(scanRecord);

    expect(sensorData, isNotNull);
    expect(sensorData!.temperature, closeTo(-5.25, 0.001));
  });

  test('parseSensorData decodes negative v1 temperature', () {
    final scanRecord = Uint8List.fromList([
      0x12, 0x16,
      0x4C, 0x4B,
      0x0B, 0xB8,
      0x0A, 0x00,
      0xF0, 0xC8, 0x1A, 0x2B, 0x3C, 0x4D,
      0x00, 0x00,
      0x85, 0x19, // sign bit + 5.25 C magnitude
      0x32,
    ]);

    final sensorData = SensorDataParser.parseSensorData(scanRecord);

    expect(sensorData, isNotNull);
    expect(sensorData!.temperature, closeTo(-5.25, 0.001));
  });

  test('parseSensorData decodes sub-zero v1 temperature with zero integer part',
      () {
    final scanRecord = Uint8List.fromList([
      0x12, 0x16,
      0x4C, 0x4B,
      0x0B, 0xB8,
      0x0A, 0x00,
      0xF0, 0xC8, 0x1A, 0x2B, 0x3C, 0x4D,
      0x00, 0x00,
      0x80, 0x19, // sign bit + 0.25 C magnitude
      0x32,
    ]);

    final sensorData = SensorDataParser.parseSensorData(scanRecord);

    expect(sensorData, isNotNull);
    expect(sensorData!.temperature, closeTo(-0.25, 0.001));
  });

  test('parseSensorData keeps positive v1 temperature compatible', () {
    final scanRecord = Uint8List.fromList([
      0x12, 0x16,
      0x4C, 0x4B,
      0x0B, 0xB8,
      0x0A, 0x00,
      0xF0, 0xC8, 0x1A, 0x2B, 0x3C, 0x4D,
      0x00, 0x00,
      0x19, 0x32, // 25.50 C, high bit clear
      0x32,
    ]);

    final sensorData = SensorDataParser.parseSensorData(scanRecord);

    expect(sensorData, isNotNull);
    expect(sensorData!.temperature, closeTo(25.50, 0.001));
  });

  test('v2 fields decode', () {
    final scanRecord = Uint8List.fromList([
      0x0E, 0xFF, 0x4C, 0x4B,
      0x05, 0xFB, // interval code 5, tx power -5
      0x00, 0x3C, // record interval 60s
      0x00, 0x0A, // record count 10
      0x09, 0xC4, // 25.00 C
      0x32, // 50%
      0x0B, 0xB8, // 3.000V
    ]);
    final d = SensorDataParser.parseSensorData(scanRecord)!;
    expect(d.intervalCode, 5);
    expect(d.txPowerLevel, -5);
    expect(d.recordInterval, 60);
    expect(d.recordCount, 10);
    expect(d.temperature, closeTo(25.0, 0.001));
    expect(d.humidity, 50);
    expect(d.voltage, closeTo(3.0, 0.001));
  });

  test('iBeacon segment is not mistaken for sensor data', () {
    // 公司 ID 4C 4B + 02 15 魔数 → iBeacon，不是传感器段
    final scanRecord = Uint8List.fromList([
      0x1A, 0xFF, 0x4C, 0x4B, 0x02, 0x15,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0x00, 0x0A, 0x00, 0x02, 0xC3,
    ]);
    expect(SensorDataParser.parseSensorData(scanRecord), isNull);
    expect(SensorDataParser.hasTLDeviceData(scanRecord), isFalse);
  });

  test('parseDeviceNameFromScanRecord reads complete name', () {
    final scanRecord = Uint8List.fromList([
      0x02, 0x01, 0x06,
      0x09, 0x09, ...'TL8BEEB2'.codeUnits,
    ]);
    expect(SensorDataParser.parseDeviceNameFromScanRecord(scanRecord),
        'TL8BEEB2');
  });

  test('parseDeviceNameFromScanRecord returns null when absent', () {
    expect(SensorDataParser.parseDeviceNameFromScanRecord(null), isNull);
    expect(SensorDataParser.parseDeviceNameFromScanRecord(Uint8List(0)), isNull);
  });

  group('ScanRecordBuilder', () {
    test('rebuilds manufacturer data and name for v2 parsing', () {
      final record = ScanRecordBuilder.build(
        name: 'TL8BEEB2',
        manufacturerData: {
          // 广播字节 4C 4B（小端）→ universal_ble 解析出的 companyId 是 0x4B4C
          0x4B4C: Uint8List.fromList([
            0x05, 0xFB, // interval code 5, tx power -5
            0x00, 0x3C,
            0x00, 0x0A,
            0x09, 0xC4,
            0x32,
            0x0B, 0xB8,
          ]),
        },
      );

      expect(SensorDataParser.parseDeviceNameFromScanRecord(record),
          'TL8BEEB2');
      final d = SensorDataParser.parseSensorData(record)!;
      expect(d.intervalCode, 5);
      expect(d.txPowerLevel, -5);
      expect(d.recordCount, 10);
      expect(d.temperature, closeTo(25.0, 0.001));
      expect(SensorDataParser.hasTLDeviceData(record), isTrue);
    });

    test('rebuilds service data for v1 parsing', () {
      final record = ScanRecordBuilder.build(
        serviceData: {
          // UUID 0x4B4C → AD 字节 4C 4B，与原固件 v1.x 段一致
          '00004b4c-0000-1000-8000-00805f9b34fb': Uint8List.fromList([
            0x0B, 0xB8, // voltage
            0x0A, 0x00, // interval, tx
            0xF0, 0xC8, 0x1A, 0x2B, 0x3C, 0x4D,
            0x00, 0x00,
            0x19, 0x32, // 25.50 C
            0x32,
          ]),
        },
      );
      final d = SensorDataParser.parseSensorData(record)!;
      expect(d.temperature, closeTo(25.50, 0.001));
      expect(d.humidity, 50);
    });

    test('rebuilds iBeacon manufacturer section', () {
      final uuidBytes = [
        0xFD, 0xA5, 0x06, 0x93, 0xA4, 0xE2, 0x4F, 0xB1,
        0xAF, 0xCF, 0xC6, 0xEB, 0x07, 0x64, 0x78, 0x25,
      ];
      final record = ScanRecordBuilder.build(
        manufacturerData: {
          0x004C: Uint8List.fromList([
            0x02, 0x15,
            ...uuidBytes,
            0x00, 0x0A,
            0x00, 0x02,
            0xC3, // -61
          ]),
        },
      );
      final cfg = IBeaconCodec.parseConfig(record)!;
      expect(cfg.uuidHex, 'fda50693a4e24fb1afcfc6eb07647825');
      expect(cfg.major, 10);
      expect(cfg.minor, 2);
      expect(cfg.companyId, 0x004C);
      expect(cfg.rssi1m, -61);
    });
  });

  test('interval code mapping', () {
    expect(SensorData.intervalCodeToMs(0x01), 100);
    expect(SensorData.intervalCodeToMs(0x10), 10000);
    expect(SensorData.intervalCodeToMs(0x11), 1700); // fallback code*100
  });
}
