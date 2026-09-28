class ApiConfig {
  const ApiConfig({
    required this.id,
    required this.name,
    required this.provider,
    required this.apiKey,
    required this.model,
    required this.baseUrl,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String provider;
  final String apiKey;
  final String model;
  final String baseUrl;
  final bool enabled;

  ApiConfig copyWith({
    String? id,
    String? name,
    String? provider,
    String? apiKey,
    String? model,
    String? baseUrl,
    bool? enabled,
  }) {
    return ApiConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      baseUrl: baseUrl ?? this.baseUrl,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'provider': provider,
        'apiKey': apiKey,
        'model': model,
        'baseUrl': baseUrl,
        'enabled': enabled,
      };

  factory ApiConfig.fromJson(Map<String, dynamic> json) {
    return ApiConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      provider: json['provider'] as String,
      apiKey: json['apiKey'] as String,
      model: json['model'] as String,
      baseUrl: json['baseUrl'] as String,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  static String defaultBaseUrl(String provider) {
    switch (provider) {
      case 'groq':
        return 'https://api.groq.com/openai/v1';
      case 'openrouter':
        return 'https://openrouter.ai/api/v1';
      default:
        return '';
    }
  }

  static String defaultModel(String provider) {
    switch (provider) {
      case 'groq':
        return 'openai/gpt-oss-120b';
      case 'openrouter':
        return 'openrouter/free';
      default:
        return '';
    }
  }
}
