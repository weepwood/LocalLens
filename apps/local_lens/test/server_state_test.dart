import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/server_state.dart';

void main() {
  group('LibraryInfo', () {
    test('parses counts and an empty last scan timestamp', () {
      final library = LibraryInfo.fromJson(<String, dynamic>{
        'id': 'main',
        'name': '媒体库',
        'recursive': true,
        'enabled': true,
        'mediaCount': 1250,
        'lastScannedAt': '',
      });

      expect(library.id, 'main');
      expect(library.lastScannedAt, isNull);
      expect(library.recursive, isTrue);
      expect(library.mediaCount, 1250);
    });
  });

  group('MediaStats', () {
    test('parses server aggregate values', () {
      final stats = MediaStats.fromJson(<String, dynamic>{
        'total': 10,
        'images': 7,
        'videos': 3,
        'favorites': 2,
        'sizeBytes': 4096,
      });

      expect(stats.total, 10);
      expect(stats.images, 7);
      expect(stats.videos, 3);
      expect(stats.favorites, 2);
      expect(stats.sizeBytes, 4096);
    });
  });

  group('ScanStatus', () {
    test('clamps progress to the valid range', () {
      final status = ScanStatus.fromJson(<String, dynamic>{
        'running': true,
        'discovered': 10,
        'indexed': 12,
        'failed': 1,
      });

      expect(status.progress, 1);
      expect(status.failed, 1);
    });

    test('uses indeterminate progress before discovery starts', () {
      final status = ScanStatus.fromJson(<String, dynamic>{
        'running': true,
        'discovered': 0,
        'indexed': 0,
        'failed': 0,
      });

      expect(status.progress, isNull);
    });
  });
}
