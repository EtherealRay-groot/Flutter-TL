import 'package:test/test.dart';
import 'package:tl_app/core/protocol/ibeacon_codec.dart';

/// 设备名称（FFC2）校验与默认名生成的单测。
///
/// 保护固件侧两条硬约束：
///  - 名称 ≤8 **字节**（app_adv_set_device_name 的 len > 8 截断）；
///  - 名称不得为空（FFC2 对空串既不写也不回 ack）。
void main() {
  test('max bytes matches firmware truncation', () {
    expect(IBeaconCodec.deviceNameMaxBytes, 8);
  });

  group('valid input', () {
    test('full 8 ascii bytes accepted', () {
      expect(IBeaconCodec.normalizeDeviceName('TL8BEEB2'), 'TL8BEEB2');
    });

    test('name starting with TL is accepted', () {
      expect(IBeaconCodec.normalizeDeviceName('TLTEST'), 'TLTEST');
      expect(IBeaconCodec.normalizeDeviceName('TL'), 'TL');
    });

    test('short name accepted', () {
      expect(IBeaconCodec.normalizeDeviceName('ABC'), 'ABC');
      expect(IBeaconCodec.normalizeDeviceName('A'), 'A');
    });

    test('surrounding whitespace trimmed', () {
      expect(IBeaconCodec.normalizeDeviceName('  ABC  '), 'ABC');
      expect(IBeaconCodec.normalizeDeviceName('\tABC\n'), 'ABC');
    });

    test('two chinese chars fit in 6 bytes', () {
      expect(IBeaconCodec.normalizeDeviceName('温湿'), '温湿');
    });

    test('whitespace does not count toward the byte budget', () {
      expect(IBeaconCodec.normalizeDeviceName('  ABCDEFGH  '), 'ABCDEFGH');
    });
  });

  group('invalid input', () {
    test('nine ascii chars rejected', () {
      expect(IBeaconCodec.normalizeDeviceName('ABCDEFGHI'), isNull);
    });

    test('eight chinese chars rejected despite short char count', () {
      expect(IBeaconCodec.normalizeDeviceName('温湿度记录仪名称'), isNull);
    });

    test('three chinese chars rejected at nine bytes', () {
      expect(IBeaconCodec.normalizeDeviceName('温湿度'), isNull);
    });

    test('empty and blank rejected', () {
      expect(IBeaconCodec.normalizeDeviceName(''), isNull);
      expect(IBeaconCodec.normalizeDeviceName('   '), isNull);
      expect(IBeaconCodec.normalizeDeviceName('\t\n'), isNull);
    });
  });

  group('default name', () {
    test('default name from mac address', () {
      expect(IBeaconCodec.defaultDeviceName('F1:11:42:8B:EE:B2'), 'TL8BEEB2');
      expect(IBeaconCodec.defaultDeviceName('F0:C8:90:02:10:9B'), 'TL02109B');
    });

    test('case insensitive input, uppercase output', () {
      expect(IBeaconCodec.defaultDeviceName('f1:11:42:8b:ee:b2'), 'TL8BEEB2');
    });

    test('accepts address without separators', () {
      expect(IBeaconCodec.defaultDeviceName('F111428BEEB2'), 'TL8BEEB2');
    });

    test('rejects short or null address', () {
      expect(IBeaconCodec.defaultDeviceName(null), isNull);
      expect(IBeaconCodec.defaultDeviceName(''), isNull);
      expect(IBeaconCodec.defaultDeviceName('AB:CD'), isNull);
    });

    test('default name itself passes validation', () {
      final def = IBeaconCodec.defaultDeviceName('F1:11:42:8B:EE:B2')!;
      expect(IBeaconCodec.normalizeDeviceName(def), def);
    });
  });
}
