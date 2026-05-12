import 'package:flutter_test/flutter_test.dart';
import 'package:light_winter_retailos/main.dart';

void main() {
  testWidgets('RetailOS shell renders', (WidgetTester tester) async {
    await tester.pumpWidget(const LightWinterPosApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(LightWinterPosApp), findsOneWidget);
  });
}
