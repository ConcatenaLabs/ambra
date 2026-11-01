/// What the wallet holds that cannot move before a date: a vesting allocation, such as the
/// tokens of a sale that vests.
///
/// A vesting distribution pays a key of the wallet a coin nobody can move before its vest date.
/// The leaf library's `claims` lists it (state `vesting`, `vest` a median time, `vests` the date
/// in words); from that date the library's `care` takes it up by itself and it is an ordinary
/// coin, arriving until that is final. Until then default mode shows it under the asset's figure
/// ("100 ORNG vests on 3 November 2026"), counts it in the figure and the headline, and never as
/// what can be spent: every Max leaves it out, and an action that needs it says from when it can
/// be used ([notVestedSentence]). `care` and `claim` list a vesting claim without its asset or
/// value, so only `claims` is read for this.
///
/// The web wallet's `default-arca.js` (the default-mode contract, sequentia-web-wallet
/// `docs/DEFAULT_MODE.md`, Balance and Send): change the two together.
library;

import 'default_words.dart';
import 'format.dart';

/// How often the wallet reads its claims at most (and once after each care).
const Duration kClaimsEvery = Duration(minutes: 2);

/// One line under an asset's figure: what of [asset] vests on one day.
class VestingLot {
  const VestingLot({required this.asset, required this.vest, required this.vests, required this.atoms});

  final String asset;

  /// The earliest median time (unix seconds) of the claims on this line.
  final int vest;

  /// That day in words, as the library writes it: "3 November 2026".
  final String vests;
  final BigInt atoms;

  @override
  String toString() => '$atoms of $asset vests on $vests';
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// The UTC date of unix time [t] in words, as the library writes it: "3 November 2026".
String dateWords(int t) {
  final d = DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true);
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

BigInt _big(Object? v) => v is int ? BigInt.from(v) : (BigInt.tryParse('${v ?? ''}') ?? BigInt.zero);

/// A `claims` answer -> what vests, one entry for each asset and day (claims vesting on the same
/// day are one line), earliest first. A claim the wallet holds already, or one without an asset,
/// a value or a date, is not counted.
List<VestingLot> vestingLots(Object? claims) {
  final by = <String, VestingLot>{};
  for (final c in claims is List ? claims : const []) {
    if (c is! Map || c['state'] != 'vesting' || c['held'] != null || c['asset'] is! String) continue;
    final vest = c['vest'] is num ? (c['vest'] as num).toInt() : int.tryParse('${c['vest']}') ?? 0;
    final atoms = _big(c['value']);
    if (vest <= 0 || atoms <= BigInt.zero) continue;
    final words = c['vests'] is String && (c['vests'] as String).isNotEmpty ? c['vests'] as String : dateWords(vest);
    final asset = c['asset'] as String;
    final k = '$asset|$words';
    final e = by[k];
    by[k] = e == null
        ? VestingLot(asset: asset, vest: vest, vests: words, atoms: atoms)
        : VestingLot(asset: asset, vest: vest < e.vest ? vest : e.vest, vests: words, atoms: e.atoms + atoms);
  }
  final out = by.values.toList()
    ..sort((a, b) => a.vest != b.vest ? a.vest.compareTo(b.vest) : a.asset.compareTo(b.asset));
  return out;
}

/// The lines of one asset, earliest first.
List<VestingLot> vestingFor(List<VestingLot> lots, String asset) => [for (final l in lots) if (l.asset == asset) l];

/// What of each asset vests later, in atoms.
Map<String, BigInt> vestingAtomsOf(List<VestingLot> lots) {
  final out = <String, BigInt>{};
  for (final l in lots) {
    out[l.asset] = (out[l.asset] ?? BigInt.zero) + l.atoms;
  }
  return out;
}

/// Whether [asked] atoms of [asset] need what has not vested: more than [spendable], and no more
/// than what vests on top of it. Null, or the part of what is asked that cannot be spent now and
/// the earliest day from which all of it can be used. Asked for more than even that covers, it
/// is plainly not enough: null, for the action's own refusal.
({BigInt atoms, int vest, String vests})? vestingShort(List<VestingLot> lots, String asset, BigInt asked, BigInt spendable) {
  final s = spendable > BigInt.zero ? spendable : BigInt.zero;
  if (asked <= s) return null;
  final need = asked - s;
  var got = BigInt.zero;
  for (final l in vestingFor(lots, asset)) {
    got += l.atoms;
    if (got >= need) return (atoms: need, vest: l.vest, vests: l.vests);
  }
  return null;
}

/// The sentence every action that would spend [asset] says when [asked] needs what has not
/// vested ([vestingShort]), or null when it does not.
String? notVestedSentence(List<VestingLot> lots, String asset, BigInt asked, BigInt spendable,
    {required String ticker, required int precision}) {
  final v = vestingShort(lots, asset, asked, spendable);
  return v == null ? null : DefaultWords.notVested(formatAtoms('${v.atoms}', precision), ticker, v.vests);
}

/// A refusal of the network's for a coin that has not vested (the operator's code `vesting`, its
/// message naming the median time) in plain words, or null for any other.
String? vestingRefusal(String? code, String message) {
  if (code != 'vesting') return null;
  final m = RegExp(r'median time (\d+)').firstMatch(message);
  final t = m == null ? null : int.tryParse(m.group(1)!);
  return t == null ? DefaultWords.notVestedYet : DefaultWords.vestingRefused(dateWords(t));
}

/// Whether a reading of `claims` shows a claim whose vest date has passed that the wallet has not
/// taken up yet: care then runs at once rather than at its pace, so it becomes a coin by itself.
bool vestedOpen(Object? claims) =>
    (claims is List ? claims : const []).any((c) => c is Map && c['state'] == 'open' && c['held'] == null && c['vest'] != null);
