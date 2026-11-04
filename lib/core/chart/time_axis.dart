import 'dart:math' as math;

import 'chart_model.dart';

/// X 轴上的一个刻度。`ratio` 是 0..1 的相对位置，由调用方乘上绘图区宽度。
class TimeTick {
  const TimeTick({
    required this.ratio,
    required this.label,
    required this.anchor,
  });

  final double ratio;
  final String label;
  final Anchor anchor;

  @override
  bool operator ==(Object other) =>
      other is TimeTick &&
      other.ratio == ratio &&
      other.label == label &&
      other.anchor == anchor;

  @override
  int get hashCode => Object.hash(ratio, label, anchor);
}

/// 时区的最小抽象，对应 `java.util.TimeZone` 在本图表内需要的部分。
///
/// 纯 Dart 层不引入时区数据库：生产代码传入设备时区（固定偏移），
/// 需要夏令时的调用方可用 [ChartTimeZone.custom] 提供按时刻解析的偏移。
class ChartTimeZone {
  const ChartTimeZone.fixed(this.id, this._fixedOffsetSeconds)
      : _offsetAt = null;

  const ChartTimeZone.custom(this.id, int Function(int epochSeconds) offsetAt)
      : _fixedOffsetSeconds = 0,
        _offsetAt = offsetAt;

  /// UTC。
  static const ChartTimeZone utc = ChartTimeZone.fixed('UTC', 0);

  final String id;
  final int _fixedOffsetSeconds;
  final int Function(int epochSeconds)? _offsetAt;

  /// 给定 epoch 秒对应的 UTC 偏移（秒）。
  int offsetSecondsAt(int epochSeconds) =>
      _offsetAt?.call(epochSeconds) ?? _fixedOffsetSeconds;

  /// 设备本地时区。按每个时刻向平台查询偏移，因此夏令时切换也成立。
  static ChartTimeZone local() => ChartTimeZone.custom(
        'local',
        (epochSeconds) => DateTime.fromMillisecondsSinceEpoch(
          epochSeconds * 1000,
        ).timeZoneOffset.inSeconds,
      );

  @override
  String toString() => 'ChartTimeZone($id)';
}

/// 时间轴刻度。
///
/// ## 为什么不用"首尾均分 + 各自格式化"
/// 均分会产生 `14:07 / 14:53` 这种不圆整的标签，打印在报告里很难看，
/// 也不便于读者对齐。这里改为**从步长阶梯里挑一个步长，再把刻度对齐到自然边界**
/// （整分、刻钟、整点……）。
///
/// ## 为什么不用 Dart 的 DateTime 本地时区
/// 与 Kotlin 侧一致，时间字段的计算显式依赖传入的 [ChartTimeZone]，
/// 这样测试传 UTC 就能断言精确字符串，而生产代码传设备时区。
abstract final class TimeAxis {
  static const int _second = 1;
  static const int _minute = 60;
  static const int _hour = 3600;
  static const int _day = 86400;

  static const List<_Tier> _tiers = <_Tier>[
    _Tier(
      maxSpanSec: 5 * _minute,
      candidates: <int>[
        1 * _second,
        2 * _second,
        5 * _second,
        10 * _second,
        15 * _second,
        30 * _second,
        1 * _minute,
      ],
      targetTicks: 5,
      pattern: 'HH:mm:ss',
    ),
    _Tier(
      maxSpanSec: _day,
      candidates: <int>[
        1 * _minute,
        2 * _minute,
        5 * _minute,
        10 * _minute,
        15 * _minute,
        30 * _minute,
        1 * _hour,
        2 * _hour,
        3 * _hour,
        6 * _hour,
        12 * _hour,
      ],
      targetTicks: 6,
      pattern: 'HH:mm',
    ),
    _Tier(
      maxSpanSec: 7 * _day,
      candidates: <int>[
        1 * _hour,
        2 * _hour,
        3 * _hour,
        6 * _hour,
        12 * _hour,
        1 * _day,
      ],
      targetTicks: 4,
      pattern: 'MM-dd HH:mm',
    ),
    _Tier(
      maxSpanSec: 180 * _day,
      candidates: <int>[1 * _day, 2 * _day, 7 * _day],
      targetTicks: 5,
      pattern: 'MM-dd',
    ),
    _Tier(
      maxSpanSec: 0x7fffffffffffffff,
      candidates: <int>[
        30 * _day,
        90 * _day,
        180 * _day,
        365 * _day,
        730 * _day,
        1826 * _day,
        3652 * _day,
      ],
      targetTicks: 4,
      pattern: 'yyyy-MM-dd',
    ),
  ];

  /// 达到或超过这个步长就按日历年份步进，避免闰年误差逐年累积。
  static const int _yearStepThreshold = 365 * _day;

  /// 生成 X 轴刻度。
  ///
  /// [tz] 与 [locale] 显式传入而非读全局默认值，这样测试传 UTC 就能断言精确字符串，
  /// 而生产代码传设备时区。当前所有 pattern 都是纯数字格式，locale 不改变输出。
  static List<TimeTick> ticks(
    int startSec,
    int endSec,
    ChartTimeZone tz,
    String locale,
  ) {
    final start = math.min(startSec, endSec);
    final end = math.max(startSec, endSec);
    final span = end - start;

    if (span <= 0) {
      return <TimeTick>[
        TimeTick(
          ratio: 0.5,
          label: _format(start, tz, locale, _patternFor(span)),
          anchor: Anchor.center,
        ),
      ];
    }

    final tier = _tiers.firstWhere((t) => span <= t.maxSpanSec);
    final needsYear = _crossesYearBoundary(start, end, tz);
    final pattern =
        needsYear ? _yearPatternFor(tier.pattern) : tier.pattern;
    final step = _pickStep(span, tier.candidates, tier.targetTicks);

    final tickSecs = _generate(start, end, step, tz);
    if (tickSecs.isEmpty) {
      return <TimeTick>[
        TimeTick(
          ratio: 0,
          label: _format(start, tz, locale, pattern),
          anchor: Anchor.left,
        ),
        TimeTick(
          ratio: 1,
          label: _format(end, tz, locale, pattern),
          anchor: Anchor.right,
        ),
      ];
    }

    final spanD = span.toDouble();
    final out = <TimeTick>[];
    for (var i = 0; i < tickSecs.length; i++) {
      final t = tickSecs[i];
      final ratio =
          ((t - start).toDouble() / spanD).clamp(0.0, 1.0).toDouble();
      final Anchor anchor;
      if (i == 0) {
        anchor = Anchor.left;
      } else if (i == tickSecs.length - 1) {
        anchor = Anchor.right;
      } else {
        anchor = Anchor.center;
      }
      out.add(TimeTick(
        ratio: ratio,
        label: _format(t, tz, locale, pattern),
        anchor: anchor,
      ));
    }
    return out;
  }

  // ---------- 步长选择 ----------

  /// 挑一个使刻度数最接近目标的步长。并列时取较小步长（刻度更密）。
  static int _pickStep(int span, List<int> candidates, int target) {
    var best = candidates.first;
    var bestDiff = (span / best - target).abs();
    for (var i = 1; i < candidates.length; i++) {
      final candidate = candidates[i];
      final diff = (span / candidate - target).abs();
      if (diff < bestDiff) {
        best = candidate;
        bestDiff = diff;
      }
    }
    return best;
  }

  // ---------- 刻度生成 ----------

  static List<int> _generate(
    int start,
    int end,
    int step,
    ChartTimeZone tz,
  ) {
    final out = <int>[];
    var t = _alignDown(start, step, tz);
    var guard = 0;
    while (guard++ < _maxTicks) {
      if (t > end) break;
      if (t >= start) out.add(t);
      // 天级及以上必须用日历字段步进：直接加固定秒数在夏令时切换日会偏 1 小时
      if (step >= _yearStepThreshold) {
        t = _addYears(
          t,
          math.max(
            1,
            (step / (365.2425 * _day)).round(),
          ),
          tz,
        );
      } else if (step >= _day) {
        t = _addDays(t, step ~/ _day, tz);
      } else {
        t = t + step;
      }
    }
    return out;
  }

  /// 把时刻向下对齐到 [step] 的自然边界（在 [tz] 的本地时间字段上操作）。
  /// 这样从 14:07:33 开始的记录，刻度仍会落在 14:15:00 而不是 14:22:33。
  static int _alignDown(int sec, int step, ChartTimeZone tz) {
    final local = _localDateTime(sec, tz);
    var hour = local.hour;
    var minute = local.minute;
    var second = local.second;
    if (step >= _day) {
      hour = 0;
      minute = 0;
      second = 0;
    } else if (step >= _hour) {
      minute = 0;
      second = 0;
      final drop = math.max(step ~/ _hour, 1);
      hour = (hour ~/ drop) * drop;
    } else if (step >= _minute) {
      second = 0;
      final drop = math.max(step ~/ _minute, 1);
      minute = (minute ~/ drop) * drop;
    } else {
      final drop = math.max(step, 1);
      second = (second ~/ drop) * drop;
    }
    return _epochFromLocal(
      local.year,
      local.month,
      local.day,
      hour,
      minute,
      second,
      tz,
    );
  }

  static int _addDays(int sec, int days, ChartTimeZone tz) {
    final local = _localDateTime(sec, tz);
    return _epochFromLocal(
      local.year,
      local.month,
      local.day + days,
      local.hour,
      local.minute,
      local.second,
      tz,
    );
  }

  static int _addYears(int sec, int years, ChartTimeZone tz) {
    final local = _localDateTime(sec, tz);
    final targetYear = local.year + years;
    // Calendar.add(YEAR) 会把 2/29 夹到目标年的月末，而不是溢出到 3/1。
    final lastDay = DateTime.utc(targetYear, local.month + 1, 0).day;
    final day = math.min(local.day, lastDay);
    return _epochFromLocal(
      targetYear,
      local.month,
      day,
      local.hour,
      local.minute,
      local.second,
      tz,
    );
  }

  // ---------- 时区字段 ----------

  /// 把 epoch 秒换算成 [tz] 下的墙钟时间，用 UTC DateTime 承载字段值。
  static DateTime _localDateTime(int sec, ChartTimeZone tz) {
    final offset = tz.offsetSecondsAt(sec);
    return DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true)
        .add(Duration(seconds: offset));
  }

  static int _epochFromLocal(
    int year,
    int month,
    int day,
    int hour,
    int minute,
    int second,
    ChartTimeZone tz,
  ) {
    final wallMs =
        DateTime.utc(year, month, day, hour, minute, second).millisecondsSinceEpoch;
    final approxSec = wallMs ~/ 1000;
    return approxSec - tz.offsetSecondsAt(approxSec);
  }

  // ---------- 格式化 ----------

  static String _patternFor(int span) =>
      _tiers.firstWhere((t) => span <= t.maxSpanSec).pattern;

  /// 跨年时必须带年份，否则 `12-31` 与 `01-01` 分不清是哪一年。
  static String _yearPatternFor(String pattern) =>
      pattern.startsWith('yyyy') ? pattern : 'yyyy-$pattern';

  static bool _crossesYearBoundary(
    int startSec,
    int endSec,
    ChartTimeZone tz,
  ) =>
      _localDateTime(startSec, tz).year != _localDateTime(endSec, tz).year;

  static String _format(
    int sec,
    ChartTimeZone tz,
    String locale,
    String pattern,
  ) {
    final local = _localDateTime(sec, tz);
    return pattern
        .replaceAll('yyyy', local.year.toString().padLeft(4, '0'))
        .replaceAll('MM', local.month.toString().padLeft(2, '0'))
        .replaceAll('dd', local.day.toString().padLeft(2, '0'))
        .replaceAll('HH', local.hour.toString().padLeft(2, '0'))
        .replaceAll('mm', local.minute.toString().padLeft(2, '0'))
        .replaceAll('ss', local.second.toString().padLeft(2, '0'));
  }

  static const int _maxTicks = 500;
}

/// 时间跨度超过某个值时切换到对应的步长阶梯与标签格式。
class _Tier {
  const _Tier({
    required this.maxSpanSec,
    required this.candidates,
    required this.targetTicks,
    required this.pattern,
  });

  final int maxSpanSec;
  final List<int> candidates;
  final int targetTicks;
  final String pattern;
}
