import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tl_app/core/protocol/ibeacon_codec.dart';

/// 构造一个 iBeacon AD structure：
/// len 0x1A + type 0xFF + CompanyID + 02 15 + UUID + Major + Minor + RSSI
Uint8List iBeaconAd({
  String uuidHex = 'fda50693a4e24fb1afcfc6eb07647825',
  int major = 10,
  int minor = 2,
  int rssi = -61,
  int companyId = 0x004C,
}) {
  final v = <int>[
    ...IBeaconCodec.u16LE(companyId),
    0x02,
    0x15,
    ...IBeaconCodec.uuidHexToBytes(uuidHex),
    ...IBeaconCodec.u16BE(major),
    ...IBeaconCodec.u16BE(minor),
    rssi & 0xFF,
  ];
  return Uint8List.fromList([v.length + 1, 0xFF, ...v]);
}

/// TL 传感器厂商段（0x4C4B），不应被识别为 iBeacon。
Uint8List tlVendorAd() {
  const v = [0x4C, 0x4B, 0x01, 0x00, 0x01, 0x00, 0x0A, 0x00, 0x02, 0x0B, 0xB8, 0x64, 0x32];
  return Uint8List.fromList([v.length + 1, 0xFF, ...v]);
}

void main() {
  group('parseConfig', () {
    test('reads all fields', () {
      final cfg = IBeaconCodec.parseConfig(iBeaconAd());
      expect(cfg, isNotNull);
      expect(cfg!.uuidHex, 'fda50693a4e24fb1afcfc6eb07647825');
      expect(cfg.major, 10);
      expect(cfg.minor, 2);
      expect(cfg.companyId, 0x004C);
      expect(cfg.rssi1m, -61);
    });

    test('handles negative rssi', () {
      final cfg = IBeaconCodec.parseConfig(iBeaconAd(rssi: -90));
      expect(cfg!.rssi1m, -90);
    });

    test('ignores TL vendor section', () {
      expect(IBeaconCodec.parseConfig(tlVendorAd()), isNull);
    });

    test('matches regardless of company id', () {
      final cfg = IBeaconCodec.parseConfig(iBeaconAd(companyId: 0x4B4C));
      expect(cfg, isNotNull);
      expect(cfg!.companyId, 0x4B4C);
      expect(cfg.major, 10);

      final cfg2 = IBeaconCodec.parseConfig(iBeaconAd(companyId: 0x1234));
      expect(cfg2!.companyId, 0x1234);
    });

    test('null and short return null', () {
      expect(IBeaconCodec.parseConfig(null), isNull);
      expect(IBeaconCodec.parseConfig(Uint8List(0)), isNull);
      expect(
        IBeaconCodec.parseConfig(
          Uint8List.fromList([0x05, 0xFF, 0x4C, 0x00, 0x02, 0x15]),
        ),
        isNull,
      );
    });

    test('skips leading ad structures', () {
      final flags = Uint8List.fromList([0x02, 0x01, 0x06]);
      final cfg = IBeaconCodec.parseConfig(
        Uint8List.fromList([...flags, ...iBeaconAd()]),
      );
      expect(cfg, isNotNull);
      expect(cfg!.major, 10);
    });
  });

  group('isIBeaconValue', () {
    test('distinguishes TL vendor section', () {
      expect(IBeaconCodec.isIBeaconValue(Uint8List.fromList([0x4C, 0x00, 0x02, 0x15])), isTrue);
      expect(IBeaconCodec.isIBeaconValue(Uint8List.fromList([0x4C, 0x4B, 0x02, 0x15])), isTrue);
      expect(IBeaconCodec.isIBeaconValue(Uint8List.fromList([0x4C, 0x4B, 0x01, 0x00, 0x01])), isFalse);
      expect(IBeaconCodec.isIBeaconValue(Uint8List.fromList([0x4C, 0x4B])), isFalse);
    });
  });

  group('byte encoding', () {
    test('u16BE is big endian', () {
      expect(IBeaconCodec.u16BE(0x1234), [0x12, 0x34]);
      expect(IBeaconCodec.u16BE(10), [0x00, 0x0A]);
    });

    test('u16LE is little endian', () {
      expect(IBeaconCodec.u16LE(0x004C), [0x4C, 0x00]);
      expect(IBeaconCodec.u16LE(0x1234), [0x34, 0x12]);
    });

    test('uuidHexToBytes preserves order', () {
      final b = IBeaconCodec.uuidHexToBytes('fda50693a4e24fb1afcfc6eb07647825');
      expect(b.length, 16);
      expect(b[0], 0xFD);
      expect(b[1], 0xA5);
      expect(b[15], 0x25);
    });
  });

  group('normalizeUuidHex', () {
    test('accepts formats', () {
      expect(
        IBeaconCodec.normalizeUuidHex('FDA50693-A4E2-4FB1-AFCF-C6EB07647825'),
        'fda50693a4e24fb1afcfc6eb07647825',
      );
      expect(
        IBeaconCodec.normalizeUuidHex('fda50693 a4e24fb1 afcfc6eb07647825'),
        'fda50693a4e24fb1afcfc6eb07647825',
      );
    });

    test('rejects bad input', () {
      expect(IBeaconCodec.normalizeUuidHex('fda50693'), isNull);
      expect(IBeaconCodec.normalizeUuidHex('zda50693a4e24fb1afcfc6eb07647825'), isNull);
      expect(IBeaconCodec.normalizeUuidHex(''), isNull);
    });
  });

  test('formatUuidHex inserts hyphens and uppercases', () {
    expect(
      IBeaconCodec.formatUuidHex('fda50693a4e24fb1afcfc6eb07647825'),
      'FDA50693-A4E2-4FB1-AFCF-C6EB07647825',
    );
  });

  test('parseU16 range checks', () {
    expect(IBeaconCodec.parseU16('0'), 0);
    expect(IBeaconCodec.parseU16('65535'), 65535);
    expect(IBeaconCodec.parseU16('65536'), isNull);
    expect(IBeaconCodec.parseU16('-1'), isNull);
    expect(IBeaconCodec.parseU16('abc'), isNull);
  });

  test('parseSigned8 range checks', () {
    expect(IBeaconCodec.parseSigned8('-128'), -128);
    expect(IBeaconCodec.parseSigned8('127'), 127);
    expect(IBeaconCodec.parseSigned8('-61'), -61);
    expect(IBeaconCodec.parseSigned8('128'), isNull);
    expect(IBeaconCodec.parseSigned8('-129'), isNull);
  });

  test('parseCompany prefers hex when unprefixed', () {
    expect(IBeaconCodec.parseCompany('0x004C'), 0x004C);
    expect(IBeaconCodec.parseCompany('4c'), 0x004C);
    expect(IBeaconCodec.parseCompany('76'), 0x0076);
    expect(IBeaconCodec.parseCompany('0x10000'), isNull);
    expect(IBeaconCodec.parseCompany(''), isNull);
    expect(IBeaconCodec.parseCompany('-1'), isNull);
  });

  test('companyToHex formats', () {
    expect(IBeaconCodec.companyToHex(0x004C), '0x004C');
    expect(IBeaconCodec.companyToHex(65535), '0xFFFF');
  });

  test('defaultConfig matches firmware', () {
    final d = IBeaconCodec.defaultConfig();
    expect(d.uuidHex, 'fda50693a4e24fb1afcfc6eb07647825');
    expect(d.major, 10);
    expect(d.minor, 2);
    expect(d.companyId, 0x004C);
    expect(d.rssi1m, -61);
  });
}
