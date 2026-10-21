import 'package:ambra/src/data/leaf_rail.dart';
import 'package:ambra/src/data/swap_route.dart' show kBtcSentinel;
import 'package:ambra/src/screens/leaf_rail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const x = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const y = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  group('the rail type', () {
    test('the yes/no Lightning preference reads off the rail; a leaf reads as on-chain', () {
      expect(railLn(null), isNull);
      expect(railLn(SettleRail.ln), isTrue);
      expect(railLn(SettleRail.chain), isFalse);
      expect(railLn(SettleRail.leaf), isFalse);
      expect(railFromLn(true), SettleRail.ln);
      expect(railFromLn(false), SettleRail.chain);
      expect(railFromLn(null), isNull);
    });
  });

  group('when Leaf is offered', () {
    test('only in developer mode, for two Sequentia assets', () {
      expect(leafRailOffered(dev: false, joined: true, pay: x, recv: y).offered, isFalse);
      final ok = leafRailOffered(dev: true, joined: true, pay: x, recv: y);
      expect((ok.offered, ok.usable), (true, true));
      final btc = leafRailOffered(dev: true, joined: true, pay: kBtcSentinel, recv: y);
      expect((btc.offered, btc.why), (false, LeafWords.btc));
      final nj = leafRailOffered(dev: true, joined: false, pay: x, recv: y);
      expect((nj.offered, nj.usable, nj.why), (true, false, LeafWords.join));
    });
  });

  group('what a choice settles as', () {
    LeafShapeKind k(SettleRail? p, SettleRail? r, String mode, {String pay = x, String recv = y}) =>
        leafShape(pay: pay, recv: recv, payRail: p, recvRail: r, mode: mode).kind;
    test('Leaf to Leaf: a take in Market, an in-tree swap in Limit', () {
      expect(k(SettleRail.leaf, SettleRail.leaf, 'take'), LeafShapeKind.take);
      expect(k(SettleRail.leaf, SettleRail.leaf, 'post'), LeafShapeKind.swap);
    });
    test('no leaf, or one leg still to choose', () {
      expect(k(SettleRail.chain, SettleRail.ln, 'take'), LeafShapeKind.none);
      expect(k(SettleRail.leaf, null, 'take'), LeafShapeKind.pending);
    });
    test('every other shape is refused, with its reason', () {
      expect(leafShape(pay: x, recv: y, payRail: SettleRail.chain, recvRail: SettleRail.leaf, mode: 'take').why, LeafWords.payToo);
      expect(leafShape(pay: x, recv: y, payRail: SettleRail.leaf, recvRail: SettleRail.ln, mode: 'take').why, LeafWords.ln);
      expect(leafShape(pay: x, recv: y, payRail: SettleRail.leaf, recvRail: SettleRail.chain, mode: 'post').why, LeafWords.chain);
      expect(leafShape(pay: kBtcSentinel, recv: y, payRail: SettleRail.leaf, recvRail: SettleRail.leaf, mode: 'take').why, LeafWords.btc);
    });
  });

  group('which order a take from leaves fills', () {
    Map<String, dynamic> cov(String id, int offer, int want, {bool covenant = true, bool conf = false, String sells = y}) => {
          'offer_id': id,
          'offer_asset': sells,
          'want_asset': sells == y ? x : y,
          'offer_amount': '$offer',
          'want_amount': '$want',
          if (covenant) 'covenant': {'covenant_txid': 'ab'},
          if (conf) 'confidential': true,
        };
    final offers = [
      cov('intent', 1000000, 900000, covenant: false),
      cov('blind', 1000000, 950000, conf: true),
      cov('small', 200000, 200000),
      cov('ok', 600000, 1200000),
      cov('other-way', 600000, 1200000, sells: x),
    ];
    test('the cheapest the round can take, holding the amount when one does', () {
      expect(bestLeafOrder(offers, pay: x, recv: y, amount: BigInt.from(300000))!['offer_id'], 'ok');
      expect(bestLeafOrder(offers, pay: x, recv: y, amount: BigInt.from(100000))!['offer_id'], 'small');
      expect(bestLeafOrder(offers, pay: x, recv: y, amount: BigInt.from(9000000))!['offer_id'], 'small');
      expect(bestLeafOrder(offers.take(2).toList(), pay: x, recv: y, amount: BigInt.one), isNull);
      expect(bestLeafOrder(offers, pay: x, recv: y, amount: BigInt.one, verified: (o) => o['offer_id'] != 'small')!['offer_id'], 'ok');
    });
  });

  group('the panel', () {
    String amt(String a, Object? v) => '$v ${a == x ? 'XLEAF' : 'YLEAF'}';

    // The composer's amounts are in units: an asset with no label reads at precision 8.
    Widget host(String mode, Future<dynamic> Function(String, Map<String, dynamic>) run,
            {String pay = '0.003', String recv = '0.004', Future<List<Map<String, dynamic>>> Function(String, String)? offers}) =>
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LeafRailPanel(
                pay: x,
                recv: y,
                payRail: SettleRail.leaf,
                recvRail: SettleRail.leaf,
                mode: mode,
                payAmount: TextEditingController(text: pay),
                recvAmount: TextEditingController(text: recv),
                amount: amt,
                run: run,
                fetchOffers: offers,
              ),
            ),
          ),
        );

    testWidgets('an offer shows what is given, got and paid; the completion signs only after it', (t) async {
      final calls = <String>[];
      await t.pumpWidget(host('post', (cmd, args) async {
        calls.add(cmd);
        if (cmd == 'swap_offer') {
          expect(args, {'give_asset': x, 'give': '300000', 'want_asset': y, 'want': '400000'});
          return {
            'swap': 's' * 64,
            'offer': 'swap-offer:7b7d',
            'gives': {'asset': x, 'value': '300000'},
            'gets': {'asset': y, 'value': '400000'},
            'pays': {'asset': x, 'margin': '536', 'margins': '192'},
          };
        }
        if (cmd == 'swap_complete') return {'swap': 's' * 64};
        throw Exception('no $cmd');
      }));
      await t.tap(find.byKey(const ValueKey('leafOffer')));
      await t.pumpAndSettle();
      expect(find.textContaining('300000 XLEAF from your leaves'), findsWidgets);
      expect(find.textContaining('536 XLEAF as the reassignment'), findsWidgets);
      expect(find.text('swap-offer:7b7d'), findsOneWidget);
      expect(calls, ['swap_offer']);
      await t.enterText(find.descendant(of: find.byKey(const ValueKey('leafAcceptIn')), matching: find.byType(TextField)), 'swap-accept:7b7d');
      await t.ensureVisible(find.byKey(const ValueKey('leafCompleteGo')));
      await t.tap(find.byKey(const ValueKey('leafCompleteGo')));
      await t.pumpAndSettle();
      expect(calls, ['swap_offer', 'swap_complete']);
      expect(find.byKey(const ValueKey('leafNote')), findsOneWidget);
    });

    testWidgets('a read shows the library\'s terms; the acceptance carries them as shown', (t) async {
      final read = {
        'swap': 's' * 64,
        'gets': {'asset': x, 'value': '300000'},
        'gives': {'asset': y, 'value': '400000'},
        'pays': {'asset': y, 'margins': '2'},
        'maker_pays': {'asset': x, 'margin': '536'},
        'change': {'asset': y, 'value': '0'},
        'dates': {'exit_deadline': 1800000000},
      };
      Map<String, dynamic>? accepted;
      await t.pumpWidget(host('take', (cmd, args) async {
        if (cmd == 'swap_read') return read;
        if (cmd == 'swap_accept') {
          accepted = args;
          return {'swap': 's' * 64, 'accept': 'swap-accept:7b7d'};
        }
        throw Exception('no $cmd');
      }));
      await t.enterText(find.descendant(of: find.byKey(const ValueKey('leafOfferIn')), matching: find.byType(TextField)), 'swap-offer:7b7d');
      await t.ensureVisible(find.text('Read the offer'));
      await t.tap(find.text('Read the offer'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('leafReadRows')), findsOneWidget);
      expect(find.textContaining('2 YLEAF: the margins your coins leave'), findsOneWidget);
      expect(find.textContaining('536 XLEAF as the reassignment'), findsOneWidget);
      expect(accepted, isNull, reason: 'nothing is signed by a read');
      await t.ensureVisible(find.byKey(const ValueKey('leafAcceptGo')));
      await t.tap(find.byKey(const ValueKey('leafAcceptGo')));
      await t.pumpAndSettle();
      expect(accepted, {'offer': 'swap-offer:7b7d', 'shown': read});
      expect(find.text('swap-accept:7b7d'), findsOneWidget);
    });

    testWidgets('a take is quoted by the library against the best order the round can take', (t) async {
      final order = {'offer_id': 'ok', 'offer_asset': y, 'want_asset': x, 'offer_amount': '600000', 'want_amount': '600000', 'covenant': {'covenant_txid': 'ab'}};
      final asked = <String, Map<String, dynamic>>{};
      await t.pumpWidget(host('take', (cmd, args) async {
        asked[cmd] = args;
        if (cmd == 'take_quote') {
          return {'order': 'ab:0', 'asset_a': y, 'asset_b': x, 'filled': '300000', 'gives': '301000', 'price': '300000', 'fee': '1000', 'remainder': '300000'};
        }
        if (cmd == 'info') return {'server_info': {'fills': {'forfeit_window_seconds': 600}}};
        throw Exception('no $cmd');
      }, recv: '0.003', offers: (a, b) async => [order]));
      await t.tap(find.byKey(const ValueKey('leafTakeReview')));
      await t.pumpAndSettle();
      expect(asked['take_quote'], {'order': order, 'amount': '300000'});
      expect(find.byKey(const ValueKey('leafTakeRows')), findsOneWidget);
      expect(find.textContaining('301000 XLEAF: the price and the operator'), findsOneWidget);
      expect(find.textContaining('within 10 minutes'), findsOneWidget);
    });
  });

  test('an offer is verified with its covenant bytes as hex, and handed on as the relay served it', () {
    final o = {
      'offer_id': 'a',
      'covenant': {
        'internal_key': 'UJKbdMGgSVS3i0tgNel6XgeKWg8o7JbVR7/ums6AOsA=',
        'merkle_path': ['XxWRiGicv3poxE8vvWbrMYJHwe64UA1tQ719iTPBQNA='],
        'maker_prog': '11' * 32,
        'covenant_txid': 'ab',
      },
    };
    final v = offerForVerify(o);
    expect((v['covenant'] as Map)['internal_key'], '50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0');
    expect(((v['covenant'] as Map)['merkle_path'] as List).single, '5f159188689cbf7a68c44f2fbd66eb318247c1eeb8500d6d43bd7d8933c140d0');
    expect((v['covenant'] as Map)['maker_prog'], '11' * 32);
    expect((o['covenant'] as Map)['internal_key'], 'UJKbdMGgSVS3i0tgNel6XgeKWg8o7JbVR7/ums6AOsA=', reason: 'the original is untouched');
  });
}
