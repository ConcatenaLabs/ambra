/// One asset's figure across everything the wallet holds of it: on-chain, leaves,
/// Lightning (the wallet's own channels, the reserve included) and, for the Sequence
/// token, what is staked (bonded stakes, unbonding outputs not yet returned, the
/// delegation record). The figure is their sum, in both modes; user mode shows the
/// parts one tap away ([splitParts]), developer mode beside each row. Native BTC is
/// never a leaf (a tree on Sequentia holds no BTC) and never staked.
class AssetFigure {
  AssetFigure(
      {required this.id, required this.onchain, required this.leaves, required this.lightning, BigInt? staked})
      : staked = staked ?? BigInt.zero;
  final String id;
  final BigInt onchain;
  final BigInt leaves;
  final BigInt lightning;
  final BigInt staked;
  BigInt get total => onchain + leaves + lightning + staked;
}

/// Every Sequentia asset held anywhere, each with its figure. No asset comes first:
/// the order is the caller's.
List<AssetFigure> assetFigures({
  required Map<String, BigInt> onchain,
  Map<String, BigInt> leaves = const {},
  Map<String, BigInt> lightning = const {},
  Map<String, BigInt> staked = const {},
}) {
  final ids = <String>{...onchain.keys, ...leaves.keys, ...lightning.keys, ...staked.keys};
  return [
    for (final id in ids)
      AssetFigure(
        id: id,
        onchain: onchain[id] ?? BigInt.zero,
        leaves: leaves[id] ?? BigInt.zero,
        lightning: lightning[id] ?? BigInt.zero,
        staked: staked[id] ?? BigInt.zero,
      ),
  ];
}

/// The parts of a figure in the plain words user mode shows one tap away, only the
/// parts held: On-chain, Instant (leaves: paid in seconds), Lightning, Staked. User mode
/// ([dev] false) shows Staked alone: the split by rail is developer mode's (the default-mode
/// contract, sequentia-web-wallet `docs/DEFAULT_MODE.md`).
List<(String, BigInt)> splitParts(AssetFigure f, {bool dev = true}) => [
      ('On-chain', f.onchain),
      ('Instant', f.leaves),
      ('Lightning', f.lightning),
      ('Staked', f.staked),
    ].where((p) => p.$2 > BigInt.zero && (dev || p.$1 == 'Staked')).toList();

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
