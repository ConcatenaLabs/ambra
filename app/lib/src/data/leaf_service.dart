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
import 'catch_up.dart';
import 'config.dart';
import 'default_words.dart';
import 'dev_mode.dart';
import 'format.dart';
import 'home_coins.dart';
import 'ln_max_payment.dart';
import 'pay_code.dart' show expandRequest;
import 'pending_sends.dart';
import 'price_service.dart';
import 'vesting.dart';
import 'wallet_cache.dart';
import 'wallet_repository.dart';

/// A refusal by the leaf wallet, in the library's own words.
class LeafRefusal implements Exception {
  LeafRefusal(this.kind, this.message,
      {this.code, this.status, this.asset, this.release = const [], this.plain = false, this.fields = const {}});
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

  /// The library's whole `error` object: the figures some refusals carry beside their words
  /// (`settle_first`'s `coins`, `final_in_seconds`, `usual_in_seconds` and `waiting_for`;
  /// `in_channel`'s `close`; `short`'s `most`).
  final Map<String, dynamic> fields;

  /// The coins a `settle_first` refusal names, to put through the next round first.
  List<String> get coins => [for (final c in (fields['coins'] as List?) ?? const []) '$c'];

  /// The channel leaves an `in_channel` refusal names, to close into the next round.
  List<String> get close => [for (final c in (fields['close'] as List?) ?? const []) '$c'];

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
            release: [for (final r in (err['release'] as List?) ?? const []) '$r'],
            fields: Map<String, dynamic>.from(err));
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
      // A wallet user mode joined by itself whose restore was cut short (the app closed, or the
      // operator did not answer) restores now, before it opens: never opened as if it held nothing.
      if (!DevMode.instance.on) {
        final gen = _gen;
        await restoreOnce();
        // Closed while it restored: the next start opens it.
        if (gen != _gen) return;
      }
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
    // Back from the background: the scheduled job may have moved the wait on meanwhile.
    if (by == 'resume') await _catchUpReload();
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
    if (!DevMode.instance.on) unawaited(resumePending());
  }

  // -------------------------------------------------------------------------
  // Finding what the wallet holds: its restore, then its history a slice at a time
  // -------------------------------------------------------------------------

  /// While the wallet restores what its phrase holds with the operator (a join, or a restore cut
  /// short before): since when, how long it has run ([RestoreState.slow]), and, while the operator
  /// does not answer, why. Default mode then says it is finding what it holds ([findingWords])
  /// rather than any figure; a payment asked meanwhile waits for it ([pay]). Null otherwise.
  RestoreState? restoring;

  /// A restore the operator does not answer is asked again this often, until it answers.
  static const restoreRetry = Duration(seconds: 30);
  /// A restore running this long is a long history being checked; this long, far longer than
  /// any history should take.
  static const restoreSlow = Duration(minutes: 2);
  static const restoreLong = Duration(minutes: 30);

  /// A restore's history, after the wallet opens: each slice the library runs takes about
  /// [historySlice]; the next comes [historyGap] after, so a person's ask between two goes
  /// first; while the wallet is busy it looks again after [historyBusy], and after a slice that
  /// could check nothing (its coins wait for the chain) after [historyIdle].
  static const historySlice = Duration(milliseconds: 500);
  static const historyGap = Duration(milliseconds: 250);
  static const historyBusy = Duration(seconds: 2);
  static const historyIdle = Duration(minutes: 1);

  static const _kRestored = 'ambra.leaves.restored';
  String get _restoredKey => '$_kRestored.${DevMode.instance.tag ?? 'default'}';

  /// The sentence default mode shows under the total while the wallet finds what it holds, or
  /// null once it has.
  String? findingWords() => restoreWords(restoring);

  /// Whether the wallet is still finding what it holds: restoring, or checking its history.
  bool get stillFinding {
    final h = balance?['history'];
    return restoring != null || (h is Map && h['loading'] == true);
  }

  final List<Timer> _restoreTimers = [];
  // Bumped by each [stop]: a restore that outlives a stop does not open the wallet.
  int _gen = 0;

  DateTime _restoreStarts() {
    final t0 = DateTime.now();
    restoring = RestoreState(since: t0);
    for (final t in _restoreTimers) {
      t.cancel();
    }
    _restoreTimers
      ..clear()
      ..add(Timer(restoreSlow, () => _restoreSlowed(t0, 'slow')))
      ..add(Timer(restoreLong, () => _restoreSlowed(t0, 'long')));
    notifyListeners();
    return t0;
  }

  void _restoreSlowed(DateTime t0, String level) {
    final r = restoring;
    if (r == null || r.since != t0) return;
    restoring = r.copy(slow: level);
    debugPrint('[leaves] restore still running after ${DateTime.now().difference(t0).inSeconds} s ($level)');
    notifyListeners();
  }

  void _restoreEnds(DateTime t0) {
    if (restoring?.since != t0) return;
    for (final t in _restoreTimers) {
      t.cancel();
    }
    _restoreTimers.clear();
    restoring = null;
    notifyListeners();
  }

  Future<void> _setRestored() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_restoredKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// The join's restore, run to its end once: a wallet whose restore was cut short restores when
  /// it next opens, so a phrase's coins are never left behind. Every request inside it is bounded,
  /// so it returns; when it returns because the operator does not answer, the wallet has found
  /// nothing and is not opened empty: it stays finding, says why, and restores again every
  /// [restoreRetry] until the operator answers. A restore refused for any other reason lets the
  /// wallet open as before. The library leaves the coins the history gave up to slices
  /// ([_historySoon]).
  Future<void> restoreOnce() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getInt(_restoredKey) != null) return;
    } catch (_) {}
    final t0 = _restoreStarts();
    try {
      for (;;) {
        try {
          final v = jsonDecode(await leaves.leavesRun(command: 'restore', argsJson: '{}'));
          await _setRestored();
          debugPrint('[leaves] restore: ${DateTime.now().difference(t0).inMilliseconds} ms');
          final r = v is Map ? v['result'] : null;
          // The watchtowers' deposits of what it found owed: made at once, not awaited.
          if (r is Map && r['deposits'] is Map && (r['deposits'] as Map)['owed'] != null) {
            unawaited(leaves.leavesRun(command: 'deposits', argsJson: '{}').then((_) {}, onError: (_) {}));
          }
          return;
        } catch (e) {
          final r = LeafRefusal.of(e);
          debugPrint('[leaves] restore: ${r.message}');
          if (r.kind != 'unreachable') return;
          final was = restoring;
          if (was != null && was.since == t0) {
            restoring = was.copy(stalled: r.message, stalledSince: was.stalledSince ?? DateTime.now());
            notifyListeners();
          }
          await Future<void>.delayed(restoreRetry);
          if (restoring?.since != t0) return;
        }
      }
    } finally {
      _restoreEnds(t0);
    }
  }

  /// A person's ask that comes while the wallet restores waits for it, then goes on; while the
  /// operator does not answer, or once the restore has run far too long, it ends at once in words
  /// that say nothing moved.
  Future<void> _waitRestored() async {
    while (restoring != null) {
      final r = restoring!;
      if (r.stalled != null) throw LeafRefusal('refused', DefaultWords.findingStalledPay, plain: true);
      if (r.slow == 'long') throw LeafRefusal('refused', DefaultWords.findingLongPay, plain: true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Timer? _historyTimer;
  bool _noSlices = false;

  /// Runs a slice of the restore's history after [d], while the balance says it is loading.
  void _historySoon([Duration d = Duration.zero]) {
    if (!open || _noSlices || (_historyTimer?.isActive ?? false)) return;
    final h = balance?['history'];
    if (!(h is Map && h['loading'] == true)) return;
    _historyTimer = Timer(d, () => unawaited(_historySlice()));
  }

  /// One slice of the history (`restore_history {budget_ms}`), only while nobody asks the wallet
  /// for anything and no other command of it runs, so a receive code, a price or a payment waits
  /// for one slice at most, never the whole history.
  Future<void> _historySlice() async {
    _historyTimer = null;
    if (!open) return;
    final hold = _holdUntil;
    if (_asking > 0 || _running > 0 || _ticking || (hold != null && DateTime.now().isBefore(hold))) {
      return _historySoon(_asking > 0 ? historyGap : historyBusy);
    }
    Object? v;
    try {
      v = await run('restore_history', {'budget_ms': historySlice.inMilliseconds});
    } catch (e) {
      debugPrint('[leaves] history slice: $e');
    }
    if (v is! Map) return _historySoon(historyIdle);
    final left = (v['left'] as num?)?.toInt() ?? 0;
    // A library without slices answers a whole step and no `ms`: its syncs carry the history.
    if (v['ms'] == null && left != 0) {
      _noSlices = true;
      debugPrint('[leaves] this library takes no slices of its history');
    }
    final b = balance;
    if (b != null) {
      balance = {...b, 'history': left > 0 ? {...?(b['history'] as Map?), 'loading': true, 'left': left} : null};
    }
    if (left > 0) {
      notifyListeners();
      return _historySoon(((v['checked'] as num?) ?? 0) > 0 ? historyGap : historyIdle);
    }
    debugPrint('[leaves] the history is whole');
    await refresh();
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
    _historyTimer?.cancel();
    _historyTimer = null;
    _gen++;
    final r = restoring;
    if (r != null) _restoreEnds(r.since);
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
    _noSlices = false;
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
  /// in whole minutes, from the operator's `info.fills` and `offboards.unlock_within_seconds`
  /// ([addressArrivalMinutes]), or null when it publishes no round interval.
  int? addressMinutes() {
    final f = _fills();
    return addressArrivalMinutes(f?['round_interval_seconds'], f?['block_seconds'], _unlockSeconds());
  }

  /// The minutes a payment to an address the library just answered (`offboard`) takes, from the
  /// settlement it said it goes in (`round_within_seconds`), else [addressMinutes]. The web
  /// wallet's `offboardOutcome`.
  int? offboardMinutes(Object? answer) {
    final f = _fills();
    final r = answer is Map ? answer['round_within_seconds'] : null;
    return addressArrivalMinutes(r, f?['block_seconds'], _unlockSeconds()) ?? addressMinutes();
  }

  /// How long a move out of the Ark to the wallet's own address takes, in whole minutes
  /// ([moveOutMinutes]), or null when the operator publishes no round interval.
  int? moveOutMinutesNow() {
    final f = _fills();
    return moveOutMinutes(f?['round_interval_seconds'], f?['block_seconds'], _unlockSeconds());
  }

  /// The minutes a payment that settles first usually waits, from the operator's settings
  /// ([settleMinutesOf]), before the library has said.
  int settleMinutesNow() => settleMinutesOf(info);

  /// When, in words, a line of what is arriving of [cause] ([arrivingCause]) is the wallet's,
  /// at the operator's anchor depth ([causeWhen]).
  String arrivingWhen(String cause) =>
      causeWhen(cause, boardMin: boardMinutes(anchorDepth()), roundMin: roundMinutes(anchorDepth()));

  Map? _fills() {
    final si = info?['server_info'];
    return si is Map && si['fills'] is Map ? si['fills'] as Map : (info?['fills'] is Map ? info!['fills'] as Map : null);
  }

  Object? _unlockSeconds() {
    final si = info?['server_info'];
    final o = si is Map ? si['offboards'] : null;
    return o is Map ? o['unlock_within_seconds'] : null;
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
    final t0 = _restoreStarts();
    try {
      final cfg = {...op.toJson(), if (nodePassword.isNotEmpty) 'node_password': nodePassword};
      Map<String, dynamic> out;
      try {
        out = jsonDecode(await leaves.leavesJoin(dir: dir, mnemonic: m, configJson: jsonEncode(cfg))) as Map<String, dynamic>;
        await _setRestored();
        _restoreEnds(t0);
      } catch (e) {
        // The wallet was made and its restore found nothing because the operator did not answer:
        // it is kept, and stays finding what it holds until the operator answers.
        final r = LeafRefusal.of(e);
        _restoreEnds(t0);
        if (r.kind != 'unreachable' || !await leaves.leavesExists(dir: dir, mnemonic: m)) rethrow;
        debugPrint('[leaves] join: made, its restore not answered: ${r.message}');
        await restoreOnce();
        out = {'info': jsonDecode(await leaves.leavesRun(command: 'info', argsJson: '{}'))['result']};
      }
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
      final out = jsonDecode(await (debugLibrary ?? _library)(command, jsonEncode(args)));
      // A command over ten seconds says where its time went (the library's own costs), so a slow
      // phone can be read from its log.
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (ms > 10000 && out is Map) {
        final r = out['result'];
        final t = jsonEncode({'cost': out['cost'], 'steps': r is Map ? r['cost_by_step'] : null});
        debugPrint('[leaves] slow $command $ms ms: ${t.length > 900 ? t.substring(0, 900) : t}');
      }
      final result = (out as Map)['result'];
      await _readForCatchUp(command, result);
      return result;
    } catch (e) {
      // Every sync is an attempt at the catch-up a wait holds, one that throws too.
      if (command == 'sync') await _catchUpCounted();
      // A command refused after holding the library over ten seconds is named as one that
      // answered is: a refusal holds every command behind it just as long.
      final ms = DateTime.now().difference(t0).inMilliseconds;
      final refusal = LeafRefusal.of(e);
      // Refused for what the wallet holds out of round (a large payment just received, such as
      // the faucet's five assets): what it received is given up at the next turn, not after the
      // refresh's usual pace, so room comes back sooner (faucet#30).
      if (holdingRefusal(refusal)) _refreshedAt = null;
      if (ms > 10000) {
        final t = refusal.message.length > 300 ? refusal.message.substring(0, 300) : refusal.message;
        debugPrint('[leaves] slow $command $ms ms, refused: $t');
      }
      throw refusal;
    } finally {
      _running--;
    }
  }

  /// How many of the library's commands run now: a channel read waits for none.
  int _running = 0;

  static Future<String> _library(String command, String argsJson) => leaves.leavesRun(command: command, argsJson: argsJson);

  /// The library [run] asks, in place of the native one: host tests answer as the library does.
  @visibleForTesting
  static Future<String> Function(String command, String argsJson)? debugLibrary;

  // -------------------------------------------------------------------------
  // A payment to a code another wallet of the phrase handed out (catch_up.dart)
  // -------------------------------------------------------------------------

  static const _kCatchUp = 'ambra.leaves.catchUp';

  /// The coins of the phrase a mailbox read refused, waited for until the wallet holds them, and
  /// when the library's catch-up is open next (its median time): kept, so an app opened again goes
  /// on waiting, and one opened soon after a catch-up knows the library runs none yet.
  CatchUpWait? catchUp;
  num? _catchUpOpenAt;
  bool _catchUpLoaded = false;

  /// What this engine last read or wrote of the kept wait: the scheduled job writes it too (in an
  /// engine of its own, in this process while the app holds the wallet), and [_catchUpMerge]
  /// takes in what it changed since, by leaf id, rather than writing over it (ambra#286).
  CatchUpWait? _catchUpBase;
  num? _catchUpBaseOpenAt;

  Future<({CatchUpWait? wait, num? openAt})?> _catchUpKept({bool reload = true}) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (reload) await p.reload();
      final j = jsonDecode(p.getString(_kCatchUp) ?? 'null');
      return j is Map ? (wait: CatchUpWait.fromJson(j['wait']), openAt: j['openAt'] as num?) : (wait: null, openAt: null);
    } catch (_) {
      return null;
    }
  }

  Future<void> _catchUpLoad() async {
    if (_catchUpLoaded) return;
    _catchUpLoaded = true;
    final k = await _catchUpKept(reload: false);
    if (k == null) return;
    catchUp ??= k.wait;
    _catchUpOpenAt ??= k.openAt;
    _catchUpBase = k.wait;
    _catchUpBaseOpenAt = k.openAt;
  }

  /// The kept wait read again and merged into this engine's ([mergeWaits]): a coin the job's sync
  /// refused is waited for here too, and one the job took in is not announced again.
  Future<void> _catchUpMerge() async {
    await _catchUpLoad();
    final k = await _catchUpKept();
    if (k == null) return;
    catchUp = mergeWaits(_catchUpBase, catchUp, k.wait);
    _catchUpOpenAt = mergeOpenAt(_catchUpBaseOpenAt, _catchUpOpenAt, k.openAt);
    _catchUpBase = k.wait;
    _catchUpBaseOpenAt = k.openAt;
  }

  /// Back from the background: what the scheduled job did meanwhile, merged in.
  Future<void> _catchUpReload() => _catchUpMerge();

  /// The wait kept, one write at a time, each merged with what is kept first.
  Future<void> _catchUpKeep() => _catchUpWrites = _catchUpWrites.then((_) async {
        await _catchUpMerge();
        try {
          final p = await SharedPreferences.getInstance();
          await p.setString(_kCatchUp, jsonEncode({'wait': catchUp?.toJson(), 'openAt': _catchUpOpenAt}));
          _catchUpBase = catchUp;
          _catchUpBaseOpenAt = _catchUpOpenAt;
        } catch (_) {}
      });
  Future<void> _catchUpWrites = Future.value();

  /// Once every write of the wait asked so far has landed.
  @visibleForTesting
  Future<void> catchUpWrittenForTest() => _catchUpWrites;

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  /// The library's median time now, from its last schedule read, counted on at one second a second.
  num? _libNow() {
    final n = schedule?['now'];
    final at = _scheduleReadAt;
    if (n is! num) return null;
    return at == null ? n : n + DateTime.now().difference(at).inSeconds;
  }

  DateTime? _scheduleReadAt;

  /// Every answer of the library, read once here for the wait: a mailbox read's refusals, a sync's
  /// refusals, catch-up and gate, and the coins the wallet lists.
  Future<void> _readForCatchUp(String command, Object? result) async {
    if (command != 'mailbox' && command != 'sync' && command != 'coins' && command != 'schedule') return;
    await _catchUpLoad();
    if (command != 'schedule') await _catchUpMerge();
    final now = _nowMs;
    switch (command) {
      case 'schedule':
        if (result is Map) _scheduleReadAt = DateTime.now();
        return;
      case 'mailbox':
        final before = catchUp?.pending.length ?? 0;
        _setCatchUp(catchUpWait(catchUp, mailbox: result, now: now));
        if ((catchUp?.pending.length ?? 0) > before) {
          final ms = catchUpSyncIn(catchUp, now: now, libNow: _libNow(), openAt: _catchUpOpenAt) ?? 0;
          debugPrint('[leaves] a payment to a code another wallet of the phrase handed out: '
              'the catch-up that takes it in runs in about ${(ms / 1000).round()} s');
          _askEarlier(Duration(milliseconds: ms));
        }
        return;
      case 'sync':
        final openAt = catchUpGate(_catchUpOpenAt, result, _libNow());
        if (openAt != _catchUpOpenAt) {
          _catchUpOpenAt = openAt;
          unawaited(_catchUpKeep());
        }
        final a = catchUpAfterSync(catchUp, sync: result, now: now);
        _setCatchUp(a.wait);
        _caughtIn(a.arrived);
        return;
      case 'coins':
        if (catchUp == null) return;
        final h = catchUpHeld(catchUp, result, now);
        _setCatchUp(h.wait);
        _caughtIn(h.arrived);
        return;
    }
  }

  /// A sync or a schedule read that threw: an attempt all the same, so the wait's cadence holds
  /// while the node does not answer.
  Future<void> _catchUpCounted() async {
    await _catchUpMerge();
    _setCatchUp(catchUpAttempt(catchUp, _nowMs));
  }

  void _setCatchUp(CatchUpWait? w) {
    final was = catchUp;
    catchUp = w;
    if (was != w) unawaited(_catchUpKeep());
    if (was != null && w == null && was.pending.isNotEmpty) {
      debugPrint('[leaves] the wait for the catch-up ends with ${was.pending.length} coin(s) not found after '
          '${was.tries} catch-up(s); the library\'s own catch-ups and daily sync still look for them');
    }
  }

  /// The coins of the wait the wallet now holds: each shown as an arrival, as a mailbox's coin is.
  void _caughtIn(List<CaughtIn> arrived) {
    if (arrived.isEmpty) return;
    for (final a in arrived) {
      arrivedCount++;
      _noteArrived(a);
      unawaited(notifyArrived(a, channel: _channel));
    }
    debugPrint('[leaves] ${arrived.length} coin(s) paid to another wallet\'s code taken in by the catch-up');
    // What the catch-up took in shows in the figures at once.
    unawaited(() async {
      try {
        balance = await run('balance') as Map<String, dynamic>?;
      } catch (_) {}
      notifyListeners();
    }());
  }

  /// The next pass no later than [d] from now: a pass under way plans its own next one when it ends.
  void _askEarlier(Duration d) {
    if (!open || _ticking) return;
    final at = _nextPassAt;
    final want = DateTime.now().add(d < const Duration(seconds: 1) ? const Duration(seconds: 1) : d);
    if (_timer?.isActive == true && at != null && !at.isAfter(want)) return;
    _plan(want.difference(DateTime.now()));
  }

  DateTime? _nextPassAt;

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
  Future<dynamic> pay(String command, [Map<String, dynamic> args = const {}, bool plain = false, bool person = true]) =>
      _pay(command, args, plain, person);

  /// [pay], with each stage of the payment written by [stage] before the library is asked:
  /// 'asking' while it is asked (it may sign), 'waiting' while it waits for a round (nothing
  /// signed). [payPending] keeps them, so an app closed meanwhile makes the payment once.
  Future<dynamic> _pay(String command, Map<String, dynamic> args, bool plain, bool person,
      {void Function(String stage)? stage}) async {
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
      if (person) await _waitRestored();
      stage?.call('asking');
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
          if ((releasing == null) != (w == null)) stage?.call(w == null ? 'asking' : 'waiting');
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

  // -------------------------------------------------------------------------
  // A payment that waits, written down: made once, even across a closed app (pending_sends.dart)
  // -------------------------------------------------------------------------

  String get _sendTag => DevMode.instance.tag ?? 'default';

  Future<PendingStore> _pendingStore() async => _PrefsPendingStore(await SharedPreferences.getInstance());

  /// A person's payment in the tree ([command] `send` to a receive code, `offboard` to an
  /// address), written down while it waits for a round, so that an app closed meanwhile makes it
  /// when the wallet is next open, and never twice ([resumePending]). [kind] 'code' or 'address',
  /// [to] the code or address, [atoms] of [asset]; [history], when given, is the History entry
  /// written for it should it be made after the app reopened (the library's `offboard` id added).
  /// Otherwise as [pay] with `plain`.
  Future<dynamic> payPending(String command, Map<String, dynamic> args,
      {required String kind, required String asset, required BigInt atoms, required String to,
      Map<String, dynamic>? history, String? ticker, int? precision}) async {
    final store = await _pendingStore();
    final rec = <String, dynamic>{
      'id': '${DateTime.now().microsecondsSinceEpoch}-${asset.length > 8 ? asset.substring(0, 8) : asset}',
      'kind': kind, 'asset': asset, 'atoms': atoms.toString(), 'to': to,
      'command': command, 'args': args, 'history': ?history, 'ticker': ?ticker, 'precision': ?precision,
      'at': DateTime.now().millisecondsSinceEpoch, 'state': 'asking',
    };
    final write = stageWriter(store, _sendTag, rec);
    try {
      return await _pay(command, args, true, true, stage: write);
    } finally {
      dropPending(store, _sendTag, '${rec['id']}');
      notifyListeners();
    }
  }

  /// Whether the same payment (asset, amount, recipient) is written down and not ended: the
  /// review then says [DefaultWords.sameOnItsWay], since sending it again pays it twice.
  Future<bool> samePendingNow(String asset, BigInt atoms, String to) async =>
      samePending(await _pendingStore(), _sendTag, asset: asset, atoms: atoms.toString(), to: to) != null;

  /// The payments written down and waiting: History shows each as [DefaultWords.rowSending].
  Future<List<Map<String, dynamic>>> pendingNow() async => pendingSends(await _pendingStore(), _sendTag);

  /// How payments made after the app reopened ended, when not made: each said once on Balance
  /// ([pendingEndText]), then [markPendingEndTold].
  Future<List<Map<String, dynamic>>> pendingEndsNow() async => pendingEnds(await _pendingStore(), _sendTag);
  Future<void> markPendingEndTold(String id) async {
    markEndTold(await _pendingStore(), _sendTag, id);
    notifyListeners();
  }

  bool _resumed = false;

  /// Once the wallet is open, once per run: each payment that was waiting when the app closed is
  /// asked again with what was reviewed; one the library was being asked for then is never asked
  /// again (it may have gone), and is said once on Balance. One asked again that is refused is
  /// said once on Balance too: nothing left the wallet.
  Future<void> resumePending() async {
    if (_resumed || !open) return;
    _resumed = true;
    final store = await _pendingStore();
    final got = takePending(store, _sendTag, DateTime.now());
    for (final d in got.dropped) {
      debugPrint('[send] not asked again (${d['why']}): ${d['kind']} ${d['atoms']}');
    }
    if (got.dropped.isNotEmpty) notifyListeners();
    for (final rec in got.resume) {
      debugPrint('[send] made after the app was closed while it waited: ${rec['kind']} ${rec['atoms']}');
      final args = Map<String, dynamic>.from((rec['args'] as Map?) ?? const {});
      try {
        final v = await _pay('${rec['command']}', args, true, true, stage: stageWriter(store, _sendTag, rec));
        final h = rec['history'];
        if (h is Map && !offboardAlready(v)) {
          final id = v is Map && v['offboard'] != null ? '${v['offboard']}' : null;
          await WalletCache.addPayment({...Map<String, dynamic>.from(h), 'offboard': ?id, if (id != null) 'stage': 'pending'});
        }
      } catch (e) {
        debugPrint('[send] the payment made after the app was closed was refused: $e');
        noteEnd(store, _sendTag, rec, 'refused', DateTime.now());
      } finally {
        dropPending(store, _sendTag, '${rec['id']}');
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
    _historySoon();
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
  Future<Map<String, dynamic>> syncNow({String by = 'user', Map<String, dynamic> args = const {}}) async {
    final r = await run('sync', args) as Map<String, dynamic>;
    // A sync without the watchtowers' step ([args] `deposits: false`, the catch-up wait's) still
    // counts as the wallet's sync, and the library's schedule puts the next one, which would make
    // the deposits, a day later: they are made now, not awaited, as the library expects of a
    // program that leaves them out (ambra#275).
    if (args['deposits'] == false) {
      unawaited(run('deposits').then((_) {}, onError: (Object e) => debugPrint('[leaves] deposits after a catch-up sync: $e')));
    }
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
      await p.remove(_kCatchUp);
    } catch (_) {}
    instance
      ..catchUp = null
      .._catchUpOpenAt = null
      .._catchUpBase = null
      .._catchUpBaseOpenAt = null
      .._catchUpLoaded = false;
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
  /// How long until the next pass, as planned.
  @visibleForTesting
  Duration? get plannedInForTest => _timer?.isActive == true && _nextPassAt != null ? _nextPassAt!.difference(DateTime.now()) : null;
  /// No mailbox read yet, as at a start.
  @visibleForTesting
  void resetReadsForTest() {
    _mailReadAt = null;
    _mailReadEnd = null;
    _mailCostMs = 0;
  }

  void _plan(Duration d) {
    _timer?.cancel();
    if (!open) return;
    _nextPassAt = DateTime.now().add(d);
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
    final tickStarted = _nowMs;
    try {
      final s = await run('schedule') as Map<String, dynamic>?;
      schedule = s;
      final d = syncDecision(s, _heldFor, inFlight(coins, participations));
      _heldFor = d.held;
      // A payment to a code another wallet of the phrase handed out, which only the catch-up takes
      // in, once the library's catch-up is open by its own clock (the schedule's `now`): a sync
      // without the watchtowers' step, which nobody waits on (catch_up.dart).
      await _catchUpMerge();
      _setCatchUp(catchUpWait(catchUp, now: _nowMs));
      final forCatchUp = !d.sync && catchUpSyncIn(catchUp, now: _nowMs, libNow: s?['now'] as num?, openAt: _catchUpOpenAt) == 0;
      if (d.sync) {
        await syncNow(by: d.why!);
      } else if (forCatchUp) {
        debugPrint('[leaves] sync for the catch-up: ${catchUp?.pending.length} coin(s) of the phrase waited for');
        await syncNow(by: 'catch-up', args: const {'deposits': false});
      } else if ((_inForeground ? requestWaits(s) : freshRequestWaits(s, DateTime.now())) && _mailDue(DateTime.now())) {
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
      // User mode: a receive code handed out lately is read for every few seconds, and, while the
      // app is in view, while any request the wallet handed out waits (the payment name's stocked
      // codes are handed out up to a day after they are made) every [mailboxEvery], so a payment
      // to it shows at once. Out of view the pass keeps [nextAsk]: the name's codes keep a request
      // waiting for as long as the name lasts, and the foreground service would otherwise read
      // the operator's mailbox every ten seconds for good.
      if (!DevMode.instance.on && freshRequestWaits(s, DateTime.now()) && wait > fastAsk) wait = fastAsk;
      if (!DevMode.instance.on && _inForeground && requestWaits(s) && wait > mailboxEvery) wait = mailboxEvery;
      // The wait for coins of the phrase syncs once the library's catch-up is open again.
      final forWait = catchUpSyncIn(catchUp, now: _nowMs, libNow: _libNow(), openAt: _catchUpOpenAt);
      if (forWait != null && Duration(milliseconds: forWait) < wait) {
        wait = Duration(milliseconds: forWait < 1000 ? 1000 : forWait);
      }
    } catch (e) {
      lastError = LeafRefusal.of(e);
      // A schedule read that threw is an attempt too (a sync that threw counted itself in `run`).
      if (catchUp != null && (catchUp!.attemptAt ?? 0) < tickStarted) await _catchUpCounted();
      // While coins of the phrase are waited for, the next pass keeps the wait's cadence: a minute
      // apart, and ten minutes once ten attempts in a row ran no catch-up (the node or the operator
      // not answering), never a pass a minute for the wait's whole day.
      final forWait = catchUpSyncIn(catchUp, now: _nowMs, libNow: _libNow(), openAt: _catchUpOpenAt);
      if (forWait != null) wait = Duration(milliseconds: forWait < 1000 ? 1000 : forWait);
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
    // No later than the wait for coins of the phrase next syncs, should the app close meanwhile.
    final wake = jobWakeIn(leaves.leavesWakeIn(scheduleJson: jsonEncode(s), coinsJson: jsonEncode(coins))?.toInt(),
        catchUpSyncIn(catchUp, now: _nowMs, libNow: _libNow(), openAt: _catchUpOpenAt));
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

/// A restore under way ([LeafService.restoring]): since when, how long it has run (`slow` past
/// [LeafService.restoreSlow], `long` past [LeafService.restoreLong]), and why the operator does
/// not answer, since when.
class RestoreState {
  const RestoreState({required this.since, this.slow, this.stalled, this.stalledSince});
  final DateTime since;
  final String? slow;
  final String? stalled;
  final DateTime? stalledSince;
  RestoreState copy({String? slow, String? stalled, DateTime? stalledSince}) => RestoreState(
      since: since, slow: slow ?? this.slow, stalled: stalled ?? this.stalled, stalledSince: stalledSince ?? this.stalledSince);
}

/// What default mode says under the total while a restore runs ([DefaultWords.finding] and its
/// slow, long and stalled forms), or null when none does.
String? restoreWords(RestoreState? r) {
  if (r == null) return null;
  if (r.stalled != null) return DefaultWords.findingStalled;
  if (r.slow == 'long') return DefaultWords.findingLong;
  if (r.slow == 'slow') return DefaultWords.findingSlow;
  return DefaultWords.finding;
}

/// A payment waiting for a round: to free the planned coins it needs (`release`), for coins to
/// settle first (`settle`), for channels it pays from to close (`channel`), for coins too many
/// payments deep to be refreshed (`depth`), or for the wallet's own refresh of its asset already in
/// a round (`round`). [finalBy] is when the library said it goes through (`settle` only), updated
/// as it says more ([nextFinalBy]).
class ReleaseWait {
  ReleaseWait({required this.command, required this.coins, this.asset, required this.since, this.why = 'release', this.finalBy});
  final String command;
  final List<String> coins;
  final String? asset;
  final DateTime since;
  final String why;
  FinalBy? finalBy;
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

/// How often a payment waiting for its coins to settle first, or for the wallet's own round,
/// reads again.
const kRoundPoll = Duration(seconds: 5);

/// A coin just moved in that the wallet reads final and the operator not yet (its view of the
/// chain a block behind, at anchor depth 0): asked again this often, for at most [kNotLiveFor].
const kNotLiveEvery = Duration(seconds: 3);
const kNotLiveFor = Duration(minutes: 2);

/// Whether a refusal is the operator calling a coin not live yet (`not_live`).
bool notLiveRefusal(LeafRefusal r) => RegExp(r'\bnot_live\b').hasMatch('${r.code ?? ''} ${r.message}');

/// The coins of [asset] in the wallet's own round now (`given`, `forfeited`): a payment refused
/// for want of live coins while they are waits for that round to end.
List<String> inRoundCoins(List<dynamic> coins, String? asset) => [
      for (final c in coins.whereType<Map>())
        if (c['asset'] == asset && (c['state'] == 'given' || c['state'] == 'forfeited')) '${c['leaf_id']}'
    ];

/// Runs [command] through [run]. What the library holds back only for want of a round is never
/// refused; the payment waits for that round and is asked again once it is through, a person in
/// user mode asking nothing:
/// - `planned` (the unplanned coins fall short, the planned coins it names would cover it): those
///   coins are given up in the next round (`plan_release`), and the wallet syncs every [poll]
///   until none of them is held or in that round any more;
/// - `settle_first` (coins still arriving, at the operator's depth limit, or of a shape the other
///   side does not read): `settle_first` puts the coins it names through the next round, asked
///   again every [roundPoll] after a sync until it answers `ready`; its figures set the time the
///   wait is told it goes by ([nextFinalBy]). An offboard's quote is answered as the library gave it;
/// - `in_channel` (the wallet's side of a channel would cover it): those channels are closed into
///   the next round, followed as a release;
/// - `depth_limit` (coins too many payments from a round): the asset's live coins are refreshed in
///   the next round, followed as a release;
/// - "in live coins" while the wallet's own refresh of the asset is in a round: waits for it;
/// - `not_live` (a coin just moved in the operator does not call live yet): asked again every
///   [kNotLiveEvery], for [kNotLiveFor], never shown.
/// At most [tries] waits of each payment, each for at most [wait]; past them a settle's words are
/// [DefaultWords.settleGaveUp]. Every other answer and refusal is the library's, untouched.
/// [onWait] hears each wait start (a [ReleaseWait]), its told time move, and end (null); [synced]
/// each sync's answer. The web wallet's `paying` (leaves.js).
Future<dynamic> payThroughRelease(
  String command,
  Map<String, dynamic> args, {
  required Future<dynamic> Function(String command, Map<String, dynamic> args) run,
  Future<void> Function(Duration)? sleep,
  DateTime Function()? now,
  void Function(ReleaseWait? wait)? onWait,
  Future<void> Function(Object? sync)? synced,
  Duration poll = kReleasePoll,
  Duration roundPoll = kRoundPoll,
  Duration wait = kReleaseWait,
  int tries = kReleaseTries,
}) async {
  final clock = now ?? DateTime.now;
  final pause = sleep ?? (d) => Future<void>.delayed(d);
  Future<void> sync() async {
    try {
      final v = await run('sync', const {});
      await synced?.call(v);
    } catch (_) {}
  }

  Future<List<dynamic>?> coinsNow() async {
    try {
      return (await run('coins', const {}) as List?) ?? const [];
    } catch (_) {
      return null;
    }
  }

  // Until the coins a round gives up are done with.
  Future<void> released(List<String> coins) async {
    final until = clock().add(wait);
    for (;;) {
      await sync();
      final cs = await coinsNow();
      if (cs != null && releaseDone(cs, coins)) return;
      if (!clock().isBefore(until)) throw LeafRefusal('refused', kReleaseTimeout);
      await pause(poll);
    }
  }

  // A wait: told, run, its end told.
  Future<void> waiting(ReleaseWait w, Future<void> Function() f) async {
    onWait?.call(w);
    try {
      await f();
    } finally {
      onWait?.call(null);
    }
  }

  var notLive = 0;
  for (var i = 0;; i++) {
    try {
      return await run(command, args);
    } catch (e) {
      final r = LeafRefusal.of(e);
      if (notLiveRefusal(r) && kNotLiveEvery * notLive < kNotLiveFor) {
        notLive++;
        await pause(kNotLiveEvery);
        await sync();
        i--;
        continue;
      }
      final payAsset = '${args['asset'] ?? args['give_asset'] ?? ''}';
      if (r.kind == 'settle_first' && command != 'offboard_quote') {
        if (i >= tries) throw LeafRefusal('refused', DefaultWords.settleGaveUp, code: 'settle_gave_up', plain: true);
        final coins = r.coins;
        final ask = <String, dynamic>{if (coins.isNotEmpty) 'coins': coins else 'asset': r.asset};
        final w = ReleaseWait(command: command, coins: coins, asset: r.asset, since: clock(), why: 'settle',
            finalBy: nextFinalBy(null, r.fields, clock()));
        await waiting(w, () async {
          final until = clock().add(wait);
          for (var first = true;; first = false) {
            if (!first) await sync();
            final v = await run('settle_first', ask);
            final n = nextFinalBy(w.finalBy, v is Map ? v : null, clock());
            if (n != w.finalBy) {
              w.finalBy = n;
              onWait?.call(w);
            }
            if (v is! Map || v['ready'] == true) return;
            if (!clock().isBefore(until)) {
              throw LeafRefusal('refused', DefaultWords.settleGaveUp, code: 'settle_gave_up', plain: true);
            }
            await pause(roundPoll);
          }
        });
        continue;
      }
      if (r.kind == 'in_channel' && r.close.isNotEmpty && i < tries) {
        final close = r.close;
        await waiting(ReleaseWait(command: command, coins: close, asset: r.asset, since: clock(), why: 'channel'), () async {
          final q = await run('quote', {'leaves': close});
          await run('participate', {'leaves': close, 'shown': (q as Map)['coins']});
          await released(close);
        });
        continue;
      }
      if (r.code == 'depth_limit' && i < tries && payAsset.isNotEmpty) {
        final live = [
          for (final c in (await coinsNow() ?? const []).whereType<Map>())
            if (c['asset'] == payAsset && c['state'] == 'live') '${c['leaf_id']}'
        ];
        if (live.isEmpty) throw r;
        await waiting(ReleaseWait(command: command, coins: live, asset: payAsset, since: clock(), why: 'depth'), () async {
          final q = await run('quote', {'leaves': live});
          await run('participate', {'leaves': live, 'shown': (q as Map)['coins']});
          await released(live);
        });
        continue;
      }
      if (r.kind == 'refused' && r.message.contains('in live coins') && payAsset.isNotEmpty && i < tries) {
        final held = inRoundCoins(await coinsNow() ?? const [], payAsset);
        if (held.isNotEmpty) {
          await waiting(ReleaseWait(command: command, coins: held, asset: payAsset, since: clock(), why: 'round'), () async {
            final until = clock().add(wait);
            for (;;) {
              await sync();
              final cs = await coinsNow() ?? const [];
              if (inRoundCoins([for (final c in cs) if (c is Map && held.contains('${c['leaf_id']}')) c], payAsset).isEmpty) return;
              if (!clock().isBefore(until)) {
                throw LeafRefusal('refused',
                    "the wallet's own round did not end in time; nothing was paid, and the payment can be asked again");
              }
              await pause(roundPoll);
            }
          });
          continue;
        }
      }
      if (r.kind != 'planned' || r.release.isEmpty || i >= tries) throw r;
      await waiting(ReleaseWait(command: command, coins: r.release, asset: r.asset, since: clock()), () async {
        await run('plan_release', {'leaves': r.release});
        await released(r.release);
      });
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
  final r = await jobOutcome(out, host: host);
  return {
    ...r,
    'summary': '${r['summary']}'
        '${care == null ? '' : '; care ${careSummary(out['care'] is Map ? Map<String, dynamic>.from(out['care'] as Map) : null)}'}',
  };
}

/// What the scheduled job's pass did ([out], `leaves_job`'s answer): a notification per coin
/// received, the wait for coins of the phrase carried on (catch_up.dart: the sync's refusals join
/// it, what its catch-up restored and what the wallet now holds leave it, the attempt is counted),
/// and when to wake: the library's time, and no later than the wait's next sync. The wait is kept
/// where the app keeps it, so the app and the job go on with the same one.
Future<Map<String, dynamic>> jobOutcome(Map<String, dynamic> out, {required MethodChannel host, int? nowMs}) async {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final arrived = arrivals({'accepted': out['arrived']});
  for (final a in arrived) {
    await notifyArrived(a, channel: host);
  }
  final s = out['schedule'] as Map?;
  final libNow = s?['now'] as num?;
  final kept = await _jobWait();
  if (out['opened_for_the_job'] == false) {
    // The app holds this wallet open in this process, and its upkeep carries the wait: the job
    // only hands over the coins its own sync refused (the app merges them in before its next
    // change), announces nothing of the wait's and wakes on the library's time (ambra#286).
    final refused = phraseCoinsRefused((out['sync'] as Map?)?['mailbox']);
    if (refused.isNotEmpty) await _jobKeep(catchUpWait(kept.wait, mailbox: (out['sync'] as Map)['mailbox'], now: now), kept.openAt);
    return {
      'ok': true,
      'wake_in': out['wake_in'],
      'summary': 'arrived ${arrived.length}; next_sync_at ${s?['next_sync_at']}; now ${s?['now']}; the open app carries the wait'
          '${refused.isEmpty ? '' : ' (${refused.length} coin(s) refused handed to it)'}',
    };
  }
  final openAt = catchUpGate(kept.openAt, out['sync'], libNow);
  final a = catchUpAfterSync(kept.wait, sync: out['sync'], now: now);
  final h = catchUpHeld(a.wait, out['coins'], now);
  for (final c in [...a.arrived, ...h.arrived]) {
    await notifyArrived(c, channel: host);
  }
  await _jobKeep(h.wait, openAt);
  final waitMs = catchUpSyncIn(h.wait, now: now, libNow: libNow, openAt: openAt);
  return {
    'ok': true,
    'wake_in': jobWakeIn(out['wake_in'], waitMs),
    'summary': 'arrived ${arrived.length + a.arrived.length + h.arrived.length}; next_sync_at ${s?['next_sync_at']}; now ${s?['now']}'
        '${h.wait == null ? '' : '; waiting for ${h.wait!.pending.length} coin(s) of the phrase, next sync in ${waitMs == null ? '-' : (waitMs / 1000).ceil()} s'}',
  };
}

/// A pass of the scheduled job that failed (the node or the operator not answering): an attempt
/// at the wait's catch-up all the same. The wake time it names while the wait lasts (seconds), so
/// the job keeps the wait's cadence; null when there is no wait.
Future<int?> jobFailed({int? nowMs}) async {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final kept = await _jobWait();
  final w = catchUpAttempt(catchUpWait(kept.wait, now: now), now);
  await _jobKeep(w, kept.openAt);
  return jobWakeIn(null, catchUpSyncIn(w, now: now, openAt: kept.openAt));
}

Future<({CatchUpWait? wait, num? openAt})> _jobWait() async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final j = jsonDecode(p.getString(LeafService._kCatchUp) ?? 'null');
    if (j is Map) return (wait: CatchUpWait.fromJson(j['wait']), openAt: j['openAt'] as num?);
  } catch (_) {}
  return (wait: null, openAt: null);
}

Future<void> _jobKeep(CatchUpWait? w, num? openAt) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(LeafService._kCatchUp, jsonEncode({'wait': w?.toJson(), 'openAt': openAt}));
  } catch (_) {}
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
  if (holdingRefusal(e)) return LeafRefusal(e.kind, kHoldingRefusal, code: e.code, status: e.status, plain: true);
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

/// The library's refusal of a payment that would leave the wallet holding more out of round than
/// the bond covers, or than its instant budget: the bond stands, and room comes back once what the
/// wallet holds is settled in the next round (the web wallet's `holdingRefusal`).
bool holdingRefusal(LeafRefusal e) => RegExp(r'would hold out of round', caseSensitive: false).hasMatch(e.message);

/// User mode's words for it.
const kHoldingRefusal = 'Not yet: this wallet is settling what it was just paid, and takes a new instant payment once that '
    'is done, in a few minutes. Nothing was signed.';

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
/// wallet's figure, from the operator's interval between settlements ([roundSeconds]), the
/// chain's block interval ([blockSeconds], 60 when it says none) and the most the operator says it
/// takes to unlock the payment in a block ([unlockSeconds], its `offboards.unlock_within_seconds`;
/// [kUnlockWithin] when it says none). The whole way, not the settlement alone: the settlement,
/// its block and its certificate ([kAddressPathBlocks]), the unlock, and [kAddressPathSlack] for
/// the wallets to read the chain, rounded up to five minutes: fifteen on the testnet while its
/// operator publishes no unlock time. The web wallet's `arrivalMinutes` (default-arca.js).
int? addressArrivalMinutes(Object? roundSeconds, Object? blockSeconds, [Object? unlockSeconds]) {
  final n = _num(roundSeconds);
  if (n == null || n <= 0) return null;
  final m = ((n + kAddressPathBlocks * _blockOf(blockSeconds) + _unlockOf(unlockSeconds) + kAddressPathSlack) / 60).ceil();
  final five = (m / 5).ceil() * 5;
  return five < 5 ? 5 : five;
}

const kAddressPathBlocks = 2;
const kAddressPathSlack = 120;
const kUnlockWithin = 600;
const kMoveOutBlocks = 2;
const kMoveOutSlack = 30;

num? _num(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');
num _blockOf(Object? b) {
  final v = _num(b);
  return v != null && v > 0 ? v : 60;
}

num _unlockOf(Object? u) {
  final v = _num(u);
  return v != null && v > 0 ? v : kUnlockWithin;
}

/// The most minutes a move out of the Ark to the wallet's own address takes (for a stake, a
/// pool, a mix, a confidential payment): the operator's next settlement ([roundSeconds]), the
/// wallet handing over its part of it at once, the settlement's block and the operator's unlock
/// of the output in a block ([unlockSeconds], as for [addressArrivalMinutes]), with
/// [kMoveOutBlocks] blocks and [kMoveOutSlack] seconds for the reads on either side. Nothing
/// waits on another wallet: fourteen on the testnet. Null when the operator publishes no
/// interval. The web wallet's `moveOutMinutes`.
int? moveOutMinutes(Object? roundSeconds, Object? blockSeconds, [Object? unlockSeconds]) {
  final n = _num(roundSeconds);
  if (n == null || n <= 0) return null;
  final m = ((n + kMoveOutBlocks * _blockOf(blockSeconds) + _unlockOf(unlockSeconds) + kMoveOutSlack) / 60).ceil();
  return m < 1 ? 1 : m;
}

/// The minutes a deposit takes to be usable: a Sequentia block, and its block certified with its
/// anchor buried under [anchorDepth] Bitcoin blocks (ten minutes each), rounded up to five. Five
/// at depth 0: no anchor-depth wait is added that the operator does not count.
int boardMinutes(Object? anchorDepth) {
  final d = _num(anchorDepth);
  final m = (d != null && d > 0 ? d * 10 : 0) + 5;
  return (m / 5).ceil() * 5;
}

/// The minutes a settlement's coin takes to be the wallet's: the settlement, and its block
/// certified with its anchor buried under [anchorDepth] Bitcoin blocks. 1 at depth 0 ("about a
/// minute"); otherwise a minute and ten for each Bitcoin block, rounded up to five.
int roundMinutes(Object? anchorDepth) {
  final d = _num(anchorDepth);
  if (d == null || d <= 0) return 1;
  return ((1 + d * 10) / 5).ceil() * 5;
}

/// The minutes a payment that settles first usually waits before it goes, as the library's
/// `settle_first` counts it (`usual_in_seconds`): the operator's next settlement; a settlement
/// more when it holds them for every participant ([held]: its batches have no sweep); a block for
/// the settlement and one for its certificate; ten minutes for each block of anchor depth the
/// operator counts finality at (none at depth 0); and the operator's release: three of its passes
/// when it publishes how long one takes ([passSeconds], one more pass then to build the
/// settlement), else a settlement interval and a block. 6 on the testnet. The web wallet's
/// `settleMinutes`.
int settleMinutes(Object? roundSeconds, Object? blockSeconds, Object? anchorDepth, {bool held = false, Object? passSeconds}) {
  final r0 = _num(roundSeconds);
  final r = r0 != null && r0 > 0 ? r0 : 60;
  final b = _blockOf(blockSeconds);
  final d0 = _num(anchorDepth);
  final d = d0 != null && d0 > 0 ? d0 : 0;
  final p0 = _num(passSeconds);
  final p = p0 != null && p0 > 0 ? p0 : null;
  final release = p != null ? 3 * p : r + b;
  final m = ((r + (p ?? 0) + (held ? r : 0) + 2 * b + d * 600 + release) / 60).ceil();
  return m < 1 ? 1 : m;
}

/// [settleMinutes] for an operator as the library's `info` answers it (null: the defaults).
int settleMinutesOf(Map? info) {
  final si = info?['server_info'] is Map ? info!['server_info'] as Map : const {};
  final f = si['fills'] is Map ? si['fills'] as Map : const {};
  final b = si['batches'];
  return settleMinutes(f['round_interval_seconds'], f['block_seconds'], info?['anchor_depth'],
      held: b is Map && b['no_sweep'] == true, passSeconds: f['round_pass_seconds']);
}

/// The steps a payment settling first waits for, in order.
const kWaitSteps = ['round', 'forfeits', 'block', 'certificate', 'anchor', 'release'];

/// When a payment settling first is told it goes, and the step it waits for.
typedef FinalBy = ({DateTime at, String? step});

/// The time a payment settling first is told it goes by, from each answer of the library's
/// `settle_first` or its `settle_first` refusal ([answer]: `usual_in_seconds`, else
/// `final_in_seconds`; `waiting_for`; `ready`): the first answer sets it, and it stays while the
/// step waited for stands or moves on (a step slower than usual makes it late, not later); it is
/// set again only when the step goes back (a new settlement, an anchor rollback). The web
/// wallet's `nextFinalBy`.
FinalBy? nextFinalBy(FinalBy? prev, Map? answer, DateTime now) {
  final secs = _num(answer?['usual_in_seconds'] ?? answer?['final_in_seconds']);
  if (answer == null || answer['ready'] == true || secs == null) return prev;
  final at = now.add(Duration(milliseconds: (secs * 1000).round()));
  final step = answer['waiting_for']?.toString();
  if (prev == null) return (at: at, step: step);
  final back = step != null && prev.step != null && kWaitSteps.indexOf(step) < kWaitSteps.indexOf(prev.step!);
  return back ? (at: at, step: step) : (at: prev.at, step: step ?? prev.step);
}

/// How long past the time it was told a payment settling first reads as taking longer.
const kSettleLate = Duration(minutes: 2);

/// The words of a payment settling first at [now]: within the minutes left to [finalBy], or
/// [minutes] before the library has said; past [finalBy] by [kSettleLate], that it takes longer
/// and goes by itself. The web wallet's `settleWords`.
String settleWords(DateTime? finalBy, int? minutes, DateTime now) {
  if (finalBy == null) return DefaultWords.goesThrough(minutes ?? 1);
  if (now.isAfter(finalBy.add(kSettleLate))) return DefaultWords.goesThroughLate;
  final left = (finalBy.difference(now).inMilliseconds / 60000).ceil();
  return DefaultWords.goesThrough(left < 1 ? 1 : left);
}

/// The cause of a line of what is arriving: `return` (a coin coming home on the chain), `board`
/// (money moved in from the chain), or `round` (a coin of a settlement). The web wallet's
/// `arrivingCause`.
String arrivingCause(Map a) {
  if (a['state'] == 'exiting') return 'return';
  if (a['deposit'] == true || a['kind'] == 'board') return 'board';
  return 'round';
}

/// The seconds after which a line of [cause] is taking longer than it said.
int statedSeconds(String cause, {int boardMin = 5, int roundMin = 1}) =>
    cause == 'return' ? 2 * 86400 : cause == 'board' ? boardMin * 60 : roundMin <= 1 ? 180 : roundMin * 60;

/// When, in words, for a line of [cause]: "about a minute" for a settlement's coin at anchor
/// depth 0, never an anchor-depth wait the operator does not count.
String causeWhen(String cause, {int boardMin = 5, int roundMin = 1}) {
  if (cause == 'return') return DefaultWords.comingBackWhen;
  if (cause == 'board') return DefaultWords.boardWhen(boardMin);
  return roundMin <= 1 ? DefaultWords.arrivingSoon : DefaultWords.boardWhen(roundMin);
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

/// The pending payments' store over SharedPreferences.
class _PrefsPendingStore implements PendingStore {
  _PrefsPendingStore(this.p);
  final SharedPreferences p;
  @override
  String? getString(String key) => p.getString(key);
  @override
  void setString(String key, String value) => unawaited(p.setString(key, value));
  @override
  void remove(String key) => unawaited(p.remove(key));
}
