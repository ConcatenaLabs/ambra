/// The swap composer's leaf rail (developer mode): the settlement rail a leg is on, and
/// what a choice with a leaf in it settles as. The same rules as the web wallet's
/// settlement router and leaf rail (`settlement-router.mjs`, `leaf-rail.js`):
///
///   Market, pay Leaf, receive Leaf  a take from leaves of an on-chain order: the
///                                   operator's round spends the order, pays its maker
///                                   on the chain and gives this wallet a leaf. Beside
///                                   it, accepting another wallet's in-tree swap offer.
///   Limit, pay Leaf, receive Leaf   an in-tree swap offered to another wallet that holds
///                                   leaves: one reassignment in the tree.
///
/// Every other shape with a leaf is refused, with the reason: BTC is never a leaf (a pair
/// with BTC has no Leaf choice), a leaf settles with Lightning only through the
/// operator's gateway, and a trade that gives a leaf is paid from leaves. Every amount,
/// fee and refusal of a leaf is the leaf library's; nothing here decides one.
library;

import 'dart:convert';

import 'swap_route.dart' show kBtcSentinel;

/// The rail one leg of a trade settles on.
enum SettleRail { chain, ln, leaf }

/// The composer's older yes/no Lightning preference, read from a rail: a leaf reads as
/// on-chain there, so the book and the quote render as for the on-chain book, while the
/// leaf rail's own panel settles it.
bool? railLn(SettleRail? r) => r == null ? null : r == SettleRail.ln;

/// A rail from the yes/no Lightning preference (never a leaf).
SettleRail? railFromLn(bool? ln) => ln == null ? null : (ln ? SettleRail.ln : SettleRail.chain);

/// The words of the leaf rail, the same as the web wallet's.
class LeafWords {
  static const button = 'Leaf';
  static const btc = 'BTC is never a leaf: it settles over Lightning or on the chain. Leaves trade two Sequentia assets.';
  static const join = 'Join a leaf operator in the Leaves screen to pay from leaves.';
  static const payToo = 'A trade that gives you a leaf is paid from leaves: choose Leaf to pay from too.';
  static const chain =
      'An order placed on the chain from leaves is made in the web wallet or the browser wallet; here a leaf trades with another wallet\'s leaves or takes an on-chain order.';
  static const ln =
      'A leaf settles with Lightning only through the operator\'s gateway, which this composer does not run: choose Leaf or On-chain on both sides.';
}

/// Whether the Leaf choice is offered: developer mode, an operator joined, two Sequentia
/// assets. `usable` is false (with the reason) when it is shown but cannot be chosen yet.
({bool offered, bool usable, String? why}) leafRailOffered({
  required bool dev,
  required bool joined,
  String? pay,
  String? recv,
}) {
  if (!dev || pay == null || recv == null || pay == recv) return (offered: false, usable: false, why: null);
  if (pay == kBtcSentinel || recv == kBtcSentinel) return (offered: false, usable: false, why: LeafWords.btc);
  if (!joined) return (offered: true, usable: false, why: LeafWords.join);
  return (offered: true, usable: true, why: null);
}

enum LeafShapeKind { none, pending, take, swap, refused }

/// What the composer's choices settle as on the leaf rail.
({LeafShapeKind kind, String? why}) leafShape({
  String? pay,
  String? recv,
  SettleRail? payRail,
  SettleRail? recvRail,
  required String mode,
}) {
  if (payRail != SettleRail.leaf && recvRail != SettleRail.leaf) return (kind: LeafShapeKind.none, why: null);
  if (pay == kBtcSentinel || recv == kBtcSentinel) return (kind: LeafShapeKind.refused, why: LeafWords.btc);
  if (payRail == null || recvRail == null) return (kind: LeafShapeKind.pending, why: null);
  if (payRail == SettleRail.ln || recvRail == SettleRail.ln) return (kind: LeafShapeKind.refused, why: LeafWords.ln);
  if (payRail != SettleRail.leaf) return (kind: LeafShapeKind.refused, why: LeafWords.payToo);
  if (recvRail == SettleRail.chain) return (kind: LeafShapeKind.refused, why: LeafWords.chain);
  return (kind: mode == 'post' ? LeafShapeKind.swap : LeafShapeKind.take, why: null);
}

BigInt _big(Object? v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;

/// Whether the round can take a relay offer from leaves: a transparent covenant order
/// under the tapscript terms (the unified book's `leaf_take`). A plain intent needs its
/// maker live on the chain, a blinded order hides the amounts the round must pay, and an
/// order under the Simplicity template is not one the round fills.
bool leafTakeable(Map<String, dynamic> o) {
  final cov = o['covenant'] ?? o['Covenant'];
  final conf = o['confidential'] == true || o['Confidential'] == true;
  return cov is Map && !conf;
}

/// The order a take from leaves fills: of the relay's offers (both orientations of the
/// pair, in the relay's own JSON), the verified ones selling what the wallet receives for
/// what it pays that the round can take, cheapest per atom received first; one holding at
/// least `amount` when there is one.
Map<String, dynamic>? bestLeafOrder(
  List<Map<String, dynamic>> offers, {
  required String pay,
  required String recv,
  required BigInt amount,
  bool Function(Map<String, dynamic>)? verified,
}) {
  final mine = offers
      .where((o) =>
          (o['offer_asset'] ?? o['offerAsset']) == recv &&
          (o['want_asset'] ?? o['wantAsset']) == pay &&
          leafTakeable(o) &&
          (verified == null || verified(o)) &&
          _big(o['offer_amount'] ?? o['offerAmount']) > BigInt.zero &&
          _big(o['want_amount'] ?? o['wantAmount']) > BigInt.zero)
      .toList();
  double price(Map<String, dynamic> o) =>
      _big(o['want_amount'] ?? o['wantAmount']).toDouble() / _big(o['offer_amount'] ?? o['offerAmount']).toDouble();
  mine.sort((a, b) => price(a).compareTo(price(b)));
  if (mine.isEmpty) return null;
  final holding = mine.where((o) => _big(o['offer_amount'] ?? o['offerAmount']) >= amount);
  return holding.isNotEmpty ? holding.first : mine.first;
}

/// The approval rows, from the library's answers. `amt(asset, atoms)` names an amount.
List<(String, String)> takeRows(Map<String, dynamic> q, String Function(String, Object?) amt, {int? windowSeconds}) => [
      ('Order', '${q['order']} (on the chain; the wallet found it on its own node, unspent and final)'),
      ('You get', '${amt('${q['asset_a']}', q['filled'])} as a leaf, in the round\'s batch, once the round is final'),
      ('You give', '${amt('${q['asset_b']}', q['gives'])}: the price and the operator\'s fee, from your leaves'),
      ('Price', '${amt('${q['asset_b']}', q['price'])}, paid on the chain to the order\'s maker'),
      ('Operator\'s fee', '${amt('${q['asset_b']}', q['fee'])} (its schedule for this asset)'),
      (
        'Order after the fill',
        _big(q['remainder']) > BigInt.zero ? '${amt('${q['asset_a']}', q['remainder'])} rests again on the chain, under the same terms' : 'filled whole'
      ),
      if (q['pays_itself_first'] == true) ('First', 'no single leaf holds exactly ${amt('${q['asset_b']}', q['gives'])}: the wallet first pays itself one out of round'),
      (
        'Your part',
        'once the operator builds the round, this wallet hands over the forfeit of the coin it gives, within ${windowSeconds != null ? '${(windowSeconds / 60).round()} minutes' : 'the operator\'s window'}. Keep Ambra open until then. If it does not come in time, the take is voided and the coin is yours again.'
      ),
    ];

List<(String, String)> swapReadRows(Map<String, dynamic> r, String Function(String, Object?) amt) {
  Map<String, dynamic> m(String k) => Map<String, dynamic>.from((r[k] as Map?) ?? const {});
  final change = m('change');
  final d = m('dates');
  return [
    ('You get', '${amt('${m('gets')['asset']}', m('gets')['value'])} as a leaf, in one reassignment both wallets sign and the operator co-signs'),
    ('You give', '${amt('${m('gives')['asset']}', m('gives')['value'])} from your leaves'),
    ('You pay', '${amt('${m('pays')['asset']}', m('pays')['margins'])}: the margins your coins leave for the transfer\'s fees'),
    ('The other wallet pays', '${amt('${m('maker_pays')['asset']}', m('maker_pays')['margin'])} as the reassignment\'s margin'),
    ('Change', _big(change['value']) > BigInt.zero ? '${amt('${change['asset']}', change['value'])} back as a leaf' : 'none'),
    if (d['exit_deadline'] != null)
      (
        'Dates',
        'the coins you get rest on every coin the swap spends: take them on the chain by ${DateTime.fromMillisecondsSinceEpoch((d['exit_deadline'] as num).toInt() * 1000, isUtc: true).toIso8601String().replaceFirst('T', ' ').split('.').first} UTC (median time) at the latest'
      ),
  ];
}

List<(String, String)> swapOfferRows(Map<String, dynamic> o, String Function(String, Object?) amt) {
  Map<String, dynamic> m(String k) => Map<String, dynamic>.from((o[k] as Map?) ?? const {});
  final pays = m('pays');
  return [
    ('You give', '${amt('${m('gives')['asset']}', m('gives')['value'])} from your leaves'),
    ('You get', '${amt('${m('gets')['asset']}', m('gets')['value'])} as a leaf'),
    ('You pay', '${amt('${pays['asset']}', pays['margin'])} as the reassignment\'s margin, and ${amt('${pays['asset']}', pays['margins'])} the margins your coins leave'),
    ('Your coins', 'held for this offer, signed for nothing, until it completes or you cancel it'),
  ];
}

/// A copy of a relay offer with its covenant's byte fields as hex, which the core's offer
/// verifier reads (the relay serves them in base64). Used only to check the signature: the
/// leaf library is handed the relay's own JSON.
Map<String, dynamic> offerForVerify(Map<String, dynamic> o) {
  final cov = o['covenant'] ?? o['Covenant'];
  if (cov is! Map) return o;
  String hexOf(Object? v) {
    final s = '${v ?? ''}';
    if (RegExp(r'^[0-9a-fA-F]*$').hasMatch(s) && s.length.isEven) return s;
    try {
      return base64Decode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    } catch (_) {
      return s;
    }
  }

  final c = Map<String, dynamic>.from(cov);
  for (final k in ['maker_prog', 'makerProg', 'maker_x', 'makerX', 'internal_key', 'internalKey']) {
    if (c[k] != null) c[k] = hexOf(c[k]);
  }
  for (final k in ['merkle_path', 'merklePath']) {
    if (c[k] is List) c[k] = (c[k] as List).map(hexOf).toList();
  }
  return {...o, 'covenant': c};
}
