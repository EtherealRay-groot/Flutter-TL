import 'dart:math' as math;
import 'dart:typed_data';

import 'axis_range_policy.dart';
import 'axis_scale.dart';
import 'chart_layout.dart';
import 'chart_model.dart';
import 'chart_theme.dart';
import 'downsampler.dart';
import 'time_axis.dart';

/// 把原始记录变成一份"照着画就行"的绘制方案。
///
/// 这一层做**全部**判断（范围、采样、刻度、布局文字），
/// 渲染层拿到 [RenderPlan] 之后不再做任何决定，只把数字喂给 Canvas。
/// 好处是所有这些判断都能在纯 Dart VM 上断言 —— `ChartGeometryTest` 里
/// 一个 Canvas 都不需要。
///
/// ## 时间轴必须用 double
/// epoch 秒约 1.7e9，单精度浮点尾数只有 24 位（分辨率约 1.7e7），
/// 相邻记录的时间戳会被舍入成同一个值，X 轴直接塌掉。
/// 因此内部一律用 `double` 算相对时间，只在最后一步降成 0..1 的比例值。
abstract final class ChartGeometry {
  /// 绘图区每 pt 画两个点。447pt 宽的绘图区 ≈ 894 点，肉眼已看不出折线感。
  static const double _pointsPerPt = 2;

  /// 采样目标点数。上下限防止极端窗口尺寸把小图撑爆或把大图压扁。
  static const int _minTargetPoints = 200;
  static const int _maxTargetPoints = 2000;

  /// 早于这个时刻的时间戳视为设备时钟未设置（2000-01-01）。
  static const int _saneTimestampFloor = 946684800;

  static const int _oneYearSec = 365 * 86400;

  /// 绘图区宽度 → 采样目标点数。
  static int targetPointCount(double plotWidthPt) =>
      (plotWidthPt * _pointsPerPt)
          .toInt()
          .clamp(_minTargetPoints, _maxTargetPoints)
          .toInt();

  /// 构建图表数据模型。
  ///
  /// [points] 已按时间**升序**排好的记录。顺序即 X 轴顺序，本函数不排序。
  /// [thresholdLowC] / [thresholdHighC] 报警阈值，**单位是 ℃**。
  /// 现有报警判定（`alarmCount`、表格红字）都直接与原始 ℃ 比较，
  /// 图表必须与它们一致，否则阈值线位置、红字、报警条数会互相矛盾。
  /// [targetPoints] 采样后保留的点数上限。
  static ChartModel buildModel(
    List<ChartPoint> points,
    TemperatureDisplay display,
    double? thresholdLowC,
    double? thresholdHighC,
    ChartTimeZone tz,
    String locale,
    int targetPoints,
  ) {
    // Dart 的 double.parse('NaN') 会得到 NaN 而不是 null，NaN 会污染所有比较
    // 并把坐标算成 NaN（Path.lineTo(NaN) 结果不可预期）。在入口一次性挡掉。
    // 注意 0℃ 是合法阈值，不能当成"未设置"。
    final loC = _finiteOrNull(thresholdLowC);
    final hiC = _finiteOrNull(thresholdHighC);

    if (points.isEmpty) {
      final range = AxisRangePolicy.temperature(
        dataMin: 0,
        dataMax: 0,
        thresholdLowC: loC,
        thresholdHighC: hiC,
        display: display,
      );
      return ChartModel(
        tempAxis: _toAxisScale(range),
        humAxis: null,
        tempUnitSymbol: display.symbol,
        tempSamples: Float64List(0),
        humSamples: Float64List(0),
        thresholds: <ThresholdSpec>[],
        xTicks: <TimeTick>[],
        note: null,
      );
    }

    // ---------- 数据范围 ----------
    var dataMinC = double.maxFinite;
    var dataMaxC = -double.maxFinite;
    var humMin = 0x7fffffff;
    var humMax = -0x80000000;
    for (final p in points) {
      final t = p.temperatureC;
      // 非有限值不参与范围计算，否则 NaN 会把 min/max 一起染成 NaN
      if (t.isFinite) {
        if (t < dataMinC) dataMinC = t;
        if (t > dataMaxC) dataMaxC = t;
      }
      if (p.humidity < humMin) humMin = p.humidity;
      if (p.humidity > humMax) humMax = p.humidity;
    }
    if (dataMinC > dataMaxC) {
      // 全部记录的温度都是非有限值
      dataMinC = 0;
      dataMaxC = 0;
    }

    final tempRange = AxisRangePolicy.temperature(
      dataMin: dataMinC,
      dataMax: dataMaxC,
      thresholdLowC: loC,
      thresholdHighC: hiC,
      display: display,
    );
    final tempAxis = _toAxisScale(tempRange);

    final humRange = AxisRangePolicy.humidity(humMin, humMax);
    final humAxis = humRange == null ? null : _toAxisScale(humRange);

    final thresholds = _buildThresholds(loC, hiC, display);

    // ---------- 时间 ----------
    final tMin = points.first.tSec;
    final tMax = points.last.tSec;
    final spanD = (tMax - tMin).toDouble();

    // ---------- 采样 ----------
    final n = points.length;
    final xs = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      xs[i] = (points[i].tSec - tMin).toDouble();
    }

    final tempYs = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      tempYs[i] = display.toDisplay(points[i].temperatureC);
    }

    final List<double> humYs;
    if (humAxis != null) {
      humYs = List<double>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        humYs[i] = points[i].humidity.toDouble();
      }
    } else {
      // 传空数组而不是 NaN 数组：selectIndices 靠长度判断有没有第二序列
      humYs = <double>[];
    }

    final indices = Downsampler.selectIndices(
      xs,
      tempYs,
      humYs,
      targetPoints,
      maxTotal: Downsampler.defaultMaxTotal,
      thresholds: thresholds.map((t) => t.valueDisplay).toList(),
    );

    final tempSamples = Float64List(indices.length * 2);
    final humSamples =
        humAxis != null ? Float64List(indices.length * 2) : Float64List(0);
    for (var k = 0; k < indices.length; k++) {
      final idx = indices[k];
      // 只有一条记录时 tMax == tMin，除零会得 NaN。放中间。
      final ratio = spanD <= 0
          ? 0.5
          : (xs[idx] / spanD).clamp(0.0, 1.0).toDouble();
      tempSamples[k * 2] = ratio;
      tempSamples[k * 2 + 1] = tempYs[idx];
      if (humAxis != null) {
        humSamples[k * 2] = ratio;
        humSamples[k * 2 + 1] = humYs[idx];
      }
    }

    return ChartModel(
      tempAxis: tempAxis,
      humAxis: humAxis,
      tempUnitSymbol: display.symbol,
      tempSamples: tempSamples,
      humSamples: humSamples,
      thresholds: thresholds,
      xTicks: TimeAxis.ticks(tMin, tMax, tz, locale),
      note: _buildNote(tempRange, humRange, tMin, tMax),
    );
  }

  /// 把模型摆到给定的绘图区矩形里。
  ///
  /// 返回的 `x`/`y` 全是 pt 绝对坐标，渲染层不需要再做任何换算或判断。
  static RenderPlan buildRenderPlan(ChartModel model, PlotRect plot) {
    final frame = <Line>[
      // 只画左、右、下三边。不画顶边是制图惯例，省墨且不与曲线抢视线。
      Line(plot.left, plot.top, plot.left, plot.bottom),
      Line(plot.right, plot.top, plot.right, plot.bottom),
      Line(plot.left, plot.bottom, plot.right, plot.bottom),
    ];
    final titles = _axisTitles(model, plot);

    if (model.tempSamples.isEmpty) {
      return RenderPlan(
        plot: plot,
        gridLines: <Line>[],
        frameLines: frame,
        series: <SeriesPlan>[],
        thresholdLines: <Line>[],
        thresholdLabels: <TextAt>[],
        yLabelsLeft: <TextAt>[],
        yLabelsRight: <TextAt>[],
        xLabels: <TextAt>[],
        axisTitles: titles,
        legend: <LegendItem>[],
        note: model.note,
        emptyMessage: TextAt(
          x: (plot.left + plot.right) / 2,
          y: (plot.top + plot.bottom) / 2,
          text: '无数据可绘制',
          anchor: Anchor.center,
          color: ChartTheme.mutedInk,
          sizePt: ChartTheme.emptyMessagePt,
        ),
      );
    }

    // 水平网格线只跟随左轴刻度。不画垂直网格 —— X 标签已经够读者定位了。
    // 右轴刻度**刻意不与左轴对齐**：给两条不同量纲的轴对齐刻度是双轴图最典型的欺骗手法。
    final gridLines = model.tempAxis.ticks.map((v) {
      final y = model.tempAxis.yOf(v, plot);
      return Line(plot.left, y, plot.right, y);
    }).toList();

    final series = <SeriesPlan>[
      SeriesPlan(
        points: _toPlotSpace(model.tempSamples, plot, model.tempAxis),
        color: ChartTheme.tempLine,
        dashed: false,
        widthPt: ChartTheme.seriesWidthPt,
      ),
    ];
    final humAxis = model.humAxis;
    if (humAxis != null) {
      series.add(
        SeriesPlan(
          points: _toPlotSpace(model.humSamples, plot, humAxis),
          color: ChartTheme.humLine,
          // 虚线不是装饰：蓝橙两色转灰度后只差 18/255，
          // 黑白打印时线型是唯一的第二编码通道。
          dashed: true,
          widthPt: ChartTheme.seriesWidthPt,
        ),
      );
    }

    final thresholdLines = <Line>[];
    final thresholdLabels = <TextAt>[];
    for (final t in model.thresholds) {
      // 荒谬阈值（用户敲了 9999）已被 AxisRangePolicy 挡在轴外，
      // 对应说明文字由 note 承担。画在轴外只会是一条贴着边框的假线。
      if (t.valueDisplay < model.tempAxis.minValue ||
          t.valueDisplay > model.tempAxis.maxValue) {
        continue;
      }
      final y = model.tempAxis.yOf(t.valueDisplay, plot);
      thresholdLines.add(Line(plot.left, y, plot.right, y));
      thresholdLabels.add(
        TextAt(
          x: plot.right - 2,
          y: y - 3,
          text: t.label,
          anchor: Anchor.right,
          color: t.color,
          sizePt: ChartTheme.thresholdLabelPt,
        ),
      );
    }

    final yLabelsLeft = model.tempAxis.ticks.map((v) {
      return TextAt(
        x: plot.left - ChartLayout.scaleLabelOffsetPt,
        y: model.tempAxis.yOf(v, plot) + ChartTheme.axisLabelPt / 3,
        text: _formatTick(v, model.tempAxis.decimals),
        anchor: Anchor.right,
        color: ChartTheme.labelInk,
        sizePt: ChartTheme.axisLabelPt,
      );
    }).toList();

    final humAxisForLabels = model.humAxis;
    final yLabelsRight = humAxisForLabels == null
        ? <TextAt>[]
        : humAxisForLabels.ticks.map((v) {
            return TextAt(
              x: plot.right + ChartLayout.scaleLabelOffsetPt,
              y: humAxisForLabels.yOf(v, plot) + ChartTheme.axisLabelPt / 3,
              text: _formatTick(v, humAxisForLabels.decimals),
              anchor: Anchor.left,
              // 染成湿度线同色，读者才不会误认哪条线读哪个轴
              color: ChartTheme.humLine,
              sizePt: ChartTheme.axisLabelPt,
            );
          }).toList();

    final xLabels = model.xTicks.map((t) {
      return TextAt(
        x: plot.left + t.ratio * plot.width,
        y: plot.bottom + 11,
        text: t.label,
        anchor: t.anchor,
        color: ChartTheme.mutedInk,
        sizePt: ChartTheme.axisLabelPt,
      );
    }).toList();

    // 图例从 series 派生，而不是另写一份颜色和线型。
    // 两份常量可以各说各话 —— 曲线改成实线而图例还标着虚线，
    // 在黑白打印时等于把读者唯一的区分依据弄丢。
    final seriesNames = <String>[
      '温度 (${model.tempUnitSymbol})',
      '湿度 (%RH)',
    ];
    final legend = <LegendItem>[];
    for (var i = 0; i < series.length; i++) {
      final s = series[i];
      legend.add(
        LegendItem(
          color: s.color,
          dashed: s.dashed,
          text: i < seriesNames.length ? seriesNames[i] : '',
        ),
      );
    }

    return RenderPlan(
      plot: plot,
      gridLines: gridLines,
      frameLines: frame,
      series: series,
      thresholdLines: thresholdLines,
      thresholdLabels: thresholdLabels,
      yLabelsLeft: yLabelsLeft,
      yLabelsRight: yLabelsRight,
      xLabels: xLabels,
      axisTitles: titles,
      legend: legend,
      note: model.note,
      emptyMessage: null,
    );
  }

  // ---------- 内部 ----------

  static List<TextAt> _axisTitles(ChartModel model, PlotRect plot) {
    final cy = (plot.top + plot.bottom) / 2;
    final out = <TextAt>[
      TextAt(
        x: plot.left - ChartLayout.axisTitleOffsetPt,
        y: cy,
        text: '温度 (${model.tempUnitSymbol})',
        anchor: Anchor.center,
        color: ChartTheme.titleInk,
        sizePt: ChartTheme.axisTitlePt,
        bold: true,
        rotateDeg: -90,
      ),
    ];
    if (model.showHumidity) {
      out.add(
        TextAt(
          x: plot.right + ChartLayout.axisTitleOffsetPt,
          y: cy,
          text: '湿度 (%RH)',
          anchor: Anchor.center,
          color: ChartTheme.titleInk,
          sizePt: ChartTheme.axisTitlePt,
          bold: true,
          // +90（自上而下），与左轴的 −90 镜像。
          // 两个字身都朝版心外侧，右侧标题才不会贴到刻度标签上。
          rotateDeg: 90,
        ),
      );
    }
    return out;
  }

  static List<ThresholdSpec> _buildThresholds(
    double? loC,
    double? hiC,
    TemperatureDisplay display,
  ) {
    final out = <ThresholdSpec>[];
    if (loC != null) {
      final v = display.toDisplay(loC);
      out.add(
        ThresholdSpec(
          valueDisplay: v,
          label: '下限 ${_formatOneDecimal(v)}${display.symbol}',
          color: ChartTheme.threshold,
        ),
      );
    }
    if (hiC != null) {
      final v = display.toDisplay(hiC);
      out.add(
        ThresholdSpec(
          valueDisplay: v,
          label: '上限 ${_formatOneDecimal(v)}${display.symbol}',
          color: ChartTheme.threshold,
        ),
      );
    }
    return out;
  }

  static String? _buildNote(
    AxisRange tempRange,
    AxisRange? humRange,
    int tMin,
    int tMax,
  ) {
    final parts = <String>[];
    for (final item in tempRange.outOfRangeThresholds) {
      parts.add('$item 超出量程，未在图上绘制');
    }

    if (humRange == null) {
      // 设备不上报湿度时画一条贴底直线是在骗人，明说更好
      parts.add('无湿度数据');
    } else if (AxisRangePolicy.needsZoomNote(humRange)) {
      // 不同 PDF 的湿度轴不可直接比较，必须让读者知道轴不是从 0 开始的
      parts.add(
        '湿度轴自动缩放 '
        '${_formatOneDecimal(humRange.minValue)}–'
        '${_formatOneDecimal(humRange.maxValue)} %RH',
      );
    }

    if (tMin < _saneTimestampFloor || tMax - tMin > _oneYearSec) {
      parts.add('检测到异常时间戳，请检查设备时钟');
    }
    return parts.isEmpty ? null : parts.join('　');
  }

  /// 采样序列 → 绘图区绝对坐标（交错 `[x,y,x,y,...]`）。
  static Float64List _toPlotSpace(
    SampleArray samples,
    PlotRect plot,
    AxisScale axis,
  ) {
    final out = Float64List(samples.length);
    var i = 0;
    while (i < samples.length) {
      out[i] = plot.left + samples[i].clamp(0.0, 1.0).toDouble() * plot.width;
      out[i + 1] = axis.yOf(samples[i + 1], plot);
      i += 2;
    }
    return out;
  }

  static AxisScale _toAxisScale(AxisRange range) {
    final step =
        range.ticks.length >= 2 ? range.ticks[1] - range.ticks[0] : (range.maxValue - range.minValue);
    return AxisScale(
      minValue: range.minValue,
      maxValue: math.max(range.maxValue, range.minValue + 1e-3),
      step: step,
      ticks: range.ticks,
      decimals: range.decimals,
    );
  }

  static String _formatTick(double v, int decimals) =>
      v.toStringAsFixed(decimals);

  static String _formatOneDecimal(double v) => v.toStringAsFixed(1);

  static double? _finiteOrNull(double? v) =>
      (v != null && v.isFinite) ? v : null;
}
