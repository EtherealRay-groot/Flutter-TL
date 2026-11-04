import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/chart/axis_range_policy.dart';
import '../core/chart/chart_layout.dart';
import '../core/chart/chart_model.dart';
import '../core/chart/time_axis.dart';
import '../core/protocol/logistics_info.dart';
import '../core/protocol/record_entry.dart';
import '../state/app_state.dart';
import 'pdf_chart_renderer.dart';

/// 生成与原 Android 版 `savePdfToDownloads()` 布局一致的 PDF 报告。
///
/// 本类**不加载字体**：调用方通过 [build] 的 `font` / `boldFont` 传入已加载
/// 的 CJK 字体（通常是 `pw.Font.ttf(...)` 或 `PdfTtfFont`）。
///
/// 与图表渲染器一样，所有绘图直接在 `PdfGraphics` 上进行（不经过 widgets
/// 排版引擎），坐标沿用 Android Canvas 的"页面左上角为原点、y 向下"约定，
/// 写进 PDF 时统一换算成 y 向上的用户空间。
///
/// 分页分两阶段完成：
/// 1. **布局阶段**：只算坐标，把每一页要画的图元记录成闭包；
/// 2. **绘制阶段**：`Document.save()` 逐页回放闭包并真正画到画布上。
///
/// 这样分页判定（图表原子块、表格页脚阈值）在纯布局阶段就能确定，
/// 不依赖 `package:pdf` 何时执行 page build 回调。
class PdfReportBuilder {
  PdfReportBuilder._();

  // ---------- 页面与版式常量（与 Kotlin 一致） ----------

  static const double pageWidth = 595;
  static const double pageHeight = 842;
  static const double leftMargin = 40;
  static const double topMargin = 40;
  static const double rightMargin = pageWidth - 40;
  static const double rowHeight = 20;
  static const double sectionHeight = 22;

  static const double col1X = leftMargin + 8;
  static const double col2X =
      leftMargin + (rightMargin - leftMargin) / 2 + 8;

  /// 表格四列的左边距，与 Kotlin 的 `colX` 完全一致。
  static const List<double> colX = <double>[
    leftMargin,
    leftMargin + 50,
    leftMargin + 220,
    leftMargin + 360,
  ];

  // ---------- 颜色 ----------

  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _blue = PdfColor.fromInt(0xFF0050B4);
  static const PdfColor _red = PdfColor.fromInt(0xFFFF0000);
  static const PdfColor _pageNumberInk = PdfColor.fromInt(0xFF666666);

  /// Android 用的是 `Color.argb(35, 0, 0, 0)`（半透明黑）。
  ///
  /// `package:pdf` 的 `PdfColor` 虽然有 alpha 字段，但 `setFillColor`
  /// 不会输出 `ExtGState`，直接传半透明黑会画成纯黑。报告底色是白纸，
  /// 所以这里预先把它与白色合成成不透明灰：255 × (1 − 35/255) ≈ 220。
  static const PdfColor _sectionBackground = PdfColor(
    0.8627450980392157,
    0.8627450980392157,
    0.8627450980392157,
  );

  /// `Color.argb(20, 0, 0, 0)` 与白色合成：255 × (1 − 20/255) ≈ 235。
  static const PdfColor _rowBackground = PdfColor(
    0.9215686274509803,
    0.9215686274509803,
    0.9215686274509803,
  );

  /// 生成 PDF。调用方负责提供字体；记录为空（或过滤后为空）时抛
  /// [ArgumentError]，与 Kotlin「没有记录可导出 / 过滤后无记录」一致。
  ///
  /// [fileName] 只用于页眉右上角的文件名，缺省为
  /// `$deviceName-yyyyMMdd_HHmmss.pdf`。
  static Future<Uint8List> build({
    required List<RecordEntry> records,
    required String deviceName,
    required String deviceAddress,
    required TemperatureUnit unit,
    double? thresholdLowC,
    double? thresholdHighC,
    LogisticsInfo? logistics,
    int? filterStartTime,
    int? filterEndTime,
    required PdfFont font,
    required PdfFont boldFont,
    void Function(double progress)? onProgress,
    String? fileName,
  }) async {
    // 与 Kotlin 一样：阈值一律按 ℃ 解释，且非有限值视为未设置。
    final low = thresholdLowC != null && thresholdLowC.isFinite
        ? thresholdLowC
        : null;
    final high = thresholdHighC != null && thresholdHighC.isFinite
        ? thresholdHighC
        : null;

    final tableRecords = records.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (filterStartTime != null || filterEndTime != null) {
      tableRecords.removeWhere(
        (rec) =>
            (filterStartTime != null && rec.timestamp < filterStartTime) ||
            (filterEndTime != null && rec.timestamp > filterEndTime),
      );
    }
    if (tableRecords.isEmpty) {
      throw ArgumentError('过滤后无记录');
    }

    final stats = _Stats.compute(tableRecords, low, high);
    final chartPoints = tableRecords
        .map(
          (r) => ChartPoint(
            tSec: r.timestamp,
            temperatureC: r.temperature,
            humidity: r.humidity,
          ),
        )
        .toList(growable: false);

    final now = DateTime.now();
    final resolvedFileName =
        fileName ?? '$deviceName-${formatFileStamp(now)}.pdf';

    final document = pw.Document();
    // 字体可能是在另一份 PdfDocument 上创建的。PdfObject.ref() 的对象号
    // 只在原文档内有效，跨文档直接使用会指向错误对象，所以按字节克隆到
    // 本文档；Type1 字体无法克隆时退回内置 Helvetica。
    final regular = _adoptFont(font, document.document);
    final bold = identical(font, boldFont)
        ? regular
        : _adoptFont(boldFont, document.document, bold: true);

    final layout = _ReportLayout(
      regular: regular,
      bold: bold,
      deviceName: deviceName,
      deviceAddress: deviceAddress,
      unit: unit,
      thresholdLowC: low,
      thresholdHighC: high,
      logistics: logistics,
      records: tableRecords,
      points: chartPoints,
      stats: stats,
      fileName: resolvedFileName,
      createdAt: now,
      onProgress: onProgress,
    );

    final pages = layout.run();
    final total = pages.length;

    for (var i = 0; i < total; i++) {
      final ops = pages[i].ops;
      final pageNumber = i + 1;
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (context) {
            final painter = _Painter(context.canvas, regular, bold);
            for (final op in ops) {
              op(painter);
            }
            final label = '$pageNumber / $total';
            final width = _measure(
              regular,
              _sanitize(regular, label),
              9,
            );
            painter.text(
              label,
              (pageWidth - width) / 2,
              pageHeight - 16,
              font: regular,
              size: 9,
              color: _pageNumberInk,
            );
            return pw.SizedBox.shrink();
          },
        ),
      );
    }

    final bytes = await document.save();
    onProgress?.call(1);
    return bytes;
  }

  /// 把 [source] 绑定到本文档。TTF 按字节重建；其它字体无法安全跨文档
  /// 复用，退回内置 Helvetica（中文会被降级成 `?`）。
  static PdfFont _adoptFont(
    PdfFont source,
    PdfDocument document, {
    bool bold = false,
  }) {
    if (source.pdfDocument == document) {
      return source;
    }
    if (source is PdfTtfFont) {
      return PdfTtfFont(document, source.font.bytes);
    }
    return bold
        ? PdfFont.helveticaBold(document)
        : PdfFont.helvetica(document);
  }

  /// 逐字符累加 advance 的宽度测量，与 `pdf_chart_renderer.dart` 一致。
  static double _measure(PdfFont font, String text, double sizePt) {
    var advance = 0.0;
    for (final rune in text.runes) {
      advance += font.glyphMetrics(rune).advanceWidth;
    }
    return advance * sizePt;
  }

  /// 字体不支持的字符替换成 `?`，避免 `putText` 抛异常导致整份报告失败。
  static String _sanitize(PdfFont font, String text) {
    final buffer = StringBuffer();
    var changed = false;
    for (final rune in text.runes) {
      if (_supports(font, rune)) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write('?');
        changed = true;
      }
    }
    return changed ? buffer.toString() : text;
  }

  static bool _supports(PdfFont font, int rune) {
    if (rune < 0) {
      return false;
    }
    if (font is PdfTtfFont) {
      return font.isRuneSupported(rune);
    }
    // 内置 Type1 字体使用 WinAnsi 编码。
    return rune <= 0xFF;
  }

  /// 按像素宽度折行。逐字符测量而不是按字数切：中英文宽度差很大。
  static List<String> wrapText(
    String text,
    PdfFont font,
    double sizePt,
    double maxWidth,
  ) {
    if (text.isEmpty) {
      return <String>[];
    }
    final out = <String>[];
    final buffer = StringBuffer();
    var width = 0.0;
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      final charWidth = _measure(font, char, sizePt);
      if (width + charWidth > maxWidth && buffer.isNotEmpty) {
        out.add(buffer.toString());
        buffer.clear();
        width = 0;
      }
      buffer.write(char);
      width += charWidth;
    }
    if (buffer.isNotEmpty) {
      out.add(buffer.toString());
    }
    return out;
  }

  /// `yyyy-MM-dd HH:mm:ss`（本地时间），对应 Kotlin 的 `SimpleDateFormat`。
  static String formatTimestamp(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-'
        '${two(time.day)} ${two(time.hour)}:${two(time.minute)}:'
        '${two(time.second)}';
  }

  /// 文件名用的 `yyyyMMdd_HHmmss`。
  static String formatFileStamp(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year.toString().padLeft(4, '0')}${two(time.month)}'
        '${two(time.day)}_${two(time.hour)}${two(time.minute)}'
        '${two(time.second)}';
  }

  /// 与 Kotlin `formatDuration` 一致。
  static String formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h${m}m${s}s';
    if (m > 0) return '${m}m${s}s';
    return '${s}s';
  }
}

/// 单页要画的图元。闭包在布局阶段生成，绘制阶段才执行。
class _PagePlan {
  final List<void Function(_Painter)> ops = <void Function(_Painter)>[];
}

/// 一次遍历算出的统计量（单位仍是 ℃）。
class _Stats {
  const _Stats({
    required this.maxTemp,
    required this.minTemp,
    required this.avgTemp,
    required this.maxHum,
    required this.minHum,
    required this.avgHum,
    required this.alarmCount,
    required this.firstTime,
    required this.lastTime,
  });

  final double maxTemp;
  final double minTemp;
  final double avgTemp;
  final int maxHum;
  final int minHum;
  final int avgHum;
  final int alarmCount;
  final int firstTime;
  final int lastTime;

  static _Stats compute(
    List<RecordEntry> records,
    double? thresholdLowC,
    double? thresholdHighC,
  ) {
    var maxTemp = double.negativeInfinity;
    var minTemp = double.infinity;
    var sumTemp = 0.0;
    var maxHum = -0x80000000;
    var minHum = 0x7fffffff;
    var sumHum = 0;
    var alarmCount = 0;
    int? firstTime;
    int? lastTime;

    for (final rec in records) {
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
      if (firstTime == null || ts < firstTime) firstTime = ts;
      if (lastTime == null || ts > lastTime) lastTime = ts;
    }

    final n = records.length;
    return _Stats(
      maxTemp: maxTemp,
      minTemp: minTemp,
      avgTemp: sumTemp / n,
      maxHum: maxHum,
      minHum: minHum,
      avgHum: sumHum ~/ n,
      alarmCount: alarmCount,
      firstTime: firstTime!,
      lastTime: lastTime!,
    );
  }
}

/// 负责布局。y 是"从页面顶部往下"的坐标。
class _ReportLayout {
  _ReportLayout({
    required this.regular,
    required this.bold,
    required this.deviceName,
    required this.deviceAddress,
    required this.unit,
    required this.thresholdLowC,
    required this.thresholdHighC,
    required this.logistics,
    required this.records,
    required this.points,
    required this.stats,
    required this.fileName,
    required this.createdAt,
    required this.onProgress,
  });

  final PdfFont regular;
  final PdfFont bold;
  final String deviceName;
  final String deviceAddress;
  final TemperatureUnit unit;
  final double? thresholdLowC;
  final double? thresholdHighC;
  final LogisticsInfo? logistics;
  final List<RecordEntry> records;
  final List<ChartPoint> points;
  final _Stats stats;
  final String fileName;
  final DateTime createdAt;
  final void Function(double progress)? onProgress;

  final List<_PagePlan> _pages = <_PagePlan>[_PagePlan()];
  double y = PdfReportBuilder.topMargin;

  _PagePlan get _page => _pages.last;

  TemperatureDisplay get _display => unit == TemperatureUnit.fahrenheit
      ? TemperatureDisplay.fahrenheit
      : TemperatureDisplay.celsius;

  String get _temperatureSymbol => unit.symbol;

  double _toUnit(double celsius) =>
      unit == TemperatureUnit.fahrenheit ? celsius * 9 / 5 + 32 : celsius;

  List<_PagePlan> run() {
    _header();
    _deviceInfo();
    _logisticsInfo();
    _recordsInfo();
    _statistics();
    _chart();
    _table();
    return _pages;
  }

  // ---------- 图元记录 ----------

  void _newPage() {
    _pages.add(_PagePlan());
    y = PdfReportBuilder.topMargin;
  }

  void _addText(
    String text,
    double x,
    double baselineY, {
    PdfFont? font,
    double size = 10,
    PdfColor color = PdfReportBuilder._ink,
  }) {
    final resolvedFont = font ?? regular;
    _page.ops.add(
      (painter) => painter.text(
        text,
        x,
        baselineY,
        font: resolvedFont,
        size: size,
        color: color,
      ),
    );
  }

  void _addTextRight(
    String text,
    double rightX,
    double baselineY, {
    PdfFont? font,
    double size = 10,
    PdfColor color = PdfReportBuilder._ink,
  }) {
    final resolvedFont = font ?? regular;
    final width = PdfReportBuilder._measure(
      resolvedFont,
      PdfReportBuilder._sanitize(resolvedFont, text),
      size,
    );
    _addText(
      text,
      rightX - width,
      baselineY,
      font: resolvedFont,
      size: size,
      color: color,
    );
  }

  void _addHighlight(
    double x,
    double top,
    double width,
    double height,
    PdfColor color,
  ) {
    _page.ops.add((painter) => painter.rect(x, top, width, height, color));
  }

  void _addHighlightRound(
    double x,
    double top,
    double width,
    double height,
    PdfColor color,
  ) {
    _page.ops.add(
      (painter) => painter.roundRect(x, top, width, height, 3, color),
    );
  }

  void _addLine(double x1, double y1, double x2, double y2) {
    _page.ops.add(
      (painter) => painter.line(
        x1,
        y1,
        x2,
        y2,
        width: 1,
        color: PdfReportBuilder._ink,
      ),
    );
  }

  // ---------- 各区块 ----------

  void _header() {
    _addText(
      '数据报告',
      PdfReportBuilder.leftMargin,
      y + 22,
      font: bold,
      size: 22,
      color: PdfReportBuilder._blue,
    );
    _addTextRight(
      fileName,
      PdfReportBuilder.rightMargin,
      y + 12,
      size: 9,
    );
    _addTextRight(
      '创建时间：${PdfReportBuilder.formatTimestamp(createdAt)}',
      PdfReportBuilder.rightMargin,
      y + 24,
      size: 9,
    );

    y += 38;
    _addLine(
      PdfReportBuilder.leftMargin,
      y,
      PdfReportBuilder.rightMargin,
      y,
    );
    y += 14;
  }

  void _sectionBar(String title) {
    _addHighlightRound(
      PdfReportBuilder.leftMargin,
      y,
      PdfReportBuilder.rightMargin - PdfReportBuilder.leftMargin,
      PdfReportBuilder.sectionHeight,
      PdfReportBuilder._sectionBackground,
    );
    _addText(
      '  $title',
      PdfReportBuilder.leftMargin,
      y + 15,
      font: bold,
      size: 12,
    );
    y += PdfReportBuilder.sectionHeight + 12;
  }

  void _deviceInfo() {
    _sectionBar('设备信息');

    _addText('设备名称：Temperature logger', PdfReportBuilder.col1X, y);
    y += 14;
    _addText('蓝牙广播名称：$deviceName', PdfReportBuilder.col1X, y);
    _addText(
      '存储条数：65535条',
      PdfReportBuilder.col2X,
      y - 14,
    );
    _addText('测量范围：-30~85°', PdfReportBuilder.col2X, y);
    y += 14;
    _addText('Mac地址：$deviceAddress', PdfReportBuilder.col1X, y);
    y += 18;
  }

  void _logisticsInfo() {
    final info = logistics;
    if (info == null || !info.hasContent) {
      return;
    }

    final quantity = info.quantity % 1.0 == 0.0
        ? info.quantity.toInt().toString()
        : info.quantity.toString();
    final quantityWithUnit =
        info.unit.isNotEmpty ? '$quantity ${info.unit}' : quantity;

    final shortPairs = <(String, String)>[
      ('公司名称', info.company),
      ('货物单号', info.goodsNo),
      ('货物箱号', info.boxNo),
      ('发货人', info.shipper),
      ('收货人', info.consignee),
      ('数量', quantityWithUnit),
    ];
    final longFields = <(String, String)>[
      ('货物描述', info.goodsDesc),
      ('发货地址', info.shipAddr),
      ('收货地址', info.recvAddr),
      ('备注', info.remark),
    ];

    const double bodySize = 10;
    // 预留「标签：」宽度，与 Kotlin 的 -56pt 一致。
    final wrapWidth =
        (PdfReportBuilder.rightMargin - PdfReportBuilder.leftMargin) - 56;

    var longLineCount = 0;
    for (final (_, value) in longFields) {
      longLineCount += value.isEmpty
          ? 1
          : PdfReportBuilder.wrapText(
              value,
              regular,
              bodySize,
              wrapWidth,
            ).length;
    }

    final shortRows = (shortPairs.length + 1) ~/ 2;
    final contentHeight = shortRows * 14 + longLineCount * 14;

    // Kotlin 的 boxHeight 少算了标题条下方的 12pt 间距，导致最后一行会
    // 落在灰底之外。这里补上，保证"灰底包住整段内容"。
    final boxHeight = PdfReportBuilder.sectionHeight + 12 + contentHeight + 8;

    if (y + boxHeight > ChartLayout.pageBottomLimitPt) {
      _newPage();
    }

    _addHighlightRound(
      PdfReportBuilder.leftMargin,
      y,
      PdfReportBuilder.rightMargin - PdfReportBuilder.leftMargin,
      boxHeight,
      PdfReportBuilder._sectionBackground,
    );
    _addText(
      '  物流信息',
      PdfReportBuilder.leftMargin,
      y + 15,
      font: bold,
      size: 12,
    );
    y += PdfReportBuilder.sectionHeight + 12;

    for (var i = 0; i < shortPairs.length; i += 2) {
      final (label1, value1) = shortPairs[i];
      _addText('$label1：$value1', PdfReportBuilder.col1X, y);
      if (i + 1 < shortPairs.length) {
        final (label2, value2) = shortPairs[i + 1];
        _addText('$label2：$value2', PdfReportBuilder.col2X, y);
      }
      y += 14;
    }

    for (final (label, value) in longFields) {
      final lines = value.isEmpty
          ? <String>['-']
          : PdfReportBuilder.wrapText(
              value,
              regular,
              bodySize,
              wrapWidth,
            );
      _addText('$label：${lines.first}', PdfReportBuilder.col1X, y);
      y += 14;
      for (final extra in lines.skip(1)) {
        _addText('    $extra', PdfReportBuilder.col1X, y);
        y += 14;
      }
    }
    y += 8;
  }

  void _recordsInfo() {
    _sectionBar('记录信息');

    _addText('记录总数：${records.length}', PdfReportBuilder.col1X, y);
    y += 14;
    if (thresholdLowC != null || thresholdHighC != null) {
      _addText('报警条数：${stats.alarmCount}', PdfReportBuilder.col1X, y);
      y += 14;
    }
    _addText(
      '起始时间：${PdfReportBuilder.formatTimestamp(_fromEpoch(stats.firstTime))}',
      PdfReportBuilder.col1X,
      y,
    );
    _addText(
      '结束时间：${PdfReportBuilder.formatTimestamp(_fromEpoch(stats.lastTime))}',
      PdfReportBuilder.col2X,
      y,
    );
    y += 14;
    _addText(
      '记录时长：${PdfReportBuilder.formatDuration(stats.lastTime - stats.firstTime)}',
      PdfReportBuilder.col1X,
      y,
    );
    y += 18;
  }

  void _statistics() {
    _sectionBar('统计信息');

    final symbol = _temperatureSymbol;
    _addText(
      '最高温度：${_toUnit(stats.maxTemp).toStringAsFixed(2)}$symbol',
      PdfReportBuilder.col1X,
      y,
    );
    _addText('最高湿度：${stats.maxHum}%', PdfReportBuilder.col2X, y);
    y += 14;

    _addText(
      '最低温度：${_toUnit(stats.minTemp).toStringAsFixed(2)}$symbol',
      PdfReportBuilder.col1X,
      y,
    );
    _addText('最低湿度：${stats.minHum}%', PdfReportBuilder.col2X, y);
    y += 14;

    _addText(
      '平均温度：${_toUnit(stats.avgTemp).toStringAsFixed(2)}$symbol',
      PdfReportBuilder.col1X,
      y,
    );
    _addText('平均湿度：${stats.avgHum}%', PdfReportBuilder.col2X, y);
    y += 18;
  }

  void _chart() {
    // 图表是原子块：空间不够就整体挪到下一页，绝不压缩、绝不裁切。
    if (ChartLayout.needsNewPage(y)) {
      _newPage();
    }

    _addHighlightRound(
      PdfReportBuilder.leftMargin,
      y,
      PdfReportBuilder.rightMargin - PdfReportBuilder.leftMargin,
      PdfReportBuilder.sectionHeight,
      PdfReportBuilder._sectionBackground,
    );
    _addText(
      '  温湿度曲线',
      PdfReportBuilder.leftMargin,
      y + 15,
      font: bold,
      size: 12,
    );
    y += PdfReportBuilder.sectionHeight + ChartLayout.titleGapPt;

    final chartTop = y;
    _page.ops.add(
      (painter) => PdfChartRenderer.draw(
        painter.canvas,
        topYStart: chartTop,
        contentLeft: PdfReportBuilder.leftMargin,
        contentRight: PdfReportBuilder.rightMargin,
        points: points,
        display: _display,
        thresholdLowC: thresholdLowC,
        thresholdHighC: thresholdHighC,
        tz: ChartTimeZone.local(),
        pageHeight: PdfReportBuilder.pageHeight,
        font: painter.regular,
        boldFont: painter.bold,
        onProgress: onProgress == null
            ? null
            : (progress) => onProgress!(0.10 + progress * 0.15),
      ),
    );
    y += ChartLayout.plotBlockHeightPt;
  }

  void _tableHeader() {
    final headers = <String>[
      '序号',
      '时间',
      '温度($_temperatureSymbol)',
      '湿度(%)',
    ];
    for (var i = 0; i < headers.length; i++) {
      _addText(
        headers[i],
        PdfReportBuilder.colX[i],
        y,
        font: bold,
        size: 11,
      );
    }
    y += PdfReportBuilder.rowHeight;
  }

  void _checkTablePageBreak() {
    if (y > ChartLayout.pageBottomLimitPt) {
      _newPage();
      _tableHeader();
    }
  }

  void _table() {
    // 表格上方分隔线。
    _addLine(
      PdfReportBuilder.leftMargin,
      y,
      PdfReportBuilder.rightMargin,
      y,
    );
    y += 16;

    _tableHeader();

    final total = records.length;
    // 局部变量才能让分析器完成 null 提升（公共 final 字段不会被提升）。
    final low = thresholdLowC;
    final high = thresholdHighC;
    for (var i = 0; i < total; i++) {
      final entry = records[i];
      final isAlarm =
          (low != null && entry.temperature < low) ||
          (high != null && entry.temperature > high);
      final color = isAlarm ? PdfReportBuilder._red : PdfReportBuilder._ink;

      // Kotlin 的交替行底色：奇数行（0 起）从 y-14 画到 y+6。
      if (i % 2 == 1) {
        _addHighlight(
          PdfReportBuilder.leftMargin,
          y - 14,
          PdfReportBuilder.rightMargin - PdfReportBuilder.leftMargin,
          PdfReportBuilder.rowHeight,
          PdfReportBuilder._rowBackground,
        );
      }

      final cells = <String>[
        '${i + 1}',
        PdfReportBuilder.formatTimestamp(_fromEpoch(entry.timestamp)),
        _toUnit(entry.temperature).toStringAsFixed(2),
        '${entry.humidity}',
      ];
      for (var c = 0; c < cells.length; c++) {
        _addText(
          cells[c],
          PdfReportBuilder.colX[c],
          y,
          color: color,
        );
      }

      y += PdfReportBuilder.rowHeight;
      _checkTablePageBreak();

      if (i % 100 == 0 && onProgress != null) {
        final progress = 0.25 + (i / total) * 0.70;
        _page.ops.add((_) {
          onProgress?.call(progress);
        });
      }
    }
  }

  static DateTime _fromEpoch(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
}

/// 把布局阶段记录下来的图元真正画到一页上。
class _Painter {
  _Painter(this.canvas, this.regular, this.bold);

  final PdfGraphics canvas;
  final PdfFont regular;
  final PdfFont bold;

  double get _pageHeight => PdfReportBuilder.pageHeight;

  void text(
    String text,
    double x,
    double baselineY, {
    required PdfFont font,
    required double size,
    required PdfColor color,
  }) {
    final safe = PdfReportBuilder._sanitize(font, text);
    canvas
      ..setFillColor(color)
      ..drawString(font, size, safe, x, _pageHeight - baselineY);
  }

  void rect(
    double x,
    double top,
    double width,
    double height,
    PdfColor color,
  ) {
    canvas
      ..setFillColor(color)
      ..drawRect(x, _pageHeight - top - height, width, height)
      ..fillPath();
  }

  void roundRect(
    double x,
    double top,
    double width,
    double height,
    double radius,
    PdfColor color,
  ) {
    canvas
      ..setFillColor(color)
      ..drawRRect(
        x,
        _pageHeight - top - height,
        width,
        height,
        radius,
        radius,
      )
      ..fillPath();
  }

  void line(
    double x1,
    double y1,
    double x2,
    double y2, {
    required double width,
    required PdfColor color,
  }) {
    canvas
      ..setStrokeColor(color)
      ..setLineWidth(width)
      ..setLineDashPattern()
      ..moveTo(x1, _pageHeight - y1)
      ..lineTo(x2, _pageHeight - y2)
      ..strokePath();
  }
}
