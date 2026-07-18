import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/collections.dart';
import '../models/server_settings.dart';
import '../services/api_client.dart';

class PairingScannerScreen extends StatefulWidget {
  const PairingScannerScreen({super.key});

  @override
  State<PairingScannerScreen> createState() => _PairingScannerScreenState();
}

class _PairingScannerScreenState extends State<PairingScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _processing = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫描 LocalLens 配对码'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '切换闪光灯',
            onPressed: _controller.toggleTorch,
            icon: const Icon(Icons.flash_on_outlined),
          ),
          IconButton(
            tooltip: '切换摄像头',
            onPressed: _controller.switchCamera,
            icon: const Icon(Icons.cameraswitch_outlined),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '无法打开摄像头：$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 270,
              height: 270,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 32,
            child: Card(
              color: Colors.black.withValues(alpha: 0.72),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_processing)
                      const LinearProgressIndicator()
                    else
                      const Text(
                        '在 Windows 管理端打开“服务器与设备”，生成二维码后放入取景框。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white),
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (raw == null || raw.isEmpty) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    await _controller.stop();
    try {
      final payload = PairingPayload.parse(raw);
      if (DateTime.now().isAfter(payload.expiresAt)) {
        throw const FormatException('二维码已经过期，请在 Windows 端重新生成');
      }
      final settings = await ApiClient.claimPairing(
        payload,
        deviceName: _deviceName(),
        platform: Platform.operatingSystem,
      );
      if (!mounted) return;
      Navigator.of(context).pop<ServerSettings>(settings);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = error.toString();
      });
      await _controller.start();
    }
  }

  String _deviceName() {
    final hostname = Platform.localHostname.trim();
    if (hostname.isNotEmpty && hostname != 'localhost') return hostname;
    if (Platform.isAndroid) return 'Android 手机';
    if (Platform.isIOS) return 'iPhone';
    return 'LocalLens 设备';
  }
}
