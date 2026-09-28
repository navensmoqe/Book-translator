import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'screens/api_manager_screen.dart';
import 'services/api_store.dart';
import 'services/pdf_translation_service.dart';
import 'services/translator_router.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PdfTranslatorApp());
}

class PdfTranslatorApp extends StatelessWidget {
  const PdfTranslatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PDF Arabic Translator',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _path;
  String? _fileName;
  bool _busy = false;
  double _progress = 0;
  String _status = 'جاهز';
  int _apiCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshApiCount();
  }

  Future<void> _refreshApiCount() async {
    final items = await ApiStore.load();
    if (!mounted) return;
    setState(() => _apiCount = items.where((e) => e.enabled).length);
  }

  Future<void> _pickPdf() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (file == null) return;
    if (file.path == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر الوصول إلى مسار الملف.')),
      );
      return;
    }
    setState(() {
      _path = file.path;
      _fileName = file.name;
      _status = 'تم اختيار الملف';
    });
  }

  Future<void> _translate() async {
    if (_path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر ملف PDF أولًا.')),
      );
      return;
    }
    final configs = await ApiStore.load();
    if (configs.where((e) => e.enabled).isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف API مفعّلًا أولًا.')),
      );
      return;
    }

    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'بدء الترجمة…';
    });

    try {
      final service = PdfTranslationService(TranslatorRouter());
      final saved = await service.translate(
        inputPath: _path!,
        onProgress: (progress, status) {
          if (!mounted) return;
          setState(() {
            _progress = progress.clamp(0.0, 1.0).toDouble();
            _status = status;
          });
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved == null
                ? '✅ تمت الترجمة.'
                : '✅ تم حفظ الملف في Downloads/PDF-Arabic-Translator',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'حدث خطأ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مترجم PDF إلى العربية'),
          actions: [
            IconButton(
              tooltip: 'إدارة APIs',
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ApiManagerScreen()),
                      );
                      await _refreshApiCount();
                    },
              icon: const Icon(Icons.key),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.picture_as_pdf, size: 58),
                      const SizedBox(height: 12),
                      Text(
                        _fileName ?? 'لم يتم اختيار PDF',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pickPdf,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('اختيار PDF'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.hub_outlined),
                  title: const Text('التبديل التلقائي بين APIs'),
                  subtitle: Text('$_apiCount API مفعّل • Groq / OpenRouter / Custom'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: _busy
                      ? null
                      : () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ApiManagerScreen()),
                          );
                          await _refreshApiCount();
                        },
                ),
              ),
              const SizedBox(height: 12),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    'طريقة العمل: يتم تحويل كل صفحة إلى صورة للحفاظ على الصور والترتيب، ثم OCR محلي يحدد النص، وبعدها تتم الترجمة وإعادة وضع العربية فوق النص الأصلي. الأفضل حاليًا لملفات الإنجليزية واللغات ذات الحروف اللاتينية.',
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (_busy) ...[
                LinearProgressIndicator(value: _progress == 0 ? null : _progress),
                const SizedBox(height: 10),
                Text(_status, textAlign: TextAlign.center),
                const SizedBox(height: 18),
              ],
              FilledButton.icon(
                onPressed: _busy ? null : _translate,
                icon: const Icon(Icons.translate),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  child: Text(_busy ? 'جاري العمل…' : 'ترجمة إلى العربية'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'لا توجد قاعدة بيانات ولا تسجيل دخول. مفاتيح API تُحفظ مشفرة محليًا على هاتفك.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
