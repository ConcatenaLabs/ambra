// The composer offers a covenant take only as far as the operator can fund its round now (the
// operator's `info` names a `fundable` figure per asset): smaller when it is short, passed over
// when no lot fits, unchanged when the operator does not say. The web wallet's operatorRoom().
import 'package:ambra/src/data/user_trade.dart';
import 'package:flutter_test/flutter_test.dart';

final x = 'aa' * 32, y = 'bb' * 32;

class StandIn {
  String? fundable;
  int infos = 0;
  final takes = <String>[];
  String? stored;

  Future<dynamic> run(String cmd, Map<String, dynamic> a) async {
    switch (cmd) {
      case 'coins':
        return [
          {'leaf_id': 'c1', 'asset': x, 'value': '3000000', 'state': 'live', 'kind': 'board'}
        ];
      case 'plans':
        return {'plans': []};
      case 'info':
        infos++;
        return {
          'operator': 'op',
          'server_info': {
            'assets': [
              {'asset': y, 'fundable': '1'},
              {'asset': x, if (fundable != null) 'fundable': fundable},
            ]
          }
        };
      case 'take_quote':
        takes.add('${a['amount']}');
        final r = BigInt.parse('${a['amount']}');
        final gives = (r * BigInt.from(4) + BigInt.two) ~/ BigInt.from(3);
        return {'filled': '$r', 'gives': '$gives', 'spends': '${gives + BigInt.from(50)}', 'fee': '50'};
    }
    throw StateError('no command $cmd');
  }
}

UserTradeEngine engine(StandIn s, {int Function()? now}) => UserTradeEngine(UserTradeDeps(
      run: s.run,
      fetchJson: (url, {post}) async => {},
      makers: () => const [],
      relayBook: (_, _) async => [
        {
          'offer_asset': y, 'want_asset': x, 'offer_amount': '600000', '_verified': true, '_status': {'active_amount': '600000'},
          'covenant': {'covenant_txid': 'ab' * 32, 'covenant_vout': 1, 'rate_num': '4', 'rate_den': '3', 'min_lot': '10000'}
        }
      ],
      admitted: () async => (
        pairs: {
          'chains': {
            'g': {
              'pairs': [
                {'pay': x, 'receive': y, 'sources': ['covenant-round']}
              ]
            }
          }
        },
        genesis: 'g',
      ),
      read: () async => s.stored,
      write: (v) async => s.stored = v,
      now: now,
    ));

void main() {
  test('a take the operator can fund in full is priced as asked', () async {
    final s = StandIn()..fundable = '5000000';
    final q = await engine(s).quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: q.why);
    expect(s.takes.first, '300000');
  });

  test('a take larger than the operator can fund is made smaller, to what it can pay the maker', () async {
    final s = StandIn()..fundable = '200000';
    final q = await engine(s).quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: q.why);
    expect(s.takes.first, '150000', reason: '200,000 of the asset paid buys 150,000 at 4/3');
    expect(q.ticket!.amountIn <= BigInt.from(200000 + 50), isTrue);
  });

  test('a take with no lot the operator can fund is not offered, and nothing is quoted of it', () async {
    final s = StandIn()..fundable = '1000';
    final q = await engine(s).quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isFalse);
    expect(s.takes, isEmpty);
  });

  test('an operator that names no figure changes nothing', () async {
    final s = StandIn();
    final q = await engine(s).quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: q.why);
    expect(s.takes.first, '300000');
  });

  test('the operator\'s figure is read again only after a few seconds', () async {
    var t = 1000000;
    final s = StandIn()..fundable = '5000000';
    final e = engine(s, now: () => t);
    expect(await e.operatorRoom(x), BigInt.from(5000000));
    s.fundable = '7';
    expect(await e.operatorRoom(x), BigInt.from(5000000));
    t += kInfoMs + 1;
    expect(await e.operatorRoom(x), BigInt.from(7));
    expect(s.infos, 2);
  });
}
