import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/api_config.dart';
import 'api_store.dart';

class TranslationItem {
  const TranslationItem({required this.id, required this.text});
  final int id;
  final String text;
}

class TranslationApiException implements Exception {
  TranslationApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class TranslatorRouter {
  final Map<String, DateTime> _cooldownUntil = {};
  int _cursor = 0;

  Future<Map<int, String>> translateItems(List<TranslationItem> items) async {
    if (items.isEmpty) return {};

    final all = await ApiStore.load();
    final configs = all.where((e) => e.enabled && e.apiKey.trim().isNotEmpty).toList();
    if (configs.isEmpty) {
      throw TranslationApiException('لا يوجد API مفعّل. أضف Groq أو OpenRouter أولًا.');
    }

    Object? lastError;
    final now = DateTime.now();

    for (var offset = 0; offset < configs.length; offset++) {
      final index = (_cursor + offset) % configs.length;
      final config = configs[index];
      final cooldown = _cooldownUntil[config.id];
      if (cooldown != null && cooldown.isAfter(now)) continue;

      try {
        final translated = await _call(config, items);
        _cursor = (index + 1) % configs.length;
        return translated;
      } on TranslationApiException catch (e) {
        lastError = e;
        if (e.statusCode == 429) {
          _cooldownUntil[config.id] = DateTime.now().add(const Duration(seconds: 75));
        } else if (e.statusCode != null && e.statusCode! >= 500) {
          _cooldownUntil[config.id] = DateTime.now().add(const Duration(seconds: 20));
        }
      } catch (e) {
        lastError = e;
      }
    }

    throw TranslationApiException(
      'فشلت جميع مفاتيح API المتاحة. آخر خطأ: ${lastError ?? 'غير معروف'}',
    );
  }

  Future<void> test(ApiConfig config) async {
    final result = await _call(
      config,
      const [TranslationItem(id: 0, text: 'Hello world')],
    );
    if ((result[0] ?? '').trim().isEmpty) {
      throw TranslationApiException('الاتصال نجح لكن لم تصل ترجمة صالحة.');
    }
  }

  Future<Map<int, String>> _call(
    ApiConfig config,
    List<TranslationItem> items,
  ) async {
    var base = config.baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (base.isEmpty) throw TranslationApiException('Base URL فارغ.');

    final input = items.map((e) => {'id': e.id, 'text': e.text}).toList();

    final prompt = '''
Translate every item in the JSON array below into natural Modern Standard Arabic.
Rules:
- Do not summarize or omit anything.
- Preserve names, numbers, citations, section numbers, punctuation, and meaning.
- Use natural Modern Standard Arabic word spacing. NEVER concatenate separate Arabic words.
- Keep each item as one coherent text block and do not insert artificial line breaks.
- If an item begins with a section number such as "1. Introduction", keep that section number and translate the heading naturally.
- Use the surrounding items as context, but translate each item independently.
- Return ONLY valid JSON in exactly this shape:
{"translations":[{"id":0,"text":"Arabic translation"}]}
- Every input id must appear exactly once.

INPUT:
${jsonEncode(input)}
''';

    final response = await http
        .post(
          Uri.parse('$base/chat/completions'),
          headers: {
            'Authorization': 'Bearer ${config.apiKey.trim()}',
            'Content-Type': 'application/json; charset=utf-8',
            if (config.provider == 'openrouter') 'X-Title': 'Personal PDF Arabic Translator',
          },
          body: jsonEncode({
            'model': config.model.trim(),
            'temperature': 0.15,
            'messages': [
              {
                'role': 'system',
                'content': 'You are a precise document translator. Output valid JSON only.',
              },
              {'role': 'user', 'content': prompt},
            ],
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String detail = response.body;
      if (detail.length > 350) detail = detail.substring(0, 350);
      throw TranslationApiException(
        '${config.name}: HTTP ${response.statusCode} — $detail',
        statusCode: response.statusCode,
      );
    }

    final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final choices = payload['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw TranslationApiException('${config.name}: استجابة API لا تحتوي choices.');
    }

    final message = Map<String, dynamic>.from(choices.first['message'] as Map);
    var content = (message['content'] ?? '').toString().trim();
    content = _stripCodeFence(content);

    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      final first = content.indexOf('{');
      final last = content.lastIndexOf('}');
      if (first >= 0 && last > first) {
        decoded = jsonDecode(content.substring(first, last + 1));
      } else {
        rethrow;
      }
    }

    final map = Map<String, dynamic>.from(decoded as Map);
    final list = map['translations'] as List<dynamic>?;
    if (list == null) {
      throw TranslationApiException('${config.name}: JSON لا يحتوي translations.');
    }

    final sourceById = <int, String>{for (final e in items) e.id: e.text};
    final result = <int, String>{};
    for (final row in list) {
      final item = Map<String, dynamic>.from(row as Map);
      final id = item['id'];
      if (id is num) {
        final numericId = id.toInt();
        var text = (item['text'] ?? '').toString();
        final sourceText = sourceById[numericId];
        if (sourceText != null) {
          text = _restoreAcronyms(sourceText, text);
        }
        result[numericId] = text;
      }
    }

    for (final item in items) {
      result.putIfAbsent(item.id, () => item.text);
    }
    return result;
  }

  String _restoreAcronyms(String source, String translated) {
    final acronyms = RegExp(r'\b[A-Z][A-Z0-9.+/-]{1,}\b')
        .allMatches(source)
        .map((m) => m.group(0)!)
        .toSet();

    var result = translated;
    for (final acronym in acronyms) {
      if (result.contains(acronym)) continue;

      // Translation models occasionally mutate PDF -> PDE/PDF-like tokens.
      // Replace the first all-uppercase token of the same length when present.
      final candidate = RegExp(
        r'\b[A-Z][A-Z0-9.+/-]{' + (acronym.length - 1).toString() + r'}\b',
      ).firstMatch(result);

      if (candidate != null) {
        result = result.replaceRange(candidate.start, candidate.end, acronym);
      } else {
        // If no comparable token survived, append the source acronym so it is
        // never silently lost from technical/document text.
        result = '$result $acronym';
      }
    }
    return result;
  }

  String _stripCodeFence(String value) {
    var result = value.trim();
    if (result.startsWith('```')) {
      result = result.replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
      result = result.replaceFirst(RegExp(r'\s*```$'), '');
    }
    return result.trim();
  }
}
