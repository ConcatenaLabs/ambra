// The rewards card states the chain's maturity as the kit reports it (1,000
// blocks on Sequentia), never Bitcoin's 100.
//
//   cd app && flutter test test/rewards_maturity_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ambra/src/screens/stake_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // The card's opt-in switch is a ListTile on the card's own background: a debug-only paint hint
  // about ink splashes, not what this test is about.
  void quietListTileHint() {
    final orig = FlutterError.onError;
    FlutterError.onError = (d) {
      if ('${d.exception}'.contains('ListTile background color')) return;
      orig?.call(d);
    };
    addTearDown(() => FlutterError.onError = orig);
  }

  Future<void> pump(WidgetTester tester, int? maturity) => tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: RewardsCard(totals: const [], rows: const [], maturity: maturity))),
      ));

  testWidgets('the maturity read from the kit is the one shown', (tester) async {
    quietListTileHint();
    await pump(tester, 1000);
    expect(find.textContaining('spendable 1,000 blocks after they are earned'), findsOneWidget);
    expect(find.textContaining('100 blocks'), findsNothing);
  });

  testWidgets('before it is read, no number is guessed', (tester) async {
    quietListTileHint();
    await pump(tester, null);
    expect(find.textContaining('can be spent once they mature'), findsOneWidget);
    expect(find.textContaining('blocks after'), findsNothing);
  });
}
