import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:file_saver/file_saver.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as px;
import 'package:printing/printing.dart';

import 'translator_router.dart';

class PdfLineRegion {
  PdfLineRegion({required this.id, required this.rect, required this.source});
  final int id;
  final Rect rect;
  final String source;
  String translated = '';
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
            quality: 84,
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

          final regions = <PdfLineRegion>[];
          var id = 0;
          for (final block in recognized.blocks) {
            for (final line in block.lines) {
              final text = line.text.trim();
              if (text.isEmpty) continue;
              regions.add(PdfLineRegion(id: id++, rect: line.boundingBox, source: text));
            }
          }

          if (regions.isNotEmpty) {
            final chunks = _chunk(regions);
            for (var c = 0; c < chunks.length; c++) {
              onProgress(
                ((pageIndex - 1) + ((c + 0.35) / chunks.length)) / total,
                'ترجمة الصفحة $pageIndex من $total — جزء ${c + 1}/${chunks.length}…',
              );
              final part = chunks[c];
              final translated = await router.translateItems(
                part.map((e) => TranslationItem(id: e.id, text: e.source)).toList(),
              );
              for (final item in part) {
                item.translated = translated[item.id] ?? item.source;
              }
            }
          }

          final renderedWidth = rendered.width.toDouble();
          final renderedHeight = rendered.height.toDouble();
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
                  final left = math.max(0.0, r.left * sx - 0.7).toDouble();
                  final top = math.max(0.0, r.top * sy - 0.5).toDouble();
                  final width = math.min(
                    pageWidth - left,
                    math.max(4.0, r.width * sx + 1.4),
                  ).toDouble();
                  final height = math.min(
                    pageHeight - top,
                    math.max(4.0, r.height * sy + 1.2),
                  ).toDouble();
                  final translated = region.translated.trim().isEmpty
                      ? region.source
                      : region.translated.trim();

                  children.add(
                    pw.Positioned(
                      left: left,
                      top: top,
                      width: width,
                      height: height,
                      child: pw.Container(
                        color: PdfColors.white,
                        padding: const pw.EdgeInsets.symmetric(horizontal: 0.8, vertical: 0.2),
                        alignment: pw.Alignment.centerRight,
                        child: pw.FittedBox(
                          fit: pw.BoxFit.scaleDown,
                          alignment: pw.Alignment.centerRight,
                          child: pw.Text(
                            translated,
                            textDirection: pw.TextDirection.rtl,
                            textAlign: pw.TextAlign.right,
                            style: pw.TextStyle(
                              font: arabicFont,
                              fontSize: math.max(7.0, height * 0.86).toDouble(),
                              color: PdfColors.black,
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
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
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
      recognizer.close();
      await source.close();
    }
  }

  List<List<PdfLineRegion>> _chunk(List<PdfLineRegion> items) {
    final result = <List<PdfLineRegion>>[];
    var current = <PdfLineRegion>[];
    var chars = 0;
    for (final item in items) {
      final next = item.source.length;
      if (current.isNotEmpty && (current.length >= 32 || chars + next > 5500)) {
        result.add(current);
        current = <PdfLineRegion>[];
        chars = 0;
      }
      current.add(item);
      chars += next;
    }
    if (current.isNotEmpty) result.add(current);
    return result;
  }
}
