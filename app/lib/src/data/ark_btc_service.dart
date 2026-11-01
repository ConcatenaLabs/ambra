import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import '../rust/api/ark_btc.dart' as ark;
import 'btc_state.dart';
import 'default_words.dart';
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

  /// The most one board may carry when the server's info has not said yet, in sats: the testnet
  /// server's `max_board_amount` and `max_vtxo_amount` (sequentia-testnet-ops
  /// `bitcoin-ark/captaind.toml`). The server's own figure ([maxBoard]) wins once read.
  static const defaultMaxBoard = 5000000;

  /// How many of the largest boards the wallet keeps on the ark by itself: past it, BTC at the
  /// address stays there (in the one BTC figure, sendable as ever) until a trade or a payment needs
  /// more. Thousands of coins on the ark would slow every command the wallet makes there.
  static const keepBoards = 4;

  /// What one board may carry (the server's largest coin, a board making one), in sats.
  BigInt get maxBoard {
    final v = BigInt.tryParse('${balance?['max_board'] ?? ''}');
    return v != null && v > BigInt.zero ? v : BigInt.from(defaultMaxBoard);
  }

  /// The Bitcoin confirmations a board waits for before its BTC can be spent.
  int get boardConfirmations => (balance?['board_confirmations'] as num?)?.toInt() ?? 2;

  /// BTC a trade or a payment asked to have on the ark, beyond what is there (sats), and when.
  BigInt _wanted = BigInt.zero;

  /// Asks for at least [sats] more BTC on the ark, moved from the address now: a board of what is
  /// asked (at least what the wallet keeps there by itself, at most what one board carries), made
  /// at once even while the person is busy, the refusal wait set aside.
  void boardFor(BigInt sats) {
    if (sats <= BigInt.zero) return;
    _wanted = sats;
    _boardRefusedAt = null;
    unawaited(autoBoard(asked: true));
  }

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

  // ---- leaving the ark alone (bark-wasm's exit commands, `ambra_core` `ark_exit`) ----

  /// How often the wallet asks its one rule whether a coin must leave the ark alone
  /// (`exit_auto`), and how often while one is leaving.
  static const exitEvery = Duration(minutes: 5);
  static const exitMovingEvery = Duration(minutes: 1);

  /// What the BTC row says about BTC leaving the ark alone, in both modes; null when nothing.
  String? exitNote;
  String? _exitKind;

  /// While a coin leaves, or needs the address's BTC to pay its way out, nothing is boarded.
  bool exitHolds = false;
  bool _exitPending = false;
  DateTime? _exitAt;
  String? _exitCost, _exitAmount, _exitSaid;

  /// One of the exit commands, its answer decoded.
  Future<Map<String, dynamic>> exitRun(String command, [Map<String, dynamic> args = const {}]) async =>
      Map<String, dynamic>.from(jsonDecode(await ark.arkExit(command: command, args: jsonEncode(args))) as Map);

  static const _leaving = ['starting', 'on_its_way', 'waiting_out_its_delay', 'claimable'];
  static bool leaving(Map? r) =>
      ((r?['progress'] as Map?)?['exits'] as List? ?? const []).any((e) => _leaving.contains((e as Map)['state']));
  static String _btc(Object? sats) => formatSats(BigInt.tryParse('${sats ?? 0}') ?? BigInt.zero);
  static String formatSats(BigInt n) {
    final w = n ~/ BigInt.from(100000000), f = (n % BigInt.from(100000000)).toString().padLeft(8, '0').replaceAll(RegExp(r'0+$'), '');
    return f.isEmpty ? '$w' : '$w.$f';
  }

  /// What default mode says about `exit_auto`'s answer [r]: the web wallet's exitNoteOf.
  /// -> (kind, text) or null.
  static (String, String)? exitNoteOf(Map? r, {BigInt? pendingSats, String? lastCost, String? lastAmount}) {
    if (r == null) return null;
    final progress = r['progress'] as Map?;
    final claimed = progress?['claimed'] as Map?;
    if (claimed != null) return ('arrived', DefaultWords.exitArrived(_btc(claimed['amount']), lastCost == null ? null : _btc(lastCost)));
    final started = r['started'] as Map?;
    if (r['action'] == 'started' && started != null) return ('started', DefaultWords.exitStarted(_btc(started['amount']), _btc(started['cost'])));
    if (leaving(r)) {
      final p = pendingSats ?? BigInt.zero;
      final amount = p > BigInt.zero ? p : (BigInt.tryParse(lastAmount ?? '') ?? BigInt.zero);
      if (amount > BigInt.zero) return ('moving', DefaultWords.exitMoving(formatSats(amount)));
    }
    if (r['action'] == 'cannot_start') {
      final need = r['needed'] == null ? null : (BigInt.tryParse('${r['needed']}') ?? BigInt.zero) - (BigInt.tryParse('${r['available'] ?? 0}') ?? BigInt.zero);
      if (need != null && need > BigInt.zero) return ('needs', DefaultWords.exitNeedsFees(_btc(r['amount']), formatSats(need)));
      return null;
    }
    var small = BigInt.zero;
    for (final c in (r['not_worth'] as List? ?? const [])) {
      small += BigInt.tryParse('${(c as Map)['amount']}') ?? BigInt.zero;
    }
    if (r['ark'] != null && r['ark'] != 'answering' && small > BigInt.zero) return ('not-worth', DefaultWords.exitNotWorth(formatSats(small)));
    return null;
  }

  /// Asks the one rule (`exit_auto`) every [exitEvery], every [exitMovingEvery] while a coin
  /// leaves; [force] asks now.
  Future<Map?> exitCheck({bool force = false}) async {
    if (!open) return null;
    final last = _exitAt;
    if (!force && last != null && DateTime.now().difference(last) < (_exitPending ? exitMovingEvery : exitEvery)) return null;
    _exitAt = DateTime.now();
    try {
      final r = await exitRun('exit_auto');
      final said = '${r['action']} (${r['ark']})';
      if (said != _exitSaid) debugPrint('[ambra-ark] exit rule: $said');
      _exitSaid = said;
      final started = r['started'] as Map?;
      if (r['action'] == 'started' && started != null) {
        _exitCost = '${started['cost']}';
        _exitAmount = '${started['amount']}';
        debugPrint('[ambra-ark] leaving alone: ${started['started']} cost ${started['cost']}');
      }
      await refresh();
      final pending = BigInt.tryParse('${balance?['pending_exit'] ?? 0}') ?? BigInt.zero;
      _exitPending = leaving(r) || (((r['progress'] as Map?)?['pending'] as num?) ?? 0) > 0;
      final note = exitNoteOf(r, pendingSats: pending, lastCost: _exitCost, lastAmount: _exitAmount);
      if (note != null && note.$1 == 'arrived' && !leaving(r)) _exitCost = _exitAmount = null;
      // What arrived stays said until something else happens; a coin too small to leave is said after it.
      if (_exitKind == 'arrived' && (note == null || note.$1 == 'not-worth')) {
        if (note != null) exitNote = '${exitNote!.split(' The service holding').first} ${note.$2}';
      } else {
        _exitKind = note?.$1;
        exitNote = note?.$2;
      }
      exitHolds = _exitPending || r['action'] == 'started' || r['action'] == 'cannot_start';
      notifyListeners();
      return r;
    } catch (e) {
      debugPrint('[ambra-ark] leaving alone: $e');
      return null;
    }
  }

  /// Developer mode: each coin priced alone, and the start of the exit of [vtxos].
  Future<Map<String, dynamic>> exitEstimate() => exitRun('exit_estimate');
  Future<Map<String, dynamic>> exitStart(List<String> vtxos) async {
    final r = await exitRun('exit_start', {'vtxos': vtxos});
    _exitCost = '${r['cost']}';
    _exitAmount = '${r['amount']}';
    _exitPending = true;
    exitHolds = true;
    _exitAt = null;
    notifyListeners();
    return r;
  }

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
      await exitCheck();
      await autoBoard();
      // A wallet from before BTC lived on the ark moves its Lightning BTC here by itself.
      unawaited(LightningToArk.instance.tick());
      // And its assets' channels into the tree: the leaf wallet's own pass can be far apart
      // while nothing is on its way.
      unawaited(LightningToArk.instance.tickAssets());
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
  Future<void> autoBoard({BigInt? onchainSats, bool asked = false}) async {
    if (!open || _boarding || exitHolds || DevMode.instance.on || (!asked && LeafService.instance.personBusy)) return;
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
      // Enough is on the ark already, and nothing more was asked for: the rest stays at the address.
      final wanted = _wanted;
      if (wanted <= BigInt.zero && held >= maxBoard * BigInt.from(keepBoards)) return;
      final where = jsonDecode(await ark.arkBoardAddress()) as Map;
      // A first build tells the fee of paying everything; the board is everything less it.
      final probe = await core.btcPrepare(
          mnemonic: m,
          t4Api: Backend.testnet4,
          address: '${where['address']}',
          amountSats: BigInt.from(minBoard ~/ 2),
          feeRate: boardFeeRate);
      final fee = BigInt.parse(probe.feeSats) + BigInt.from(200); // room for the inputs of a full spend
      // Everything at the address less the fee, but never more than one board may carry: a board
      // over the server's largest coin is refused, and the BTC would never move at all. The rest
      // moves in later boards, one at a time.
      var amount = have - fee;
      if (amount > maxBoard) amount = maxBoard;
      if (amount < BigInt.from(minBoard) || (!asked && LeafService.instance.personBusy)) return;
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
      debugPrint('[ambra-ark] boarded $amount sat of $have at the address${asked ? ' (asked for $wanted)' : ''}: ${tx.txid}');
      _wanted = wanted > amount ? wanted - amount : BigInt.zero;
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

  /// Pays [sats] (null: the invoice's own amount) to [destination] out of the ark. For an
  /// invoice the answer carries the payment's `state` and `payment_hash`: `complete` once the
  /// payee took it, `pending` while the payee holds it without taking it yet ([payOutcome]
  /// follows it to its end).
  Future<Map<String, dynamic>> send(String destination, BigInt? sats) async {
    LeafService.instance.personActed();
    final out = Map<String, dynamic>.from(jsonDecode(await ark.arkSend(destination: destination, sats: sats)) as Map);
    unawaited(refresh());
    return out;
  }

  /// A payment out of the ark that its payee holds (a hold invoice), followed to its end:
  /// `complete` when they take it, `came-back` when it fails back (the BTC is the wallet's
  /// again), or `pending` still after [until]. The web wallet's `payOutcome`.
  Future<String> payOutcome(String hash,
      {Duration until = const Duration(minutes: 30), Duration every = const Duration(seconds: 3)}) async {
    final t0 = DateTime.now();
    while (true) {
      final st = await payState(hash);
      if (st == 'complete' || st == 'came-back') {
        await refresh();
        return st!;
      }
      if (DateTime.now().difference(t0) >= until) return 'pending';
      await Future.delayed(every);
    }
  }

  /// One look at the payment [hash] out of the ark, the server asked how it stands: `complete`,
  /// `came-back`, `pending`, or null when it could not be read now.
  Future<String?> payState(String hash) async {
    if (!open) return null;
    try {
      final r = jsonDecode(await ark.arkPayStatus(hash: hash, drive: true)) as Map;
      return switch (r['state']) {
        'complete' => 'complete',
        'none' || 'failed' => 'came-back',
        'pending' => 'pending',
        _ => null,
      };
    } catch (e) {
      debugPrint('[ambra-ark] payment status: $e');
      return null;
    }
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

  /// The ark's movements, newest first (Bark's history), or none while it is not open.
  Future<List<Map>> history({int limit = 200}) async {
    if (!open) return const [];
    try {
      return (jsonDecode(await ark.arkHistory(limit: limit)) as List).whereType<Map>().toList();
    } catch (e) {
      debugPrint('[ambra-ark] history: $e');
      return const [];
    }
  }

  /// A new address of the ark: another wallet of the same ark pays it in seconds.
  Future<String> address() async => '${(jsonDecode(await ark.arkAddress()) as Map)['address']}';
}
