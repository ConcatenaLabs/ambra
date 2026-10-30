/// The market of a pair, as default mode's Swap tab shows it above "You pay": the pair, its last
/// price and 24-hour change, the day's high, low and volume, a price chart over 1D, 1W and 1M,
/// the best bid and ask with the book's depth on each side, and the market's recent trades.
///
/// The web wallet's `market-view.js` in Dart (change them together; docs/DEFAULT_MODE.md
/// "Market"). Every figure comes from SeqDEX's relay, whose one trade log per market holds every
/// trade however it settled, so the market reads the same in every wallet and on SeqDEX. This
/// file holds the words and the pure parts (reading, the day, the chart's points, the book); the
/// widget is `widgets/market_view.dart`. Every word is in [MarketWords], none of
/// [kUserModeForbiddenWords] (market_view_test.dart checks).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

class MarketWords {
  static const ranges = ['1D', '1W', '1M'];
  static const change24 = '24h';
  static const noDay = 'No trades in the last 24 hours';
  static String lastTrade(String price, String ago) => 'Last trade $price, $ago ago';
  static const noTrades = 'No trades yet';
  static const noRange = 'No trades in this range';
  static const bid = 'Best bid';
  static const ask = 'Best ask';
  static const noBook = 'Nobody is buying or selling right now';
  static const buyers = 'Buyers';
  static const sellers = 'Sellers';
  static const trades = 'Recent trades';
  static const price = 'Price';
  static const amount = 'Amount';
  static const time = 'Time';
  static const high = 'High';
  static const low = 'Low';
  static const volume = 'Volume';

  static List<String> all() => [
        ...ranges,
        change24,
        noDay,
        lastTrade('1 XT', '3 minutes'),
        noTrades,
        noRange,
        bid,
        ask,
        noBook,
        buyers,
        sellers,
        trades,
        price,
        amount,
        time,
        high,
        low,
        volume,
      ];
}

/// A chart range: the span shown and the candle each point is, in seconds.
class MarketRange {
  const MarketRange(this.key, this.span, this.interval);
  final String key;
  final int span, interval;
}

const List<MarketRange> kMarketRanges = [
  MarketRange('1D', 86400, 900),
  MarketRange('1W', 7 * 86400, 7200),
  MarketRange('1M', 30 * 86400, 43200),
];

MarketRange marketRange(String key) => kMarketRanges.firstWhere((r) => r.key == key, orElse: () => kMarketRanges.first);

double _num(Object? v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
int _int(Object? v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

/// One trade of the relay's log: price in quote atoms per base atom, size in base atoms.
class MarketTrade {
  MarketTrade({required this.ts, required this.price, required this.size, required this.side, this.id = ''});
  final int ts;
  final double price, size;
  final String side, id;

  static MarketTrade fromJson(Map j) =>
      MarketTrade(ts: _int(j['ts']), price: _num(j['price']), size: _num(j['size']), side: '${j['side'] ?? ''}', id: '${j['id'] ?? ''}');

  /// The trade read in the other direction of its market.
  MarketTrade flipped(Map j) {
    final q = j['quote_size'];
    return MarketTrade(ts: ts, price: price > 0 ? 1 / price : 0, size: q == null ? size : _num(q), side: side == 'buy' ? 'sell' : (side == 'sell' ? 'buy' : side), id: id);
  }
}

class MarketCandle {
  MarketCandle({required this.t, required this.o, required this.h, required this.l, required this.c, this.v = 0});
  final int t;
  final double o, h, l, c, v;
  static MarketCandle fromJson(Map j) => MarketCandle(t: _int(j['t']), o: _num(j['o']), h: _num(j['h']), l: _num(j['l']), c: _num(j['c']), v: _num(j['v']));
}

/// A price in quote atoms per base atom, in whole units: quote per whole base.
double unitPrice(double atomPrice, int basePrec, int quotePrec) => atomPrice > 0 ? atomPrice * math.pow(10, basePrec - quotePrec) : 0;

/// Candles from trades (oldest first), for a relay that serves each direction apart.
List<MarketCandle> candlesOf(List<MarketTrade> trades, int interval) {
  final out = <MarketCandle>[];
  for (final t in trades) {
    final b = (t.ts ~/ interval) * interval;
    final p = t.price;
    if (out.isEmpty || out.last.t != b) {
      out.add(MarketCandle(t: b, o: p, h: p, l: p, c: p, v: t.size));
    } else {
      final c = out.removeLast();
      out.add(MarketCandle(t: b, o: c.o, h: math.max(c.h, p), l: math.min(c.l, p), c: p, v: c.v + t.size));
    }
  }
  return out;
}

/// The last 24 hours, from trades in unit prices (oldest first).
class MarketDay {
  MarketDay({required this.inDay, this.last, this.lastT, this.hi = 0, this.lo = 0, this.vol = 0, this.changePct = 0});
  final bool inDay;
  final double? last;
  final int? lastT;
  final double hi, lo, vol, changePct;
}

MarketDay dayOf(List<({int ts, double p, double size})> trades, int nowSec) {
  final last = trades.isEmpty ? null : trades.last;
  final win = trades.where((t) => t.ts >= nowSec - 86400).toList();
  if (win.isEmpty) return MarketDay(inDay: false, last: last?.p, lastT: last?.ts);
  var hi = -double.infinity, lo = double.infinity, vol = 0.0;
  for (final t in win) {
    hi = math.max(hi, t.p);
    lo = math.min(lo, t.p);
    vol += t.size;
  }
  final open = win.first.p, close = win.last.p;
  return MarketDay(inDay: true, last: close, lastT: last!.ts, hi: hi, lo: lo, vol: vol, changePct: open > 0 ? (close - open) / open * 100 : 0);
}

/// The chart's points over a range: each candle's close at its end, the close before the range
/// carried in at its start, and the last close carried to now. Empty when nothing ever traded.
({List<({int t, double p})> pts, int inRange, int start}) seriesOf(List<MarketCandle> candles, MarketRange range, int nowSec) {
  final start = nowSec - range.span;
  final before = candles.where((c) => c.t + range.interval <= start).toList();
  final inside = candles.where((c) => c.t + range.interval > start).toList();
  final pts = <({int t, double p})>[];
  if (before.isNotEmpty) pts.add((t: start, p: before.last.c));
  for (final c in inside) {
    pts.add((t: math.max(start, math.min(nowSec, c.t + range.interval)), p: c.c));
  }
  if (pts.isNotEmpty) pts.add((t: nowSec, p: pts.last.p));
  return (pts: pts, inRange: inside.length, start: start);
}

/// "3 minutes", "1 hour", as ago.
String agoText(int tSec, int nowSec) {
  final d = math.max(0, nowSec - tSec);
  String u(int n, String w) => '$n $w${n == 1 ? '' : 's'}';
  if (d >= 86400) return u(d ~/ 86400, 'day');
  if (d >= 3600) return u(d ~/ 3600, 'hour');
  if (d >= 60) return u(d ~/ 60, 'minute');
  return u(math.max(1, d), 'second');
}

/// A price as the web wallet's `fmtPrice` writes it: 2 decimals from 1000, 4 from 1, else enough
/// to show three significant digits.
String fmtPrice(double? v) {
  if (v == null || !(v > 0) || !v.isFinite) return '-';
  final digits = v >= 1000 ? 2 : (v >= 1 ? 4 : math.min(12, 3 - (math.log(v) / math.ln10).floor() + 2));
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  final parts = s.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return parts.length > 1 ? '$whole.${parts[1]}' : whole;
}

/// The book's best bid and ask (unit prices) and its depth on each side (base units), from the
/// offers of both orientations.
({double? bid, double? ask, double bidDepth, double askDepth}) bookOf(List offers, String base, String quote, int bp, int qp, int nowSec) {
  double? bid, ask;
  var bidDepth = 0.0, askDepth = 0.0;
  final seen = <String>{};
  for (final o in offers) {
    if (o is! Map) continue;
    final exp = _int(o['expires_at_unix'] ?? o['expiresAtUnix']);
    if (exp != 0 && exp <= nowSec) continue;
    final id = '${o['maker_pubkey'] ?? o['makerPubkey']}:${o['offer_id'] ?? o['offerId']}';
    if (!seen.add(id)) continue;
    final oa = o['offer_asset'] ?? o['offerAsset'], wa = o['want_asset'] ?? o['wantAsset'];
    final oA = _num(o['offer_amount'] ?? o['offerAmount']), wA = _num(o['want_amount'] ?? o['wantAmount']);
    double baseU, quoteU;
    bool isAsk;
    if (oa == base && wa == quote) {
      baseU = oA / math.pow(10, bp);
      quoteU = wA / math.pow(10, qp);
      isAsk = true;
    } else if (oa == quote && wa == base) {
      baseU = wA / math.pow(10, bp);
      quoteU = oA / math.pow(10, qp);
      isAsk = false;
    } else {
      continue;
    }
    if (!(baseU > 0 && quoteU > 0)) continue;
    final p = quoteU / baseU;
    if (isAsk) {
      askDepth += baseU;
      if (ask == null || p < ask) ask = p;
    } else {
      bidDepth += baseU;
      if (bid == null || p > bid) bid = p;
    }
  }
  return (bid: bid, ask: ask, bidDepth: bidDepth, askDepth: askDepth);
}

/// A market read from the relay in the pair's display direction.
class MarketRead {
  MarketRead({required this.trades, required this.candles, required this.offers, required this.range, required this.ticker});
  final List<MarketTrade> trades; // oldest first, atom prices
  final List<MarketCandle> candles; // atom prices
  final List offers;
  final MarketRange range;
  final bool ticker;
}

typedef MarketGet = Future<Map?> Function(String path);

/// Reads a market: its ticker, trades, candles over [range] and both orientations of its book. A
/// relay that answers no ticker keeps each direction's trades apart: both are read and joined.
Future<MarketRead> readMarket(MarketGet get, String base, String quote, MarketRange range) async {
  String m(String b, String q) => '/v1/market/${Uri.encodeComponent(b)}/${Uri.encodeComponent(q)}';
  final r = await Future.wait([
    get('${m(base, quote)}/ticker'),
    get('${m(base, quote)}/trades?limit=200'),
    get('${m(base, quote)}/candles?interval=${range.interval}&limit=${(range.span / range.interval).ceil() + 50}'),
    get('${m(base, quote)}/orderbook'),
    get('${m(quote, base)}/orderbook'),
  ]);
  final ticker = r[0], tr = r[1], cd = r[2], b1 = r[3], b2 = r[4];
  var trades = [for (final t in (tr?['trades'] as List?) ?? const []) if (t is Map) MarketTrade.fromJson(t)];
  var candles = [for (final c in (cd?['candles'] as List?) ?? const []) if (c is Map) MarketCandle.fromJson(c)];
  if (ticker == null) {
    final tr2 = await get('${m(quote, base)}/trades?limit=200');
    final other = [for (final t in (tr2?['trades'] as List?) ?? const []) if (t is Map) MarketTrade.fromJson(t).flipped(t)];
    if (other.isNotEmpty) {
      trades = [...trades, ...other]..sort((a, b) => a.ts.compareTo(b.ts));
      candles = candlesOf(trades, range.interval);
    }
  }
  trades.sort((a, b) => a.ts.compareTo(b.ts));
  return MarketRead(
    trades: trades,
    candles: candles,
    offers: [...(b1?['offers'] as List?) ?? const [], ...(b2?['offers'] as List?) ?? const []],
    range: range,
    ticker: ticker != null,
  );
}

/// [MarketGet] over HTTP at the relay's base URL: null for anything but a 200 with JSON.
MarketGet relayGet(String relay) => (path) async {
      try {
        final r = await http.get(Uri.parse('$relay$path')).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) return null;
        final j = jsonDecode(r.body);
        return j is Map ? j : null;
      } catch (_) {
        return null;
      }
    };

/// What the view draws, in whole units, from a [MarketRead].
class MarketPicture {
  MarketPicture({
    required this.baseTicker,
    required this.quoteTicker,
    required this.trades,
    required this.day,
    required this.series,
    required this.book,
    required this.basePrec,
  });
  final String baseTicker, quoteTicker;
  final List<({int ts, double p, double size, String side})> trades; // oldest first, unit prices
  final MarketDay day;
  final ({List<({int t, double p})> pts, int inRange, int start}) series;
  final ({double? bid, double? ask, double bidDepth, double askDepth}) book;
  final int basePrec;

  /// The book's buyers' share of its depth, in percent (50 with no depth).
  int get buyersPct {
    final tot = book.bidDepth + book.askDepth;
    return tot > 0 ? (book.bidDepth / tot * 100).round() : 50;
  }
}

MarketPicture pictureOf(MarketRead m, {required String base, required String quote, required String baseTicker, required String quoteTicker, required int bp, required int qp, required int nowSec}) {
  final trades = [
    for (final t in m.trades)
      if (unitPrice(t.price, bp, qp) > 0) (ts: t.ts, p: unitPrice(t.price, bp, qp), size: t.size, side: t.side),
  ];
  final candles = [
    for (final c in m.candles)
      MarketCandle(t: c.t, o: unitPrice(c.o, bp, qp), h: unitPrice(c.h, bp, qp), l: unitPrice(c.l, bp, qp), c: unitPrice(c.c, bp, qp), v: c.v),
  ];
  return MarketPicture(
    baseTicker: baseTicker,
    quoteTicker: quoteTicker,
    trades: trades,
    day: dayOf([for (final t in trades) (ts: t.ts, p: t.p, size: t.size)], nowSec),
    series: seriesOf(candles, m.range, nowSec),
    book: bookOf(m.offers, base, quote, bp, qp, nowSec),
    basePrec: bp,
  );
}

/// The pair's display direction, "1 base = N quote": BTC, then the fiat stablecoins, are the
/// quote; every other asset (the Sequence token included) is a base of equal standing, ties broken
/// by id. The web wallet's `canonicalPair`.
({String base, String quote}) canonicalPair(String a, String b, String Function(String hex) ticker) {
  int rank(String h) {
    if (h == 'BTC') return 1000;
    const r = {'USDX': 900, 'EURX': 890, 'EURC.E': 885, 'FEEUSD': 880, 'USDT': 870, 'USDC': 865, 'USDC.E': 864, 'USD': 860};
    return r[ticker(h).toUpperCase()] ?? 400;
  }

  final ra = rank(a), rb = rank(b);
  if (ra != rb) return ra > rb ? (base: b, quote: a) : (base: a, quote: b);
  return a.compareTo(b) < 0 ? (base: a, quote: b) : (base: b, quote: a);
}
