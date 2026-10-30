// Default mode's market view (data/market_view.dart): its words, the day, the chart's points, the
// book, and the reading of both directions. The same rules as the web wallet's
// market-view.test.mjs.
import 'package:ambra/src/data/market_view.dart';
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no word of the market view names a rail or developer word', () {
    for (final w in MarketWords.all()) {
      expect(forbiddenIn(w), isEmpty, reason: w);
    }
  });

  test('prices are written as the web wallet writes them', () {
    expect(fmtPrice(1234.5678), '1,234.57');
    expect(fmtPrice(1.5), '1.5');
    expect(fmtPrice(0.0000124394), '0.0000124394');
    expect(fmtPrice(0), '-');
    expect(fmtPrice(null), '-');
  });

  test('the day: last price, change, high, low and volume; or the last trade before it', () {
    const now = 1000000;
    final d = dayOf([(ts: now - 90000, p: 1.0, size: 5.0), (ts: now - 3600, p: 2.0, size: 1.0), (ts: now - 60, p: 3.0, size: 2.0)], now);
    expect(d.inDay, isTrue);
    expect(d.last, 3.0);
    expect(d.changePct, 50);
    expect(d.hi, 3.0);
    expect(d.lo, 2.0);
    expect(d.vol, 3.0);
    final old = dayOf([(ts: now - 90000, p: 1.0, size: 5.0)], now);
    expect(old.inDay, isFalse);
    expect(old.last, 1.0);
    expect(agoText(now - 90000, now), '1 day');
    expect(agoText(now - 120, now), '2 minutes');
  });

  test('the chart steps from the close before the range to now', () {
    const now = 100000;
    final r = marketRange('1D');
    final s = seriesOf([MarketCandle(t: now - 90000 - 900, o: 1, h: 1, l: 1, c: 1), MarketCandle(t: now - 1800, o: 2, h: 2, l: 2, c: 2)], r, now);
    expect(s.pts.first, (t: now - 86400, p: 1.0));
    expect(s.pts.last, (t: now, p: 2.0));
    expect(s.inRange, 1);
    expect(seriesOf([], r, now).pts, isEmpty);
  });

  test('the book: best bid and ask in the quote per whole base, depth on each side', () {
    final o = [
      // Sells 2 GOLD for 4,000 USDX: an ask at 2,000.
      {'maker_pubkey': 'a', 'offer_id': '1', 'offer_asset': 'G', 'want_asset': 'U', 'offer_amount': '200000000', 'want_amount': '400000000000'},
      // Buys 1 GOLD for 1,900 USDX: a bid at 1,900.
      {'maker_pubkey': 'b', 'offer_id': '2', 'offer_asset': 'U', 'want_asset': 'G', 'offer_amount': '190000000000', 'want_amount': '100000000'},
      // The same offer twice counts once; an expired one not at all.
      {'maker_pubkey': 'b', 'offer_id': '2', 'offer_asset': 'U', 'want_asset': 'G', 'offer_amount': '190000000000', 'want_amount': '100000000'},
      {'maker_pubkey': 'c', 'offer_id': '3', 'offer_asset': 'U', 'want_asset': 'G', 'offer_amount': '1', 'want_amount': '1', 'expires_at_unix': 5},
    ];
    final b = bookOf(o, 'G', 'U', 8, 8, 10);
    expect(b.ask, 2000);
    expect(b.bid, 1900);
    expect(b.askDepth, 2);
    expect(b.bidDepth, 1);
  });

  test('a relay with no ticker: both directions read and joined', () async {
    final seen = <String>[];
    Future<Map?> get(String path) async {
      seen.add(path);
      if (path.endsWith('/ticker')) return null;
      if (path == '/v1/market/G/U/trades?limit=200') return {'trades': [{'ts': 10, 'price': 2.0, 'size': 3, 'side': 'buy'}]};
      if (path == '/v1/market/U/G/trades?limit=200') return {'trades': [{'ts': 5, 'price': 0.5, 'size': 8, 'quote_size': 4, 'side': 'buy'}]};
      return null;
    }

    final m = await readMarket(get, 'G', 'U', marketRange('1D'));
    expect(m.trades.map((t) => t.price), [2.0, 2.0]);
    expect(m.trades.first.side, 'sell');
    expect(m.trades.first.size, 4);
    expect(m.candles, isNotEmpty);
    expect(seen.where((p) => p.contains('/orderbook')), hasLength(2));
  });

  test('a pair reads one way: BTC and the fiat stablecoins are the quote', () {
    String t(String h) => h;
    expect(canonicalPair('USDX', 'BTC', t), (base: 'USDX', quote: 'BTC'));
    expect(canonicalPair('BTC', 'GOLD', t), (base: 'GOLD', quote: 'BTC'));
    expect(canonicalPair('GOLD', 'USDX', t), (base: 'GOLD', quote: 'USDX'));
    expect(canonicalPair('tSEQ', 'GOLD', t), canonicalPair('GOLD', 'tSEQ', t));
  });
}
