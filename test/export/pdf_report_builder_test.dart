import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:test/test.dart';

import 'package:tl_app/core/protocol/logistics_info.dart';
import 'package:tl_app/core/protocol/record_entry.dart';
import 'package:tl_app/export/pdf_report_builder.dart';
import 'package:tl_app/state/app_state.dart';

/// 报告里用的长中文地址，足以触发按字符折行。
const String _longAddress =
    '广东省深圳市南山区科技园南区高新南一道飞亚达科技大厦西座十八楼1801室'
    '（靠近深大地铁站C出口，收货前请电话联系收货人确认具体楼层与卸货通道）';

PdfFont? _font;

/// 用测试字体文件构造一个 [PdfFont]。
///
/// 等价于 `pw.Font.ttf(...).buildFont(...)`，但后者是 protected API。
/// 来源文档与报告内部文档不同也没关系：构造器会按字节把字体重建到
/// 报告自己的 `PdfDocument` 上。
PdfFont _testFont() {
  final cached = _font;
  if (cached != null) {
    return cached;
  }
  final data = File('assets/fonts/NotoSansSC-VF.ttf').readAsBytesSync();
  final font = PdfTtfFont(
    PdfDocument(),
    ByteData.sublistView(Uint8List.fromList(data)),
  );
  _font = font;
  return font;
}

const LogisticsInfo _logistics = LogisticsInfo(
  company: '深圳市飞亚达科技发展有限公司',
  goodsNo: 'GOODS-2026-0001',
  boxNo: 'BOX-07',
  goodsDesc: '冷链药品',
  shipper: '张三',
  consignee: '李四',
  shipAddr: _longAddress,
  recvAddr: _longAddress,
  remark: '温度敏感货物，请勿倒置',
  quantity: 12,
  unit: '箱',
);

List<RecordEntry> _threeRecords() => const <RecordEntry>[
      RecordEntry(timestamp: 1700000000, temperature: 25.5, humidity: 55),
      RecordEntry(timestamp: 1700000060, temperature: 35.2, humidity: 61),
      RecordEntry(timestamp: 1700000120, temperature: 18.0, humidity: 48),
    ];

Future<Uint8List> _build({
  List<RecordEntry>? records,
  TemperatureUnit unit = TemperatureUnit.celsius,
  double? thresholdLowC = 2,
  double? thresholdHighC = 30,
  LogisticsInfo? logistics = _logistics,
  int? filterStartTime,
  int? filterEndTime,
  void Function(double progress)? onProgress,
}) {
  return PdfReportBuilder.build(
    records: records ?? _threeRecords(),
    deviceName: 'TL-Test',
    deviceAddress: 'AA:BB:CC:DD:EE:FF',
    unit: unit,
    thresholdLowC: thresholdLowC,
    thresholdHighC: thresholdHighC,
    logistics: logistics,
    filterStartTime: filterStartTime,
    filterEndTime: filterEndTime,
    font: _testFont(),
    boldFont: _testFont(),
    onProgress: onProgress,
  );
}

void _expectValidPdf(Uint8List bytes) {
  expect(bytes, isNotEmpty);
  expect(
    utf8.decode(bytes.sublist(0, 4), allowMalformed: true),
    '%PDF',
    reason: 'PDF 必须以 %PDF 魔数开头',
  );
  expect(
    bytes.length,
    greaterThan(1000),
    reason: '大于 1KB 说明页面内容不是空的',
  );
}

void main() {
  test('builds a Celsius report with thresholds and logistics', () async {
    final bytes = await _build();
    _expectValidPdf(bytes);
  });

  test('builds a Fahrenheit report', () async {
    final bytes = await _build(unit: TemperatureUnit.fahrenheit);
    _expectValidPdf(bytes);
  });

  test('handles a long logistics address with wrapping', () async {
    // 地址换行后物流块会变高，仍必须完整落在页面内并正常分页。
    final bytes = await _build(
      records: List<RecordEntry>.generate(
        60,
        (i) => RecordEntry(
          timestamp: 1700000000 + i * 60,
          temperature: 20 + (i % 15),
          humidity: 40 + (i % 40),
        ),
      ),
    );
    _expectValidPdf(bytes);
  });

  test('paginates a 100-record table', () async {
    final records = List<RecordEntry>.generate(
      100,
      (i) => RecordEntry(
        timestamp: 1700000000 + i * 60,
        temperature: 15 + (i % 25),
        humidity: 30 + (i % 60),
      ),
    );

    final progress = <double>[];
    final bytes = await _build(records: records, onProgress: progress.add);

    _expectValidPdf(bytes);
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
    for (var i = 1; i < progress.length; i++) {
      expect(
        progress[i],
        greaterThanOrEqualTo(progress[i - 1]),
        reason: '进度条不能往回跳',
      );
    }
    for (final p in progress) {
      expect(p, inInclusiveRange(0.0, 1.0));
    }
  });

  test('applies the time filter before building', () async {
    final bytes = await _build(
      filterStartTime: 1700000000,
      filterEndTime: 1700000060,
    );
    _expectValidPdf(bytes);
  });

  test('throws ArgumentError when there are no records', () async {
    await expectLater(
      _build(records: const <RecordEntry>[]),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('throws ArgumentError when the filter removes every record', () async {
    await expectLater(
      _build(filterStartTime: 1800000000),
      throwsA(isA<ArgumentError>()),
    );
  });
}
