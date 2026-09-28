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
                  final r = region.rect;

                  // A little extra horizontal room is important for Arabic,
                  // which frequently needs more width than the English source.
                  final horizontalPad = math.max(1.2, r.width * sx * 0.025);
                  final verticalPad = math.max(0.7, r.height * sy * 0.035);

                  final left =
                      math.max(0.0, r.left * sx - horizontalPad).toDouble();
                  final top =
                      math.max(0.0, r.top * sy - verticalPad).toDouble();
                  final width = math
                      .min(
                        pageWidth - left,
                        math.max(
                          6.0,
                          r.width * sx + horizontalPad * 2,
                        ),
                      )
                      .toDouble();
                  final height = math
                      .min(
                        pageHeight - top,
                        math.max(
                          5.0,
                          r.height * sy + verticalPad * 2,
                        ),
                      )
                      .toDouble();

                  final translated = region.translated.trim().isEmpty
                      ? region.source
                      : region.translated.trim();

                  final innerWidth = math.max(2.0, width - 2.4).toDouble();
                  final innerHeight = math.max(2.0, height - 1.4).toDouble();
                  final fontSize = _fitFontSize(
                    translated,
                    innerWidth,
                    innerHeight,
                    region.sourceLineCount,
                  );

                  children.add(
                    pw.Positioned(
                      left: left,
                      top: top,
                      child: pw.Container(
                        width: width,
                        height: height,
                        color: region.background,
                        padding: const pw.EdgeInsets.symmetric(
                          horizontal: 1.2,
                          vertical: 0.7,
                        ),
                        alignment: pw.Alignment.centerRight,
                        child: pw.FittedBox(
                          fit: pw.BoxFit.scaleDown,
                          alignment: pw.Alignment.centerRight,
                          child: pw.Container(
                            width: innerWidth,
                            child: pw.Text(
                              translated,
                              textDirection: pw.TextDirection.rtl,
                              textAlign: pw.TextAlign.right,
                              softWrap: true,
                              style: pw.TextStyle(
                                font: arabicFont,
                                fontSize: fontSize,
                                color: region.foreground,
                              ),
                            ),
                          ),
                        ),
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
    return value
        .replaceAll('\u200b', '')
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
        .trim();
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
