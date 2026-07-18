import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/server_state.dart';

void main() {
  group('LibraryInfo', () {
    test('parses an empty last scan timestamp as null', () {
      final library = LibraryInfo.fromJson(<String, dynamic>{
        'id': 'main',
        'name': '媒体库',
        'recursive': true,
        'enabled': true,
        'lastScannedAt': '',
      });

      expect(library.id, 'main');
      expect(library.lastScannedAt, isNull);
      expect(library.recursive, isTrue);
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
