import 'dart:math' as math;

import 'chart_model.dart';

/// 一条数值轴的刻度配置 + 值到像素的映射。
///
/// 构造函数强制 `maxValue > minValue`，把"跨度为 0 导致除零得 NaN"这一整类
/// bug 挡在类型层面 —— NaN 传进 `Path.lineTo` 会画出不可预期的结果。
class AxisScale {
  AxisScale({
    required this.minValue,
    required this.maxValue,
    required this.step,
    required this.ticks,
    required this.decimals,
  }) {
    if (!(maxValue > minValue)) {
      throw ArgumentError('AxisScale 必须满足 maxValue > minValue');
    }
  }

  final double minValue;
  final double maxValue;
  final double step;
  final List<double> ticks;
  final int decimals;

  double get span => maxValue - minValue;

  /// 值 → 绘图区 y 坐标。minValue 落在底边，maxValue 落在顶边（屏幕坐标系 y 向下）。
  double yOf(double value, PlotRect plot) =>
      plot.bottom - (value - minValue) / span * plot.height;

  @override
  bool operator ==(Object other) =>
      other is AxisScale &&
      other.minValue == minValue &&
      other.maxValue == maxValue &&
      other.step == step &&
      _listEquals(other.ticks, ticks) &&
      other.decimals == decimals;

  @override
  int get hashCode =>
      Object.hash(minValue, maxValue, step, Object.hashAll(ticks), decimals);
}

bool _listEquals(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Heckbert 的 "nice numbers" 取整：结果必为 1、2、5、10 × 10^k。
double niceNum(double range, bool round) {
  if (range <= 0.0 || !range.isFinite) return 1.0;
  final exp = _log10(range).floor();
  final f = range / math.pow(10.0, exp).toDouble();
  final double nf;
  if (round) {
    if (f < 1.5) {
      nf = 1.0;
    } else if (f < 3.0) {
      nf = 2.0;
    } else if (f < 7.0) {
      nf = 5.0;
    } else {
      nf = 10.0;
    }
  } else {
    if (f <= 1.0) {
      nf = 1.0;
    } else if (f <= 2.0) {
      nf = 2.0;
    } else if (f <= 5.0) {
      nf = 5.0;
    } else {
      nf = 10.0;
    }
  }
  return nf * math.pow(10.0, exp).toDouble();
}

double _log10(double x) => math.log(x) / math.ln10;

/// 生成一条**只向外扩大**的轴：返回的 [AxisScale.minValue] 必 ≤ 入参下界，
/// `maxValue` 必 ≥ 入参上界，因此永远不会裁掉数据。
///
/// 跨度为 0（恒温记录、单条记录）走 [degenerate] 分支。
/// 这不是防御性编程的洁癖：若无此分支，`step` 会算成 0，
/// [ticksBetween] 退化成 `while (v <= hi) v += 0` 的死循环，应用直接挂死。
AxisScale niceScale(double minV, double maxV, int targetTicks) {
  if (targetTicks < 2) {
    throw ArgumentError('刻度数至少为 2');
  }
  final lo = math.min(minV, maxV);
  final hi = math.max(minV, maxV);
  if (hi - lo < _spanEpsilon || !lo.isFinite || !hi.isFinite) {
    return _degenerate(lo);
  }

  final range = niceNum(hi - lo, false);
  final step = niceNum(range / (targetTicks - 1), true);
  if (step <= 0) return _degenerate(lo);

  final start = (lo / step).floor() * step;
  final end = (hi / step).ceil() * step;
  if (!(end > start)) return _degenerate(lo);

  return AxisScale(
    minValue: start,
    maxValue: end,
    step: step,
    ticks: _ticksBetween(start, end, step),
    decimals: _decimalsFor(step),
  );
}

/// 只生成**严格落在轴内部**的好看刻度，轴端点保持原样。
///
/// 用于"无报警阈值"时的温度轴：轴范围精确取设备量程 −30~85，
/// 刻度取 −20/0/20/40/60/80。这里刻意不做 nice 取整 ——
/// nice 取整会把 [−30, 85] 变成 [−50, 100]，等于把"设备量程"这个语义弄丢。
List<double> interiorTicks(double minV, double maxV, int targetTicks) {
  if (targetTicks < 1) {
    throw ArgumentError('刻度数至少为 1');
  }
  final lo = math.min(minV, maxV);
  final hi = math.max(minV, maxV);
  if (hi - lo < _spanEpsilon || !lo.isFinite || !hi.isFinite) {
    return <double>[];
  }

  final step = niceNum((hi - lo) / targetTicks, true);
  if (step <= 0) return <double>[];

  final eps = step * 1e-4;
  final out = <double>[];
  var k = (lo / step).floor();
  // 循环上限只是死循环的兜底，正常范围最多迭代十几次
  var guard = 0;
  while (guard++ < _maxTicks) {
    final v = k * step;
    if (v > hi - eps) break;
    if (v > lo + eps) out.add(v);
    k++;
  }
  return out;
}

// ---------- 内部 ----------

const double _spanEpsilon = 1e-6;
const int _maxTicks = 10000;

List<double> _ticksBetween(double start, double end, double step) {
  final out = <double>[];
  var k = 0;
  while (k < _maxTicks) {
    final v = start + step * k;
    if (v > end + step * 1e-4) break;
    out.add(v);
    k++;
  }
  return out;
}

/// 跨度为 0 时的兜底轴：以该值为中心撑开一个可见区间。
/// 温度量级很小，绝对 padding 足够；`abs(v) * 1e-4` 只是防极端值把区间撑成单点。
AxisScale _degenerate(double v) {
  final center = v.isFinite ? v : 0.0;
  final half = math.max(1.0, center.abs() * 1e-4);
  return AxisScale(
    minValue: center - half,
    maxValue: center + half,
    step: half,
    ticks: <double>[center - half, center, center + half],
    decimals: _decimalsFor(half),
  );
}

int _decimalsFor(double step) {
  if (step >= 1) return 0;
  if (step >= 0.1) return 1;
  if (step >= 0.01) return 2;
  return 3;
}
