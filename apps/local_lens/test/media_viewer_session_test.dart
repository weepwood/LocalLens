import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/media_item.dart';
import 'package:local_lens/models/media_viewer_session.dart';

void main() {
  test('viewer session clamps index and navigates without leaving bounds', () {
    final items = [_item('one'), _item('two'), _item('three')];
    final session = MediaViewerSession(items: items, initialIndex: 99);

    expect(session.index, 2);
    expect(session.current.id, 'three');
    expect(session.canMoveNext, isFalse);
    expect(session.moveNext(), isFalse);
    expect(session.movePrevious(), isTrue);
    expect(session.current.id, 'two');
    expect(session.moveTo(0), isTrue);
    expect(session.current.id, 'one');
    expect(session.movePrevious(), isFalse);
  });

  test('viewer session replaces updated media without changing selection', () {
    final session = MediaViewerSession(
      items: [_item('one'), _item('two')],
      initialIndex: 1,
    );

    session.replace(session.current.copyWith(favorite: true, rating: 5));

    expect(session.index, 1);
    expect(session.current.favorite, isTrue);
    expect(session.current.rating, 5);
    expect(session.items.first.favorite, isFalse);
  });
}

MediaItem _item(String id) => MediaItem(
      id: id,
      libraryId: 'main',
      relativePath: '$id.jpg',
      folderPath: '',
      fileName: '$id.jpg',
      type: 'image',
      mimeType: 'image/jpeg',
      sizeBytes: 1024,
      modifiedAt: DateTime(2026),
      capturedAt: DateTime(2026),
      capturedAtSource: 'exif',
      width: 1920,
      height: 1080,
      durationMs: 0,
      codec: '',
      metadataStatus: 'done',
      favorite: false,
      rating: 0,
      thumbnailUrl: '/thumb/$id',
      originalUrl: '/original/$id',
      streamUrl: '/stream/$id',
    );
