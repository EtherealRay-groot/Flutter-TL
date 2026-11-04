import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:tl_app/core/chart/downsampler.dart';

void main() {
  /// 真实量级的 epoch 秒，用来暴露单精度浮点精度坍塌（1.7e9 超出其尾数分辨率）。
  const epochStart = 1700000000.0;

  List<double> xsOf(int n, {double stepSec = 60.0}) =>
      List<double>.generate(n, (i) => epochStart + i * stepSec);

  List<double> flatY(int n, double v) => List<double>.filled(n, v);

  void assertStrictlyAscending(List<int> indices) {
    for (var i = 1; i < indices.length; i++) {
      expect(
        indices[i - 1] < indices[i],
        isTrue,
        reason: '索引必须严格升序：$i 处 ${indices[i - 1]} >= ${indices[i]}',
      );
    }
  }

  // ---------- 退化规模 ----------

  test('lttb_emptyInput_returnsEmpty', () {
    expect(
      Downsampler.lttbIndices(<double>[], <double>[], 100).length,
      0,
    );
  });

  test('lttb_singlePoint_returnsThatPoint', () {
    expect(
      Downsampler.lttbIndices(xsOf(1), flatY(1, 25), 100),
      equals(<int>[0]),
    );
  });

  test('lttb_twoPoints_returnBoth', () {
    expect(
      Downsampler.lttbIndices(xsOf(2), flatY(2, 25), 100),
      equals(<int>[0, 1]),
    );
  });

  test('lttb_fewerPointsThanTarget_returnsAllIndices', () {
    const n = 50;
    expect(
      Downsampler.lttbIndices(xsOf(n), flatY(n, 25), 100),
      equals(List<int>.generate(n, (i) => i)),
    );
  });

  test('lttb_targetBelowThree_doesNotCrash', () {
    expect(
      Downsampler.lttbIndices(xsOf(100), flatY(100, 25), 2).length <= 2,
      isTrue,
    );
  });

  // ---------- 基本契约 ----------

  test('lttb_alwaysKeepsFirstAndLastPoint', () {
    const n = 5000;
    final idx = Downsampler.lttbIndices(xsOf(n), flatY(n, 25), 300);
    expect(idx.first, 0, reason: '首点必须保留，否则曲线起点会凭空位移');
    expect(idx.last, n - 1, reason: '末点必须保留，否则曲线终点会凭空位移');
  });

  test('lttb_outputIsStrictlyAscendingAndDeduplicated', () {
    const n = 10000;
    final ys = List<double>.generate(
      n,
      (i) => math.sin(i / 100.0) * 20 + 25.0,
    );
    final idx = Downsampler.lttbIndices(xsOf(n), ys, 500);
    assertStrictlyAscending(idx);
  });

  test('lttb_respectsTheTargetCount', () {
    const n = 60000;
    final idx = Downsampler.lttbIndices(xsOf(n), flatY(n, 25), 894);
    expect(idx.length <= 894, isTrue,
        reason: '目标 894 点，实际给了 ${idx.length} 点');
  });

  test('lttb_isDeterministic', () {
    const n = 10000;
    final ys = List<double>.generate(
      n,
      (i) => math.sin(i / 50.0) * 15 + 25.0,
    );
    expect(
      Downsampler.lttbIndices(xsOf(n), ys, 400),
      equals(Downsampler.lttbIndices(xsOf(n), ys, 400)),
    );
  });

  // ---------- 核心保证：报警尖峰绝不能被采样丢掉 ----------

  /// 这是一份报警合规报告。等距抽样（65535→894 时步长是 73）
  /// 会把任何持续不到 73 个采样点的尖峰整段丢掉 —— 那是正确性事故，不是美观问题。
  /// 保留下来的点在原数据里对应的最大/最小值。
  double retainedMax(List<double> ys, List<int> idx) =>
      idx.map((i) => ys[i]).reduce(math.max);

  double retainedMin(List<double> ys, List<int> idx) =>
      idx.map((i) => ys[i]).reduce(math.min);

  test('lttb_preservesANarrowSpikeBuriedInSixtyThousandFlatPoints', () {
    const n = 60000;
    final ys = flatY(n, 25);
    // 刻意避开等距抽样会命中的下标：60000/894 的步长是 67.1141，
    // 447 步正好落在 30000 上。若尖峰放在 30000，这条测试连天真的等距抽样
    // 都抓不住，等于白测。
    const spikeAt = 30037;
    ys[spikeAt - 1] = 80.0;
    ys[spikeAt] = 80.0;
    ys[spikeAt + 1] = 80.0;

    final idx = Downsampler.lttbIndices(xsOf(n), ys, 894);
    expect(
      retainedMax(ys, idx),
      closeTo(80.0, 1e-6),
      reason: '3 个点宽的报警尖峰被降采样削掉了 —— 峰值必须原样留在图上',
    );
    expect(
      idx.any((it) => (it - spikeAt).abs() <= 2),
      isTrue,
      reason: '尖峰虽然保住了峰值，但被搬到了别的位置'
          '（最近的点距尖峰 ${idx.map((it) => (it - spikeAt).abs()).reduce(math.min)}）',
    );
  });

  test('lttb_preservesMultipleSpikesAcrossTheSeries', () {
    const n = 60000;
    final ys = flatY(n, 25);
    final spikes = <int>[5000, 20000, 33333, 55000];
    for (final s in spikes) {
      ys[s] = 79.0;
    }

    final idx = Downsampler.lttbIndices(xsOf(n), ys, 894);
    for (final s in spikes) {
      expect(
        idx.any((it) => it >= s - 70 && it <= s + 70 && ys[it] >= 79.0),
        isTrue,
        reason: '下标 $s 附近的尖峰被丢掉了 —— 报了警的时间段在图上却看不见',
      );
    }
  });

  test('lttb_preservesADeepValleyToo', () {
    const n = 60000;
    final ys = flatY(n, 25);
    const dipAt = 12345;
    ys[dipAt] = -29.0;

    final idx = Downsampler.lttbIndices(xsOf(n), ys, 894);
    expect(
      retainedMin(ys, idx),
      closeTo(-29.0, 1e-6),
      reason: '低温谷被削平了 —— 低于下限的报警同样必须留在图上',
    );
  });

  test('lttb_flatDataStillProducesASanePointCount', () {
    const n = 60000;
    final idx = Downsampler.lttbIndices(xsOf(n), flatY(n, 25), 894);
    expect(idx.length >= 3, isTrue);
    assertStrictlyAscending(idx);
  });

  // ---------- 极值注入 ----------

  test('injectExtremes_addsGlobalMinAndMax', () {
    final ys = <double>[25.0, 24.0, 88.0, 25.0, -5.0, 25.0];
    final out = Downsampler.injectExtremes(<int>[0, 5], ys, <double>[]);
    expect(out.contains(2), isTrue, reason: '全局最大值下标 2 未被注入');
    expect(out.contains(4), isTrue, reason: '全局最小值下标 4 未被注入');
  });

  test('injectExtremes_resultStaysSortedAndUnique', () {
    final ys = <double>[25.0, 88.0, 24.0, 25.0, -5.0];
    final out = Downsampler.injectExtremes(<int>[0, 4, 2], ys, <double>[]);
    assertStrictlyAscending(out);
  });

  test('injectExtremes_keepsTheOnsetOfAThresholdCrossing', () {
    // 前 50 点 20℃，之后升到 40℃ 并保持，再降回 20℃
    final ys = List<double>.filled(150, 0);
    for (var i = 0; i < 150; i++) {
      if (i < 50) {
        ys[i] = 20.0;
      } else if (i < 100) {
        ys[i] = 40.0;
      } else {
        ys[i] = 20.0;
      }
    }
    // 只保留首尾，模拟把越限区间整段抽掉的情况
    final out =
        Downsampler.injectExtremes(<int>[0, 149], ys, <double>[30]);

    final crossings = out
        .where((i) =>
            i > 0 && i < ys.length && (ys[i - 1] - 30.0) * (ys[i] - 30.0) < 0.0)
        .toList();
    expect(
      crossings.isNotEmpty,
      isTrue,
      reason: '30℃ 阈值的越限起点/终点没有被保留，报警区间在图上看不出来'
          '（保留了下标 $out）',
    );
  });

  test('injectExtremes_noThresholds_stillInjectsMinMaxOnly', () {
    final ys = <double>[1.0, 2.0, 3.0];
    final out = Downsampler.injectExtremes(<int>[1], ys, <double>[]);
    expect(out, equals(<int>[0, 1, 2]));
  });

  // ---------- 双序列并集 ----------

  test('selectIndices_preservesSpikesFromBothSeries', () {
    const n = 60000;
    final temp = flatY(n, 25);
    final hum = flatY(n, 50);
    const tempSpike = 10000;
    const humSpike = 40000;
    temp[tempSpike] = 80.0;
    hum[humSpike] = 99.0;

    final idx = Downsampler.selectIndices(xsOf(n), temp, hum, 894);
    expect(idx.any((it) => it == tempSpike), isTrue, reason: '温度尖峰丢失');
    expect(
      idx.any((it) => it == humSpike),
      isTrue,
      reason: '湿度尖峰丢失 —— 若把温度的采样点直接套用到两条曲线，'
          '湿度自己的波动就会被抹掉',
    );
  });

  test('selectIndices_outputIsSortedAndUnique', () {
    const n = 20000;
    final temp =
        List<double>.generate(n, (i) => math.sin(i / 70.0) * 10 + 25);
    final hum =
        List<double>.generate(n, (i) => math.cos(i / 33.0) * 15 + 50);
    assertStrictlyAscending(Downsampler.selectIndices(xsOf(n), temp, hum, 600));
  });

  test('selectIndices_staysUnderTheSafetyCeiling', () {
    const n = 65535;
    final temp =
        List<double>.generate(n, (i) => math.sin(i / 13.0) * 10 + 25);
    final hum =
        List<double>.generate(n, (i) => math.cos(i / 7.0) * 20 + 50);
    final idx =
        Downsampler.selectIndices(xsOf(n), temp, hum, 894, maxTotal: 2500);
    expect(idx.length <= 2500, isTrue,
        reason: '并集膨胀到 ${idx.length} 点，超出上限');
  });

  test('selectIndices_neverReturnsEmptyForNonEmptyInput', () {
    expect(
      Downsampler.selectIndices(
        xsOf(500),
        flatY(500, 25),
        flatY(500, 50),
        100,
      ).isNotEmpty,
      isTrue,
    );
  });

  test('selectIndices_bothSeriesIdentical_doesNotDuplicateIndices', () {
    const n = 10000;
    final ys =
        List<double>.generate(n, (i) => math.sin(i / 90.0) * 12 + 25);
    final idx = Downsampler.selectIndices(xsOf(n), ys, ys, 500);
    assertStrictlyAscending(idx);
  });

  // ---------- 精度：必须用 double 处理 epoch 秒 ----------

  /// epoch 秒约 1.7e9，单精度浮点尾数只有 24 位（分辨率约 1.7e7），
  /// 相邻记录的时间戳会被舍入成同一个值 —— X 轴直接塌掉。
  /// 这里断言在 epoch 量级下相邻点仍能被区分。
  test('lttb_atEpochScale_stillDistinguishesAdjacentPoints', () {
    const n = 2000;
    final xs = xsOf(n);
    final ys = List<double>.generate(n, (i) => i == 1000 ? 80.0 : 25.0);
    final idx = Downsampler.lttbIndices(xs, ys, 300);
    expect(
      idx.any((it) => (it - 1000).abs() <= 2 && ys[it] >= 79.0),
      isTrue,
      reason: 'epoch 量级下尖峰被算丢了，说明内部把时间轴降成了单精度',
    );
  });
}
