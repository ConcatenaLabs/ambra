// The wallet rule for the asset a Sequentia transaction pays its fee in. Every
// place Ambra builds a Sequentia transaction asks this file, so the rule has one
// home:
//
//   1. the asset being moved, when the node accepts it for fees and the wallet
//      holds a coin of it;
//   2. else the accepted asset whose largest coin covers the most fees: the one
//      whose largest single coin is worth the most at the node's rate, since a
//      fee of F reference units costs ceil(F * 1e8 / rate) atoms of an asset, so
//      a coin of A atoms covers A * rate / (F * 1e8) fees;
//   3. else nothing. The caller refuses with [noFeeAssetMessage]. The Sequence
//      token (tSEQ) is never a default and never a fallback: it is chosen only
//      as any other asset is, by rule 1 or 2.
//
// The node's rate feed keys an asset by ticker or by id; a feed may also key the
// policy asset (tSEQ) as "bitcoin" (Elements naming). An asset absent from the feed is
// not accepted, and no rate is ever invented for it.

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';

/// The node's rate for [hex] from its fee-rate feed, or null when the node does
/// not accept [hex] for fees.
BigInt? feeRateFor(Map<String, BigInt> rates, String hex) {
  final r = (hex == SeqAssets.policy ? rates['bitcoin'] : null) ?? rates[SeqAssets.labelFor(hex).ticker] ?? rates[hex];
  return (r != null && r > BigInt.zero) ? r : null;
}

/// The fee asset by the wallet rule (see the file comment), or null when the
/// wallet holds no coin of any asset the node accepts.
///
/// [moved] is the asset the transaction moves (null when it moves none of the
/// wallet's assets, e.g. an issuance). [largestCoin] maps each asset to the
/// wallet's largest single coin of it, in atoms. [exclude] names assets that may
/// not pay this fee (a covenant fill refuses the asset it sells).
String? walletFeeAsset({
  required String? moved,
  required Map<String, BigInt> rates,
  required Map<String, BigInt> largestCoin,
  Set<String> exclude = const {},
}) {
  bool usable(String hex) =>
      !exclude.contains(hex) &&
      feeRateFor(rates, hex) != null &&
      (largestCoin[hex] ?? BigInt.zero) > BigInt.zero;

  if (moved != null && usable(moved)) return moved;

  String? best;
  BigInt bestValue = BigInt.zero;
  final ids = largestCoin.keys.toList()..sort(); // a tie goes to the lower id, never to a favourite
  for (final hex in ids) {
    if (!usable(hex)) continue;
    final value = largestCoin[hex]! * feeRateFor(rates, hex)!;
    if (value > bestValue) {
      best = hex;
      bestValue = value;
    }
  }
  return best;
}

/// The words for a wallet that holds no coin the node accepts for fees.
const noFeeAssetMessage =
    'No asset you hold is accepted for fees by the node right now, so this cannot be sent. '
    'Receive or swap into an asset the node accepts, then try again.';

/// The fee, in atoms of an asset the node rates at [rate], that is worth
/// [referenceAtoms] of the reference unit: ceil(referenceAtoms * 1e8 / rate). For a
/// fixed-size transaction (a covenant fill or refund) whose fee the caller sizes.
BigInt feeAtomsIn(BigInt rate, BigInt referenceAtoms) {
  final scale = BigInt.from(100000000);
  final f = (referenceAtoms * scale + rate - BigInt.one) ~/ rate;
  return f <= BigInt.zero ? BigInt.one : f;
}

/// Each asset's largest single coin from a wallet sync.
Map<String, BigInt> largestCoinsOf(core.WalletSync s) => {
      for (final c in s.largestCoins) c.assetId: BigInt.tryParse(c.atoms) ?? BigInt.zero,
    };

/// The fee asset by the wallet rule for code that holds a mnemonic but no screen
/// state: reads the node's rates and the wallet's coins (the sync is shared with
/// the build that follows, so it costs no second scan). When [movedAtoms] is the
/// whole on-chain balance of [moved], the moved asset cannot also pay the fee and
/// the rule looks past it. Throws [noFeeAssetMessage] when nothing qualifies.
Future<({String asset, BigInt rate})> walletFeeFor(
  String mnemonic, {
  required String? moved,
  BigInt? movedAtoms,
  Set<String> exclude = const {},
}) async {
  final rates = await ApiClient.feeRates();
  final s = await core.syncWallet(mnemonic: mnemonic, esploraUrl: Backend.esplora);
  final skip = {...exclude};
  if (moved != null && movedAtoms != null) {
    BigInt bal = BigInt.zero;
    for (final b in s.balances) {
      if (b.assetId == moved) bal = BigInt.tryParse(b.atoms) ?? BigInt.zero;
    }
    if (movedAtoms >= bal) skip.add(moved);
  }
  final asset = walletFeeAsset(moved: moved, rates: rates, largestCoin: largestCoinsOf(s), exclude: skip);
  if (asset == null) throw Exception(noFeeAssetMessage);
  return (asset: asset, rate: feeRateFor(rates, asset)!);
}

/// The builders' fee parameter: [asset] at the node's [rate]. The policy asset
/// (tSEQ) goes the same way: the core pays it natively but values it at this rate,
/// as the node does.
core.FeeAsset feeAssetParam(String asset, BigInt rate) => core.FeeAsset(assetId: asset, rate: rate);

/// [walletFeeFor] as the builders' fee parameter.
Future<core.FeeAsset> walletFeeParam(String mnemonic,
    {required String? moved, BigInt? movedAtoms, Set<String> exclude = const {}}) async {
  final f = await walletFeeFor(mnemonic, moved: moved, movedAtoms: movedAtoms, exclude: exclude);
  return feeAssetParam(f.asset, f.rate);
}

/// A fee rate typed in the fee asset's own units per vByte, as the reference
/// atoms per kvB the core takes: r × 10^precision × rate / 1e5.
double referenceKvbFromAssetRate(double perVb, BigInt rate, int precision) {
  var scale = 1.0;
  for (var i = 0; i < precision; i++) {
    scale *= 10;
  }
  return perVb * scale * rate.toDouble() / 100000;
}

/// A rate of [referencePerVb] reference atoms per vByte, in the fee asset's own
/// units per vByte (the inverse of [referenceKvbFromAssetRate]).
double assetRateFromReference(double referencePerVb, BigInt rate, int precision) {
  var scale = 1.0;
  for (var i = 0; i < precision; i++) {
    scale *= 10;
  }
  return referencePerVb * 100000000 / rate.toDouble() / scale;
}

/// [assetRateFromReference] written for a text field: up to [digits] significant
/// figures, no exponent, no trailing zeros.
String formatAssetRate(double v, {int digits = 3}) {
  if (v <= 0) return '0';
  var s = v.toStringAsPrecision(digits);
  if (s.contains('e')) {
    // Exponent form: as many decimals as the significant figures need, within 20.
    final exp = int.parse(s.substring(s.indexOf('e') + 1));
    final decimals = (digits - 1 - exp).clamp(0, 20);
    s = v.toStringAsFixed(decimals);
  }
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s;
}
