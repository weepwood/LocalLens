import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/media_item.dart';

void main() {
  test('parses v0.2 timeline metadata rating and cursor', () {
    final page = MediaPage.fromJson(<String, dynamic>{
      'items': [
        <String, dynamic>{
          'id': 'media-1',
          'libraryId': 'main',
          'relativePath': 'Travel/photo.jpg',
          'folderPath': 'Travel',
          'fileName': 'photo.jpg',
          'type': 'image',
          'mimeType': 'image/jpeg',
          'sizeBytes': 1024,
          'modifiedAt': '2026-07-18T12:00:00Z',
          'capturedAt': '2020-01-02T03:04:05Z',
          'capturedAtSource': 'exif',
          'width': 4000,
          'height': 3000,
          'durationMs': 0,
          'codec': '',
          'latitude': 35.6,
          'longitude': 139.7,
          'cameraModel': 'Camera',
          'metadataStatus': 'done',
          'favorite': true,
          'rating': 4,
          'thumbnailUrl': '/thumbnail',
          'originalUrl': '/original',
          'streamUrl': '/stream',
        },
      ],
      'total': 3,
      'limit': 1,
      'offset': 0,
      'nextCursor': 'cursor-value',
      'hasMore': true,
    });

    final item = page.items.single;
    expect(item.libraryId, 'main');
    expect(item.folderPath, 'Travel');
    expect(item.capturedAt.year, 2020);
    expect(item.capturedAtSource, 'exif');
    expect(item.aspectRatio, closeTo(4 / 3, 0.001));
    expect(item.hasLocation, isTrue);
    expect(item.favorite, isTrue);
    expect(item.rating, 4);
    expect(page.nextCursor, 'cursor-value');
    expect(page.hasMore, isTrue);
    expect(item.copyWith(favorite: false, rating: 2).favorite, isFalse);
    expect(item.copyWith(rating: 2).rating, 2);
  });
}
