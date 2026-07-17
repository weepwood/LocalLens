import 'package:flutter/material.dart';

import '../models/server_settings.dart';
import '../services/api_client.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({required this.onSaved, super.key});

  final Future<void> Function(ServerSettings settings) onSaved;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController(text: 'http://192.168.1.2:9527');
  final _tokenController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.photo_library_outlined, size: 56),
                      const SizedBox(height: 16),
                      Text(
                        '连接 LocalLens',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '输入 Windows 媒体服务的局域网地址和访问令牌。',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _urlController,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: '服务地址',
                          hintText: 'http://192.168.1.2:9527',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                        validator: (value) {
                          final uri = Uri.tryParse(value?.trim() ?? '');
                          if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
                            return '请输入有效的 HTTP 或 HTTPS 地址';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _tokenController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'API Token',
                          prefixIcon: Icon(Icons.key_outlined),
                        ),
                        validator: (value) => (value?.trim().length ?? 0) < 16
                            ? 'Token 至少需要 16 个字符'
                            : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.link),
                        label: const Text('测试并保存'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    final settings = ServerSettings(
      baseUrl: _urlController.text.trim(),
      token: _tokenController.text.trim(),
    );
    final client = ApiClient(settings);
    try {
      await client.verify();
      await widget.onSaved(settings);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      client.close();
      if (mounted) setState(() => _submitting = false);
    }
  }
}
