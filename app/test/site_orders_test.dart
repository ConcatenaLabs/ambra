// A site's orders (data/site_orders.dart) mapped onto the trade engine and the leaf library's
// placement, against fakes. The same cases as the web wallet's site-orders.test.mjs; the engine
// and the library are driven live on the device.
import 'dart:async';

import 'package:ambra/src/data/leaf_service.dart' show LeafRefusal;
import 'package:ambra/src/data/site_orders.dart';
import 'package:ambra/src/data/user_trade.dart';
import 'package:flutter_test/flutter_test.dart';

final b = 'bb' * 32, q = 'cc' * 32;
final u = BigInt.from(10).pow(8);

/// The words default mode keeps out (the web wallet's docs/DEFAULT_MODE.md), beyond Ambra's list.
const moreForbidden = ['board', 'sat', 'node', 'room'];
List<String> forbidden(String t) => [
      ...forbiddenIn(t),
      for (final w in moreForbidden)
        if (RegExp('(^|[^a-z-])$w([^a-z-]|\$)').hasMatch(t.toLowerCase())) w,
    ];

/// A book that sells GOLD at 4000 USDX each and buys it at 3900.
class FakeEngine {
  final quotes = <(String, BigInt)>[];
  final dropped = <Candidate?>[];
  final recs = <Map<String, dynamic>>[];
  final advanced = <String>[];
  QuoteResult Function(String pay, BigInt amount)? answer;

  Candidate _cand(BigInt pay) => Candidate(
      source: 'covenant-round',
      id: 'c$pay',
      entry: BookEntry(source: 'covenant-round', id: 'e', rateNum: BigInt.one, rateDen: BigInt.one, maxReceive: pay, minReceive: BigInt.one,
          lot: BigInt.one, raw: const {}),
      receive: pay,
      give: pay,
      fees: const []);

  Future<QuoteResult> quote({required String pay, required String receive, required BigInt amount}) async {
    quotes.add((pay, amount));
    if (answer != null) return answer!(pay, amount);
    final have = BigInt.from(10).pow(12);
    final p = amount < have ? amount : have;
    final out = pay == q ? p ~/ BigInt.from(4000) : p * BigInt.from(3900);
    return QuoteResult.ok(
        Ticket(payAsset: pay, receiveAsset: receive, amountIn: p, amountOut: out, fees: [{'asset': pay, 'atoms': '10'}], source: 'covenant-round'),
        _cand(p));
  }

  Future<Map<String, dynamic>> confirm(Candidate c, Ticket t) async {
    final r = {'id': 'r${recs.length}', 'state': 'sent', 'ticket': t.toJson()};
    recs.add(r);
    return r;
  }
}

class FakeLeaves {
  final calls = <(String, Map<String, dynamic>)>[];
  Object? placeError;
  List<Map<String, dynamic>>? ordersAnswer;
  Future<dynamic> call(String c, Map<String, dynamic> a) async {
    calls.add((c, a));
    switch (c) {
      case 'schedule':
        return {'now': 1000};
      case 'order_quote':
        return {'fee': {'asset': a['sell'], 'amount': '25'}, 'full_price': '999', 'min_lot': a['min_lot'], 'expiry_locktime': 87400};
      case 'order_place':
        if (placeError != null) throw placeError!;
        return {'order': 'o1', 'state': 'waiting'};
      case 'orders':
        if (ordersAnswer != null) return ordersAnswer;
        return [
          {'order': 'o1', 'state': 'resting', 'holds': '60000000', 'refund_from': 87400, 'rests_at': 't:0'}
        ];
      case 'order_refund':
        // The library answers the refund's txid as `refund`.
        return {'order': 'o1', 'refund': 'rf'};
    }
    throw StateError('no $c');
  }
}

SiteOrders make(FakeEngine e, FakeLeaves l, {int Function()? now, Future<Map<String, dynamic>> Function(Map<String, dynamic>, Map<String, dynamic>)? list}) {
  String? stored;
  return SiteOrders(SiteOrderDeps(
    quote: e.quote,
    confirm: e.confirm,
    drop: e.dropped.add,
    advance: (r) async {
      e.advanced.add('${r['id']}');
      return r;
    },
    records: () async => e.recs,
    leaves: l.call,
    meta: (h) => h == b ? (ticker: 'GOLD', precision: 8) : (ticker: 'USDX', precision: 8),
    read: () async => stored,
    write: (v) async => stored = v,
    now: now,
    list: list,
  ));
}

String words(SiteReview r) => [r.title, r.text, for (final (k, v) in r.rows) '$k $v'].join('\n');

void main() {
  test('params: a market of two assets, a side, an amount; a limit needs its price', () {
    expect(() => readOrderParams({'type': 'x'}), throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'm', contains('type'))));
    expect(() => readOrderParams({'type': 'limit', 'base': b, 'quote': q, 'side': 'buy', 'amount': '5'}),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'm', contains('price'))));
    expect(() => readOrderParams({'type': 'market', 'base': b, 'quote': b, 'side': 'buy', 'amount': '5'}),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'm', contains('differ'))));
    expect(() => readOrderParams({'type': 'market', 'base': b, 'quote': q, 'side': 'buy', 'amount': '0'}), throwsArgumentError);
    expect(readOrderParams({'type': 'market', 'base': b, 'quote': 'BTC', 'side': 'sell', 'amount': '5'}).quote, 'BTC');
  });

  test('rest terms and the limit check: the price is quote atoms per whole base unit', () {
    final sell = SiteOrder('limit', b, q, 'sell', u * BigInt.two, BigInt.from(4100) * u);
    final rs = restTerms(sell, u);
    // In lowest terms: 4100·10^8 / 10^8 is 4100 / 1.
    expect([rs.sell, rs.want, rs.amount, rs.rateNum, rs.rateDen], [b, q, u * BigInt.two, BigInt.from(4100), BigInt.one]);
    final buy = SiteOrder('limit', b, q, 'buy', u ~/ BigInt.two, BigInt.from(3950) * u);
    final rb = restTerms(buy, u);
    expect([rb.sell, rb.want, rb.amount, rb.rateNum, rb.rateDen], [q, b, BigInt.from(1975) * u, BigInt.one, BigInt.from(3950)]);
    // A price with no common factor with the unit stays as it is.
    final odd = restTerms(SiteOrder('limit', b, q, 'sell', u, BigInt.from(123456789)), u);
    expect([odd.rateNum, odd.rateDen], [BigInt.from(123456789), u]);
    Ticket t(BigInt i, BigInt o) => Ticket(payAsset: b, receiveAsset: q, amountIn: i, amountOut: o, fees: const [], source: 's');
    expect(meetsLimit(sell, t(u * BigInt.two, BigInt.from(7800) * u), u), false);
    expect(meetsLimit(SiteOrder('limit', b, q, 'sell', u * BigInt.two, BigInt.from(3900) * u), t(u * BigInt.two, BigInt.from(7800) * u), u), true);
    expect(meetsLimit(buy, t(BigInt.from(2000) * u, u ~/ BigInt.two), u), false);
    expect(meetsLimit(SiteOrder('limit', b, q, 'buy', u ~/ BigInt.two, BigInt.from(4000) * u), t(BigInt.from(2000) * u, u ~/ BigInt.two), u), true);
    // A buy's rest rounds what it pays up.
    expect(restTerms(SiteOrder('limit', b, q, 'buy', BigInt.from(3), BigInt.from(1)), BigInt.from(2)).amount, BigInt.two);
  });

  test('a market buy is sized from a first price, shown, and settled as one trade', () async {
    final e = FakeEngine(), l = FakeLeaves();
    final s = make(e, l);
    final r = await s.quote({'type': 'market', 'base': b, 'quote': q, 'side': 'buy', 'amount': '$u'}, 'https://s/dex/');
    expect(r.kind, 'take');
    expect(e.quotes.length, 2);
    expect(e.quotes[0].$2, BigInt.from(10).pow(18)); // the first price: all the wallet can pay
    expect(e.quotes[1].$2, BigInt.from(4000) * u); // 1 GOLD at 4000
    expect(e.dropped.length, 1);
    expect(forbidden(words(r)), isEmpty);
    expect(words(r), contains('Asked by https://s/dex/'));
    expect(words(r), contains('Fees 0.0000001 USDX, included above'));
    expect(words(r), isNot(contains('Fees Fees')));
    expect(words(r), contains('You pay 4,000 USDX'));
    final a = await s.confirm(r.id);
    expect([a['filled'], a['got'], a['gave'], a['order']], [1, '$u', '${BigInt.from(4000) * u}', null]);
    final o = await s.orders('https://s/dex/');
    expect((o['trades'] as List).single['state'], 'sent');
    expect((o['trades'] as List).single['fills'], [
      {'txid': 'r0', 'base': '$u', 'quote': '${BigInt.from(4000) * u}', 'state': 'sent'}
    ]);
    // Following moves the site's own trades on, and no other.
    e.recs.add({'id': 'composer', 'state': 'sent'});
    await s.follow();
    expect(e.advanced, ['r0']);
    expect((await s.orders('https://other/'))['trades'], isEmpty);
    await expectLater(s.confirm(r.id), throwsA(isA<SiteRefusal>().having((x) => x.message, 'm', contains('no longer current'))));
  });

  test('a market sell trades its amount; a review left five minutes lapses', () async {
    final e = FakeEngine(), l = FakeLeaves();
    var t = 0;
    final s = make(e, l, now: () => t);
    final r = await s.quote({'type': 'market', 'base': b, 'quote': q, 'side': 'sell', 'amount': '$u'}, 'o');
    expect(e.quotes.single.$2, u);
    t = 5 * 60 * 1000 + 1;
    await expectLater(s.confirm(r.id), throwsA(isA<SiteRefusal>().having((x) => x.message, 'm', SiteWords.lapsed)));
    expect(e.recs, isEmpty);
    expect(e.dropped.length, 1);
  });

  test('a declined review lets its price go and moves nothing', () async {
    final e = FakeEngine(), l = FakeLeaves();
    final s = make(e, l);
    final r = await s.quote({'type': 'market', 'base': b, 'quote': q, 'side': 'sell', 'amount': '$u'}, 'o');
    s.drop(r.id);
    expect(e.dropped.length, 1);
    expect(e.recs, isEmpty);
    await expectLater(s.confirm(r.id), throwsA(isA<SiteRefusal>()));
  });

  test('a limit order away from the book rests from leaves, listed once it rests, taken back only after its date', () async {
    final e = FakeEngine(), l = FakeLeaves();
    final listed = <(String, String)>[];
    var t = 1000 * 1000;
    final s = make(e, l, now: () => t, list: (o, rec) async {
      listed.add(('${o['order']}', '${rec['offer_id']}'));
      return {'relay_expires': 5};
    });
    final r = await s.quote({'type': 'limit', 'base': b, 'quote': q, 'side': 'sell', 'amount': '$u', 'price': '${BigInt.from(4200) * u}'}, 'https://s/dex/');
    expect(r.kind, 'rest');
    expect(e.dropped.length, 1); // the price that did not meet the limit is let go
    expect(forbidden(words(r)), isEmpty);
    final qa = l.calls.firstWhere((c) => c.$1 == 'order_quote').$2;
    expect([qa['sell'], qa['want'], qa['amount'], qa['rate_num'], qa['rate_den'], qa['expiry'], qa['min_lot']],
        [b, q, '$u', '4200', '1', '87400', '${u ~/ BigInt.from(10)}']);
    expect(words(r), contains('Price 4,200 USDX per GOLD'));
    expect(words(r), contains('What is left can be taken back from 1970-01-02 00:16 UTC'));
    expect(words(r), contains('Fees 0.00000025 GOLD, on top\n'));
    final a = await s.confirm(r.id);
    expect([a['order'], a['filled'], a['trade']], ['o1', 0, null]);
    expect((l.calls.firstWhere((c) => c.$1 == 'order_place').$2['shown'] as Map)['full_price'], '999');
    await s.follow();
    expect(listed.length, 1);
    await s.follow();
    expect(listed.length, 1);
    final o = ((await s.orders('https://s/dex/'))['orders'] as List).single as Map;
    expect([o['state'], o['filled'], o['can_take_back']], ['filling', '${u - BigInt.from(60000000)}', false]);
    await expectLater(s.quoteCancel({'order': 'o1'}, 'https://s/dex/'),
        throwsA(isA<SiteRefusal>().having((x) => x.message, 'm', contains('can be taken back from 1970-01-02 00:16 UTC'))));
    t = 90000 * 1000;
    final c = await s.quoteCancel({'order': 'o1'}, 'https://s/dex/');
    expect(forbidden(words(c)), isEmpty);
    expect(await s.confirmCancel(c.id), {'order': 'o1', 'txid': 'rf'});
    await expectLater(s.quoteCancel({'order': 'o1'}, 'https://x/'), throwsA(isA<SiteRefusal>().having((x) => x.message, 'm', contains('no such order'))));
  });

  test('a limit buy that meets the book trades; one that does not rests at its price', () async {
    final e = FakeEngine(), l = FakeLeaves();
    final s = make(e, l);
    // Buy 1 GOLD at up to 4100: the book sells at 4000, so it trades, paying for 1 GOLD.
    final r = await s.quote({'type': 'limit', 'base': b, 'quote': q, 'side': 'buy', 'amount': '$u', 'price': '${BigInt.from(4100) * u}'}, 'o');
    expect(r.kind, 'take');
    expect(e.quotes.first.$2, BigInt.from(4100) * u); // the probe pays the limit's worth
    // At 3000 it rests: selling 3000 USDX for 1 GOLD.
    final r2 = await s.quote({'type': 'limit', 'base': b, 'quote': q, 'side': 'buy', 'amount': '$u', 'price': '${BigInt.from(3000) * u}'}, 'o');
    expect(r2.kind, 'rest');
    final qa = l.calls.lastWhere((c) => c.$1 == 'order_quote').$2;
    expect([qa['sell'], qa['want'], qa['amount'], qa['rate_num'], qa['rate_den']], [q, b, '${BigInt.from(3000) * u}', '1', '3000']);
  });

  test('a market order nobody offers is refused in plain words, and a limit against BTC only trades', () async {
    final e = FakeEngine()..answer = (_, _) => QuoteResult.no('not-offered');
    final s = make(e, FakeLeaves());
    await expectLater(s.quote({'type': 'market', 'base': b, 'quote': q, 'side': 'sell', 'amount': '5'}, 'o'),
        throwsA(isA<SiteRefusal>().having((x) => x.message, 'm', 'Not offered right now: nobody offers USDX for GOLD in one step.')));
    await expectLater(s.quote({'type': 'limit', 'base': b, 'quote': 'BTC', 'side': 'sell', 'amount': '5', 'price': '9'}, 'o'),
        throwsA(isA<SiteRefusal>().having((x) => x.message, 'm', SiteWords.priceNotMet)));
  });

  test('an order is recorded before the library is asked: one whose app closed mid-placement is still the site\'s', () async {
    final e = FakeEngine(), l = FakeLeaves();
    final placing = Completer<void>();
    final hold = Completer<void>();
    final real = l.call;
    String? stored;
    final s = SiteOrders(SiteOrderDeps(
      quote: e.quote, confirm: e.confirm, drop: e.dropped.add, advance: (r) async => r, records: () async => e.recs,
      leaves: (c, a) async {
        if (c == 'order_place') {
          placing.complete();
          await hold.future;
        }
        return real(c, a);
      },
      meta: (h) => (ticker: 'GOLD', precision: 8), read: () async => stored, write: (v) async => stored = v,
    ));
    final r = await s.quote({'type': 'limit', 'base': b, 'quote': q, 'side': 'sell', 'amount': '$u', 'price': '${BigInt.from(9000) * u}'}, 'o');
    unawaited(s.confirm(r.id));
    await placing.future;
    // While the library places it: listed as placing.
    final o1 = ((await s.orders('o'))['orders'] as List).single as Map;
    expect(o1['state'], 'placing');
    // The library's orders name an order of that amount: it is adopted as this site's.
    l.ordersAnswer = [{'order': 'o9', 'state': 'waiting', 'amount': '$u'}];
    final o2 = ((await s.orders('o'))['orders'] as List).single as Map;
    expect([o2['order'], o2['state']], ['o9', 'placing']);
    hold.complete();
  });

  test('a placement the library refuses is said plainly, never in its own words', () async {
    final e = FakeEngine(), l = FakeLeaves()..placeError = LeafRefusal('refused', 'the operator round has no room for the leaf');
    final s = make(e, l);
    final r = await s.quote({'type': 'limit', 'base': b, 'quote': q, 'side': 'sell', 'amount': '$u', 'price': '${BigInt.from(9000) * u}'}, 'o');
    await expectLater(s.confirm(r.id), throwsA(isA<SiteRefusal>().having((x) => x.message, 'm', SiteWords.cannotRest)));
  });

  test('every word a site order shows keeps out of default mode\'s forbidden words', () {
    for (final w in SiteWords.all()) {
      expect(forbidden(w), isEmpty, reason: w);
    }
  });
}
