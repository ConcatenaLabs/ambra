/// What a stake, a pool's membership or a mix needs on the chain, moved out of the Ark first.
///
/// Default mode holds what a person receives in the Ark (the leaves). A stake, a pool's
/// membership record and a mix are made from coins the wallet holds on the chain, so the wallet
/// moves what is missing out of the Ark to its own address by itself (the library's quoted
/// `offboard`), says so, and waits for it to arrive; the person then reviews and signs as always.
/// The web wallet's `ensureOnChain` (docs/DEFAULT_MODE.md "Stake, pools and Mix").
library;

import 'dart:async';

import '../rust/api.dart' as core;
import 'dev_mode.dart';
import 'format.dart';
import 'leaf_service.dart';
import 'stake_words.dart';
import 'wallet_repository.dart';

/// Thrown with a sentence the screen shows as it is.
class OnChainRefusal implements Exception {
  OnChainRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How long a move out of the Ark is waited for before the screen says it has not arrived.
const Duration kMoveWait = Duration(minutes: 45);

/// What the operator can pay out of [asset] in a round now (its `info`'s `fundable`), or null.
BigInt? operatorFundable(Map? info, String asset) {
  final si = info?['server_info'];
  final list = si is Map && si['assets'] is List ? si['assets'] as List : const [];
  for (final a in list) {
    if (a is Map && a['asset'] == asset && a['fundable'] != null) return BigInt.tryParse('${a['fundable']}');
  }
  return null;
}

/// Makes sure the wallet holds at least [need] atoms of [asset] on the chain ([onChain] reads what
/// it holds there now). Answers whether anything was moved. [say] is told what the screen should
/// show while it waits. Throws an [OnChainRefusal] in plain words when it cannot.
Future<bool> ensureOnChain({
  required String asset,
  required String ticker,
  required int precision,
  required BigInt need,
  required Future<BigInt> Function() onChain,
  required String purpose,
  required void Function(String) say,
  LeafService? leavesIn,
  Duration poll = const Duration(seconds: 10),
}) async {
  final leaves = leavesIn ?? LeafService.instance;
  final have = await onChain();
  if (have >= need) return false;
  var missing = need - have;
  String words(BigInt a) => '${formatAtoms('$a', precision)} $ticker';
  if (DevMode.instance.on || !leaves.open) throw OnChainRefusal(StakeWords.notEnough(formatAtoms('$missing', precision)));
  // The operator pays nothing below its smallest coin of the asset.
  final least = minLeaves(leaves.info)[asset] ?? BigInt.zero;
  if (missing < least) missing = least;
  final can = leaves.spendableAtoms(asset);
  if (can < missing) {
    // What vests later is never moved: an action that needs it says from when it can be used.
    throw OnChainRefusal(leaves.notVested(asset, missing, can, ticker: ticker, precision: precision) ??
        StakeWords.notEnough(formatAtoms('${missing - can}', precision)));
  }
  final m = await WalletRepository.instance.readMnemonic();
  if (m == null) throw OnChainRefusal(StakeWords.notMoved);
  final address = await core.receiveAddress(mnemonic: m);
  final args = {'asset': asset, 'amount': '$missing', 'address': address};
  Map q;
  try {
    q = (await leaves.run('offboard_quote', args)) as Map;
  } catch (_) {
    throw OnChainRefusal(StakeWords.notMoved);
  }
  // A round pays the whole coin a move gives (what is moved and its change) out of the operator's
  // own coins: when that is more than it can pay now, nothing is asked, so no coin waits.
  final pays = missing + (BigInt.tryParse('${q['change'] ?? 0}') ?? BigInt.zero);
  final fundable = operatorFundable(leaves.info, asset);
  if (fundable != null && pays > fundable) throw OnChainRefusal(StakeWords.cannotMoveNow(words(missing)));
  say(StakeWords.movingOut(words(missing), purpose));
  try {
    await leaves.pay('offboard', {...args, 'shown': q}, true);
  } catch (_) {
    throw OnChainRefusal(StakeWords.notMoved);
  }
  final until = DateTime.now().add(kMoveWait);
  var n = 0;
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(poll);
    if (++n % 3 == 0) {
      try {
        await leaves.syncNow(by: 'move');
      } catch (_) {}
    }
    try {
      if (await onChain() >= need) return true;
    } catch (_) {}
  }
  throw OnChainRefusal(StakeWords.notArrived);
}
