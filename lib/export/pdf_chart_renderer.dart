import 'dart:math' as math;

import 'package:pdf/pdf.dart';

import '../core/chart/axis_range_policy.dart';
import '../core/chart/chart_geometry.dart';
import '../core/chart/chart_layout.dart';
import '../core/chart/chart_model.dart';
import '../core/chart/chart_theme.dart';
import '../core/chart/time_axis.dart';

/// 把 [ChartGeometry] 产出的 [RenderPlan] 画到 `package:pdf` 的 [PdfGraphics] 上。
///
/// 与 Android 版 `PdfChartRenderer` 一样，本类**只画不算** ——
/// 轴范围、采样、刻度、文字位置全部由 `core/chart` 决定，这里只把数字喂给 PDF
/// 绘图指令。这样几何判断都能在纯 Dart VM 上单测，渲染层即使画歪了
/// 也只影响观感，不会静默产生错误的数据结论。
///
/// ## 坐标约定
/// `package:pdf` 的用户空间是 **y 向上**（PDF 原生），而 `ChartLayout` /
/// `RenderPlan` 沿用 Android Canvas 的 **y 向下**约定。两种模式：
///
/// - 传了 [draw] 的 `pageHeight`（推荐）：`topYStart` 是**从页面顶部往下量**的
///   y，渲染器内部换算成 `pageHeight - y`，直接画在普通 PDF 页面上。
/// - 不传 `pageHeight`：假定调用方已经在 canvas 上装好了"左上角为原点、
///   y 向下"的整体变换（例如 `T(0, pageHeight) · S(1, -1)`）。此时坐标原样使用；
///   文字会再套一次局部 y 翻转，保证字形不会上下镜像。
///
/// ## 字体
/// PDF 内置的 Helvetica 只有 WinAnsi（≈Latin-1）字符，画不了中文和 `℃`。
/// 本类**不负责加载字体**：调用方通过 [draw] 的 `font` / `boldFont` 传入
/// 已加载的 CJK 字体；为 null 时退回 canvas 的默认字体，并把该字体不支持的
/// 字符替换成 `?`（总比抛异常导致整份报告生成失败要好）。
class PdfChartRenderer {
  PdfChartRenderer._();

  /// 曲线虚线。相位在被采样后的整条折线上连续。
  static const List<num> _seriesDash = <num>[4, 2.5];

  /// 阈值线虚线。
  static const List<num> _thresholdDash = <num>[3, 3];

  /// 图例样条虚线。
  static const List<num> _legendDash = <num>[3, 2];

  /// 单条记录时曲线画不出来（一个点构不成线段），改画一个实心圆点。
  static const double _singlePointRadiusPt = 1.6;

  /// 在 [topYStart] 处画一整块图表。
  ///
  /// 调用方负责画图表标题条，并以**标题条底部**作为 [topYStart]。
  ///
  /// [pageHeight] 见类注释的坐标约定；A4 可用 `PdfPageFormat.a4.height`。
  ///
  /// [points] 已按时间升序、已按时间筛选过的记录。
  /// [thresholdLowC] / [thresholdHighC] 报警阈值，**单位是 ℃**。
  ///
  /// 返回图表块底部的 y（y 向下的坐标系），恒等于
  /// `topYStart + ChartLayout.plotBlockHeightPt`，调用方据此继续往下排版。
  static double draw(
    PdfGraphics canvas, {
    required double topYStart,
    required double contentLeft,
    required double contentRight,
    required List<ChartPoint> points,
    required TemperatureDisplay display,
    double? thresholdLowC,
    double? thresholdHighC,
    required ChartTimeZone tz,
    String locale = 'en_US',
    double? pageHeight,
    PdfFont? font,
    PdfFont? boldFont,
    void Function(double progress)? onProgress,
  }) {
    final plot = ChartLayout.plotRectFor(topYStart, contentLeft, contentRight);

    onProgress?.call(0.2);
    final ChartModel model = ChartGeometry.buildModel(
      points,
      display,
      thresholdLowC,
      thresholdHighC,
      tz,
      locale,
      ChartGeometry.targetPointCount(plot.width),
    );

    onProgress?.call(0.7);
    final RenderPlan plan = ChartGeometry.buildRenderPlan(model, plot);

    final fallbackFont = canvas.defaultFont;
    if (fallbackFont == null) {
      throw StateError('PdfGraphics 没有默认字体，无法绘制图表文字');
    }

    final painter = _PlanPainter(
      canvas,
      pageHeight: pageHeight,
      regularFont: font ?? fallbackFont,
      boldFont: boldFont ?? font ?? fallbackFont,
    );
    painter.paint(plan);
    onProgress?.call(1);

    return topYStart + ChartLayout.plotBlockHeightPt;
  }
}

/// 负责把一份 [RenderPlan] 逐项画出来。
///
/// 和 Kotlin 版一样，所有绘图状态（颜色、线宽、虚线、字体）都显式设置，
/// 不依赖调用方留下的状态；整块绘制过程被 save/restore 包住。
class _PlanPainter {
  _PlanPainter(
    this.canvas, {
    required this.pageHeight,
    required this.regularFont,
    required this.boldFont,
  });

  final PdfGraphics canvas;

  /// null 表示调用方已把 canvas 装成 y 向下的坐标系。
  final double? pageHeight;

  final PdfFont regularFont;
  final PdfFont boldFont;

  bool get _nativePdf => pageHeight != null;

  /// y（y 向下）→ canvas 用户空间 y。
  double _y(double yDown) => pageHeight == null ? yDown : pageHeight! - yDown;

  void paint(RenderPlan plan) {
    canvas.saveContext();
    try {
      canvas
        ..setLineCap(PdfLineCap.round)
        ..setLineJoin(PdfLineJoin.round);
      _paint(plan);
    } finally {
      canvas.restoreContext();
    }
  }

  void _paint(RenderPlan plan) {
    // 网格先画，会被后面的曲线盖住。
    _setStroke(ChartTheme.grid, ChartTheme.gridWidthPt);
    for (final line in plan.gridLines) {
      _strokeLine(line);
    }

    _setStroke(ChartTheme.frame, ChartTheme.frameWidthPt);
    for (final line in plan.frameLines) {
      _strokeLine(line);
    }

    for (final series in plan.series) {
      _drawSeries(series);
    }

    // 阈值线压在曲线之上：它必须始终可见，被曲线盖住就失去了警示作用。
    _setStroke(ChartTheme.threshold, ChartTheme.thresholdWidthPt);
    canvas.setLineDashPattern(PdfChartRenderer._thresholdDash);
    for (final line in plan.thresholdLines) {
      _strokeLine(line);
    }
    canvas.setLineDashPattern();

    for (final item in plan.thresholdLabels) {
      _drawTextAt(item);
    }
    for (final item in plan.yLabelsLeft) {
      _drawTextAt(item);
    }
    for (final item in plan.yLabelsRight) {
      _drawTextAt(item);
    }
    for (final item in plan.xLabels) {
      _drawTextAt(item);
    }
    for (final item in plan.axisTitles) {
      _drawTextAt(item);
    }

    final emptyMessage = plan.emptyMessage;
    if (emptyMessage != null) {
      _drawTextAt(emptyMessage);
    }

    _drawLegendAndNote(plan);
  }

  // ---------- 基本图元 ----------

  void _setStroke(int color, double widthPt) {
    canvas
      ..setStrokeColor(PdfColor.fromInt(color))
      ..setLineWidth(widthPt)
      ..setLineDashPattern();
  }

  void _strokeLine(Line line) {
    canvas
      ..moveTo(line.x0, _y(line.y0))
      ..lineTo(line.x1, _y(line.y1))
      ..strokePath();
  }

  void _drawSeries(SeriesPlan series) {
    final points = series.points;
    if (points.isEmpty) {
      return;
    }

    if (points.length == 2) {
      // 单条记录：一个点构不成线段，drawPath 什么都不会画出来。
      // 报告上会出现"有数据但图上什么都没有"，比不画更容易被误读。
      canvas
        ..setFillColor(PdfColor.fromInt(series.color))
        ..drawEllipse(
          points[0],
          _y(points[1]),
          PdfChartRenderer._singlePointRadiusPt,
          PdfChartRenderer._singlePointRadiusPt,
        )
        ..fillPath();
      return;
    }

    canvas
      ..setStrokeColor(PdfColor.fromInt(series.color))
      ..setLineWidth(series.widthPt)
      ..setLineDashPattern(
        series.dashed ? PdfChartRenderer._seriesDash : const <num>[],
      );

    canvas.moveTo(points[0], _y(points[1]));
    var i = 2;
    while (i < points.length) {
      canvas.lineTo(points[i], _y(points[i + 1]));
      i += 2;
    }
    canvas
      ..strokePath()
      ..setLineDashPattern();
  }

  // ---------- 文字 ----------

  void _drawTextAt(TextAt t) {
    final font = t.bold ? boldFont : regularFont;
    final text = _sanitize(font, t.text);
    final width = _measure(font, text, t.sizePt);
    final offset = switch (t.anchor) {
      Anchor.left => 0.0,
      Anchor.center => width / 2,
      Anchor.right => width,
    };

    canvas.setFillColor(PdfColor.fromInt(t.color));

    if (!_nativePdf) {
      // 调用方的 canvas 已 y 向下；给文字套一次局部 y 翻转，
      // 抵消整体翻转，字形才不会上下镜像。
      canvas.saveContext();
      final m = canvas.getTransform()
        ..setIdentity()
        ..translateByDouble(t.x, t.y, 0, 1);
      if (t.rotateDeg != 0) {
        m.rotateZ(t.rotateDeg * math.pi / 180);
      }
      m
        ..translateByDouble(-offset, 0, 0, 1)
        ..scaleByDouble(1, -1, 1, 1)
        ..translateByDouble(-t.x, -t.y, 0, 1);
      canvas
        ..setTransform(m)
        ..drawString(font, t.sizePt, text, t.x, t.y)
        ..restoreContext();
      return;
    }

    final yPdf = pageHeight! - t.y;
    final startX = t.x - offset;

    if (t.rotateDeg == 0) {
      canvas.drawString(font, t.sizePt, text, startX, yPdf);
      return;
    }

    // PDF 的旋转正方向是逆时针，Android Canvas 是顺时针，
    // 所以角度取负；旋转轴心仍是 (t.x, t.y) 对应的 PDF 点。
    canvas.saveContext();
    final m = canvas.getTransform()
      ..setIdentity()
      ..translateByDouble(t.x, yPdf, 0, 1)
      ..rotateZ(-t.rotateDeg * math.pi / 180)
      ..translateByDouble(-t.x, -yPdf, 0, 1);
    canvas
      ..setTransform(m)
      ..drawString(font, t.sizePt, text, startX, yPdf)
      ..restoreContext();
  }

  /// 不旋转、起点已算好的普通文字（图例样条后的标签）。
  void _drawTextRun(
    PdfFont font,
    double sizePt,
    String text,
    double startX,
    double baselineY,
    int color,
  ) {
    canvas.setFillColor(PdfColor.fromInt(color));

    if (_nativePdf) {
      canvas.drawString(font, sizePt, text, startX, pageHeight! - baselineY);
      return;
    }

    canvas.saveContext();
    final m = canvas.getTransform()
      ..setIdentity()
      ..translateByDouble(startX, baselineY, 0, 1)
      ..scaleByDouble(1, -1, 1, 1)
      ..translateByDouble(-startX, -baselineY, 0, 1);
    canvas
      ..setTransform(m)
      ..drawString(font, sizePt, text, startX, baselineY)
      ..restoreContext();
  }

  /// 文字宽度（pt）。逐字累加 advance，和 PDF 实际排版一致。
  ///
  /// 不用 `PdfFont.stringMetrics`：它对 TrueType 字体扣除了末字的
  /// right bearing，量出来的宽度会比实际排出来的短一点。
  double _measure(PdfFont font, String text, double sizePt) {
    var advance = 0.0;
    for (final rune in text.runes) {
      advance += font.glyphMetrics(rune).advanceWidth;
    }
    return advance * sizePt;
  }

  /// 把字体不支持的字符替换成 `?`。
  ///
  /// 默认 Helvetica 只有 WinAnsi 编码；直接交给它画中文会在
  /// `PdfFont.putText` 里抛异常，整份报告都生成不出来。
  String _sanitize(PdfFont font, String text) {
    final buffer = StringBuffer();
    var changed = false;
    for (final rune in text.runes) {
      if (_supports(font, rune)) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write('?');
        changed = true;
      }
    }
    return changed ? buffer.toString() : text;
  }

  bool _supports(PdfFont font, int rune) {
    if (rune < 0) {
      return false;
    }
    if (font is PdfTtfFont) {
      return font.isRuneSupported(rune);
    }
    // 内置 Type1 字体使用 WinAnsi 编码。
    return rune <= 0xFF;
  }

  // ---------- 图例与注释 ----------

  /// 图例与注释行。
  ///
  /// 两者抢同一行时**让位给注释**：注释是"湿度轴不从 0 开始"这类
  /// 防止误读的披露，图例只是导航。空间不足时直接停止画后续图例条目，
  /// 而不是叠在一起 —— 重叠的文字谁也读不出来。
  void _drawLegendAndNote(RenderPlan plan) {
    final plot = plan.plot;
    final legendY = plot.bottom + ChartLayout.xLabelBandPt + 9;

    final note = plan.note;
    final noteWidth = note == null
        ? 0.0
        : _measure(
            regularFont,
            _sanitize(regularFont, note),
            ChartTheme.notePt,
          );
    final noteLeft = plot.right - noteWidth;

    var x = plot.left;
    final swatchY = legendY - ChartTheme.legendPt / 3;
    for (final item in plan.legend) {
      const swatch = ChartTheme.legendSwatchPt;
      final text = _sanitize(regularFont, item.text);
      final textWidth = _measure(regularFont, text, ChartTheme.legendPt);
      if (x + swatch + 4 + textWidth > noteLeft - 10) {
        break;
      }

      canvas
        ..setStrokeColor(PdfColor.fromInt(item.color))
        ..setLineWidth(1.4)
        ..setLineDashPattern(
          item.dashed ? PdfChartRenderer._legendDash : const <num>[],
        )
        ..moveTo(x, _y(swatchY))
        ..lineTo(x + swatch, _y(swatchY))
        ..strokePath()
        ..setLineDashPattern();

      _drawTextRun(
        regularFont,
        ChartTheme.legendPt,
        text,
        x + swatch + 4,
        legendY,
        ChartTheme.titleInk,
      );
      x += swatch + 4 + textWidth + 14;
    }

    if (note != null) {
      _drawTextAt(
        TextAt(
          x: plot.right,
          y: legendY,
          text: note,
          anchor: Anchor.right,
          color: ChartTheme.mutedInk,
          sizePt: ChartTheme.notePt,
        ),
      );
    }
  }
}
