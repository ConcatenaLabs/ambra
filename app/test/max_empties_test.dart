// Max empties the coins: the person's figure is all-in. After Max the amount field, the ticket's You
// pay and what leaves the wallet are one number, the fees in it, and nothing stays; where one trade
// cannot take all of it, the amount is what goes and the ticket names what stays. And a trade the
// wallet itself cannot pay with the fees says what can be traded now (own-short).
//
// The web wallet's max-empties.test.mjs (ConcatenaLabs/sequentia-web-wallet 75ce2b70, db1ba020).
// The engine and the composer are the real ones; the library is a stand-in that chooses coins and
// refuses as the leaf library does (each coin keeps its value less a checkpoint margin; at most 16
// coins a payment, largest first; change none or at least the operator's smallest leaf; a refusal
// for want of funds carries `most`, `all` and `live`), and the maker prices as the real one does
// (it wants ceil(give x rate_num / rate_den)).
import 'package:ambra/src/data/format.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/user_trade.dart';
import 'package:ambra/src/screens/user_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final x = 'aa' * 32, y = 'bb' * 32;
final m = BigInt.from(192), leaf = BigInt.from(1000);

class StandIn {
  StandIn(List<int> values, {this.rate = const (4, 3), this.figures = true, this.alwaysShort = false})
      : values = [for (final v in values) BigInt.from(v)] {
    order = [...this.values]..sort((a, b) => b.compareTo(a));
    if (order.length > 16) order = order.sublist(0, 16);
    live = this.values.fold(BigInt.zero, (n, v) => n + v);
    allK = keptOf(order.length);
  }
  final List<BigInt> values;
  final (int, int) rate;
  final bool figures;
  /// Every payment is refused for want of its margins: nothing the wallet asks can go.
  final bool alwaysShort;
  late List<BigInt> order;
  late BigInt live, allK;
  int get n => order.length;
  BigInt keptOf(int k) => order.take(k).fold(BigInt.zero, (s, v) => s + v - m);

  Never refuse(String message, [Map<String, dynamic> extra = const {}]) => throw LeafRefusal('refused', message,
      asset: x, fields: {'kind': 'refused', 'message': message, if (figures) ...{'most': '${allK - leaf}', 'all': '$allK', ...extra}});

  Future<dynamic> run(String cmd, Map<String, dynamic> a) async {
    switch (cmd) {
      case 'coins':
        return [
          for (var i = 0; i < values.length; i++) {'leaf_id': 'c$i', 'asset': x, 'value': '${values[i]}', 'state': 'live', 'kind': 'board'}
        ];
      case 'plans':
        return {'plans': []};
      case 'swap_read':
        final parts = '${a['offer']}'.split(':');
        final give = BigInt.parse(parts[1]), want = BigInt.parse(parts[2]);
        if (alwaysShort) {
          refuse(
              'refused: the wallet holds $live of asset $x in live coins, and paying $want takes ${want + BigInt.from(order.length) * m} with the margins its transactions leave for their fees',
              {'live': '$live'});
        }
        for (var k = 1; k <= order.length; k++) {
          final ch = keptOf(k) - want;
          if (ch < BigInt.zero || (ch > BigInt.zero && ch < leaf)) continue;
          return {
            'swap': 's-$give',
            'gets': {'asset': y, 'value': '$give'},
            'gives': {'asset': x, 'value': '$want'},
            'pays': {'asset': x, 'margins': '${BigInt.from(k) * m}'},
            'change': ch > BigInt.zero ? {'asset': x, 'value': '$ch'} : null,
            'dates': {'expiry': 1800000000},
            'hops': 1,
          };
        }
        if (want > allK) {
          refuse(
              'refused: the wallet holds $live of asset $x in live coins, and paying $want takes ${want + BigInt.from(order.length) * m} with the margins its transactions leave for their fees',
              {'live': '$live'});
        }
        refuse("refused: the change would be below the operator's smallest leaf in asset $x ($leaf atoms): pay a little less, or that much more");
      case 'settle_quote':
        return {'asset': a['asset'], 'value': a['value'], 'fee': '3', 'after': '${BigInt.parse('${a['value']}') - BigInt.from(3)}'};
      case 'swap_cancel':
        return {'cancelled': true};
      case 'swaps':
        return [];
      default:
        return {};
    }
  }

  Future<Map<String, dynamic>> fetchJson(String url, {Map<String, dynamic>? post}) async {
    final num = BigInt.from(rate.$1), den = BigInt.from(rate.$2);
    if (url.endsWith('/v1/quotes')) {
      return {
        'quotes': [
          {'give_asset': y, 'want_asset': x, 'rate_num': '$num', 'rate_den': '$den', 'max_give': '50000000', 'min_give': '1000'}
        ]
      };
    }
    if (url.endsWith('/v1/firm')) {
      final give = BigInt.parse('${post!['give']}');
      final want = (give * num + den - BigInt.one) ~/ den;
      return {'swap': 's-$give', 'offer': 'swap-offer:$give:$want', 'give': '$give', 'want': '$want'};
    }
    return {};
  }
}

UserTradeEngine engineOf(StandIn s) {
  var t = 0;
  return UserTradeEngine(UserTradeDeps(
    run: s.run,
    fetchJson: s.fetchJson,
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
    now: () => t += 1000,
    sleep: (_) async {},
    held: (_) async => s.live,
  ));
}

BigInt feesIn(Ticket k, String a) => k.fees.where((f) => f['asset'] == a).fold(BigInt.zero, (n, f) => n + (f['atoms'] as BigInt));

void main() {
  test('the library refusal figures, as the web wallet reads them', () {
    final short = LeafRefusal('refused', 'refused: the wallet holds 1000000 of asset $x in live coins, and paying 999900 takes 1000092 with the margins',
        fields: {'most': '998808', 'all': '999808', 'live': '1000000'});
    expect(refusalMost(short), BigInt.from(998808));
    expect(refusalAll(short), BigInt.from(999808));
    expect(refusalMargins(short), BigInt.from(192));
    expect(refusalLive(short), BigInt.from(1000000));
    // A library that gives no figures: read from its words.
    final words = LeafRefusal('refused', short.message);
    expect(refusalMost(words), BigInt.from(999900 - 92));
    expect(refusalAll(words), isNull);
    expect(refusalLive(words), BigInt.from(1000000));
    expect(shortBy("refused: the change would be below the operator's smallest leaf in asset $x (1000 atoms): pay a little less"), BigInt.from(1000));
    expect(ownShortMost('something else'), isNull);
  });

  for (final (label, values, rate) in [
    ('one coin', [1000000], (4, 3)),
    ('three coins', [500000, 300000, 200000], (4, 3)),
    ("three coins at 3:1, where the maker's want moves by 3", [500000, 300002, 200000], (3, 1)),
  ]) {
    test('the whole balance asked: the trade empties the coins ($label)', () async {
      final s = StandIn(values, rate: rate);
      final q = await engineOf(s).quote(pay: x, receive: y, amount: s.live);
      expect(q.ok, isTrue, reason: q.why);
      final t = q.choice!.terms!;
      expect(t['change'], isNull, reason: 'change stays: $t');
      expect('${(t['gives'] as Map)['value']}', '${s.allK}');
      expect(q.ticket!.amountIn, s.live, reason: 'You pay is the whole balance');
      expect(feesIn(q.ticket!, x), BigInt.from(s.n) * m, reason: 'the margins are the fees in the asset paid');
    });
  }

  test('no give of the maker pays exactly what the coins keep: the trade goes, leaving at least the smallest leaf', () async {
    final s = StandIn([1000000], rate: (3, 1));
    final q = await engineOf(s).quote(pay: x, receive: y, amount: s.live);
    expect(q.ok, isTrue, reason: q.why);
    final ch = BigInt.parse('${(q.choice!.terms!['change'] as Map)['value']}');
    expect(ch >= leaf, isTrue, reason: 'change $ch');
    // The phone settles the change in the next round, and that fee (3 here) is in You pay.
    expect(q.ticket!.amountIn + ch, s.live + BigInt.from(3), reason: 'You pay and what stays are the balance');
  });

  test('an amount less than the coins keep is not made larger', () async {
    final s = StandIn([1000000]);
    final q = await engineOf(s).quote(pay: x, receive: y, amount: BigInt.from(500000));
    expect(q.ok, isTrue, reason: q.why);
    expect(q.ticket!.amountIn <= BigInt.from(500000), isTrue);
    expect(BigInt.parse('${(q.choice!.terms!['change'] as Map)['value']}') >= BigInt.from(499000), isTrue);
  });

  test('more than the wallet can pay with the fees: what can be traded now, and what emptying the coins pays', () async {
    final s = StandIn([1000000], alwaysShort: true);
    final q = await engineOf(s).quote(pay: x, receive: y, amount: BigInt.from(900000));
    expect([q.ok, q.why], [false, 'own-short']);
    expect(q.most, s.allK - leaf);
    expect(q.all, s.allK + m);
    expect(UserWords.ownShort('1 XT'), contains('You can trade up to 1 XT now'));
  });

  Future<({String field, Ticket k, String? stays, Map? change})> max(WidgetTester tester, StandIn s, int precision) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final names = {x: 'XT', y: 'YT', kUserBtc: 'BTC'};
    final e = engineOf(s);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UserComposer(
          engine: e,
          assets: () => [kUserBtc, x],
          known: () => [y],
          held: (a) => a == x ? s.live : BigInt.zero,
          ticker: (a) => names[a] ?? a,
          precision: (_) => precision,
          admittedReceives: (pay) async => pay == x ? [y] : const [],
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('ucMax')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ucReview')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final st = tester.state(find.byType(UserComposer)) as dynamic;
    expect(find.byKey(const ValueKey('ucConfirm')), findsOneWidget, reason: 'no ticket');
    final field = (tester.widget(find.byKey(const ValueKey('ucAmount'))) as TextField).controller!.text;
    final stays = find.byKey(const ValueKey('ucStays'));
    final k = st.ticketForTest as Ticket;
    final change = (st.choiceForTest as Candidate).terms?['change'] as Map?;
    return (field: field, k: k, stays: stays.evaluate().isEmpty ? null : (tester.widget(stays) as Text).data, change: change);
  }

  for (final precision in [8, 2]) {
    testWidgets('Max: the field and You pay are the balance, nothing stays (precision $precision)', (tester) async {
      for (final values in [
        [1000000],
        [500000, 300000, 200000]
      ]) {
        final s = StandIn(values);
        final r = await max(tester, s, precision);
        expect(r.field, formatAtoms('${s.live}', precision));
        expect(r.k.amountIn, s.live);
        expect(r.change, isNull);
        expect(r.stays, isNull);
      }
    });

    testWidgets('Max over 17 coins: one trade takes 16, the field is what it pays, the 17th is named as staying (precision $precision)',
        (tester) async {
      final s = StandIn([for (var i = 0; i < 17; i++) 100000 + i * 1000]);
      final r = await max(tester, s, precision);
      final paid = s.allK + BigInt.from(16) * m;
      expect(r.k.amountIn, paid);
      expect(r.field, formatAtoms('$paid', precision));
      expect(r.change, isNull);
      expect(r.stays, UserWords.stays('${formatAtoms('100000', precision)} XT'));
    });

    testWidgets('Max where no offer pays exactly the rest: the field is what goes, and what stays is named (precision $precision)',
        (tester) async {
      final s = StandIn([1000000], rate: (3, 1));
      final r = await max(tester, s, precision);
      // What stays is the change less its settling fee (3), which You pay carries.
      final left = s.live - r.k.amountIn;
      expect(left + BigInt.from(3) >= leaf, isTrue, reason: 'left $left');
      expect(r.field, formatAtoms('${r.k.amountIn}', precision));
      expect(r.stays, UserWords.stays('${formatAtoms('$left', precision)} XT'));
    });

    testWidgets('Max with a library that gives no figures: the terms it reads show the coins whole, and the trade empties them (precision $precision)',
        (tester) async {
      final s = StandIn([1000000], figures: false);
      final r = await max(tester, s, precision);
      expect(r.k.amountIn, s.live);
      expect(r.field, formatAtoms('${s.live}', precision));
      expect(r.change, isNull);
      expect(r.stays, isNull);
    });
  }
}
