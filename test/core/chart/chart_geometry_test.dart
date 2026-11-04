import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:tl_app/core/chart/axis_range_policy.dart';
import 'package:tl_app/core/chart/chart_geometry.dart';
import 'package:tl_app/core/chart/chart_model.dart';
import 'package:tl_app/core/chart/time_axis.dart';

void main() {
  const utc = ChartTimeZone.utc;
  const locale = 'en_US';
  const plot = PlotRect(left: 74, top: 100, right: 521, bottom: 270);

  int utcSec(int y, int mo, int d, {int h = 0, int mi = 0}) =>
      DateTime.utc(y, mo, d, h, mi, 0).millisecondsSinceEpoch ~/ 1000;

  /// 生成 n 条等间隔记录。
  /// `temp` 放在最后，这样 trailing lambda 就是温度曲线，符合直觉。
  List<ChartPoint> points(
    int n, {
    int? startSec,
    int stepSec = 60,
    int Function(int)? hum,
    double Function(int)? temp,
  }) {
    final start = startSec ?? utcSec(2026, 9, 11);
    final humFn = hum ?? (i) => 50;
    final tempFn = temp ?? (i) => 25.0;
    return List<ChartPoint>.generate(
      n,
      (i) => ChartPoint(
        tSec: start + i * stepSec,
        temperatureC: tempFn(i),
        humidity: humFn(i),
      ),
    );
  }

  /// 常见曲线：温度在 20~29℃ 之间波动，湿度落在 45~64% 的正常区间。
  List<ChartPoint> wave(int n, {int Function(int)? hum}) => points(
        n,
        hum: hum ?? (i) => 45 + i % 20,
        temp: (i) => 20.0 + (i % 10),
      );

  ChartModel model(
    List<ChartPoint> pts, {
    TemperatureDisplay display = TemperatureDisplay.celsius,
    double? low,
    double? high,
    int targetPoints = 900,
  }) =>
      ChartGeometry.buildModel(
        pts,
        display,
        low,
        high,
        utc,
        locale,
        targetPoints,
      );

  RenderPlan plan(
    List<ChartPoint> pts, {
    double? low,
    double? high,
    TemperatureDisplay display = TemperatureDisplay.celsius,
  }) =>
      ChartGeometry.buildRenderPlan(model(pts, display: display, low: low, high: high), plot);

  List<double> xCoords(List<double> interleaved) =>
      <double>[for (var i = 0; i < interleaved.length; i += 2) interleaved[i]];

  List<double> yCoords(List<double> interleaved) =>
      <double>[for (var i = 1; i < interleaved.length; i += 2) interleaved[i]];

  // ---------- 采样序列 ----------

  test('seriesPointsAreInsideThePlotRect', () {
    final p = plan(wave(500));
    expect(p.series.isNotEmpty, isTrue);
    for (final s in p.series) {
      expect(s.points.length % 2, 0, reason: '交错数组不成对');
      var i = 0;
      while (i < s.points.length) {
        final x = s.points[i];
        final y = s.points[i + 1];
        expect(
          x >= plot.left - 0.01 && x <= plot.right + 0.01,
          isTrue,
          reason: 'x=$x 越出 [${plot.left}, ${plot.right}]',
        );
        expect(
          y >= plot.top - 0.01 && y <= plot.bottom + 0.01,
          isTrue,
          reason: 'y=$y 越出 [${plot.top}, ${plot.bottom}]',
        );
        i += 2;
      }
    }
  });

  test('allCoordinatesAreFinite', () {
    final p = plan(wave(300), low: 10, high: 30);
    for (final s in p.series) {
      for (final value in s.points) {
        expect(value.isFinite, isTrue,
            reason: '坐标出现 NaN，drawPath 会画出不可预期的结果');
      }
    }
    for (final line in p.thresholdLines) {
      expect(
        line.x0.isFinite &&
            line.y0.isFinite &&
            line.x1.isFinite &&
            line.y1.isFinite,
        isTrue,
      );
    }
    for (final line in p.gridLines) {
      expect(line.y0.isFinite, isTrue);
    }
  });

  test('singleRecord_producesFiniteCoordinatesInsteadOfNaN', () {
    // 只有一条记录时 tMax == tMin，ratio 会除零得 NaN
    final p = plan(points(1));
    for (final s in p.series) {
      for (final value in s.points) {
        expect(value.isFinite, isTrue, reason: '单条记录产生了 NaN 坐标');
      }
    }
  }, timeout: const Timeout(Duration(seconds: 2)));

  test('temperatureRunsLeftToRightAcrossTheFullWidth', () {
    final p = plan(wave(200));
    final pts = p.series.first.points;
    expect(pts[0], closeTo(plot.left, 0.01),
        reason: '序列未从绘图区左边界开始');
    expect(pts[pts.length - 2], closeTo(plot.right, 0.01),
        reason: '序列未抵达绘图区右边界');
  });

  test('temperatureSeriesIsSolidAndHumiditySeriesIsDashed', () {
    final p = plan(wave(200));
    expect(p.series.length, 2, reason: '应同时画出温度与湿度两条曲线');
    expect(p.series[0].dashed, isFalse, reason: '温度线必须实线');
    expect(
      p.series[1].dashed,
      isTrue,
      reason: '湿度线必须虚线 —— 蓝橙两色在黑白打印时灰度只差 18/255，'
          '线型是唯一的第二编码通道',
    );
  });

  test('twoSeriesUseDistinctColors', () {
    final p = plan(wave(200));
    expect(p.series[0].color != p.series[1].color, isTrue,
        reason: '两条曲线同色则无法区分');
  });

  test('twoSeriesShareTheSameXCoordinates', () {
    final p = plan(wave(300), high: 40);
    expect(
      xCoords(p.series[1].points),
      equals(xCoords(p.series[0].points)),
      reason: '两条曲线的 X 必须逐点对齐，否则读出的交叉关系是假的',
    );
  });

  // ---------- 阈值线 ----------

  test('thresholdsProduceHorizontalLinesAtTheCorrectHeight', () {
    final m = model(wave(100), low: 10, high: 30);
    final p = ChartGeometry.buildRenderPlan(m, plot);
    expect(p.thresholdLines.length, 2, reason: '两条阈值应各画一条线');
    final ys = p.thresholdLines.map((it) => it.y0).toList()..sort();
    expect(
      ys[0],
      closeTo(m.tempAxis.yOf(30, plot), 0.01),
      reason: '值大的阈值对应更小的 y（屏幕坐标向下）',
    );
    expect(ys[1], closeTo(m.tempAxis.yOf(10, plot), 0.01));
    for (final line in p.thresholdLines) {
      expect(line.x0, closeTo(plot.left, 0.01), reason: '阈值线必须横贯绘图区');
      expect(line.x1, closeTo(plot.right, 0.01));
    }
  });

  test('thresholdLineCarriesATextLabelNotJustAColor', () {
    final p = plan(wave(100), low: 10, high: 30);
    expect(p.thresholdLabels.length, 2,
        reason: '状态色必须配文字标签，不能只靠颜色传达信息');
    expect(
      p.thresholdLabels.every((it) => it.text.contains('℃')),
      isTrue,
      reason: '阈值标签应写出数值与单位，实测 '
          '${p.thresholdLabels.map((it) => it.text)}',
    );
  });

  test('noThresholdsMeansNoThresholdLines', () {
    final p = plan(wave(100));
    expect(p.thresholdLines.isEmpty, isTrue);
    expect(p.thresholdLabels.isEmpty, isTrue);
  });

  test('singleSidedThresholdDrawsExactlyOneLine', () {
    expect(plan(wave(100), high: 28).thresholdLines.length, 1);
  });

  // ---------- 坐标轴 ----------

  test('gridLinesFollowTheLeftAxisTicks', () {
    final m = model(wave(200));
    final p = ChartGeometry.buildRenderPlan(m, plot);
    expect(p.gridLines.length, m.tempAxis.ticks.length,
        reason: '每条左轴刻度应有一条水平网格线');
    for (final line in p.gridLines) {
      expect(line.y0, closeTo(line.y1, 0.01), reason: '网格线必须水平');
      expect(line.x0, closeTo(plot.left, 0.01));
      expect(line.x1, closeTo(plot.right, 0.01));
    }
  });

  test('leftAxisLabelsSitToTheLeftOfThePlot', () {
    final m = model(wave(200));
    final p = ChartGeometry.buildRenderPlan(m, plot);
    expect(p.yLabelsLeft.length, m.tempAxis.ticks.length);
    for (final label in p.yLabelsLeft) {
      expect(label.anchor, Anchor.right,
          reason: '左轴标签应右对齐于绘图区左侧留白');
      expect(label.x <= plot.left, isTrue,
          reason: '左轴标签 x=${label.x} 落在绘图区内，会压在曲线上');
    }
  });

  test('rightAxisLabelsSitToTheRightOfThePlot', () {
    final p = plan(wave(200));
    expect(p.yLabelsRight.isNotEmpty, isTrue, reason: '湿度轴刻度不该为空');
    for (final label in p.yLabelsRight) {
      expect(label.anchor, Anchor.left);
      expect(label.x >= plot.right, isTrue,
          reason: '右轴标签 x=${label.x} 落在绘图区内');
    }
  });

  test('rightAxisLabelsAreTintedLikeTheHumidityLine', () {
    final p = plan(wave(200));
    final humColor = p.series[1].color;
    expect(
      p.yLabelsRight.every((it) => it.color == humColor),
      isTrue,
      reason: '右轴刻度染成湿度线的颜色，读者才不会误认哪条线读哪个轴',
    );
  });

  test('xLabelsMatchTheTimeTicks', () {
    final m = model(points(400, stepSec: 60));
    final p = ChartGeometry.buildRenderPlan(m, plot);
    expect(p.xLabels.length, m.xTicks.length);
    for (final label in p.xLabels) {
      expect(label.y > plot.bottom, isTrue, reason: 'X 标签应位于绘图区下方');
    }
  });

  test('bothAxisTitlesArePresentAndRotated', () {
    final p = plan(wave(200));
    expect(p.axisTitles.length, 2,
        reason: '温度轴与湿度轴各需要一个带单位的标题');
    expect(p.axisTitles.every((it) => it.rotateDeg != 0), isTrue,
        reason: '轴标题必须旋转 90°，否则挤不下');
    expect(p.axisTitles.any((it) => it.text.contains('℃')), isTrue,
        reason: '温度轴标题未标明单位');
    expect(p.axisTitles.any((it) => it.text.contains('%')), isTrue,
        reason: '湿度轴标题未标明单位');
  });

  test('fahrenheitChangesTheAxisTitle', () {
    final p = plan(wave(200), display: TemperatureDisplay.fahrenheit);
    expect(p.axisTitles.any((it) => it.text.contains('℉')), isTrue,
        reason: '℉ 模式下轴标题必须标明 ℉');
    expect(p.axisTitles.any((it) => it.text.contains('℃')), isFalse);
  });

  // ---------- 图例 ----------

  test('legendHasOneEntryPerSeries', () {
    final p = plan(wave(200));
    expect(p.legend.length, 2);
    expect(p.legend.any((it) => it.text.contains('温度')), isTrue,
        reason: '图例需写明曲线名称');
    expect(p.legend.any((it) => it.text.contains('湿度')), isTrue);
  });

  test('legendEntriesCarryTheLineStyleSoSolidVsDashedIsReadable', () {
    final p = plan(wave(200));
    expect(p.legend.firstWhere((it) => it.text.contains('温度')).dashed, isFalse);
    expect(p.legend.firstWhere((it) => it.text.contains('湿度')).dashed, isTrue);
  });

  test('legendMatchesTheSeriesItDescribes', () {
    // 图例的颜色与线型必须就是曲线的颜色与线型。两份常量各写一份的话，
    // 曲线改成实线而图例还标着虚线，在黑白打印时等于把读者唯一的区分依据弄丢。
    final p = plan(wave(200));
    expect(p.legend.length, p.series.length,
        reason: '图例条数应与曲线条数一致');
    for (var i = 0; i < p.series.length; i++) {
      expect(p.legend[i].color, p.series[i].color,
          reason: '第 $i 条曲线的图例颜色对不上');
      expect(p.legend[i].dashed, p.series[i].dashed,
          reason: '第 $i 条曲线的图例线型对不上');
    }
  });

  // ---------- 湿度缺失 ----------

  test('allZeroHumidity_hidesTheHumiditySeriesAndRightAxis', () {
    final p = plan(points(200, hum: (i) => 0, temp: (i) => 20.0 + (i % 10)));
    expect(p.series.length, 1,
        reason: '湿度恒为 0 说明设备不上报湿度，不该画一条贴底直线');
    expect(p.yLabelsRight.isEmpty, isTrue);
    expect(p.note, isNotNull,
        reason: '必须告诉读者湿度缺失，而不是留一片空白');
  });

  test('normalHumidity_keepsBothSeries', () {
    expect(plan(wave(200)).series.length, 2);
  });

  // ---------- 注释 ----------

  test('zoomedHumidityAxis_isDisclosedToTheReader', () {
    final p = plan(points(200, hum: (i) => 48 + i % 5, temp: (i) => 20.0 + (i % 10)));
    expect(p.note, isNotNull,
        reason: '湿度轴不从 0 开始时必须告知读者，否则会误读波动的烈度');
    expect(p.note!.contains('%'), isTrue,
        reason: '注释应写出实际范围，实测 ${p.note}');
  });

  test('fullHumidityAxis_needsNoZoomNote', () {
    final p = plan(points(200, hum: (i) => i % 100, temp: (i) => 20.0 + (i % 10)));
    expect(p.note?.contains('湿度轴自动缩放') ?? false, isFalse);
  });

  // ---------- 空数据 ----------

  test('emptyData_producesAnEmptyMessageRatherThanACrash', () {
    final p = plan(<ChartPoint>[]);
    expect(p.emptyMessage, isNotNull,
        reason: '没有数据时应说明情况，而不是留一个空白框');
    expect(p.series.every((it) => it.points.isEmpty), isTrue);
  });

  // ---------- 输出契约 ----------

  test('downsampledSeriesStillSharesOneXForBothCurves', () {
    // 未降采样的对齐靠"同一个下标数组"天然成立，降采样后靠的是
    // "两条曲线取并集、再用同一个 ratio 公式"。这是两回事，要分别断言。
    final p = plan(points(
      20000,
      hum: (i) => 40 + i % 25,
      temp: (i) => 20.0 + (i % 40),
    ));
    expect(p.series.length, 2);
    expect(
      xCoords(p.series[1].points),
      equals(xCoords(p.series[0].points)),
      reason: '降采样后两条曲线的 X 不再逐点对齐，读出的交叉关系是假的',
    );
  });

  test('downsampledXCoordinatesAreMonotonic', () {
    // drawPath 拿到的点若 X 乱序，曲线会来回折返，形状完全是假的。
    // 并集采样是排序后再输出的，这条锁住它。
    final p = plan(points(
      20000,
      hum: (i) => 40 + i % 25,
      temp: (i) => 20.0 + (i % 40),
    ));
    final xs = xCoords(p.series[0].points);
    for (var i = 1; i < xs.length; i++) {
      expect(
        xs[i] >= xs[i - 1],
        isTrue,
        reason: '第 $i 个点的 X=${xs[i]} 小于前一个 ${xs[i - 1]}，曲线会折返',
      );
    }
  });

  test('planKeepsThePlotRectItWasGiven', () {
    expect(plan(wave(100)).plot, equals(plot));
  });

  test('downsamplingKeepsThePointCountReasonable', () {
    final p = plan(points(20000, temp: (i) => 20.0 + (i % 40)));
    final count = p.series[0].points.length ~/ 2;
    expect(count <= 2000, isTrue,
        reason: '2 万条记录画成了 $count 个点，矢量 PDF 会被撑爆');
    expect(count >= 100, isTrue, reason: '降采样过头，曲线形状会失真');
  });

  test('spikeSurvivesAllTheWayThroughToRenderPlanCoordinates', () {
    // 端到端：一个点宽的尖峰必须真的出现在最终坐标里。
    // 断言"极差"而不是"贴到绘图区顶部"：无阈值时轴固定为设备量程 −30~85，
    // 78℃ 落在轴的 94% 高处而**不是**顶边，拿 plot.top 当判据是错的。
    final p = plan(points(20000, temp: (i) => i == 9999 ? 78.0 : 25.0));
    final ys = yCoords(p.series[0].points);
    const flat = 25.0;
    final expectedDrop = (78 - flat) /
        (AxisRangePolicy.deviceMaxC - AxisRangePolicy.deviceMinC) *
        plot.height;
    final spread = ys.reduce(math.max) - ys.reduce(math.min);
    expect(
      spread > expectedDrop * 0.9,
      isTrue,
      reason: '尖峰在几何阶段被丢掉了，图上根本看不到报警'
          '（y 极差 $spread，应当约为 $expectedDrop）',
    );
  });
}
