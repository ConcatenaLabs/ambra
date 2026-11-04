// The unified book (data/unified_book.dart): one price-sorted book for a pair, read from the
// hosted-node service's /book/unified, the book the web wallet reads. The fixture is a capture
// of the live testnet book for one asset against BTC, its lists reversed so the client's own
// sort is what puts the best price first.
import 'dart:convert';
import 'dart:io';

import 'package:ambra/src/data/unified_book.dart';
import 'package:flutter_test/flutter_test.dart';

UnifiedBook load() => UnifiedBook.fromJson(
    jsonDecode(File('test/fixtures/unified_book.json').readAsStringSync()) as Map<String, dynamic>);

void main() {
  test('asks sort cheapest first, bids richest first, whatever the order served', () {
    final b = load();
    for (var i = 1; i < b.asks.length; i++) {
      expect(b.asks[i - 1].price <= b.asks[i].price, isTrue);
    }
    for (var i = 1; i < b.bids.length; i++) {
      expect(b.bids[i - 1].price >= b.bids[i].price, isTrue);
    }
  });

  test('a buy matches the lowest ask and a sell the highest bid, on any rail', () {
    final b = load();
    final buy = b.bestFor('buy')!, sell = b.bestFor('sell')!;
    final lowestAsk = b.asks.map((e) => e.price).reduce((a, c) => a < c ? a : c);
    final highestBid = b.bids.map((e) => e.price).reduce((a, c) => a > c ? a : c);
    expect(buy.price, lowestAsk);
    expect(sell.price, highestBid);
    // The book holds offers on more than one rail, and the match is the price, not a rail.
    expect({for (final e in [...b.asks, ...b.bids]) e.rail}.length, greaterThan(1));
  });

  test('the match passes over a skipped offer to the next best price', () {
    final b = load();
    final first = b.bestFor('buy')!;
    final next = b.bestFor('buy', skip: {first.id!})!;
    expect(next.id, isNot(first.id));
    expect(next.price >= first.price, isTrue);
  });

  test('entries keep sizes in atoms and say where they rest', () {
    final b = load();
    for (final e in [...b.asks, ...b.bids]) {
      expect(e.assetAtoms > BigInt.zero, isTrue);
      expect(e.quoteAtoms > BigInt.zero, isTrue);
      expect(e.overLightning, e.rail != 'onchain');
    }
  });

  test('a priceless or sideless entry is dropped, an empty side matches nothing', () {
    final b = UnifiedBook.fromJson({
      'ok': true, 'asset': 'a', 'quote': 'BTC',
      'asks': [
        {'side': 'ask', 'rail': 'onchain', 'assetAtoms': 10, 'btcSats': 0, 'price': null},
        {'side': 'x', 'rail': 'onchain', 'assetAtoms': 10, 'btcSats': 500, 'price': 50},
      ],
      'bids': [],
    });
    expect(b.isEmpty, isTrue);
    expect(b.bestFor('buy'), isNull);
    expect(b.bestFor('sell'), isNull);
  });
}
