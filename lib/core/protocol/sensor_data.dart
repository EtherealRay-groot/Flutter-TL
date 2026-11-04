import 'dart:convert';
import 'dart:typed_data';

import 'ibeacon_codec.dart';

/// 广播中的 TL 传感器数据（v2.0 的 0xFF 段 / v1.x 的 0x16 段）。
class SensorData {
  const SensorData({
    required this.voltage,
    required this.intervalCode,
    required this.txPowerLevel,
    required this.recordCount,
    required this.temperature,
    required this.humidity,
    this.recordInterval = 0,
  });

  /// 电池电压 (V)。
  final double voltage;

  /// 广播间隔编码 (0x01-0x10)。
  final int intervalCode;

  /// 发射功率 (dBm)。
  final int txPowerLevel;

  /// 已记录温湿度数据总条数。
  final int recordCount;

  /// 温度 (°C)。
  final double temperature;

  /// 相对湿度 (%)。
  final int humidity;

  /// 记录间隔（秒）。
  final int recordInterval;

  static const Map<int, int> _intervalMap = {
    0x01: 100,
    0x02: 200,
    0x03: 300,
    0x04: 400,
    0x05: 500,
    0x06: 600,
    0x07: 700,
    0x08: 800,
    0x09: 900,
    0x0A: 1000,
    0x0B: 1500,
    0x0C: 2000,
    0x0D: 2500,
    0x0E: 3000,
    0x0F: 5000,
    0x10: 10000,
  };

  static int intervalCodeToMs(int code) => _intervalMap[code] ?? (code * 100);
}

/// 一个 AD Structure（Advertising Data Structure）。
class AdStructure {
  const AdStructure({
    required this.length,
    required this.type,
    required this.value,
  });

  final int length;
  final int type;
  final Uint8List value;

  @override
  bool operator ==(Object other) =>
      other is AdStructure &&
      other.length == length &&
      other.type == type &&
      _listEquals(other.value, value);

  @override
  int get hashCode => Object.hash(length, type, Object.hashAll(value));
}

/// 把平台解析后的广播字段重新拼成 AD 结构字节。
///
/// universal_ble 的 `ManufacturerData.payload` **不含** Company ID，
/// `serviceData` 的 key 是规范化后的 128 位 UUID；而现有协议解析器
/// 都以原始 AD 字节为输入，因此这里按 BLE 编码规则还原：
/// - manufacturer: `[companyId LE][payload]`，AD type 0xFF
/// - service data: `[uuid16 LE][payload]`，AD type 0x16（仅 16 位基础 UUID）
/// - name: AD type 0x09
///
/// iOS 拿不到 Scan Response，因此名称可能缺失；能拿到的字段仍可正常解析。
class ScanRecordBuilder {
  ScanRecordBuilder._();

  static Uint8List build({
    Map<int, Uint8List> manufacturerData = const {},
    Map<String, Uint8List> serviceData = const {},
    String? name,
  }) {
    final out = BytesBuilder(copy: false);
    out.add([0x02, 0x01, 0x06]);

    if (name != null && name.isNotEmpty) {
      final nameBytes = utf8.encode(name);
      if (nameBytes.length + 1 <= 0xFF) {
        out.add([nameBytes.length + 1, 0x09, ...nameBytes]);
      }
    }

    manufacturerData.forEach((companyId, payload) {
      final value = [companyId & 0xFF, (companyId >> 8) & 0xFF, ...payload];
      if (value.length + 1 <= 0xFF) {
        out.add([value.length + 1, 0xFF, ...value]);
      }
    });

    serviceData.forEach((uuid, payload) {
      final short = _shortUuidBytes(uuid);
      if (short == null) return;
      final value = [...short, ...payload];
      if (value.length + 1 <= 0xFF) {
        out.add([value.length + 1, 0x16, ...value]);
      }
    });

    return out.toBytes();
  }

  /// 128 位基础 UUID → 16 位 UUID 的小端字节。非基础 UUID 返回 null。
  static List<int>? _shortUuidBytes(String uuid) {
    final u = uuid.replaceAll('-', '').toLowerCase();
    const suffix = '00001000800000805f9b34fb';
    if (u.length != 32 ||
        u.substring(0, 4) != '0000' ||
        u.substring(8) != suffix) {
      return null;
    }
    final value = int.parse(u.substring(4, 8), radix: 16);
    return [value & 0xFF, (value >> 8) & 0xFF];
  }
}

/// 广播包解析工具（纯 Dart）。
class SensorDataParser {
  SensorDataParser._();

  static int _u8(int v) => v & 0xFF;

  static int _s8(int v) => v > 127 ? v - 256 : v;

  static int _s16be(int hi, int lo) {
    final raw = ((hi & 0xFF) << 8) | (lo & 0xFF);
    return raw >= 0x8000 ? raw - 0x10000 : raw;
  }

  /// 手动解析广播包中的设备名称。
  /// 支持 AD Type 0x08 (Shortened Local Name) 和 0x09 (Complete Local Name)。
  static String? parseDeviceNameFromScanRecord(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    var i = 0;
    while (i < bytes.length) {
      final length = bytes[i];
      if (length == 0) break;
      if (i + length + 1 > bytes.length) break;
      final type = bytes[i + 1];
      if (type == 0x08 || type == 0x09) {
        final nameBytes =
            Uint8List.sublistView(bytes, i + 2, i + length + 1);
        final name =
            utf8.decode(nameBytes, allowMalformed: true).trim();
        return name.isEmpty ? null : name;
      }
      i += length + 1;
    }
    return null;
  }

  static List<AdStructure> parseAdStructures(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return const [];
    final result = <AdStructure>[];
    var i = 0;
    while (i < bytes.length) {
      final length = bytes[i];
      if (length == 0 || i + length + 1 > bytes.length) break;
      final type = bytes[i + 1];
      final value = Uint8List.sublistView(bytes, i + 2, i + length + 1);
      result.add(AdStructure(length: length, type: type, value: value));
      i += length + 1;
    }
    return result;
  }

  /// 检查广播包中是否存在 TL 设备数据（兼容 v1.x 和 v2.0）。
  static bool hasTLDeviceData(Uint8List? bytes) {
    final structures = parseAdStructures(bytes);
    for (final struct in structures) {
      if (struct.value.length < 2) continue;
      if (IBeaconCodec.isIBeaconValue(struct.value)) continue;
      final b0 = _u8(struct.value[0]);
      final b1 = _u8(struct.value[1]);
      if ((struct.type == 0xFF || struct.type == 0x16) &&
          b0 == 0x4C &&
          b1 == 0x4B) {
        return true;
      }
    }
    return false;
  }

  /// 解析 AD Type 0x01（Flags）的标志位描述。
  static String parseAdFlags(Uint8List? bytes) {
    if (bytes == null) return '';
    Uint8List? flags;
    for (final s in parseAdStructures(bytes)) {
      if (s.type == 0x01) {
        flags = s.value;
        break;
      }
    }
    if (flags == null || flags.isEmpty) return '';

    final flagByte = _u8(flags[0]);
    final parts = <String>[];
    if (flagByte & 0x01 != 0) parts.add('LimitedDiscoverable');
    if (flagByte & 0x02 != 0) parts.add('GeneralDiscoverable');
    if (flagByte & 0x04 != 0) parts.add('BrEdrNotSupported');
    if (flagByte & 0x08 != 0) parts.add('SimultaneousLeBrEdr');
    if (flagByte & 0x10 != 0) parts.add('SimultaneousLeBrEdrController');
    return parts.isEmpty ? '0x${flagByte.toRadixString(16).padLeft(2, '0').toUpperCase()}' : parts.join(', ');
  }

  static int intervalCodeToMs(int code) => SensorData.intervalCodeToMs(code);

  /// 解析 Manufacturer Specific Data 中的传感器数据。
  ///
  /// v2.0 格式（value 部分，不含 length/type 字节）：
  ///   0-1 Company ID (0x4C4B, LE=4C 4B)
  ///   2   广播间隔 (100ms 为单位, 1~16)
  ///   3   发射功率 (dBm, 有符号 int8)
  ///   4-5 记录间隔 (uint16 BE, 秒)
  ///   6-7 记录条数 (uint16 BE)
  ///   8-9 温度 (int16 BE, ×100)
  ///   10  湿度 (uint8)
  ///   11-12 电池电压 (uint16 BE, mV)
  static SensorData? parseSensorData(Uint8List? bytes) {
    final structures = parseAdStructures(bytes);

    for (final struct in structures) {
      if (struct.type != 0xFF || struct.value.length < 13) continue;
      if (IBeaconCodec.isIBeaconValue(struct.value)) continue;
      final d = struct.value;
      if (_u8(d[0]) != 0x4C || _u8(d[1]) != 0x4B) continue;

      final intervalCode = _u8(d[2]);
      final txPowerLevel = _s8(d[3]);
      final recordInterval = (_u8(d[4]) << 8) | _u8(d[5]);
      final recordCount = (_u8(d[6]) << 8) | _u8(d[7]);
      final temperature = _s16be(d[8], d[9]) / 100.0;
      final humidity = _u8(d[10]);
      final voltage = ((_u8(d[11]) << 8) | _u8(d[12])) / 1000.0;

      return SensorData(
        voltage: voltage,
        intervalCode: intervalCode,
        txPowerLevel: txPowerLevel,
        recordCount: recordCount,
        temperature: temperature,
        humidity: humidity,
        recordInterval: recordInterval,
      );
    }

    for (final struct in structures) {
      if (struct.type != 0x16 || struct.value.length < 17) continue;
      if (IBeaconCodec.isIBeaconValue(struct.value)) continue;
      final d = struct.value;
      if (_u8(d[0]) != 0x4C || _u8(d[1]) != 0x4B) continue;

      final voltage = ((_u8(d[2]) << 8) | _u8(d[3])) / 1000.0;
      final intervalCode = _u8(d[4]);
      final txPowerLevel = _s8(d[5]);
      final recordCount = (_u8(d[12]) << 8) | _u8(d[13]);

      // v1.x 温度整数字节以 bit7 为符号位、bits0-6 为幅值。
      final tempIntRaw = _u8(d[14]);
      final tempInt = tempIntRaw & 0x7F;
      final tempDec = _u8(d[15]);
      var temperature = tempInt + tempDec / 100.0;
      if (tempIntRaw & 0x80 != 0) temperature = -temperature;
      final humidity = _u8(d[16]);

      return SensorData(
        voltage: voltage,
        intervalCode: intervalCode,
        txPowerLevel: txPowerLevel,
        recordCount: recordCount,
        temperature: temperature,
        humidity: humidity,
      );
    }
    return null;
  }
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
