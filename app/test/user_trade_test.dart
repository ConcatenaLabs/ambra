// The user-mode composer's engine (data/user_trade.dart) against a stand-in leaf library and
// maker, and its words against the word list. The same cases as the web wallet's
// user-trade.test.mjs.
import 'dart:convert';
import 'dart:io';

import 'package:ambra/src/data/user_trade.dart';
import 'package:flutter_test/flutter_test.dart';

final x = 'aa' * 32, y = 'bb' * 32;

String fmt(String a, BigInt n) => '$n ${a == x ? 'XT' : a == y ? 'YT' : 'BTC'}';

class StandIn {
  final coins = <Map<String, dynamic>>[
    {'leaf_id': 'c1', 'asset': x, 'value': '3000000', 'state': 'live', 'kind': 'board'}
  ];
  final swaps = <Map<String, dynamic>>[];
  final parts = <Map<String, dynamic>>[];
  final posts = <String>[];
  final firmGives = <String>[];
  List<Map<String, dynamic>>? quotes;
  List<String>? last;
  bool away = false;
  String? stored;

  Future<dynamic> run(String cmd, Map<String, dynamic> a) async {
    switch (cmd) {
      case 'coins':
        return [for (final c in coins) Map<String, dynamic>.from(c)];
      case 'plans':
        return {'plans': []};
      case 'swap_read':
        final p = '${a['offer']}'.split(':');
        return {
          'swap': 's1',
          'gets': {'asset': y, 'value': p[1]},
          'gives': {'asset': x, 'value': p[2]},
          'pays': {'asset': x, 'margins': '192'},
          'change': {'asset': x, 'value': '${3000000 - int.parse(p[2]) - 192}'},
          'dates': {'expiry': 1800000000},
        };
      case 'settle_quote':
        return {'asset': a['asset'], 'value': a['value'], 'fee': '3', 'after': '${int.parse('${a['value']}') - 3}'};
      case 'swap_accept':
        last = '${a['offer']}'.split(':');
        swaps.add({'swap': 's1', 'role': 'taker', 'state': 'accepted'});
        coins[0]['state'] = 'offered';
        return {'swap': 's1', 'accept': 'swap-accept:xyz'};
      case 'swaps':
        return [for (final s in swaps) Map<String, dynamic>.from(s)];
      case 'sync':
        return {};
      case 'quote':
        return {
          'coins': [for (final l in a['leaves'] as List) {'leaf_id': l, 'fee': '3'}]
        };
      case 'participate':
        parts.add({'participation': 'p${parts.length}', 'state': 'pending', 'new_leaves': [{'state': null}]});
        return {'participations': [parts.last]};
      case 'participations':
        return [for (final p in parts) Map<String, dynamic>.from(p)];
      case 'swap_cancel':
        swaps.firstWhere((s) => s['swap'] == a['swap'])['state'] = 'cancelled';
        coins[0]['state'] = 'live';
        return {'cancelled': true};
    }
    throw StateError('no command $cmd');
  }

  bool held = false;

  Future<Map<String, dynamic>> fetchJson(String url, {Map<String, dynamic>? post}) async {
    if (url.endsWith('/v1/quotes')) {
      return {
        'quotes': quotes ?? [
          {'give_asset': y, 'want_asset': x, 'rate_num': '4', 'rate_den': '3', 'max_give': '1000000', 'min_give': '10000'}
        ]
      };
    }
    posts.add(url.split('/v1/').last);
    // The maker holds its coin for an offer until the offer is released, a moment after it is
    // asked to, and refuses a second offer meanwhile, as the live maker does.
    if (url.endsWith('/v1/release')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      held = false;
      return {};
    }
    if (url.endsWith('/v1/firm')) {
      firmGives.add('${post!['give']}');
      if (held) throw Exception('the maker does not hold that much now');
      held = true;
      final give = BigInt.parse('${post['give']}');
      final want = (give * BigInt.from(4) + BigInt.two) ~/ BigInt.from(3);
      return {'swap': 's1', 'offer': 'swap-offer:$give:$want', 'give': '$give', 'want': '$want'};
    }
    if (url.endsWith('/v1/accept')) {
      if (away) throw Exception('the maker is away');
      swaps.firstWhere((s) => s['swap'] == 's1')['state'] = 'done';
      coins[0]['state'] = 'spent';
      coins.add({'leaf_id': 'got', 'asset': y, 'value': last![1], 'state': 'live', 'kind': 'transfer'});
      coins.add({'leaf_id': 'chg', 'asset': x, 'value': '${3000000 - int.parse(last![2]) - 192}', 'state': 'live', 'kind': 'transfer'});
      return {'state': 'done'};
    }
    return {};
  }

  UserTradeEngine engine({List<String> sources = const ['leaf-maker'], List<String> makers = const ['http://m'], required int Function() now}) =>
      UserTradeEngine(UserTradeDeps(
        run: run,
        fetchJson: fetchJson,
        makers: () => makers,
        relayBook: (_, _) async => [],
        admitted: () async => (
              pairs: {
                'chains': {
                  'g': {
                    'pairs': [
                      {'pay': x, 'receive': y, 'sources': sources}
                    ]
                  }
                }
              },
              genesis: 'g'
            ),
        read: () async => stored,
        write: (v) async => stored = v,
        now: now,
        sleep: (_) async {},
      ));
}

void main() {
  test('no string the user composer shows names a rail or developer word', () {
    for (final w in UserWords.all()) {
      expect(forbiddenIn(w), isEmpty, reason: w);
    }
    final src = File('lib/src/screens/user_composer.dart').readAsStringSync();
    // Every Text the composer draws is a UserWords entry or an amount, never a literal.
    final literals = RegExp(r"Text\('([^']+)'").allMatches(src).map((m) => m.group(1)).toList();
    expect(literals, isEmpty);
  });

  test('the word list catches rail words as words', () {
    expect(forbiddenIn('Paid from your leaves in the next round'), ['round', 'leaves']);
    expect(forbiddenIn('Surrounded, relayed'), isEmpty);
  });

  test('the cost line: every fee in its own asset, the asset paid first', () {
    expect(costLine([{'asset': x, 'atoms': '536'}], fmt, x), 'Fees 536 XT, included above');
    expect(costLine([{'asset': y, 'atoms': '12'}, {'asset': x, 'atoms': '536'}, {'asset': x, 'atoms': '4'}], fmt, x), 'Fees 540 XT and 12 YT, included above');
    expect(costLine([{'asset': x, 'atoms': '0'}], fmt, x), 'No fees');
  });

  test('both pickers list BTC first, then what is held, then the rest', () {
    final cc = 'cc' * 32;
    expect(pickerOrder([cc, y, x], (a) => a == y ? BigInt.from(5) : BigInt.zero, (a) => a), [kUserBtc, y, x, cc]);
  });

  test('sizing and the choice match the web wallet', () {
    final e = BookEntry(source: 'covenant-round', id: 'o', rateNum: BigInt.from(4), rateDen: BigInt.from(3), maxReceive: BigInt.from(600000),
        minReceive: BigInt.from(10000), lot: BigInt.from(10000), raw: {});
    expect(sizeEntry(e, BigInt.from(400000))!.receive, BigInt.from(300000));
    expect(sizeEntry(e, BigInt.from(795000))!.receive, BigInt.from(590000));
    expect(sizeEntry(e, BigInt.from(100)), isNull);
    Candidate c(String s, String id, int r) => Candidate(source: s, id: id, entry: e, receive: BigInt.from(r), give: BigInt.one, fees: const []);
    expect(chooseCandidate([c('leaf-maker', 'b', 300), c('covenant-round', 'z', 300), c('leaf-maker', 'a', 299)])!.source, 'covenant-round');
    expect(chooseCandidate([c('leaf-maker', 'b', 301), c('covenant-round', 'a', 300)])!.id, 'b');
  });

  test('a covenant order is sized from the relay\'s status of it, not its signed amount', () {
    final o = {
      'offer_asset': y, 'want_asset': x, 'offer_amount': '600000', '_verified': true, '_status': {'active_amount': '250000'},
      'covenant': {'covenant_txid': 'ab' * 32, 'covenant_vout': 1, 'rate_num': '4', 'rate_den': '3', 'min_lot': '10000'}
    };
    final es = covenantRoundEntries([o], pay: x, receive: y);
    expect(es.single.maxReceive, BigInt.from(250000));
    expect(covenantRoundEntries([{...o, 'confidential': true}], pay: x, receive: y), isEmpty);
  });

  test('a pair is offered only as the drill admitted it', () {
    final pairs = {
      'chains': {
        'g1': {
          'pairs': [
            {'pay': x, 'receive': y, 'sources': ['leaf-maker']}
          ]
        }
      }
    };
    expect(admittedSources(pairs, 'g1', x, y), ['leaf-maker']);
    expect(admittedSources(pairs, 'g2', x, y), isEmpty);
    expect(admittedReceives(pairs, 'g1', x), [y]);
  });

  test('engine: an in-tree trade from ticket to Settled', () async {
    final s = StandIn();
    var t = 0;
    final eng = s.engine(now: () => t += 1000);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: q.why);
    expect(q.ticket!.amountIn <= BigInt.from(400000), isTrue);
    expect(s.posts.contains('release'), isTrue);
    final rec = await eng.confirm(q.choice!, q.ticket!);
    expect(rec['state'], 'sent');
    var r = await eng.advance((await eng.records()).first);
    expect((r['settle'] as Map)['coins'], hasLength(2));
    for (final p in s.parts) {
      p['state'] = 'released';
      p['new_leaves'] = [{'state': 'live'}];
    }
    r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'settled');
    expect(jsonDecode(s.stored!), isA<List>());
  });

  test('engine: a maker that never completes: cancelled, the coin back, no action asked', () async {
    final s = StandIn()..away = true;
    var t = 0;
    final eng = s.engine(now: () => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(200000));
    await eng.confirm(q.choice!, q.ticket!);
    var r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'sent');
    t += 10 * 60 * 1000;
    r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'returned');
    expect(s.coins.first['state'], 'live');
  });

  test('engine: not listed, not offered, no funds', () async {
    final s = StandIn();
    expect((await s.engine(sources: const [], now: () => 0).quote(pay: x, receive: y, amount: BigInt.one)).why, 'not-listed');
    expect((await s.engine(makers: const [], now: () => 0).quote(pay: x, receive: y, amount: BigInt.from(400000))).why, 'not-offered');
    s.coins.first['state'] = 'spent';
    expect((await s.engine(now: () => 0).quote(pay: x, receive: y, amount: BigInt.from(400000))).why, 'no-funds');
  });

  test('engine: a maker quoting levels of one pair is asked for one firm offer, at the level that gives the most', () async {
    final s = StandIn()
      ..quotes = [
        {'give_asset': y, 'want_asset': x, 'rate_num': '4', 'rate_den': '3', 'max_give': '100000', 'min_give': '10000'},
        {'give_asset': y, 'want_asset': x, 'rate_num': '5', 'rate_den': '3', 'max_give': '1000000', 'min_give': '10000'},
        {'give_asset': y, 'want_asset': x, 'rate_num': '6', 'rate_den': '3', 'max_give': '2000000', 'min_give': '10000'},
      ];
    await s.engine(now: () => 0).quote(pay: x, receive: y, amount: BigInt.from(400000));
    // 400,000 at 5/3 gives 240,000, more than the first level's 100,000 cap or 200,000 at 6/3.
    expect(s.firmGives, ['240000'], reason: 'one firm offer, at the deeper level');
  });
}
