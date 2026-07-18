import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/server_settings.dart';
import '../services/api_client.dart';
import '../widgets/app_components.dart';
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
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 18,
              left: 18,
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF6976E8), Color(0xFF4956C8)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(LucideIcons.aperture, color: Colors.white, size: 21),
                  ),
                  const SizedBox(width: 10),
                  Text('LocalLens', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
            if (_isEditing)
              Positioned(
                top: 16,
                right: 16,
                child: IconButton(
                  tooltip: '取消修改',
                  onPressed: _submitting ? null : widget.onCancel,
                  icon: const Icon(LucideIcons.x),
                ),
              ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 86, 20, 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: AppSurface(
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 30),
                    radius: 18,
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                _isEditing ? LucideIcons.settings : LucideIcons.link,
                                size: 25,
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _isEditing ? '更新服务器连接' : '连接到 LocalLens',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isEditing
                                ? '服务器 IP 变化时只需更新地址，现有 Token 会继续保留。'
                                : _canScan
                                    ? '扫描 Windows 管理端生成的一次性二维码，或手动填写局域网地址。'
                                    : '填写 Windows 媒体服务的局域网地址和管理员令牌。',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          if (_canScan && !_isEditing) ...[
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: _submitting ? null : _scanPairing,
                              icon: const Icon(LucideIcons.scanLine, size: 18),
                              label: const Text('扫描二维码配对'),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
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
                            const SizedBox(height: 26),
                          TextFormField(
                            controller: _urlController,
                            keyboardType: TextInputType.url,
                            autofocus: _isEditing,
                            decoration: const InputDecoration(
                              labelText: '服务地址',
                              hintText: 'http://192.168.1.2:9527',
                              helperText: '跨电脑连接请填写服务端当前局域网 IPv4 地址',
                              prefixIcon: Icon(LucideIcons.server, size: 19),
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
                              prefixIcon: const Icon(LucideIcons.keyRound, size: 19),
                              suffixIcon: IconButton(
                                tooltip: _showToken ? '隐藏 Token' : '显示 Token',
                                onPressed: () => setState(() => _showToken = !_showToken),
                                icon: Icon(
                                  _showToken ? LucideIcons.eyeOff : LucideIcons.eye,
                                  size: 19,
                                ),
                              ),
                            ),
                            validator: (value) => (value?.trim().length ?? 0) < 16
                                ? 'Token 至少需要 16 个字符'
                                : null,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(13),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.errorContainer,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.error.withValues(alpha: 0.2),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    LucideIcons.circleAlert,
                                    size: 18,
                                    color: Theme.of(context).colorScheme.onErrorContainer,
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Text(
                                      _error!,
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.onErrorContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: _submitting ? null : _submit,
                            icon: _submitting
                                ? const SizedBox.square(
                                    dimension: 17,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(LucideIcons.link, size: 18),
                            label: Text(
                              _isEditing ? '测试并保存新地址' : '测试并保存连接',
                            ),
                          ),
                          if (_isEditing) ...[
                            const SizedBox(height: 10),
                            TextButton(
                              onPressed: _submitting ? null : widget.onCancel,
                              child: const Text('取消修改，返回客户端'),
                            ),
                          ],
                          const SizedBox(height: 18),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AppStatusPill(
                                label: '局域网直连',
                                icon: LucideIcons.shieldCheck,
                                color: Color(0xFF2B9B66),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
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
