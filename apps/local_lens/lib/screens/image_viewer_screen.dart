import 'package:flutter/material.dart';

import '../models/media_item.dart';

class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({
    required this.item,
    required this.url,
    required this.headers,
    super.key,
  });

  final MediaItem item;
  final String url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(item.fileName),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 8,
          child: Image.network(
            url,
            headers: headers,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const Center(child: CircularProgressIndicator()),
            errorBuilder: (context, error, stackTrace) => const Center(
              child: Text('图片加载失败', style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}
