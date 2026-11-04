import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tl_app/core/protocol/logistics_info.dart';
import 'package:tl_app/core/protocol/record_entry.dart';
import 'package:tl_app/export/pdf_fonts.dart';
import 'package:tl_app/export/pdf_report_builder.dart';
import 'package:tl_app/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app asset font can build a Chinese PDF report', () async {
    final fonts = await AppPdfFonts.load();
    final bytes = await PdfReportBuilder.build(
      records: const [
        RecordEntry(timestamp: 1700000000, temperature: 20.5, humidity: 45),
        RecordEntry(timestamp: 1700000060, temperature: 21.5, humidity: 46),
      ],
      deviceName: 'TL000005',
      deviceAddress: 'f0:c8:00:00:00:05',
      unit: TemperatureUnit.celsius,
      thresholdLowC: 10,
      thresholdHighC: 30,
      logistics: const LogisticsInfo(company: '顺丰', quantity: 2),
      font: fonts.regular,
      boldFont: fonts.bold,
    );
    expect(bytes.length, greaterThan(1000));
    expect(
      utf8.decode(bytes.sublist(0, 4), allowMalformed: true),
      '%PDF',
    );
  });
}
