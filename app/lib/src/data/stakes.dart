import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as core;
import 'config.dart';

/// The Sequence token this wallet holds at its staking key (m/2/0): each bonded stake
/// under either lock a Sequentia wallet bonds with (the height lock of the web wallet
/// and the extension, the time lock of this app), each unbonding output not yet
/// returned to the wallet, and the delegation record. All of it is the holder's, so it
/// counts in the token's figure and in the headline, in both modes. A stake returned
/// to the wallet is on-chain again and counted there, once.
///
/// Read from the chain (`core.listStakes`, `core.findDelegation`), never stored as the
/// truth: a reorg can move any of it back. [refresh] reads at most every
/// [minInterval] unless forced; the stake screen forces a read when it opens and after
/// each step.
class StakeHoldings extends ChangeNotifier {
  StakeHoldings._();
  static final StakeHoldings instance = StakeHoldings._();

  static const minInterval = Duration(minutes: 5);

  /// Signers this device has delegated to (the stake screen keeps them): the hints a
  /// moved delegation record is found by.
  static const hintKey = 'seq.staking.signerHints';

  List<core.StakeEntry> _stakes = const [];
  core.DelegationRecord? _delegation;
  DateTime? _readAt;
  String? _error;
  Future<void>? _inFlight;

  List<core.StakeEntry> get stakes => _stakes;
  core.DelegationRecord? get delegation => _delegation;
  DateTime? get readAt => _readAt;
  String? get error => _error;

  /// Every atom of the Sequence token at the staking key.
  BigInt get stakedAtoms => stakedTotal(_stakes.map((s) => s.value), _delegation?.value);

  /// Read the stakes, and the delegation record unless [readDelegation] is false (the
  /// stake screen reads that itself with the pool board's signers as probes, then
  /// hands it to [setDelegation]).
  Future<void> refresh(String mnemonic, {bool force = false, bool readDelegation = true}) {
    final last = _readAt;
    if (!force && last != null && DateTime.now().difference(last) < minInterval) return Future.value();
    return _inFlight ??= _read(mnemonic, readDelegation).whenComplete(() => _inFlight = null);
  }

  Future<void> _read(String mnemonic, bool readDelegation) async {
    try {
      final s = await core.listStakes(
          mnemonic: mnemonic, esploraUrl: Backend.esplora, anchorUrl: Backend.anchorBase);
      _stakes = s;
      if (readDelegation) {
        _delegation = await core.findDelegation(
            mnemonic: mnemonic, esploraUrl: Backend.esplora, probeSigners: await _hints());
      }
      _readAt = DateTime.now();
      _error = null;
    } catch (e) {
      // The last reading stays: an explorer that is briefly away must not make the
      // stake disappear from the balance.
      _error = '$e';
    }
    notifyListeners();
  }

  void setDelegation(core.DelegationRecord? d) {
    _delegation = d;
    notifyListeners();
  }

  @visibleForTesting
  void debugSet(List<core.StakeEntry> stakes, {core.DelegationRecord? delegation}) {
    _stakes = stakes;
    _delegation = delegation;
    _readAt = DateTime.now();
    notifyListeners();
  }

  /// A different wallet opened on this phone: nothing of the last one's stays.
  void clear() {
    _stakes = const [];
    _delegation = null;
    _readAt = null;
    _error = null;
    notifyListeners();
  }

  static Future<List<String>> _hints() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getStringList(hintKey) ?? const [];
    } catch (_) {
      return const [];
    }
  }
}

/// The Sequence token at the staking key: every stake and unbonding output, and the
/// delegation record.
BigInt stakedTotal(Iterable<BigInt> stakes, BigInt? delegation) =>
    stakes.fold(BigInt.zero, (a, b) => a + b) + (delegation ?? BigInt.zero);

/// What a stake's line says, in plain words: where it stands and when it moves on.
/// [blockSeconds] is the chain's block spacing; [now] the phone's clock.
String stakeStatusText(core.StakeEntry s, {int? tip, int blockSeconds = 60, DateTime? now}) {
  final at = now ?? DateTime.now();
  String day(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${months[l.month - 1]} ${l.year}';
  }

  switch (s.state) {
    case 'pending':
      return s.lock.isEmpty ? 'Unbonding, waiting to confirm' : 'Waiting to confirm';
    case 'bonded':
      if (s.lock == 'time' && s.maturesAtTime != null) {
        final t = DateTime.fromMillisecondsSinceEpoch(s.maturesAtTime!.toInt() * 1000);
        return 'Locked until about ${day(t)}';
      }
      if (s.maturesAtHeight != null) {
        final left = tip == null ? null : s.maturesAtHeight! - 1 - tip;
        if (left != null && left > 0) {
          final when = at.add(Duration(seconds: left * blockSeconds));
          return 'Locked until block ${s.maturesAtHeight} (about ${day(when)})';
        }
        return 'Locked until block ${s.maturesAtHeight}';
      }
      return 'Locked';
    case 'unbondable':
      return 'Unlocked: you can unbond it';
    case 'unbonding':
      if (s.claimableAtAnchor != null && s.tipAnchor != null) {
        final left = s.claimableAtAnchor! - s.tipAnchor!;
        if (left > 0) {
          final when = at.add(Duration(minutes: left * 10));
          return 'Unbonding: can return to your wallet after Bitcoin block ${s.claimableAtAnchor} '
              '(about ${day(when)})';
        }
      }
      return s.height == null ? 'Unbonding, waiting to confirm' : 'Unbonding';
    case 'claimable':
      return 'Unbonded: ready to return to your wallet';
  }
  return s.state;
}
