import 'dart:io';

import 'package:flutter/material.dart';

import '../models/server_settings.dart';
import '../services/api_client.dart';
import 'pairing_scanner_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    required this.onSaved,
    this.initialSettings,
    this.onCancel,
    super.key,
  });

  final Future<void> Function(ServerSettings settings) onSaved;
  final ServerSettings? initialSettings;
  final VoidCallback? onCancel;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  bool _submitting = false;
  bool _showToken = false;
  String? _error;

  bool get _canScan => Platform.isAndroid || Platform.isIOS;
  bool get _isEditing => widget.initialSettings != null;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: widget.initialSettings?.baseUrl ?? 'http://192.168.1.2:9527',
    );
    _tokenController = TextEditingController(
      text: widget.initialSettings?.token ?? '',
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isEditing
          ? AppBar(
              title: const Text('修改服务器连接'),
              leading: IconButton(
                tooltip: '取消修改',
                onPressed: _submitting ? null : widget.onCancel,
                icon: const Icon(Icons.close),
              ),
            )
          : null,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        _isEditing
                            ? Icons.settings_ethernet_rounded
                            : Icons.photo_library_outlined,
                        size: 56,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _isEditing ? '更新服务器地址' : '连接 LocalLens',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isEditing
                            ? '服务器 IP 发生变化时，在此填写新地址。现有 Token 已保留。'
                            : _canScan
                                ? '推荐扫描 Windows 管理端生成的一次性二维码。'
                                : '输入 Windows 媒体服务的局域网地址和管理员令牌。',
                        textAlign: TextAlign.center,
                      ),
                      if (_canScan && !_isEditing) ...[
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _submitting ? null : _scanPairing,
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          label: const Text('扫描二维码配对'),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Row(
                            children: [
                              Expanded(child: Divider()),
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12),
                                child: Text('或手动连接'),
                              ),
                              Expanded(child: Divider()),
                            ],
                          ),
                        ),
                      ] else
                        const SizedBox(height: 28),
                      TextFormField(
                        controller: _urlController,
                        keyboardType: TextInputType.url,
                        autofocus: _isEditing,
                        decoration: const InputDecoration(
                          labelText: '服务地址',
                          hintText: 'http://192.168.1.2:9527',
                          helperText: '跨电脑连接请填写服务端当前局域网 IPv4 地址',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                        validator: (value) {
                          final uri = Uri.tryParse(value?.trim() ?? '');
                          if (uri == null ||
                              !uri.hasScheme ||
                              uri.host.isEmpty ||
                              (uri.scheme != 'http' && uri.scheme != 'https')) {
                            return '请输入有效的 HTTP 或 HTTPS 地址';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _tokenController,
                        obscureText: !_showToken,
                        decoration: InputDecoration(
                          labelText: '管理员或设备 Token',
                          prefixIcon: const Icon(Icons.key_outlined),
                          suffixIcon: IconButton(
                            tooltip: _showToken ? '隐藏 Token' : '显示 Token',
                            onPressed: () => setState(() => _showToken = !_showToken),
                            icon: Icon(
                              _showToken
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                        validator: (value) => (value?.trim().length ?? 0) < 16
                            ? 'Token 至少需要 16 个字符'
                            : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Card(
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
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
                        label: Text(
                          _isEditing ? '测试并保存新地址' : '测试并保存手动连接',
                        ),
                      ),
                      if (_isEditing) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _submitting ? null : widget.onCancel,
                          child: const Text('取消修改，返回客户端'),
                        ),
                      ],
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

  Future<void> _scanPairing() async {
    final settings = await Navigator.of(context).push<ServerSettings>(
      MaterialPageRoute(builder: (_) => const PairingScannerScreen()),
    );
    if (settings == null || !mounted) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final client = ApiClient(settings);
      try {
        await client.verify();
      } finally {
        client.close();
      }
      await widget.onSaved(settings);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
