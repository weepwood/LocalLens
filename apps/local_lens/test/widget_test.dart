import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/server_settings.dart';

void main() {
  group('ServerSettings', () {
    test('removes one trailing slash from the base URL', () {
      const settings = ServerSettings(
        baseUrl: 'http://192.168.1.20:9527/',
        token: 'test-token',
      );

      expect(settings.normalizedBaseUrl, 'http://192.168.1.20:9527');
    });

    test('keeps a base URL without trailing slash unchanged', () {
      const settings = ServerSettings(
        baseUrl: 'http://192.168.1.20:9527',
        token: 'test-token',
      );

      expect(settings.normalizedBaseUrl, 'http://192.168.1.20:9527');
    });
  });
}
