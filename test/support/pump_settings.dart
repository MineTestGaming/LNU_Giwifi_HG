import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitForSettings(WidgetTester tester) async {
  final devices = find.byType(ChoiceChip).first;
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (tester.widget<ChoiceChip>(devices).onSelected != null) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Settings did not finish loading or saving');
}
