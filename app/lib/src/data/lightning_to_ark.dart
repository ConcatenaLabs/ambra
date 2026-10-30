import 'dart:async';

import 'package:flutter/foundation.dart';

import 'seqln_keys.dart' as lnkeys;
import 'ark_btc_service.dart';
import 'dev_mode.dart';
import 'leaf_service.dart';
import 'lightning_service.dart';
import 'ln_rail.dart';
import 'wallet_repository.dart';

/// User mode keeps BTC on the Bitcoin ark, where it is sent in seconds and needs no channel.
/// A wallet made before that holds its BTC in its own Lightning channel: this moves it, as the
/// wallet's own upkeep, by paying an invoice of the wallet's own ark from the channel. Nothing
/// is asked and nothing is lost: until the move is paid the BTC stays in the channel, spendable
/// as before and in the one BTC figure, and while it is on its way it is "arriving" under the
/// figure ([moving] names it). A move that fails is tried again after [retry]; one is never made
/// while something a person asked for runs, nor in developer mode, where channels are the
/// person's to use.
class LightningToArk extends ChangeNotifier {
  LightningToArk._();
  static final LightningToArk instance = LightningToArk._();

  /// The least worth moving, in sats: below it the routing fee is too large a share.
  static const minMove = 5000;

  /// How long after a move, or a move that failed, before the channel is looked at again.
  static const retry = Duration(minutes: 15);

  DateTime? _lastTry;
  bool _running = false;

  /// What is on its way from the channel to the ark, in sats, or null.
  BigInt? moving;

  /// What of [spendable] sats in the channel is moved: all of it less the routing fee the
  /// channel must also pay (1% and 10 sats, the hosted nodes' fee bound), or null when that is
  /// below [minMove].
  static BigInt? amountToMove(BigInt spendable) {
    final fee = spendable ~/ BigInt.from(100) + BigInt.from(10);
    final a = spendable - fee;
    return a >= BigInt.from(minMove) ? a : null;
  }

  /// One look at the wallet's own BTC channel; a move when it holds enough.
  Future<void> tick() async {
    final ark = ArkBtcService.instance;
    final ln = LightningService.instance;
    if (_running || DevMode.instance.on || !ark.open || !ln.configured || LeafService.instance.personBusy) return;
    final last = _lastTry;
    if (last != null && DateTime.now().difference(last) < retry) return;
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    _running = true;
    try {
      final st = await ln.getStatus(nodes: [lnkeys.ownNodeKeyForBtc(m)]);
      final channels = ((st.raw['channels'] as List?) ?? const []).whereType<Map>().toList();
      final spendable = legLiquidity(channels, RailTarget.btc()).spendable;
      final amount = amountToMove(spendable);
      if (amount == null) return;
      _lastTry = DateTime.now();
      final invoice = await ark.invoice(amount);
      moving = amount;
      notifyListeners();
      debugPrint('[ambra-ln-ark] moving $amount sat of $spendable from the channel to the ark');
      final r = await ln.payInvoice(bolt11: invoice, asset: kLnBtc);
      debugPrint('[ambra-ln-ark] paid: ${r.paid}');
      await ark.refresh();
    } catch (e) {
      _lastTry = DateTime.now();
      debugPrint('[ambra-ln-ark] not moved now: $e');
    } finally {
      moving = null;
      _running = false;
      notifyListeners();
    }
  }
}
