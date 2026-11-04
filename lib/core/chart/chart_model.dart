import 'dart:typed_data';

import 'axis_scale.dart';
import 'time_axis.dart';

/// 图表层之间传递的纯数据模型。
///
/// 本包（`chart.core`）**不允许 import 任何 Flutter/Android API** ——
/// 把"需要判断"的逻辑全部限制在这个包内，就能用纯 Dart 单测覆盖它们。
/// 这个约束是自证的：只要本包某个文件 import 了 `dart:ui`，
/// 对应的测试类在纯 Dart VM 上就加载不了，测试当场失败。

/// 文字锚点。首个/末尾刻度必须分别用 left/right ——
/// 居中会被绘图区边界切掉半截标签。
enum Anchor { left, center, right }

/// 绘图区矩形，单位是 PDF 的 point（A4 = 595×842pt）。
class PlotRect {
  const PlotRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  @override
  bool operator ==(Object other) =>
      other is PlotRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'PlotRect($left, $top, $right, $bottom)';
}

/// 一条记录在图表里的最小表示。
class ChartPoint {
  const ChartPoint({
    required this.tSec,
    required this.temperatureC,
    required this.humidity,
  });

  final int tSec;
  final double temperatureC;
  final int humidity;

  @override
  bool operator ==(Object other) =>
      other is ChartPoint &&
      other.tSec == tSec &&
      other.temperatureC == temperatureC &&
      other.humidity == humidity;

  @override
  int get hashCode => Object.hash(tSec, temperatureC, humidity);
}

/// 一条阈值线的规格。
class ThresholdSpec {
  const ThresholdSpec({
    required this.valueDisplay,
    required this.label,
    required this.color,
  });

  final double valueDisplay;
  final String label;
  final int color;

  @override
  bool operator ==(Object other) =>
      other is ThresholdSpec &&
      other.valueDisplay == valueDisplay &&
      other.label == label &&
      other.color == color;

  @override
  int get hashCode => Object.hash(valueDisplay, label, color);
}

/// 采样序列。交错存放 `[ratio0, value0, ratio1, value1, ...]`。
///
/// 用 `Float64List` 而非 `List<Pair>`：6.5 万条时前者不产生装箱对象。
/// `ratio` 是 0..1 的相对位置（不是像素），`value` 是**显示单位**下的数值 ——
/// 几何层完全不需要知道数据是 ℃ 还是 ℉。
typedef SampleArray = Float64List;

/// 交给渲染层的全部内容。渲染层拿到后不做任何判断，只把数字喂给 Canvas。
class RenderPlan {
  const RenderPlan({
    required this.plot,
    required this.gridLines,
    required this.frameLines,
    required this.series,
    required this.thresholdLines,
    required this.thresholdLabels,
    required this.yLabelsLeft,
    required this.yLabelsRight,
    required this.xLabels,
    required this.axisTitles,
    required this.legend,
    required this.note,
    required this.emptyMessage,
  });

  final PlotRect plot;
  final List<Line> gridLines;
  final List<Line> frameLines;
  final List<SeriesPlan> series;
  final List<Line> thresholdLines;
  final List<TextAt> thresholdLabels;
  final List<TextAt> yLabelsLeft;
  final List<TextAt> yLabelsRight;
  final List<TextAt> xLabels;
  final List<TextAt> axisTitles;
  final List<LegendItem> legend;

  /// 图下方的一行说明（湿度轴缩放、湿度缺失、时间戳异常等），无则为 null。
  final String? note;

  /// 无数据时的提示文字。
  final TextAt? emptyMessage;
}

/// 线段，全部是 pt 坐标。
class Line {
  const Line(this.x0, this.y0, this.x1, this.y1);

  final double x0;
  final double y0;
  final double x1;
  final double y1;

  @override
  bool operator ==(Object other) =>
      other is Line &&
      other.x0 == x0 &&
      other.y0 == y0 &&
      other.x1 == x1 &&
      other.y1 == y1;

  @override
  int get hashCode => Object.hash(x0, y0, x1, y1);
}

/// 定位好的文字。
///
/// [rotateDeg] 非 0 时，渲染层需以 (x, y) 为轴心旋转绘制 —— 仅在轴标题上使用。
class TextAt {
  const TextAt({
    required this.x,
    required this.y,
    required this.text,
    required this.anchor,
    required this.color,
    required this.sizePt,
    this.bold = false,
    this.rotateDeg = 0,
  });

  final double x;
  final double y;
  final String text;
  final Anchor anchor;
  final int color;
  final double sizePt;
  final bool bold;
  final double rotateDeg;

  @override
  bool operator ==(Object other) =>
      other is TextAt &&
      other.x == x &&
      other.y == y &&
      other.text == text &&
      other.anchor == anchor &&
      other.color == color &&
      other.sizePt == sizePt &&
      other.bold == bold &&
      other.rotateDeg == rotateDeg;

  @override
  int get hashCode =>
      Object.hash(x, y, text, anchor, color, sizePt, bold, rotateDeg);
}

/// 一条曲线及其绘制样式。[points] 是交错数组 `[x0,y0,x1,y1,...]`，单位 pt。
class SeriesPlan {
  const SeriesPlan({
    required this.points,
    required this.color,
    required this.dashed,
    required this.widthPt,
  });

  final Float64List points;
  final int color;
  final bool dashed;
  final double widthPt;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SeriesPlan) return false;
    if (points.length != other.points.length) return false;
    for (var i = 0; i < points.length; i++) {
      if (points[i] != other.points[i]) return false;
    }
    return color == other.color &&
        dashed == other.dashed &&
        widthPt == other.widthPt;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(points),
        color,
        dashed,
        widthPt,
      );
}

/// 图例条目。虚线样式一并带上，让实线/虚线的区分在图例里也读得出来。
class LegendItem {
  const LegendItem({
    required this.color,
    required this.dashed,
    required this.text,
  });

  final int color;
  final bool dashed;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is LegendItem &&
      other.color == color &&
      other.dashed == dashed &&
      other.text == text;

  @override
  int get hashCode => Object.hash(color, dashed, text);
}

/// 构建好的图表数据，是 [ChartGeometry.buildRenderPlan] 的输入。
class ChartModel {
  const ChartModel({
    required this.tempAxis,
    required this.humAxis,
    required this.tempUnitSymbol,
    required this.tempSamples,
    required this.humSamples,
    required this.thresholds,
    required this.xTicks,
    required this.note,
  });

  final AxisScale tempAxis;

  /// 湿度轴。设备不上报湿度（读数恒为 0）时为 null。
  final AxisScale? humAxis;

  final String tempUnitSymbol;
  final SampleArray tempSamples;
  final SampleArray humSamples;
  final List<ThresholdSpec> thresholds;
  final List<TimeTick> xTicks;
  final String? note;

  bool get showHumidity => humAxis != null;
}
