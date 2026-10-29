// The user composer's BTC trades (data/user_trade_btc.dart through data/user_trade.dart) against
// stand-ins of the leaf library, a maker's BTC desk and a Bitcoin Lightning wallet: the order of the
// one hash-lock, and what a ticket counts. The same cases as the web wallet's user-trade-btc.test.mjs.
import 'dart:convert';

import 'package:ambra/src/data/btc_lightning.dart';
import 'package:ambra/src/data/user_trade.dart';
import 'package:ambra/src/data/user_trade_btc.dart';
import 'package:flutter_test/flutter_test.dart';

final x = 'aa' * 32;
final h = 'cd' * 32, p = 'ef' * 32;

class FakeBtc implements BtcLightning {
  FakeBtc(this.s);
  final StandIn s;
  @override
  Future<BigInt> balance() async => BigInt.from(500000);
  @override
  Future<Map<String, dynamic>> invoice({required BigInt sats, String description = 'trade'}) async {
    s.invoices[h] = {'sats': sats, 'status': 'unpaid'};
    return {'invoice': 'lnbcrt-wallet', 'payment_hash': h, 'expires_at': 4000000000};
  }

  @override
  Future<Map<String, dynamic>> decode(String invoice) async => invoice == 'lnbcrt-maker-2'
      ? {'sats': s.makerSats ?? s.lastWant, 'payment_hash': s.renew == 'other-hash' ? 'ab' * 32 : h, 'expires_at': 4000000000, 'min_final_cltv': 18}
      : {'sats': s.makerSats ?? s.lastWant, 'payment_hash': h, 'expires_at': s.expired ? DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60 : 4000000000, 'min_final_cltv': 18};
  @override
  Future<Map<String, dynamic>> invoiceStatus(String hash) async =>
      s.invoices[hash]?['status'] == 'paid' ? {'status': 'paid', 'preimage': p} : {'status': 'unpaid'};
  @override
  Future<void> cancelInvoice(String hash) async {}
  @override
  Future<Map<String, dynamic>> pay({required String invoice, BigInt? maxFeeSats, int? maxDelay}) async {
    s.btcPaid.add(invoice);
    s.maxDelay = maxDelay;
    return {'state': 'complete', 'preimage': p};
  }

  @override
  Future<Map<String, dynamic>> payStatus(String hash) async => s.btcPaid.isNotEmpty ? {'state': 'complete', 'preimage': p} : {'state': 'none'};
  @override
  Future<({BigInt fee, int delay})?> payRoute(String invoice) async => s.route;
}

class StandIn {
  final coins = <Map<String, dynamic>>[
    {'leaf_id': 'c1', 'asset': x, 'value': '1000000', 'state': 'live'}
  ];
  final posts = <List<dynamic>>[];
  final receives = <String, Map<String, dynamic>>{};
  final pays = <String, Map<String, dynamic>>{};
  final invoices = <String, Map<String, dynamic>>{};
  final btcPaid = <String>[];
  var parts = <Map<String, dynamic>>[];
  bool ready = false;
  String? want, posted, claimed, stored;
  BigInt? makerSats, lastWant;
  int? maxDelay, needAsked;
  ({BigInt fee, int delay})? route;
  bool refuseLock = false;
  bool expired = false;
  String? renew;
  int locks = 0;

  Future<dynamic> run(String cmd, Map<String, dynamic> a) async {
    switch (cmd) {
      case 'coins':
        return coins;
      case 'plans':
        return {'plans': []};
      case 'sync':
        return {};
      case 'participations':
        return parts;
      case 'lightning_pay_quote':
        return {'payment_hash': h, 'asset': x, 'amount': want, 'fee': '200', 'margins': '480', 'spends': '${BigInt.parse(want!) + BigInt.from(680)}'};
      case 'lightning_pay':
        pays[h] = {'state': 'paying'};
        coins[0]['state'] = 'spent';
        return {'change': '799320'};
      case 'lightning_payments':
        return pays;
      case 'lightning_post_preimage':
        posted = '${a['preimage']}';
        return {};
      case 'lightning_receive_quote':
        final n = BigInt.parse('${a['amount']}');
        return {'asset': x, 'amount': a['amount'], 'fee': '200', 'value': '${n - BigInt.from(200)}', 'claim_margins': '416', 'claimed': '${n - BigInt.from(616)}'};
      case 'settle_quote':
        final v = BigInt.parse('${a['value']}');
        return {'asset': x, 'value': a['value'], 'fee': '3', 'after': '${v - BigInt.from(3)}'};
      case 'lightning_receive':
        receives['${a['hash']}'] = {'state': 'waiting'};
        return {'invoice': 'lnsqrt-x', 'fee': '200', 'value': '${BigInt.parse('${a['amount']}') - BigInt.from(200)}'};
      case 'lightning_receives':
        return receives;
      case 'lightning_receive_ready':
        needAsked = a['need_seconds'] as int;
        return ready ? {'ready': true} : {'ready': false, 'why': 'the received leaf\'s round is not final'};
      case 'lightning_receive_preimage':
        receives['${a['hash']}']!['preimage'] = a['preimage'];
        receives['${a['hash']}']!['state'] = 'received';
        coins.add({'leaf_id': 'r1', 'asset': x, 'value': claimed, 'state': 'live'});
        return {};
      case 'quote':
        return {
          'coins': [for (final l in a['leaves'] as List) {'leaf_id': l, 'fee': '3'}]
        };
      case 'participate':
        parts = [
          for (var i = 0; i < (a['leaves'] as List).length; i++) {'participation': 'p$i', 'state': 'pending'}
        ];
        return {'participations': parts};
    }
    throw StateError('no command $cmd');
  }

  Future<Map<String, dynamic>> fetchJson(String url, {Map<String, dynamic>? post}) async {
    if (url.endsWith('/v1/quotes')) {
      return {
        'quotes': [
          {'give_asset': 'BTC', 'want_asset': x, 'rate_num': '2', 'rate_den': '1', 'min_give': '1000', 'max_give': '1000000'},
          {'give_asset': x, 'want_asset': 'BTC', 'rate_num': '1', 'rate_den': '2', 'min_give': '1000', 'max_give': '1000000'},
        ]
      };
    }
    posts.add([url.split('/v1/btc/').last, post]);
    if (url.endsWith('/v1/btc/invoice')) {
      if (renew == null) throw Exception('404 no such path');
      return {'swap': post!['swap'], 'invoice': 'lnbcrt-maker-2'};
    }
    if (url.endsWith('/v1/btc/lock')) {
      locks++;
      if (refuseLock) {
        refuseLock = false;
        throw Exception('refused: the payment\'s spends changed since it was shown');
      }
    }
    if (url.endsWith('/v1/btc/firm')) {
      final give = BigInt.parse('${post!['give']}');
      if (post['give_asset'] == 'BTC') {
        want = '${give * BigInt.two}';
        return {'swap': 's1', 'invoice': 'lnsqrt-x', 'give': post['give'], 'want': want, 'expires_at': 4000000000};
      }
      lastWant = (give + BigInt.one) ~/ BigInt.two;
      return {'swap': 's2', 'invoice': 'lnbcrt-maker', 'give': post['give'], 'want': '$lastWant', 'expires_at': 4000000000};
    }
    return {};
  }
}

UserTradeEngine engine(StandIn s, String pay, String receive, {bool btc = true}) {
  final fb = FakeBtc(s);
  return UserTradeEngine(UserTradeDeps(
    run: s.run,
    fetchJson: s.fetchJson,
    makers: () => ['http://m'],
    relayBook: (_, _) async => const [],
    admitted: () async => (
      pairs: {
        'chains': {
          'g': {
            'pairs': [
              {'pay': pay, 'receive': receive, 'sources': ['btc-gateway']}
            ]
          }
        }
      },
      genesis: 'g',
    ),
    read: () async => s.stored,
    write: (v) async => s.stored = v,
    btc: () => btc ? fb : null,
  ));
}

/// A [FakeBtc] that notes which rail paid.
class RailBtc extends FakeBtc {
  RailBtc(super.s, this.name, this.paidOn);
  final String name;
  final List<String> paidOn;
  @override
  Future<Map<String, dynamic>> pay({required String invoice, BigInt? maxFeeSats, int? maxDelay}) {
    paidOn.add(name);
    return super.pay(invoice: invoice, maxFeeSats: maxFeeSats, maxDelay: maxDelay);
  }
}

/// An engine whose BTC has two rails, `ark` and `lightning`: [now] picks the one new trades take,
/// and [arkOpen] whether the ark is there.
({UserTradeEngine eng, List<String> paidOn, void Function(String) use, void Function(bool) ark}) railEngine(StandIn s, String pay, String receive) {
  final paidOn = <String>[];
  final rails = {'ark': RailBtc(s, 'ark', paidOn), 'lightning': RailBtc(s, 'lightning', paidOn)};
  var now = 'ark';
  var arkOpen = true;
  BtcLightning? on(String r) => r == 'ark' && !arkOpen ? null : rails[r];
  final eng = UserTradeEngine(UserTradeDeps(
    run: s.run,
    fetchJson: s.fetchJson,
    makers: () => ['http://m'],
    relayBook: (_, _) async => const [],
    admitted: () async => (
      pairs: {
        'chains': {
          'g': {
            'pairs': [
              {'pay': pay, 'receive': receive, 'sources': ['btc-gateway']}
            ]
          }
        }
      },
      genesis: 'g',
    ),
    read: () async => s.stored,
    write: (v) async => s.stored = v,
    btc: () => on(now),
    btcRail: () => now,
    btcOf: on,
  ));
  return (eng: eng, paidOn: paidOn, use: (r) => now = r, ark: (o) => arkOpen = o);
}

void main() {
  test('selling for BTC: the wallet\'s hash, its leaf pays first, and the preimage goes to the operator once the BTC came', () async {
    final s = StandIn();
    final eng = engine(s, x, 'BTC');
    final q = await eng.quote(pay: x, receive: 'BTC', amount: BigInt.from(200680));
    expect(q.ok, isTrue, reason: q.why);
    expect(q.ticket!.source, 'btc-gateway');
    // 100,340 sat would take 200,680 and 680 of fees: sized down to fit what is paid.
    expect(q.ticket!.amountIn, BigInt.from(200678));
    expect(q.ticket!.amountOut, BigInt.from(99999));
    expect(s.posts.any((e) => e[0] == 'release'), isTrue, reason: 'the firm offer that did not fit is released');
    expect(q.ticket!.toJson()['fees'], [
      {'asset': x, 'atoms': '680'}
    ]);
    final firm = s.posts.lastWhere((e) => e[0] == 'firm')[1] as Map;
    expect(firm['invoice'], 'lnbcrt-wallet', reason: 'the maker receives under the wallet\'s own hash');
    var r = await eng.confirm(q.choice!, q.ticket!);
    expect(r['state'], 'sent');
    r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'sent', reason: 'nothing settled before the BTC comes');
    s.invoices[h]!['status'] = 'paid';
    r = await eng.advance((await eng.records()).first);
    expect(s.posted, p, reason: 'the preimage is handed to the operator');
    expect(r['state'], 'sent');
    s.pays[h]!['state'] = 'paid';
    r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'settled');
  });

  test('buying with BTC: the maker\'s hash, its leaf first, and the BTC paid only once the wallet\'s leaf is held for good', () async {
    final s = StandIn()
      ..makerSats = BigInt.from(50000)
      ..claimed = '${100000 - 616}';
    final eng = engine(s, 'BTC', x);
    final q = await eng.quote(pay: 'BTC', receive: x, amount: BigInt.from(50000));
    expect(q.ok, isTrue, reason: q.why);
    expect(q.ticket!.amountIn, BigInt.from(50000));
    expect(q.ticket!.amountOut, BigInt.from(100000 - 616 - 3));
    expect(q.ticket!.toJson()['fees'], [
      {'asset': x, 'atoms': '619'}
    ]);
    var r = await eng.confirm(q.choice!, q.ticket!);
    expect(r['state'], 'waiting', reason: 'nothing of the wallet\'s has left yet');
    expect(s.posts.any((e) => e[0] == 'lock' && (e[1] as Map)['invoice'] == 'lnsqrt-x'), isTrue, reason: 'the maker is asked to lock first');
    s.receives[h]!['state'] = 'issuing';
    r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'waiting');
    expect(s.btcPaid, isEmpty, reason: 'no BTC before the leaf is final');
    expect(s.needAsked, needSeconds(18));
    s.ready = true;
    r = await eng.advance((await eng.records()).first);
    expect(s.btcPaid.length, 1);
    expect(s.maxDelay, 18 + kExtraBlocks);
    expect(r['preimage'], p);
    r = await eng.advance((await eng.records()).first);
    expect(r['settle'], isNotNull, reason: 'the claimed coin goes into the next round');
    for (final pt in s.parts) {
      pt['state'] = 'released';
      pt['new_leaves'] = [
        {'state': 'live'}
      ];
    }
    r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'settled');
  });

  test('buying with BTC through another node: the route\'s fee on the ticket, its whole lock bounds the payment and the leaf', () async {
    final s = StandIn()
      ..claimed = '${99999 - 616}'
      ..route = (fee: BigInt.from(2), delay: 52);
    final eng = engine(s, 'BTC', x);
    final q = await eng.quote(pay: 'BTC', receive: x, amount: BigInt.from(50002));
    expect(q.ok, isTrue, reason: q.why);
    // 100,004 X would want 50,002 sat and 2 of fee: sized down so both fit what is paid.
    expect(q.ticket!.amountIn, BigInt.from(50002), reason: 'the BTC and its routing fee');
    expect(q.ticket!.amountOut, BigInt.from(99999 - 616 - 3));
    expect(q.ticket!.toJson()['fees'], [
      {'asset': 'BTC', 'atoms': '2'},
      {'asset': x, 'atoms': '619'}
    ]);
    await eng.confirm(q.choice!, q.ticket!);
    s.receives[h]!['state'] = 'issuing';
    s.ready = true;
    await eng.advance((await eng.records()).first);
    expect(s.needAsked, needSeconds(52));
    expect(s.maxDelay, 52 + kExtraBlocks);
  });

  test('buying with BTC: a maker that never locks leaves nothing moved', () async {
    final s = StandIn()..makerSats = BigInt.from(50000);
    final eng = engine(s, 'BTC', x);
    final q = await eng.quote(pay: 'BTC', receive: x, amount: BigInt.from(50000));
    await eng.confirm(q.choice!, q.ticket!);
    s.receives[h]!['state'] = 'failed';
    final r = await eng.advance((await eng.records()).first);
    expect(r['state'], 'returned');
    expect(s.btcPaid, isEmpty);
  });

  test('a wallet with no Bitcoin Lightning is offered no BTC trade', () async {
    final s = StandIn();
    expect((await engine(s, 'BTC', x, btc: false).quote(pay: 'BTC', receive: x, amount: BigInt.from(50000))).why, 'no-funds');
    expect((await engine(s, x, 'BTC', btc: false).quote(pay: x, receive: 'BTC', amount: BigInt.from(50000))).why, 'not-offered');
  });

  test('buying with BTC: a maker that refuses to lock at first leaves the trade under way, not returned', () async {
    final s = StandIn()
      ..makerSats = BigInt.from(50000)
      ..claimed = '${100000 - 616}'
      ..refuseLock = true;
    final eng = engine(s, 'BTC', x);
    final q = await eng.quote(pay: 'BTC', receive: x, amount: BigInt.from(50000));
    final r = await eng.confirm(q.choice!, q.ticket!);
    expect(r['state'], 'waiting', reason: 'the receive is asked: the trade is under way');
    await eng.advance((await eng.records()).first);
    expect(s.locks, 2, reason: 'the lock is asked for again as the trade is followed');
    expect(jsonDecode(s.stored!), isA<List>());
  });

  test('a BTC trade is finished on the rail it was priced on, whatever new trades take by then', () async {
    final s = StandIn()
      ..makerSats = BigInt.from(50000)
      ..claimed = '${100000 - 616}';
    final r0 = railEngine(s, 'BTC', x);
    final q = await r0.eng.quote(pay: 'BTC', receive: x, amount: BigInt.from(50000));
    expect(q.ok, isTrue, reason: q.why);
    var r = await r0.eng.confirm(q.choice!, q.ticket!);
    expect(r['btcRail'], 'ark');
    // Developer mode turned on: new trades take the hosted node; this one stays on the ark.
    r0.use('lightning');
    s.receives[h]!['state'] = 'issuing';
    s.ready = true;
    // The ark not open yet (the app just started): the trade waits, nothing is paid elsewhere.
    r0.ark(false);
    r = await r0.eng.advance((await r0.eng.records()).first);
    expect(r['state'], 'waiting');
    expect(r0.paidOn, isEmpty);
    r0.ark(true);
    r = await r0.eng.advance((await r0.eng.records()).first);
    expect(r0.paidOn, ['ark']);
    expect(r['preimage'], p);
  });

  test('selling for BTC on the ark: the ark\'s invoice is the one the maker pays, and its claim settles it', () async {
    final s = StandIn();
    final r0 = railEngine(s, x, 'BTC');
    final q = await r0.eng.quote(pay: x, receive: 'BTC', amount: BigInt.from(200680));
    expect(q.ok, isTrue, reason: q.why);
    var r = await r0.eng.confirm(q.choice!, q.ticket!);
    expect(r['btcRail'], 'ark');
    expect(r['state'], 'sent');
    r0.use('lightning');
    s.invoices[h]!['status'] = 'paid';
    r = await r0.eng.advance((await r0.eng.records()).first);
    expect(s.posted, p);
    s.pays[h]!['state'] = 'paid';
    r = await r0.eng.advance((await r0.eng.records()).first);
    expect(r['state'], 'settled');
    expect(r0.paidOn, isEmpty, reason: 'a sale pays no BTC');
  });

  test('a trade priced before the wallet named rails is followed on the rail of the moment', () async {
    final s = StandIn()
      ..makerSats = BigInt.from(50000)
      ..claimed = '${100000 - 616}';
    final r0 = railEngine(s, 'BTC', x);
    r0.use('lightning');
    final q = await r0.eng.quote(pay: 'BTC', receive: x, amount: BigInt.from(50000));
    await r0.eng.confirm(q.choice!, q.ticket!);
    final rec = (await r0.eng.records()).first..remove('btcRail');
    s.receives[h]!['state'] = 'issuing';
    s.ready = true;
    await r0.eng.advance(rec);
    expect(r0.paidOn, ['lightning']);
  });

  // A purchase whose asset became final only after the maker's invoice ran out (a parent-chain
  // split held finality for hours): the maker renews it under the same hash, or the trade returns.
  Future<(StandIn, Map<String, dynamic>)> boughtPastTheInvoice(String? renew) async {
    final s = StandIn()
      ..makerSats = BigInt.from(50000)
      ..claimed = '${100000 - 616}'
      ..renew = renew;
    final eng = engine(s, 'BTC', x);
    final q = await eng.quote(pay: 'BTC', receive: x, amount: BigInt.from(50000));
    expect(q.ok, isTrue, reason: q.why);
    await eng.confirm(q.choice!, q.ticket!);
    s.receives[h]!['state'] = 'issuing';
    s.expired = true;
    s.ready = true;
    final r = await eng.advance((await eng.records()).first);
    return (s, r);
  }

  test('buying with BTC: an invoice that ran out while the asset became final is renewed under the same hash and paid', () async {
    final (s, r) = await boughtPastTheInvoice('same');
    expect(s.posts.firstWhere((e) => e[0] == 'invoice')[1], {'swap': 's2'});
    expect(s.btcPaid, ['lnbcrt-maker-2'], reason: 'the renewed invoice is paid, never the one that ran out');
    expect(r['preimage'], p);
  });

  test('buying with BTC: a maker that renews no invoice leaves the trade returned, nothing paid, and the row says why', () async {
    final (s, r) = await boughtPastTheInvoice(null);
    expect(r['state'], 'returned');
    expect(r['whyKind'], 'lapsed');
    expect(s.btcPaid, isEmpty);
    expect(tradeStateWord(r, DateTime.now().millisecondsSinceEpoch), UserWords.returnedLapsed);
  });

  test('buying with BTC: a renewed invoice under another hash is not paid', () async {
    final (s, r) = await boughtPastTheInvoice('other-hash');
    expect(r['state'], 'returned');
    expect(s.btcPaid, isEmpty);
  });

  test('the rows say what is already true, with the minutes waited', () {
    const t = 10 * 60000;
    expect(tradeStateWord({'state': 'waiting', 'source': 'btc-gateway', 'waitingSince': t - 30000}, t), UserWords.waitingOther);
    expect(tradeStateWord({'state': 'waiting', 'source': 'btc-gateway', 'waitingSince': 0}, t), '${UserWords.waitingOther} (10 min)');
    expect(tradeStateWord({'state': 'sent', 'source': 'btc-gateway', 'dir': 'buy', 'preimage': p, 'receiveState': 'received', 'sentAt': t - 120000}, t),
        '${UserWords.receivedSettling} (2 min)');
    expect(tradeStateWord({'state': 'sent', 'source': 'leaf-maker', 'sentAt': t}, t), UserWords.sent);
    expect(tradeStateWord({'state': 'returned', 'feesPaid': [{'asset': x, 'atoms': '1'}]}, t), isNull);
    expect(tradeStateWord({'state': 'settled'}, t), UserWords.settled);
  });
}
