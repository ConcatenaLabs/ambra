/// What a stake, a pool's membership or a mix needs on the chain, moved out of the Ark first.
///
/// Default mode holds what a person receives in the Ark (the leaves). A stake, a pool's
/// membership record and a mix are made from coins the wallet holds on the chain, so the wallet
/// moves what is missing out of the Ark to its own address by itself (the library's quoted
/// `offboard`), says so, and waits for it to arrive; the person then reviews and signs as always.
/// A payment to a confidential address is made the same way: what is held for instant payments
/// is never confidential. The web wallet's `ensureOnChain` (docs/DEFAULT_MODE.md "Send" and
/// "Stake, pools and Mix").
library;

import 'dart:async';

import '../rust/api.dart' as core;
import 'dev_mode.dart';
import 'format.dart';
import 'leaf_service.dart';
import 'default_words.dart';
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

/// How long the coins a move brought are kept off the wallet's own boarding after the wait.
const Duration kKeepOnChain = Duration(minutes: 15);

/// After how long a move still waiting for the network is said to wait.
const Duration kMoveSlow = Duration(minutes: 3);

/// The states of the library's `offboards` in which a move has not reached the address.
const kMoveUnderWay = ['waiting', 'in_round', 'unlocking'];

/// What of [asset] the moves to [address] that are under way are bringing (the library's
/// `offboards`), and whether one of them still waits for the network.
({BigInt atoms, bool waiting}) movesComing(Object? offboards, String address, String asset) {
  var atoms = BigInt.zero;
  var waiting = false;
  for (final o in offboards is List ? offboards : const []) {
    if (o is! Map || o['asset'] != asset || o['address'] != address || !kMoveUnderWay.contains(o['state'])) continue;
    atoms += BigInt.tryParse('${o['amount'] ?? 0}') ?? BigInt.zero;
    if (o['state'] == 'waiting') waiting = true;
  }
  return (atoms: atoms, waiting: waiting);
}

/// Whether [text] is a confidential Sequentia address (blech32, `tsqb1…` on the testnet): a
/// payment to it is made on the chain, blinded, never out of the Ark.
bool isConfidentialAddress(String text) => RegExp(r'^(tsqb|sqb)1[02-9ac-hj-np-z]{20,}$').hasMatch(text.trim().toLowerCase());

/// Makes sure the wallet holds at least [need] atoms of [asset] on the chain ([onChain] reads what
/// it holds there now). Answers whether anything was moved. [say] is told what the screen should
/// show while it waits. Throws an [OnChainRefusal] in plain words when it cannot. A move already
/// under way to the wallet's address is waited for, never asked twice, and the coins are kept off
/// the wallet's own boarding while they move and for [kKeepOnChain] after.
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
  if (DevMode.instance.on || !leaves.open) throw OnChainRefusal(DefaultWords.notEnough(formatAtoms('$missing', precision), ticker));
  final m = await WalletRepository.instance.readMnemonic();
  if (m == null) throw OnChainRefusal(DefaultWords.notMoved);
  final address = await core.receiveAddress(mnemonic: m);
  // A move asked before (this screen earlier, or before the app was closed) counts.
  Future<({BigInt atoms, bool waiting})> under() async {
    try {
      return movesComing(await leaves.run('offboards'), address, asset);
    } catch (_) {
      return (atoms: BigInt.zero, waiting: false);
    }
  }
  final coming = (await under()).atoms;
  final started = DateTime.now();
  var moving = coming;
  if (missing > coming) {
    missing -= coming;
    // The operator pays nothing below its smallest coin of the asset.
    final least = minLeaves(leaves.info)[asset] ?? BigInt.zero;
    if (missing < least) missing = least;
    final can = leaves.spendableAtoms(asset);
    if (can < missing) {
      // What vests later is never moved: an action that needs it says from when it can be used.
      throw OnChainRefusal(leaves.notVested(asset, missing, can, ticker: ticker, precision: precision) ??
          DefaultWords.notEnough(formatAtoms('${missing - can}', precision), ticker));
    }
    final args = {'asset': asset, 'amount': '$missing', 'address': address};
    Map q;
    try {
      q = (await leaves.run('offboard_quote', args)) as Map;
    } catch (_) {
      throw OnChainRefusal(DefaultWords.notMoved);
    }
    // A round pays the whole coin a move gives (what is moved and its change) out of the operator's
    // own coins: when that is more than it can pay now, nothing is asked, so no coin waits.
    final pays = missing + (BigInt.tryParse('${q['change'] ?? 0}') ?? BigInt.zero);
    final fundable = operatorFundable(leaves.info, asset);
    if (fundable != null && pays > fundable) throw OnChainRefusal(DefaultWords.cannotMoveNow(words(missing)));
    moving = missing;
    say(DefaultWords.movingOut(words(missing), purpose, leaves.roundMinutes()));
    // The wallet's own boarding leaves these coins on the chain while they move, and after.
    leaves.keepOnChain(kMoveWait + kKeepOnChain);
    try {
      await leaves.pay('offboard', {...args, 'shown': q}, true);
    } catch (_) {
      throw OnChainRefusal(DefaultWords.notMoved);
    }
  } else {
    leaves.keepOnChain(kMoveWait + kKeepOnChain);
    say(DefaultWords.movingOut(words(coming), purpose, leaves.roundMinutes()));
  }
  final until = DateTime.now().add(kMoveWait);
  var n = 0;
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(poll);
    if (++n % 3 == 0) {
      try {
        await leaves.syncNow(by: 'move');
      } catch (_) {}
      // Still waiting for the network after a few minutes: said plainly; it goes ahead by itself.
      if (DateTime.now().difference(started) > kMoveSlow && (await under()).waiting) {
        say(DefaultWords.movingWaits(words(moving), purpose));
      }
    }
    try {
      if (await onChain() >= need) {
        leaves.keepOnChain(kKeepOnChain);
        return true;
      }
    } catch (_) {}
  }
  throw OnChainRefusal(DefaultWords.notReady);
}
