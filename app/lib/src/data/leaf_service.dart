import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../rust/api/leaves.dart' as leaves;
import 'config.dart';
import 'format.dart';
import 'wallet_repository.dart';

/// A refusal by the leaf wallet, in the library's own words.
class LeafRefusal implements Exception {
  LeafRefusal(this.kind, this.message, {this.code, this.status});
  final String kind;
  final String message;
  final String? code;
  final int? status;

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
            code: err['code']?.toString(), status: (err['status'] as num?)?.toInt());
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
  bool open = false;
  bool busy = false;
  LeafOperator? operator;
  Map<String, dynamic>? info;
  Map<String, dynamic>? balance;
  List<dynamic> coins = const [];
  List<dynamic> participations = const [];
  Map<String, dynamic>? schedule;
  DateTime? lastSync;
  LeafRefusal? lastError;
  Timer? _timer;
  bool _ticking = false;

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
      _plan(Duration.zero);
    }
  }

  /// Stops the schedule and closes the wallet; the scheduled job takes over.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (open) leaves.leavesClose();
    open = false;
    await _foreground(false);
    notifyListeners();
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
      try {
        await Permission.notification.request();
      } catch (_) {}
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
    notifyListeners();
  }

  /// A sync now: what the library does on its own (the mailbox, refreshes, every
  /// coin's way home), and a notification per coin received.
  Future<Map<String, dynamic>> syncNow({String by = 'user'}) async {
    final r = await run('sync') as Map<String, dynamic>;
    lastSync = DateTime.now();
    for (final a in arrivals(r['mailbox'])) {
      await notifyArrived(a, channel: _channel);
    }
    await refresh();
    return r;
  }

  /// Leaf atoms per asset: every coin the library counts as held off the chain,
  /// whatever its state.
  Map<String, BigInt> leafAtoms() {
    final out = <String, BigInt>{};
    final arca = balance?['arca'];
    if (arca is! Map) return out;
    arca.forEach((asset, states) {
      if (states is! Map) return;
      var sum = BigInt.zero;
      states.forEach((_, v) => sum += BigInt.tryParse('$v') ?? BigInt.zero);
      if (sum > BigInt.zero) out['$asset'] = sum;
    });
    return out;
  }

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
      final moving = inFlight(coins, participations);
      if (s?['due'] == true || moving) {
        await syncNow(by: s?['due'] == true ? 'schedule' : 'moving');
      } else if (freshRequestWaits(s, DateTime.now())) {
        final mb = await run('mailbox');
        for (final a in arrivals(mb)) {
          await notifyArrived(a, channel: _channel);
        }
        if (arrivals(mb).isNotEmpty) await refresh();
      }
      lastError = null;
      wait = nextAsk(schedule, inFlight(coins, participations));
    } catch (e) {
      lastError = LeafRefusal.of(e);
    }
    _ticking = false;
    notifyListeners();
    _plan(wait);
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
  final out = jsonDecode(
          await leaves.leavesJob(dir: dir, mnemonic: m, nodePassword: await LeafService.nodePassword() ?? ''))
      as Map<String, dynamic>;
  if (out['joined'] == false) return {'ok': true, 'wake_in': null, 'summary': 'no leaf wallet'};
  final arrived = arrivals({'accepted': out['arrived']});
  for (final a in arrived) {
    await notifyArrived(a, channel: host);
  }
  final s = out['schedule'] as Map?;
  return {
    'ok': true,
    'wake_in': out['wake_in'],
    'summary': 'arrived ${arrived.length}; next_sync_at ${s?['next_sync_at']}; now ${s?['now']}',
  };
}
