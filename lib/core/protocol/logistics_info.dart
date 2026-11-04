import 'dart:convert';
import 'dart:typed_data';

/// FFC5 物流信息（v3 布局，508B）。
///
/// 设备端结构 = 4B 版本头（"LG" + ver 0x02 + rsvd）+ 11 个定长字段槽。
/// 文本字段 UTF-8、不足补 0x00；长度为**字节数**，中文 3 字节/字符。
///
/// 为什么是 508B：蓝牙规范把特征值上限定为 512B，Android 的
/// GATT_MAX_ATTR_LEN 同为此值；保持 ≤512 才能一次长读收齐整块。
class LogisticsInfo {
  const LogisticsInfo({
    this.company = '',
    this.goodsNo = '',
    this.boxNo = '',
    this.goodsDesc = '',
    this.shipper = '',
    this.consignee = '',
    this.shipAddr = '',
    this.recvAddr = '',
    this.remark = '',
    this.quantity = 0.0,
    this.unit = '',
  });

  final String company;
  final String goodsNo;
  final String boxNo;
  final String goodsDesc;
  final String shipper;
  final String consignee;
  final String shipAddr;
  final String recvAddr;
  final String remark;
  final double quantity;
  final String unit;

  /// 是否含有实际内容，供导出判断要不要输出「物流信息」段。
  ///
  /// 不能用 `!= null` 判空：设备物流区为空时 FFC5 读回的是空白 v3 块，
  /// [decode] 会正确解出非 null 但字段全空的对象。
  bool get hasContent =>
      quantity != 0.0 ||
      [company, goodsNo, boxNo, goodsDesc, shipper, consignee, shipAddr,
        recvAddr, remark, unit]
          .any((s) => s.trim().isNotEmpty);

  static const int headerLen = 4;
  static const int totalLen = 508; // 必须 ≤ 512（GATT_MAX_ATTR_LEN）
  static const int headerMagic0 = 0x4C; // 'L'
  static const int headerMagic1 = 0x47; // 'G'
  static const int headerVer = 0x02;

  /// 字段描述：fid 对应固件 service_ffc0.c 的 s_log_fields[]，两表必须逐项一致。
  static const List<LogisticsField> fields = [
    LogisticsField(0x01, 4, 48, '公司名称'),
    LogisticsField(0x02, 52, 24, '货物单号'),
    LogisticsField(0x03, 76, 24, '货物箱号'),
    LogisticsField(0x04, 100, 64, '货物描述'),
    LogisticsField(0x05, 164, 20, '发货人'),
    LogisticsField(0x06, 184, 20, '收货人'),
    LogisticsField(0x07, 204, 128, '发货地址'),
    LogisticsField(0x08, 332, 128, '收货地址'),
    LogisticsField(0x09, 460, 32, '备注'),
    LogisticsField(0x0A, 492, 8, '数量'),
    LogisticsField(0x0B, 500, 8, '单位'),
  ];

  /// 取某 fid 的槽长，用于 UI 按字节限长；未知 fid 返回 0。
  static int slotSize(int fid) {
    for (final f in fields) {
      if (f.fid == fid) return f.size;
    }
    return 0;
  }

  static String _stringOf(LogisticsInfo info, int fid) => switch (fid) {
        0x01 => info.company,
        0x02 => info.goodsNo,
        0x03 => info.boxNo,
        0x04 => info.goodsDesc,
        0x05 => info.shipper,
        0x06 => info.consignee,
        0x07 => info.shipAddr,
        0x08 => info.recvAddr,
        0x09 => info.remark,
        0x0B => info.unit,
        _ => '',
      };

  /// 拼出完整 508B 块（含版本头），供测试与字段表校验使用。
  static Uint8List encode(LogisticsInfo info) {
    final buf = Uint8List(totalLen);
    buf[0] = headerMagic0;
    buf[1] = headerMagic1;
    buf[2] = headerVer;
    buf[3] = 0;
    final data = ByteData.sublistView(buf);
    for (final f in fields) {
      if (f.fid == 0x0A) {
        data.setFloat64(f.off, info.quantity, Endian.little);
      } else {
        _encodeString(buf, f.off, f.size, _stringOf(info, f.fid));
      }
    }
    return buf;
  }

  /// 拆成 11 个 GATT 写包，每包 = [fid 1B] + 补满槽长的内容，长度恰为 size+1。
  /// 固件要求长度**严格等于** size+1，否则回 GATT Error 0x13。
  static List<Uint8List> packetsFor(LogisticsInfo info) {
    final whole = encode(info);
    return fields.map((f) {
      final out = Uint8List(f.size + 1);
      out[0] = f.fid;
      out.setRange(1, f.size + 1, whole, f.off);
      return out;
    }).toList(growable: false);
  }

  /// 整块解码；版本头不符（旧 v2 固件 / 空扇区）返回 null。
  static LogisticsInfo? decode(Uint8List data) {
    if (data.length < totalLen) return null;
    if (data[0] != headerMagic0 ||
        data[1] != headerMagic1 ||
        data[2] != headerVer) {
      return null;
    }

    String s(int fid) {
      final f = fields.firstWhere((f) => f.fid == fid);
      return _decodeString(data, f.off, f.size);
    }

    final qf = fields.firstWhere((f) => f.fid == 0x0A);
    final qty = ByteData.sublistView(data).getFloat64(qf.off, Endian.little);

    return LogisticsInfo(
      company: s(0x01),
      goodsNo: s(0x02),
      boxNo: s(0x03),
      goodsDesc: s(0x04),
      shipper: s(0x05),
      consignee: s(0x06),
      shipAddr: s(0x07),
      recvAddr: s(0x08),
      remark: s(0x09),
      quantity: qty.isNaN ? 0.0 : qty,
      unit: s(0x0B),
    );
  }

  static void _encodeString(Uint8List buf, int offset, int maxLen, String s) {
    final budget = maxLen - 1; // 留 1B 给 NUL
    final bytes = truncateUtf8(s, budget);
    buf.setRange(offset, offset + bytes.length, bytes);
  }

  /// 按**字节预算**截断，且不切断多字节字符。
  static Uint8List truncateUtf8(String s, int budget) {
    final full = utf8.encode(s);
    if (full.length <= budget) return Uint8List.fromList(full);
    var end = budget;
    // 回退到不落在续接字节（10xxxxxx）上的位置。
    while (end > 0 && (full[end] & 0xC0) == 0x80) {
      end--;
    }
    return Uint8List.fromList(full.sublist(0, end));
  }

  static String _decodeString(Uint8List data, int offset, int maxLen) {
    var end = offset;
    while (end < offset + maxLen && data[end] != 0) {
      end++;
    }
    return utf8.decode(
      Uint8List.sublistView(data, offset, end),
      allowMalformed: true,
    );
  }

  LogisticsInfo copyWith({
    String? company,
    String? goodsNo,
    String? boxNo,
    String? goodsDesc,
    String? shipper,
    String? consignee,
    String? shipAddr,
    String? recvAddr,
    String? remark,
    double? quantity,
    String? unit,
  }) =>
      LogisticsInfo(
        company: company ?? this.company,
        goodsNo: goodsNo ?? this.goodsNo,
        boxNo: boxNo ?? this.boxNo,
        goodsDesc: goodsDesc ?? this.goodsDesc,
        shipper: shipper ?? this.shipper,
        consignee: consignee ?? this.consignee,
        shipAddr: shipAddr ?? this.shipAddr,
        recvAddr: recvAddr ?? this.recvAddr,
        remark: remark ?? this.remark,
        quantity: quantity ?? this.quantity,
        unit: unit ?? this.unit,
      );

  @override
  bool operator ==(Object other) =>
      other is LogisticsInfo &&
      other.company == company &&
      other.goodsNo == goodsNo &&
      other.boxNo == boxNo &&
      other.goodsDesc == goodsDesc &&
      other.shipper == shipper &&
      other.consignee == consignee &&
      other.shipAddr == shipAddr &&
      other.recvAddr == recvAddr &&
      other.remark == remark &&
      other.quantity == quantity &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(
        company,
        goodsNo,
        boxNo,
        goodsDesc,
        shipper,
        consignee,
        shipAddr,
        recvAddr,
        remark,
        quantity,
        unit,
      );
}

/// FFC5 字段槽描述。
class LogisticsField {
  const LogisticsField(this.fid, this.off, this.size, this.label);

  final int fid;
  final int off;
  final int size;
  final String label;
}
