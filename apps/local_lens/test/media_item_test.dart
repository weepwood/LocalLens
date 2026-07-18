import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/media_item.dart';

void main() {
  test('parses media favorite and cursor metadata', () {
    final page = MediaPage.fromJson(<String, dynamic>{
      'items': [
        <String, dynamic>{
          'id': 'media-1',
          'libraryId': 'main',
          'fileName': 'photo.jpg',
          'type': 'image',
          'mimeType': 'image/jpeg',
          'sizeBytes': 1024,
          'modifiedAt': '2026-07-18T12:00:00Z',
          'favorite': true,
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

    expect(page.items.single.libraryId, 'main');
    expect(page.items.single.favorite, isTrue);
    expect(page.nextCursor, 'cursor-value');
    expect(page.hasMore, isTrue);
    expect(page.items.single.copyWith(favorite: false).favorite, isFalse);
  });
}
