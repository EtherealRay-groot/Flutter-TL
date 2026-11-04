import 'dart:io';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 跨平台文件保存：
/// - Android：写入系统下载目录（MediaStore）。
/// - iOS：写入临时目录后弹系统分享面板（iOS 没有共享 Downloads 概念）。
class ExportService {
  ExportService._();

  static Future<String> saveCsv(String fileName, Uint8List bytes) =>
      _save(fileName, bytes, 'csv', MimeType.csv);

  static Future<String> savePdf(String fileName, Uint8List bytes) =>
      _save(fileName, bytes, 'pdf', MimeType.pdf);

  static Future<String> _save(
    String fileName,
    Uint8List bytes,
    String extension,
    MimeType mimeType,
  ) async {
    if (kIsWeb) {
      throw UnsupportedError('Web 端未启用文件保存');
    }
    if (Platform.isAndroid) {
      final name = fileName.endsWith('.$extension')
          ? fileName.substring(0, fileName.length - extension.length - 1)
          : fileName;
      // saveFile 写的是应用私有目录；saveToDownloads 才走 MediaStore 的 Download/。
      final path = await FileSaver.instance.saveToDownloads(
        name: name,
        bytes: bytes,
        fileExtension: extension,
        mimeType: mimeType,
      );
      if (path == null) {
        throw StateError('无法写入系统下载目录');
      }
      return path;
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)]),
    );
    return file.path;
  }
}
