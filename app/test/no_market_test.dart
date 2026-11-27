// Choosing under You receive an asset nobody offers for what is paid says so at once, before an
// amount is typed ("There is no market for … right now."), from the offers the composer reads
// anyway (engine.offered): no request of its own. While those offers are not known yet (the
// wallet's Bitcoin side still starting: the list is `pending`), nothing is said, and they are asked
// again shortly. The web wallet's no-market.test.mjs and its user-trade.test.mjs cases
// (ConcatenaLabs/sequentia-web-wallet#870).
import 'package:ambra/src/data/btc_lightning.dart';
import 'package:ambra/src/data/user_trade.dart';
import 'package:ambra/src/screens/user_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final x = 'aa' * 32, y = 'bb' * 32, z = 'cc' * 32;

/// A Bitcoin side that is up: nothing of it is called here but that it is there.
class UpBtc implements BtcLightning {
  @override
  Future<BigInt> balance() async => BigInt.zero;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

typedef Pairs = List<Map<String, Object>>;

UserTradeEngine engine({required Pairs pairs, List<Map<String, String>> quotes = const [], BtcLightning? btc, int Function()? now}) =>
    UserTradeEngine(UserTradeDeps(
      run: (cmd, _) async => cmd == 'coins'
          ? [
              {'leaf_id': 'c1', 'asset': x, 'value': '3000000', 'state': 'live'}
            ]
          : {'plans': []},
      fetchJson: (u, {post}) async => {'quotes': quotes},
      makers: () => ['http://m'],
      relayBook: (_, _) async => [],
      admitted: () async => (
            pairs: {
              'chains': {
                'g': {'pairs': pairs}
              }
            },
            genesis: 'g'
          ),
      read: () async => null,
      write: (_) async {},
      btc: btc == null ? null : () => btc,
      now: now,
      sleep: (_) async {},
    ));

void main() {
  test('while the Bitcoin side is not up, what only it could take is not known yet (pending), not unoffered', () async {
    final pairs = <Map<String, Object>>[
      {'pay': kUserBtc, 'receive': y, 'sources': ['btc-gateway']},
      {'pay': kUserBtc, 'receive': z, 'sources': ['leaf-maker']},
    ];
    final quotes = [
      {'give_asset': y, 'want_asset': kUserBtc, 'rate_num': '1', 'rate_den': '1', 'max_give': '1000000', 'min_give': '10000'}
    ];
    final before = await engine(pairs: pairs, quotes: quotes).offered(kUserBtc);
    expect([before.toList(), before.pending], [<String>[], true]);
    final after = await engine(pairs: pairs, quotes: quotes, btc: UpBtc()).offered(kUserBtc);
    expect([after.toList(), after.pending], [
      [y],
      false
    ]);
    // Nothing that needs it: an empty list is an answer.
    final none = await engine(pairs: [pairs[1]], quotes: quotes).offered(kUserBtc);
    expect(none.pending, isFalse);
    // Past kBtcStartMs a Bitcoin side that never came up is no longer waited for.
    var t = 0;
    final late = engine(pairs: pairs, quotes: quotes, now: () => t);
    t = kBtcStartMs + 1;
    expect((await late.offered(kUserBtc)).pending, isFalse);
  });

  test('an estimate only the starting Bitcoin side could give takes a moment (again), not "not offered"', () async {
    final pairs = <Map<String, Object>>[
      {'pay': kUserBtc, 'receive': y, 'sources': ['btc-gateway']}
    ];
    final quotes = [
      {'give_asset': y, 'want_asset': kUserBtc, 'rate_num': '1', 'rate_den': '1', 'max_give': '1000000', 'min_give': '10000'}
    ];
    var t = 0;
    final eng = engine(pairs: pairs, quotes: quotes, now: () => t);
    final e = await eng.estimate(pay: kUserBtc, receive: y, payAtoms: BigInt.from(50000));
    expect([e.ok, e.why, e.again], [false, 'not-offered', true]);
    t = kBtcStartMs + 10000;
    final later = await eng.estimate(pay: kUserBtc, receive: y, payAtoms: BigInt.from(50000));
    expect([later.ok, later.why, later.again], [false, 'not-offered', false]);
  });

  test('the words are default-mode words', () {
    expect(UserWords.noMarket('GOLD', 'BTC'), 'There is no market for GOLD with BTC right now.');
    expect(UserWords.all(), containsAll([UserWords.noMarket('YT', 'XT'), UserWords.noMarketRow]));
  });

  Widget composer(UserTradeEngine e) {
    final names = {x: 'XT', y: 'YT', z: 'ZT', kUserBtc: 'BTC'};
    return MaterialApp(
      home: Scaffold(
        body: UserComposer(
          engine: e,
          assets: () => [kUserBtc, x],
          known: () => [y, z],
          held: (a) => a == x ? BigInt.from(3000000) : BigInt.zero,
          ticker: (a) => names[a] ?? a,
          precision: (a) => 4,
          admittedReceives: (pay) async => pay == x ? [y, z] : const [],
        ),
      ),
    );
  }

  testWidgets('choosing an asset nobody offers says so at once, with no amount; the picker marks it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final e = engine(pairs: [
      {'pay': x, 'receive': y, 'sources': ['leaf-maker']},
      {'pay': x, 'receive': z, 'sources': ['leaf-maker']},
    ], quotes: [
      {'give_asset': y, 'want_asset': x, 'rate_num': '4', 'rate_den': '3', 'max_give': '1000000', 'min_give': '10000'}
    ]);
    await tester.pumpWidget(composer(e));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // YT is offered for XT: nothing said.
    expect(find.byKey(ValueKey('ucGet-$y')), findsOneWidget);
    expect(find.text(UserWords.noMarket('YT', 'XT')), findsNothing);
    // The receive picker marks what nobody offers for XT (ZT, and BTC: no pair of it here), never YT.
    await tester.tap(find.byKey(const ValueKey('ucGet')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('asset-row-note-$z')), findsOneWidget);
    expect(find.byKey(const ValueKey('asset-row-note-BTC')), findsOneWidget);
    expect(find.byKey(ValueKey('asset-row-note-$y')), findsNothing);
    await tester.tap(find.byKey(ValueKey('asset-row-$z')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // Chosen with no amount typed: said at once.
    expect(find.text(UserWords.noMarket('ZT', 'XT')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers not known yet say nothing about a market, and are asked again', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    var t = 0;
    final e = engine(
        pairs: [
          {'pay': x, 'receive': kUserBtc, 'sources': ['btc-gateway']},
        ],
        quotes: [
          {'give_asset': kUserBtc, 'want_asset': x, 'rate_num': '1', 'rate_den': '1', 'max_give': '1000000', 'min_give': '10000'}
        ],
        now: () => t);
    // The offers are asked again every few seconds while not known: never settled, so pumped by time.
    await tester.pumpWidget(composer(e));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byKey(const ValueKey('ucGet-BTC')), findsOneWidget);
    expect(find.textContaining('There is no market'), findsNothing, reason: 'the Bitcoin side is still starting');
    // Past the starting window the offers are an answer: BTC is said to have no market.
    t = kBtcStartMs + 1;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: kOffersPendingMs ~/ 5));
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(UserWords.noMarket('BTC', 'XT')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
  });
}
