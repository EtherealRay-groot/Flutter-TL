import 'dart:math' as math;

import 'axis_scale.dart';

/// 温度显示单位。**只影响显示，不影响存储与比较** ——
/// 见 [AxisRangePolicy] 顶部关于阈值单位约定（按 ℃ 解释）的说明。
enum TemperatureDisplay {
  celsius('℃'),
  fahrenheit('℉');

  const TemperatureDisplay(this.symbol);

  final String symbol;

  double toDisplay(double celsius) =>
      this == TemperatureDisplay.fahrenheit ? celsius * 9 / 5 + 32 : celsius;

  /// 显示单位 → 原始 ℃。用于把用户输入的阈值换算回存储单位。
  double toCelsius(double display) =>
      this == TemperatureDisplay.fahrenheit ? (display - 32) * 5 / 9 : display;
}

/// 一条数值轴的最终范围 + 刻度。
class AxisRange {
  const AxisRange({
    required this.minValue,
    required this.maxValue,
    required this.ticks,
    required this.decimals,
    this.outOfRangeThresholds = const <String>[],
  });

  final double minValue;
  final double maxValue;
  final List<double> ticks;
  final int decimals;

  /// 因超出量程而未绘制到图上的阈值描述，用于在图下方给读者加说明。
  final List<String> outOfRangeThresholds;

  @override
  bool operator ==(Object other) =>
      other is AxisRange &&
      other.minValue == minValue &&
      other.maxValue == maxValue &&
      _listEquals(other.ticks, ticks) &&
      other.decimals == decimals &&
      _listEquals(other.outOfRangeThresholds, outOfRangeThresholds);

  @override
  int get hashCode => Object.hash(
        minValue,
        maxValue,
        Object.hashAll(ticks),
        decimals,
        Object.hashAll(outOfRangeThresholds),
      );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 决定两条纵轴的范围。
///
/// ## 阈值一律按 ℃ 解释
/// 现有的报警判定（`BluetoothLeViewModel` 的 `alarmCount` 与表格红字）
/// 都是把 `alarmThresholdLow/High` 解析后**直接与原始 ℃ 比较**。
/// 图表必须与它们保持一致，否则阈值线位置、表格红字、报警条数会互相矛盾。
/// 所以这里入参一律收 ℃，只在内部换算成显示单位。
///
/// ## 温度轴：-30~85 是设备量程，不是裁剪边界
/// 轴只扩大，从不收缩。无阈值时轴范围精确取设备量程；有阈值时紧贴数据并纳入阈值。
abstract final class AxisRangePolicy {
  /// 设备量程（℃），与报告里打印的"测量范围：-30~85°"一致。
  static const double deviceMinC = -30;
  static const double deviceMaxC = 85;

  /// 湿度轴最小跨度（百分点）。防止把量化噪声放大成假的剧烈波动。
  static const double humidityMinSpan = 20;

  /// 当阈值荒谬到把正常曲线压成一条直线时的容忍上限（显示单位）。
  /// 460 相当于设备跨度 115 的 4 倍，足够宽容，不会误伤合法的宽量程场景。
  static const double _absurdSpan = 460;

  static const int _tempTicks = 5;

  static AxisRange temperature({
    required double dataMin,
    required double dataMax,
    required double? thresholdLowC,
    required double? thresholdHighC,
    required TemperatureDisplay display,
  }) {
    final dMin = display.toDisplay(math.min(dataMin, dataMax));
    final dMax = display.toDisplay(math.max(dataMin, dataMax));
    final deviceMin = display.toDisplay(deviceMinC);
    final deviceMax = display.toDisplay(deviceMaxC);

    final loC = _finiteOrNull(thresholdLowC);
    final hiC = _finiteOrNull(thresholdHighC);
    final lo = loC == null ? null : display.toDisplay(loC);
    final hi = hiC == null ? null : display.toDisplay(hiC);
    final hasThreshold = lo != null || hi != null;

    // 1. 基底：无阈值 → 设备量程；有阈值 → 数据范围
    var min = hasThreshold ? math.min(dMin, dMax) : deviceMin;
    var max = hasThreshold ? math.max(dMin, dMax) : deviceMax;

    // 2. 无条件并入数据 —— 数据超出设备量程时轴只扩大，不裁剪
    min = math.min(min, math.min(dMin, dMax));
    max = math.max(max, math.max(dMin, dMax));

    // 3. 并入已设的阈值（有几边并几边）
    if (lo != null) min = math.min(min, lo);
    if (hi != null) max = math.max(max, hi);

    // 4. 退化跨度兜底：n=1、恒温、阈值恰等于数据值
    if (max - min < 1) {
      final c = (max + min) / 2;
      min = c - 0.5;
      max = c + 0.5;
    }

    // 5. 荒谬值兜底：有人在阈值框里敲了 9999。
    //    这里选择"改画说明"而不是"静默忽略" —— 静默忽略等于对读者撒谎说阈值已生效。
    final notes = <String>[];
    if (max - min > _absurdSpan) {
      if (lo != null && lo < deviceMin) {
        notes.add('下限 ${_formatOneDecimal(lo)}${display.symbol}');
      }
      if (hi != null && hi > deviceMax) {
        notes.add('上限 ${_formatOneDecimal(hi)}${display.symbol}');
      }
      min = math.min(deviceMin, math.min(dMin, dMax));
      max = math.max(deviceMax, math.max(dMin, dMax));
    }

    // 6. 成形。两种风格略有差异，是刻意的：
    //    - 无阈值：轴端点精确停在设备量程上（-30~85），刻度只取内部的圆整值。
    //      这里**不做** nice 取整 —— 取整会把它变成 [-50,100]，把"设备量程"这个语义弄丢。
    //    - 有阈值：向外 nice 取整，让轴端点落在圆整刻度上，便于读数。
    if (!hasThreshold) {
      return AxisRange(
        minValue: min,
        maxValue: max,
        ticks: interiorTicks(min, max, _tempTicks),
        decimals: 0,
        outOfRangeThresholds: notes,
      );
    }
    final pad = (max - min) * 0.05;
    final scale = niceScale(min - pad, max + pad, _tempTicks);
    return AxisRange(
      minValue: scale.minValue,
      maxValue: scale.maxValue,
      ticks: scale.ticks,
      decimals: scale.decimals,
      outOfRangeThresholds: notes,
    );
  }

  /// 湿度轴。
  ///
  /// 采用"紧贴数据的自适应 + 20pp 最小跨度"而非固定 0–100：
  /// 真实记录里湿度常年在 45–60%，固定 0–100 会把曲线压成一条几乎看不出波动的直线，
  /// 让人误以为"一直很稳定"—— 这是另一种形式的误导。
  /// 20pp 最小跨度防的是相反方向的误导：数据只有 0.5pp 波动时，
  /// 紧贴数据的轴会把量化噪声放大成大起大落。
  ///
  /// 代价是不同 PDF 之间的湿度轴不可直接比较，因此调用方**必须**在
  /// 轴不是 0–100 时于图下方加一行灰字说明（见 [needsZoomNote]）。
  ///
  /// 恒为 0 时返回 null（设备不上报湿度），
  /// 由调用方改画"无湿度数据"——比画一条贴底直线更诚实。
  static AxisRange? humidity(int dataMin, int dataMax) {
    final lo0 = math.min(dataMin, dataMax).toDouble();
    final hi0 = math.max(dataMin, dataMax).toDouble();
    // 恒为 0 视为"设备不上报湿度"。注意恒为 100 是合法读数，不能同样对待。
    if (hi0 <= 0) return null;

    var lo = lo0;
    var hi = hi0;
    if (hi - lo < humidityMinSpan) {
      final c = (lo + hi) / 2;
      lo = c - humidityMinSpan / 2;
      hi = c + humidityMinSpan / 2;
    }
    // 先平移再夹取：直接夹取会让跨度又变得不够
    if (lo < 0) {
      hi -= lo;
      lo = 0;
    }
    if (hi > 100) {
      lo -= (hi - 100);
      hi = 100;
    }
    lo = lo.clamp(0.0, 100.0).toDouble();
    hi = hi.clamp(0.0, 100.0).toDouble();
    if (hi - lo < 1) {
      lo = 0;
      hi = 100;
    }

    final pad = (hi - lo) * 0.05;
    final scale = niceScale(
      math.max(lo - pad, 0.0),
      math.min(hi + pad, 100.0),
      4,
    );
    return AxisRange(
      minValue: scale.minValue,
      maxValue: scale.maxValue,
      ticks: scale.ticks,
      decimals: 0,
    );
  }

  /// 湿度轴不是 0–100 时，读者需要被告知轴不从 0 开始。
  static bool needsZoomNote(AxisRange range) =>
      range.minValue > 0.001 || range.maxValue < 99.999;

  static double? _finiteOrNull(double? v) =>
      (v != null && v.isFinite) ? v : null;

  static String _formatOneDecimal(double v) => v.toStringAsFixed(1);
}
