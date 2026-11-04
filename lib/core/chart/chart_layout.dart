import 'chart_model.dart';

/// 一个闭区间 `[start, endInclusive]`，对应 Kotlin 的 `ClosedFloatingPointRange<Float>`。
class ClosedFloatRange {
  const ClosedFloatRange(this.start, this.endInclusive);

  final double start;
  final double endInclusive;
}

/// 图表分块的尺寸常量与分页判定。
///
/// 常量集中在这里、而不是散落在几何层和渲染层各写一份，
/// 否则两边的高度一旦对不上，分页判定就会与实际绘制错位。
///
/// 单位一律是 PDF 的 point（A4 = 595×842pt，72dpi）。
/// 注意 dataviz 规范里的线宽尺寸是屏幕口径（px），打印文档要按 pt 换算：
/// 发丝线 0.4–0.6pt、数据线 1–1.3pt、任何需人读的字不小于 7pt。
abstract final class ChartLayout {
  /// 与"统计信息"等既有区块同款的灰底圆角标题条。
  static const double titleHeightPt = 22;
  static const double titleGapPt = 8;

  static const double plotHeightPt = 170;

  /// X 轴刻度标签带。
  static const double xLabelBandPt = 18;

  /// 图例 / 注释行。
  static const double footerBandPt = 14;

  /// 图表块整体高度。图表是原子块，绝不允许跨页断开。
  static const double blockHeightPt = titleHeightPt +
      titleGapPt +
      plotHeightPt +
      xLabelBandPt +
      footerBandPt;

  /// 标题条之下、绘图区及其附属部分的高度。
  ///
  /// 调用方自己画标题条（复用报告里既有的"灰底圆角条"画法），
  /// 然后以 `topYStart = 标题条底部` 调用渲染器，渲染器返回
  /// `topYStart + plotBlockHeightPt`。两者相加必须恰好等于 [blockHeightPt]，
  /// 否则分页判定与实际绘制会错位（`ChartLayoutTest` 锁住了这个恒等式）。
  static const double plotBlockHeightPt =
      plotHeightPt + xLabelBandPt + footerBandPt;

  /// 左右两侧留给"轴刻度 + 旋转轴标题"的沟。
  ///
  /// 40 而不是 34。卡住下限的是**外缘**，不是叠字：
  /// 轴标题旋转 −90° 后，占水平方向的是**字身**（ascent ≈ 0.93em），不是字号。
  /// 轴槽 34 → plot.left = 74 → 标题外缘 = 74 − 28 − 7.44 = 38.6，
  /// 已经越过版心左边界 40，打印出来会被裁掉一截。
  /// 轴槽 40 → plot.left = 80 → 外缘 44.6，留出 4.6pt 余量。
  ///
  /// 叠字是另一回事：刻度标签左缘与标题内缘都锚在 plot.left 上，
  /// 相对距离与轴槽宽度无关，40 和 34 都不叠。
  static const double plotGutterLeftPt = 40;
  static const double plotGutterRightPt = 40;

  /// 轴标题基线到绘图区边缘的距离。旋转后它决定轴标题字身的水平位置。
  static const double axisTitleOffsetPt = 28;

  /// 刻度标签基线到绘图区边缘的距离。
  static const double scaleLabelOffsetPt = 4;

  /// 图表画完之后，页面底部至少还要留得下"分隔线 + 表头 + 2 行数据"。
  /// 否则会出现"图表占满整页、表格孤零零跑到下一页只剩两行"的浪费排版。
  static const double tableReservePt = 80;

  /// 与既有表格分页逻辑保持一致的页面底部阈值。
  static const double pageBottomLimitPt = 780;

  /// 绘图区宽度 = 内容区宽度减去左右两条轴标签沟。实测 515 − 40 − 40 = 435pt。
  static double plotWidthFor(double contentWidthPt) =>
      contentWidthPt - plotGutterLeftPt - plotGutterRightPt;

  /// sans-serif 的字身比例（ascent / descent 相对字号）。
  ///
  /// core 层不许 import Flutter/Android，所以调不了 `Paint.getFontMetrics()`，
  /// 这两个常数是保守代理值。它们只被用来回答"轴槽够不够宽"这一个问题，
  /// 不追求像素级精确 —— 真正的排版由渲染层目视验收。
  static const double _fontAscentRatio = 0.93;
  static const double _fontDescentRatio = 0.25;

  /// 轴标题占用的水平区间。
  ///
  /// 两条轴标题**旋转方向必须相反**，否则右侧会挤到刻度上：
  ///
  /// 旋转以**基线点**为轴心，字身落在 `[基线 − ascent, 基线 + descent]` ——
  /// 注意这是不对称的，ascent 远大于 descent。−90°（字头朝 −x）用在左轴时，
  /// 靠近绘图区的那条边是 `基线 + descent`，只有 2pt，绰绰有余；
  /// 但同一个 −90° 用在右轴，靠近绘图区的那条边就变成 `基线 − ascent`（−7.4pt），
  /// 一下子贴到刻度标签上。
  ///
  /// 所以左轴 −90°（自下而上）、右轴 +90°（自上而下），
  /// 两条标题的"字头"都朝版心外侧 —— 这也正是双轴图右轴标题的排版惯例。
  ///
  /// 按"字号的一半"估会低估约 15%，正好把这一类"差一点点就叠上"的问题放过去。
  static ClosedFloatRange leftRotatedTitleSpan(
    double plotLeftPt,
    double titleSizePt,
  ) {
    final baseline = plotLeftPt - axisTitleOffsetPt;
    return ClosedFloatRange(
      baseline - titleSizePt * _fontAscentRatio,
      baseline + titleSizePt * _fontDescentRatio,
    );
  }

  /// 见 [leftRotatedTitleSpan]。右轴 +90°，字身方向镜像。
  static ClosedFloatRange rightRotatedTitleSpan(
    double plotRightPt,
    double titleSizePt,
  ) {
    final baseline = plotRightPt + axisTitleOffsetPt;
    return ClosedFloatRange(
      baseline - titleSizePt * _fontDescentRatio,
      baseline + titleSizePt * _fontAscentRatio,
    );
  }

  /// 右对齐于绘图区左侧的刻度标签占用的水平区间 `[左缘, 基线]`。
  static ClosedFloatRange leftScaleLabelSpan(
    double plotLeftPt,
    double labelWidthPt,
  ) {
    final baseline = plotLeftPt - scaleLabelOffsetPt;
    return ClosedFloatRange(baseline - labelWidthPt, baseline);
  }

  /// 左对齐于绘图区右侧的刻度标签占用的水平区间 `[基线, 右缘]`。
  static ClosedFloatRange rightScaleLabelSpan(
    double plotRightPt,
    double labelWidthPt,
  ) {
    final baseline = plotRightPt + scaleLabelOffsetPt;
    return ClosedFloatRange(baseline, baseline + labelWidthPt);
  }

  /// 绘图区矩形：内容区左边 + 左沟，顶部从 [topYStart] 起，高 [plotHeightPt]。
  ///
  /// 放在这里而不是渲染器里，是为了让"图表在真实版心内不越界"能被单测断言 ——
  /// 渲染器里那份代码没法在纯 Dart VM 上跑，
  /// 而这段坐标一旦算错，轴标题和刻度标签就会被版心裁掉。
  static PlotRect plotRectFor(
    double topYStart,
    double contentLeftPt,
    double contentRightPt,
  ) =>
      PlotRect(
        left: contentLeftPt + plotGutterLeftPt,
        top: topYStart,
        right: contentLeftPt +
            plotGutterLeftPt +
            plotWidthFor(contentRightPt - contentLeftPt),
        bottom: topYStart + plotHeightPt,
      );

  /// 图表块是否需要整体挪到下一页。
  /// 实测：内容区宽 515pt 时，y 超过约 468 就翻页。
  static bool needsNewPage(double y) =>
      y + blockHeightPt > pageBottomLimitPt - tableReservePt;
}
