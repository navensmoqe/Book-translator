import 'package:flutter/material.dart';

import '../models/api_config.dart';
import '../services/api_store.dart';
import '../services/translator_router.dart';

class ApiManagerScreen extends StatefulWidget {
  const ApiManagerScreen({super.key});

  @override
  State<ApiManagerScreen> createState() => _ApiManagerScreenState();
}

class _ApiManagerScreenState extends State<ApiManagerScreen> {
  List<ApiConfig> _items = [];
  bool _loading = true;
  final _router = TranslatorRouter();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await ApiStore.load();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _persist() => ApiStore.save(_items);

  String _masked(String key) {
    if (key.length <= 8) return '••••••••';
    return '${key.substring(0, 4)}••••••••${key.substring(key.length - 4)}';
  }

  Future<void> _edit([ApiConfig? existing]) async {
    final result = await showDialog<ApiConfig>(
      context: context,
      builder: (_) => _ApiDialog(existing: existing),
    );
    if (result == null) return;

    setState(() {
      final index = _items.indexWhere((e) => e.id == result.id);
      if (index >= 0) {
        _items[index] = result;
      } else {
        _items.add(result);
      }
    });
    await _persist();
  }

  Future<void> _test(ApiConfig config) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('جاري اختبار ${config.name}…')),
    );
    try {
      await _router.test(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ ${config.name} يعمل بنجاح')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إدارة مفاتيح API')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('إضافة API'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'لم تضف أي API بعد.\nأضف Groq أو OpenRouter، ويمكنك إضافة أي عدد تريده.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final item = _items[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.name,
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                  ),
                                  Switch(
                                    value: item.enabled,
                                    onChanged: (value) async {
                                      setState(() => _items[index] = item.copyWith(enabled: value));
                                      await _persist();
                                    },
                                  ),
                                ],
                              ),
                              Text('${item.provider} • ${item.model}'),
                              const SizedBox(height: 4),
                              Text(_masked(item.apiKey)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton.icon(
                                    onPressed: () => _test(item),
                                    icon: const Icon(Icons.wifi_tethering),
                                    label: const Text('اختبار'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _edit(item),
                                    icon: const Icon(Icons.edit),
                                    label: const Text('تعديل'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () async {
                                      setState(() => _items.removeAt(index));
                                      await _persist();
                                    },
                                    icon: const Icon(Icons.delete_outline),
                                    label: const Text('حذف'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class _ApiDialog extends StatefulWidget {
  const _ApiDialog({this.existing});
  final ApiConfig? existing;

  @override
  State<_ApiDialog> createState() => _ApiDialogState();
}

class _ApiDialogState extends State<_ApiDialog> {
  late String provider;
  late final TextEditingController name;
  late final TextEditingController apiKey;
  late final TextEditingController model;
  late final TextEditingController baseUrl;
  late bool enabled;

  @override
  void initState() {
    super.initState();
    final item = widget.existing;
    provider = item?.provider ?? 'groq';
    name = TextEditingController(text: item?.name ?? 'Groq');
    apiKey = TextEditingController(text: item?.apiKey ?? '');
    model = TextEditingController(text: item?.model ?? ApiConfig.defaultModel(provider));
    baseUrl = TextEditingController(text: item?.baseUrl ?? ApiConfig.defaultBaseUrl(provider));
    enabled = item?.enabled ?? true;
  }

  @override
  void dispose() {
    name.dispose();
    apiKey.dispose();
    model.dispose();
    baseUrl.dispose();
    super.dispose();
  }

  void _providerChanged(String value) {
    setState(() {
      provider = value;
      if (widget.existing == null) {
        name.text = value == 'groq'
            ? 'Groq'
            : value == 'openrouter'
                ? 'OpenRouter'
                : 'Custom API';
        model.text = ApiConfig.defaultModel(value);
        baseUrl.text = ApiConfig.defaultBaseUrl(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(widget.existing == null ? 'إضافة API' : 'تعديل API'),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: provider,
                  decoration: const InputDecoration(labelText: 'Provider'),
                  items: const [
                    DropdownMenuItem(value: 'groq', child: Text('Groq')),
                    DropdownMenuItem(value: 'openrouter', child: Text('OpenRouter')),
                    DropdownMenuItem(value: 'custom', child: Text('OpenAI-compatible / Custom')),
                  ],
                  onChanged: (v) {
                    if (v != null) _providerChanged(v);
                  },
                ),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم')),
                TextField(
                  controller: apiKey,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API Key'),
                ),
                TextField(controller: model, decoration: const InputDecoration(labelText: 'Model')),
                TextField(controller: baseUrl, decoration: const InputDecoration(labelText: 'Base URL')),
                SwitchListTile(
                  value: enabled,
                  title: const Text('مفعّل'),
                  onChanged: (v) => setState(() => enabled = v),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              if (apiKey.text.trim().isEmpty || model.text.trim().isEmpty || baseUrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('أكمل API Key وModel وBase URL.')),
                );
                return;
              }
              Navigator.pop(
                context,
                ApiConfig(
                  id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
                  name: name.text.trim().isEmpty ? provider : name.text.trim(),
                  provider: provider,
                  apiKey: apiKey.text.trim(),
                  model: model.text.trim(),
                  baseUrl: baseUrl.text.trim(),
                  enabled: enabled,
                ),
              );
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }
}
