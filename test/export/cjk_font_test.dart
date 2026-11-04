import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:test/test.dart';

void main() {
  test('Noto Sans SC variable TTF embeds and renders Chinese', () async {
    final data = File('assets/fonts/NotoSansSC-VF.ttf').readAsBytesSync();
    final font = pw.Font.ttf(ByteData.sublistView(Uint8List.fromList(data)));

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              '数据报告',
              style: pw.TextStyle(font: font, fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              '设备名称：温度记录仪  温度 27.50℃  湿度 50%',
              style: pw.TextStyle(font: font, fontSize: 10),
            ),
          ],
        ),
      ),
    );
    final bytes = await doc.save();
    expect(bytes.length, greaterThan(1000));
  });
}
