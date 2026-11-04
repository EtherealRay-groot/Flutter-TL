import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/protocol/record_entry.dart';
import '../../state/app_controller.dart';
import '../../state/app_state.dart';
import 'dialog_style.dart';

class RecordDialog extends ConsumerStatefulWidget {
  const RecordDialog({super.key});

  @override
  ConsumerState<RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends ConsumerState<RecordDialog> {
  int? _startTime;
  int? _endTime;
  int _rangeMin = 0;
  int _rangeMax = 0;

  static const _intervals = <int, String>{
    3: '3秒',
    10: '10秒',
    30: '30秒',
    60: '1分钟',
    300: '5分钟',
    600: '10分钟',
  };

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final c = ref.read(appControllerProvider.notifier);
    final theme = Theme.of(context);
    final device = state.activeDevice;
    final isRecording = device?.isRecording ?? false;
    final deviceInterval = device?.deviceInterval ?? 0;
    final records = device?.records ?? const <RecordEntry>[];

    if (state.timeRangeMin != _rangeMin || state.timeRangeMax != _rangeMax) {
      _rangeMin = state.timeRangeMin;
      _rangeMax = state.timeRangeMax;
      _startTime ??= _rangeMin;
      _endTime ??= _rangeMax;
    }

    final ftStart = state.filterStartTime;
    final ftEnd = state.filterEndTime;
    final sorted = records.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final filtered = (ftStart != null && ftEnd != null)
        ? sorted.where((r) => r.timestamp >= ftStart && r.timestamp <= ftEnd)
        : sorted;
    final totalCount = filtered.length;
    final lastItems = filtered.toList().reversed.take(10).toList().reversed;

    final tempUnit = state.temperatureUnit;
    final thresholdLow = double.tryParse(state.alarmThresholdLow);
    final thresholdHigh = double.tryParse(state.alarmThresholdHigh);

    final dateFmt = DateFormat('yyyy-MM-dd HH:mm:ss');

    Widget intervalButton(int sec) {
      final selected = state.recordInterval == sec;
      final isDeviceInterval = deviceInterval > 0 && deviceInterval == sec;
      final bg = (isDeviceInterval && isRecording)
          ? theme.colorScheme.error
          : selected
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest;
      final fg = (isDeviceInterval && isRecording) || selected
          ? theme.colorScheme.onPrimary
          : theme.colorScheme.onSurfaceVariant;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: bg,
              foregroundColor: fg,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              minimumSize: const Size(0, 36),
            ),
            onPressed: isRecording ? null : () => c.setRecordInterval(sec),
            child: Text(
              _intervals[sec]!,
              style: theme.textTheme.labelSmall,
              maxLines: 1,
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      insetPadding: kDialogInsetPadding,
      title: const Text('温湿度记录'),
      content: DialogContent(
        maxHeightFactor: 0.78,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (state.recordResult != null) ...[
                Text(
                  state.recordResult!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: state.recordResult!.contains('❌')
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (device != null && device.readCurrent > 0) ...[
                if (device.readTotal > 0) ...[
                  Text(
                    '读取进度：${device.readCurrent} / ${device.readTotal} 条'
                    ' (${(device.readCurrent * 100 / device.readTotal).clamp(0, 100).toInt()}%)',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: device.readCurrent / device.readTotal,
                  ),
                ] else ...[
                  Text(
                    '已读取 ${device.readCurrent} 条',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: 8),
              ],
              Text('记录间隔:', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Row(children: [3, 10, 30].map(intervalButton).toList()),
              const SizedBox(height: 4),
              Row(children: [60, 300, 600].map(intervalButton).toList()),
              const SizedBox(height: 12),
              Row(
                children: [
                  _actionButton(
                    '开始',
                    (!isRecording && state.hasSelectedInterval)
                        ? c.startRecording
                        : null,
                  ),
                  _actionButton('停止', isRecording ? c.stopRecording : null),
                  _actionButton('读取', !isRecording ? _showReadOptions : null),
                  _actionButton('清空', !isRecording ? c.clearRecords : null),
                ],
              ),
              if (state.showTimeRangePicker) _timeRangeSection(theme),
              if (records.isNotEmpty) ...[
                const SizedBox(height: 8),
                _dividerText(
                  theme,
                  (ftStart != null && ftEnd != null)
                      ? '${dateFmt.format(DateTime.fromMillisecondsSinceEpoch(ftStart * 1000))}'
                            ' -- '
                            '${dateFmt.format(DateTime.fromMillisecondsSinceEpoch(ftEnd * 1000))}'
                            ' 共 $totalCount 条（最近10条）'
                      : '共 $totalCount 条（最近10条）',
                ),
                const SizedBox(height: 4),
                for (var i = 0; i < lastItems.length; i++)
                  _recordRow(
                    theme,
                    lastItems.elementAt(i),
                    i,
                    tempUnit,
                    thresholdLow,
                    thresholdHigh,
                  ),
                if (state.exportResult != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    state.exportResult!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: state.exportResult!.contains('❌')
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                if (state.isExporting) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '正在导出…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      Text(
                        '${(state.exportProgress * 100).toInt()}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: state.exportProgress),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (!isRecording && !state.isExporting)
                        ? c.savePdfToDownloads
                        : null,
                    child: Text('📥 下载 PDF（共 $totalCount 条记录）'),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (!isRecording && !state.isExporting)
                        ? c.saveCsvToDownloads
                        : null,
                    child: Text('📥 下载 CSV（共 $totalCount 条记录）'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: c.dismissRecordDialog, child: const Text('关闭')),
      ],
    );
  }

  Widget _actionButton(String label, VoidCallback? onPressed) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            minimumSize: const Size(0, 36),
          ),
          onPressed: onPressed,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }

  Widget _dividerText(ThemeData theme, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _recordRow(
    ThemeData theme,
    RecordEntry entry,
    int index,
    TemperatureUnit unit,
    double? thresholdLow,
    double? thresholdHigh,
  ) {
    final date = DateFormat('yyyy-MM-dd HH:mm:ss')
        .format(DateTime.fromMillisecondsSinceEpoch(entry.timestamp * 1000));
    final temp = unit == TemperatureUnit.celsius
        ? entry.temperature
        : entry.temperature * 9 / 5 + 32;
    final isAlarm =
        (thresholdLow != null && entry.temperature < thresholdLow) ||
        (thresholdHigh != null && entry.temperature > thresholdHigh);
    final bg = index.isEven
        ? theme.colorScheme.surface
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3);
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              date,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          Text(
            '${temp.toStringAsFixed(2)}${unit.symbol}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: isAlarm
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${entry.humidity}%',
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  Widget _timeRangeSection(ThemeData theme) {
    final fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          '数据范围：${fmt.format(DateTime.fromMillisecondsSinceEpoch(_rangeMin * 1000))}'
          ' -- '
          '${fmt.format(DateTime.fromMillisecondsSinceEpoch(_rangeMax * 1000))}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => _pickDateTime(true),
          child: Text(
            '起始时间：${fmt.format(DateTime.fromMillisecondsSinceEpoch((_startTime ?? _rangeMin) * 1000))}',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => _pickDateTime(false),
          child: Text(
            '结束时间：${fmt.format(DateTime.fromMillisecondsSinceEpoch((_endTime ?? _rangeMax) * 1000))}',
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: ref
                  .read(appControllerProvider.notifier)
                  .cancelTimeRangePick,
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final start = _startTime ?? _rangeMin;
                final end = _endTime ?? _rangeMax;
                if (start >= end) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('起始时间必须小于结束时间')));
                  return;
                }
                ref
                    .read(appControllerProvider.notifier)
                    .applyTimeRangeFilter(start, end);
              },
              child: const Text('确认'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickDateTime(bool isStart) async {
    final current = (isStart ? _startTime : _endTime) ?? _rangeMin;
    final initial = DateTime.fromMillisecondsSinceEpoch(current * 1000);
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.fromMillisecondsSinceEpoch(_rangeMin * 1000),
      lastDate: DateTime.fromMillisecondsSinceEpoch(_rangeMax * 1000),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final combined = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
      initial.second,
    );
    var epoch = combined.millisecondsSinceEpoch ~/ 1000;
    epoch = epoch.clamp(_rangeMin, _rangeMax);
    setState(() {
      if (isStart) {
        _startTime = epoch;
      } else {
        _endTime = epoch;
      }
    });
  }

  Future<void> _showReadOptions() async {
    final c = ref.read(appControllerProvider.notifier);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择读取方式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  c.readAllRecords();
                },
                child: const Text('所有记录'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  c.readAllRecordsForTimeRange();
                },
                child: const Text('按时间读取'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}
