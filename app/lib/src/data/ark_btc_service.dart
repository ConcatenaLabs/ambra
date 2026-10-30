import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import '../rust/api/ark_btc.dart' as ark;
import 'btc_state.dart';
import 'config.dart';
import 'dev_mode.dart';
import 'leaf_service.dart';
import 'lightning_to_ark.dart';
import 'wallet_repository.dart';

/// BTC on the Bitcoin ark, in user mode: the wallet's BTC lives there by itself,
/// native bitcoin the holder can always take on the chain. Confirmed BTC at the
/// shared address is moved in by the wallet (one transaction from the address to a
/// board), invoices and other wallets of the ark are paid from it in seconds, and an
/// address is paid out of it on the chain. Developer mode opens it too, so what it holds
/// is counted in BTC's figure, but moves nothing into it or out of it by itself.
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

  /// How many boards the wallet made by itself since the app started (see LeafService.boardsMade).
  int boardsMade = 0;
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
    if (open || _opening || server == null) return;
    _opening = true;
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) {
      _opening = false;
      return;
    }
    try {
      await ark.arkOpen(
          dir: await LeafService.dataDir(), mnemonic: m, network: 'testnet4', server: server, esplora: Backend.testnet4);
      open = true;
      lastError = null;
      await refresh();
      debugPrint('[ambra-ark] open: ${jsonEncode(balance)}');
      // A store made before (another device of the phrase, or this one before a remove and an
      // import) learns here what the phrase's other wallets boarded, received and spent.
      await catchUp();
      _plan(const Duration(seconds: 1));
    } catch (e) {
      lastError = e;
      debugPrint('[ambra-ark] open refused: $e');
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
    _watching = null;
    received = null;
    _caughtUpAt = null;
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

  /// How often the store is brought up to date with the phrase's other wallets while open.
  static const catchUpEvery = Duration(minutes: 5);
  DateTime? _caughtUpAt;

  /// Brings the store up to date with what the phrase's other wallets did; a failure changes
  /// nothing and is tried again at the next [catchUpEvery].
  Future<void> catchUp() async {
    if (!open) return;
    _caughtUpAt = DateTime.now();
    try {
      final t0 = DateTime.now();
      final r = jsonDecode(await ark.arkCatchUp()) as Map;
      final n = (r['recovered'] as List?)?.length ?? 0, gone = (r['spent_elsewhere'] as List?)?.length ?? 0;
      if (n > 0 || gone > 0) {
        debugPrint('[ambra-ark] caught up in ${DateTime.now().difference(t0).inMilliseconds} ms: '
            '$n coins (${r['recovered_sat']} sat) recovered, $gone spent elsewhere');
        await refresh();
      }
    } catch (e) {
      debugPrint('[ambra-ark] catch up refused: $e');
    }
  }

  Future<void> _tick() async {
    if (!open || _ticking) return;
    _ticking = true;
    try {
      await ark.arkSync();
      final last = _caughtUpAt;
      if (last == null || DateTime.now().difference(last) >= catchUpEvery) await catchUp();
      await refresh();
      await autoBoard();
      // A wallet from before BTC lived on the ark moves its Lightning BTC here by itself.
      unawaited(LightningToArk.instance.tick());
    } catch (e) {
      lastError = e;
      debugPrint('[ambra-ark] sync refused: $e');
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
    // One board at a time: a board in progress still holds the coins it spends until it is
    // seen on the chain, and the address's balance does not show them spent before then. A
    // board whose transaction the network never took (its broadcast failed) holds nothing, and
    // waiting on it would stop every board after it for good: once the network has not known
    // it for [lostBoard], the BTC at the address is boarded again.
    if (((balance?['boards_in_progress'] as num?) ?? 0) > 0 && !await boardsLost(balance?['boards'])) return;
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
      // A board registered counts as in progress at once, whatever its broadcast does, so the
      // next tick never boards the same coins again.
      balance = {...?balance, 'boards_in_progress': 1};
      final done = jsonDecode(await ark.arkBoardWith(
          txHex: tx.hex, keyIndex: (where['key_index'] as num).toInt(), expiryHeight: (where['expiry_height'] as num).toInt())) as Map;
      if (done['broadcast_error'] != null) debugPrint('[ambra-ark] board broadcast: ${done['broadcast_error']}');
      boardError = null;
      debugPrint('[ambra-ark] boarded $amount sat: ${tx.txid}');
      boardsMade++;
      // A sync first, so the figure counts the board at once; and the address read again, so
      // the coin the board spent is not counted on the chain as well meanwhile.
      await ark.arkSync();
      try {
        BtcState.instance.observe(btc: await core.btcSync(mnemonic: m, t4Api: Backend.testnet4));
      } catch (_) {}
      await refresh();
    } catch (e) {
      boardError = e;
      debugPrint('[ambra-ark] board refused: $e');
      _boardRefusedAt = DateTime.now();
    } finally {
      _boarding = false;
      notifyListeners();
    }
  }

  /// How long a board's funding transaction may be unknown to the network before the board is
  /// taken as never made.
  static const lostBoard = Duration(minutes: 10);
  final Map<String, DateTime> _missingSince = {};

  /// Whether every board in progress ([boards], the core's `boards`) has a funding transaction
  /// the network has not known for [lostBoard]. Any doubt (no list, the explorer unreachable,
  /// one transaction known) is no.
  Future<bool> boardsLost(Object? boards, {Future<int> Function(String txid)? status, DateTime? at}) async {
    if (boards is! List || boards.isEmpty) return false;
    final ask = status ??
        (String txid) async => (await http
                .get(Uri.parse('${Backend.testnet4}/tx/$txid/status'), headers: Backend.authHeaders)
                .timeout(const Duration(seconds: 20)))
            .statusCode;
    final now = at ?? DateTime.now();
    for (final b in boards) {
      final txid = b is Map ? b['funding_txid']?.toString() : null;
      if (txid == null) return false;
      int code;
      try {
        code = await ask(txid);
      } catch (_) {
        return false;
      }
      if (code != 404) {
        _missingSince.remove(txid);
        return false;
      }
      final since = _missingSince.putIfAbsent(txid, () => now);
      if (now.difference(since) < lostBoard) return false;
    }
    debugPrint('[ambra-ark] ${boards.length} board(s) never reached the network: boarding again');
    return true;
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

  /// An invoice of [sats] paid into the ark. While it runs the wallet looks for its payment
  /// every [watchEvery] and claims it at once ([received] then names it); a newer invoice
  /// takes the watch over.
  Future<String> invoice(BigInt sats) async {
    final out = jsonDecode(await ark.arkInvoice(sats: sats)) as Map;
    final hash = '${out['payment_hash']}';
    final until = ((out['expires_at'] as num?)?.toInt() ?? 0) * 1000;
    _watching = hash;
    unawaited(_watch(hash, sats, until));
    return '${out['invoice']}';
  }

  /// How often an open invoice's payment is looked for.
  static const watchEvery = Duration(seconds: 3);

  String? _watching;

  /// The last invoice of the ark's that was paid and claimed: its hash and what arrived of it.
  ({String hash, BigInt sats})? received;

  Future<void> _watch(String hash, BigInt sats, int untilMs) async {
    while (open && _watching == hash && DateTime.now().millisecondsSinceEpoch < untilMs) {
      await Future.delayed(watchEvery);
      if (!open || _watching != hash) return;
      try {
        final st = jsonDecode(await ark.arkReceiveStatus(hash: hash, claim: true)) as Map;
        if (st['state'] == 'paid') {
          _watching = null;
          // What arrived: the invoice's amount less the server's fee for receiving it.
          received = (hash: hash, sats: BigInt.tryParse('${st['net'] ?? st['amount']}') ?? sats);
          debugPrint('[ambra-ark] invoice paid and claimed: $hash');
          await refresh();
          return;
        }
        if (st['state'] == 'unknown') return;
      } catch (e) {
        debugPrint('[ambra-ark] invoice watch: $e');
      }
    }
  }

  /// A new address of the ark: another wallet of the same ark pays it in seconds.
  Future<String> address() async => '${(jsonDecode(await ark.arkAddress()) as Map)['address']}';
}
