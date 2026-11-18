// A trade whose coins wait only for a round (the library's `settle_first`, or coins of the asset not
// live yet) settles them first and goes: never a refusal out of confirm. The same cases as the web
// wallet's settle-first.test.mjs and settle-first-once.test.mjs, as far as the app's engine has them.
import 'package:ambra/src/data/user_trade.dart';
import 'package:ambra/src/data/user_trade_btc.dart';
import 'package:flutter_test/flutter_test.dart';

final x = 'aa' * 32, y = 'bb' * 32;

/// The library's refusal as LeafService hands it on: its kind, words and figures.
class Refusal implements Exception {
  Refusal(this.kind, this.message, [this.fields = const {}]);
  final String kind, message;
  final Map<String, dynamic> fields;
  String? get code => fields['code'] as String?;
  @override
  String toString() => message;
}

Refusal settleFirst(List<String> coins) => Refusal('settle_first', 'refused: the wallet\'s coins of asset $x settle them first (settle_first)',
    {'coins': coins, 'final_in_seconds': 240, 'usual_in_seconds': 120, 'waiting_for': 'round'});

/// The wallet's one coin of X (`c1`) waits for a round: `swap_read` (at the quote, [deepAt] 'read'),
/// `swap_accept` ('accept'), or, as a wallet the faucet has just paid, `swap_accept` refused for want
/// of live coins ('live'). `settle_first` gives it up once and is ready after the next sync, which
/// gives the wallet `c2`.
class SettleStandIn {
  SettleStandIn({this.deepAt = 'read'});
  final String deepAt;
  int rateNum = 4;
  final coins = <Map<String, dynamic>>[
    {'leaf_id': 'c1', 'asset': x, 'value': '3000000', 'state': 'live', 'kind': 'transfer'},
  ];
  final swaps = <Map<String, dynamic>>[];
  final calls = <String>[];
  final settleAsks = <Map>[];
  final posts = <String>[];
  var given = false, synced = false, held = false;
  List<String>? last;
  String? stored;
  bool get deep => coins.any((c) => c['leaf_id'] == 'c1' && c['state'] != 'spent');

  Future<dynamic> run(String cmd, Map<String, dynamic> a) async {
    calls.add(cmd);
    switch (cmd) {
      case 'coins':
        return [for (final c in coins) Map<String, dynamic>.from(c)];
      case 'plans':
        return {'plans': []};
      case 'info':
        return {'server_info': {}};
      case 'swap_read':
        if (deepAt == 'read' && deep) throw settleFirst(['c1']);
        final p = '${a['offer']}'.split(':');
        return {
          'swap': 's1',
          'gets': {'asset': y, 'value': p[1]},
          'gives': {'asset': x, 'value': p[2]},
          'pays': {'asset': x, 'margins': '192'},
          'change': {'asset': x, 'value': '1000'},
          'dates': {'expiry': 1800000000},
        };
      case 'swap_accept':
        if (deep && deepAt == 'accept') throw settleFirst(['c1']);
        if (deep && deepAt == 'live') {
          throw Refusal('refused', 'refused: the wallet holds 0 of asset $x in live coins, and paying 400000 takes 400192 with the margins its transactions leave for their fees');
        }
        last = '${a['offer']}'.split(':');
        swaps.add({'swap': 's1', 'role': 'taker', 'state': 'accepted'});
        return {'swap': 's1', 'accept': 'swap-accept:xyz'};
      case 'swaps':
        return [for (final s in swaps) Map<String, dynamic>.from(s)];
      case 'settle_first':
        settleAsks.add(a);
        if (!given) {
          given = true;
          synced = false;
          coins[0]['state'] = 'given';
          return {'settling': ['c1'], 'ready': false, 'final_in_seconds': 240, 'usual_in_seconds': 120, 'waiting_for': 'round'};
        }
        if (!synced) return {'waiting': ['c1'], 'ready': false, 'final_in_seconds': 200, 'waiting_for': 'block'};
        return {'done': ['c1'], 'ready': true};
      case 'sync':
        if (given && coins[0]['state'] == 'given') {
          coins[0]['state'] = 'spent';
          coins.add({'leaf_id': 'c2', 'asset': x, 'value': '2999990', 'state': 'live', 'kind': 'leaf'});
        }
        synced = true;
        return {};
      case 'mailbox':
        return {};
      case 'settle_quote':
        return {'asset': a['asset'], 'value': a['value'], 'fee': '0', 'after': a['value']};
      case 'quote':
        return {
          'coins': [for (final l in a['leaves'] as List) {'leaf_id': l, 'fee': '0'}]
        };
    }
    throw StateError('no command $cmd');
  }

  Future<Map<String, dynamic>> fetchJson(String url, {Map<String, dynamic>? post}) async {
    if (url.endsWith('/v1/quotes')) {
      return {
        'quotes': [
          {'give_asset': y, 'want_asset': x, 'rate_num': '$rateNum', 'rate_den': '3', 'max_give': '1000000', 'min_give': '10000'}
        ]
      };
    }
    posts.add(url.split('/v1/').last);
    if (url.endsWith('/v1/firm')) {
      if (held) throw Exception('the maker does not hold that much now');
      held = true;
      final give = BigInt.parse('${post!['give']}');
      final want = (give * BigInt.from(rateNum) + BigInt.two) ~/ BigInt.from(3);
      return {'swap': 's1', 'offer': 'swap-offer:$give:$want', 'give': '$give', 'want': '$want'};
    }
    if (url.endsWith('/v1/release')) {
      held = false;
      return {};
    }
    if (url.endsWith('/v1/accept')) {
      held = false;
      swaps.firstWhere((s) => s['swap'] == 's1')['state'] = 'done';
      coins.add({'leaf_id': 'got', 'asset': y, 'value': last![1], 'state': 'live', 'kind': 'transfer'});
      return {'state': 'done'};
    }
    return {};
  }

  UserTradeEngine engine(int Function() now, {Future<BigInt> Function(String asset)? held}) => UserTradeEngine(UserTradeDeps(
        run: run,
        held: held,
        fetchJson: fetchJson,
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
        read: () async => stored,
        write: (v) async => stored = v,
        now: now,
        sleep: (_) async {},
      ));
}

/// Follows the trade as the Swap tab does, the clock moving 15 s between passes.
Future<Map<String, dynamic>> follow(UserTradeEngine eng, void Function() tick, {int passes = 8}) async {
  var r = (await eng.records()).first;
  for (var i = 0; i < passes && r['state'] == 'settling'; i++) {
    tick();
    r = await eng.advance((await eng.records()).first);
  }
  return r;
}

void main() {
  // Review RV93, F2: more than the balance shows, while every coin of the asset is in a round of the
  // wallet's own, is answered as web main does (part-ready, "That is more than your <amount>."),
  // never "not ready".
  test('F2: more than the balance is never answered "not ready"', () async {
    final s = SettleStandIn(deepAt: 'none');
    s.coins[0]['state'] = 'given';
    Future<BigInt> held(String a) async => a == x ? BigInt.from(3000000) : BigInt.zero;
    final more = await s.engine(() => 1000000, held: held).quote(pay: x, receive: y, amount: BigInt.from(4000000));
    expect(more.ok, isFalse);
    expect(more.why, isNot('not-ready'), reason: 'web main: part-ready');
    expect(UserWords.moreThanHeld('0.03 XT'), 'That is more than your 0.03 XT.');
    expect(UserWords.all(), contains(UserWords.moreThanHeld('1 XT')));
    expect(forbiddenIn(UserWords.moreThanHeld('1 XT')), isEmpty);
  });

  // The reliability run of 2026-11-18: twice Ambra mobile answered "Your USDX is on its way: it is
  // ready to trade in a minute or two" and moved nothing, while every coin of the asset was in a
  // round of the wallet's own (its refresh of coins received out of round). The web wallet answers
  // that with a ticket that settles first (D96); so does this engine now.
  test('every coin of the asset in a round of the wallet\'s own: a ticket that settles first, never a refusal', () async {
    final s = SettleStandIn(deepAt: 'none');
    s.coins[0]['state'] = 'given';
    var t = 1000000;
    Future<BigInt> held(String a) async => a == x ? BigInt.from(3000000) : BigInt.zero;
    final q = await s.engine(() => t, held: held).quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: 'not "on its way": ${q.why}');
    expect(q.ticket!.source, 'settling');
    expect(q.ticket!.indicative, isTrue);
    expect(s.settleAsks, isEmpty, reason: 'a price request gives nothing to a round');
    // More than the balance shows is not waited for.
    final s2 = SettleStandIn(deepAt: 'none');
    s2.coins[0]['state'] = 'given';
    final more = await s2.engine(() => t, held: held).quote(pay: x, receive: y, amount: BigInt.from(4000000));
    expect(more.ok, isFalse);
    expect([more.why, more.ready], ['part-ready', BigInt.from(3000000)], reason: 'more than the balance shows: "That is more than your …"');
  });

  test('a coin held by an order the person placed is said as that, never "on its way"', () async {
    final s = SettleStandIn(deepAt: 'none');
    s.coins[0]['state'] = 'offered';
    Future<BigInt> held(String a) async => a == x ? BigInt.from(3000000) : BigInt.zero;
    final q = await s.engine(() => 0, held: held).quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.why, 'busy');
    expect(UserWords.busy('USDX'), 'Your USDX is held by an order you placed, and can be traded once it is filled or cancelled. Nothing has moved.');
    expect(forbiddenIn(UserWords.busy('USDX')), isEmpty);
    expect(UserWords.all(), contains(UserWords.busy('XT')));
  });

  test('the words of settling first name no developer word, and promise no time until the wallet says one', () {
    for (final w in [UserWords.settling, UserWords.goesThrough(1), UserWords.goesThrough(6), UserWords.goesThroughLate, UserWords.atLeast('1 YT'), UserWords.returnedLate]) {
      expect(forbiddenIn(w), isEmpty, reason: w);
      expect(UserWords.all(), contains(w));
    }
    expect(UserWords.settling, isNot(contains('minute')));
    expect(tradeStateWord({'state': 'settling', 'at': 0}, 0), UserWords.settling);
    expect(tradeStateWord({'state': 'settling', 'at': 0, 'finalBy': 5 * 60000}, 0), UserWords.goesThrough(5));
    expect(tradeStateWord({'state': 'settling', 'at': 0, 'finalBy': 60000}, 60000 + kSettleLateMs + 1), UserWords.goesThroughLate);
    expect(tradeStateWord({'state': 'returned', 'whyKind': 'late'}, 0), UserWords.returnedLate);
    expect(settleBound(null), kSettleMostMs);
    expect(settleBound(600), 2 * 600000 + kSettleMarginMs);
  });

  test('a quote whose coins wait for a round is a ticket to accept now; the coins go into a round once it is accepted, and it goes once through', () async {
    final s = SettleStandIn(deepAt: 'read');
    var t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: 'never "nobody could confirm a price" for coins the balance shows: ${q.why}');
    expect(q.ticket!.indicative, isTrue);
    expect(q.ticket!.amountOut < q.ticket!.about!, isTrue, reason: 'the least it goes for is under the price now');
    expect(q.ticket!.finalBy, t + 120000, reason: 'the wait the library\'s refusal gave');
    expect(s.settleAsks, isEmpty, reason: 'a price request gives nothing to a round');
    expect(s.posts, contains('release'), reason: 'the maker\'s firm offer is let go of');
    final rec = await eng.confirm(q.choice!, q.ticket!);
    expect(rec['state'], 'settling');
    await Future<void>.delayed(Duration.zero);
    expect(s.settleAsks.first, {'coins': ['c1']}, reason: 'accepted: the coins the library named go into the next round');
    expect(tradeStateWord(rec, t), UserWords.goesThrough(2));
    final r = await follow(eng, () => t += 15000);
    expect(r['state'], isNot('settling'), reason: '$r');
    expect(['sent', 'settled'], contains(r['state']), reason: '$r');
    expect(r['id'], rec['id']);
    expect(await eng.records(), hasLength(1), reason: 'never made twice');
    expect(s.calls.lastIndexOf('sync') > s.calls.indexOf('settle_first'), isTrue, reason: 'the round is looked for before it is called through');
  });

  test('a confirmation answered settle_first keeps the trade, settles, and goes ahead by itself within the price accepted', () async {
    final s = SettleStandIn(deepAt: 'accept');
    var t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: q.why);
    final rec = await eng.confirm(q.choice!, q.ticket!);
    expect(rec['state'], 'settling', reason: 'never a refusal out of confirm');
    expect(rec['settleCoins'], ['c1']);
    expect(tradeStateWord(rec, t), UserWords.goesThrough(2));
    expect(s.posts.where((p) => p == 'release'), isNotEmpty, reason: 'the firm offer accepted is let go of while the coins settle');
    final r = await follow(eng, () => t += 15000);
    expect(['sent', 'settled'], contains(r['state']), reason: '$r');
    expect(r['id'], rec['id']);
    expect(await eng.records(), hasLength(1));
    expect(r['accepted'], q.ticket!.toJson(), reason: 'the price the person accepted is kept with it');
    expect(s.swaps, hasLength(1), reason: 'one acceptance');
  });

  test('a wallet the faucet has just paid: a confirmation refused for want of live coins settles first, then trades', () async {
    final s = SettleStandIn(deepAt: 'live');
    var t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: q.why);
    final rec = await eng.confirm(q.choice!, q.ticket!);
    expect(rec['state'], 'settling', reason: 'never thrown out of confirm: $rec');
    expect(tradeStateWord(rec, t), UserWords.settling, reason: 'no time until the wallet says one');
    await Future<void>.delayed(Duration.zero);
    expect(s.settleAsks.first, {'asset': x}, reason: 'the engine names no coins: the library settles what of the asset waits');
    final r = await follow(eng, () => t += 15000);
    expect(['sent', 'settled'], contains(r['state']), reason: '$r');
    expect(s.swaps, hasLength(1));
  });

  test('a settled-first trade whose price moved past the bound is returned, with words', () async {
    final s = SettleStandIn(deepAt: 'accept');
    var t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    await eng.confirm(q.choice!, q.ticket!);
    s.rateNum = 5; // a quarter more to pay for each Y
    final r = await follow(eng, () => t += 15000);
    expect(r['state'], 'returned', reason: '$r');
    expect(r['whyKind'], 'moved');
    expect(tradeStateWord(r, t), UserWords.returnedMoved);
    expect(s.swaps, isEmpty, reason: 'nothing was accepted at the moved price');
  });

  test('a trade that waits past its bound comes back, nothing traded', () async {
    final s = SettleStandIn(deepAt: 'accept');
    var t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    await eng.confirm(q.choice!, q.ticket!);
    s.synced = false;
    // The round never comes: the sync gives nothing.
    final r0 = (await eng.records()).first;
    t += settleBound(240) + 1;
    s.given = true;
    final r = await eng.advance(r0);
    expect(r['state'], 'returned', reason: '$r');
    expect(tradeStateWord(r, t), UserWords.returnedLate);
    expect(s.swaps, isEmpty);
  });

  test('an app closed while a trade settles first finds it again, and it completes once', () async {
    final s = SettleStandIn(deepAt: 'accept');
    var t = 1000000;
    final first = s.engine(() => t);
    final q = await first.quote(pay: x, receive: y, amount: BigInt.from(400000));
    final rec = await first.confirm(q.choice!, q.ticket!);
    expect(rec['state'], 'settling');
    final second = s.engine(() => t);
    var out = await second.resume();
    for (var i = 0; i < 8 && out.any((r) => r['state'] == 'settling'); i++) {
      t += 15000;
      out = await second.resume();
    }
    final recs = await second.records();
    expect(recs, hasLength(1), reason: 'never made twice');
    expect(['sent', 'settled'], contains(recs.first['state']), reason: '${recs.first}');
    expect(s.swaps, hasLength(1), reason: 'one acceptance');
  });
}
