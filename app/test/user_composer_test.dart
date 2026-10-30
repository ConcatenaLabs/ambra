// Default mode's Swap tab (screens/user_composer.dart) drawn with a stand-in maker and relay:
// both pickers open the searchable chooser, You pay and You receive are tethered both ways, Max
// fills what is held, and the pair's market shows above You pay.
import 'package:ambra/src/data/user_trade.dart';
import 'package:ambra/src/screens/user_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final x = 'aa' * 32, y = 'bb' * 32, z = 'cc' * 32;

UserTradeEngine engine() => UserTradeEngine(UserTradeDeps(
      run: (cmd, _) async => cmd == 'coins'
          ? [
              {'leaf_id': 'c1', 'asset': x, 'value': '3000000', 'state': 'live'}
            ]
          : {'plans': []},
      fetchJson: (u, {post}) async => {
            'quotes': [
              {'give_asset': y, 'want_asset': x, 'rate_num': '4', 'rate_den': '3', 'max_give': '1000000', 'min_give': '10000'}
            ]
          },
      makers: () => ['http://m'],
      relayBook: (_, _) async => [],
      admitted: () async => (
            pairs: {
              'chains': {
                'g': {
                  'pairs': [
                    {'pay': x, 'receive': y, 'sources': ['leaf-maker']}
                  ]
                }
              }
            },
            genesis: 'g'
          ),
      read: () async => null,
      write: (_) async {},
    ));

Future<Map?> relay(String path) async {
  if (path.contains('/trades')) {
    return {
      'trades': [
        {'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120, 'price': 1.3333, 'size': 300000, 'side': 'buy'}
      ]
    };
  }
  if (path.contains('/ticker')) return {'last': 1};
  return null;
}

void main() {
  testWidgets('chooser, tethered amounts, Max and the market', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final names = {x: 'XT', y: 'YT', z: 'ZT', kUserBtc: 'BTC'};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UserComposer(
          engine: engine(),
          assets: () => [kUserBtc, x],
          known: () => [y, z],
          held: (a) => a == x ? BigInt.from(3000000) : BigInt.zero,
          ticker: (a) => names[a] ?? a,
          precision: (a) => 4,
          admittedReceives: (pay) async => pay == x ? [y] : const [],
          relay: () => 'http://relay',
          marketGet: relay,
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // XT is held, so it is what is paid; YT is what the book offers for it.
    expect(find.byKey(ValueKey('ucPay-$x')), findsOneWidget);
    expect(find.byKey(ValueKey('ucGet-$y')), findsOneWidget);
    expect(find.text('balance 300 XT'), findsOneWidget);
    // Each chooser reads as the asset it names, and the amount fields stay their own.
    expect(find.bySemanticsLabel('You pay: XT'), findsOneWidget);
    expect(find.bySemanticsLabel('You receive: YT'), findsOneWidget);
    // The market: the pair, the recent trade.
    expect(find.text('XT / YT'), findsOneWidget);
    expect(find.text('Recent trades'), findsOneWidget);

    // You pay 40 XT -> You receive 30 YT, by itself.
    await tester.enterText(find.byKey(const ValueKey('ucAmount')), '40');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect((tester.widget(find.byKey(const ValueKey('ucReceive'))) as TextField).controller!.text, '30');
    // And the other way: You receive 15 YT -> You pay 20 XT.
    await tester.enterText(find.byKey(const ValueKey('ucReceive')), '15');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect((tester.widget(find.byKey(const ValueKey('ucAmount'))) as TextField).controller!.text, '20');
    // More than the book fills: it says how much it can.
    await tester.enterText(find.byKey(const ValueKey('ucAmount')), '400');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('The book can fill up to 100 YT now.'), findsOneWidget);
    // Max: everything held.
    await tester.tap(find.byKey(const ValueKey('ucMax')));
    await tester.pumpAndSettle();
    expect((tester.widget(find.byKey(const ValueKey('ucAmount'))) as TextField).controller!.text, '300');

    // The receive chooser: a search box, YT before the rest, ZT reached by typing.
    await tester.tap(find.byKey(const ValueKey('ucGet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('asset-sheet-search')), findsOneWidget);
    expect(find.text('Search assets'), findsOneWidget);
    expect(find.text('ZT'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('asset-sheet-search')), 'zt');
    await tester.pumpAndSettle();
    await tester.tap(find.text('ZT'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('ucGet-$z')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
