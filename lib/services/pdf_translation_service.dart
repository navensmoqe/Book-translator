import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_saver/file_saver.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as px;
import 'package:printing/printing.dart';

import 'translator_router.dart';

class PdfTextRegion {
  PdfTextRegion({
    required this.id,
    required this.rect,
    required this.source,
    required this.sourceLineCount,
  });

  final int id;
  final ui.Rect rect;
  final String source;
  final int sourceLineCount;

  String translated = '';
  PdfColor background = PdfColors.white;
  PdfColor foreground = PdfColors.black;
}

class _SampledColors {
  const _SampledColors(this.background, this.foreground);
  final PdfColor background;
  final PdfColor foreground;
}

class _LayoutBox {
  const _LayoutBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;
}

class _SectionText {
  const _SectionText(this.number, this.title);
  final String number;
  final String title;
}

class PdfTranslationService {
  PdfTranslationService(this.router);

  final TranslatorRouter router;

  Future<String?> translate({
    required String inputPath,
    required void Function(double progress, String status) onProgress,
  }) async {
    final source = await px.PdfDocument.openFile(inputPath);
    final out = pw.Document(compress: true);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final tempDir = await getTemporaryDirectory();
    final arabicFont = await PdfGoogleFonts.cairoRegular();

    try {
      final total = source.pagesCount;
      for (var pageIndex = 1; pageIndex <= total; pageIndex++) {
        onProgress(
          (pageIndex - 1) / total,
          'تحليل الصفحة $pageIndex من $total…',
        );

        final page = await source.getPage(pageIndex);
        try {
          const scale = 1.55;
          final rendered = await page.render(
            width: page.width * scale,
            height: page.height * scale,
            format: px.PdfPageImageFormat.jpeg,
            quality: 88,
            backgroundColor: '#FFFFFF',
          );
          if (rendered == null) {
            throw Exception('تعذر تحويل الصفحة $pageIndex إلى صورة.');
          }

          final imageBytes = rendered.bytes;
          final tempImage = File('${tempDir.path}/pdf_translate_$pageIndex.jpg');
          await tempImage.writeAsBytes(imageBytes, flush: true);

          final inputImage = InputImage.fromFilePath(tempImage.path);
          final recognized = await recognizer.processImage(inputImage);

          // Merge only genuinely adjacent OCR lines into coherent text regions.
          // This gives the translator sentence/paragraph context while avoiding
          // collapsing distant table cells into one giant block.
          final regions = _buildRegions(recognized);

          if (regions.isNotEmpty) {
            final chunks = _chunk(regions);
            for (var c = 0; c < chunks.length; c++) {
              onProgress(
                ((pageIndex - 1) + ((c + 0.35) / chunks.length)) / total,
                'ترجمة الصفحة $pageIndex من $total — جزء ${c + 1}/${chunks.length}…',
              );
              final part = chunks[c];
              final translated = await router.translateItems(
                part
                    .map((e) => TranslationItem(id: e.id, text: e.source))
                    .toList(),
              );
              for (final item in part) {
                item.translated = _normalizeTranslated(
                  translated[item.id] ?? item.source,
                );
              }
            }

            // Match the replacement rectangle to the page background instead
            // of always painting bright white boxes over colored areas.
            await _sampleRegionColors(imageBytes, regions);
          }

          final renderedWidth =
              (rendered.width ?? (page.width * scale).round()).toDouble();
          final renderedHeight =
              (rendered.height ?? (page.height * scale).round()).toDouble();
          final pageWidth = page.width;
          final pageHeight = page.height;
          final sx = pageWidth / renderedWidth;
          final sy = pageHeight / renderedHeight;
          final background = pw.MemoryImage(imageBytes);

          out.addPage(
            pw.Page(
              pageFormat: PdfPageFormat(pageWidth, pageHeight),
              margin: pw.EdgeInsets.zero,
              build: (_) {
                final children = <pw.Widget>[
                  pw.Positioned.fill(
                    child: pw.Image(background, fit: pw.BoxFit.fill),
                  ),
                ];

                for (final region in regions) {
                  final translated = region.translated.trim().isEmpty
                      ? region.source
                      : region.translated.trim();

                  final box = _layoutBox(
                    region,
                    regions,
                    translated,
                    pageWidth,
                    pageHeight,
                    sx,
                    sy,
                  );

                  final innerWidth =
                      math.max(2.0, box.width - 3.0).toDouble();
                  final innerHeight =
                      math.max(2.0, box.height - 2.0).toDouble();

                  final fontSize = _fitFontSize(
                    translated,
                    innerWidth,
                    innerHeight,
                    region.sourceLineCount,
                  );

                  final maxLines = math.max(
                    1,
                    (innerHeight / (fontSize * 1.22)).floor(),
                  );

                  final section = _sectionText(region.source, translated);
                  final displayText = _displayArabic(translated);

                  final textStyle = pw.TextStyle(
                    font: arabicFont,
                    fontSize: fontSize,
                    color: region.foreground,
                  );

                  final textWidget = section == null
                      ? pw.Text(
                          displayText,
                          textDirection: pw.TextDirection.rtl,
                          textAlign: pw.TextAlign.right,
                          softWrap: true,
                          maxLines: maxLines,
                          overflow: pw.TextOverflow.clip,
                          style: textStyle,
                        )
                      : pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.end,
                          crossAxisAlignment: pw.CrossAxisAlignment.center,
                          children: [
                            pw.Flexible(
                              child: pw.Text(
                                _displayArabic(section.title),
                                textDirection: pw.TextDirection.rtl,
                                textAlign: pw.TextAlign.right,
                                softWrap: true,
                                maxLines: maxLines,
                                overflow: pw.TextOverflow.clip,
                                style: textStyle,
                              ),
                            ),
                            pw.SizedBox(width: 2.4),
                            pw.Text(
                              section.number,
                              textDirection: pw.TextDirection.ltr,
                              textAlign: pw.TextAlign.right,
                              style: textStyle,
                            ),
                          ],
                        );

                  children.add(
                    pw.Positioned(
                      left: box.left,
                      top: box.top,
                      child: pw.Container(
                        width: box.width,
                        height: box.height,
                        color: region.background,
                        padding: const pw.EdgeInsets.symmetric(
                          horizontal: 1.5,
                          vertical: 1.0,
                        ),
                        alignment: pw.Alignment.centerRight,
                        child: textWidget,
                      ),
                    ),
                  );
                }

                return pw.Stack(children: children);
              },
            ),
          );

          if (await tempImage.exists()) {
            await tempImage.delete();
          }
        } finally {
          await page.close();
        }
      }

      onProgress(0.97, 'إنشاء ملف PDF النهائي…');
      final bytes = await out.save();
      final stamp =
          DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final saved = await FileSaver.instance.saveToDownloads(
        name: 'translated_ar_$stamp',
        bytes: bytes,
        fileExtension: 'pdf',
        mimeType: MimeType.pdf,
        subfolder: 'PDF-Arabic-Translator',
      );
      onProgress(1, 'اكتملت الترجمة وحُفظ الملف في Downloads.');
      return saved;
    } finally {
      await recognizer.close();
      await source.close();
    }
  }

  List<PdfTextRegion> _buildRegions(RecognizedText recognized) {
    final result = <PdfTextRegion>[];
    var nextId = 0;

    for (final block in recognized.blocks) {
      final lines = block.lines
          .where((line) => line.text.trim().isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;

      var group = <TextLine>[];

      void flush() {
        if (group.isEmpty) return;

        var rect = group.first.boundingBox;
        for (var i = 1; i < group.length; i++) {
          rect = _union(rect, group[i].boundingBox);
        }

        final source = _joinSourceLines(group);
        if (source.trim().isNotEmpty) {
          result.add(
            PdfTextRegion(
              id: nextId++,
              rect: rect,
              source: source,
              sourceLineCount: group.length,
            ),
          );
        }
        group = <TextLine>[];
      }

      for (final line in lines) {
        if (group.isEmpty) {
          group.add(line);
          continue;
        }

        if (_shouldJoin(group.last, line)) {
          group.add(line);
        } else {
          flush();
          group.add(line);
        }
      }
      flush();
    }

    return result;
  }

  bool _shouldJoin(TextLine previous, TextLine next) {
    final a = previous.boundingBox;
    final b = next.boundingBox;
    final lineHeight = math.max(a.height, b.height);
    if (lineHeight <= 0) return false;

    final verticalGap = b.top - a.bottom;

    // Paragraph lines are normally close. Table rows and unrelated labels
    // usually have noticeably larger vertical gaps.
    if (verticalGap > lineHeight * 0.55) return false;
    if (verticalGap < -lineHeight * 0.45) return false;

    final overlap = math.max(
      0.0,
      math.min(a.right, b.right) - math.max(a.left, b.left),
    );
    final minWidth = math.max(1.0, math.min(a.width, b.width));
    final overlapRatio = overlap / minWidth;

    final leftDelta = (a.left - b.left).abs();
    final alignedLeft = leftDelta <= lineHeight * 0.9;

    return overlapRatio >= 0.42 || alignedLeft;
  }

  ui.Rect _union(ui.Rect a, ui.Rect b) {
    return ui.Rect.fromLTRB(
      math.min(a.left, b.left),
      math.min(a.top, b.top),
      math.max(a.right, b.right),
      math.max(a.bottom, b.bottom),
    );
  }

  String _joinSourceLines(List<TextLine> lines) {
    final buffer = StringBuffer();

    for (var i = 0; i < lines.length; i++) {
      var text = lines[i].text.trim();
      if (text.isEmpty) continue;

      if (buffer.isEmpty) {
        buffer.write(text);
        continue;
      }

      final current = buffer.toString();
      if (current.endsWith('-') && RegExp(r'[A-Za-z]-$').hasMatch(current)) {
        final withoutHyphen = current.substring(0, current.length - 1);
        buffer
          ..clear()
          ..write(withoutHyphen)
          ..write(text);
      } else {
        buffer
          ..write(' ')
          ..write(text);
      }
    }

    return buffer.toString();
  }

  String _normalizeTranslated(String value) {
    var result = value
        .replaceAll('\u200b', '')
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
        .trim();

    // Some models occasionally put a full stop before an isolated number in
    // RTL output (".125"). Remove only that accidental leading dot while
    // keeping normal decimal numbers untouched.
    result = result.replaceAllMapped(
      RegExp(r'(^|[\s:،؛])\.(\d+)'),
      (m) => '${m.group(1) ?? ''}${m.group(2) ?? ''}',
    );

    return result;
  }

  _LayoutBox _layoutBox(
    PdfTextRegion region,
    List<PdfTextRegion> all,
    String text,
    double pageWidth,
    double pageHeight,
    double sx,
    double sy,
  ) {
    final r = region.rect;
    final baseHeight = math.max(5.0, r.height * sy + 1.8).toDouble();
    final originalWidth = math.max(6.0, r.width * sx + 2.6).toDouble();

    final isTableLike = _isTableLike(region, all);
    final widthGrowth = isTableLike
        ? 0.0
        : math.min(pageWidth * 0.045, originalWidth * 0.10).toDouble();

    var left = math.max(0.0, r.left * sx - 1.3 - widthGrowth).toDouble();
    final top = math.max(0.0, r.top * sy - 0.9).toDouble();
    var width = math
        .min(
          pageWidth - left,
          originalWidth + widthGrowth * 2,
        )
        .toDouble();

    if (width < 6.0) width = 6.0;

    final sourceLines = math.max(1, region.sourceLineCount);
    final sourceLineHeight = math.max(7.6, (r.height * sy) / sourceLines);
    final preferredFont =
        math.min(16.5, math.max(8.0, sourceLineHeight * 0.92)).toDouble();
    final estimatedLines = _estimateWrappedLines(
      _displayArabic(text),
      math.max(2.0, width - 3.0),
      preferredFont,
    );
    final desiredHeight = math.max(
      baseHeight,
      estimatedLines * preferredFont * 1.24 + 2.2,
    ).toDouble();

    var nearestBelow = pageHeight;
    for (final other in all) {
      if (identical(other, region)) continue;
      if (other.rect.top <= r.top + 0.5) continue;

      final overlap = math.max(
        0.0,
        math.min(r.right, other.rect.right) -
            math.max(r.left, other.rect.left),
      );
      final minWidth = math.max(1.0, math.min(r.width, other.rect.width));
      if (overlap / minWidth < 0.22) continue;

      nearestBelow = math.min(nearestBelow, other.rect.top * sy);
    }

    final availableHeight =
        math.max(baseHeight, nearestBelow - top - 1.2).toDouble();
    final height = math
        .min(
          pageHeight - top,
          math.min(
            desiredHeight,
            isTableLike
                ? math.max(baseHeight, availableHeight)
                : math.max(baseHeight * 1.35, availableHeight),
          ),
        )
        .toDouble();

    // Keep the box fully on-page after the small horizontal expansion.
    if (left + width > pageWidth) {
      width = math.max(6.0, pageWidth - left).toDouble();
    }

    return _LayoutBox(
      left: left,
      top: top,
      width: width,
      height: math.max(baseHeight, height).toDouble(),
    );
  }

  bool _isTableLike(PdfTextRegion region, List<PdfTextRegion> all) {
    final r = region.rect;
    for (final other in all) {
      if (identical(other, region)) continue;
      final o = other.rect;

      final verticalOverlap = math.max(
        0.0,
        math.min(r.bottom, o.bottom) - math.max(r.top, o.top),
      );
      final minHeight = math.max(1.0, math.min(r.height, o.height));
      if (verticalOverlap / minHeight < 0.55) continue;

      final gap = o.left > r.right
          ? o.left - r.right
          : r.left > o.right
              ? r.left - o.right
              : 0.0;

      if (gap <= math.max(r.height, o.height) * 3.0) return true;
    }
    return false;
  }

  _SectionText? _sectionText(String source, String translated) {
    final match = RegExp(r'^\s*(\d+(?:\.\d+)*)\.\s*(.+)    String text,
    double width,
    double height,
    int sourceLineCount,
  ) {
    final lines = math.max(1, sourceLineCount);
    final sourceBased = (height / lines) * 0.90;
    var size = math.min(18.0, math.max(8.0, sourceBased)).toDouble();

    while (size > 7.2) {
      final estimatedLines =
          _estimateWrappedLines(_displayArabic(text), width, size);
      final neededHeight = estimatedLines * size * 1.22;
      if (neededHeight <= height * 0.98) return size;
      size -= 0.30;
    }

    return 7.2;
  }

  int _estimateWrappedLines(String text, double width, double fontSize) {
    if (text.trim().isEmpty) return 1;

    // Cairo Arabic glyphs average a little over half an em in document text.
    final capacity = math.max(3, (width / (fontSize * 0.56)).floor());
    var lines = 1;
    var used = 0;

    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final length = word.runes.length;

      if (used == 0) {
        used = length;
      } else if (used + 1 + length <= capacity) {
        used += 1 + length;
      } else {
        lines++;
        used = length;
      }

      if (used > capacity) {
        final extra = ((used - 1) ~/ capacity);
        lines += extra;
        used = ((used - 1) % capacity) + 1;
      }
    }

    return lines;
  }

  Future<void> _sampleRegionColors(
    Uint8List imageBytes,
    List<PdfTextRegion> regions,
  ) async {
    ui.Codec? codec;
    ui.Image? image;

    try {
      codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      image = frame.image;

      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return;

      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      for (final region in regions) {
        final colors = _sampleColors(
          rgba,
          image.width,
          image.height,
          region.rect,
        );
        region.background = colors.background;
        region.foreground = colors.foreground;
      }
    } catch (_) {
      // Color matching is a visual enhancement only. Translation should still
      // succeed even if a particular Android device cannot decode the raster.
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  _SampledColors _sampleColors(
    Uint8List rgba,
    int imageWidth,
    int imageHeight,
    ui.Rect rect,
  ) {
    final rs = <int>[];
    final gs = <int>[];
    final bs = <int>[];

    void sample(double x, double y) {
      final px = x.round().clamp(0, imageWidth - 1).toInt();
      final py = y.round().clamp(0, imageHeight - 1).toInt();
      final index = (py * imageWidth + px) * 4;
      if (index + 3 >= rgba.length) return;
      final alpha = rgba[index + 3];
      if (alpha < 128) return;
      rs.add(rgba[index]);
      gs.add(rgba[index + 1]);
      bs.add(rgba[index + 2]);
    }

    final offset = math.max(2.0, math.min(rect.width, rect.height) * 0.18);
    final xs = <double>[
      rect.left,
      rect.left + rect.width * 0.25,
      rect.center.dx,
      rect.left + rect.width * 0.75,
      rect.right,
    ];
    final ys = <double>[
      rect.top,
      rect.top + rect.height * 0.25,
      rect.center.dy,
      rect.top + rect.height * 0.75,
      rect.bottom,
    ];

    for (final x in xs) {
      sample(x, rect.top - offset);
      sample(x, rect.bottom + offset);
    }
    for (final y in ys) {
      sample(rect.left - offset, y);
      sample(rect.right + offset, y);
    }

    if (rs.isEmpty) {
      return const _SampledColors(PdfColors.white, PdfColors.black);
    }

    rs.sort();
    gs.sort();
    bs.sort();
    final mid = rs.length ~/ 2;
    final r = rs[mid];
    final g = gs[mid];
    final b = bs[mid];

    final background = PdfColor(r / 255, g / 255, b / 255);
    final luminance =
        (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
    final foreground =
        luminance < 0.48 ? PdfColors.white : PdfColors.black;

    return _SampledColors(background, foreground);
  }

  List<List<PdfTextRegion>> _chunk(List<PdfTextRegion> items) {
    final result = <List<PdfTextRegion>>[];
    var current = <PdfTextRegion>[];
    var chars = 0;

    for (final item in items) {
      final next = item.source.length;
      if (current.isNotEmpty &&
          (current.length >= 24 || chars + next > 5000)) {
        result.add(current);
        current = <PdfTextRegion>[];
        chars = 0;
      }
      current.add(item);
      chars += next;
    }

    if (current.isNotEmpty) result.add(current);
    return result;
  }
}
).firstMatch(source);
    if (match == null) return null;

    final number = '${match.group(1)}.';
    var title = translated.trim();

    // Remove whichever side the model placed the section number on.
    title = title.replaceFirst(
      RegExp(r'^\s*\.?\s*\d+(?:\.\d+)*\.?\s*'),
      '',
    );
    title = title.replaceFirst(
      RegExp(r'\s*\.?\s*\d+(?:\.\d+)*\.?\s*    String text,
    double width,
    double height,
    int sourceLineCount,
  ) {
    final lines = math.max(1, sourceLineCount);
    final sourceBased = (height / lines) * 0.82;
    var size = math.min(22.0, math.max(7.0, sourceBased)).toDouble();

    while (size > 5.5) {
      final estimatedLines = _estimateWrappedLines(text, width, size);
      final neededHeight = estimatedLines * size * 1.18;
      if (neededHeight <= height * 0.98) return size;
      size -= 0.35;
    }

    return 5.5;
  }

  int _estimateWrappedLines(String text, double width, double fontSize) {
    if (text.trim().isEmpty) return 1;

    // Cairo Arabic glyphs average a little over half an em in document text.
    final capacity = math.max(3, (width / (fontSize * 0.56)).floor());
    var lines = 1;
    var used = 0;

    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final length = word.runes.length;

      if (used == 0) {
        used = length;
      } else if (used + 1 + length <= capacity) {
        used += 1 + length;
      } else {
        lines++;
        used = length;
      }

      if (used > capacity) {
        final extra = ((used - 1) ~/ capacity);
        lines += extra;
        used = ((used - 1) % capacity) + 1;
      }
    }

    return lines;
  }

  Future<void> _sampleRegionColors(
    Uint8List imageBytes,
    List<PdfTextRegion> regions,
  ) async {
    ui.Codec? codec;
    ui.Image? image;

    try {
      codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      image = frame.image;

      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return;

      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      for (final region in regions) {
        final colors = _sampleColors(
          rgba,
          image.width,
          image.height,
          region.rect,
        );
        region.background = colors.background;
        region.foreground = colors.foreground;
      }
    } catch (_) {
      // Color matching is a visual enhancement only. Translation should still
      // succeed even if a particular Android device cannot decode the raster.
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  _SampledColors _sampleColors(
    Uint8List rgba,
    int imageWidth,
    int imageHeight,
    ui.Rect rect,
  ) {
    final rs = <int>[];
    final gs = <int>[];
    final bs = <int>[];

    void sample(double x, double y) {
      final px = x.round().clamp(0, imageWidth - 1).toInt();
      final py = y.round().clamp(0, imageHeight - 1).toInt();
      final index = (py * imageWidth + px) * 4;
      if (index + 3 >= rgba.length) return;
      final alpha = rgba[index + 3];
      if (alpha < 128) return;
      rs.add(rgba[index]);
      gs.add(rgba[index + 1]);
      bs.add(rgba[index + 2]);
    }

    final offset = math.max(2.0, math.min(rect.width, rect.height) * 0.18);
    final xs = <double>[
      rect.left,
      rect.left + rect.width * 0.25,
      rect.center.dx,
      rect.left + rect.width * 0.75,
      rect.right,
    ];
    final ys = <double>[
      rect.top,
      rect.top + rect.height * 0.25,
      rect.center.dy,
      rect.top + rect.height * 0.75,
      rect.bottom,
    ];

    for (final x in xs) {
      sample(x, rect.top - offset);
      sample(x, rect.bottom + offset);
    }
    for (final y in ys) {
      sample(rect.left - offset, y);
      sample(rect.right + offset, y);
    }

    if (rs.isEmpty) {
      return const _SampledColors(PdfColors.white, PdfColors.black);
    }

    rs.sort();
    gs.sort();
    bs.sort();
    final mid = rs.length ~/ 2;
    final r = rs[mid];
    final g = gs[mid];
    final b = bs[mid];

    final background = PdfColor(r / 255, g / 255, b / 255);
    final luminance =
        (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
    final foreground =
        luminance < 0.48 ? PdfColors.white : PdfColors.black;

    return _SampledColors(background, foreground);
  }

  List<List<PdfTextRegion>> _chunk(List<PdfTextRegion> items) {
    final result = <List<PdfTextRegion>>[];
    var current = <PdfTextRegion>[];
    var chars = 0;

    for (final item in items) {
      final next = item.source.length;
      if (current.isNotEmpty &&
          (current.length >= 24 || chars + next > 5000)) {
        result.add(current);
        current = <PdfTextRegion>[];
        chars = 0;
      }
      current.add(item);
      chars += next;
    }

    if (current.isNotEmpty) result.add(current);
    return result;
  }
}
),
      '',
    );
    if (title.isEmpty) title = match.group(2) ?? translated;

    return _SectionText(number, title);
  }

  String _displayArabic(String value) {
    var result = value.trim();

    // Keep regular spaces for wrapping, but add a tiny visual spacer so Arabic
    // words do not appear glued together at small PDF font sizes.
    result = result.replaceAll(' ', ' \u2009');

    // Stabilize embedded western numbers/acronyms inside RTL text.
    result = result.replaceAllMapped(
      RegExp(r'(?<![A-Za-z0-9])(?:\d+[\d.,:/-]*|[A-Z]{2,})(?![A-Za-z0-9])'),
      (m) => '\u200E${m.group(0)}\u200E',
    );

    return result;
  }

  double _fitFontSize(
    String text,
    double width,
    double height,
    int sourceLineCount,
  ) {
    final lines = math.max(1, sourceLineCount);
    final sourceBased = (height / lines) * 0.82;
    var size = math.min(22.0, math.max(7.0, sourceBased)).toDouble();

    while (size > 5.5) {
      final estimatedLines = _estimateWrappedLines(text, width, size);
      final neededHeight = estimatedLines * size * 1.18;
      if (neededHeight <= height * 0.98) return size;
      size -= 0.35;
    }

    return 5.5;
  }

  int _estimateWrappedLines(String text, double width, double fontSize) {
    if (text.trim().isEmpty) return 1;

    // Cairo Arabic glyphs average a little over half an em in document text.
    final capacity = math.max(3, (width / (fontSize * 0.56)).floor());
    var lines = 1;
    var used = 0;

    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final length = word.runes.length;

      if (used == 0) {
        used = length;
      } else if (used + 1 + length <= capacity) {
        used += 1 + length;
      } else {
        lines++;
        used = length;
      }

      if (used > capacity) {
        final extra = ((used - 1) ~/ capacity);
        lines += extra;
        used = ((used - 1) % capacity) + 1;
      }
    }

    return lines;
  }

  Future<void> _sampleRegionColors(
    Uint8List imageBytes,
    List<PdfTextRegion> regions,
  ) async {
    ui.Codec? codec;
    ui.Image? image;

    try {
      codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      image = frame.image;

      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return;

      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      for (final region in regions) {
        final colors = _sampleColors(
          rgba,
          image.width,
          image.height,
          region.rect,
        );
        region.background = colors.background;
        region.foreground = colors.foreground;
      }
    } catch (_) {
      // Color matching is a visual enhancement only. Translation should still
      // succeed even if a particular Android device cannot decode the raster.
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  _SampledColors _sampleColors(
    Uint8List rgba,
    int imageWidth,
    int imageHeight,
    ui.Rect rect,
  ) {
    final rs = <int>[];
    final gs = <int>[];
    final bs = <int>[];

    void sample(double x, double y) {
      final px = x.round().clamp(0, imageWidth - 1).toInt();
      final py = y.round().clamp(0, imageHeight - 1).toInt();
      final index = (py * imageWidth + px) * 4;
      if (index + 3 >= rgba.length) return;
      final alpha = rgba[index + 3];
      if (alpha < 128) return;
      rs.add(rgba[index]);
      gs.add(rgba[index + 1]);
      bs.add(rgba[index + 2]);
    }

    final offset = math.max(2.0, math.min(rect.width, rect.height) * 0.18);
    final xs = <double>[
      rect.left,
      rect.left + rect.width * 0.25,
      rect.center.dx,
      rect.left + rect.width * 0.75,
      rect.right,
    ];
    final ys = <double>[
      rect.top,
      rect.top + rect.height * 0.25,
      rect.center.dy,
      rect.top + rect.height * 0.75,
      rect.bottom,
    ];

    for (final x in xs) {
      sample(x, rect.top - offset);
      sample(x, rect.bottom + offset);
    }
    for (final y in ys) {
      sample(rect.left - offset, y);
      sample(rect.right + offset, y);
    }

    if (rs.isEmpty) {
      return const _SampledColors(PdfColors.white, PdfColors.black);
    }

    rs.sort();
    gs.sort();
    bs.sort();
    final mid = rs.length ~/ 2;
    final r = rs[mid];
    final g = gs[mid];
    final b = bs[mid];

    final background = PdfColor(r / 255, g / 255, b / 255);
    final luminance =
        (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
    final foreground =
        luminance < 0.48 ? PdfColors.white : PdfColors.black;

    return _SampledColors(background, foreground);
  }

  List<List<PdfTextRegion>> _chunk(List<PdfTextRegion> items) {
    final result = <List<PdfTextRegion>>[];
    var current = <PdfTextRegion>[];
    var chars = 0;

    for (final item in items) {
      final next = item.source.length;
      if (current.isNotEmpty &&
          (current.length >= 24 || chars + next > 5000)) {
        result.add(current);
        current = <PdfTextRegion>[];
        chars = 0;
      }
      current.add(item);
      chars += next;
    }

    if (current.isNotEmpty) result.add(current);
    return result;
  }
}
