import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/server_settings.dart';
import 'package:local_lens/screens/setup_screen.dart';

void main() {
  testWidgets('edit mode pre-fills the saved address and token', (tester) async {
    const settings = ServerSettings(
      baseUrl: 'http://192.168.1.20:9527',
      token: 'existing-token-1234567890',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(
          initialSettings: settings,
          onSaved: (_) async {},
          onCancel: () {},
        ),
      ),
    );

    expect(find.text('修改服务器连接'), findsOneWidget);
    expect(find.text('更新服务器地址'), findsOneWidget);
    expect(find.text('http://192.168.1.20:9527'), findsOneWidget);
    expect(find.text('existing-token-1234567890'), findsOneWidget);
    expect(find.text('测试并保存新地址'), findsOneWidget);
    expect(find.text('取消修改，返回客户端'), findsOneWidget);
  });
}
