// The unified order book: one price-sorted book per pair, merging every relay that rests
// liquidity for it (the on-chain cross relay, the sub-asset relays and the pure-Lightning
// relay), with the rail an offer settles on carried as metadata. The hosted-node service
// serves it at `GET /book/unified?asset=<id>[&quote=<id>]`, the same book the web wallet
// reads (its `tooling/lsp/unified-book.mjs` builds it). The match a taker gets is the best
// PRICE on the side it takes, whatever rail that offer rests on; the rails the user picks
// decide how the trade settles, never which offer it matches.

import 'dart:convert';

import 'lsp_client.dart';

/// One resting offer in the unified book. [side] is 'ask' (the maker sells the asset; a taker
/// buys) or 'bid' (the maker buys the asset; a taker sells). [quoteAtoms] are BTC satoshis on a
/// BTC pair, else the quote asset's atoms. [price] is quote atoms per asset atom, for ordering
/// only, never for settlement.
class UnifiedEntry {
  UnifiedEntry({
    required this.side,
    required this.rail,
    required this.assetAtoms,
    required this.quoteAtoms,
    required this.price,
    required this.minFill,
    required this.indivisible,
    required this.id,
    required this.maker,
  });

  final String side;
  final String rail; // 'onchain' | 'pureln' | 'submarine' | 'ln' | 'samechain' ...
  final BigInt assetAtoms;
  final BigInt quoteAtoms;
  final double price;
  final BigInt minFill;
  final bool indivisible;
  final String? id;
  final String? maker;

  bool get isAsk => side == 'ask';

  /// Whether the offer settles over Lightning (on either leg), for the developer-mode line.
  bool get overLightning => rail != 'onchain' && rail != 'samechain' && rail != 'same';

  static BigInt _big(Object? v) {
    if (v == null) return BigInt.zero;
    if (v is int) return BigInt.from(v);
    if (v is double) return BigInt.from(v.truncate());
    return BigInt.tryParse('$v'.split('.').first) ?? BigInt.zero;
  }

  /// Null for an entry without a usable price or side; the service drops those already.
  static UnifiedEntry? fromJson(Map<String, dynamic> j) {
    final side = '${j['side'] ?? ''}';
    final p = j['price'];
    final price = p is num ? p.toDouble() : double.tryParse('${p ?? ''}');
    if ((side != 'ask' && side != 'bid') || price == null || !(price > 0)) return null;
    return UnifiedEntry(
      side: side,
      rail: '${j['rail'] ?? ''}',
      assetAtoms: _big(j['assetAtoms']),
      quoteAtoms: _big(j['btcSats']),
      price: price,
      minFill: _big(j['minFill']),
      indivisible: j['indivisible'] == true,
      id: j['id']?.toString(),
      maker: j['maker']?.toString(),
    );
  }
}

/// The book for one pair: asks cheapest first, bids richest first, as the service sorts them.
class UnifiedBook {
  UnifiedBook({required this.asset, required this.quote, required this.asks, required this.bids});

  final String asset;
  final String quote; // 'BTC' or the quote asset id
  final List<UnifiedEntry> asks;
  final List<UnifiedEntry> bids;

  bool get isEmpty => asks.isEmpty && bids.isEmpty;

  /// The offer a taker on [takerSide] ('buy' | 'sell') matches: the lowest ask for a buy, the
  /// highest bid for a sell, passing over any id in [skip]. Rail-blind by construction: nothing
  /// here reads a rail. The twin of `bestFor` in the web wallet's unified-book.mjs.
  UnifiedEntry? bestFor(String takerSide, {Set<String>? skip}) {
    final list = takerSide == 'buy' ? asks : (takerSide == 'sell' ? bids : const <UnifiedEntry>[]);
    for (final o in list) {
      if (skip != null && o.id != null && skip.contains(o.id)) continue;
      return o;
    }
    return null;
  }

  static UnifiedBook fromJson(Map<String, dynamic> j) {
    List<UnifiedEntry> read(Object? v) => [
          for (final e in (v is List ? v : const []))
            if (e is Map<String, dynamic>) UnifiedEntry.fromJson(e),
        ].whereType<UnifiedEntry>().toList();
    final asks = read(j['asks'])..sort((a, b) => a.price.compareTo(b.price));
    final bids = read(j['bids'])..sort((a, b) => b.price.compareTo(a.price));
    return UnifiedBook(asset: '${j['asset'] ?? ''}', quote: '${j['quote'] ?? 'BTC'}', asks: asks, bids: bids);
  }
}

/// Reads the unified book for ([asset], [quote]) from the hosted-node service. [quote] null or
/// 'BTC' is the asset's Bitcoin market. Null when the service cannot be reached or refuses, so
/// the caller can tell an unreachable book from an empty one.
Future<UnifiedBook?> fetchUnifiedBook(String asset, {String? quote}) async {
  try {
    final q = StringBuffer('/book/unified?asset=${Uri.encodeComponent(asset)}');
    if (quote != null && quote.isNotEmpty && quote.toUpperCase() != 'BTC') {
      q.write('&quote=${Uri.encodeComponent(quote)}');
    }
    final r = await LspClient.getPath(q.toString());
    if (r.statusCode < 200 || r.statusCode >= 300 || r.body.isEmpty) return null;
    final j = jsonDecode(r.body);
    if (j is! Map<String, dynamic> || j['ok'] != true) return null;
    return UnifiedBook.fromJson(j);
  } catch (_) {
    return null;
  }
}
