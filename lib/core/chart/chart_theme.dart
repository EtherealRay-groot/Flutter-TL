/// 图表的颜色与线宽。
///
/// 配色取自 dataviz 参考调色板，其校验脚本已在白色底（PDF 纸张）上实跑通过：
/// 明度带、彩度下限、色盲分离度（protan ΔE 24.7）、常视觉分离度（ΔE 33.6）、
/// 对比度全部 PASS。
///
/// ## 尺寸单位
/// 这里不是屏幕 UI，是 72dpi 的 A4 打印矢量文档。
/// dataviz 规范里的"2px 线宽"是屏幕口径，直接照搬到 pt 会太粗 ——
/// 打印惯例是发丝线 0.4–0.6pt、数据线 1–1.3pt。
/// **任何需要人读的字不得小于 7pt**（A4 100% 下约 2.5mm 高）。
///
/// ## 为什么温度实线、湿度虚线
/// 蓝 `#2A78D6` 与橙 `#EB6834` 转成灰度后分别是 110 和 128 —— 只差 18/255，
/// **黑白打印时两条线几乎同色**。线型是灰度下唯一可靠的区分手段，
/// 不是装饰。右侧湿度轴刻度也染成橙色，读者才不会误认哪条线读哪个轴。
abstract final class ChartTheme {
  /// 温度线，蓝。灰度值 110。
  static const int tempLine = 0xFF2A78D6;

  /// 湿度线，橙。灰度值 128。
  static const int humLine = 0xFFEB6834;

  /// 报警阈值线，状态红。灰度值 91，比两条数据线都深。
  static const int threshold = 0xFFD03B3B;

  static const int grid = 0xFFE1E0D9;
  static const int frame = 0xFFC3C2B7;
  static const int labelInk = 0xFF52514E;
  static const int mutedInk = 0xFF898781;
  static const int titleInk = 0xFF0B0B0B;
  static const int surface = 0xFFFFFFFF;

  static const double seriesWidthPt = 1.2;
  static const double thresholdWidthPt = 0.8;
  static const double gridWidthPt = 0.4;
  static const double frameWidthPt = 0.6;

  static const double axisLabelPt = 7.5;
  static const double axisTitlePt = 8;
  static const double legendPt = 8;
  static const double thresholdLabelPt = 7;
  static const double notePt = 7;
  static const double emptyMessagePt = 9;

  /// 图例样条的宽度。
  static const double legendSwatchPt = 14;
}
