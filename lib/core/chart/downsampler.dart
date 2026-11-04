import 'dart:math' as math;

/// 把最多 65535 条记录降到绘制区能表现的点数。
///
/// ## 为什么必须用 LTTB 而不是等距抽样
/// 绘图区宽约 447pt，目标约 894 点，即从 65535 降到 894。等距抽样的步长是 73 ——
/// **任何持续不到 73 个采样点的报警尖峰会被整段丢掉**。
/// 这是一份报警合规报告，漏掉尖峰是正确性事故，不是美观问题。
/// 均值分桶的问题相反：它把尖峰削平成一个假的缓坡。
/// LTTB（Largest-Triangle-Three-Buckets）的设计目标恰好是"在给定点数下最大化保留视觉轮廓"。
///
/// ## 必须用 double 承载时间轴
/// epoch 秒约 1.7e9，单精度浮点尾数只有 24 位（分辨率约 1.7e7），
/// 相邻记录的时间戳会被舍入成同一个值，X 轴直接塌掉。
/// 因此 [xs] 一律是 `double`，并且内部绝不把它降成单精度再比较。
abstract final class Downsampler {
  /// 双序列并集超过这个点数就退回只采样主序列，防止并集无限膨胀。
  static const int defaultMaxTotal = 2500;

  /// LTTB 采样，返回保留点在原数组中的**下标**（严格升序）。
  ///
  /// - `n <= targetCount` 时返回 `0..n-1`（没有可降的空间）
  /// - 首尾点无条件保留：丢掉它们会让曲线的起止位置凭空位移
  /// - 时间 O(n)，额外空间 O(targetCount)
  /// - 无随机量，结果确定可断言
  static List<int> lttbIndices(
    List<double> xs,
    List<double> ys,
    int targetCount,
  ) {
    final n = math.min(xs.length, ys.length);
    if (n == 0) return <int>[];
    if (n <= 3 || targetCount >= n) {
      return List<int>.generate(n, (i) => i);
    }
    // 少于 3 点无法构成三角形，退化为首尾两点（保留起止位置）
    if (targetCount < 3) return <int>[0, n - 1];
    final target = targetCount;

    final out = List<int>.filled(target, 0);
    out[0] = 0;
    out[target - 1] = n - 1;

    // 首尾各占一个名额，中间分 target-2 个桶
    final bucketCount = target - 2;
    final bucketSize = (n - 2).toDouble() / bucketCount;

    var a = 0; // 上一个被选中的点
    for (var i = 0; i < bucketCount; i++) {
      // 当前桶的候选区间
      final rangeStart = 1 + (i * bucketSize).toInt();
      final rangeEnd =
          math.min(1 + ((i + 1) * bucketSize).toInt(), n - 1);

      // 下一个桶的平均点，作为三角形的一个顶点
      final nextStart = 1 + ((i + 1) * bucketSize).toInt();
      final nextEnd =
          math.min(1 + ((i + 2) * bucketSize).toInt(), n - 1);
      double avgX;
      double avgY;
      if (nextStart >= n - 1) {
        avgX = xs[n - 1];
        avgY = ys[n - 1];
      } else {
        var sx = 0.0;
        var sy = 0.0;
        var c = 0;
        var j = nextStart;
        while (j < nextEnd) {
          sx += xs[j];
          sy += ys[j];
          c++;
          j++;
        }
        if (c == 0) {
          avgX = xs[n - 1];
          avgY = ys[n - 1];
        } else {
          avgX = sx / c;
          avgY = sy / c;
        }
      }

      final ax = xs[a];
      final ay = ys[a];
      var bestArea = -1.0;
      var bestIdx = rangeStart;
      var j = rangeStart;
      while (j < rangeEnd) {
        // 三角形面积的两倍（省去除以 2，只用于比较大小）
        final area =
            ((ax - avgX) * (ys[j] - ay) - (ax - xs[j]) * (avgY - ay)).abs();
        if (area > bestArea) {
          bestArea = area;
          bestIdx = j;
        }
        j++;
      }
      out[i + 1] = bestIdx;
      a = bestIdx;
    }
    return out;
  }

  /// 各桶的最小/最大值的下标，按时间序输出。LTTB 之外的备选降采样策略。
  static List<int> minMaxIndices(
    List<double> xs,
    List<double> ys,
    int targetCount,
  ) {
    final n = math.min(xs.length, ys.length);
    if (n == 0) return <int>[];
    if (n <= 3 || targetCount >= n) {
      return List<int>.generate(n, (i) => i);
    }

    final out = <int>[0];
    final bucketCount = math.max(1, (targetCount - 2) ~/ 2);
    final bucketSize = n.toDouble() / bucketCount;
    for (var i = 0; i < bucketCount; i++) {
      final s = (i * bucketSize).toInt().clamp(0, n - 1).toInt();
      final e = ((i + 1) * bucketSize)
          .toInt()
          .clamp(s + 1, n)
          .toInt();
      var minI = s;
      var maxI = s;
      for (var j = s; j < e; j++) {
        if (ys[j] < ys[minI]) minI = j;
        if (ys[j] > ys[maxI]) maxI = j;
      }
      out.add(math.min(minI, maxI));
      if (maxI != minI) out.add(math.max(minI, maxI));
    }
    out.add(n - 1);
    return out.toSet().toList()..sort();
  }

  /// 强制并入"关键下标"：全局最大/最小值，以及每个阈值的越限起点。
  ///
  /// 越限点是一份报警报告的全部意义所在，绝不允许被采样丢掉 ——
  /// 读者必须在图上看到"什么时候开始超限、什么时候恢复"。
  static List<int> injectExtremes(
    List<int> indices,
    List<double> ys,
    List<double> thresholds,
  ) {
    if (ys.isEmpty) return indices;
    final set = <int>{};
    for (final index in indices) {
      if (index >= 0 && index < ys.length) set.add(index);
    }

    var minI = 0;
    var maxI = 0;
    for (var i = 0; i < ys.length; i++) {
      if (ys[i] < ys[minI]) minI = i;
      if (ys[i] > ys[maxI]) maxI = i;
    }
    set.add(minI);
    set.add(maxI);

    for (final t in thresholds) {
      if (!t.isFinite) continue;
      // 越限区间的起点（进入）与终点（离开）
      var prevSide = 0;
      for (var i = 0; i < ys.length; i++) {
        final int side;
        if (ys[i] > t) {
          side = 1;
        } else if (ys[i] < t) {
          side = -1;
        } else {
          side = 0;
        }
        if (side != 0) {
          if (prevSide != 0 && side != prevSide) {
            set.add(i - 1);
            set.add(i);
          }
          prevSide = side;
        }
      }
    }
    return set.toList()..sort();
  }

  /// 双序列采样：分别 LTTB 后取**并集**再排序。
  ///
  /// 不能把温度的采样点直接套用到两条曲线 —— 那样湿度自己的波动会被抹掉。
  /// 并集保证两条曲线共享同一组 X（对齐天然成立），且各自的尖峰都被保住。
  /// 并集通常只比 target 大 20–50%。超过 [maxTotal] 时退回只采样主序列。
  static List<int> selectIndices(
    List<double> xs,
    List<double> primaryYs,
    List<double> secondaryYs,
    int targetCount, {
    int maxTotal = defaultMaxTotal,
    List<double> thresholds = const <double>[],
  }) {
    final n = math.min(xs.length, primaryYs.length);
    if (n == 0) return <int>[];

    final primary = injectExtremes(
      lttbIndices(xs, primaryYs, targetCount),
      primaryYs,
      thresholds,
    );
    if (secondaryYs.length < n) return primary;

    final secondary = injectExtremes(
      lttbIndices(xs, secondaryYs, targetCount),
      secondaryYs,
      const <double>[],
    );
    final union = <int>{}..addAll(primary)..addAll(secondary);

    return union.length > maxTotal ? primary : (union.toList()..sort());
  }
}
