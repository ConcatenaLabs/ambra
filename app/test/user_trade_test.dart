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

  UserTradeEngine engine({List<String> sources = const ['leaf-maker'], List<String> makers = const ['http://m'], required int Function() now,
          Future<BigInt> Function(String)? held, void Function(String)? prepare, int? Function()? anchorDepth}) =>
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
        held: held,
        prepare: prepare,
        anchorDepth: anchorDepth,
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
    // Held (the balance shows it) but no coin can pay now: not ready, and the wallet is asked to
    // make it ready; held nowhere: none.
    final prepared = <String>[];
    final e = s.engine(now: () => 0, held: (a) async => a == x ? BigInt.from(500) : BigInt.zero, prepare: prepared.add);
    expect((await e.quote(pay: x, receive: y, amount: BigInt.from(400000))).why, 'not-ready');
    expect(prepared, [x]);
    final none = s.engine(now: () => 0, held: (_) async => BigInt.zero, prepare: prepared.add);
    expect((await none.quote(pay: x, receive: y, amount: BigInt.from(400000))).why, 'no-funds');
    expect(prepared, [x]);
    expect(UserWords.notReady('USDX'), 'Your USDX is not ready to trade yet: it is once the next Bitcoin blocks settle it. Nothing has moved.');
  });

  test('engine: at anchor depth 0 a coin not ready yet is on its way; one a reorganisation took back is being redone', () async {
    final s = StandIn();
    s.coins.first['state'] = 'pending';
    Future<BigInt> held(String a) async => a == x ? BigInt.from(500) : BigInt.zero;
    final q0 = await s.engine(now: () => 0, held: held, anchorDepth: () => 0).quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect([q0.why, q0.soon], ['not-ready', true]);
    expect(UserWords.notReady('USDX', q0.soon), 'Your USDX is on its way: it is ready to trade in a minute or two. Nothing has moved.');
    for (final d in <int? Function()?>[() => 2, () => null, null]) {
      final q = await s.engine(now: () => 0, held: held, anchorDepth: d).quote(pay: x, receive: y, amount: BigInt.from(400000));
      expect([q.why, q.soon], ['not-ready', false]);
    }
    s.coins.first['redoing'] = true;
    final r = await s.engine(now: () => 0, held: held, anchorDepth: () => 0).quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(r.why, 'redoing');
    expect(UserWords.redoing('USDX'),
        'Your USDX is being redone after a Bitcoin reorganisation: it is still yours, and ready to trade again once that settles. Nothing has moved.');
    for (final w in [UserWords.notReady('USDX', true), UserWords.freeing('GOLD', true), UserWords.redoing('USDX'), UserWords.receivedSoon]) {
      expect(forbiddenIn(w), isEmpty, reason: w);
    }
    final rec = {'source': 'leaf-maker', 'state': 'sent', 'sentAt': 0, 'swapState': 'done'};
    expect(tradeStateWord(rec, 30000, soon: true), UserWords.receivedSoon);
    expect(tradeStateWord(rec, 30000), UserWords.receivedSettling);
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

  test('estimate: the amount typed stays, the other follows the best price now, in both directions', () async {
    final s = StandIn();
    final e = s.engine(now: () => 0);
    // 4 XT buys 3 YT; the maker gives up to 1,000,000 YT and no less than 10,000.
    final a = await e.estimate(pay: x, receive: y, payAtoms: BigInt.from(400000));
    expect(a.ok, isTrue);
    expect(a.receive, BigInt.from(300000));
    expect(a.short, isNull);
    final b = await e.estimate(pay: x, receive: y, receiveAtoms: BigInt.from(300000));
    expect(b.pay, BigInt.from(400000));
    // More than the book fills: what it can, and how much that is.
    final c = await e.estimate(pay: x, receive: y, payAtoms: BigInt.from(4000000));
    expect(c.receive, BigInt.from(1000000));
    expect(c.short!.receive, BigInt.from(1000000));
    final d = await e.estimate(pay: x, receive: y, receiveAtoms: BigInt.from(2000000));
    expect(d.receive, BigInt.from(1000000));
    expect(d.short, isNotNull);
    expect((await e.estimate(pay: x, receive: y, payAtoms: BigInt.from(4))).why, 'too-small');
    // No firm offer is asked for, so the maker holds nothing for an estimate.
    expect(s.firmGives, isEmpty);
    expect((await s.engine(sources: const [], now: () => 0).estimate(pay: x, receive: y, payAtoms: BigInt.one)).why, 'not-listed');
    expect((await s.engine(makers: const [], now: () => 0).estimate(pay: x, receive: y, payAtoms: BigInt.one)).why, 'not-offered');
  });

  test('estimate: the book is read once every few seconds per pair', () async {
    final s = StandIn();
    var reads = 0;
    var t = 0;
    final e = UserTradeEngine(UserTradeDeps(
      run: s.run,
      fetchJson: (u, {post}) {
        if (u.endsWith('/v1/quotes')) reads++;
        return s.fetchJson(u, post: post);
      },
      makers: () => ['http://m'],
      relayBook: (_, _) async => [],
      admitted: () async => (pairs: {'chains': {'g': {'pairs': [{'pay': x, 'receive': y, 'sources': ['leaf-maker']}]}}}, genesis: 'g'),
      read: () async => null,
      write: (_) async {},
      now: () => t,
    ));
    await e.estimate(pay: x, receive: y, payAtoms: BigInt.from(400000));
    t += 3000;
    await e.estimate(pay: x, receive: y, payAtoms: BigInt.from(500000));
    expect(reads, 1);
    t += 9000;
    await e.estimate(pay: x, receive: y, payAtoms: BigInt.from(500000));
    expect(reads, 2);
  });

  test('offered: what the book offers for the asset paid now', () async {
    final s = StandIn();
    expect(await s.engine(now: () => 0).offered(x), [y]);
    expect(await s.engine(makers: const [], now: () => 0).offered(x), isEmpty);
    expect(await s.engine(now: () => 0).offered(y), isEmpty);
  });

  test('quote: a pay asset held only in coins a refresh plan keeps is freed in the next round', () async {
    final released = <String>[];
    final e = UserTradeEngine(UserTradeDeps(
      run: (cmd, _) async => switch (cmd) {
        'coins' => [
            {'leaf_id': 'k1', 'asset': x, 'value': '3000000', 'state': 'live'},
            {'leaf_id': 'k2', 'asset': x, 'value': '5', 'state': 'live'},
          ],
        'plans' => {
            'plans': [
              {'coin': 'k1', 'state': 'open'},
              {'coin': 'old', 'state': 'open', 'steps': [{'leaf_id': 'k2'}]},
              {'coin': 'k3', 'state': 'done'},
            ]
          },
        _ => {},
      },
      fetchJson: (u, {post}) async => {'quotes': []},
      makers: () => ['http://m'],
      relayBook: (_, _) async => [],
      admitted: () async => (pairs: {'chains': {'g': {'pairs': [{'pay': x, 'receive': y, 'sources': ['leaf-maker']}]}}}, genesis: 'g'),
      read: () async => null,
      write: (_) async {},
      held: (_) async => BigInt.from(3000005),
      release: (a, leaves) => released.addAll(leaves),
    ));
    expect((await e.quote(pay: x, receive: y, amount: BigInt.from(100))).why, 'freeing');
    expect(released, ['k1', 'k2']);
    expect(UserWords.freeing('USDX'), 'Your USDX is being made ready to trade: it is ready once the next Bitcoin blocks settle it. Nothing has moved.');
    expect(spendableFrom([{'leaf_id': 'k2', 'asset': x, 'value': '5', 'state': 'live'}], {'plans': [{'coin': 'old', 'state': 'open', 'steps': [{'leaf_id': 'k2'}]}]}), isEmpty);
  });
}
