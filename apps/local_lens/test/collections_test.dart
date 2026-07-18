import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/collections.dart';

void main() {
  test('parses folder hierarchy and media collection state', () {
    final folder = FolderInfo.fromJson(<String, dynamic>{
      'id': 'folder-1',
      'libraryId': 'main',
      'path': '2026/Tokyo',
      'parentPath': '2026',
      'name': 'Tokyo',
      'mediaCount': 25,
      'childCount': 2,
    });
    expect(folder.path, '2026/Tokyo');
    expect(folder.parentPath, '2026');
    expect(folder.mediaCount, 25);

    final state = MediaCollectionState.fromJson(<String, dynamic>{
      'albumIds': ['a', 'b'],
      'tagIds': ['t'],
    });
    expect(state.albumIds, {'a', 'b'});
    expect(state.tagIds, {'t'});
  });

  test('parses QR pairing payload and playback progress', () {
    final value = jsonEncode(<String, dynamic>{
      'version': 1,
      'baseUrl': 'http://192.168.1.2:9527',
      'serverName': 'Home',
      'pairingId': 'pair',
      'secret': 'secret',
      'expiresAt': '2026-07-18T13:00:00Z',
    });
    final payload = PairingPayload.parse(value);
    expect(payload.serverName, 'Home');
    expect(payload.pairingId, 'pair');

    final progress = PlaybackProgress.fromJson(<String, dynamic>{
      'positionMs': 12000,
      'durationMs': 60000,
      'completed': false,
    });
    expect(progress.positionMs, 12000);
    expect(progress.completed, isFalse);
  });
}
