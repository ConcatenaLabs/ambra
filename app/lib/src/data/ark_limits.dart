import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How much default mode keeps where it pays in seconds, in USD: the web wallet's `ark-limits.js`
/// in Dart, the same function names and the same rules (change the two together). Only the
/// Bitcoin ark is held to figures: its coins can be swept at expiry and leave only when its server
/// has BTC to spare, both out of our hands. Sequentia's Ark has no sweep, its operator's capital
/// comes back within a round, and a double-spend of an unrefreshed coin is covered by the
/// operator's bond: no figures there.
///
/// Three figures:
///   board   the resting level: the wallet moves BTC there from its own address, in one move back
///           up to it, only once the ark holds less than a quarter of it ([kRefillBelow]);
///   hold    the ceiling: once the ark holds this much, everything above `board` moves out to the
///           wallet's own address in one move, so it is back at `board`;
///   direct  one payment of this much or more is paid to the address straight away, never to the
///           ark: a large payment would only be moved out again, and the ark's server has no bond
///           behind what it co-signs.
/// BTC: 1500, 3000, 1500. Payments in and out over Lightning are held to the limit the operator
/// publishes instead (ln_max_payment.dart [lnMaxPayment]).
///
/// A debug build may set other figures (`--dart-define=AMBRA_ARK_LIMITS=<json>`, the shape of
/// [kArkLimits]: any figure left out keeps its default, null for no limit), as the web wallet's
/// `window.SEQ_ARK_LIMITS`; a release build always holds the defaults ([arkLimitsNow]).
class ArkFigures {
  const ArkFigures({required this.board, required this.hold, required this.direct});
  final double? board, hold, direct;

  @override
  bool operator ==(Object other) =>
      other is ArkFigures && other.board == board && other.hold == hold && other.direct == direct;
  @override
  int get hashCode => Object.hash(board, hold, direct);
  @override
  String toString() => '{board: $board, hold: $hold, direct: $direct}';
}

class ArkLimits {
  const ArkLimits({required this.btc, required this.asset});
  final ArkFigures btc, asset;

  @override
  bool operator ==(Object other) => other is ArkLimits && other.btc == btc && other.asset == asset;
  @override
  int get hashCode => Object.hash(btc, asset);
}

const kArkLimits = ArkLimits(
  btc: ArkFigures(board: 1500, hold: 3000, direct: 1500),
  asset: ArkFigures(board: null, hold: null, direct: null),
);

/// The wallet moves BTC into the ark only once it holds less than this share of `board`: one move
/// back up to `board` every ~three quarters of it spent, never a board after each payment.
const kRefillBelow = 0.25;

BigInt _big(Object? v) {
  if (v is BigInt) return v;
  if (v is int) return BigInt.from(v);
  return BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
}

/// The JS `figure`: null stays null (no limit); a number of at least 0 is taken; anything else
/// (missing, not a number, negative) keeps the default [d].
double? _figure(Object? v, bool given, double? d) {
  if (given && v == null) return null;
  final n = v is num ? v.toDouble() : (v is String && v.isNotEmpty ? double.tryParse(v) : null);
  return n != null && n.isFinite && n >= 0 ? n : d;
}

/// The limits a page (a debug build) set, each figure checked. `hold` is never under `board`.
ArkLimits arkLimits(Object? page) {
  final p = page is Map ? page : const {};
  ArkFigures one(String k, ArkFigures d) {
    final q = p[k] is Map ? p[k] as Map : const {};
    final board = _figure(q['board'], q.containsKey('board'), d.board);
    var hold = _figure(q['hold'], q.containsKey('hold'), d.hold);
    if (hold != null && board != null && hold < board) hold = board;
    return ArkFigures(board: board, hold: hold, direct: _figure(q['direct'], q.containsKey('direct'), d.direct));
  }

  return ArkLimits(btc: one('btc', kArkLimits.btc), asset: one('asset', kArkLimits.asset));
}

const _override = String.fromEnvironment('AMBRA_ARK_LIMITS');

/// The limits this build holds: the defaults, or in a debug build those `AMBRA_ARK_LIMITS` names.
ArkLimits arkLimitsNow() {
  if (kReleaseMode || _override.isEmpty) return kArkLimits;
  try {
    return arkLimits(jsonDecode(_override));
  } catch (_) {
    return kArkLimits;
  }
}

/// `usd` dollars of an asset priced `price` USD per whole unit with `precision` decimals, in atoms
/// (rounded down), or null when either is not a number (no limit can be told).
BigInt? usdAtoms(num? usd, num? price, int? precision) {
  if (usd == null || price == null) return null;
  final u = usd.toDouble(), p = price.toDouble();
  if (!(u >= 0) || !(p > 0) || !u.isFinite || !p.isFinite) return null;
  // Whole cents and a price in millionths keep the sum in integers.
  final cents = BigInt.from((u * 100).floor()), micro = BigInt.from((p * 1e6).round());
  if (micro <= BigInt.zero) return null;
  return cents * BigInt.from(10).pow(precision ?? 0) * BigInt.from(10000) ~/ micro;
}

/// How much the wallet moves into the ark by itself now, holding [held] atoms there: nothing while
/// it holds [refill] of the limit or more, else the rest up to the limit, in one move. Atoms (zero
/// when nothing moves), or null for no limit (none set, or the kind unpriced).
BigInt? boardRoom({required Object? held, required num? limitUsd, required num? price, required int precision, double refill = kRefillBelow}) {
  if (limitUsd == null) return null;
  final cap = usdAtoms(limitUsd, price, precision);
  if (cap == null) return null;
  if (_big(held) * BigInt.from(10000) >= cap * BigInt.from((refill * 10000).round())) return BigInt.zero;
  final left = cap - _big(held);
  return left > BigInt.zero ? left : BigInt.zero;
}

/// What moves out to the wallet's own address, holding [held] atoms: once the ark holds `hold`,
/// everything above `board`, in one move (so never less than `hold - board`); else nothing.
BigInt moveOutAtoms({required Object? held, required num? board, required num? hold, required num? price, required int precision}) {
  if (board == null || hold == null) return BigInt.zero;
  final b = usdAtoms(board, price, precision), h = usdAtoms(hold, price, precision);
  if (b == null || h == null || _big(held) < h) return BigInt.zero;
  final over = _big(held) - b;
  return over > BigInt.zero ? over : BigInt.zero;
}

/// The USD from which one payment goes to the address rather than the ark, or null for never.
double? directUsd(ArkFigures l) => l.direct;

/// Whether a payment of [atoms] goes to the address straight away ([directUsd] or more).
bool goesToAddress({required Object? atoms, required double? direct, required num? price, required int precision}) {
  final usd = direct;
  if (usd == null || !(usd > 0)) return false;
  final at = usdAtoms(usd, price, precision);
  return at != null && _big(atoms) >= at;
}

/// A USD figure as the words write it: whole dollars grouped by thousands ("1,500"), cents only
/// when there are any (the web wallet's `toLocaleString()`).
String usdFigure(double usd) {
  final whole = usd.truncate();
  final s = whole.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final cents = ((usd - whole) * 100).round();
  return cents == 0 ? s : '$s.${cents.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '')}';
}
