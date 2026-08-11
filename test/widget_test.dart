import 'package:flutter_test/flutter_test.dart';

import 'package:furniture_restyler_mobile/main.dart';

void main() {
  testWidgets('App renders home page with capture buttons', (WidgetTester tester) async {
    await tester.pumpWidget(const FurnitureRestylerApp());

    expect(find.text('Furniture Restyler'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);
  });
}
