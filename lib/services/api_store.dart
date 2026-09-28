import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/api_config.dart';

class ApiStore {
  ApiStore._();

  static const _storage = FlutterSecureStorage();
  static const _key = 'pdf_translator_api_configs_v1';

  static Future<List<ApiConfig>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final data = jsonDecode(raw) as List<dynamic>;
      return data
          .map((e) => ApiConfig.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<ApiConfig> configs) async {
    await _storage.write(
      key: _key,
      value: jsonEncode(configs.map((e) => e.toJson()).toList()),
    );
  }
}
