import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:tl_app/core/chart/axis_scale.dart';
import 'package:tl_app/core/chart/chart_model.dart';

void main() {
  // ---------- niceNum：结果必为 1/2/5 × 10^k ----------

  test('niceNum_resultIsAlwaysOneTwoOrFiveTimesAPowerOfTen', () {
    final inputs = <double>[
      0.7,
      1.0,
      1.4,
      1.5,
      2.0,
      2.9,
      3.0,
      3.3,
      4.9,
      5.0,
      6.9,
      7.0,
      9.9,
      12.0,
      23.0,
      33.0,
      115.0,
      460.0,
    ];
    for (final r in inputs) {
      for (final round in <bool>[true, false]) {
        final n = niceNum(r, round);
        final mantissa =
            n / math.pow(10.0, (math.log(n) / math.ln10).floor()).toDouble();
        expect(
          <double>[1.0, 2.0, 5.0, 10.0]
              .any((it) => (mantissa - it).abs() < 1e-6),
          isTrue,
          reason: 'niceNum($r, $round) = $n，尾数 $mantissa 不在 {1,2,5,10} 内',
        );
      }
    }
  });

  // ---------- 跨度为 0：绝不能死循环 ----------

  /// 恒温记录（所有温度相同）会得到 span = 0。若无防护，
  /// step 会算成 0，刻度生成退化成 `generateSequence(min) { it + 0 }`
  /// —— 永不终止，应用直接挂死。
  test('niceScale_zeroSpan_returnsUsableScaleInsteadOfHanging', () {
    final s = niceScale(5, 5, 5);
    expect(s.maxValue > s.minValue, isTrue, reason: '退化轴仍须满足 max > min');
    expect(5 >= s.minValue && 5 <= s.maxValue, isTrue,
        reason: '退化轴仍须包含原值 5');
  }, timeout: const Timeout(Duration(seconds: 2)));

  test('niceScale_nearZeroSpan_doesNotHang', () {
    final s = niceScale(25, 25 + 1e-7, 5);
    expect(s.maxValue > s.minValue, isTrue);
  }, timeout: const Timeout(Duration(seconds: 2)));

  test('niceScale_negativeDegenerateValue_doesNotHang', () {
    final s = niceScale(-30, -30, 5);
    expect(s.maxValue > s.minValue, isTrue);
    expect(-30 >= s.minValue && -30 <= s.maxValue, isTrue);
  }, timeout: const Timeout(Duration(seconds: 2)));

  // ---------- 正常范围：只扩大，不收缩 ----------

  test('niceScale_neverShrinksTheRequestedRange', () {
    final s = niceScale(-12, 47, 5);
    expect(s.minValue <= -12, isTrue,
        reason: '下界收缩了：${s.minValue} > -12');
    expect(s.maxValue >= 47, isTrue,
        reason: '上界收缩了：${s.maxValue} < 47');
  });

  test('niceScale_neverShrinksEvenForOddRanges', () {
    final ranges = <(double, double)>[
      (-12, 47),
      (-30, 85),
      (0.02, 0.87),
      (45, 62),
      (-0.5, 0.5),
    ];
    for (final range in ranges) {
      final lo = range.$1;
      final hi = range.$2;
      final s = niceScale(lo, hi, 5);
      expect(s.minValue <= lo, isTrue, reason: '[$lo,$hi] 下界被收缩');
      expect(s.maxValue >= hi, isTrue, reason: '[$lo,$hi] 上界被收缩');
    }
  });

  test('niceScale_tickCountStaysReadable', () {
    for (var target = 3; target <= 8; target++) {
      final s = niceScale(-12, 47, target);
      expect(
        s.ticks.length,
        inInclusiveRange(3, 9),
        reason: 'target=$target 时得到 ${s.ticks.length} 个刻度，不可读',
      );
    }
  });

  test('niceScale_ticksAreEvenlySpacedAndInsideTheRange', () {
    final s = niceScale(-12, 47, 5);
    expect(s.ticks.length >= 2, isTrue);
    for (final t in s.ticks) {
      expect(
        t >= s.minValue - 1e-4 && t <= s.maxValue + 1e-4,
        isTrue,
        reason: '刻度 $t 越出 [${s.minValue}, ${s.maxValue}]',
      );
    }
    for (var i = 1; i < s.ticks.length; i++) {
      expect(
        s.ticks[i] - s.ticks[i - 1],
        closeTo(s.step, 1e-3),
        reason: '刻度间距不均',
      );
    }
  });

  test('niceScale_reportsZeroDecimalsForTwentyDegreeSteps', () {
    expect(niceScale(-12, 47, 5).decimals, 0); // step = 20
  });

  /// 小数位真正的职责：让相邻刻度渲染成**不同的字符串**。
  /// 窄范围（例如恒温箱的 25.0~25.4℃）若小数位不够，整条轴会印出一排一模一样的数字。
  test('niceScale_decimalsKeepAdjacentTicksFromCollapsingToTheSameLabel', () {
    final ranges = <(double, double)>[
      (0, 2),
      (25.0, 25.4),
      (0.02, 0.09),
      (-0.3, 0.3),
      (45, 62),
      (-30, 85),
    ];
    for (final range in ranges) {
      final lo = range.$1;
      final hi = range.$2;
      final s = niceScale(lo, hi, 5);
      final labels = s.ticks.map((it) => _formatTick(it, s.decimals)).toList();
      expect(
        labels.toSet().length,
        labels.length,
        reason: '[$lo,$hi] 的刻度标签塌陷成重复字符串：$labels',
      );
    }
  });

  // ---------- interiorTicks：设备量程 -30~85 ----------

  test('interiorTicks_deviceRange_givesRoundValuesInsideTheBounds', () {
    expect(
      interiorTicks(-30, 85, 5),
      equals(<double>[-20, 0, 20, 40, 60, 80]),
    );
  });

  test('interiorTicks_areStrictlyInsideSoTheyNeverSitOnTheFrame', () {
    final ticks = interiorTicks(-30, 85, 5);
    expect(ticks.isNotEmpty, isTrue);
    expect(
      ticks.every((it) => it > -30 && it < 85),
      isTrue,
      reason: '刻度必须严格落在轴内部，否则会压在边框线上',
    );
  });

  test('interiorTicks_zeroSpan_doesNotHang', () {
    expect(interiorTicks(5, 5, 5).isEmpty, isTrue);
  }, timeout: const Timeout(Duration(seconds: 2)));

  // ---------- 值 → 像素映射 ----------

  test('yOf_mapsAxisBoundsToPlotBottomAndTop', () {
    final scale = niceScale(-30, 85, 5);
    const plot = PlotRect(left: 100, top: 200, right: 500, bottom: 400);
    expect(scale.yOf(scale.minValue, plot), closeTo(400, 1e-3),
        reason: 'minValue 应落在绘图区底边');
    expect(scale.yOf(scale.maxValue, plot), closeTo(200, 1e-3),
        reason: 'maxValue 应落在绘图区顶边');
  });

  test('yOf_midpointSitsHalfWayUp', () {
    final scale = niceScale(0, 100, 5);
    const plot = PlotRect(left: 0, top: 100, right: 100, bottom: 300);
    expect(scale.yOf(50, plot), closeTo(200, 1e-3));
  });
}

String _formatTick(double v, int decimals) => v.toStringAsFixed(decimals);
