import 'dart:convert';

import 'fee_asset_rule.dart' show feeRateFor;

/// The wallet's reference fee rate, in reference atoms per 1,000 vB: the rate every other fee in the
/// app starts from (`DEFAULT_FEERATE_SAT_KVB` in the core).
const int kReferenceRatePerKvb = 2000;

/// [askJson] with a drip's fee rate valued at the node's rate for the dripped asset, when the ask
/// names none. A drip pays its fee in the asset it drips, so a default in that asset's own atoms
/// (the engine's 1,000 a kvB) would be worth whatever that asset is worth: a cheap asset's drip
/// would underpay and a dear one's overpay. The rate here is the reference rate at the node's
/// exchange rate for the asset, `ceil(reference × 10^8 / rate)` atoms of it a kvB, as every other
/// fee in the app is. Throws when the node does not price the asset. An ask that is not a drip,
/// or that names its rate, comes back unchanged.
String dripAskAtNodeRate(String askJson, Map<String, BigInt> rates) {
  final ask = jsonDecode(askJson);
  if (ask is! Map || ask['drip'] is! Map) return askJson;
  final drip = Map<String, dynamic>.from(ask['drip'] as Map);
  if (drip['ratePerKvb'] != null) return askJson;
  final asset = dripAsset(ask);
  if (asset == null) return askJson; // the engine refuses an instance without its asset
  final rate = feeRateFor(rates, asset);
  if (rate == null) {
    throw 'the node does not price the dripped asset for fees, so this drip cannot pay one';
  }
  final num = BigInt.from(kReferenceRatePerKvb) * BigInt.from(100000000);
  final perKvb = (num + rate - BigInt.one) ~/ rate;
  drip['ratePerKvb'] = perKvb.toInt();
  return jsonEncode({...Map<String, dynamic>.from(ask), 'drip': drip});
}

/// The dripped asset's id in display order: the instance's `ASSET` parameter is in the internal
/// (serialized) byte order, the reverse.
String? dripAsset(Map ask) {
  final inst = ask['instance'];
  final params = inst is Map ? inst['params'] : null;
  final a = params is Map ? params['ASSET'] : null;
  if (a is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(a)) return null;
  final bytes = [for (var i = 0; i < 64; i += 2) a.substring(i, i + 2)];
  return bytes.reversed.join().toLowerCase();
}
