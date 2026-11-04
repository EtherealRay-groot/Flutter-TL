import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';

/// 应用内 PDF 字体。Noto Sans SC 变量字体覆盖常用中文。
///
/// 字体对象必须绑定到一个 PdfDocument。这里先用一个临时文档承载，
/// [PdfReportBuilder] 会把 TTF 字节克隆到真正要保存的文档里。
///
/// 目前 variable font 只有默认字重实例，标题与正文共用同一字体；
/// 需要真正粗体时再补一份静态 Bold TTF。
class AppPdfFonts {
  AppPdfFonts._();

  static Future<PdfFontPair> load() async {
    final data = await rootBundle.load('assets/fonts/NotoSansSC-VF.ttf');
    final holder = PdfDocument();
    final font = PdfTtfFont(holder, data);
    return PdfFontPair(regular: font, bold: font);
  }
}

class PdfFontPair {
  const PdfFontPair({required this.regular, required this.bold});

  final PdfFont regular;
  final PdfFont bold;
}
