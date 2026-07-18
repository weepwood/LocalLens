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

    final fields = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .toList(growable: false);

    expect(find.text('修改服务器连接'), findsOneWidget);
    expect(find.text('更新服务器地址'), findsOneWidget);
    expect(fields, hasLength(2));
    expect(fields[0].controller?.text, 'http://192.168.1.20:9527');
    expect(fields[1].controller?.text, 'existing-token-1234567890');
    expect(find.text('测试并保存新地址'), findsOneWidget);
    expect(find.text('取消修改，返回客户端'), findsOneWidget);
  });
}
