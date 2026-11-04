import 'dart:convert';
import 'dart:typed_data';

/// iBeacon 广播帧解析 / 编解码 / 校验工具（纯 Dart，无 Flutter 依赖）。
///
/// 固件广播里同时存在两段 Manufacturer Specific AD：
///  - 0x4C4B：TL 传感器数据段（由 sensor_data 解析）
///  - 0x4C00：Apple iBeacon 段（本类处理）——value =
///    4C 00 02 15 + 16B UUID + 2B Major(BE) + 2B Minor(BE) + 1B RSSI@1m(有符号)
///
/// 默认值与固件 main/app_adv.c 的 V2_DEFAULT 保持一致。
class IBeaconCodec {
  IBeaconCodec._();

  /// 固件默认 Proximity UUID（32 hex 小写，发送序）。
  static const String defaultUuidHex = 'fda50693a4e24fb1afcfc6eb07647825';
  static const int defaultMajor = 10;
  static const int defaultMinor = 2;
  static const int defaultCompany = 0x004C;
  static const int defaultRssi1m = -61;

  /// 设备名上限，单位是**字节**（固件 s_device_name[9] / len > 8 截断）。
  static const int deviceNameMaxBytes = 8;

  static IBeaconConfig defaultConfig() => const IBeaconConfig(
        uuidHex: defaultUuidHex,
        major: defaultMajor,
        minor: defaultMinor,
        companyId: defaultCompany,
        rssi1m: defaultRssi1m,
      );

  /// 从 scanRecord.bytes 解析 iBeacon 段。找不到返回 null。
  ///
  /// 识别依据是 iBeacon 的**子类型魔数** value[2..3] == 02 15，**不是** Company ID——
  /// Company ID 是用户可改字段（FFA5），改成 0x4B4C 后字节会命中 TL 传感器段前缀。
  static IBeaconConfig? parseConfig(Uint8List? scanRecordBytes) {
    if (scanRecordBytes == null) return null;
    var i = 0;
    while (i < scanRecordBytes.length) {
      final length = scanRecordBytes[i];
      if (length == 0 || i + length + 1 > scanRecordBytes.length) break;
      if (i + 1 >= scanRecordBytes.length) break;
      final type = scanRecordBytes[i + 1];
      final value = Uint8List.sublistView(
        scanRecordBytes,
        i + 2,
        i + length + 1,
      );
      if (type == 0xFF &&
          value.length >= 25 &&
          value[2] == 0x02 &&
          value[3] == 0x15) {
        final uuidSb = StringBuffer();
        for (var j = 4; j < 20; j++) {
          uuidSb.write(value[j].toRadixString(16).padLeft(2, '0'));
        }
        final major = (value[20] << 8) | value[21];
        final minor = (value[22] << 8) | value[23];
        final company = value[0] | (value[1] << 8);
        return IBeaconConfig(
          uuidHex: uuidSb.toString(),
          major: major,
          minor: minor,
          companyId: company,
          rssi1m: value[24] > 127 ? value[24] - 256 : value[24],
        );
      }
      i += length + 1;
    }
    return null;
  }

  /// 判断一个 Manufacturer Specific AD 的 value 是否为 iBeacon 段。
  static bool isIBeaconValue(Uint8List value) =>
      value.length >= 4 && value[2] == 0x02 && value[3] == 0x15;

  /// 归一化 UUID 输入：去连字符/空格 → 需恰好 32 hex → 小写；否则 null。
  static String? normalizeUuidHex(String raw) {
    final cleaned = raw.replaceAll('-', '').replaceAll(' ', '');
    if (cleaned.length != 32) return null;
    for (var i = 0; i < cleaned.length; i++) {
      final c = cleaned.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39;
      final isLowerHex = c >= 0x61 && c <= 0x66;
      final isUpperHex = c >= 0x41 && c <= 0x46;
      if (!isDigit && !isLowerHex && !isUpperHex) return null;
    }
    return cleaned.toLowerCase();
  }

  /// 展示格式：XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX（大写）。
  /// 非 32 hex 原样返回，不抛异常。
  static String formatUuidHex(String hex32) {
    if (hex32.length != 32) return hex32;
    final h = hex32.toUpperCase();
    const starts = [0, 8, 12, 16, 20];
    const lengths = [8, 4, 4, 4, 12];
    return List.generate(
      starts.length,
      (i) => h.substring(starts[i], starts[i] + lengths[i]),
    ).join('-');
  }

  /// 解析 0..65535 十进制。
  static int? parseU16(String raw) {
    final v = int.tryParse(raw.trim());
    return (v != null && v >= 0 && v <= 65535) ? v : null;
  }

  /// 解析 -128..127 十进制（有符号）。
  static int? parseSigned8(String raw) {
    final v = int.tryParse(raw.trim());
    return (v != null && v >= -128 && v <= 127) ? v : null;
  }

  /// 解析 Company ID：有 "0x" 前缀按 hex；无前缀按 hex（厂商码惯例），
  /// 含非 hex 字符时退回十进制。越界或非法返回 null。
  static int? parseCompany(String raw) {
    final t = raw.trim();
    int? v;
    if (t.toLowerCase().startsWith('0x')) {
      v = int.tryParse(t.substring(2), radix: 16);
    } else {
      v = int.tryParse(t, radix: 16) ?? int.tryParse(t);
    }
    return (v != null && v >= 0 && v <= 65535) ? v : null;
  }

  /// 展示为 0x%04X（大写 hex）。
  static String companyToHex(int v) =>
      '0x${v.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  /// 校验并归一设备名。
  ///
  /// - 去首尾空白后不得为空（固件 FFC2 对空串既不写也不回 ack）。
  /// - UTF-8 编码后**字节数** ≤ [deviceNameMaxBytes]（中文 3 字节/字）。
  ///
  /// 返回去掉首尾空白后的名称；不合法返回 null。
  static String? normalizeDeviceName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return null;
    if (utf8.encode(name).length > deviceNameMaxBytes) return null;
    return name;
  }

  /// 出厂默认名称：`TL` + MAC 后 3 字节（大写 hex）。
  ///
  /// 地址为空或长度不足时返回 null。
  static String? defaultDeviceName(String? address) {
    final hex = address?.replaceAll(':', '').trim();
    if (hex == null || hex.length < 6) return null;
    return 'TL${hex.substring(hex.length - 6).toUpperCase()}';
  }

  /// 32 hex（小写）→ 16B 原序。
  static Uint8List uuidHexToBytes(String hex32) {
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(hex32.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// 2B 大端（Major/Minor）。
  static Uint8List u16BE(int v) =>
      Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF]);

  /// 2B 小端（Company ID，与 BE 相反）。
  static Uint8List u16LE(int v) =>
      Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);
}

/// iBeacon 广播参数。
class IBeaconConfig {
  const IBeaconConfig({
    required this.uuidHex,
    required this.major,
    required this.minor,
    required this.companyId,
    required this.rssi1m,
  });

  /// 32 hex 小写。
  final String uuidHex;
  final int major;
  final int minor;

  /// native int（如 0x004C = 76），上播 LE。
  final int companyId;

  /// 有符号 dBm。
  final int rssi1m;

  @override
  bool operator ==(Object other) =>
      other is IBeaconConfig &&
      other.uuidHex == uuidHex &&
      other.major == major &&
      other.minor == minor &&
      other.companyId == companyId &&
      other.rssi1m == rssi1m;

  @override
  int get hashCode => Object.hash(uuidHex, major, minor, companyId, rssi1m);
}

/// 单个 iBeacon 字段的写结果（suffix 见 PARAM_ACK_SUFFIXES）。
class BeaconFieldResult {
  const BeaconFieldResult({
    required this.suffix,
    required this.title,
    required this.ok,
    required this.detail,
  });

  final String suffix;
  final String title;
  final bool ok;
  final String detail;
}
