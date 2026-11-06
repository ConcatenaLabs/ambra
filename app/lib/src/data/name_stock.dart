import 'receive_index.dart';

/// The stock of receive codes a wallet leaves with its payment name (lnaddr.dart): which addresses
/// they use, so that a payer who looks the name up while the wallet is closed gets a new code, and
/// a wallet restored from its phrase still finds every payment made to any of them. The web
/// wallet's `name-stock.js`, the same rule: change both together (and the browser extension's copy).
///
/// Each code in the stock is a full receive code at an address of its own, signed by the name's
/// key. The name service hands each one out once. The wallet tops the stock up to [defaultStockSize]
/// whenever it is open, and replaces a code whose single-use Sequentia part lapses within
/// [stockMarginS].
///
/// Every address a stocked code uses is inside the window [nextReceiveIndex] keeps New code in:
/// from the first address neither chain has seen paid through the [receiveGap] after it. A scan
/// from the phrase alone reads [receiveGap] addresses past the last one paid, so a payment to any
/// code ever stocked is found. The window only moves forward, so an address inside it when its code
/// was made stays inside what a restore reads. When the window holds no address the stock and the
/// screen are not already using, the stock reuses the address handed out longest ago: an address is
/// used twice before the stock ever walks past the gap.

/// How many codes a wallet leaves with the service.
const defaultStockSize = 10;

/// A stocked code whose Sequentia part lapses within this is replaced.
const stockMarginS = 12 * 3600;

/// How many indices handed out the wallet remembers, most recent last.
const handedKeep = 64;

/// The indices for [count] new codes: inside [nextUnused] .. [nextUnused] + [gap] - 1, none of
/// [held] (the indices of codes still in the stock, and the one on the screen), those never handed
/// out first in order, then the ones handed out longest ago ([handed], oldest first). Fewer than
/// [count] when the window has no more room.
List<int> pickStockIndices(int count,
    {int nextUnused = 0, Iterable<int?> held = const [], List<int> handed = const [], int gap = receiveGap}) {
  final first = nextUnused < 0 ? 0 : nextUnused;
  final busy = held.whereType<int>().toSet();
  final window = [for (var i = first; i < first + gap; i++) if (!busy.contains(i)) i];
  final last = <int, int>{};
  for (var at = 0; at < handed.length; at++) {
    last[handed[at]] = at;
  }
  window.sort((a, b) {
    final c = (last[a] ?? -1).compareTo(last[b] ?? -1);
    return c != 0 ? c : a.compareTo(b);
  });
  return window.take(count < 0 ? 0 : count).toList();
}

/// One code this wallet made for the stock: its address index and when its Sequentia part lapses.
typedef StockCode = ({int index, int? until});

/// What a top-up does, from the stock the wallet made ([mine]: id -> code), what the service still
/// holds of it ([held]: ids) and the time: which codes were handed out since ([served]), which to
/// take back ([drop]: still held, lapsing within the margin), which stay ([keep]) and how many to
/// make ([make]). Ids the service holds that the wallet did not make (a copy of the wallet open
/// elsewhere) count toward the stock and are left alone.
({List<String> served, List<String> drop, List<String> keep, int make}) planTopUp({
  required Map<String, StockCode> mine,
  required List<String> held,
  required int nowS,
  int size = defaultStockSize,
  int margin = stockMarginS,
}) {
  final at = held.toSet();
  final served = <String>[], drop = <String>[], keep = <String>[];
  mine.forEach((id, c) {
    if (!at.contains(id)) {
      served.add(id);
    } else if (c.until != null && c.until! - nowS < margin) {
      drop.add(id);
    } else {
      keep.add(id);
    }
  });
  final others = held.where((id) => !mine.containsKey(id)).length;
  final make = size - keep.length - others;
  return (served: served, drop: drop, keep: keep, make: make < 0 ? 0 : make);
}
