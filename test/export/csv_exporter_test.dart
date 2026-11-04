import 'package:intl/intl.dart';
import 'package:test/test.dart';
import 'package:tl_app/core/protocol/logistics_info.dart';
import 'package:tl_app/core/protocol/record_entry.dart';
import 'package:tl_app/export/csv_exporter.dart';
import 'package:tl_app/state/app_state.dart';

void main() {
  final records = [
    const RecordEntry(timestamp: 1700000000, temperature: 20.0, humidity: 40),
    const RecordEntry(timestamp: 1700000060, temperature: 25.5, humidity: 60),
    const RecordEntry(timestamp: 1700000120, temperature: 15.0, humidity: 50),
  ];

  String build({
    TemperatureUnit unit = TemperatureUnit.celsius,
    double? low,
    double? high,
    LogisticsInfo? logistics,
    int? start,
    int? end,
  }) =>
      CsvExporter.build(
        records: records,
        deviceName: 'TL000005',
        deviceAddress: 'f0:c8:00:00:00:05',
        unit: unit,
        thresholdLowC: low,
        thresholdHighC: high,
        logistics: logistics,
        filterStartTime: start,
        filterEndTime: end,
      );

  test('throws when filter removes all records', () {
    expect(
      () => build(start: 1800000000, end: 1800000100),
      throwsA(isA<CsvExportException>()),
    );
  });

  test('device header and record stats', () {
    final csv = build(low: 16, high: 24);
    expect(csv, contains('=== 设备信息 ==='));
    expect(csv, contains('蓝牙广播名称,TL000005'));
    expect(csv, contains('Mac地址,f0:c8:00:00:00:05'));
    expect(csv, contains('存储条数,65535'));
    expect(csv, contains('记录总数,3'));
    expect(csv, contains('报警条数,2')); // 20/15 below 16? 20 no, 15 yes, 25.5 yes
    expect(csv, contains('最高温度,25.50℃'));
    expect(csv, contains('最低温度,15.00℃'));
    expect(csv, contains('平均温度,20.17℃'));
    expect(csv, contains('序号,时间,温度(℃),湿度(%)'));
    // CSV 按设备本地时区输出，测试不能依赖 CI 机器的时区。
    final firstTime = DateFormat(
      'yyyy-MM-dd HH:mm:ss',
    ).format(DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    expect(csv, contains('1,$firstTime,20.00,40'));
  });

  test('fahrenheit conversion', () {
    final csv = build(unit: TemperatureUnit.fahrenheit);
    expect(csv, contains('最高温度,77.90℉')); // 25.5C
    expect(csv, contains('最低温度,59.00℉')); // 15C
  });

  test('filters by time range', () {
    final csv = build(start: 1700000060, end: 1700000120);
    expect(csv, contains('记录总数,2'));
    expect(csv, isNot(contains('20.00')));
  });

  test('logistics section is omitted for blank v3 block', () {
    final blank = LogisticsInfo.decode(
      LogisticsInfo.encode(const LogisticsInfo()),
    );
    final csv = build(logistics: blank);
    expect(csv, isNot(contains('=== 物流信息 ===')));
  });

  test('logistics values are escaped per RFC 4180', () {
    final csv = build(
      logistics: const LogisticsInfo(
        company: '顺丰,"冷链"',
        shipAddr: '深圳\n南山',
      ),
    );
    expect(csv, contains('=== 物流信息 ==='));
    expect(csv, contains('公司名称,"顺丰,""冷链"""'));
    expect(csv, contains('发货地址,"深圳\n南山"'));
  });

  test('quantity prints as integer when whole', () {
    final csv = build(logistics: const LogisticsInfo(quantity: 12.0));
    expect(csv, contains('数量,12'));
  });
}
