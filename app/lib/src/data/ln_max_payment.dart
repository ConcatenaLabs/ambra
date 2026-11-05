import 'ark_limits.dart' show usdAtoms;

/// The operator's limit on one payment over Lightning: the web wallet's `lnMaxPayment`, `fitsMax`
/// (asset-lightning.js) and `lnFits`, `lnFallbackFits` (index.html) in Dart. Change them together.
///
/// The operator's nodes carry every user's payments and the BTC legs of swaps, so the operator
/// holds one payment to a share of what they carry, less what it keeps for swaps, publishes that
/// figure in its `info` (`max_payment`: `send`, `receive`, per asset and for its Bitcoin node) and
/// refuses a payment above it. The wallet holds no figure of its own: above the operator's limit a
/// payment goes on the chain. Only when the operator publishes nothing is one payment held to
/// [kLnFallbackUsd].

/// One payment over Lightning is held to this many USD when the operator publishes no limit.
const kLnFallbackUsd = 1500.0;

BigInt _big(Object? v) {
  if (v is BigInt) return v;
  if (v is int) return BigInt.from(v);
  return BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
}

/// The operator's published facts of the node that carries [kind]: its Bitcoin node for 'BTC'
/// (`server_info.lightning.bitcoin.node`), else the asset's (`server_info.assets[].lightning`).
Map? lnNodeOf(Map? info, String kind) {
  if (info == null) return null;
  final si = info['server_info'] is Map ? info['server_info'] as Map : info;
  if (kind == 'BTC') {
    final ln = si['lightning'];
    final b = ln is Map ? ln['bitcoin'] : null;
    final n = b is Map ? b['node'] : null;
    return n is Map ? n : null;
  }
  final assets = si['assets'];
  if (assets is! List) return null;
  for (final a in assets) {
    if (a is Map && a['asset'] == kind) return a['lightning'] is Map ? a['lightning'] as Map : null;
  }
  return null;
}

/// The operator's limit on one payment over its node for [kind] ('BTC', or an asset id) in
/// direction [dir] ('out': a payment the wallet makes, 'in': one it receives), in atoms, as its
/// `info` publishes it; null when it publishes none. A node that is down publishes 0.
BigInt? lnMaxPayment(Map? info, String kind, String dir) {
  final mp = lnNodeOf(info, kind)?['max_payment'];
  final v = mp is Map ? mp[dir == 'in' ? 'receive' : 'send'] : null;
  if (v == null || !RegExp(r'^\d+$').hasMatch('$v')) return null;
  return _big(v);
}

/// Whether a payment of [atoms] fits the operator's limit [max]. A limit that is not published
/// holds nothing back here: the fallback applies then ([lnFits]).
bool fitsMax(Object? atoms, BigInt? max) => max == null || _big(atoms) <= max;

/// The fallback: worth no more than [kLnFallbackUsd] at [price] USD a unit of [precision]
/// decimals. An asset the feed does not value is not held.
bool lnFallbackFits(Object? atoms, {required double? price, required int precision, double usd = kLnFallbackUsd}) {
  if (!(usd > 0)) return true;
  final at = usdAtoms(usd, price, precision);
  return at == null || _big(atoms) <= at;
}

/// Whether one payment of [atoms] of [kind] fits the operator's limit in direction [dir], from
/// the operator's `info` the leaf wallet holds ([info], null when it holds none): the published
/// limit, or the fallback when the operator publishes none. A payment of no known amount fits.
bool lnFits(Map? info, String kind, String dir, Object? atoms, {required double? price, required int precision}) {
  if (atoms == null) return true;
  final max = lnMaxPayment(info, kind, dir);
  if (max == null) return lnFallbackFits(atoms, price: price, precision: precision);
  return fitsMax(atoms, max);
}
