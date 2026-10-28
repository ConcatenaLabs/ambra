import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../rust/api.dart' as core;
import '../rust/api/ark_btc.dart' as ark;
import 'config.dart';
import 'dev_mode.dart';
import 'leaf_service.dart';
import 'wallet_repository.dart';

/// BTC on the Bitcoin ark, in user mode: the wallet's BTC lives there by itself,
/// native bitcoin the holder can always take on the chain. Confirmed BTC at the
/// shared address is moved in by the wallet (one transaction from the address to a
/// board), invoices and other wallets of the ark are paid from it in seconds, and an
/// address is paid out of it on the chain. Developer mode keeps BTC where it was:
/// on the chain and in Lightning, by hand.
///
/// The ark wallet is Second's Bark client in the Rust core (`ambra_core/src/ark_btc.rs`),
/// opened from the same recovery phrase against the default node's ark
/// ([Backend.bitcoinArk]); a custom node has none, and BTC stays as it was.
class ArkBtcService extends ChangeNotifier {
  ArkBtcService._();
  static final ArkBtcService instance = ArkBtcService._();

  /// How often the wallet syncs while the app runs: payments received, boards
  /// confirmed, Lightning receives claimed, coins refreshed before they expire.
  static const tick = Duration(seconds: 20);

  /// How long an open that failed waits before it is tried again.
  static const retry = Duration(minutes: 2);

  /// The smallest board the wallet makes by itself, in sats: below it, the fee is too
  /// large a share, and the BTC stays on the chain (still in the one BTC figure).
  static const minBoard = 20000;

  /// The fee rate of a board's funding transaction, sat/vB.
  static const boardFeeRate = 2.0;

  bool open = false;
  bool _opening = false;
  bool _ticking = false;
  bool _boarding = false;
  Timer? _timer;
  Map<String, dynamic>? balance;
  Object? lastError;
  Object? boardError;
  DateTime? _boardRefusedAt;

  BigInt _sats(String k) => BigInt.tryParse('${balance?[k] ?? 0}') ?? BigInt.zero;

  /// BTC in the ark now, spendable at once.
  BigInt get spendable => _sats('spendable');

  /// BTC on its way into the ark (a board, a round, a Lightning receive to claim).
  BigInt get arriving => _sats('pending_board') + _sats('pending_in_round') + _sats('claimable_lightning_receive');

  /// Everything of the ark that counts in the BTC figure.
  BigInt get held => spendable + arriving + _sats('pending_lightning_send');

  /// Opens the ark wallet in user mode, in the background; a failure changes nothing
  /// (BTC stays on the chain and in Lightning) and is tried again after [retry].
  Future<void> start() async {
    final server = Backend.bitcoinArk;
    if (open || _opening || server == null || DevMode.instance.on) return;
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    _opening = true;
    try {
      await ark.arkOpen(
          dir: await LeafService.dataDir(), mnemonic: m, network: 'testnet4', server: server, esplora: Backend.testnet4);
      open = true;
      lastError = null;
      await refresh();
      _plan(const Duration(seconds: 1));
    } catch (e) {
      lastError = e;
      _timer?.cancel();
      _timer = Timer(retry, () => unawaited(start()));
    } finally {
      _opening = false;
      notifyListeners();
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (open) ark.arkClose();
    open = false;
    balance = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!open) return;
    try {
      balance = Map<String, dynamic>.from(jsonDecode(await ark.arkBalance()) as Map);
    } catch (e) {
      lastError = e;
    }
    notifyListeners();
  }

  void _plan(Duration d) {
    _timer?.cancel();
    if (!open) return;
    _timer = Timer(d, () => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (!open || _ticking) return;
    _ticking = true;
    try {
      await ark.arkSync();
      await refresh();
      await autoBoard();
    } catch (e) {
      lastError = e;
    }
    _ticking = false;
    _plan(tick);
  }

  /// Moves the confirmed BTC at the shared address into the ark: the kit pays all of
  /// it, less the fee, to a new board's funding address, and the ark wallet boards that
  /// transaction. Never while something a person asked for runs or within a minute of
  /// it (the payment spends the address's coins), never below [minBoard], and after a
  /// refusal not again for ten minutes.
  Future<void> autoBoard({BigInt? onchainSats}) async {
    if (!open || _boarding || DevMode.instance.on || LeafService.instance.personBusy) return;
    final refused = _boardRefusedAt;
    if (refused != null && DateTime.now().difference(refused) < const Duration(minutes: 10)) return;
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    _boarding = true;
    try {
      final have = onchainSats ?? BigInt.parse((await core.btcSync(mnemonic: m, t4Api: Backend.testnet4)).balanceSats);
      if (have < BigInt.from(minBoard)) return;
      final where = jsonDecode(await ark.arkBoardAddress()) as Map;
      // A first build tells the fee of paying everything; the board is everything less it.
      final probe = await core.btcPrepare(
          mnemonic: m,
          t4Api: Backend.testnet4,
          address: '${where['address']}',
          amountSats: BigInt.from(minBoard ~/ 2),
          feeRate: boardFeeRate);
      final fee = BigInt.parse(probe.feeSats) + BigInt.from(200); // room for the inputs of a full spend
      final amount = have - fee;
      if (amount < BigInt.from(minBoard) || LeafService.instance.personBusy) return;
      final tx = await core.btcPrepare(
          mnemonic: m,
          t4Api: Backend.testnet4,
          address: '${where['address']}',
          amountSats: amount,
          feeRate: boardFeeRate);
      await ark.arkBoardWith(
          txHex: tx.hex, keyIndex: (where['key_index'] as num).toInt(), expiryHeight: (where['expiry_height'] as num).toInt());
      boardError = null;
      await refresh();
    } catch (e) {
      boardError = e;
      _boardRefusedAt = DateTime.now();
    } finally {
      _boarding = false;
      notifyListeners();
    }
  }

  /// What a destination is to the ark wallet: `ark`, `lightning`, `onchain` or `none`.
  String kindOf(String destination) => ark.arkKindOf(destination: destination);

  /// Pays [sats] (null: the invoice's own amount) to [destination] out of the ark.
  Future<Map<String, dynamic>> send(String destination, BigInt? sats) async {
    LeafService.instance.personActed();
    final out = Map<String, dynamic>.from(jsonDecode(await ark.arkSend(destination: destination, sats: sats)) as Map);
    unawaited(refresh());
    return out;
  }

  /// An invoice of [sats] paid into the ark; the wallet claims it while it runs.
  Future<String> invoice(BigInt sats) async {
    final out = jsonDecode(await ark.arkInvoice(sats: sats)) as Map;
    _plan(const Duration(seconds: 3));
    return '${out['invoice']}';
  }

  /// A new address of the ark: another wallet of the same ark pays it in seconds.
  Future<String> address() async => '${(jsonDecode(await ark.arkAddress()) as Map)['address']}';
}
