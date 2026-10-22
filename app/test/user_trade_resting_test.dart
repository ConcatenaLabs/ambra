// The user-mode composer's fill of an order resting in the operator's tree (data/user_trade.dart)
// against a stand-in leaf library and relay: the same cases as the web wallet's
// user-trade-resting.test.mjs.
import 'package:ambra/src/data/user_trade.dart';
import 'package:flutter_test/flutter_test.dart';

final x = 'aa' * 32, y = 'bb' * 32, op = 'ab' * 32, order = 'cd' * 32;

class Resting {
  Resting({this.moved = false, this.movedPrice});
  bool moved;
  final String? movedPrice;
  String atCoin = 'coin-1';
  String? shownCoin;
  String operator = op;
  String? stored;
  final coins = <Map<String, dynamic>>[
    {'leaf_id': 'c1', 'asset': x, 'value': '2000000', 'state': 'live', 'expiry': 1800000000}
  ];
  var parts = <Map<String, dynamic>>[];
  final fills = <Map<String, dynamic>>[];
  BigInt? eligible; // what the wallet's coins no older than the order's hold
  List<Map<String, dynamic>>? book;
  final refuse = <String>{};

  Map<String, dynamic> quote(String amount) {
    final a = BigInt.parse(amount);
    return {
      'order': order, 'coin': atCoin, 'rests': '600000', 'filled': amount, 'gets': {'asset': y, 'amount': amount},
      'paid': (movedPrice != null && atCoin == 'coin-2') ? movedPrice : '${a * BigInt.two}',
      'fee': {'asset': x, 'amount': '300'}, 'change': '${BigInt.from(2000000) - a * BigInt.two - BigInt.from(500)}', 'remainder': null,
      'gives': ['c1'], 'served': {'order': order, 'expiry': 1790000000},
    };
  }

  Future<dynamic> run(String cmd, Map<String, dynamic> a) async {
    switch (cmd) {
      case 'info':
        return {'operator': operator};
      case 'coins':
        return [for (final c in coins) Map<String, dynamic>.from(c)];
      case 'plans':
        return {'plans': []};
      case 'sync':
        return {};
      case 'participations':
        return [for (final p in parts) Map<String, dynamic>.from(p)];
      case 'order_fill_resting_quote':
        if (refuse.contains(a['order'])) throw Exception('refused: the order is filled');
        final takes = BigInt.parse('${a['amount']}') * BigInt.two + BigInt.from(500);
        if (eligible != null && takes > eligible!) throw Exception('refused: the outputs take $takes of asset $x, more than the $eligible the inputs hold');
        return quote('${a['amount']}');
      case 'order_fill_resting':
        final shown = a['shown'] as Map;
        if (moved && shown['coin'] == 'coin-1') {
          moved = false;
          atCoin = 'coin-2';
          throw Exception('refused: order_moved');
        }
        shownCoin = '${shown['coin']}';
        coins[0]['state'] = 'spent';
        coins.add({'leaf_id': 'got', 'asset': y, 'value': '${a['amount']}', 'state': 'live', 'expiry': 1790000000});
        coins.add({'leaf_id': 'chg', 'asset': x, 'value': '${shown['change']}', 'state': 'live', 'expiry': 1790000000});
        return {'order': order, 'filled': a['amount'], 'paid': shown['paid'], 'answer': {'transfer_id': 'tr1', 'coins': []}};
      case 'settle_quote':
        expect(a['expiry'], 1790000000, reason: 'the coins it brings expire with the earliest of the order\'s and the wallet\'s');
        return {'asset': a['asset'], 'value': a['value'], 'fee': '3', 'after': '${BigInt.parse('${a['value']}') - BigInt.from(3)}'};
      case 'quote':
        return {'coins': [for (final l in a['leaves'] as List) {'leaf_id': l, 'fee': '3'}]};
      case 'participate':
        parts = [for (var i = 0; i < (a['leaves'] as List).length; i++) {'participation': 'p$i', 'state': 'pending'}];
        return {'participations': parts};
    }
    throw StateError('no command $cmd');
  }

  UserTradeEngine engine() => UserTradeEngine(UserTradeDeps(
        run: run,
        fetchJson: (url, {post}) async => <String, dynamic>{},
        makers: () => const [],
        relayBook: (_, _) async => book ?? [
          {
            'offer_asset': y, 'want_asset': x, '_verified': true, '_status': {'active_amount': '600000'},
            'resting_leaf': {'operator_key': op, 'order_id': order, 'asset_a': y, 'asset_b': x, 'rate_num': '2', 'rate_den': '1', 'min_lot': '10000', 'value': '600000'},
          }
        ],
        relayFills: (_, _) async => fills,
        admitted: () async => (
              pairs: {
                'chains': {
                  'g': {
                    'pairs': [
                      {'pay': x, 'receive': y, 'sources': ['leaf-resting']}
                    ]
                  }
                }
              },
              genesis: 'g'
            ),
        read: () async => stored,
        write: (v) async => stored = v,
        sleep: (_) async {},
      ));
}

void main() {
  test('a resting order filled from the library\'s quote, Settled once the relay and the round call it final', () async {
    final s = Resting();
    final e = s.engine();
    final q = await e.quote(pay: x, receive: y, amount: BigInt.from(400503));
    expect(q.ok, isTrue, reason: q.why);
    expect(q.ticket!.source, 'leaf-resting');
    final filled = BigInt.parse('${q.choice!.quote!['filled']}');
    expect(q.ticket!.amountIn, filled * BigInt.two + BigInt.from(503));
    expect(q.ticket!.amountOut, filled - BigInt.from(3));
    var r = await e.confirm(q.choice!, q.ticket!);
    expect(r['state'], 'sent');
    expect(r['transfer'], 'tr1');
    r = await e.advance((await e.records()).first);
    expect(r['settle'], isNotNull, reason: 'the coins it brought are asked into the next round');
    for (final p in s.parts) {
      p['state'] = 'released';
      p['new_leaves'] = [
        {'state': 'live'}
      ];
    }
    r = await e.advance((await e.records()).first);
    expect(r['state'], 'sent', reason: 'not Settled before the relay records the fill final');
    s.fills.add({'txid': 'tr1', 'state': 'final'});
    r = await e.advance((await e.records()).first);
    expect(r['state'], 'settled');
  });

  test('an order that moved is filled at its new coin only on the same terms', () async {
    final s = Resting(moved: true);
    final e = s.engine();
    final q = await e.quote(pay: x, receive: y, amount: BigInt.from(400503));
    final r = await e.confirm(q.choice!, q.ticket!);
    expect(r['state'], 'sent');
    expect(s.shownCoin, 'coin-2');
    final s2 = Resting(moved: true, movedPrice: '400002');
    final e2 = s2.engine();
    final q2 = await e2.quote(pay: x, receive: y, amount: BigInt.from(400503));
    await expectLater(e2.confirm(q2.choice!, q2.ticket!), throwsA(isA<LapsedError>()));
    expect(s2.coins[0]['state'], 'live');
  });

  test('a resting fill the wallet\'s eligible coins cannot pay in full is sized to what they hold', () async {
    final s = Resting()..eligible = BigInt.from(300000);
    final q = await s.engine().quote(pay: x, receive: y, amount: BigInt.from(400503));
    expect(q.ok, isTrue, reason: q.why);
    expect(q.ticket!.source, 'leaf-resting');
    final filled = BigInt.parse('${q.choice!.quote!['filled']}');
    expect(filled * BigInt.two + BigInt.from(500) <= BigInt.from(300000), isTrue, reason: 'the fill fits what the eligible coins hold');
    expect(filled > BigInt.from(100000), isTrue, reason: 'and is not sized down further than that');
  });

  test('orders that cannot be filled make way for the next one: the engine does not stop at three', () async {
    final s = Resting();
    final ids = [for (final h in ['01', '02', '03', '04']) h * 32];
    Map<String, dynamic> o(String id, String n) => {
          'offer_asset': y, 'want_asset': x, '_verified': true, '_status': {'active_amount': '600000'},
          'resting_leaf': {'operator_key': op, 'order_id': id, 'asset_a': y, 'asset_b': x, 'rate_num': n, 'rate_den': '10', 'min_lot': '10000', 'value': '600000'},
        };
    s.book = [for (final id in ids) o(id, '19'), o(order, '20')];
    s.refuse.addAll(ids);
    final q = await s.engine().quote(pay: x, receive: y, amount: BigInt.from(400503));
    expect(q.ok, isTrue, reason: q.why);
    expect(q.choice!.id, order);
  });

  test('an order of another operator is not offered', () async {
    final s = Resting()..operator = 'ef' * 32;
    final q = await s.engine().quote(pay: x, receive: y, amount: BigInt.from(400503));
    expect(q.why, 'not-offered');
  });
}
