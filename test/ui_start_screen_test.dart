// UI (widget) test for the screens reachable WITHOUT a running mesh node — i.e.
// before onboarding. Proves the widget-test layer works (tap/find/assert) for
// node-free UI. Post-onboarding screens need a node and are covered separately.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a fresh launch shows the start screen (scanner-first)',
      (tester) async {
    SharedPreferences.setMockInitialValues({}); // no formation key -> start screen
    await tester.pumpWidget(const GrapheionApp());
    await tester.pump(); // let _restoreIdentity's async settle (no node starts)

    expect(find.text('Grapheion'), findsWidgets);
    expect(find.text('Scan join QR'), findsOneWidget,
        reason: 'entry leads with the scanner');
    expect(find.text('Set up a new mesh instead'), findsOneWidget,
        reason: 'host option is the secondary action');
  });

  testWidgets('the theme toggle button is present on the start screen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const GrapheionApp());
    await tester.pump();
    expect(find.byType(IconButton), findsWidgets); // the ☀️/🌙 toggle
  });
}
