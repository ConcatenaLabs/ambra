/// A paired site's market and limit orders (the provider protocol's `placeOrder`, `getOrders`,
/// `cancelOrder`), settled the way the Swap tab settles a trade.
///
/// The same rules as the web wallet's `site-orders.js` (change them together). A market order is
/// one trade of the default-mode trade engine ([UserTradeEngine], `user_trade.dart`): it reads the
/// single-step book, has the leaf library price each candidate, and settles the best one in one
/// step. A limit order is that same trade when the best price meets the limit; otherwise the whole
/// amount rests on the book as an order placed from the wallet's leaves (the library's
/// `order_quote` and `order_place`), listed by the wallet once it rests, and taken back by its
/// refund once its time has run out. Against BTC a limit order only trades: nothing of BTC rests.
///
/// Each step answers what the person must approve ([SiteReview], in the words of the web wallet's
/// `docs/DEFAULT_MODE.md`) before anything is signed; the approval itself is the caller's (the
/// site sheet). Every amount on it is the engine's or the library's; nothing the site sent is
/// trusted beyond the market, the side, the amount and the price.
library;

import 'dart:convert';
import 'dart:math';

import 'format.dart';
import 'leaf_service.dart' show LeafRefusal;
import 'user_trade.dart';

const _quoteTtlMs = 5 * 60 * 1000;
const _day = 86400;
final _hex64 = RegExp(r'^[0-9a-f]{64}$');

BigInt _big(Object? v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
BigInt _ceilDiv(BigInt a, BigInt b) => (a + b - BigInt.one) ~/ b;

/// Every string a site's order shows, beside [UserWords].
class SiteWords {
  static const tradeTitle = 'Trade?';
  static const restTitle = 'Place an order?';
  static const takeBackTitle = 'Take back what is left of your order?';
  static const askedBy = 'Asked by';
  static const youSell = 'You sell';
  static const forAtLeast = 'For';
  static const price = 'Price';
  static const smallest = 'Smallest part filled';
  static const takeBack = 'What is left can be taken back from';
  static const restText =
      'Nothing on the book meets your price now, so the order rests on the book at your price: anyone can fill it, all or in parts, while your wallet is closed. What it is paid arrives in your wallet.';
  static const tradeText = 'One trade, at the best price the book offers now.';
  static const takeBackText = 'The order comes off the book and what is left of it returns to your wallet.';
  static String notYet(String when) => 'this order can be taken back from $when; until then it stays on the book for anyone to fill at your price';
  static const priceNotMet = 'Nothing on the book meets that price right now.';
  static const cannotRest = 'This order could not be placed. Nothing moved.';
  static const lapsed = 'This review is no longer current: place the order again.';

  static List<String> all() => [tradeTitle, restTitle, takeBackTitle, askedBy, youSell, forAtLeast, price, smallest, takeBack, restText,
      tradeText, takeBackText, notYet('2026-01-01 00:00 UTC'), priceNotMet, cannotRest, lapsed];
}

/// A site's order, as read from its params.
class SiteOrder {
  SiteOrder(this.type, this.base, this.quote, this.side, this.amount, this.price);
  final String type, base, quote, side;
  final BigInt amount;
  final BigInt? price;
}

/// The order's terms from the site's params; refuses what is not a market of two assets, a side,
/// an amount and (limit) a price.
SiteOrder readOrderParams(Map p) {
  final type = p['type'] == 'limit' ? 'limit' : (p['type'] == 'market' ? 'market' : null);
  if (type == null) throw ArgumentError("type must be 'market' or 'limit'");
  final base = '${p['base'] ?? ''}'.toLowerCase();
  final quote = p['quote'] == kUserBtc ? kUserBtc : '${p['quote'] ?? ''}'.toLowerCase();
  if (!_hex64.hasMatch(base)) throw ArgumentError('base must be a 32-byte hex asset id');
  if (quote != kUserBtc && !_hex64.hasMatch(quote)) throw ArgumentError("quote must be a 32-byte hex asset id or 'BTC'");
  if (base == quote) throw ArgumentError('base and quote must differ');
  final side = p['side'] == 'buy' || p['side'] == 'sell' ? p['side'] as String : null;
  if (side == null) throw ArgumentError("side must be 'buy' or 'sell'");
  final amount = '${p['amount'] ?? ''}';
  if (!RegExp(r'^\d+$').hasMatch(amount) || _big(amount) <= BigInt.zero) throw ArgumentError('amount must be a positive number of base atoms');
  BigInt? price;
  if (type == 'limit') {
    final s = '${p['price'] ?? ''}';
    if (!RegExp(r'^\d+$').hasMatch(s) || _big(s) <= BigInt.zero) {
      throw ArgumentError('a limit order needs a price: quote atoms per whole base unit');
    }
    price = _big(s);
  }
  return SiteOrder(type, base, quote, side, _big(amount), price);
}

/// What a limit order rests as: what it sells, for what, at which rate (want atoms per sold atoms).
/// `unit` is 10^(base precision): the price is quote atoms per whole base unit. The rate is kept in
/// lowest terms: a fill multiplies by it in 64-bit arithmetic.
({String sell, String want, BigInt amount, BigInt rateNum, BigInt rateDen}) restTerms(SiteOrder o, BigInt unit) {
  final g = o.price!.gcd(unit);
  if (o.side == 'sell') return (sell: o.base, want: o.quote, amount: o.amount, rateNum: o.price! ~/ g, rateDen: unit ~/ g);
  return (sell: o.quote, want: o.base, amount: _ceilDiv(o.amount * o.price!, unit), rateNum: unit ~/ g, rateDen: o.price! ~/ g);
}

/// Whether a ticket meets a limit: a sale gets at least the price per base, a purchase pays at most it.
bool meetsLimit(SiteOrder o, Ticket t, BigInt unit) {
  final inA = t.amountIn, out = t.amountOut;
  if (inA <= BigInt.zero || out <= BigInt.zero) return false;
  return o.side == 'sell' ? out * unit >= o.price! * inA : inA * unit <= o.price! * out;
}

/// What the person approves: a title, a sentence and the rows. Nothing is signed yet.
class SiteReview {
  SiteReview(this.id, this.kind, this.title, this.text, this.rows);
  final String id, kind, title, text;
  final List<(String, String)> rows;
}

/// A refusal said to the site in the words a person reads.
class SiteRefusal implements Exception {
  SiteRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the site orders need from the app.
class SiteOrderDeps {
  SiteOrderDeps({
    required this.quote,
    required this.confirm,
    required this.drop,
    required this.advance,
    required this.records,
    required this.leaves,
    required this.meta,
    required this.read,
    required this.write,
    this.list,
    int Function()? now,
    void Function(String)? log,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       log = log ?? ((_) {});

  /// The trade engine's ([UserTradeEngine]).
  final Future<QuoteResult> Function({required String pay, required String receive, required BigInt amount}) quote;
  final Future<Map<String, dynamic>> Function(Candidate c, Ticket t) confirm;
  final void Function(Candidate? c) drop;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> rec) advance;
  final Future<List<Map<String, dynamic>>> Function() records;

  /// The leaf library: a command and its answer.
  final Future<dynamic> Function(String command, Map<String, dynamic> args) leaves;
  final ({String ticker, int precision}) Function(String asset) meta;
  final Future<String?> Function() read;
  final Future<void> Function(String value) write;

  /// Lists an order placed here on the book once it rests; answers what to keep of the listing.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> order, Map<String, dynamic> rec)? list;
  final int Function() now;
  final void Function(String) log;
}

class _Pending {
  _Pending.take(this.o, this.origin, this.choice, this.ticket, this.at) : kind = 'take', args = null, quote = null, order = null;
  _Pending.rest(this.o, this.origin, this.args, this.quote, this.at) : kind = 'rest', choice = null, ticket = null, order = null;
  _Pending.cancel(this.order, this.at) : kind = 'cancel', o = null, origin = null, choice = null, ticket = null, args = null, quote = null;
  final String kind;
  final SiteOrder? o;
  final String? origin, order;
  final Candidate? choice;
  final Ticket? ticket;
  final Map<String, dynamic>? args, quote;
  final int at;
}

class SiteOrders {
  SiteOrders(this.d);
  final SiteOrderDeps d;
  final _pending = <String, _Pending>{};
  final _rng = Random.secure();

  ({String ticker, int precision}) _meta(String h) {
    if (h == kUserBtc) return (ticker: 'BTC', precision: 8);
    try {
      return d.meta(h);
    } catch (_) {
      return (ticker: '?', precision: 0);
    }
  }

  String _tick(String h) {
    final t = _meta(h).ticker;
    return t.isNotEmpty && t != '?' ? t : '${h.substring(0, min(8, h.length))}…';
  }

  int _prec(String h) => _meta(h).precision;
  String _fmt(String h, Object? atoms) => '${formatAtoms('${_big(atoms)}', _prec(h))} ${_tick(h)}';
  BigInt _unitOf(String h) => BigInt.from(10).pow(_prec(h));
  static String when(int unix) =>
      '${DateTime.fromMillisecondsSinceEpoch(unix * 1000, isUtc: true).toIso8601String().substring(0, 16).replaceFirst('T', ' ')} UTC';
  String _priceText(BigInt price, String base, String quote) => '${formatAtoms('$price', _prec(quote))} ${_tick(quote)} per ${_tick(base)}';
  /// The fees' one line under its own label: "`amount`, included above", or "No fees".
  (String, String) _feeRow(List<Map<String, dynamic>> fees, String pay) {
    final l = costLine(fees, (a, x) => _fmt(a, x), pay);
    return (UserWords.fees, l.startsWith('${UserWords.fees} ') ? l.substring(UserWords.fees.length + 1) : l);
  }

  String _nid() => '${d.now()}-${_rng.nextInt(1 << 32).toRadixString(16)}';
  String _hex16() => List.generate(16, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<Map<String, dynamic>> _db() async {
    Map<String, dynamic> v;
    try {
      final s = await d.read();
      v = s == null ? {} : Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      v = {};
    }
    v['trades'] = Map<String, dynamic>.from((v['trades'] as Map?) ?? const {});
    v['orders'] = Map<String, dynamic>.from((v['orders'] as Map?) ?? const {});
    v['placing'] = Map<String, dynamic>.from((v['placing'] as Map?) ?? const {});
    return v;
  }

  Future<void> _save(Map<String, dynamic> v) async {
    try {
      await d.write(jsonEncode(v));
    } catch (_) {}
  }

  String _refusal(QuoteResult q, String pay, String get) => switch (q.why) {
        'not-listed' => UserWords.notListed(_tick(get), _tick(pay)),
        'not-offered' => UserWords.notOffered(_tick(get), _tick(pay)),
        'no-funds' => UserWords.noFunds(_tick(pay)),
        'not-ready' => UserWords.notReady(_tick(pay), q.soon),
        'redoing' => UserWords.redoing(_tick(pay)),
        'freeing' => UserWords.freeing(_tick(pay), q.soon),
        _ => UserWords.tooSmall,
      };

  /// One trade of the engine for the order: a sale pays its amount; a purchase pays what the book
  /// asks for its amount, read from a first price for all the wallet can pay.
  Future<({String pay, String get, QuoteResult q})> _tradeQuote(SiteOrder o) async {
    final pay = o.side == 'sell' ? o.base : o.quote;
    final get = o.side == 'sell' ? o.quote : o.base;
    if (o.side == 'sell') return (pay: pay, get: get, q: await d.quote(pay: pay, receive: get, amount: o.amount));
    final probeAmount = o.price != null ? _ceilDiv(o.amount * o.price!, _unitOf(o.base)) : BigInt.from(10).pow(18);
    final probe = await d.quote(pay: pay, receive: get, amount: probeAmount);
    if (!probe.ok) return (pay: pay, get: get, q: probe);
    final t = probe.ticket!;
    if (t.amountOut <= o.amount) return (pay: pay, get: get, q: probe);
    try {
      d.drop(probe.choice);
    } catch (_) {}
    final want = _ceilDiv(o.amount * t.amountIn, t.amountOut);
    return (pay: pay, get: get, q: await d.quote(pay: pay, receive: get, amount: want));
  }

  /// What the person approves for a site's order. Nothing is signed yet.
  Future<SiteReview> quote(Map params, String origin) async {
    final SiteOrder o;
    try {
      o = readOrderParams(params);
    } on ArgumentError catch (e) {
      throw SiteRefusal('${e.message}');
    }
    final asked = (SiteWords.askedBy, origin);
    ({String pay, String get, QuoteResult q})? tq;
    try {
      tq = await _tradeQuote(o);
    } catch (e) {
      d.log('[site orders] no price: $e');
      tq = null;
    }
    final unit = _unitOf(o.base);
    final q = tq?.q;
    final takes = q != null && q.ok && (o.type == 'market' || meetsLimit(o, q.ticket!, unit));
    if (takes) {
      final t = q.ticket!;
      final id = _nid();
      _pending[id] = _Pending.take(o, origin, q.choice, t, d.now());
      return SiteReview(id, 'take', SiteWords.tradeTitle, SiteWords.tradeText, [
        (UserWords.pay, _fmt(t.payAsset, t.amountIn)),
        (UserWords.get, _fmt(t.receiveAsset, t.amountOut)),
        _feeRow(t.fees, t.payAsset),
        if (t.upTo != null) ('', UserWords.upTo(_fmt(t.payAsset, t.upTo))),
        asked,
      ]);
    }
    if (q != null && q.ok) {
      try {
        d.drop(q.choice);
      } catch (_) {}
    }
    if (o.type == 'market' || o.quote == kUserBtc) {
      if (o.type == 'limit') throw SiteRefusal(SiteWords.priceNotMet);
      throw SiteRefusal(q != null ? _refusal(q, tq!.pay, tq.get) : UserWords.failed);
    }
    // Rest the whole amount at the price, from the wallet's leaves.
    final terms = restTerms(o, unit);
    final args = <String, dynamic>{
      'sell': terms.sell,
      'want': terms.want,
      'amount': '${terms.amount}',
      'rate_num': '${terms.rateNum}',
      'rate_den': '${terms.rateDen}',
      'min_lot': '${terms.amount ~/ BigInt.from(10) > BigInt.zero ? terms.amount ~/ BigInt.from(10) : BigInt.one}',
    };
    Map<String, dynamic> rq;
    try {
      final sch = (await d.leaves('schedule', const {})) as Map;
      args['expiry'] = '${_big(sch['now']) + BigInt.from(_day)}';
      rq = Map<String, dynamic>.from((await d.leaves('order_quote', args)) as Map);
    } catch (e) {
      d.log('[site orders] order_quote: $e');
      throw SiteRefusal(SiteWords.cannotRest);
    }
    final id = _nid();
    _pending[id] = _Pending.rest(o, origin, args, rq, d.now());
    final fee = Map<String, dynamic>.from((rq['fee'] as Map?) ?? const {});
    final feeAsset = '${fee['asset'] ?? args['sell']}';
    return SiteReview(id, 'rest', SiteWords.restTitle, SiteWords.restText, [
      (SiteWords.youSell, _fmt(args['sell'] as String, args['amount'])),
      (SiteWords.forAtLeast, _fmt(args['want'] as String, rq['full_price'])),
      (SiteWords.price, _priceText(o.price!, o.base, o.quote)),
      (SiteWords.smallest, _fmt(args['sell'] as String, rq['min_lot'] ?? args['min_lot'])),
      // Paid from the wallet besides what the order sells: not "included above".
      (UserWords.fees, _big(fee['amount']) > BigInt.zero ? '${_fmt(feeAsset, fee['amount'])}, on top' : UserWords.noFees),
      (SiteWords.takeBack, when(_big(rq['expiry_locktime'] ?? args['expiry']).toInt())),
      asked,
    ]);
  }

  /// A review the person declined, or that lapsed: what it held is let go.
  void drop(String id) {
    final p = _pending.remove(id);
    if (p != null && p.kind == 'take') {
      try {
        d.drop(p.choice);
      } catch (_) {}
    }
  }

  /// Settles an approved review: placeOrder's answer.
  Future<Map<String, dynamic>> confirm(String id) async {
    final p = _pending.remove(id);
    if (p == null || p.kind == 'cancel' || d.now() - p.at > _quoteTtlMs) {
      if (p != null && p.kind == 'take') d.drop(p.choice);
      throw SiteRefusal(SiteWords.lapsed);
    }
    final o = p.o!;
    final market = {'base': o.base, 'quote': o.quote};
    if (p.kind == 'take') {
      Map<String, dynamic> rec;
      try {
        rec = await d.confirm(p.choice!, p.ticket!);
      } on LapsedError {
        throw SiteRefusal(SiteWords.lapsed);
      } catch (e) {
        d.log('[site orders] confirm: $e');
        throw SiteRefusal(e is LeafRefusal && e.plain ? e.message : UserWords.failed);
      }
      if (rec['state'] == 'failed') throw SiteRefusal(UserWords.failed);
      final gave = p.ticket!.amountIn, got = p.ticket!.amountOut;
      // In the market's terms: base and quote atoms of the one fill.
      final fill = o.side == 'sell' ? {'base': '$gave', 'quote': '$got'} : {'base': '$got', 'quote': '$gave'};
      final v = await _db();
      (v['trades'] as Map)[rec['id']] = {'origin': p.origin, 'market': market, 'side': o.side, 'type': o.type, 'at': d.now(), ...fill};
      await _save(v);
      return {
        'trade': rec['id'],
        'filled': 1,
        'failed': <dynamic>[],
        'order': null,
        'order_error': null,
        'gave': '${p.ticket!.amountIn}',
        'got': '${p.ticket!.amountOut}',
      };
    }
    final args = p.args!;
    final offerId = _hex16();
    final rec = {
      'origin': p.origin,
      'market': market,
      'side': o.side,
      'price': '${o.price}',
      'amount': '${o.amount}',
      'sell': args['sell'],
      'sold': args['amount'],
      'rate_num': args['rate_num'],
      'rate_den': args['rate_den'],
      'offer_id': offerId,
      'at': d.now(),
    };
    // Written before the library is asked, so an order whose app closed while it was placed is
    // still this site's: it shows as being placed until the library's orders name it.
    var v = await _db();
    (v['placing'] as Map)[offerId] = rec;
    await _save(v);
    Map<String, dynamic> r;
    try {
      r = Map<String, dynamic>.from((await d.leaves('order_place', {...args, 'shown': p.quote})) as Map);
    } catch (e) {
      v = await _db();
      (v['placing'] as Map).remove(offerId);
      await _save(v);
      // The library's own words name its internals: the site hears the plain refusal.
      d.log('[site orders] order_place: $e');
      throw SiteRefusal(e is LeafRefusal && e.plain ? e.message : SiteWords.cannotRest);
    }
    v = await _db();
    (v['placing'] as Map).remove(offerId);
    (v['orders'] as Map)['${r['order']}'] = rec;
    await _save(v);
    return {'trade': null, 'filled': 0, 'failed': <dynamic>[], 'order': r['order'], 'order_error': null, 'gave': '0', 'got': '0'};
  }

  Future<void>? _following;

  /// Moves this wallet's site trades on, and lists the orders placed here that rest now. One pass
  /// at a time: a call while one runs waits for that one.
  Future<void> follow() => _following ??= _follow().whenComplete(() => _following = null);

  Future<void> _follow() async {
    final v = await _db();
    final trades = v['trades'] as Map;
    for (final r in await d.records()) {
      if (!trades.containsKey(r['id']) || ['settled', 'returned', 'failed'].contains(r['state'])) continue;
      try {
        await d.advance(r);
      } catch (e) {
        d.log('[site orders] follow: $e');
      }
    }
    final mine = v['orders'] as Map;
    if (mine.isEmpty || d.list == null) return;
    List lib;
    try {
      lib = (await d.leaves('orders', const {})) as List? ?? const [];
    } catch (e) {
      d.log('[site orders] orders: $e');
      return;
    }
    for (final o in lib.whereType<Map>()) {
      final rec = mine['${o['order']}'];
      if (rec is! Map || rec['listed'] != null || o['state'] != 'resting') continue;
      try {
        final res = await d.list!(Map<String, dynamic>.from(o), Map<String, dynamic>.from(rec));
        final w = await _db();
        (w['orders'] as Map)['${o['order']}'] = {...Map<String, dynamic>.from(rec), 'listed': o['rests_at'], 'relay_expires': res['relay_expires']};
        await _save(w);
      } catch (e) {
        d.log('[site orders] list: $e');
      }
    }
  }

  static String _tradeState(Map? r) {
    if (r == null) return 'sent';
    if (r['state'] == 'settled') return 'settled';
    if (r['state'] == 'failed' || r['state'] == 'returned') return 'failed';
    return 'sent';
  }

  static String _orderState(Map? o, Map rec) {
    final s = '${o?['state'] ?? 'waiting'}';
    if (s == 'filled') return 'filled';
    if (s == 'refunded' || s == 'spent' || s == 'not_placed') return 'withdrawn';
    if (s != 'resting') return 'placing';
    return _big(o!['holds']) < _big(rec['sold']) ? 'filling' : 'open';
  }

  /// getOrders' answer: the trades and orders this site made through this wallet.
  Future<Map<String, dynamic>> orders(String origin) async {
    final v = await _db();
    final byId = {for (final r in await d.records()) '${r['id']}': r};
    final trades = [
      for (final e in (v['trades'] as Map).entries)
        if ((e.value as Map)['origin'] == origin)
          {
            'trade': e.key,
            'at': (e.value as Map)['at'],
            'market': (e.value as Map)['market'],
            'side': (e.value as Map)['side'],
            'type': (e.value as Map)['type'],
            'kind': 'take',
            'order': null,
            'state': _tradeState(byId['${e.key}']),
            'fills': [
              if ((e.value as Map)['base'] != null)
                {'txid': e.key, 'base': (e.value as Map)['base'], 'quote': (e.value as Map)['quote'], 'state': _tradeState(byId['${e.key}'])},
            ],
          },
    ];
    final placing = [for (final e in (v['placing'] as Map).entries) if ((e.value as Map)['origin'] == origin) e];
    var ids = [for (final e in (v['orders'] as Map).entries) if ((e.value as Map)['origin'] == origin) e];
    List lib = const [];
    if (ids.isNotEmpty || placing.isNotEmpty) {
      try {
        lib = (await d.leaves('orders', const {})) as List? ?? const [];
      } catch (e) {
        d.log('[site orders] orders: $e');
      }
    }
    // An order placed while its app closed: the library's order of the same amount sold, named by
    // no other record, is it.
    if (placing.isNotEmpty && lib.isNotEmpty) {
      final known = {...(v['orders'] as Map).keys.map((k) => '$k')};
      for (final e in placing) {
        final rec = e.value as Map;
        final o = lib.whereType<Map>().where((x) => !known.contains('${x['order']}') && '${x['amount'] ?? x['holds'] ?? ''}' == '${rec['sold']}').firstOrNull;
        if (o == null) continue;
        known.add('${o['order']}');
        (v['orders'] as Map)['${o['order']}'] = rec;
        (v['placing'] as Map).remove(e.key);
      }
      await _save(v);
      ids = [for (final e in (v['orders'] as Map).entries) if ((e.value as Map)['origin'] == origin) e];
    }
    final byOrder = {for (final o in lib.whereType<Map>()) '${o['order']}': o};
    final t = d.now() ~/ 1000;
    final out = <Map<String, dynamic>>[];
    for (final e in ids) {
      final rec = e.value as Map;
      final o = byOrder['${e.key}'];
      final state = _orderState(o, rec);
      final soldNow = _big(rec['sold']) - _big(o != null ? o['holds'] : rec['sold']);
      // In base atoms: a sale filled what it sold; a purchase what it was paid, at its rate.
      final filled = rec['side'] == 'sell' ? soldNow : (soldNow * _big(rec['rate_num'])) ~/ _big(rec['rate_den']);
      final from = o != null && o['refund_from'] != null ? _big(o['refund_from']).toInt() : null;
      out.add({
        'order': e.key,
        'market': rec['market'],
        'side': rec['side'],
        'price': rec['price'],
        'at': rec['at'],
        'amount': rec['amount'],
        'filled': '${filled < BigInt.zero ? BigInt.zero : filled}',
        'holds': '${o != null ? (o['holds'] ?? '0') : rec['sold']}',
        'sell': rec['sell'],
        'state': state,
        'settled': state == 'filled',
        'take_back_from': from,
        'take_back_from_text': from != null && from > 0 ? when(from) : '',
        'can_take_back': from != null && from > 0 && t >= from && (state == 'open' || state == 'filling'),
        'fills': <dynamic>[],
        'note': o != null && o['note'] != null ? '${o['note']}' : '',
      });
    }
    for (final e in (v['placing'] as Map).entries) {
      final rec = e.value as Map;
      if (rec['origin'] != origin) continue;
      out.add({
        'order': e.key, 'market': rec['market'], 'side': rec['side'], 'price': rec['price'], 'at': rec['at'], 'amount': rec['amount'],
        'filled': '0', 'holds': rec['sold'], 'sell': rec['sell'], 'state': 'placing', 'settled': false, 'take_back_from': null,
        'take_back_from_text': '', 'can_take_back': false, 'fills': <dynamic>[], 'note': '',
      });
    }
    return {'orders': out, 'trades': trades};
  }

  /// What the person approves to take back one of this site's orders, once its time has run out.
  Future<SiteReview> quoteCancel(Map params, String origin) async {
    final id = '${params['order'] ?? ''}';
    final v = await _db();
    final rec = (v['orders'] as Map)[id];
    if (rec is! Map || rec['origin'] != origin) throw SiteRefusal('no such order of this site');
    final lib = (await d.leaves('orders', const {})) as List? ?? const [];
    final o = lib.whereType<Map>().where((x) => x['order'] == id).firstOrNull;
    final from = o != null && o['refund_from'] != null ? _big(o['refund_from']).toInt() : null;
    if (from == null || from == 0 || d.now() ~/ 1000 < from) {
      throw SiteRefusal(SiteWords.notYet(from != null && from > 0 ? when(from) : 'its refund date'));
    }
    final qid = _nid();
    _pending[qid] = _Pending.cancel(id, d.now());
    final market = Map<String, dynamic>.from(rec['market'] as Map);
    return SiteReview(qid, 'cancel', SiteWords.takeBackTitle, SiteWords.takeBackText, [
      (SiteWords.youSell, _fmt('${rec['sell']}', rec['sold'])),
      (SiteWords.price, _priceText(_big(rec['price']), '${market['base']}', '${market['quote']}')),
      (SiteWords.askedBy, origin),
    ]);
  }

  Future<Map<String, dynamic>> confirmCancel(String qid) async {
    final p = _pending.remove(qid);
    if (p == null || p.kind != 'cancel') throw SiteRefusal(SiteWords.lapsed);
    Map? r;
    try {
      r = (await d.leaves('order_refund', {'order': p.order})) as Map?;
    } catch (e) {
      d.log('[site orders] order_refund: $e');
      throw SiteRefusal(e is LeafRefusal && e.plain ? e.message : UserWords.failed);
    }
    return {'order': p.order, 'txid': r?['txid'] ?? r?['refund']};
  }
}
