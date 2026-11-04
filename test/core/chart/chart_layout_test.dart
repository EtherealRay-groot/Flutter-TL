import 'package:test/test.dart';
import 'package:tl_app/core/chart/chart_layout.dart';
import 'package:tl_app/core/chart/chart_theme.dart';

void main() {
  test('needsNewPage_returnsFalseWhenThereIsAmpleSpace', () {
    expect(ChartLayout.needsNewPage(200), isFalse);
  });

  test('needsNewPage_returnsTrueWhenTheChartWouldOverflowThePage', () {
    expect(ChartLayout.needsNewPage(600), isTrue);
  });

  test('needsNewPage_reservesRoomForTheTableBelowTheChart', () {
    // 图表之后至少还要放得下"分隔线 + 表头 + 2 行数据"，
    // 否则会出现"图表占满整页、表格孤零零跑到下一页"的浪费排版。
    final yWhereChartFitsButTableDoesNot =
        780 - ChartLayout.blockHeightPt - ChartLayout.tableReservePt / 2;
    expect(
      ChartLayout.needsNewPage(yWhereChartFitsButTableDoesNot),
      isTrue,
      reason: '图表能放下但表格只剩一两行时，应当整体挪到下一页',
    );
  });

  test('blockHeightExactlyCoversItsParts', () {
    final parts = ChartLayout.titleHeightPt +
        ChartLayout.titleGapPt +
        ChartLayout.plotHeightPt +
        ChartLayout.xLabelBandPt +
        ChartLayout.footerBandPt;
    expect(
      (parts - ChartLayout.blockHeightPt).abs() < 0.01,
      isTrue,
      reason: '分块高度 ${ChartLayout.blockHeightPt} 与其组成部分之和 $parts 不一致，'
          '会导致分页判定与实际绘制错位',
    );
  });

  test('titlePlusPlotBlockExactlyCoversTheWholeBlock', () {
    // 调用方画完标题条后以 topYStart = 标题条底部调用渲染器，
    // 渲染器返回 topYStart + plotBlockHeightPt。
    // 两者相加若不等于 blockHeightPt，needsNewPage 就会与实际绘制错位 ——
    // 要么图表底部压到页脚外，要么白留一条缝。
    final parts = ChartLayout.titleHeightPt +
        ChartLayout.titleGapPt +
        ChartLayout.plotBlockHeightPt;
    expect(
      (parts - ChartLayout.blockHeightPt).abs() < 0.01,
      isTrue,
      reason: '标题 + 绘图块 = $parts，与 blockHeightPt=${ChartLayout.blockHeightPt} 不一致',
    );
  });

  test('plotWidthIsPositiveAfterGuttersOnAnA4ContentArea', () {
    // PDF 内容区：leftMargin=40, rightMargin=555 → 宽 515pt
    final width = ChartLayout.plotWidthFor(515);
    expect(width > 300, isTrue,
        reason: '扣掉两侧轴标签沟之后绘图区宽度为 $width，放不下曲线');
  });

  // ---------- 真实 A4 版心 ----------

  /// 报告实际使用的版心：leftMargin = 40f, rightMargin = 595 - 40 = 555f。
  const contentLeft = 40.0;
  const contentRight = 555.0;

  test('plotRect_sitsOneGutterInsideTheContentArea', () {
    final r = ChartLayout.plotRectFor(100, contentLeft, contentRight);
    expect(
      (r.left - (contentLeft + ChartLayout.plotGutterLeftPt)).abs() < 0.01,
      isTrue,
    );
    expect(
      (r.right - (contentRight - ChartLayout.plotGutterRightPt)).abs() < 0.01,
      isTrue,
    );
    expect(
      (r.bottom - r.top - ChartLayout.plotHeightPt).abs() < 0.01,
      isTrue,
    );
  });

  /// 最宽的刻度标签的保守宽度。
  /// 五字符是最坏情况：带小数的负阈值如 `-10.5`（7.5pt 下约 17pt），
  /// 这里再放宽到 18 留出字距余量。
  const widestScaleLabelPt = 18.0;

  test('rotatedAxisTitlesStayInsideTheContentArea', () {
    // 打印出来被裁掉半个字的轴标题，比没有轴标题更糟 —— 读者会以为单位是别的。
    final r = ChartLayout.plotRectFor(100, contentLeft, contentRight);
    final left = ChartLayout.leftRotatedTitleSpan(r.left, ChartTheme.axisTitlePt);
    final right =
        ChartLayout.rightRotatedTitleSpan(r.right, ChartTheme.axisTitlePt);
    expect(left.start >= contentLeft, isTrue,
        reason: '左轴标题左缘 ${left.start} 越出版心 $contentLeft');
    expect(right.endInclusive <= contentRight, isTrue,
        reason: '右轴标题右缘 ${right.endInclusive} 越出版心 $contentRight');
  });

  test('scaleLabelsDoNotCollideWithTheRotatedAxisTitleOnEitherSide', () {
    // 刻度标签向绘图区外侧让出轴槽，轴标题再往外套一层。
    // 两侧都要查：字身在旋转后是不对称的，左轴成立不代表右轴成立。
    final r = ChartLayout.plotRectFor(100, contentLeft, contentRight);
    final leftTitle =
        ChartLayout.leftRotatedTitleSpan(r.left, ChartTheme.axisTitlePt);
    final leftLabel =
        ChartLayout.leftScaleLabelSpan(r.left, widestScaleLabelPt);
    expect(
      leftLabel.start > leftTitle.endInclusive,
      isTrue,
      reason: '左刻度标签左缘 ${leftLabel.start} 与左轴标题内缘 '
          '${leftTitle.endInclusive} 重叠',
    );
    final rightTitle =
        ChartLayout.rightRotatedTitleSpan(r.right, ChartTheme.axisTitlePt);
    final rightLabel =
        ChartLayout.rightScaleLabelSpan(r.right, widestScaleLabelPt);
    expect(
      rightLabel.endInclusive < rightTitle.start,
      isTrue,
      reason: '右刻度标签右缘 ${rightLabel.endInclusive} 与右轴标题内缘 '
          '${rightTitle.start} 重叠',
    );
  });

  test('aThirtyFourPointGutterWouldClipTheRotatedAxisTitle', () {
    // 反向用例：证明 40 不是随手取的数。没有这条，上面两条只是
    // "当前参数恰好通过"，挡不住后人"顺手把沟改窄一点"。
    //
    // 注意卡住下限的是**外缘**而不是叠字：刻度标签与轴标题都锚在 plot.left 上，
    // 两者的相对距离与轴槽宽度无关。
    final plotLeft = contentLeft + 34;
    final title =
        ChartLayout.leftRotatedTitleSpan(plotLeft, ChartTheme.axisTitlePt);
    expect(
      title.start < contentLeft,
      isTrue,
      reason: '34pt 轴槽下旋转标题外缘 ${title.start} 应当越出版心 $contentLeft',
    );
  });

  test('theRightTitlePutsItsNarrowEdgeTowardsThePlot', () {
    // 这条锁住的是"右轴标题为什么必须镜像"，而不是"反正现在没撞上"。
    //
    // 字身在旋转后不对称：ascent 一侧约 0.93em，descent 一侧只有 0.25em。
    // 右轴标题朝绘图区的那条边必须是窄的那条 —— 否则它比左轴多探出 3.7 倍，
    // 直接压到刻度标签上。+90° 就是用来把窄边翻到内侧的。
    final r = ChartLayout.plotRectFor(100, contentLeft, contentRight);
    final baseline = r.right + ChartLayout.axisTitleOffsetPt;
    final title =
        ChartLayout.rightRotatedTitleSpan(r.right, ChartTheme.axisTitlePt);
    final label =
        ChartLayout.rightScaleLabelSpan(r.right, widestScaleLabelPt);

    expect(
      (baseline - title.start) < (title.endInclusive - baseline),
      isTrue,
      reason: '右轴标题朝绘图区的一侧有 ${baseline - title.start}pt，朝外侧有 '
          '${title.endInclusive - baseline}pt —— 内外反了，该镜像成 +90°',
    );
    expect(
      label.endInclusive < title.start,
      isTrue,
      reason: '右刻度标签右缘 ${label.endInclusive} 与轴标题内缘 ${title.start} 重叠',
    );
  });

  test('theChartBlockStartsBelowTheHeaderBandWhenThePageIsFresh', () {
    // newPage() 后 y = topMargin = 40，图表从 topMargin + 22 + 8 = 70 起画绘图区，
    // 整块结束于 40 + 232 = 272，稳稳在一页之内。
    final afterTitle = 40 +
        ChartLayout.titleHeightPt +
        ChartLayout.titleGapPt;
    final bottom = afterTitle + ChartLayout.plotBlockHeightPt;
    expect(bottom < ChartLayout.pageBottomLimitPt, isTrue);
  });

  test('plotWidthAccountsForBothGutters', () {
    const content = 515.0;
    final expected = content -
        ChartLayout.plotGutterLeftPt -
        ChartLayout.plotGutterRightPt;
    expect((ChartLayout.plotWidthFor(content) - expected).abs() < 0.01, isTrue);
  });
}
