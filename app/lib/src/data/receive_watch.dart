/// What Receive says while it is open about a payment coming in: "Payment arriving…", then
/// "Received `amount` `TICKER`.", so whoever holds up the QR code sees the payment land without
/// leaving the screen. The web wallet's `receive-watch.js` (sequentia-web-wallet
/// `docs/DEFAULT_MODE.md`, "Receive").
///
/// It reads only the figures Balance shows. For each asset it is given what counts now
/// (`settled`) and what is on its way and not counted yet (`arriving`). The watch keeps what they
/// were when Receive opened, or at the last payment it reported, and compares each reading with it:
///
///   - an asset whose settled and arriving parts together went up while some of it is still on its
///     way: a payment is arriving;
///   - an asset whose settled and arriving parts together went up, with nothing of it on its way any
///     more: received, the amount being what they rose by. Only value the wallet did not hold is a
///     payment: coins of its own that come home (counted as arriving while they do) or that were on
///     their way when Receive opened only move from arriving to settled, and say nothing;
///   - an asset that went down (a payment out): its new figure is the base from then on, so a
///     payment received after it is still seen whole;
///   - one asset down and another up in the same reading: a trade settling, not a payment: nothing
///     is said, and the reading is the new base.
///
/// A move of the wallet's own (coins on the chain taken in for instant payments, BTC moved to
/// where it is sent in seconds) leaves an asset's total where it was, so it says nothing.
library;

/// One asset's figure: what counts now, and what is on its way.
typedef ReceiveFigure = ({BigInt settled, BigInt arriving});

/// What Receive says: a payment of [asset] arriving, or received for [atoms] of it.
class ReceiveState {
  const ReceiveState.arriving(this.asset)
      : kind = 'arriving',
        atoms = null;
  const ReceiveState.received(this.asset, BigInt this.atoms) : kind = 'received';

  /// 'arriving' or 'received'.
  final String kind;
  final String asset;
  final BigInt? atoms;

  bool get received => kind == 'received';

  @override
  bool operator ==(Object other) =>
      other is ReceiveState && other.kind == kind && other.asset == asset && other.atoms == atoms;

  @override
  int get hashCode => Object.hash(kind, asset, atoms);

  @override
  String toString() => 'ReceiveState($kind, $asset${atoms == null ? '' : ', $atoms'})';
}

class ReceiveWatch {
  Map<String, ReceiveFigure>? _base;
  ReceiveState? _state;

  static final ReceiveFigure _zero = (settled: BigInt.zero, arriving: BigInt.zero);

  bool get watching => _base != null;
  ReceiveState? get state => _state;

  /// Receive opened: what the wallet holds now is the base, and nothing is said yet.
  ReceiveState? start(Map<String, ReceiveFigure> snap) {
    _base = Map.of(snap);
    _state = null;
    return _state;
  }

  void stop() {
    _base = null;
    _state = null;
  }

  /// A new reading of the figures. -> the state to show.
  ReceiveState? update(Map<String, ReceiveFigure> snap) {
    final base = _base;
    if (base == null) return null;
    final now = Map.of(snap);
    final up = <String>[], down = <String>[];
    for (final a in {...base.keys, ...now.keys}) {
      final b = base[a] ?? _zero, n = now[a] ?? _zero;
      final d = (n.settled + n.arriving) - (b.settled + b.arriving);
      if (d > BigInt.zero) up.add(a);
      if (d < BigInt.zero) down.add(a);
    }
    if (down.isNotEmpty && up.any((a) => !down.contains(a))) {
      _base = now;
      return _state;
    }
    for (final a in down) {
      base[a] = now[a] ?? _zero;
    }
    String? arriving;
    ({String asset, BigInt atoms})? received;
    for (final a in up) {
      if (down.contains(a)) continue;
      final b = base[a] ?? _zero, n = now[a] ?? _zero;
      if (n.arriving > BigInt.zero) {
        arriving ??= a;
        continue;
      }
      final rise = (n.settled + n.arriving) - (b.settled + b.arriving);
      if (received == null || rise > received.atoms) received = (asset: a, atoms: rise);
    }
    if (received != null) {
      _state = ReceiveState.received(received.asset, received.atoms);
      _base = now;
    } else if (arriving != null) {
      _state = ReceiveState.arriving(arriving);
    }
    return _state;
  }
}
