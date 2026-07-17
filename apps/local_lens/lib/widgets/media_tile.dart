import 'package:flutter/material.dart';

import '../models/media_item.dart';

class MediaTile extends StatelessWidget {
  const MediaTile({
    required this.item,
    required this.imageUrl,
    required this.headers,
    required this.onTap,
    super.key,
  });

  final MediaItem item;
  final String imageUrl;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              imageUrl,
              headers: headers,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Icon(Icons.broken_image_outlined, size: 36),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 24, 10, 8),
                  child: Row(
                    children: [
                      if (item.isVideo) ...[
                        const Icon(Icons.play_circle_outline, color: Colors.white, size: 18),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          item.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
