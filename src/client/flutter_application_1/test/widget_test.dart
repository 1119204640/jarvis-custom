import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/main.dart';

void main() {
  testWidgets('App renders with correct title', (WidgetTester tester) async {
    await tester.pumpWidget(const JarvisApp());

    // 应用标题应为 Jarvis
    expect(find.text('Jarvis'), findsOneWidget);

    // 首页应显示侧边栏中的第一个功能名称
    expect(find.text('记账'), findsOneWidget);
  });
}
