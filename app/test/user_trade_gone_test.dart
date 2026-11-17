// A maker that answers "the offer is gone" (the operator refused its completion): the trade takes its
// coins back at once and is priced again for what the person accepted, going ahead in the same record
// only at that price or better, the maker's own offer made in its place taken first; otherwise it
// comes back with the words it has, and after three gone offers it comes back. The same cases as the
// web wallet's user-trade-gone.test.mjs.
import 'package:ambra/src/data/user_trade.dart';
import 'package:flutter_test/flutter_test.dart';

final x = 'aa' * 32, y = 'bb' * 32;

class GoneStandIn {
  GoneStandIn({this.again = 'same', this.always = false, this.respend = 0});

  /// 'same': the maker makes an offer in place of a gone one; 'worse': none, and it asks more after.
  final String again;
  final bool always;
  final int respend;
  final coins = <Map<String, dynamic>>[
    {'leaf_id': 'dead', 'asset': x, 'value': '3000000', 'state': 'live', 'kind': 'transfer'},
  ];
  final swaps = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  final posts = <(String, Map)>[];
  final made = <String, Map<String, dynamic>>{};
  var n = 0;
  var refused = false;
  /// A maker that quotes nothing for a while (reading its coins again after a trade).
  var silent = false;
  String? stored;

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
        final p = '${a['offer']}'.split(':');
        return {
          'swap': p[1],
          'gets': {'asset': y, 'value': p[2]},
          'gives': {'asset': x, 'value': p[3]},
          'pays': {'asset': x, 'margins': '192'},
          'change': {'asset': x, 'value': '1000'},
          'dates': {'expiry': 1800000000},
        };
      case 'settle_quote':
        return {'asset': a['asset'], 'value': a['value'], 'fee': '3', 'after': '${int.parse('${a['value']}') - 3}'};
      case 'swap_accept':
        final id = '${a['offer']}'.split(':')[1];
        swaps[id] = {'swap': id, 'role': 'taker', 'state': 'accepted'};
        final c = coins.firstWhere((x) => x['state'] == 'live');
        c['state'] = 'offered';
        c['note'] = 'swap $id';
        return {'swap': id, 'accept': 'swap-accept:$id'};
      case 'swaps':
        return [for (final s in swaps.values) Map<String, dynamic>.from(s)];
      case 'sync':
      case 'mailbox':
        return {};
      case 'swap_cancel':
        swaps[a['swap']]!['state'] = 'cancelled';
        final d = coins.firstWhere((x) => x['note'] == 'swap ${a['swap']}');
        d['state'] = 'spent';
        if (respend > 0) {
          coins.add({'leaf_id': 'self${++n}', 'asset': x, 'value': '${int.parse('${d['value']}') - respend}', 'state': 'live', 'kind': 'transfer'});
          return {'swap': a['swap'], 'cancelled': true, 'respent': [d['leaf_id']]};
        }
        coins.add({'leaf_id': 'round${++n}', 'asset': x, 'value': '3000000', 'state': 'live', 'kind': 'batch'});
        return {'swap': a['swap'], 'cancelled': true, 'spent_elsewhere': [d['leaf_id']]};
      case 'quote':
        return {
          'coins': [for (final l in a['leaves'] as List) {'leaf_id': l, 'fee': '3'}]
        };
      case 'participate':
        return {'participations': [{'participation': 'p${++n}'}]};
      case 'participations':
        return [];
    }
    throw StateError('no command $cmd');
  }

  Map<String, dynamic> offer(String give, int rn) {
    final id = 'o${++n}';
    final want = (BigInt.parse(give) * BigInt.from(rn) + BigInt.two) ~/ BigInt.from(3);
    final o = {'swap': id, 'offer': 'swap-offer:$id:$give:$want', 'give': give, 'want': '$want', 'expires_at': 4102444800};
    made[id] = o;
    return o;
  }

  Future<Map<String, dynamic>> fetchJson(String url, {Map<String, dynamic>? post}) async {
    if (url.endsWith('/v1/quotes')) {
      if (silent) return {'quotes': []};
      return {
        'quotes': [
          {'give_asset': y, 'want_asset': x, 'rate_num': '4', 'rate_den': '3', 'max_give': '1000000', 'min_give': '10000'}
        ]
      };
    }
    final b = post ?? const {};
    posts.add((url.split('/v1/').last, b));
    if (url.endsWith('/v1/firm')) {
      final firms = posts.where((p) => p.$1 == 'firm').length;
      return offer('${b['give']}', firms > 1 && again == 'worse' ? 5 : 4);
    }
    if (url.endsWith('/v1/release')) return {};
    if (url.endsWith('/v1/accept')) {
      final s = swaps[b['swap']]!;
      if (!refused || s['gone'] != null || always) {
        refused = true;
        s['gone'] ??= {
          'error': 'refused: the operator refused the swap\'s completion (409 double_spend); the offer is withdrawn',
          'swap': b['swap'],
          'gone': true,
          'code': 'double_spend',
          'whose': 'taker',
          if (again == 'same') 'offer': offer('${made[b['swap']]!['give']}', 4),
        };
        throw MakerError('${(s['gone'] as Map)['error']}', s['gone'] as Map);
      }
      s['state'] = 'done';
      coins.firstWhere((c) => c['note'] == 'swap ${b['swap']}')['state'] = 'spent';
      coins.add({'leaf_id': 'got-${b['swap']}', 'asset': y, 'value': '1', 'state': 'live', 'kind': 'transfer'});
      return {'swap': b['swap'], 'state': 'done'};
    }
    return {};
  }

  UserTradeEngine engine(int Function() now) => UserTradeEngine(UserTradeDeps(
        run: run,
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

void main() {
  test('a gone offer: the coins come back at once and the maker\'s offer made in its place completes the trade in the same record', () async {
    final s = GoneStandIn();
    const t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect(q.ok, isTrue, reason: q.why);
    final rec = await eng.confirm(q.choice!, q.ticket!);
    expect(rec['state'], 'sent');
    expect((rec['gone'] as Map)['whose'], 'taker', reason: 'the first hand-over\'s answer is read');
    final firms = s.posts.where((p) => p.$1 == 'firm').length;
    final r = await eng.advance((await eng.records()).first);
    expect(s.calls, contains('swap_cancel'), reason: 'the dead acceptance is cancelled at once, the clock standing still');
    expect(s.posts.where((p) => p.$1 == 'firm').length, firms, reason: 'the offer made in its place is taken, no new one asked');
    expect(await eng.records(), hasLength(1), reason: 'one record: the trade is never made twice');
    expect(r['id'], rec['id']);
    expect(r['swap'], isNot(rec['swap']));
    expect([for (final g in r['gave'] as List) (g as Map)['swap']], [rec['swap']]);
    final rt = r['ticket'] as Map;
    expect(BigInt.parse('${rt['amountOut']}') >= q.ticket!.amountOut && BigInt.parse('${rt['amountIn']}') <= q.ticket!.amountIn, isTrue,
        reason: 'no worse than the ticket');
    expect(tradeStateWord(r, t), UserWords.sent);
    final done = await eng.advance((await eng.records()).first);
    expect(done['state'], isNot('returned'));
    expect(s.swaps.values.where((x) => x['state'] == 'done'), hasLength(1), reason: 'exactly one swap done');
  });

  test('a gone offer with no offer in its place, and the maker now asking more: returned with words, at once', () async {
    final s = GoneStandIn(again: 'worse');
    const t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    final rec = await eng.confirm(q.choice!, q.ticket!);
    final r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'returned', reason: '$r');
    expect(r['whyKind'], 'moved');
    expect(tradeStateWord(r, t), UserWords.returnedMoved);
    expect(s.swaps.values.where((x) => x['state'] == 'done'), isEmpty, reason: 'nothing traded');
    expect(s.posts.any((p) => p.$1 == 'accept' && p.$2['swap'] != rec['swap']), isFalse, reason: 'no other offer was accepted');
  });

  test('a maker whose offers are gone again and again: the trade comes back after three, never asking on and on', () async {
    final s = GoneStandIn(always: true);
    const t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    await eng.confirm(q.choice!, q.ticket!);
    Map<String, dynamic>? r;
    for (var i = 0; i < 6; i++) {
      r = await eng.advance((await eng.records()).first);
    }
    expect(r!['state'], 'returned', reason: '$r');
    expect(r['gave'], hasLength(kGoneMost));
    expect(r['whyKind'], isNot('moved'), reason: 'not said as a price that moved: it may not have');
    expect(s.swaps.values.where((x) => x['state'] == 'done'), isEmpty);
    expect(s.posts.any((p) => p.$1 == 'release'), isTrue, reason: 'the last offer made in place of a gone one is let go of');
  });

  test('a gone offer whose cancel respent the coins: the re-priced trade counts the respend\'s margins in what it paid and in its fees', () async {
    final s = GoneStandIn(respend: 500);
    const t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    await eng.confirm(q.choice!, q.ticket!);
    final r = await eng.advance((await eng.records()).first);
    expect(r['cancelFees'], '500');
    BigInt feesOf(List fs) => fs.where((f) => (f as Map)['asset'] == x).fold(BigInt.zero, (n, f) => n + BigInt.parse('${(f as Map)['atoms']}'));
    final rt = r['ticket'] as Map;
    expect(feesOf(rt['fees'] as List), feesOf(q.ticket!.toJson()['fees'] as List) + BigInt.from(500));
    expect(BigInt.parse('${rt['amountIn']}'), BigInt.parse('${(r['accepted'] as Map)['amountIn']}') + BigInt.from(500));
  });

  test('a step refused for a coin spent elsewhere is priced again in the same record, never failed', () async {
    final s = GoneStandIn();
    s.refused = true;
    const t = 1000000;
    final eng = s.engine(() => t);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    // The coin the acceptance pays from was given to a round by another device of the wallet.
    final real = s.run;
    var first = true;
    final eng2 = UserTradeEngine(UserTradeDeps(
      run: (cmd, a) async {
        if (cmd == 'swap_accept' && first) {
          first = false;
          s.coins.first['state'] = 'spent';
          s.coins.add({'leaf_id': 'fresh', 'asset': x, 'value': '3000000', 'state': 'live', 'kind': 'batch'});
          throw Exception('refused: double_spend: leaf ${'d' * 64} is already spent');
        }
        return real(cmd, a);
      },
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
      read: () async => s.stored,
      write: (v) async => s.stored = v,
      now: () => t,
      sleep: (_) async {},
    ));
    s.coins.first['leaf_id'] = 'd' * 64;
    final rec = await eng2.confirm(q.choice!, q.ticket!);
    expect(rec['state'], 'repricing', reason: '$rec');
    expect(rec['gave'], hasLength(1));
    expect(tradeStateWord(rec, t), UserWords.sent);
    final r = await eng2.advance((await eng2.records()).first);
    expect(r['id'], rec['id']);
    expect(['sent', 'settled'], contains(r['state']), reason: '$r');
    expect(await eng.records(), hasLength(1));
    expect(spentElsewhere(Exception('double_spend: leaf ${'e' * 64}'), ['d' * 64]), isFalse, reason: 'only a coin the wallet held');
  });

  test('a pair offered a moment ago that nobody offers now is asked again, not called not offered', () async {
    final s = GoneStandIn();
    var t = 1000000;
    final eng = s.engine(() => t);
    expect((await eng.estimate(pay: x, receive: y, payAtoms: BigInt.from(400000))).ok, isTrue);
    s.silent = true;
    t += 9000;
    final e = await eng.estimate(pay: x, receive: y, payAtoms: BigInt.from(400000));
    expect([e.why, e.again], ['not-offered', true]);
    final q = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect([q.why, q.again], ['not-offered', true]);
    t += kOfferedAgainMs;
    final late = await eng.quote(pay: x, receive: y, amount: BigInt.from(400000));
    expect([late.why, late.again], ['not-offered', false], reason: 'past the window: the last answer stands');
    expect(forbiddenIn(UserWords.offeredAgain('YT', 'XT')), isEmpty);
  });
}
