import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tl_app/core/protocol/logistics_info.dart';

LogisticsInfo sample() => const LogisticsInfo(
      company: '深圳某某物流有限公司',
      goodsNo: 'SF1234567890',
      boxNo: 'BX-001',
      goodsDesc: '精密仪器，轻拿轻放',
      shipper: '张三',
      consignee: '李四',
      shipAddr: '广东省深圳市南山区科技园南路 1 号 A 栋 302',
      recvAddr: '北京市海淀区中关村大街 27 号 B 座 1801',
      remark: '工作日送达',
      quantity: 12.5,
      unit: '箱',
    );

void main() {
  test('field table is contiguous and matches firmware layout', () {
    final f = LogisticsInfo.fields;
    expect(f.length, 11);
    expect(f.first.off, 4);

    var expectOff = 4;
    for (final field in f) {
      expect(field.off, expectOff, reason: '字段 ${field.label} 起点应接上一项末尾');
      expectOff = field.off + field.size;
    }
    expect(expectOff, LogisticsInfo.totalLen, reason: '末项末尾应等于总长');

    expect(f.map((x) => x.fid).toSet().length, f.length);

    expect(
      f.map((x) => (x.fid, x.off)).toList(),
      [
        (0x01, 4), (0x02, 52), (0x03, 76), (0x04, 100), (0x05, 164),
        (0x06, 184), (0x07, 204), (0x08, 332), (0x09, 460),
        (0x0A, 492), (0x0B, 500),
      ],
    );
    expect(f.map((x) => x.size).toList(),
        [48, 24, 24, 64, 20, 20, 128, 128, 32, 8, 8]);
  });

  test('total length stays within GATT attribute limit', () {
    expect(LogisticsInfo.totalLen <= 512, isTrue,
        reason: 'TOTAL_LEN=${LogisticsInfo.totalLen} 超出 512B');
  });

  test('header is LG plus version 2', () {
    final buf = LogisticsInfo.encode(sample());
    expect(buf[0], 0x4C);
    expect(buf[1], 0x47);
    expect(buf[2], 0x02);
    expect(buf[3], 0x00);
  });

  test('encode then decode round trips every field', () {
    final info = sample();
    final decoded = LogisticsInfo.decode(LogisticsInfo.encode(info));
    expect(decoded, isNotNull);
    expect(decoded, info);
  });

  test('empty info encodes as header plus zeros', () {
    final buf = LogisticsInfo.encode(const LogisticsInfo());
    expect(buf.length, LogisticsInfo.totalLen);
    expect(buf.sublist(0, 4), [0x4C, 0x47, 0x02, 0x00]);
    expect(buf.sublist(4).every((b) => b == 0), isTrue);
    expect(LogisticsInfo.decode(buf), isNotNull);
  });

  test('overlong utf8 text is truncated to slot minus one byte', () {
    final huge = '汉' * 300;
    final info = LogisticsInfo(
      company: huge,
      goodsNo: huge,
      boxNo: huge,
      goodsDesc: huge,
      shipper: huge,
      consignee: huge,
      shipAddr: huge,
      recvAddr: huge,
      remark: huge,
      unit: huge,
      quantity: 1.0,
    );
    final buf = LogisticsInfo.encode(info);
    expect(buf.length, LogisticsInfo.totalLen);

    final d = LogisticsInfo.decode(buf)!;
    for (final f in LogisticsInfo.fields) {
      if (f.fid == 0x0A) continue;
      final text = switch (f.fid) {
        0x01 => d.company,
        0x02 => d.goodsNo,
        0x03 => d.boxNo,
        0x04 => d.goodsDesc,
        0x05 => d.shipper,
        0x06 => d.consignee,
        0x07 => d.shipAddr,
        0x08 => d.recvAddr,
        0x09 => d.remark,
        _ => d.unit,
      };
      expect(
        Uint8List.fromList(text.codeUnits).length <= f.size - 1,
        isTrue,
        reason: '${f.label} 编码后应不超过 ${f.size - 1} 字节',
      );
    }
  });

  test('packetsFor emits one packet per field with exact slot length', () {
    final packets = LogisticsInfo.packetsFor(sample());
    expect(packets.length, LogisticsInfo.fields.length);

    for (var i = 0; i < LogisticsInfo.fields.length; i++) {
      final f = LogisticsInfo.fields[i];
      final p = packets[i];
      expect(p.length, f.size + 1, reason: '${f.label} 包长应为 ${f.size + 1}');
      expect(p[0], f.fid, reason: '${f.label} 首字节应为 fid');
    }
  });

  test('packetsFor sends empty fields as all zero rather than skipping', () {
    final packets =
        LogisticsInfo.packetsFor(const LogisticsInfo(company: '顺丰'));
    expect(packets.length, 11);

    final goodsNo = packets[1];
    expect(goodsNo[0], 0x02);
    expect(goodsNo.sublist(1).every((b) => b == 0), isTrue);
  });

  test('decode rejects blocks with wrong header', () {
    final good = LogisticsInfo.encode(sample());

    expect(
      LogisticsInfo.decode(Uint8List(LogisticsInfo.totalLen)..fillRange(0, LogisticsInfo.totalLen, 0xFF)),
      isNull,
    );

    final badMagic = Uint8List.fromList(good);
    badMagic[0] = 'X'.codeUnitAt(0);
    expect(LogisticsInfo.decode(badMagic), isNull);

    final badVer = Uint8List.fromList(good);
    badVer[2] = 0x01;
    expect(LogisticsInfo.decode(badVer), isNull);

    expect(
      LogisticsInfo.decode(
        Uint8List.sublistView(good, 0, LogisticsInfo.totalLen - 1),
      ),
      isNull,
    );
  });

  test('quantity survives as little endian double', () {
    const info = LogisticsInfo(quantity: 1234.5678);
    final buf = LogisticsInfo.encode(info);
    final off = LogisticsInfo.fields.firstWhere((f) => f.fid == 0x0A).off;
    final data = ByteData.sublistView(buf);
    expect(data.getFloat64(off, Endian.little), 1234.5678);
    expect(LogisticsInfo.decode(buf)!.quantity, 1234.5678);
  });

  test('empty info reports no content', () {
    expect(const LogisticsInfo().hasContent, isFalse);
  });

  test('blank device block reports no content', () {
    final decoded =
        LogisticsInfo.decode(LogisticsInfo.encode(const LogisticsInfo()));
    expect(decoded, isNotNull);
    expect(decoded!.hasContent, isFalse);
  });

  test('any single text field reports content', () {
    for (final f in LogisticsInfo.fields.where((f) => f.fid != 0x0A)) {
      final info = switch (f.fid) {
        0x01 => const LogisticsInfo(company: '顺丰'),
        0x02 => const LogisticsInfo(goodsNo: 'SF123'),
        0x03 => const LogisticsInfo(boxNo: 'BX-1'),
        0x04 => const LogisticsInfo(goodsDesc: '易碎'),
        0x05 => const LogisticsInfo(shipper: '张三'),
        0x06 => const LogisticsInfo(consignee: '李四'),
        0x07 => const LogisticsInfo(shipAddr: '深圳'),
        0x08 => const LogisticsInfo(recvAddr: '北京'),
        0x09 => const LogisticsInfo(remark: '勿压'),
        _ => const LogisticsInfo(unit: '箱'),
      };
      expect(info.hasContent, isTrue, reason: '${f.label} 有值时应判为有内容');
    }
  });

  test('quantity alone reports content but whitespace text does not', () {
    expect(const LogisticsInfo(quantity: 12.5).hasContent, isTrue);
    expect(const LogisticsInfo(quantity: 0.0).hasContent, isFalse);
    expect(
      const LogisticsInfo(company: '   ', remark: '\t').hasContent,
      isFalse,
    );
  });

  test('slotSize returns firmware slot sizes', () {
    expect(LogisticsInfo.slotSize(0x01), 48);
    expect(LogisticsInfo.slotSize(0x07), 128);
    expect(LogisticsInfo.slotSize(0x08), 128);
    expect(LogisticsInfo.slotSize(0x0A), 8);
    expect(LogisticsInfo.slotSize(0x99), 0);
  });
}
