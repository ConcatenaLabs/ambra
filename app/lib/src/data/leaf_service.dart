import 'lightning_to_ark.dart';
import 'speed_up_service.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'dart:ui' show AppLifecycleState;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/leaves.dart' as leaves;
import 'address_payments.dart';
import 'btc_state.dart';
import 'config.dart';
import 'dev_mode.dart';
import 'format.dart';
import 'home_coins.dart';
import 'ln_max_payment.dart';
import 'pay_code.dart' show expandRequest;
import 'price_service.dart';
import 'vesting.dart';
import 'wallet_cache.dart';
import 'wallet_repository.dart';

/// A refusal by the leaf wallet, in the library's own words.
class LeafRefusal implements Exception {
  LeafRefusal(this.kind, this.message, {this.code, this.status, this.asset, this.release = const [], this.plain = false});
  final String kind;
  final String message;
  final String? code;
  final int? status;

  /// A payment that planned coins could cover (kind `planned`): their asset, and the
  /// coins whose release covers it.
  final String? asset;
  final List<String> release;

  /// A refusal said in user mode's plain words ([plainRefusal]): a screen in user mode
  /// shows [message] as it is.
  final bool plain;

  /// Reads the library's `{"error": {"kind", "message", "code"?, "status"?}}`
  /// out of whatever the core threw.
  static LeafRefusal of(Object e) {
    final text = e is LeafRefusal ? null : _messageOf(e);
    if (e is LeafRefusal) return e;
    try {
      final j = jsonDecode(text!);
      if (j is Map && j['error'] is Map) {
        final err = j['error'] as Map;
        return LeafRefusal('${err['kind'] ?? 'error'}', '${err['message'] ?? text}',
            code: err['code']?.toString(),
            status: (err['status'] as num?)?.toInt(),
            asset: err['asset']?.toString(),
            release: [for (final r in (err['release'] as List?) ?? const []) '$r']);
      }
    } catch (_) {}
    return LeafRefusal('error', text ?? '$e');
  }

  static String _messageOf(Object e) {
    // flutter_rust_bridge's AnyhowException carries the core's text in `message`.
    try {
      final m = (e as dynamic).message;
      if (m is String) return m;
    } catch (_) {}
    return e.toString();
  }

  @override
  String toString() => message;
}

/// How the app reaches the operator and the node for leaves.
class LeafOperator {
  const LeafOperator({required this.server, required this.nodeUrl, this.nodeUser});
  final String server;
  final String nodeUrl;
  final String? nodeUser;

  Map<String, dynamic> toJson() => {'server': server, 'node_url': nodeUrl, if (nodeUser != null) 'node_user': nodeUser};
  static LeafOperator? fromJson(Object? j) {
    if (j is! Map) return null;
    return LeafOperator(
        server: '${j['server']}', nodeUrl: '${j['node_url']}', nodeUser: j['node_user'] as String?);
  }
}

/// The app's leaf wallet: the operator's wallet library in the Rust core, its store
/// a file in the app's support directory, open while the app runs. It syncs on the
/// library's own schedule while the app runs (a foreground service keeps the process
/// up), and the scheduled job ([leafSyncJob] in main.dart) takes over while it is
/// closed. Every refusal is the library's, shown as it says it.
class LeafService extends ChangeNotifier {
  LeafService._();
  static final LeafService instance = LeafService._();

  static const _channel = MethodChannel('ambra/leaves');
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _kOperator = 'ambra.leaves.operator';
  static const _kNodePassword = 'ambra.leaves.node_password';
  static const tick = Duration(seconds: 60);

  bool joined = false;

  /// How many coins arrived since the app started: the default Receive draws a new code
  /// once the one it shows is paid.
  int arrivedCount = 0;
  bool open = false;
  bool busy = false;
  LeafOperator? operator;
  Map<String, dynamic>? info;
  Map<String, dynamic>? balance;
  List<dynamic> coins = const [];
  List<dynamic> participations = const [];
  Map<String, dynamic>? schedule;
  /// The library's `plans` answer: developer mode marks each planned leaf ([plannedCoins]).
  Object? plans;
  DateTime? lastSync;
  LeafRefusal? lastError;
  Timer? _timer;
  bool _ticking = false;
  // The schedule's next_sync_at as first given after the last sync (see syncDecision).
  num? _heldFor;

  /// The last answer of the library's `care` (what the wallet did by itself: claims
  /// taken up, plans cancelled and made, coins refreshed into a round), when it ran,
  /// and its refusal if it failed. Developer mode shows them; user mode only sees a
  /// claim taken up in the asset's figure.
  Map<String, dynamic>? lastCare;
  DateTime? lastCareAt;
  LeafRefusal? careError;
  // Whether care ran since the app started: the first sync after a start runs it.
  bool _caredThisRun = false;

  /// The library's last `claims` answer (every claim named under a key of this wallet, a vesting
  /// one with its asset, value and date) and when it was read: kept, so the wallet shows what
  /// vests from the last reading while it is offline or syncing ([vesting]).
  List<dynamic>? claims;
  DateTime? claimsAt;
  LeafRefusal? claimsError;
  bool _readingClaims = false;
  static const _kClaims = 'ambra.leaves.claims';

  /// What the wallet holds that cannot move before a date, one line for each asset and day.
  List<VestingLot> vesting() => vestingLots(claims);

  /// What of each asset vests later, in atoms: part of the asset's figure, never of what can be
  /// spent.
  Map<String, BigInt> vestingAtoms() => vestingAtomsOf(vesting());

  /// The sentence an action says when [asked] atoms of [asset] need what has not vested
  /// ([notVestedSentence]), [spendable] what it can spend now; null when it does not.
  String? notVested(String asset, BigInt asked, BigInt spendable, {required String ticker, required int precision}) =>
      notVestedSentence(vesting(), asset, asked, spendable, ticker: ticker, precision: precision);

  static Future<String> dataDir() async => (await getApplicationSupportDirectory()).path;

  static Future<String?> nodePassword() => _storage.read(key: _kNodePassword);

  static Future<LeafOperator?> savedOperator() async {
    final s = await _storage.read(key: _kOperator);
    if (s == null) return null;
    try {
      return LeafOperator.fromJson(jsonDecode(s));
    } catch (_) {
      return null;
    }
  }

  /// Opens the leaf wallet this phone holds for the wallet's mnemonic, if any, and
  /// starts its schedule. Called once the wallet is unlocked.
  /// The library's refusal while another opener holds the store.
  static bool _openElsewhere(LeafRefusal r) => r.message.contains('open elsewhere');

  Timer? _startTimer;
  int _startTries = 0;

  /// [start] asked again in a few seconds, while the store is held elsewhere (for two minutes at most).
  void _startAgainSoon() {
    if (_startTries++ >= 24 || (_startTimer?.isActive ?? false)) return;
    _startTimer = Timer(const Duration(seconds: 5), () {
      if (!open) unawaited(start());
    });
  }

  /// One start at a time: Balance's mode listener and the shell can both ask as the app opens,
  /// and two at once each opened the wallet and ran the opening sync, the second planning a pass
  /// the first's sync then made return without planning the next (RX1: no board in 25 min).
  Future<void>? _starting;
  Future<void> start() {
    final s = _starting;
    if (s != null) return s;
    final f = _start().whenComplete(() => _starting = null);
    _starting = f;
    return f;
  }

  Future<void> _start() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    final dir = await dataDir();
    try {
      joined = await leaves.leavesExists(dir: dir, mnemonic: m);
    } catch (e) {
      final r = LeafRefusal.of(e);
      // A store open elsewhere holds a wallet: this process still holds it open from a screen closed
      // before (the app swiped away while its scheduled pass kept the process), or that pass has it
      // now. It is this phone's leaf wallet, and is opened below (ambra#220); never "none held".
      if (_openElsewhere(r)) {
        joined = true;
      } else {
        lastError = r;
        joined = false;
      }
    }
    operator = await savedOperator();
    await _loadClaims();
    await _homeKept();
    debugPrint('[leaves] start: ${joined ? 'a leaf wallet is held' : 'none held yet'}');
    if (!joined) {
      notifyListeners();
      // User mode joins the default node's operator by itself, in the background.
      unawaited(autoJoin());
      return;
    }
    final t0 = DateTime.now();
    debugPrint('[leaves] opening');
    try {
      await leaves.leavesOpen(dir: dir, mnemonic: m, nodePassword: await nodePassword() ?? '');
      open = true;
      lastError = null;
      _startTries = 0;
      debugPrint('[leaves] open in ${DateTime.now().difference(t0).inMilliseconds} ms');
      await _setWatchtowers();
    } catch (e) {
      lastError = LeafRefusal.of(e);
      debugPrint('[leaves] open refused after ${DateTime.now().difference(t0).inMilliseconds} ms: $e');
      // The scheduled pass holds the store for its own open: asked again once it has let go.
      if (_openElsewhere(lastError!)) _startAgainSoon();
    }
    notifyListeners();
    if (open) {
      await _foreground(true);
      await refresh();
      await openingSync();
      _plan(tick);
      _watchChannels();
    }
  }

  /// One sync when the leaf wallet opens or the app comes back, whatever the schedule
  /// says, then care. The schedule wakes a planned coin only at its plan's `sync_by`,
  /// so a wallet back after an expiry would otherwise show the coin a plan's step
  /// replaced until then; and a wallet back from a while away may have payments in
  /// its mailbox or an exit to move on.
  Future<void> openingSync({String by = 'open'}) async {
    _openedAt = DateTime.now();
    if (!open || _ticking) return;
    _ticking = true;
    try {
      await syncNow(by: by);
      lastError = null;
    } catch (e) {
      lastError = LeafRefusal.of(e);
    }
    _ticking = false;
    notifyListeners();
    // A pass that came due during this sync waited for it ([_tick]); none is ever left unplanned.
    if (open && !(_timer?.isActive ?? false)) _plan(const Duration(seconds: 5));
    unawaited(followAddressPayments());
  }

  // -------------------------------------------------------------------------
  // Payments to an address out of the tree, followed to their end (address_payments.dart)
  // -------------------------------------------------------------------------

  bool _following = false;

  /// Reads the library's `offboards` for the payments to an address this wallet asked for that are
  /// not at an end yet, and writes down where each stands: History follows it, and Balance says an
  /// unmade or taken-back one once ([WalletCache.untoldEnds]). [sync]: let the library move them
  /// on first (the paying wallet signs its part of the settlement as it is made). Answers the
  /// stage of payment [id] when one is named.
  Future<String?> followAddressPayments({bool sync = false, String? id}) async {
    Future<String?> stageOf() async {
      if (id == null) return null;
      for (final e in await WalletCache.addressPayments()) {
        if (e['offboard'] == id) return '${e['stage'] ?? 'pending'}';
      }
      return null;
    }
    final asked = await WalletCache.addressPayments();
    if (!open || _following || !asked.any((e) => e['stage'] == null || e['stage'] == 'pending')) return stageOf();
    _following = true;
    try {
      if (sync) {
        try {
          await syncNow(by: 'a payment to an address');
        } catch (_) {}
      }
      final r = offboardEnds(asked, await run('offboards'));
      for (final n in r.news) {
        debugPrint('[leaves] payment to an address ${n['offboard']}: ${n['state']}');
      }
      if (await WalletCache.setOffboardStages(r.stages)) notifyListeners();
    } catch (e) {
      debugPrint('[leaves] payments to an address not read: $e');
    } finally {
      _following = false;
    }
    return stageOf();
  }

  /// Stops the schedule and closes the wallet; the scheduled job takes over.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _chanTimer?.cancel();
    _chanTimer = null;
    _joinTimer?.cancel();
    _joinTimer = null;
    if (open) leaves.leavesClose();
    open = false;
    info = null;
    await _foreground(false);
    notifyListeners();
  }

  /// The wallet is being removed from this phone: the leaf wallet of its phrase is closed
  /// and everything read of it forgotten, so the next wallet (a new one, or another phrase
  /// restored) starts from nothing and opens its own.
  Future<void> forget() async {
    await stop();
    joined = false;
    operator = null;
    balance = null;
    coins = const [];
    participations = const [];
    schedule = null;
    plans = null;
    lastSync = null;
    lastError = null;
    lastCare = null;
    lastCareAt = null;
    careError = null;
    claims = null;
    claimsAt = null;
    claimsError = null;
    bond = null;
    bondError = null;
    lastWatch = null;
    lastWatchAt = null;
    watchError = null;
    autoJoinError = null;
    autoBoardError = null;
    releasing = null;
    _caredThisRun = false;
    _heldFor = null;
    _boardRefused.clear();
    unreachable = null;
    unreachableSince = null;
    await _keepHome({});
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // User mode on the operator: joined, received and boarded by itself
  // -------------------------------------------------------------------------

  /// How often user mode reads for a payment to a receive code handed out lately.
  static const fastAsk = Duration(seconds: 4);

  /// How long after a join that failed user mode tries again.
  static const joinRetry = Duration(minutes: 2);

  /// How long after something a person asked for the wallet leaves its on-chain coins
  /// alone: the leaf wallet spends the same coins as the on-chain wallet (one key per
  /// address, both chains), so a board must never race a send or a trade.
  static const boardQuiet = Duration(seconds: 60);

  /// How often the automatic board reads the library's balance again, at most: about a block.
  static const boardRead = Duration(seconds: 55);
  DateTime? _boardReadAt;

  /// How long an asset whose board was refused is left before it is tried again.
  static const boardBackoff = Duration(minutes: 10);

  Timer? _joinTimer;
  bool _joining = false;
  int _asking = 0;
  DateTime? _personAt;
  bool _boarding = false;
  final Map<String, DateTime> _boardRefused = {};

  /// The last join user mode tried and its refusal, for developer mode's eyes.
  LeafRefusal? autoJoinError;

  /// The last automatic board's refusal, for developer mode's eyes.
  LeafRefusal? autoBoardError;

  /// Something a person asked for just ran (a payment, a trade, an on-chain send): the
  /// wallet's own upkeep keeps off the coins for [boardQuiet].
  void personActed() => _personAt = DateTime.now();

  /// Coins the wallet moved out of the Ark for something a person asked for (a confidential
  /// payment, a stake, a pool's membership, a mix; on_chain_need.dart) are left on the chain for
  /// [d]: the wallet's own boarding would otherwise put them back before they are used.
  void keepOnChain(Duration d) {
    final until = DateTime.now().add(d);
    if (_keepUntil == null || until.isAfter(_keepUntil!)) _keepUntil = until;
  }

  DateTime? _keepUntil;
  bool get _keptOnChain => _keepUntil != null && DateTime.now().isBefore(_keepUntil!);

  /// Whether something a person asked for runs now or ran within [boardQuiet]: the
  /// wallet's own upkeep (a board, here or on the Bitcoin side) waits.
  bool get personBusy {
    final at = _personAt;
    return _asking > 0 || (at != null && DateTime.now().difference(at) < boardQuiet);
  }

  /// User mode: a wallet that holds no leaf wallet joins the default node's operator by
  /// itself. The server must show the pinned key ([Backend.arcaOperatorKey]) before
  /// anything is made, and the wallet made must name it; the join restores whatever the
  /// operator and the chain hold of this recovery phrase. A join that fails changes
  /// nothing (the wallet works as before, on the chain) and is tried again after
  /// [joinRetry]. Developer mode keeps its join form and joins nothing by itself.
  Future<void> autoJoin() async {
    final pinned = Backend.arcaOperatorKey;
    if (joined || _joining || pinned == null || DevMode.instance.on) return;
    _joinTimer?.cancel();
    _joining = true;
    try {
      final op = LeafOperator(server: Backend.arcaOperator, nodeUrl: Backend.nodeRpc);
      final shown = await operatorKeyAt(op.server);
      if (shown != pinned) {
        throw LeafRefusal('refused', 'the server at ${op.server} shows operator $shown, not $pinned');
      }
      final out = await join(op, '');
      final named = (out['info'] is Map) ? '${(out['info'] as Map)['operator']}' : null;
      if (named != pinned) {
        await stop();
        throw LeafRefusal('refused', 'the wallet joined operator $named, not $pinned');
      }
      autoJoinError = null;
    } catch (e) {
      autoJoinError = LeafRefusal.of(e);
      _joinTimer = Timer(joinRetry, () => unawaited(autoJoin()));
    } finally {
      _joining = false;
      notifyListeners();
    }
  }

  /// The operator key the server at [server] shows (`GET /v1/info`).
  static Future<String?> operatorKeyAt(String server) async {
    final r = await http.get(Uri.parse('$server/v1/info')).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw LeafRefusal('refused', 'the operator answered HTTP ${r.statusCode}');
    final j = jsonDecode(r.body);
    return j is Map ? j['operator']?.toString() : null;
  }

  /// User mode: every on-chain coin of an asset the operator serves is boarded, as the
  /// wallet's own upkeep: the amount is what the chain holds less the board's fee, paid
  /// in the same asset, and only on the fee quoted. Never while something a person asked
  /// for runs or within [boardQuiet] of it; an asset whose board is refused (coins not
  /// confirmed yet, too small for the smallest leaf, a fee the node does not take) is
  /// left for [boardBackoff]. Whatever is boarded shows as arriving until its board is
  /// final, then in the figure as before.
  Future<void> autoBoard() async {
    final skip = !open
        ? 'not open'
        : DevMode.instance.on
            ? null
            : _boarding
                ? 'a board runs'
                : personBusy
                    ? 'something a person asked for runs ($_asking asking)'
                    : _keptOnChain
                        ? 'coins moved out for a payment are kept on the chain until ${_keepUntil!.toIso8601String()}'
                        : null;
    if (skip != null || DevMode.instance.on) return _boardWhy(skip);
    // The library must read every key the balance may show a coin at, first. Then its balance is
    // read again (at most once a [boardRead]): the balance last read by a sync can be hours old,
    // and a coin paid to the address since would wait for an unrelated sync to be boarded.
    final handed = await _coverReceiveKeys() > 0;
    final readAt = _boardReadAt;
    if (handed || readAt == null || DateTime.now().difference(readAt) >= boardRead) {
      try {
        balance = await run('balance') as Map<String, dynamic>?;
        _boardReadAt = DateTime.now();
      } catch (_) {}
    }
    final served = minLeaves(info);
    final on = balance?['sequentia_onchain'];
    if (on is! Map || served.isEmpty) return _boardWhy('no on-chain balance or no served asset read');
    _boardWhy('looking at ${on.length} asset(s) on the chain');
    _boarding = true;
    var boarded = false;
    try {
      for (final e in on.entries) {
        final asset = '${e.key}';
        final held = BigInt.tryParse('${e.value}') ?? BigInt.zero;
        final min = served[asset];
        if (min == null || held <= min) continue;
        final refused = _boardRefused[asset];
        if (refused != null && DateTime.now().difference(refused) < boardBackoff) continue;
        if (_asking > 0) break;
        try {
          final done = await boardAll(_runKeepingBoards, asset: asset, held: held, min: min, stop: () => _asking > 0);
          if (done == null) {
            debugPrint('[leaves] board of ${asset.substring(0, 8)} left for the next pass: no fee leaves room for itself, or a person asked');
            continue;
          }
          final amount = done.$1, fee = done.$2;
          boarded = true;
          boardsMade++;
          _boardSpent[asset] = (spent: amount + fee, below: held - amount - fee, at: DateTime.now());
          _boardRefused.remove(asset);
          autoBoardError = null;
          debugPrint('[leaves] boarded $amount of ${asset.substring(0, 8)} (fee $fee)');
        } catch (err) {
          autoBoardError = LeafRefusal.of(err);
          _boardRefused[asset] = DateTime.now();
          debugPrint('[leaves] board of ${asset.substring(0, 8)} refused, again in ${boardBackoff.inMinutes} min: ${autoBoardError!.message}');
        }
      }
    } finally {
      _boarding = false;
    }
    if (boarded) await refresh();
  }

  /// User mode, when [refreshReceived] is on: every coin received out of round is given up in the operator's next round for a
  /// coin of the wallet's own (`refresh_received`), which ends what its senders could still do
  /// with it; at most once every [refreshEvery], never while something a person asked for runs.
  /// Until that round is final the coin counts as arriving. Nothing is said unless it goes wrong:
  /// the refusal is kept for developer mode's eyes.
  static const refreshEvery = Duration(minutes: 2);
  DateTime? _refreshedAt;
  Object? refreshError;
  /// On: the library gives a coin up only with an operator that takes back a refresh that waits,
  /// and only as much of each asset as the operator can fund now; a refresh that still waits is
  /// taken back after two minutes, and a payment or a trade that needs its coins takes it back first.
  static const refreshReceived = true;
  Future<void> autoRefreshReceived() async {
    if (!refreshReceived) return;
    if (!open || DevMode.instance.on || personBusy || _boarding) return;
    if (_refreshedAt != null && DateTime.now().difference(_refreshedAt!) < refreshEvery) return;
    _refreshedAt = DateTime.now();
    try {
      final v = await run('refresh_received', const {}) as Map<String, dynamic>?;
      refreshError = null;
      final n = ((v?['refreshed'] as List?) ?? const []).length;
      if (n > 0) {
        debugPrint('[leaves] $n coin(s) received out of round given up in the next round');
        await refresh();
      }
      for (final l in (v?['left'] as List?) ?? const []) {
        debugPrint('[leaves] a received coin left as it is: ${(l as Map)['why']}');
      }
    } catch (err) {
      refreshError = LeafRefusal.of(err);
      debugPrint('[leaves] refreshing what was received: $err');
    }
  }

  /// Hands the leaf wallet the keys the main wallet handed out, so its on-chain window covers
  /// them ([coverReceiveKeys]); how many keys were handed now.
  Future<int> _coverReceiveKeys() async {
    final key = '$_kWindow.${DevMode.instance.tag ?? 'default'}';
    final p = await SharedPreferences.getInstance();
    return coverReceiveKeys(
      want: await scanNext(),
      had: p.getInt(key) ?? 0,
      handOne: () async => run('address'),
      remember: (n) async => p.setInt(key, n),
      stop: () => _asking > 0,
      log: (m) => debugPrint(m),
    );
  }

  static const _kWindow = 'ambra.leaves.window';
  Timer? _boardSoon;

  /// A trade from coins an open plan keeps (the trade engine's `release`): they are given up in
  /// the next round (`plan_release`) for leaves no plan names, followed until that round is done
  /// with them, so the trade can be asked again. One release at a time; a second ask while one
  /// runs is the one running.
  bool _releasingForTrade = false;
  void releaseFor(String asset, List<String> leaves) {
    if (_releasingForTrade || !open || leaves.isEmpty) return;
    _releasingForTrade = true;
    unawaited(() async {
      try {
        await run('plan_release', {'leaves': leaves});
        debugPrint('[leaves] ${leaves.length} planned coin(s) of ${asset.substring(0, 8)} given up in the next round to be traded');
        final until = DateTime.now().add(kReleaseWait);
        while (DateTime.now().isBefore(until)) {
          await Future<void>.delayed(kReleasePoll);
          try {
            await run('sync');
            if (releaseDone((await run('coins') as List?) ?? const [], leaves)) break;
          } catch (_) {}
        }
        await refresh();
      } catch (e) {
        debugPrint('[leaves] release for a trade: $e');
      } finally {
        _releasingForTrade = false;
      }
    }());
  }

  String? _lastBoardWhy;

  /// How many boards the wallet made by itself since the app started: a screen showing the
  /// on-chain balance reads it again when this moves, so a coin a board spent is not counted on
  /// the chain and in the leaves at once.
  int boardsMade = 0;

  final Map<String, ({BigInt spent, BigInt below, DateTime at})> _boardSpent = {};

  @visibleForTesting
  void debugBoarded(String asset, {required BigInt spent, required BigInt held, DateTime? at}) =>
      _boardSpent[asset] = (spent: spent, below: held - spent, at: at ?? DateTime.now());

  /// [onchain] atoms of [asset] as the main wallet's chain reading shows them, less what a board
  /// the wallet just made spent and that reading does not hold yet: the board's coins are counted
  /// as arriving in the leaves meanwhile, never twice.
  ///
  /// [readFrom] is when the scan that made that reading began. A scan begun after the board was
  /// broadcast holds it (its spend, and any coin that reached the address since), so the reading
  /// is taken as it is from then on. Before that, only what the reading still holds of the coins
  /// the board spent comes off: the library read `held` (below + spent) when it boarded, and a
  /// reading short of that has not seen part of them yet. Comparing the reading with what the
  /// board left instead read a coin arriving after the board as the board's own, and it vanished
  /// from the figure until the next board or half an hour (sequentia-web-wallet#574). Without
  /// [readFrom] the board is taken as seen once the reading drops to what it left. Never longer
  /// than half an hour. The web wallet's `onchainLessBoards` (default-arca.js).
  BigInt onchainLessBoards(String asset, BigInt onchain, {DateTime? readFrom}) {
    final b = _boardSpent[asset];
    if (b == null) return onchain;
    if (DateTime.now().difference(b.at) > const Duration(minutes: 30) || (readFrom != null && readFrom.isAfter(b.at))) {
      _boardSpent.remove(asset);
      return onchain;
    }
    if (readFrom != null) {
      final held = b.below + b.spent;
      final missing = held > onchain ? held - onchain : BigInt.zero;
      final off = b.spent > missing ? b.spent - missing : BigInt.zero;
      return onchain - off;
    }
    if (onchain <= b.below) {
      _boardSpent.remove(asset);
      return onchain;
    }
    final v = onchain - b.spent;
    return v > BigInt.zero ? v : BigInt.zero;
  }

  static const _kBoardTxids = 'ambra.leaves.boardTxids';

  /// The transactions of the wallet's own boards: a move within the wallet, which History's
  /// default mode does not list as a payment.
  Set<String> boardTxids = {};
  bool _boardsRead = false;

  /// [run], keeping the transaction of each board it makes ([boardTxids]).
  Future<dynamic> _runKeepingBoards(String command, [Map<String, dynamic> args = const {}]) async {
    final r = await run(command, args);
    if (command == 'board' && r is Map && r['txid'] is String) await _keepBoards({r['txid'] as String});
    return r;
  }

  Future<void> _keepBoards(Set<String> txids) async {
    final p = await SharedPreferences.getInstance();
    final had = (p.getStringList(_kBoardTxids) ?? const []).toSet();
    boardTxids = {...had, ...boardTxids, ...txids};
    if (boardTxids.length != had.length) await p.setStringList(_kBoardTxids, boardTxids.toList());
  }

  /// The wallet's board transactions, those it made before it kept them read once from the
  /// operator (`boards`: each board's status names its transaction).
  Future<Set<String>> boardTransactions() async {
    await _keepBoards(const {});
    if (_boardsRead || !open) return boardTxids;
    try {
      final bs = await run('boards');
      _boardsRead = true;
      await _keepBoards(boardTxidsOf(bs));
    } catch (e) {
      debugPrint('[leaves] boards not read: $e');
    }
    return boardTxids;
  }

  /// Logs why the automatic board did nothing, once per reason.
  void _boardWhy(String? why) {
    if (why == null || why == _lastBoardWhy) return;
    _lastBoardWhy = why;
    debugPrint('[leaves] auto board: $why');
  }

  /// A trade found an asset held but not payable yet: board it once the person's action is
  /// [boardQuiet] behind, instead of at the next scheduled pass.
  void boardSoon() {
    _boardSoon?.cancel();
    _boardSoon = Timer(boardQuiet + const Duration(seconds: 2), () => unawaited(autoBoard()));
  }

  /// What of each asset is arriving: leaves not final yet (a board, a payment in
  /// flight), shown under the asset's one figure until they are.
  Map<String, BigInt> arrivingAtoms() => arrivingAtomsOf(balance, schedule);

  /// Of what is arriving, what is being redone: coins the library marks `redoing` (spendable once,
  /// then taken out of the chain with the Bitcoin block their round's block anchors to).
  Map<String, BigInt> redoingAtoms() => redoingAtomsOf(coins);

  /// What was moved out to keep it safe while the wallet was away (the library's balance
  /// `kept_safe`), until the library has put it back.
  Map<String, BigInt> keptSafeAtoms() => keptSafeAtomsOf(balance);

  /// The operator's anchor depth as the library follows it (`info.anchor_depth`; 0: a coin is
  /// spendable once its block is certified), or null before the library has said.
  int? anchorDepth() {
    final d = info?['anchor_depth'];
    return d is num ? d.toInt() : null;
  }

  /// How long a payment to an address out of the tree takes to reach the other wallet's figure,
  /// in whole minutes, from the operator's `info.fills` ([addressArrivalMinutes]), or null when
  /// it publishes no round interval.
  int? addressMinutes() {
    final si = info?['server_info'];
    final fills = si is Map && si['fills'] is Map ? si['fills'] as Map : (info?['fills'] is Map ? info!['fills'] as Map : null);
    return addressArrivalMinutes(fills?['round_interval_seconds'], fills?['block_seconds']);
  }

  /// Whether one payment of [atoms] of [kind] ('BTC', or an asset id) fits the most the operator
  /// takes in one payment over Lightning in direction [dir] ('out' or 'in'), from its `info`
  /// (ln_max_payment.dart [lnFits]): its published limit, or [kLnFallbackUsd] when it publishes
  /// none. Above it, a payment goes on the chain.
  bool lnFitsNow(String kind, String dir, BigInt? atoms) {
    final precision = kind == 'BTC' ? 8 : SeqAssets.labelFor(kind).precision;
    final ticker = kind == 'BTC' ? 'BTC' : SeqAssets.labelFor(kind).ticker;
    return lnFits(open ? info : null, kind, dir, atoms, price: PriceService.instance.usdPrice(ticker), precision: precision);
  }

  /// What of [asset] the leaves can pay now: held, less what is still arriving and what
  /// its issuer froze.
  BigInt spendableAtoms(String asset) {
    final held = leafAtoms()[asset] ?? BigInt.zero;
    final pending = arrivingAtomsOf(balance)[asset] ?? BigInt.zero;
    final v = held - pending - frozenAtoms(asset);
    return v > BigInt.zero ? v : BigInt.zero;
  }

  /// A fresh receive code (the library's receive request, any asset, any amount): the
  /// default Receive's QR. Null when the leaf wallet is not open or refuses one.
  Future<String?> receiveCode() async {
    if (!open) return null;
    // A code handed out is when a person waits for a payment: channels are read fast.
    _usedAt = DateTime.now();
    try {
      final r = await run('receive');
      final req = r is Map ? r['request']?.toString() : null;
      return (req == null || req.isEmpty) ? null : req;
    } catch (_) {
      return null;
    }
  }

  /// Whether [text] is a receive code this wallet can pay in the tree: a receive
  /// request naming this wallet's operator and chain.
  bool paysInTree(String text) {
    final i = info;
    if (!open || i == null) return false;
    return requestFor(text, operator: '${i['operator']}', genesis: '${i['genesis_hash']}') != null;
  }

  /// A receive request as a receive code carries it (short, or the library's own spelling)
  /// as the library's request this wallet pays in the tree, or null when it names another
  /// operator or chain, or the leaf wallet is not open ([expandRequest]).
  String? payable(String text) {
    final i = info;
    if (!open || i == null) return null;
    final full = expandRequest(text, operator: '${i['operator']}', genesis: '${i['genesis_hash']}');
    return (full != null && paysInTree(full)) ? full : null;
  }

  /// Joins an operator: creates the leaf wallet of this wallet's mnemonic against
  /// it (pinning its key and the node's chain) and restores whatever the operator
  /// and the chain hold of this mnemonic's leaves.
  Future<Map<String, dynamic>> join(LeafOperator op, String nodePassword) async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw LeafRefusal('refused', 'no wallet is open');
    final dir = await dataDir();
    busy = true;
    notifyListeners();
    try {
      final cfg = {...op.toJson(), if (nodePassword.isNotEmpty) 'node_password': nodePassword};
      final out = jsonDecode(await leaves.leavesJoin(dir: dir, mnemonic: m, configJson: jsonEncode(cfg)))
          as Map<String, dynamic>;
      await _storage.write(key: _kOperator, value: jsonEncode(op.toJson()));
      await _storage.write(key: _kNodePassword, value: nodePassword);
      operator = op;
      joined = true;
      open = true;
      lastError = null;
      info = out['info'] as Map<String, dynamic>?;
      await _setWatchtowers();
      // Asked for, never waited on: the wallet goes on while the person answers.
      unawaited(Permission.notification.request().then((_) {}, onError: (_) {}));
      await _foreground(true);
      _openedAt = DateTime.now();
      await refresh();
      _plan(tick);
      _watchChannels();
      return out;
    } catch (e) {
      throw LeafRefusal.of(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Gives the library the other operators' watchtowers ([Backend.defaultWatchtowers]) each time
  /// the leaf wallet opens; a refusal changes nothing but that.
  Future<void> _setWatchtowers() async {
    final urls = Backend.defaultWatchtowers;
    if (urls.isEmpty) return;
    try {
      await run('set_default_watchtowers', {'urls': urls});
    } catch (e) {
      debugPrint('[leaves] default watchtowers not set: $e');
    }
  }

  /// Runs one of the library's commands and answers its `result`. Throws a
  /// [LeafRefusal] in the library's words.
  Future<dynamic> run(String command, [Map<String, dynamic> args = const {}]) async {
    if (!open) throw LeafRefusal('refused', 'the leaf wallet is not open');
    _running++;
    final t0 = DateTime.now();
    try {
      final out = jsonDecode(await leaves.leavesRun(command: command, argsJson: jsonEncode(args)));
      // A command over ten seconds says where its time went (the library's own costs), so a slow
      // phone can be read from its log.
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (ms > 10000 && out is Map) {
        final r = out['result'];
        final t = jsonEncode({'cost': out['cost'], 'steps': r is Map ? r['cost_by_step'] : null});
        debugPrint('[leaves] slow $command $ms ms: ${t.length > 900 ? t.substring(0, 900) : t}');
      }
      return (out as Map)['result'];
    } catch (e) {
      throw LeafRefusal.of(e);
    } finally {
      _running--;
    }
  }

  /// How many of the library's commands run now: a channel read waits for none.
  int _running = 0;

  // -------------------------------------------------------------------------
  // A payment another service made to the receive code: taken in at once
  // -------------------------------------------------------------------------

  /// Every coin the library took in, by whichever read (a sync, the mailbox read, a channel's),
  /// with its asset and when: for [takeIn].
  final List<(String, DateTime)> _arrived = [];
  void _noteArrived(Map a) {
    _arrived.add(('${a['asset'] ?? ''}'.toLowerCase(), DateTime.now()));
    if (_arrived.length > 50) _arrived.removeAt(0);
  }

  /// Whether a coin of [asset] (hex) was taken in at or after [since], by any read.
  bool arrivedSince(String asset, DateTime since) =>
      _arrived.any((x) => x.$1 == asset.toLowerCase() && !x.$2.isBefore(since));

  /// The faucet answers once its coin is in the wallet's mailbox, so `mailbox` (a read of
  /// seconds) takes it in, never a whole sync, which can sit in a round for a minute or more.
  /// It counts as something a person asked for, so the wallet's own upkeep waits; it waits
  /// only for a command of the library already running. It reads again every [takeInEvery]
  /// until a coin of [asset] has arrived since [since] (by this read or any other) or [within]
  /// has passed; then the balance is read again, so the figure holds the coin before the screen
  /// says Received. Answers whether it arrived.
  Future<bool> takeIn(String asset, {required DateTime since, Duration within = takeInWithin}) async {
    if (!open) return false;
    _asking++;
    try {
      final got = await readUntil(
        came: () => arrivedSince(asset, since),
        within: within,
        every: takeInEvery,
        read: () async {
          final mb = await run('mailbox');
          for (final a in arrivals(mb)) {
            arrivedCount++;
            _noteArrived(a);
            await notifyArrived(a, channel: _channel);
          }
        },
      );
      if (got) {
        try {
          balance = await run('balance') as Map<String, dynamic>?;
        } catch (_) {}
        notifyListeners();
        unawaited(refresh());
      }
      return got;
    } finally {
      _asking--;
      personActed();
    }
  }

  // -------------------------------------------------------------------------
  // Channels: a payment into one is in the asset's figure within a second
  // -------------------------------------------------------------------------

  /// The wallet's channel leaves as the library holds them (`channels`, asking nothing), each
  /// merged with its last read (`channel_sync`).
  List<dynamic> channels = const [];

  /// Bumped when the channels a payer can pay change ([payableChannels]): Receive then makes its
  /// code again, so the code names them.
  int channelsVersion = 0;
  String _payable = '{}';

  /// How often, in default mode, the wallet reads its channels from the operator while the app is
  /// in the foreground and was used, opened, paid or showed a receive code within [channelFastFor]: a payment into one is
  /// in the asset's figure within this and the read's own time. Otherwise every [channelIdle].
  /// Each read runs the library's witness, which the operator hands out at a bounded rate, so only
  /// a wallet in use reads fast. The web wallet's CHANNEL_POLL_MS, CHANNEL_POLL_IDLE_MS and
  /// CHANNEL_FAST_FOR_MS.
  static const channelPoll = Duration(milliseconds: 300);
  static const channelIdle = Duration(seconds: 5);
  static const channelFastFor = Duration(minutes: 3);

  Timer? _chanTimer;
  DateTime? _openedAt, _usedAt, _channelIn, _holdUntil;
  bool _chanReading = false;

  /// Holds the channel reads for [d] (zero lets them go on): while a person reviews a payment the
  /// wallet is about to make, so the payment never waits behind one.
  void holdReads(Duration d) => _holdUntil = d > Duration.zero ? DateTime.now().add(d) : null;

  /// Whether the app is in view: in front, or in view behind a system sheet (`inactive`).
  bool get _inForeground {
    final s = SchedulerBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
  }

  Duration _channelPace() {
    final used = [_personAt, _openedAt, _usedAt, _channelIn].whereType<DateTime>().fold<DateTime?>(
        null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (!_inForeground || used == null || DateTime.now().difference(used) > channelFastFor) return channelIdle;
    return channelPoll;
  }

  /// While the leaf wallet is open in default mode and holds a live channel, reads its channels
  /// from the operator at [_channelPace], never while another command of the wallet runs, while a
  /// person asks for something, or while the reads are held ([holdReads]); a channel that was
  /// paid reads the balance again, so the asset's figure moves at once, and counts as a payment
  /// received (Receive draws a new code).
  void _watchChannels() {
    _chanTimer?.cancel();
    if (!open) return;
    _chanTimer = Timer(_channelPace(), () async {
      if (_running == 0 && !_ticking) await _readChannelsNow();
      _watchChannels();
    });
  }

  DateTime? _chanReadAt;

  /// One read of the channels when the wallet holds a live one, in default mode, while no
  /// person asks for something and the reads are not held; also between two commands of the
  /// wallet's own upkeep ([_readsBetween]).
  Future<void> _readChannelsNow() async {
    {
      final hold = _holdUntil;
      final live = channels.any((c) => c is Map && c['coin_state'] == 'live');
      if (live && open && !DevMode.instance.on && _asking == 0 && !_chanReading &&
          !(hold != null && DateTime.now().isBefore(hold))) {
        _chanReading = true;
        _chanReadAt = DateTime.now();
        try {
          final before = channels;
          final after = await run('channel_sync');
          if (after is List) {
            channels = [
              for (final c in after)
                if (c is Map)
                  {...?before.whereType<Map>().where((x) => x['leaf_id'] == c['leaf_id']).firstOrNull, ...c}
            ];
          }
          final came = channelArrivals(before, channels);
          if (came.isNotEmpty) {
            _channelIn = DateTime.now();
            try {
              balance = await run('balance') as Map<String, dynamic>?;
            } catch (_) {}
            for (final a in came) {
              arrivedCount++;
              _noteArrived(a);
              debugPrint('[leaves] channel ${a['leaf_id']} paid ${a['value']} of ${'${a['asset']}'.substring(0, 8)}');
              unawaited(notifyArrived(a, channel: _channel));
            }
            notifyListeners();
          }
        } catch (_) {
        } finally {
          _chanReading = false;
        }
      }
    }
  }

  /// The last read of the mailbox, by any path (a sync reads it too).
  DateTime? _mailReadAt;

  /// How often default mode reads the mailbox while nothing else does: a payment to a receive
  /// code is taken in within this and the read's own time. With a receive code handed out lately,
  /// [fastAsk].
  static const mailboxEvery = Duration(seconds: 10);

  /// Between two commands of the wallet's own upkeep (a sync and the care, claims and bond's watch
  /// after it): the reads that show a payment to this wallet, when they are due. The upkeep is
  /// several commands, some of them long, and every other read waits for it, so without this a
  /// payment to the receive code waited for the whole pass. Default mode only, never while a person
  /// asks for something.
  /// When the last mailbox read ended, and what it took: the next waits at least twice that. A read
  /// the operator answers slowly (10 to 20 s were seen) otherwise kept the library busy all the
  /// time with reads that found nothing, and every other command of the wallet waited.
  DateTime? _mailReadEnd;
  int _mailCostMs = 0;
  bool _mailDue(DateTime now) {
    final base = freshRequestWaits(schedule, now) ? fastAsk : mailboxEvery;
    final gap = _mailCostMs * 2 > base.inMilliseconds ? Duration(milliseconds: _mailCostMs * 2) : base;
    final end = _mailReadEnd ?? _mailReadAt;
    return end == null || now.difference(end) >= gap;
  }

  Future<dynamic> _mailboxRead() async {
    final t0 = DateTime.now();
    _mailReadAt = t0;
    try {
      return await run('mailbox');
    } finally {
      _mailReadEnd = DateTime.now();
      _mailCostMs = _mailReadEnd!.difference(t0).inMilliseconds;
    }
  }

  Future<void> _readsBetween() async {
    if (!open || DevMode.instance.on || _asking > 0) return;
    final now = DateTime.now();
    if (_mailDue(now)) {
      try {
        final got = arrivals(await _mailboxRead());
        for (final a in got) {
          arrivedCount++;
          _noteArrived(a);
          await notifyArrived(a, channel: _channel);
        }
        if (got.isNotEmpty) {
          try {
            balance = await run('balance') as Map<String, dynamic>?;
          } catch (_) {}
          notifyListeners();
        }
      } catch (_) {}
    }
    final ch = _chanReadAt;
    if (ch == null || DateTime.now().difference(ch) >= _channelPace()) await _readChannelsNow();
  }

  /// The channels as the wallet holds them; when those a payer can pay change, Receive's code is
  /// made again.
  Future<void> _readChannels() async {
    try {
      final c = await run('channels');
      final before = {for (final x in channels.whereType<Map>()) x['leaf_id']: x};
      channels = [for (final x in (c is List ? c : const [])) if (x is Map) {...?before[x['leaf_id']], ...x}];
    } catch (_) {
      channels = const [];
    }
    final p = jsonEncode(payableChannels(channels));
    if (p != _payable) {
      _payable = p;
      channelsVersion++;
      debugPrint('[leaves] the channels a payer can pay: $p');
    }
  }

  /// While a payment waits for the round that frees the planned coins it needs: which
  /// coins, their asset, the command, and since when. Developer mode shows it as "Paying
  /// through the next round"; user mode shows nothing more than the payment's own wait.
  ReleaseWait? releasing;

  /// Runs a leaf command a person started (a payment, a trade, an order, a fill, and every
  /// other command the screens send on someone's tap): the library's answer, or its
  /// refusal. A payment the unplanned coins cannot cover and planned ones can is made
  /// through the next round by itself ([payThroughRelease]): the planned coins the
  /// refusal names are given up in that round for leaves no plan names, and the command
  /// is asked again once that round is final. Every screen that starts a leaf command
  /// goes through here; keep it the one path.
  ///
  /// With [plain] (user mode), a refusal user mode has plain words for is said in them
  /// ([plainRefusal]); every other refusal is the library's.
  /// [person]: false for the wallet's own following of what was asked before (a trade's
  /// syncs and reads), which keeps no upkeep waiting.
  Future<dynamic> pay(String command, [Map<String, dynamic> args = const {}, bool plain = false, bool person = true]) async {
    // Whether this command holds the wallet's own reads and upkeep off (`_asking`). It does while
    // the library works for the person, and not while the command waits for a round to free the
    // planned coins it needs (up to hours): the wallet then goes on reading its mailbox and its
    // channels and taking in what is paid to it, or a payment to it would show only once that
    // round came (ambra#244).
    var holding = false;
    void hold(bool on) {
      if (!person || holding == on) return;
      holding = on;
      _asking += on ? 1 : -1;
    }
    hold(true);
    try {
      return await payThroughRelease(
        command,
        args,
        run: run,
        synced: (v) async {
          lastSync = DateTime.now();
          _mailReadAt = lastSync;
          _mailReadEnd = lastSync;
          noteUnreachable(unreachableOf(v, 'sync'));
          final got = arrivals(v is Map ? v['mailbox'] : null);
          for (final a in got) {
            arrivedCount++;
            _noteArrived(a);
            await notifyArrived(a, channel: _channel);
          }
          // What the sync took in shows in the figures at once.
          if (got.isNotEmpty) {
            try {
              balance = await run('balance') as Map<String, dynamic>?;
            } catch (_) {}
            notifyListeners();
          }
        },
        onWait: (w) {
          releasing = w;
          hold(w == null);
          notifyListeners();
        },
      );
    } on LeafRefusal catch (e) {
      throw plain ? plainRefusal(e) : e;
    } finally {
      if (person) {
        hold(false);
        personActed();
      }
      if (releasing != null) {
        releasing = null;
        notifyListeners();
      }
    }
  }

  /// Reads balance, coins, participations and schedule again, and plans the
  /// scheduled job from the schedule.
  Future<void> refresh() async {
    if (!open) return;
    try {
      balance = await run('balance') as Map<String, dynamic>?;
      coins = (await run('coins') as List?) ?? const [];
      participations = (await run('participations') as List?) ?? const [];
      schedule = await run('schedule') as Map<String, dynamic>?;
      await _planJob();
    } catch (e) {
      lastError = LeafRefusal.of(e);
    }
    await _readChannels();
    try {
      plans = await run('plans');
    } catch (_) {}
    // The operator's assets (which it serves supervised or issuer-operated) and the
    // landing key, read once per open.
    if (info == null) {
      try {
        info = Map<String, dynamic>.from(await run('info') as Map);
        noteUnreachable(unreachableOf(info, 'info'));
      } catch (_) {}
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Every coin home, with the operator gone (home_coins.dart)
  // -------------------------------------------------------------------------

  /// Whether the operator cannot be reached, as the library last said (a sync's `unreachable`,
  /// present only then, or an `info`'s), and since when; null once it answers again.
  Unreachable? unreachable;
  DateTime? unreachableSince;

  /// Keeps what a library answer says of the operator being reachable ([unreachableOf]).
  void noteUnreachable(({bool known, Unreachable? value}) u) {
    if (!u.known) return;
    final was = unreachable != null;
    unreachable = u.value;
    if (u.value == null) {
      unreachableSince = null;
    } else {
      unreachableSince ??= DateTime.now();
    }
    if (was != (unreachable != null)) {
      debugPrint('[leaves] the operator ${unreachable == null ? 'answers again' : 'cannot be reached: ${unreachable!.why}'}');
      notifyListeners();
    }
  }

  /// While the operator cannot be reached: the coins that could go home, else null. Balance shows
  /// the card with "Take my coins home" in either mode while it is not null.
  List<Map>? homeOffer() {
    if (!open || unreachable == null) return null;
    final c = homeCoins(coins);
    return c.isEmpty ? null : c;
  }

  /// Each coin's exit, quoted by the library; asks nothing of the operator.
  Future<HomeQuote> homeQuoteNow() => _person(() => homeQuote(run, coins, homeChannelIds()));

  /// The wallet's channel leaves, which go home by their own steps (`channel_exit`).
  List<String> homeChannelIds() => [for (final c in channels) if (c is Map) '${c['leaf_id']}'];

  /// Broadcasts what [homeQuoteNow] quoted, each exit only on the fees it showed, and keeps what
  /// was sent and when for the card's words.
  Future<HomeTaken> takeHome(HomeQuote q) => _person(() async {
        final r = await homeTake(run, q, log: debugPrint);
        await _keepHome({...await _homeKept(), ...r.kept});
        await refresh();
        return r;
      });

  /// The coins on their way home, for the card's words ([homeUnderWay]).
  List<HomeWay> homeUnderWayNow() {
    final r = homeUnderWay(coins, _homeKeptNow, unreachable != null);
    if (coins.isNotEmpty && r.kept.length != _homeKeptNow.length) {
      _homeKeptNow = Map<String, Map>.from(r.kept);
      unawaited(_keepHome(_homeKeptNow));
    }
    return r.list;
  }

  static const _kHome = 'ambra.leaves.home';
  Map<String, Map> _homeKeptNow = {};

  Future<Map<String, Map>> _homeKept() async {
    try {
      final p = await SharedPreferences.getInstance();
      final j = jsonDecode(p.getString(_kHome) ?? '{}');
      _homeKeptNow = {for (final e in (j as Map).entries) '${e.key}': e.value as Map};
    } catch (_) {}
    return _homeKeptNow;
  }

  Future<void> _keepHome(Map<String, Map> m) async {
    _homeKeptNow = m;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kHome, jsonEncode(m));
    } catch (_) {}
  }

  /// Something a person asked for: the wallet's own upkeep keeps off while it runs.
  Future<T> _person<T>(Future<T> Function() f) async {
    _asking++;
    try {
      return await f();
    } finally {
      _asking--;
      personActed();
    }
  }

  /// A sync now: what the library does on its own (the mailbox, refreshes, every
  /// coin's way home), and a notification per coin received.
  Future<Map<String, dynamic>> syncNow({String by = 'user'}) async {
    final r = await run('sync') as Map<String, dynamic>;
    noteUnreachable(unreachableOf(r, 'sync'));
    _heldFor = null;
    lastSync = DateTime.now();
    _mailReadAt = lastSync;
    _mailReadEnd = lastSync;
    for (final a in arrivals(r['mailbox'])) {
      arrivedCount++;
      _noteArrived(a);
      await notifyArrived(a, channel: _channel);
    }
    await _readsBetween();
    await careIfDue();
    await _readsBetween();
    await readClaims();
    await _readsBetween();
    await refresh();
    return r;
  }

  /// Runs the library's `care` when it is due: at the first sync after the app
  /// starts, then at most every [careEvery] (the scheduled job keeps the same
  /// clock). It takes up every claim named by an address the wallet handed out (the
  /// scan reaches 20 past the wallet's next receive index), cancels each plan whose
  /// coin moved, plans a leaf of a round once its first step could run within ten
  /// days, and refreshes into a round a coin no
  /// plan can start from once that refresh could run within ten days. No prompt: it
  /// is what the wallet does by itself.
  Future<void> careIfDue({bool force = false}) async {
    if (!open) return;
    final last = _caredThisRun ? (lastCareAt ?? await careClock()) : null;
    if (!force && !careDue(last, DateTime.now())) return;
    _caredThisRun = true;
    final at = DateTime.now();
    try {
      lastCare = Map<String, dynamic>.from(await run('care', careArgs(await scanNext())) as Map);
      careError = null;
      // A channel opened or its credit folded: the channels and the code follow at once.
      if (careMovedChannels(lastCare)) await refresh();
    } catch (e) {
      careError = LeafRefusal.of(e);
    }
    lastCareAt = at;
    await setCareClock(at);
    notifyListeners();
    await _readsBetween();
    await readClaims(force: true);
    await _readsBetween();
    await watchBond();
  }

  /// Reads the library's `claims` (under the keys care scans) at most every [kClaimsEvery], or
  /// now with [force] (after each care), and keeps the answer. A claim whose vest date has passed
  /// and that is not taken up yet runs care at once, so it becomes a coin by itself.
  Future<void> readClaims({bool force = false}) async {
    if (!open || _readingClaims) return;
    final at = claimsAt;
    if (!force && at != null && DateTime.now().difference(at) < kClaimsEvery) return;
    _readingClaims = true;
    try {
      final c = await run('claims', careArgs(await scanNext()));
      claims = c is List ? c : const [];
      claimsAt = DateTime.now();
      claimsError = null;
      await _keepClaims();
    } catch (e) {
      claimsError = LeafRefusal.of(e);
    } finally {
      _readingClaims = false;
    }
    notifyListeners();
    if (!force && vestedOpen(claims)) await careIfDue(force: true);
  }

  Future<void> _keepClaims() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kClaims, jsonEncode({'at': claimsAt?.millisecondsSinceEpoch, 'claims': claims}));
    } catch (_) {}
  }

  Future<void> _loadClaims() async {
    if (claims != null) return;
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_kClaims);
      if (s == null) return;
      final j = jsonDecode(s);
      if (j is Map && j['claims'] is List) {
        claims = j['claims'] as List;
        final t = j['at'];
        // The reading kept is shown, and read again at the first sync.
        claimsAt = null;
        if (t is int) debugPrint('[leaves] claims as of ${DateTime.fromMillisecondsSinceEpoch(t)}');
      }
    } catch (_) {}
  }

  /// The operator's bond as this wallet last read it (`bond`: state, asset, value,
  /// coin, withdrawable_at, required, covers, why) or its refusal, and the last watch
  /// (`watch_bond`) with when it ran. Developer mode shows them.
  Map<String, dynamic>? bond;
  LeafRefusal? bondError;
  Map<String, dynamic>? lastWatch;
  DateTime? lastWatchAt;
  LeafRefusal? watchError;

  /// The operator's bond, at care's pace, in either mode: read (a bond seen bonded is
  /// required from then on, so a wallet that saw one refuses to receive while it is
  /// gone or in notice), and watched: the wallet's evidence against the chain and the
  /// mempool, and a slash sent should the operator key have signed twice under one salt.
  Future<void> watchBond() async {
    if (!open) return;
    try {
      bond = Map<String, dynamic>.from(await run('bond') as Map);
      bondError = null;
    } catch (e) {
      bondError = LeafRefusal.of(e);
    }
    try {
      lastWatch = Map<String, dynamic>.from(await run('watch_bond', const {}) as Map);
      watchError = null;
    } catch (e) {
      watchError = LeafRefusal.of(e);
    }
    lastWatchAt = DateTime.now();
    notifyListeners();
  }

  static const careEvery = Duration(minutes: 10);
  static const _kCareAt = 'ambra.leaves.care_at';
  static const _kScanNext = 'ambra.leaves.scan_next';

  /// When care last ran, in this process or the scheduled job.
  static Future<DateTime?> careClock() async {
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getInt(_kCareAt);
      return t == null ? null : DateTime.fromMillisecondsSinceEpoch(t * 1000);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setCareClock(DateTime at) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kCareAt, at.millisecondsSinceEpoch ~/ 1000);
    } catch (_) {}
  }

  /// The kit wallet's next receive index (shared by both chains' addresses), kept so
  /// the scheduled job scans as far as the app does.
  static Future<int> scanNext() async {
    var n = BtcState.instance.unifiedNext;
    try {
      final p = await SharedPreferences.getInstance();
      final kept = p.getInt(_kScanNext) ?? 0;
      if (n > kept) {
        await p.setInt(_kScanNext, n);
      } else {
        n = kept;
      }
    } catch (_) {}
    return n;
  }

  /// A different wallet opened on this phone: its own clock and index.
  static Future<void> forgetCare() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kCareAt);
      await p.remove(_kScanNext);
      await p.remove(_kClaims);
    } catch (_) {}
  }

  /// The assets the operator serves supervised.
  List<String> supervisedAssets() => supervisedAssetsOf(info);

  /// What of [asset] its issuer has frozen for this wallet, in atoms (both modes show it
  /// under the asset's figure).
  BigInt frozenAtoms(String asset) => frozenAtomsOf(coins, balance)[asset] ?? BigInt.zero;

  /// Leaf atoms per asset, as the asset's figure counts them ([leafAtomsOf]).
  Map<String, BigInt> leafAtoms() => leafAtomsOf(balance);

  // -------------------------------------------------------------------------
  // The schedule while the app runs
  // -------------------------------------------------------------------------

  /// Whether the next pass is planned.
  @visibleForTesting
  bool get passPlanned => _timer?.isActive ?? false;
  /// A pass as the schedule runs it, while another is said to run ([ticking]).
  @visibleForTesting
  Future<void> tickForTest({required bool ticking}) async {
    _ticking = ticking;
    try {
      await _tick();
    } finally {
      _ticking = false;
    }
  }
  @visibleForTesting
  void stopPassesForTest() => _timer?.cancel();

  void _plan(Duration d) {
    _timer?.cancel();
    if (!open) return;
    _timer = Timer(d, () => _tick());
  }

  Future<void> _tick() async {
    if (!open) return;
    // Another pass runs (the opening sync, on start or on coming back): this one waits for it
    // rather than end the schedule, which nothing else plans again (RX1: no board in 25 min).
    if (_ticking) {
      debugPrint('[leaves] tick: a sync runs, again in 5 s');
      return _plan(const Duration(seconds: 5));
    }
    _ticking = true;
    var wait = tick;
    try {
      final s = await run('schedule') as Map<String, dynamic>?;
      schedule = s;
      final d = syncDecision(s, _heldFor, inFlight(coins, participations));
      _heldFor = d.held;
      if (d.sync) {
        await syncNow(by: d.why!);
      } else if (freshRequestWaits(s, DateTime.now()) && _mailDue(DateTime.now())) {
        final mb = await _mailboxRead();
        for (final a in arrivals(mb)) {
          arrivedCount++;
          _noteArrived(a);
          await notifyArrived(a, channel: _channel);
        }
        if (arrivals(mb).isNotEmpty) await refresh();
      }
      // What vests later, read at its own pace (at most every two minutes).
      await _readsBetween();
      await readClaims();
      lastError = null;
      wait = nextAsk(schedule, inFlight(coins, participations));
      // User mode: a receive code handed out lately is read for every few seconds, so a
      // payment to it shows at once.
      if (!DevMode.instance.on && freshRequestWaits(s, DateTime.now()) && wait > fastAsk) wait = fastAsk;
    } catch (e) {
      lastError = LeafRefusal.of(e);
    }
    _ticking = false;
    notifyListeners();
    _plan(wait);
    unawaited(autoBoard().then((_) => autoRefreshReceived()));
    unawaited(followAddressPayments());
    // What waits on the chain is sped up by itself in default mode (speed_up_service.dart).
    unawaited(SpeedUpService.instance.tick());
    // A wallet from before its assets lived in the tree moves its Lightning balances here.
    unawaited(LightningToArk.instance.tickAssets());
  }

  /// Plans the scheduled job from the library's schedule, so a pass runs whether
  /// or not the app is still open then.
  Future<void> _planJob() async {
    final s = schedule;
    if (s == null) return;
    final wake = leaves.leavesWakeIn(scheduleJson: jsonEncode(s), coinsJson: jsonEncode(coins));
    try {
      if (wake == null) {
        await _channel.invokeMethod('cancel');
      } else {
        await _channel.invokeMethod('schedule', {'seconds': wake.toInt()});
      }
    } catch (_) {/* host tests: no platform */}
  }

  Future<void> _foreground(bool on) async {
    try {
      await _channel.invokeMethod(on ? 'startService' : 'stopService');
    } catch (_) {/* host tests: no platform */}
  }
}

/// Whether `care` runs now: never yet ([last] null), or [LeafService.careEvery] since.
bool careDue(DateTime? last, DateTime now) => last == null || now.difference(last) >= LeafService.careEvery;

/// A payment through a release: how often the wallet syncs while it waits for the round
/// that frees the planned coins, how long it waits at most, and how many releases one
/// payment may need (a release can fall short by the new leaf's own margins).
const kReleasePoll = Duration(seconds: 15);
const kReleaseWait = Duration(hours: 3);
const kReleaseTries = 3;

/// The refusal when the round that frees the coins does not come in time.
const kReleaseTimeout =
    'the next round did not free the coins this payment needs in time; nothing was paid, and the payment can be asked again';

/// `care`'s arguments: the scan reaches 20 past the kit wallet's next receive index, so a
/// claim named by any address the wallet handed out is found (the leaf wallet's own
/// index counter is separate from the kit's). Its planning reach is the library's own: a
/// leaf of a round is planned once its first step could run within ten days, so it stays
/// free to trade and pay out of round for most of its life.
///
/// It also cares for the wallet's channels (`channels`): each read and its credit folded, and
/// one opened in each asset the operator makes channels of, from half of the wallet's leaves of
/// it, so a payment between two such wallets is final for the receiver at once.
Map<String, dynamic> careArgs(int kitNextIndex) => {'channels': true, 'scan': kitNextIndex + 20};

/// Whether a care answer opened a channel or folded one's credit ([careArgs]' `channels`).
bool careMovedChannels(Map? care) {
  final ch = care?['channels'];
  if (ch is! Map) return false;
  final folded = ch['folded'] is List ? (ch['folded'] as List).length : 0;
  final opened = ch['opened'] is List ? (ch['opened'] as List).where((o) => o is Map && o['participation'] != null).length : 0;
  return folded + opened > 0;
}

/// The credit a channel read brought in: each channel whose credit grew, and by how much
/// (`{leaf_id, asset, value, kind: 'channel'}`). The web wallet's `channelArrivals`.
List<Map<String, dynamic>> channelArrivals(List<dynamic>? before, List<dynamic>? after) {
  BigInt big(Object? v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
  final was = {
    for (final c in before ?? const [])
      if (c is Map && c['error'] == null) c['leaf_id']: big(c['credit'])
  };
  return [
    for (final c in after ?? const [])
      if (c is Map && c['error'] == null && was.containsKey(c['leaf_id']) && big(c['credit']) > was[c['leaf_id']]!)
        {'leaf_id': c['leaf_id'], 'asset': c['asset'], 'value': '${big(c['credit']) - was[c['leaf_id']]!}', 'kind': 'channel'}
  ];
}

/// The wallet's channels a payer can pay now, by asset (live, their round final): what a receive
/// code names (the library's `receive` puts them under `channels`). The web wallet's
/// `payableChannels`.
Map<String, String> payableChannels(List<dynamic>? channels) {
  final m = <String, String>{};
  for (final c in channels ?? const []) {
    if (c is Map && c['coin_state'] == 'live' && c['final'] == true && !m.containsKey('${c['asset']}')) {
      m['${c['asset']}'] = '${c['leaf_id']}';
    }
  }
  return m;
}

/// A payment waiting for the round that frees the planned coins it needs.
class ReleaseWait {
  ReleaseWait({required this.command, required this.coins, this.asset, required this.since});
  final String command;
  final List<String> coins;
  final String? asset;
  final DateTime since;
}

/// Whether the coins a release gave up are done with: none of them is still the wallet's
/// to spend or in the round that gives them up (their round final, the forfeits handed
/// over at sync), so the new leaves are held and the payment can be asked again.
bool releaseDone(List<dynamic> coins, List<String> released) {
  const releasing = {'live', 'pending', 'given', 'offered', 'sending', 'forfeited'};
  final by = {for (final c in coins.whereType<Map>()) '${c['leaf_id']}': c};
  return released.every((id) {
    final c = by[id];
    return c == null || !releasing.contains(c['state']);
  });
}

/// The current coin of each open or stopped plan (the leaf its next step gives up), with
/// its plan: `plans`' answer, a list or `{"plans": [...]}`.
Map<String, Map> plannedCoins(Object? plans) {
  final list = plans is Map ? plans['plans'] : plans;
  final out = <String, Map>{};
  if (list is! List) return out;
  for (final p in list.whereType<Map>()) {
    if (p['state'] != 'open' && p['state'] != 'stopped') continue;
    String? current;
    for (final st in (p['steps'] as List?) ?? const []) {
      if (st is Map && st['leaf_id'] != null) current = '${st['leaf_id']}';
    }
    out[current ?? '${p['coin']}'] = p;
  }
  return out;
}

/// Runs [command] through [run]; when the library refuses it with kind `planned` (the
/// unplanned coins fall short, the planned coins it names would cover it), gives those
/// coins up in the next round (`plan_release`), syncs every [poll] until none of them is
/// held or in that round any more, at most [wait], and asks again; at most [tries]
/// releases. Every other answer and refusal is the library's, untouched. [onWait] hears
/// the wait start (a [ReleaseWait]) and end (null); [synced] each sync's answer.
Future<dynamic> payThroughRelease(
  String command,
  Map<String, dynamic> args, {
  required Future<dynamic> Function(String command, Map<String, dynamic> args) run,
  Future<void> Function(Duration)? sleep,
  DateTime Function()? now,
  void Function(ReleaseWait? wait)? onWait,
  Future<void> Function(Object? sync)? synced,
  Duration poll = kReleasePoll,
  Duration wait = kReleaseWait,
  int tries = kReleaseTries,
}) async {
  final clock = now ?? DateTime.now;
  final pause = sleep ?? (d) => Future<void>.delayed(d);
  for (var i = 0;; i++) {
    try {
      return await run(command, args);
    } catch (e) {
      final r = LeafRefusal.of(e);
      if (r.kind != 'planned' || r.release.isEmpty || i >= tries) throw r;
      onWait?.call(ReleaseWait(command: command, coins: r.release, asset: r.asset, since: clock()));
      try {
        await run('plan_release', {'leaves': r.release});
        final until = clock().add(wait);
        for (;;) {
          try {
            final v = await run('sync', const {});
            await synced?.call(v);
          } catch (_) {}
          List<dynamic>? coins;
          try {
            coins = (await run('coins', const {}) as List?) ?? const [];
          } catch (_) {}
          if (coins != null && releaseDone(coins, r.release)) break;
          if (!clock().isBefore(until)) throw LeafRefusal('refused', kReleaseTimeout);
          await pause(poll);
        }
      } finally {
        onWait?.call(null);
      }
    }
  }
}

/// What a `care` answer did, counted for developer mode: claims taken up, plans
/// cancelled, coins planned, coins refreshed into a round, coins not yet within reach,
/// and each part's refusals.
({int claimed, int cancelled, int planned, int refreshing, int later, List<String> refusals}) careSummary(
    Map<String, dynamic>? care) {
  if (care == null) return (claimed: 0, cancelled: 0, planned: 0, refreshing: 0, later: 0, refusals: const []);
  final refusals = <String>[];
  int count(Object? list, bool Function(Map) ok) {
    if (list is! List) return 0;
    var n = 0;
    for (final e in list) {
      if (e is! Map) continue;
      final err = e['error'] ?? e['refused'];
      if (err != null) {
        refusals.add('${e['coin'] ?? e['claim'] ?? e['plan_id'] ?? ''}: $err');
      } else if (ok(e)) {
        n++;
      }
    }
    return n;
  }

  final claims = care['claims'];
  if (claims is Map && claims['error'] != null) refusals.add('claims: ${claims['error']}');
  return (
    claimed: count(claims, (e) => e['taken_up'] != null),
    cancelled: count(care['cancelled'], (_) => true),
    planned: count(care['planned'], (_) => true),
    refreshing: count(care['refreshing'], (_) => true),
    later: (care['not_yet_planned'] as num?)?.toInt() ?? 0,
    refusals: refusals,
  );
}

/// How long [LeafService.takeIn] reads the mailbox for a payment another service says it made,
/// and how often.
const takeInWithin = Duration(seconds: 45);
const takeInEvery = Duration(seconds: 2);

/// Reads ([read]: the wallet's mailbox) until [came] says what is awaited has arrived, or [within]
/// has passed: a read that has not answered by then is not waited for (the library may be busy
/// with a sync; what it takes in later is told as any arrival is), and the next read comes
/// [every] after the last. Answers [came].
Future<bool> readUntil({
  required bool Function() came,
  required Future<void> Function() read,
  Duration within = takeInWithin,
  Duration every = takeInEvery,
  DateTime Function()? now,
  Future<void> Function(Duration)? sleep,
}) async {
  final clock = now ?? DateTime.now;
  final wait = sleep ?? (d) => Future<void>.delayed(d);
  final until = clock().add(within);
  Duration left() {
    final d = until.difference(clock());
    return d.isNegative ? Duration.zero : d;
  }

  while (!came() && left() > Duration.zero) {
    final answered = await Future.any<bool>([
      read().then((_) => true, onError: (_) => true),
      Future<bool>.delayed(left(), () => false),
    ]);
    if (!answered || came() || left() == Duration.zero) break;
    await wait(every < left() ? every : left());
  }
  return came();
}

/// The coins a mailbox read accepted.
List<Map<String, dynamic>> arrivals(Object? mailbox) {
  if (mailbox is! Map) return const [];
  final a = mailbox['accepted'];
  if (a is! List) return const [];
  return [for (final c in a) if (c is Map) Map<String, dynamic>.from(c)];
}

/// Whether something is moving (a coin pending, being sent, given or on its way
/// out, or a participation not done): then the app syncs every 30 s.
bool inFlight(List<dynamic> coins, List<dynamic> participations) {
  const moving = {'pending', 'sending', 'given', 'offered', 'paying', 'receiving', 'exiting', 'forfeited'};
  if (coins.any((c) => c is Map && moving.contains(c['state']))) return true;
  const done = {'done', 'refused', 'void', 'expired', 'completed', 'released'};
  return participations.any((p) => p is Map && p['state'] != null && !done.contains(p['state']));
}

/// Whether the app syncs now. The time to hold to is the schedule's `next_sync_at` as
/// it was first given after the last sync ([held]): a schedule that moves that time on
/// at every read (a coin given to a refresh reads now + 1 h each time, and is not `due`
/// until its home date) is still synced once the time first given arrives. Also when
/// the schedule is due, and while something moves. [held] in the answer is the time to
/// hold to next, null once a sync runs. The browser wallets hold the same rule.
({bool sync, String? why, num? held}) syncDecision(Map<String, dynamic>? schedule, num? held, bool moving) {
  final next = schedule?['next_sync_at'];
  final now = schedule?['now'];
  final at = held ?? (next is num ? next : null);
  if (schedule?['due'] == true) return (sync: true, why: 'schedule', held: null);
  if (at != null && now is num && now >= at) return (sync: true, why: 'time', held: null);
  if (moving) return (sync: true, why: 'moving', held: null);
  return (sync: false, why: null, held: at);
}

/// A receive request handed out in the last hour: the app reads the mailbox every
/// tick, so a payment shows at once.
bool freshRequestWaits(Map<String, dynamic>? schedule, DateTime now) {
  final rs = schedule?['receive_requests'];
  if (rs is! List) return false;
  final t = schedule?['now'];
  return rs.any((r) {
    if (r is! Map || r['state'] != 'waiting') return false;
    final asked = r['asked_at'];
    if (asked is! num || t is! num) return true;
    return t - asked < 3600;
  });
}

/// When the app asks the schedule again: 30 s while something moves, else at the
/// schedule's `next_sync_at` but within a minute.
Duration nextAsk(Map<String, dynamic>? schedule, bool moving) {
  if (moving) return const Duration(seconds: 30);
  final next = schedule?['next_sync_at'];
  final now = schedule?['now'];
  if (next is num && now is num) {
    final s = (next - now).clamp(5, LeafService.tick.inSeconds).toInt();
    return Duration(seconds: s);
  }
  return LeafService.tick;
}

/// The notification for one coin received.
Future<void> notifyArrived(Map<String, dynamic> a, {required MethodChannel channel}) async {
  final asset = '${a['asset'] ?? ''}';
  final label = SeqAssets.labelFor(asset);
  final amount = formatAtoms('${a['value'] ?? '0'}', label.precision);
  try {
    await channel.invokeMethod('notify', {
      'id': '${a['leaf_id'] ?? asset}',
      'title': 'Payment received',
      'body': '$amount ${label.ticker} arrived.',
    });
  } catch (_) {/* host tests: no platform */}
}

/// The scheduled job's pass, from a Flutter engine with no UI: open the leaf
/// wallet from the app's own storage, sync, notify each coin received, and say
/// when to run next. Returns `{ok, wake_in, summary}` for the host.
Future<Map<String, dynamic>> leafBackgroundPass(MethodChannel host) async {
  final m = await WalletRepository.instance.readMnemonic();
  if (m == null) return {'ok': true, 'wake_in': null, 'summary': 'no wallet'};
  final dir = await LeafService.dataDir();
  // Care rides along when it is due, on the clock the app keeps too.
  final now = DateTime.now();
  final care = careDue(await LeafService.careClock(), now) ? careArgs(await LeafService.scanNext()) : null;
  final out = jsonDecode(await leaves.leavesJob(
      dir: dir,
      mnemonic: m,
      nodePassword: await LeafService.nodePassword() ?? '',
      careJson: care == null ? '' : jsonEncode(care))) as Map<String, dynamic>;
  if (out['joined'] == false) return {'ok': true, 'wake_in': null, 'summary': 'no leaf wallet'};
  if (care != null) await LeafService.setCareClock(now);
  final arrived = arrivals({'accepted': out['arrived']});
  for (final a in arrived) {
    await notifyArrived(a, channel: host);
  }
  final s = out['schedule'] as Map?;
  return {
    'ok': true,
    'wake_in': out['wake_in'],
    'summary': 'arrived ${arrived.length}; next_sync_at ${s?['next_sync_at']}; now ${s?['now']}'
        '${care == null ? '' : '; care ${careSummary(out['care'] is Map ? Map<String, dynamic>.from(out['care'] as Map) : null)}'}',
  };
}

// ---------------------------------------------------------------------------
// Supervised assets
// ---------------------------------------------------------------------------

List<Map> _operatorAssets(Map? info) {
  final si = info?['server_info'];
  final a = si is Map ? si['assets'] : null;
  return a is List ? a.whereType<Map>().toList() : const [];
}

/// The assets the operator serves under the supervised profile (`info`'s `supervised`
/// entry): a coin of one is held only as a landing-1 leaf, landing in the wallet's own
/// key (`info.landing_address`).
List<String> supervisedAssetsOf(Map? info) =>
    [for (final a in _operatorAssets(info)) if (a['supervised'] != null && a['asset'] is String) a['asset'] as String];

/// The assets the operator serves issuer-operated (`info`'s `issuer` entry): the issuer
/// mints each round's float through the asset's mint limiter, and every batch's sweep can
/// only burn.
List<String> issuerAssetsOf(Map? info) =>
    [for (final a in _operatorAssets(info)) if (a['issuer'] != null && a['asset'] is String) a['asset'] as String];

/// A leaf's batch profile in developer mode's words (`coins`' `batch_profile`), or null.
String? batchProfileLine(Object? profile) {
  if (profile == null) return null;
  return profile == 'issuer-operated' ? 'Batch: issuer-operated: its sweep can only burn' : 'Batch: $profile: its sweep pays the operator';
}

/// What of each asset its issuer has frozen for this wallet: every held leaf whose
/// landing the node shows frozen (or the asset paused), and every on-chain coin the leaf
/// wallet counts frozen (a leaf taken home by its landing stays frozen there).
Map<String, BigInt> frozenAtomsOf(List<dynamic> coins, Map? balance) {
  const held = {'pending', 'live', 'offered', 'sending', 'given', 'forfeited', 'exiting'};
  final out = <String, BigInt>{};
  void add(Object? a, Object? v) {
    if (a == null) return;
    out['$a'] = (out['$a'] ?? BigInt.zero) + (BigInt.tryParse('${v ?? 0}') ?? BigInt.zero);
  }

  for (final c in coins.whereType<Map>()) {
    final f = c['frozen'];
    if (!held.contains(c['state']) || f is! Map) continue;
    // A leaf whose exit's claim is out is the on-chain coin the claim made, counted below.
    if (c['state'] == 'exiting' && '${c['note'] ?? ''}'.startsWith('claimed by')) continue;
    if (f['frozen'] == true || f['paused'] == true) add(c['asset'], c['value']);
  }
  final on = balance?['sequentia_onchain_frozen'];
  if (on is Map) on.forEach(add);
  return out;
}

/// The one plain sentence a frozen holding gets, in either mode, under its asset's figure.
String frozenSentence(String amount, String ticker) =>
    "$amount $ticker is frozen by its issuer: it can't be sent until the issuer lifts the freeze.";

/// User mode's words for a payment of a frozen holding.
const kFrozenRefusal = 'This asset is frozen by its issuer for this wallet: nothing was sent.';

/// User mode's words for a payment the operator's signer refuses for what it asks, which
/// it would refuse again however often it were asked (the server's `declined`): the
/// library has put the coins back.
const kDeclinedRefusal = 'This payment was declined; nothing was sent.';

/// User mode's words when the operator declines what an out-of-date wallet asks (one that
/// hands its forfeits over only after a round is broadcast, to an operator building batches
/// without a sweep) and says to update it: in its words, plainly, as the web wallet says it.
const kUpdateRefusal = 'This wallet is out of date for this: update it, then try again. Nothing was taken.';

/// A refusal in user mode's words: one the operator declines (asking for the wallet to be
/// updated, or not), a refusal of the
/// operator's bond, and a frozen holding, said plainly; every other refusal as the
/// library says it.
LeafRefusal plainRefusal(LeafRefusal e) {
  final vesting = vestingRefusal(e.code, e.message);
  if (vesting != null) return LeafRefusal(e.kind, vesting, code: e.code, status: e.status, plain: true);
  if (e.code == 'declined' && RegExp(r'\bupdate the wallet\b', caseSensitive: false).hasMatch(e.message)) {
    return LeafRefusal(e.kind, kUpdateRefusal, code: e.code, status: e.status, plain: true);
  }
  if (e.code == 'declined') return LeafRefusal(e.kind, kDeclinedRefusal, code: e.code, status: e.status, plain: true);
  if (bondRefusal(e)) return LeafRefusal(e.kind, kBondRefusal, code: e.code, status: e.status, plain: true);
  if (e.code == 'frozen' || RegExp(r'\bfrozen\b|\bpaused\b', caseSensitive: false).hasMatch(e.message)) {
    return LeafRefusal(e.kind, kFrozenRefusal, code: e.code, status: e.status, plain: true);
  }
  return e;
}

/// The user composer's pairs as the operator serves them: a pair with a supervised asset
/// keeps only the in-tree swap with a live maker (`leaf-maker`), since the operator
/// serves no take, no resting order and no Lightning payment in such an asset.
Map? servedPairs(Map? pairs, List<String> supervised) {
  if (pairs == null || supervised.isEmpty || pairs['chains'] is! Map) return pairs;
  final sup = supervised.toSet();
  final chains = <String, dynamic>{};
  (pairs['chains'] as Map).forEach((g, c) {
    if (c is! Map) {
      chains['$g'] = c;
      return;
    }
    chains['$g'] = {
      ...c,
      'pairs': [
        for (final p in (c['pairs'] as List?) ?? const [])
          if (p is Map && (sup.contains(p['pay']) || sup.contains(p['receive'])))
            {...p, 'sources': [for (final x in (p['sources'] as List?) ?? const []) if (x == 'leaf-maker') x]}
          else
            p,
      ],
    };
  });
  return {...pairs, 'chains': chains};
}

// ---------------------------------------------------------------------------
// The operator's bond
// ---------------------------------------------------------------------------

/// A refusal of the operator's equivocation bond (missing, in notice, or worth less than
/// what the wallet would hold out of round on it): the library's gate in `receive` and
/// the swaps.
bool bondRefusal(LeafRefusal e) => RegExp(r'\bbond\b', caseSensitive: false).hasMatch(e.message);

/// User mode's words for it.
const kBondRefusal = 'Not accepted: the security deposit that backs these instant payments is missing or being withdrawn, '
    'so this wallet takes no payment that rests on it. Nothing was signed.';

/// Leaf atoms per asset, as the asset's figure counts them: the library's `held` (its
/// leaves and its own on-chain coins together, a leaf whose exit's claim is out counted
/// once, as the claim's output) less its `sequentia_onchain`, whose coins sit at the
/// phrase's own keys, where the main wallet's on-chain scan counts them. A library answer
/// with no `held` is read by its states (`arca`).
Map<String, BigInt> leafAtomsOf(Map? balance) {
  final out = <String, BigInt>{};
  BigInt big(Object? v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
  final held = balance?['held'];
  if (held is Map) {
    final on = balance?['sequentia_onchain'];
    held.forEach((asset, v) {
      final l = big(v) - (on is Map ? big(on[asset]) : BigInt.zero);
      if (l > BigInt.zero) out['$asset'] = l;
    });
    return out;
  }
  final arca = balance?['arca'];
  if (arca is! Map) return out;
  arca.forEach((asset, states) {
    if (states is! Map) return;
    var sum = BigInt.zero;
    states.forEach((_, v) => sum += big(v));
    if (sum > BigInt.zero) out['$asset'] = sum;
  });
  return out;
}


/// The smallest leaf of each asset the operator serves (`info`'s `assets`), in atoms;
/// an asset with no smallest leaf published is left out (nothing of it boards now).
Map<String, BigInt> minLeaves(Map? info) {
  final out = <String, BigInt>{};
  // The library's `info` carries the operator's own under `server_info`.
  final si = info?['server_info'];
  final list = si is Map && si['assets'] is List ? si['assets'] : info?['assets'];
  if (list is! List) return out;
  for (final a in list.whereType<Map>()) {
    final v = BigInt.tryParse('${a['min_leaf'] ?? ''}');
    if (a['asset'] is String && v != null) out[a['asset'] as String] = v;
  }
  return out;
}

/// Boards everything [held] of [asset] less the board's fee, paid in the asset itself, through
/// the library's [run]: the fee of a board of [min] first, then a quote of [held] less that fee,
/// asked again (at most [tries] times) until the fee it names leaves room for itself. The
/// library prices a board's coins at a size before it knows the real one, so a quote of all but
/// the real fee can be refused for want of a few atoms: the refusal doubles the room left. The
/// board is signed only on the fee its own quote named (`shown`). Answers the amount boarded
/// and its fee, or null when nothing was boarded ([stop] true: a person asked for something).
/// The web wallet's `boardAll` (default-arca.js).
Future<(BigInt, BigInt)?> boardAll(Future<dynamic> Function(String, [Map<String, dynamic>]) run,
    {required String asset, required BigInt held, required BigInt min, bool Function()? stop, int tries = 3}) async {
  var fee = boardFee(await run('board_quote', {'asset': asset, 'amount': min.toString(), 'fee_asset': asset}));
  if (fee == null) return null;
  for (var i = 0; i < tries; i++) {
    final v = held - fee!;
    if (v < min || v <= BigInt.zero) return null;
    Object? q;
    try {
      q = await run('board_quote', {'asset': asset, 'amount': v.toString(), 'fee_asset': asset});
    } on LeafRefusal catch (e) {
      if (!e.message.contains('needs')) rethrow;
      fee = fee * BigInt.two + BigInt.one;
      continue;
    }
    final f = boardFee(q);
    if (f == null) return null;
    if (v + f <= held) {
      if (stop != null && stop()) return null;
      await run('board', {'asset': asset, 'amount': v.toString(), 'fee_asset': asset, 'shown': (q as Map)['fee']});
      return (v, f);
    }
    fee = f;
  }
  return null;
}

/// The most minutes a payment to an address out of the tree takes to reach the receiving
/// wallet's figure, from the operator's interval between settlements ([roundSeconds]) and the
/// chain's block interval ([blockSeconds], 60 when it says none). The whole way, not the
/// settlement alone: the settlement's block, the paying wallet handing over its part once that
/// block is in, the operator's payment to the address and its block, and the wallets' own passes
/// and reads of the chain: four blocks and four minutes beside the settlement, rounded up to five
/// minutes. On the testnet (a settlement a minute, a block a minute) that is ten minutes; payments
/// measured there took three to six. The web wallet's `arrivalMinutes` (default-arca.js).
int? addressArrivalMinutes(Object? roundSeconds, Object? blockSeconds) {
  final n = roundSeconds is num ? roundSeconds : num.tryParse('${roundSeconds ?? ''}');
  if (n == null || n <= 0) return null;
  final b0 = blockSeconds is num ? blockSeconds : num.tryParse('${blockSeconds ?? ''}');
  final b = b0 != null && b0 > 0 ? b0 : 60;
  final m = ((n + 4 * b + 240) / 60).ceil();
  final five = (m / 5).ceil() * 5;
  return five < 5 ? 5 : five;
}

/// Whether the library's answer to an `offboard` is a payment already on its way: the same amount
/// of the same asset to the same address asked while the first is still under way, which the
/// library goes on with and does not send again. The web wallet's `offboardOutcome`.
bool offboardAlready(Object? answer) => answer is Map && answer['already'] == true;

/// A board quote's fee in atoms of the boarded asset (`{"fee": {"asset", "amount"}}`).
BigInt? boardFee(Object? quote) {
  final fee = quote is Map ? quote['fee'] : null;
  if (fee is! Map) return null;
  return BigInt.tryParse('${fee['amount'] ?? ''}');
}

/// What of each asset is on its way to the wallet: its leaves not final yet (the
/// balance's `arca` standing `pending`), and the coins the operator announced and has not
/// handed over yet (the schedule's `pending_coins`, each `{asset, value}`), which no
/// figure counts until they come.
/// What of each asset the library marks `redoing` in [coins]: live once, then out of the chain
/// with the Bitcoin block it rested on, being redone. Still the wallet's, and counted.
Map<String, BigInt> redoingAtomsOf(List<dynamic>? coins) {
  final out = <String, BigInt>{};
  for (final c in coins ?? const []) {
    if (c is! Map || c['redoing'] != true || c['asset'] == null) continue;
    final n = BigInt.tryParse('${c['value'] ?? 0}') ?? BigInt.zero;
    out['${c['asset']}'] = (out['${c['asset']}'] ?? BigInt.zero) + n;
  }
  return out;
}

/// What of each asset the library's [balance] counts as `kept_safe`: taken on the chain under its
/// owner's key while the wallet was away, being put back. Still the wallet's, and counted.
Map<String, BigInt> keptSafeAtomsOf(Map? balance) {
  final out = <String, BigInt>{};
  final arca = balance is Map ? balance['arca'] : null;
  if (arca is! Map) return out;
  for (final e in arca.entries) {
    final states = e.value;
    if (states is! Map) continue;
    final n = BigInt.tryParse('${states['kept_safe'] ?? 0}') ?? BigInt.zero;
    if (n > BigInt.zero) out['${e.key}'] = n;
  }
  return out;
}

Map<String, BigInt> arrivingAtomsOf(Map? balance, [Map? schedule]) {
  final out = <String, BigInt>{};
  void add(Object? asset, Object? v) {
    final n = BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
    if (asset == null || n <= BigInt.zero) return;
    out['$asset'] = (out['$asset'] ?? BigInt.zero) + n;
  }

  final arca = balance?['arca'];
  if (arca is Map) {
    arca.forEach((asset, by) {
      if (by is Map) add(asset, by['pending']);
    });
  }
  final announced = schedule?['pending_coins'];
  if (announced is List) {
    for (final c in announced.whereType<Map>()) {
      add(c['asset'], c['value']);
    }
  }
  return out;
}

/// The JSON of a receive request ([text] is `<word>:<hex of its JSON>`, its `kind`
/// "request") naming [operator] and [genesis], or null for any other text.
Map<String, dynamic>? requestFor(String text, {required String operator, required String genesis}) {
  final t = text.trim();
  final colon = t.indexOf(':');
  if (colon <= 0) return null;
  final word = t.substring(0, colon);
  final hex = t.substring(colon + 1);
  if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(word) || hex.isEmpty || hex.length.isOdd) return null;
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
  try {
    final bytes = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    final j = jsonDecode(utf8.decode(bytes));
    if (j is! Map) return null;
    final isRequest = j['kind'] == 'request' || j.containsKey('arca_request');
    if (!isRequest || j['operator'] != operator || j['genesis_hash'] != genesis) return null;
    return Map<String, dynamic>.from(j);
  } catch (_) {
    return null;
  }
}


/// The leaf library finds its on-chain coins by a gap of 20 unused keys past the last key it
/// handed out or saw holding an UNSPENT coin (its node's scantxoutset), where the main wallet
/// finds them by a gap past the last key with any history. Keys used and spent before the leaf
/// wallet looked, or skipped by the address shared with Bitcoin, leave a coin the balance shows at
/// a key the library never reads: default mode never boards it, and a trade finds nothing to pay
/// from. So the library is handed keys (its `address` command, each call the next key) until it
/// has handed out [want] (the main wallet's next receive index), once per key: [had] is how many
/// it was handed before, and [remember] keeps the count. Stops at the first refusal, or when
/// [stop] says a person's action waits. -> how many keys were handed now.
Future<int> coverReceiveKeys({
  required int want,
  required int had,
  required Future<void> Function() handOne,
  required Future<void> Function(int handed) remember,
  bool Function()? stop,
  void Function(String)? log,
}) async {
  if (want <= had) return 0;
  var n = 0;
  for (var i = had; i < want; i++) {
    if (stop != null && stop()) break;
    try {
      await handOne();
    } catch (e) {
      log?.call('[leaves] handing the leaf wallet its keys: $e');
      break;
    }
    n++;
    await remember(i + 1);
  }
  if (n > 0) log?.call('[leaves] the leaf wallet reads its on-chain coins up to key ${had + n + 20} now ($n key(s) handed to it)');
  return n;
}

/// The transactions the library's `boards` names: each board's status from the operator
/// (`server.txid`).
Set<String> boardTxidsOf(Object? boards) => {
      if (boards is List)
        for (final b in boards.whereType<Map>())
          if (b['server'] is Map && (b['server'] as Map)['txid'] is String) (b['server'] as Map)['txid'] as String,
    };
