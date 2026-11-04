import 'package:test/test.dart';
import 'package:tl_app/core/chart/axis_range_policy.dart';

void main() {
  const celsius = TemperatureDisplay.celsius;
  const fahrenheit = TemperatureDisplay.fahrenheit;

  // ---------- 无阈值：轴范围就是设备量程 -30~85 ----------

  test('temperature_withoutThresholds_usesFullDeviceRange', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26,
      thresholdLowC: null,
      thresholdHighC: null,
      display: celsius,
    );
    expect(r.minValue, closeTo(-30, 1e-4));
    expect(r.maxValue, closeTo(85, 1e-4));
  });

  test('temperature_withoutThresholds_ticksAreRoundValuesInsideTheRange', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26,
      thresholdLowC: null,
      thresholdHighC: null,
      display: celsius,
    );
    expect(r.ticks, equals(<double>[-20, 0, 20, 40, 60, 80]));
  });

  // ---------- 有阈值：紧贴数据并画阈值线 ----------

  test('temperature_withThresholds_tracksTheDataInsteadOfTheDeviceRange', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26,
      thresholdLowC: 20,
      thresholdHighC: 30,
      display: celsius,
    );
    expect(r.maxValue - r.minValue < 40, isTrue,
        reason: '轴不该再撑满设备量程，实测 [${r.minValue}, ${r.maxValue}]');
    expect(20 >= r.minValue && 20 <= r.maxValue, isTrue);
    expect(30 >= r.minValue && 30 <= r.maxValue, isTrue);
  });

  test('temperature_singleSidedLowThreshold_isHonored', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26,
      thresholdLowC: 15,
      thresholdHighC: null,
      display: celsius,
    );
    expect(15 >= r.minValue && 15 <= r.maxValue, isTrue,
        reason: '下限阈值 15 未纳入轴范围 [${r.minValue}, ${r.maxValue}]');
    expect(26 >= r.minValue && 26 <= r.maxValue, isTrue);
  });

  test('temperature_singleSidedHighThreshold_isHonored', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26,
      thresholdLowC: null,
      thresholdHighC: 45,
      display: celsius,
    );
    expect(45 >= r.minValue && 45 <= r.maxValue, isTrue,
        reason: '上限阈值 45 未纳入轴范围 [${r.minValue}, ${r.maxValue}]');
    expect(22 >= r.minValue && 22 <= r.maxValue, isTrue);
  });

  // ---------- 绝不裁掉数据 ----------

  test('temperature_neverClipsDataEvenOutsideTheDeviceRange', () {
    final r = AxisRangePolicy.temperature(
      dataMin: -50,
      dataMax: 120,
      thresholdLowC: null,
      thresholdHighC: null,
      display: celsius,
    );
    expect(r.minValue <= -50, isTrue, reason: '数据低于设备量程被裁掉了');
    expect(r.maxValue >= 120, isTrue, reason: '数据高于设备量程被裁掉了');
  });

  test('temperature_neverClipsDataWhenThresholdsAreSet', () {
    final r = AxisRangePolicy.temperature(
      dataMin: -5,
      dataMax: 40,
      thresholdLowC: 0,
      thresholdHighC: 10,
      display: celsius,
    );
    expect(r.minValue <= -5, isTrue);
    expect(r.maxValue >= 40, isTrue);
  });

  /// 性质测试：任意组合下，数据与阈值都必须落在轴内。
  test('temperature_neverClipsDataOrThresholds_acrossManyCombinations', () {
    final dataRanges = <(double, double)>[
      (-40, 90),
      (22, 26),
      (25, 25),
      (-50, 120),
      (0, 0),
      (60, 60),
    ];
    final thresholds = <(double?, double?)>[
      (null, null),
      (0, null),
      (null, 100),
      (-10, 10),
      (30, 30),
      (25, 25),
    ];
    for (final display in <TemperatureDisplay>[celsius, fahrenheit]) {
      for (final data in dataRanges) {
        final dMin = data.$1;
        final dMax = data.$2;
        for (final threshold in thresholds) {
          final lo = threshold.$1;
          final hi = threshold.$2;
          final r = AxisRangePolicy.temperature(
            dataMin: dMin,
            dataMax: dMax,
            thresholdLowC: lo,
            thresholdHighC: hi,
            display: display,
          );
          final ctx =
              'display=$display data=[$dMin,$dMax] thr=[$lo,$hi] '
              'axis=[${r.minValue},${r.maxValue}]';
          expect(
            r.minValue <= display.toDisplay(dMin) + 1e-3,
            isTrue,
            reason: '数据下界被裁：$ctx',
          );
          expect(
            r.maxValue >= display.toDisplay(dMax) - 1e-3,
            isTrue,
            reason: '数据上界被裁：$ctx',
          );
          if (lo != null) {
            expect(
              r.minValue <= display.toDisplay(lo) + 1e-3,
              isTrue,
              reason: '阈值下界被裁：$ctx',
            );
          }
          if (hi != null) {
            expect(
              r.maxValue >= display.toDisplay(hi) - 1e-3,
              isTrue,
              reason: '阈值上界被裁：$ctx',
            );
          }
          expect(r.maxValue > r.minValue, isTrue, reason: '轴跨度必须为正：$ctx');
        }
      }
    }
  });

  // ---------- 阈值远超量程（用户敲错 9999） ----------

  test('temperature_absurdThresholdDoesNotFlattenTheCurve', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26,
      thresholdLowC: null,
      thresholdHighC: 9999,
      display: celsius,
    );
    expect(r.maxValue - r.minValue < 460, isTrue,
        reason: '9999 的阈值把正常曲线压成了贴底直线');
    expect(22 >= r.minValue && 22 <= r.maxValue, isTrue, reason: '数据仍须完整可见');
    expect(26 >= r.minValue && 26 <= r.maxValue, isTrue, reason: '数据仍须完整可见');
  });

  test('temperature_absurdThreshold_isReportedToTheReaderNotSilentlyDropped', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26,
      thresholdLowC: null,
      thresholdHighC: 9999,
      display: celsius,
    );
    expect(r.outOfRangeThresholds.isNotEmpty, isTrue,
        reason: '阈值未绘制时必须留下说明，否则等于对读者撒谎说阈值已生效');
  });

  // ---------- 退化跨度 ----------

  test('temperature_singleRecord_getsAVisibleSpan', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 25,
      dataMax: 25,
      thresholdLowC: null,
      thresholdHighC: null,
      display: celsius,
    );
    expect(r.maxValue > r.minValue, isTrue);
  }, timeout: const Timeout(Duration(seconds: 2)));

  test('temperature_constantTemperatureWithThresholdEqual_toData_getsAVisibleSpan',
      () {
    final r = AxisRangePolicy.temperature(
      dataMin: 25,
      dataMax: 25,
      thresholdLowC: 25,
      thresholdHighC: 25,
      display: celsius,
    );
    expect(r.maxValue > r.minValue, isTrue);
    expect(25 >= r.minValue && 25 <= r.maxValue, isTrue);
  }, timeout: const Timeout(Duration(seconds: 2)));

  // ---------- 华氏换算 ----------

  test('temperature_fahrenheit_usesConvertedDeviceRange', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26,
      thresholdLowC: null,
      thresholdHighC: null,
      display: fahrenheit,
    );
    // -30℃ → -22℉，85℃ → 185℉。绝不能把 -30~85 原样标成 ℉。
    expect(r.minValue <= -22, isTrue,
        reason: '℉ 模式下轴下界应是换算后的 -22.0，实测 ${r.minValue}');
    expect(r.maxValue >= 185, isTrue,
        reason: '℉ 模式下轴上界应是换算后的 185.0，实测 ${r.maxValue}');
    expect(r.minValue, closeTo(-22, 1e-3));
    expect(r.maxValue, closeTo(185, 1e-3));
  });

  test('temperature_fahrenheit_convertsThresholdsToo', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 22,
      dataMax: 26, // ℃
      thresholdLowC: 0,
      thresholdHighC: 30,
      display: fahrenheit,
    );
    expect(32 >= r.minValue && 32 <= r.maxValue, isTrue,
        reason: '0℃ 的阈值线应出现在 32℉');
    expect(86 >= r.minValue && 86 <= r.maxValue, isTrue,
        reason: '30℃ 的阈值线应出现在 86℉');
  });

  test('temperature_fahrenheit_dataIsConvertedBeforeComputingTheRange', () {
    final r = AxisRangePolicy.temperature(
      dataMin: 100,
      dataMax: 100, // ℃，恒温 100℃ = 212℉
      thresholdLowC: null,
      thresholdHighC: null,
      display: fahrenheit,
    );
    expect(212 >= r.minValue && 212 <= r.maxValue, isTrue,
        reason: '212℉ 必须落在轴内，实测 [${r.minValue}, ${r.maxValue}]');
  });

  // ---------- 湿度轴 ----------

  test('humidity_zoomsInOnTheDataInsteadOfAlwaysSpanningZeroToHundred', () {
    final r = AxisRangePolicy.humidity(45, 62)!;
    expect(r.maxValue - r.minValue < 100, isTrue,
        reason: '湿度常年 45~62% 时固定 0-100 会把曲线压成直线');
    expect(r.minValue <= 45 && r.maxValue >= 62, isTrue);
  });

  test('humidity_enforcesAMinimumSpanSoQuantisationNoiseIsNotAmplified', () {
    // 数据只有 0.5 个百分点波动，轴若紧贴数据会把量化噪声放大成大起大落
    final r = AxisRangePolicy.humidity(50, 51)!;
    expect(r.maxValue - r.minValue >= 20, isTrue,
        reason: '50~51% 的轴跨度只有 ${r.maxValue - r.minValue}，量化噪声被放大了');
  });

  test('humidity_staysWithinZeroToHundred', () {
    for (final pair in <(int, int)>[
      (45, 62),
      (0, 0),
      (100, 100),
      (0, 100),
      (98, 100),
      (0, 3),
      (95, 96),
    ]) {
      final lo = pair.$1;
      final hi = pair.$2;
      final r = AxisRangePolicy.humidity(lo, hi);
      if (r == null) continue; // 0 to 0 走"无湿度"分支
      expect(r.minValue >= -1e-3, isTrue,
          reason: '[$lo,$hi] 的轴下界 ${r.minValue} 越界');
      expect(r.maxValue <= 100 + 1e-3, isTrue,
          reason: '[$lo,$hi] 的轴上界 ${r.maxValue} 越界');
      expect(r.maxValue > r.minValue, isTrue,
          reason: '[$lo,$hi] 的轴跨度非正');
    }
  });

  test('humidity_allZero_isReportedAsMissingRatherThanDrawnFlatOnTheFloor', () {
    expect(
      AxisRangePolicy.humidity(0, 0),
      isNull,
      reason: '湿度恒为 0 说明设备不上报湿度，画一条贴底直线会让人误以为环境极干燥',
    );
  });

  test('humidity_allHundred_isStillMeaningful', () {
    expect(AxisRangePolicy.humidity(100, 100), isNotNull,
        reason: '100% 是合法读数，不能当成缺失');
  });

  test('humidity_normalRange_isKept', () {
    final r = AxisRangePolicy.humidity(30, 90)!;
    expect(r.minValue <= 30 && r.maxValue >= 90, isTrue);
    expect(r.maxValue <= 100, isTrue);
  });

  // ---------- 轴是否从 0 开始（决定要不要给读者加注释） ----------

  test('humidity_fullRange_needsNoReaderNote', () {
    final r = AxisRangePolicy.humidity(0, 100)!;
    expect(AxisRangePolicy.needsZoomNote(r), isFalse,
        reason: '轴恰好 0-100 时不该多嘴');
  });

  test('humidity_zoomedRange_needsAReaderNote', () {
    final r = AxisRangePolicy.humidity(45, 62)!;
    expect(AxisRangePolicy.needsZoomNote(r), isTrue,
        reason: '轴不从 0 开始时必须告知读者');
  });
}
