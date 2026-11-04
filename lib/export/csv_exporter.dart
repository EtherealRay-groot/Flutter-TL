import 'package:intl/intl.dart';

import '../core/protocol/logistics_info.dart';
import '../core/protocol/record_entry.dart';
import '../state/app_state.dart';

/// 生成与原 Android 版一致的 CSV 文本（UTF-8）。
class CsvExporter {
  CsvExporter._();

  static String build({
    required List<RecordEntry> records,
    required String deviceName,
    required String deviceAddress,
    required TemperatureUnit unit,
    double? thresholdLowC,
    double? thresholdHighC,
    LogisticsInfo? logistics,
    int? filterStartTime,
    int? filterEndTime,
  }) {
    final tableRecords = records.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (filterStartTime != null || filterEndTime != null) {
      tableRecords.removeWhere((rec) =>
          (filterStartTime != null && rec.timestamp < filterStartTime) ||
          (filterEndTime != null && rec.timestamp > filterEndTime));
    }
    if (tableRecords.isEmpty) {
      throw const CsvExportException('过滤后无记录');
    }

    var maxTemp = double.negativeInfinity;
    var minTemp = double.infinity;
    var sumTemp = 0.0;
    var maxHum = -1 << 31;
    var minHum = 1 << 31;
    var sumHum = 0;
    var alarmCount = 0;
    int? firstRecordTime;
    int? lastRecordTime;
    for (final rec in tableRecords) {
      final t = rec.temperature;
      if (t > maxTemp) maxTemp = t;
      if (t < minTemp) minTemp = t;
      sumTemp += t;
      final h = rec.humidity;
      if (h > maxHum) maxHum = h;
      if (h < minHum) minHum = h;
      sumHum += h;
      if ((thresholdLowC != null && t < thresholdLowC) ||
          (thresholdHighC != null && t > thresholdHighC)) {
        alarmCount++;
      }
      final ts = rec.timestamp;
      if (firstRecordTime == null || ts < firstRecordTime) firstRecordTime = ts;
      if (lastRecordTime == null || ts > lastRecordTime) lastRecordTime = ts;
    }
    final n = tableRecords.length;
    final avgTemp = sumTemp / n;
    final avgHum = sumHum ~/ n;

    final rowFmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    String fmtTime(int? epoch) => epoch == null
        ? '--'
        : rowFmt.format(DateTime.fromMillisecondsSinceEpoch(epoch * 1000));
    final csvRangeStart = fmtTime(firstRecordTime);
    final csvRangeEnd = fmtTime(lastRecordTime);
    final csvDur = (firstRecordTime != null && lastRecordTime != null)
        ? _formatDuration(lastRecordTime - firstRecordTime)
        : '--';

    double toUnit(double c) =>
        unit == TemperatureUnit.fahrenheit ? c * 9 / 5 + 32 : c;
    final sym = unit.symbol;

    final b = StringBuffer()
      ..writeln('=== 设备信息 ===')
      ..writeln('设备名称,Temperature logger')
      ..writeln('蓝牙广播名称,${_cell(deviceName)}')
      ..writeln('Mac地址,${_cell(deviceAddress)}')
      ..writeln('存储条数,65535')
      ..writeln('测量范围,-30~85°C')
      ..writeln();

    if (logistics != null && logistics.hasContent) {
      b
        ..writeln('=== 物流信息 ===')
        ..writeln('公司名称,${_cell(logistics.company)}')
        ..writeln('货物单号,${_cell(logistics.goodsNo)}')
        ..writeln('货物箱号,${_cell(logistics.boxNo)}')
        ..writeln('货物描述,${_cell(logistics.goodsDesc)}')
        ..writeln('发货人,${_cell(logistics.shipper)}')
        ..writeln('收货人,${_cell(logistics.consignee)}')
        ..writeln('发货地址,${_cell(logistics.shipAddr)}')
        ..writeln('收货地址,${_cell(logistics.recvAddr)}')
        ..writeln('备注,${_cell(logistics.remark)}');
      final qty = logistics.quantity % 1.0 == 0.0
          ? logistics.quantity.toInt().toString()
          : logistics.quantity.toString();
      b
        ..writeln('数量,$qty')
        ..writeln('单位,${_cell(logistics.unit)}')
        ..writeln();
    }

    b
      ..writeln('=== 记录信息 ===')
      ..writeln('记录总数,$n');
    if (thresholdLowC != null || thresholdHighC != null) {
      b.writeln('报警条数,$alarmCount');
    }
    b
      ..writeln('起始时间,$csvRangeStart,结束时间,$csvRangeEnd,时长,$csvDur')
      ..writeln()
      ..writeln('=== 统计信息 ===')
      ..writeln(
          '最高温度,${toUnit(maxTemp).toStringAsFixed(2)}$sym,最高湿度,$maxHum%')
      ..writeln(
          '最低温度,${toUnit(minTemp).toStringAsFixed(2)}$sym,最低湿度,$minHum%')
      ..writeln(
          '平均温度,${toUnit(avgTemp).toStringAsFixed(2)}$sym,平均湿度,$avgHum%')
      ..writeln()
      ..writeln('=== 数据记录 ===')
      ..writeln('序号,时间,温度($sym),湿度(%)');

    for (var i = 0; i < tableRecords.length; i++) {
      final rec = tableRecords[i];
      final tempValue = toUnit(rec.temperature);
      b.writeln(
        '${i + 1},${rowFmt.format(DateTime.fromMillisecondsSinceEpoch(rec.timestamp * 1000))},'
        '${tempValue.toStringAsFixed(2)},${rec.humidity}',
      );
    }
    return b.toString();
  }

  /// RFC 4180：含逗号/引号/换行时整体加双引号，内部双引号翻倍。
  static String _cell(String s) {
    if (!s.contains(',') &&
        !s.contains('"') &&
        !s.contains('\n') &&
        !s.contains('\r')) {
      return s;
    }
    return '"${s.replaceAll('"', '""')}"';
  }

  static String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h${m}m${s}s';
    if (m > 0) return '${m}m${s}s';
    return '${s}s';
  }
}

class CsvExportException implements Exception {
  const CsvExportException(this.message);

  final String message;

  @override
  String toString() => message;
}
