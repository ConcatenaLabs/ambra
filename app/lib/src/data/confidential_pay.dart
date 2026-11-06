/// A payment to a confidential address that hides its amount: the web wallet's
/// `confidential-pay.js`, ported (sequentia-web-wallet docs/DEFAULT_MODE.md, Send).
///
/// A blinded output hides nothing by itself: when every other value of the transaction is in the
/// clear (its inputs, its change, its fee), the payment is what is left. So the payment is made
/// with a second blinded output, to the wallet's own confidential address, which takes what the
/// inputs hold beyond the payment and its fee: anyone reading the chain then knows only the two
/// together.
///
/// What the wallet holds for instant payments is paid out only in the clear, so when the chain does
/// not hold enough the wallet first moves coins out to its own address, in an amount that does not
/// give the payment away: all it holds of the asset there, or the smallest power of ten above what
/// the payment needs (at least one whole unit), whichever is smaller.
///
/// The asset is hidden only among the assets of the inputs. This wallet spends only coins of the
/// asset paid, so the review says the asset can be seen.
library;

/// A margin for the network fees of [vbytes] of transactions, in atoms of an asset whose published
/// rate is [rate], at the wallet's default fee rate (2,000 per kvB), twice over: what is moved for
/// them is never short, and what is left stays the wallet's.
BigInt feeMarginAtoms(BigInt rate, {int vbytes = 1000}) {
  if (rate <= BigInt.zero) throw ArgumentError('no rate');
  final rfa = BigInt.from(2000 * vbytes * 2 ~/ 1000);
  return (rfa * BigInt.from(100000000) + rate - BigInt.one) ~/ rate;
}

/// The smallest power of ten of atoms at least [need], and at least one whole unit of an asset of
/// [precision] decimals.
BigInt bucketAtoms(BigInt need, int precision) {
  var b = BigInt.from(10).pow(precision < 0 ? 0 : precision);
  while (b < need) {
    b *= BigInt.from(10);
  }
  return b;
}

/// What to do for a confidential payment ([confidentialPlan]): move [move] atoms out first (zero:
/// none), and whether the amount is then hidden; or, with [short] set, the wallet holds that much
/// too little in all.
class ConfidentialPlan {
  const ConfidentialPlan({required this.move, required this.hides, this.short});
  final BigInt move;
  final bool hides;
  final BigInt? short;
  @override
  bool operator ==(Object other) => other is ConfidentialPlan && other.move == move && other.hides == hides && other.short == short;
  @override
  int get hashCode => Object.hash(move, hides, short);
  @override
  String toString() => short != null ? 'short $short' : 'move $move hides $hides';
}

/// What to do for a confidential payment of [amount] atoms whose fee needs [margin], with
/// [onchain] held on the chain (spendable) and [instant] held for instant payments; [minLeaf] is
/// the least the operator pays out of the asset. The wallet's own confidential output must take at
/// least [margin] for the amount to be hidden.
ConfidentialPlan confidentialPlan({
  required BigInt amount,
  required BigInt margin,
  required BigInt onchain,
  BigInt? instant,
  BigInt? minLeaf,
  int precision = 8,
}) {
  final inst = instant ?? BigInt.zero;
  final least = minLeaf ?? BigInt.zero;
  final pays = amount + margin;
  final hidden = pays + margin;
  if (onchain >= hidden) return ConfidentialPlan(move: BigInt.zero, hides: true);
  final total = onchain + inst;
  bool canMove(BigInt x) => x > BigInt.zero && x <= inst && x >= least;
  if (total >= hidden) {
    final bucket = bucketAtoms(hidden, precision);
    final cap = total < bucket ? total : bucket; // all of it, or the round amount
    final target = cap > hidden ? cap : hidden;
    var move = target - onchain;
    if (move < least) move = least;
    if (canMove(move)) return ConfidentialPlan(move: move, hides: true);
  }
  if (onchain >= pays) return ConfidentialPlan(move: BigInt.zero, hides: false);
  if (total >= pays && canMove(inst)) return ConfidentialPlan(move: inst, hides: total >= hidden);
  if (total >= pays && canMove(least) && onchain + least >= pays) {
    return ConfidentialPlan(move: least, hides: onchain + least >= hidden);
  }
  final s = pays - total;
  return ConfidentialPlan(move: BigInt.zero, hides: false, short: s > BigInt.zero ? s : BigInt.one);
}

/// The wallet's own confidential output beside the payment: what the chain holds of the asset
/// beyond the payment and the fee margin (zero when that is too little to hide the amount).
BigInt ownShare({required BigInt amount, required BigInt margin, required BigInt onchain}) {
  final x = onchain - amount - margin;
  return x >= margin ? x : BigInt.zero;
}

/// What the wallet can move out now, by the leaf library's own refusal of a larger move: "the
/// wallet's live coins of asset … hold N and an offboard of A and its fee need F …". Coins
/// the library holds but cannot pay out (a channel's balance, a coin not final yet) count in the
/// balance and not here. The atoms (the coins less the fee such a move pays), or null when the
/// refusal says something else. The web wallet's `liveFromRefusal`.
BigInt? liveFromRefusal(String message) {
  final m = RegExp(r'live coins of asset \S+ hold (\d+) and an offboard of (\d+) and its fee need (\d+)').firstMatch(message);
  if (m == null) return null;
  final hold = BigInt.parse(m.group(1)!), fee = BigInt.parse(m.group(3)!) - BigInt.parse(m.group(2)!);
  return hold > fee ? hold - fee : BigInt.zero;
}
