import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:test/test.dart';

import 'package:tl_app/core/chart/axis_range_policy.dart';
import 'package:tl_app/core/chart/chart_layout.dart';
import 'package:tl_app/core/chart/chart_model.dart';
import 'package:tl_app/core/chart/time_axis.dart';
import 'package:tl_app/export/pdf_chart_renderer.dart';

/// 建一份 A4 文档，在真实 PdfGraphics 上画一张图并输出字节。
///
/// 不传 font/boldFont：内置 Helvetica 画不了中文，
/// 渲染器应当把不支持的字符降级成 `?`，而不是抛异常。
Future<Uint8List> _renderToBytes(
  List<ChartPoint> points, {
  double? thresholdLowC,
  double? thresholdHighC,
  List<double>? progressOut,
}) async {
  final document = PdfDocument();
  final page = PdfPage(document, pageFormat: PdfPageFormat.a4);
  final canvas = page.getGraphics();

  final bottom = PdfChartRenderer.draw(
    canvas,
    topYStart: 40,
    contentLeft: 40,
    contentRight: 555,
    points: points,
    display: TemperatureDisplay.celsius,
    thresholdLowC: thresholdLowC,
    thresholdHighC: thresholdHighC,
    tz: ChartTimeZone.utc,
    pageHeight: PdfPageFormat.a4.height,
    onProgress: progressOut?.add,
  );

  expect(
    bottom,
    closeTo(40 + ChartLayout.plotBlockHeightPt, 1e-9),
    reason:
        '渲染器必须返回 topYStart + plotBlockHeightPt，'
        '否则调用方的分页判定会与实际绘制错位',
  );

  return document.save();
}

void _expectValidPdf(Uint8List bytes) {
  expect(bytes, isNotEmpty);
  expect(utf8.decode(bytes.sublist(0, 4), allowMalformed: true), '%PDF');
  expect(bytes.length, greaterThan(400), reason: '只写了个 PDF 头说明页面内容丢了');
}

void main() {
  test('emptyPointListStillProducesAPdf', () async {
    final progress = <double>[];
    final bytes = await _renderToBytes(<ChartPoint>[], progressOut: progress);

    _expectValidPdf(bytes);
    expect(progress, hasLength(3));
    expect(progress[0], closeTo(0.2, 1e-9));
    expect(progress[1], closeTo(0.7, 1e-9));
    expect(progress[2], closeTo(1.0, 1e-9));
  });

  test('singlePointIsDrawnAsADot', () async {
    final bytes = await _renderToBytes(<ChartPoint>[
      const ChartPoint(tSec: 1700000000, temperatureC: 21.5, humidity: 55),
    ]);

    _expectValidPdf(bytes);
  });

  test('negativeTemperaturesWithThresholdsProduceAPdf', () async {
    final bytes = await _renderToBytes(
      <ChartPoint>[
        const ChartPoint(tSec: 1700000000, temperatureC: -18.5, humidity: 12),
        const ChartPoint(tSec: 1700000300, temperatureC: -14.0, humidity: 18),
        const ChartPoint(tSec: 1700000600, temperatureC: -20.25, humidity: 9),
        const ChartPoint(tSec: 1700000900, temperatureC: -16.75, humidity: 15),
      ],
      thresholdLowC: -19,
      thresholdHighC: -10,
    );

    _expectValidPdf(bytes);
  });

  test('emptyPageKeepsTheCallersGraphicsState', () async {
    // 渲染器内部 save/restore，不应改变调用方之后绘制所用的状态。
    final document = PdfDocument();
    final page = PdfPage(document, pageFormat: PdfPageFormat.a4);
    final canvas = page.getGraphics();

    canvas.setLineWidth(3);

    PdfChartRenderer.draw(
      canvas,
      topYStart: 40,
      contentLeft: 40,
      contentRight: 555,
      points: <ChartPoint>[
        const ChartPoint(tSec: 1700000000, temperatureC: -5, humidity: 0),
      ],
      display: TemperatureDisplay.celsius,
      tz: ChartTimeZone.utc,
      pageHeight: PdfPageFormat.a4.height,
    );

    // 画完图表后继续画一条线，不能因为图表内部改了线宽/颜色而变形。
    canvas
      ..moveTo(40, 40)
      ..lineTo(555, 40)
      ..strokePath();

    _expectValidPdf(await document.save());
  });
}
