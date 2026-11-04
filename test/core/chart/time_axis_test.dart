import 'package:test/test.dart';
import 'package:tl_app/core/chart/chart_model.dart';
import 'package:tl_app/core/chart/time_axis.dart';

void main() {
  const tz = ChartTimeZone.utc;
  const locale = 'en_US';

  /// 用 UTC 日历字段构造 epoch 秒，避免在测试里手算时间常量算错。
  int utcSec(
    int y,
    int mo,
    int d, {
    int h = 0,
    int mi = 0,
    int s = 0,
  }) =>
      DateTime.utc(y, mo, d, h, mi, s).millisecondsSinceEpoch ~/ 1000;

  List<TimeTick> ticks(int start, int end) =>
      TimeAxis.ticks(start, end, tz, locale);

  final hhmmss = RegExp(r'^\d{2}:\d{2}:\d{2}$');
  final hhmm = RegExp(r'^\d{2}:\d{2}$');
  final mmddhhmm = RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}$');
  final mmdd = RegExp(r'^\d{2}-\d{2}$');
  final yyyymmdd = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  // ---------- 标签格式随跨度切换 ----------

  test('shortSpan_usesSecondResolutionLabels', () {
    final t = ticks(
      utcSec(2026, 9, 11, h: 14, mi: 0, s: 0),
      utcSec(2026, 9, 11, h: 14, mi: 4, s: 0),
    );
    expect(
      t.every((it) => hhmmss.hasMatch(it.label)),
      isTrue,
      reason: '4 分钟的跨度应使用 HH:mm:ss，实测 ${t.map((it) => it.label)}',
    );
  });

  test('hoursSpan_dropsSecondsFromLabels', () {
    final t = ticks(
      utcSec(2026, 9, 11, h: 8, mi: 0, s: 0),
      utcSec(2026, 9, 11, h: 20, mi: 0, s: 0),
    );
    expect(
      t.every((it) => hhmm.hasMatch(it.label)),
      isTrue,
      reason: '12 小时的跨度不该带秒，实测 ${t.map((it) => it.label)}',
    );
  });

  test('multiDaySpan_carriesBothDateAndTime', () {
    final t = ticks(
      utcSec(2026, 9, 11, h: 0, mi: 0, s: 0),
      utcSec(2026, 9, 13, h: 12, mi: 0, s: 0),
    );
    expect(
      t.every((it) => mmddhhmm.hasMatch(it.label)),
      isTrue,
      reason: '跨天时若只有时间，读者分不清是哪一天。实测 ${t.map((it) => it.label)}',
    );
  });

  test('weeksSpan_usesDateOnlyLabels', () {
    final t = ticks(
      utcSec(2026, 9, 1, h: 0, mi: 0, s: 0),
      utcSec(2026, 9, 25, h: 0, mi: 0, s: 0),
    );
    expect(
      t.every((it) => mmdd.hasMatch(it.label)),
      isTrue,
      reason: '实测 ${t.map((it) => it.label)}',
    );
  });

  test('monthsSpan_usesFullDateLabels', () {
    final t = ticks(
      utcSec(2026, 1, 1, h: 0, mi: 0, s: 0),
      utcSec(2026, 12, 1, h: 0, mi: 0, s: 0),
    );
    expect(
      t.every((it) => yyyymmdd.hasMatch(it.label)),
      isTrue,
      reason: '实测 ${t.map((it) => it.label)}',
    );
  });

  // ---------- 跨年必须带年份 ----------

  test('yearBoundaryCrossing_addsYearToEveryLabel', () {
    // 8 小时跨度，本来该用 HH:mm；但跨越了年界
    final t = ticks(
      utcSec(2026, 12, 31, h: 20, mi: 0, s: 0),
      utcSec(2027, 1, 1, h: 4, mi: 0, s: 0),
    );
    expect(
      t.every((it) => it.label.contains('2026') || it.label.contains('2027')),
      isTrue,
      reason: '跨越年界时 12-31 与 01-01 无法区分年份，标签必须带年份。'
          '实测 ${t.map((it) => it.label)}',
    );
  });

  test('yearBoundaryCrossing_labelsDistinguishTheTwoYears', () {
    final t = ticks(
      utcSec(2026, 12, 31, h: 20, mi: 0, s: 0),
      utcSec(2027, 1, 1, h: 4, mi: 0, s: 0),
    );
    expect(t.any((it) => it.label.contains('2026')), isTrue,
        reason: '2026 年尾的刻度缺失');
    expect(t.any((it) => it.label.contains('2027')), isTrue,
        reason: '2027 年头的刻度缺失');
  });

  test('sameYearSpan_doesNotClutterLabelsWithTheYear', () {
    final t = ticks(
      utcSec(2026, 9, 1, h: 0, mi: 0, s: 0),
      utcSec(2026, 9, 25, h: 0, mi: 0, s: 0),
    );
    expect(t.any((it) => it.label.contains('2026')), isFalse,
        reason: '同年内不必重复年份，实测 ${t.map((it) => it.label)}');
  });

  // ---------- 刻度落在自然边界上 ----------

  test('ticks_areAlignedToNaturalBoundariesNotToTheDataStart', () {
    // 从 14:07:33 开始，刻度不该继承这些零头
    final t = ticks(
      utcSec(2026, 9, 11, h: 14, mi: 7, s: 33),
      utcSec(2026, 9, 11, h: 20, mi: 7, s: 33),
    );
    expect(t.isNotEmpty, isTrue,
        reason: '刻度必须对齐到自然边界，实测 ${t.map((it) => it.label)}');
    for (final tick in t) {
      final parts = tick.label.split(':');
      expect(parts[1], '00', reason: '分刻度未对齐到整分');
    }
  });

  test('ticks_areEvenlySpacedInTime', () {
    final t = ticks(
      utcSec(2026, 9, 11, h: 0, mi: 0, s: 0),
      utcSec(2026, 9, 11, h: 12, mi: 0, s: 0),
    );
    expect(t.length >= 3, isTrue);
    final gaps = <double>[
      for (var i = 1; i < t.length; i++) t[i].ratio - t[i - 1].ratio,
    ];
    for (final gap in gaps) {
      expect(
        gap,
        closeTo(gaps[0], 1e-4),
        reason: '刻度在时间上应当等距（X 轴是线性的）',
      );
    }
  });

  test('quarterHourSteps_landOnQuarterHours', () {
    final t = ticks(
      utcSec(2026, 9, 11, h: 13, mi: 5, s: 0),
      utcSec(2026, 9, 11, h: 17, mi: 5, s: 0),
    );
    for (final tick in t) {
      final minute = int.parse(tick.label.split(':')[1]);
      expect(minute % 15, 0,
          reason: '刻度落在 ${tick.label}，不在刻钟边界上');
    }
  });

  // ---------- 输出契约 ----------

  test('ratios_areWithinZeroToOneAndStrictlyAscending', () {
    final cases = <(int, int)>[
      (
        utcSec(2026, 9, 11, h: 14, mi: 0, s: 0),
        utcSec(2026, 9, 11, h: 14, mi: 4, s: 0)
      ),
      (
        utcSec(2026, 9, 11, h: 0, mi: 0, s: 0),
        utcSec(2026, 9, 12, h: 0, mi: 0, s: 0)
      ),
      (
        utcSec(2026, 9, 1, h: 0, mi: 0, s: 0),
        utcSec(2026, 9, 25, h: 0, mi: 0, s: 0)
      ),
      (
        utcSec(2026, 1, 1, h: 0, mi: 0, s: 0),
        utcSec(2026, 12, 1, h: 0, mi: 0, s: 0)
      ),
    ];
    for (final c in cases) {
      final t = ticks(c.$1, c.$2);
      expect(t.isNotEmpty, isTrue, reason: '刻度不该为空');
      for (final tick in t) {
        expect(tick.ratio >= -1e-4 && tick.ratio <= 1 + 1e-4, isTrue,
            reason: 'ratio ${tick.ratio} 越界');
      }
      for (var i = 1; i < t.length; i++) {
        expect(t[i].ratio > t[i - 1].ratio, isTrue, reason: '刻度 ratio 未升序');
      }
    }
  });

  test('firstTickIsLeftAnchoredAndLastIsRight', () {
    final t = ticks(
      utcSec(2026, 9, 11, h: 0, mi: 0, s: 0),
      utcSec(2026, 9, 11, h: 12, mi: 0, s: 0),
    );
    expect(t.length >= 2, isTrue);
    expect(t.first.anchor, Anchor.left,
        reason: '首个刻度居中会被绘图区左边界切掉半截');
    expect(t.last.anchor, Anchor.right,
        reason: '末尾刻度居中会溢出绘图区右边界');
  });

  test('tickCountStaysReadable', () {
    final cases = <(int, int)>[
      (
        utcSec(2026, 9, 11, h: 14, mi: 0, s: 0),
        utcSec(2026, 9, 11, h: 14, mi: 4, s: 0)
      ),
      (
        utcSec(2026, 9, 11, h: 0, mi: 0, s: 0),
        utcSec(2026, 9, 12, h: 0, mi: 0, s: 0)
      ),
      (
        utcSec(2026, 9, 1, h: 0, mi: 0, s: 0),
        utcSec(2026, 9, 25, h: 0, mi: 0, s: 0)
      ),
      (
        utcSec(2026, 1, 1, h: 0, mi: 0, s: 0),
        utcSec(2026, 12, 1, h: 0, mi: 0, s: 0)
      ),
      (
        utcSec(2020, 1, 1, h: 0, mi: 0, s: 0),
        utcSec(2026, 1, 1, h: 0, mi: 0, s: 0)
      ),
    ];
    for (final c in cases) {
      final n = ticks(c.$1, c.$2).length;
      expect(n, inInclusiveRange(2, 12), reason: '刻度数 $n 过少或过多');
    }
  });

  test('ticks_coverMostOfTheRange', () {
    final start = utcSec(2026, 9, 11, h: 0, mi: 0, s: 0);
    final end = utcSec(2026, 9, 11, h: 12, mi: 0, s: 0);
    final t = ticks(start, end);
    final coverage = t.last.ratio - t.first.ratio;
    expect(
      coverage >= 0.6,
      isTrue,
      reason: '刻度只覆盖了 ${(coverage * 100).toInt()}% 的跨度，两端会有大片空白',
    );
  });

  // ---------- 退化输入 ----------

  test('singleTimestamp_doesNotCrash', () {
    final ts = utcSec(2026, 9, 11, h: 14, mi: 0, s: 0);
    final t = ticks(ts, ts);
    for (final tick in t) {
      expect(tick.ratio >= -1e-4 && tick.ratio <= 1 + 1e-4, isTrue,
          reason: 'ratio ${tick.ratio} 越界');
    }
  }, timeout: const Timeout(Duration(seconds: 2)));

  test('reversedRange_isHandledGracefully', () {
    final t = ticks(
      utcSec(2026, 9, 11, h: 12, mi: 0, s: 0),
      utcSec(2026, 9, 11, h: 0, mi: 0, s: 0),
    );
    expect(t.length <= 12, isTrue,
        reason: '起止颠倒时不该抛异常或产生无穷刻度');
  }, timeout: const Timeout(Duration(seconds: 2)));

  test('multiYearSpan_doesNotExplode', () {
    final t = ticks(
      utcSec(2000, 1, 1, h: 0, mi: 0, s: 0),
      utcSec(2026, 1, 1, h: 0, mi: 0, s: 0),
    );
    expect(t.length, inInclusiveRange(2, 12),
        reason: '26 年跨度产生了 ${t.length} 个刻度');
  }, timeout: const Timeout(Duration(seconds: 2)));

  test('extremeSpanOfMinutesInSeconds_producesNoDuplicateLabels', () {
    final t = ticks(
      utcSec(2026, 9, 11, h: 14, mi: 0, s: 0),
      utcSec(2026, 9, 11, h: 14, mi: 0, s: 45),
    );
    expect(t.length, t.map((it) => it.label).toSet().length,
        reason: '45 秒跨度内不该出现两个一模一样的标签');
  });
}
