/// One asset's figure across every rail the wallet holds it on: on-chain, leaves and
/// Lightning. The figure is their sum, in both modes; developer mode also shows the
/// split. Native BTC is never a leaf (a tree on Sequentia holds no BTC).
class AssetFigure {
  const AssetFigure({required this.id, required this.onchain, required this.leaves, required this.lightning});
  final String id;
  final BigInt onchain;
  final BigInt leaves;
  final BigInt lightning;
  BigInt get total => onchain + leaves + lightning;
}

/// Every Sequentia asset held on any rail, each with its figure. No asset comes
/// first: the order is the caller's.
List<AssetFigure> assetFigures({
  required Map<String, BigInt> onchain,
  Map<String, BigInt> leaves = const {},
  Map<String, BigInt> lightning = const {},
}) {
  final ids = <String>{...onchain.keys, ...leaves.keys, ...lightning.keys};
  return [
    for (final id in ids)
      AssetFigure(
        id: id,
        onchain: onchain[id] ?? BigInt.zero,
        leaves: leaves[id] ?? BigInt.zero,
        lightning: lightning[id] ?? BigInt.zero,
      ),
  ];
}

/// The headline: every holding valued in the reference unit and summed, every asset
/// on equal terms. [value] answers a holding's value, or null when it has no price;
/// the total is null when nothing held can be priced.
double? headlineTotal(Iterable<({String key, BigInt atoms})> holdings, double? Function(String key, BigInt atoms) value) {
  double sum = 0;
  var any = false;
  for (final h in holdings) {
    if (h.atoms <= BigInt.zero) continue;
    final v = value(h.key, h.atoms);
    if (v != null) {
      sum += v;
      any = true;
    }
  }
  return any ? sum : null;
}
