import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/leaves.dart' as leaves;
import 'btc_state.dart';
import 'config.dart';
import 'dev_mode.dart';
import 'format.dart';
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
  Future<void> start() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    final dir = await dataDir();
    try {
      joined = await leaves.leavesExists(dir: dir, mnemonic: m);
    } catch (e) {
      lastError = LeafRefusal.of(e);
      joined = false;
    }
    operator = await savedOperator();
    if (!joined) {
      notifyListeners();
      // User mode joins the default node's operator by itself, in the background.
      unawaited(autoJoin());
      return;
    }
    try {
      await leaves.leavesOpen(dir: dir, mnemonic: m, nodePassword: await nodePassword() ?? '');
      open = true;
      lastError = null;
    } catch (e) {
      lastError = LeafRefusal.of(e);
    }
    notifyListeners();
    if (open) {
      await _foreground(true);
      await refresh();
      await openingSync();
      _plan(tick);
    }
  }

  /// One sync when the leaf wallet opens or the app comes back, whatever the schedule
  /// says, then care. The schedule wakes a planned coin only at its plan's `sync_by`,
  /// so a wallet back after an expiry would otherwise show the coin a plan's step
  /// replaced until then; and a wallet back from a while away may have payments in
  /// its mailbox or an exit to move on.
  Future<void> openingSync({String by = 'open'}) async {
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
  }

  /// Stops the schedule and closes the wallet; the scheduled job takes over.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _joinTimer?.cancel();
    _joinTimer = null;
    if (open) leaves.leavesClose();
    open = false;
    info = null;
    await _foreground(false);
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
    if (!open || DevMode.instance.on || _boarding || personBusy) return;
    final served = minLeaves(info);
    final on = balance?['sequentia_onchain'];
    if (on is! Map || served.isEmpty) return;
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
          final first = await run('board_quote', {'asset': asset, 'amount': held.toString(), 'fee_asset': asset});
          final fee = boardFee(first);
          if (fee == null) continue;
          final amount = held - fee;
          if (amount < min) continue;
          final quote = await run('board_quote', {'asset': asset, 'amount': amount.toString(), 'fee_asset': asset});
          if (boardFee(quote) != fee || _asking > 0) continue;
          await run('board', {
            'asset': asset,
            'amount': amount.toString(),
            'fee_asset': asset,
            'shown': (quote as Map)['fee'],
          });
          boarded = true;
          _boardRefused.remove(asset);
          autoBoardError = null;
        } catch (err) {
          autoBoardError = LeafRefusal.of(err);
          _boardRefused[asset] = DateTime.now();
        }
      }
    } finally {
      _boarding = false;
    }
    if (boarded) await refresh();
  }

  /// What of each asset is arriving: leaves not final yet (a board, a payment in
  /// flight), shown under the asset's one figure until they are.
  Map<String, BigInt> arrivingAtoms() => arrivingAtomsOf(balance, schedule);

  /// The operator's round interval in whole minutes (`info.fills.round_interval_seconds`),
  /// or null when it publishes none: how long a payment to an address takes.
  int? roundMinutes() {
    final s = (info?['fills'] is Map) ? (info!['fills'] as Map)['round_interval_seconds'] : null;
    return s is num && s > 0 ? (s / 60).ceil() : null;
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
      // Asked for, never waited on: the wallet goes on while the person answers.
      unawaited(Permission.notification.request().then((_) {}, onError: (_) {}));
      await _foreground(true);
      await refresh();
      _plan(tick);
      return out;
    } catch (e) {
      throw LeafRefusal.of(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Runs one of the library's commands and answers its `result`. Throws a
  /// [LeafRefusal] in the library's words.
  Future<dynamic> run(String command, [Map<String, dynamic> args = const {}]) async {
    if (!open) throw LeafRefusal('refused', 'the leaf wallet is not open');
    try {
      final out = jsonDecode(await leaves.leavesRun(command: command, argsJson: jsonEncode(args)));
      return (out as Map)['result'];
    } catch (e) {
      throw LeafRefusal.of(e);
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
  Future<dynamic> pay(String command, [Map<String, dynamic> args = const {}, bool plain = false]) async {
    _asking++;
    try {
      return await payThroughRelease(
        command,
        args,
        run: run,
        synced: (v) async {
          lastSync = DateTime.now();
          for (final a in arrivals(v is Map ? v['mailbox'] : null)) {
            arrivedCount++;
          await notifyArrived(a, channel: _channel);
          }
        },
        onWait: (w) {
          releasing = w;
          notifyListeners();
        },
      );
    } on LeafRefusal catch (e) {
      throw plain ? plainRefusal(e) : e;
    } finally {
      _asking--;
      personActed();
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
    try {
      plans = await run('plans');
    } catch (_) {}
    // The operator's assets (which it serves supervised or issuer-operated) and the
    // landing key, read once per open.
    if (info == null) {
      try {
        info = Map<String, dynamic>.from(await run('info') as Map);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// A sync now: what the library does on its own (the mailbox, refreshes, every
  /// coin's way home), and a notification per coin received.
  Future<Map<String, dynamic>> syncNow({String by = 'user'}) async {
    final r = await run('sync') as Map<String, dynamic>;
    _heldFor = null;
    lastSync = DateTime.now();
    for (final a in arrivals(r['mailbox'])) {
      arrivedCount++;
          await notifyArrived(a, channel: _channel);
    }
    await careIfDue();
    await refresh();
    return r;
  }

  /// Runs the library's `care` when it is due: at the first sync after the app
  /// starts, then at most every [careEvery] (the scheduled job keeps the same
  /// clock). It takes up every claim named by an address the wallet handed out (the
  /// scan reaches 20 past the wallet's next receive index), cancels each plan whose
  /// coin moved, plans every leaf of a round, and refreshes into a round a coin no
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
    } catch (e) {
      careError = LeafRefusal.of(e);
    }
    lastCareAt = at;
    await setCareClock(at);
    notifyListeners();
    await watchBond();
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

  void _plan(Duration d) {
    _timer?.cancel();
    if (!open) return;
    _timer = Timer(d, () => _tick());
  }

  Future<void> _tick() async {
    if (!open || _ticking) return;
    _ticking = true;
    var wait = tick;
    try {
      final s = await run('schedule') as Map<String, dynamic>?;
      schedule = s;
      final d = syncDecision(s, _heldFor, inFlight(coins, participations));
      _heldFor = d.held;
      if (d.sync) {
        await syncNow(by: d.why!);
      } else if (freshRequestWaits(s, DateTime.now())) {
        final mb = await run('mailbox');
        for (final a in arrivals(mb)) {
          arrivedCount++;
          await notifyArrived(a, channel: _channel);
        }
        if (arrivals(mb).isNotEmpty) await refresh();
      }
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
    unawaited(autoBoard());
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

/// `care`'s planning reach: every leaf of a round is planned at the first care after it is
/// made (the library's PLAN_EVERY_ROUND_LEAF). A coin of no round is still refreshed into
/// a round only once its refresh could run within ten days, since that refresh costs a fee.
const kPlanEveryRoundLeaf = 4294967295;

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
/// index counter is separate from the kit's); and every leaf of a round is planned.
Map<String, dynamic> careArgs(int kitNextIndex) => {'scan': kitNextIndex + 20, 'plan_within': kPlanEveryRoundLeaf};

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
      'body': '$amount ${label.ticker} arrived as a leaf.',
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

/// A refusal in user mode's words: one the operator declines, a refusal of the
/// operator's bond, and a frozen holding, said plainly; every other refusal as the
/// library says it.
LeafRefusal plainRefusal(LeafRefusal e) {
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
  final list = info?['assets'];
  if (list is! List) return out;
  for (final a in list.whereType<Map>()) {
    final v = BigInt.tryParse('${a['min_leaf'] ?? ''}');
    if (a['asset'] is String && v != null) out[a['asset'] as String] = v;
  }
  return out;
}

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
