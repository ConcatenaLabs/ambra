// A payment to a code another wallet of the phrase handed out (the payment name hands out the codes
// every wallet of a phrase leaves with the name service): the library refuses it at the mailbox
// read when the operator does not serve it yet, and only its catch-up, a step of `sync` it runs at
// most once every ten minutes of median time, takes it in. The wallet keeps the refused coins and
// syncs for them once the catch-up is open by the library's own clock, until it holds each one; and
// it reads the mailbox at every tick while any request it handed out waits, not only for an hour
// (ambra#270; the web wallet's catch-up-wait.test.mjs runs the same rules against its page).
//
//   cd app && flutter test test/catch_up_test.dart

import 'dart:convert';

import 'package:ambra/src/data/catch_up.dart';
import 'package:ambra/src/data/dev_mode.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const never = 'refused: a coin for owner nonce ab12, which this wallet never drew';
Map<String, dynamic> refusal(String id) => {
      'accepted': [],
      'refused': [
        {'leaf_id': id, 'reason': never},
      ],
      'waiting': [],
    };

/// The library as the wallet sees it: its median time [now] (seconds), a schedule a day away, one
/// request handed out [requestAge] seconds ago. `sync` runs the catch-up only once [kCatchUpEveryS]
/// have passed since the last; the catch-up takes in every coin paid to another store's code that
/// the operator has settled ([settled]). The mailbox refuses such a coin once.
class FakeLibrary {
  int now = 1800000000;
  int requestAge = 7200;
  int? lastCatchUp;
  final List<String> elsewhere = [];
  final Set<String> refusedOnce = {};
  final Set<String> settled = {};
  final List<Map<String, dynamic>> syncs = [];
  final List<String> commands = [];
  int mailboxReads = 0;
  // The node or the operator not answering a schedule read; a catch-up that answers with an error.
  bool scheduleThrows = false;
  bool catchUpErrs = false;

  Map<String, dynamic> mailbox() {
    mailboxReads++;
    final refused = [
      for (final id in elsewhere)
        if (refusedOnce.add(id)) {'leaf_id': id, 'reason': never},
    ];
    return {'accepted': [], 'refused': refused, 'waiting': []};
  }

  Object? answer(String command, Map args) {
    commands.add(command);
    switch (command) {
      case 'schedule':
        if (scheduleThrows) throw StateError('the node does not answer');
        return {
          'now': now,
          'due': false,
          'next_sync_at': now + 86400,
          'receive_requests': [
            {'owner': 'k', 'state': 'waiting', 'asked_at': now - requestAge, 'lapses_at': now - requestAge + 27 * 86400},
          ],
        };
      case 'mailbox':
        return mailbox();
      case 'sync':
        final mb = mailbox();
        Map<String, dynamic>? caughtUp;
        if (catchUpErrs) {
          caughtUp = {'error': 'the operator did not answer the catch-up'};
        } else if (lastCatchUp == null || now - lastCatchUp! >= kCatchUpEveryS) {
          lastCatchUp = now;
          final ripe = elsewhere.where(settled.contains).toList();
          elsewhere.removeWhere(ripe.contains);
          caughtUp = {
            'restored': [
              for (final id in ripe) {'leaf_id': id, 'asset': 'bb' * 32, 'value': '5', 'kind': 'mailbox'},
            ],
            'given_elsewhere': [],
          };
        }
        syncs.add({'args': args, 'caughtUp': caughtUp != null});
        return {'mailbox': mb, 'caught_up': caughtUp, 'schedule': {'now': now}};
      case 'balance':
        return {'arca': {}};
      case 'claims':
      case 'coins':
      case 'participations':
        return [];
      default:
        return {};
    }
  }

  Future<String> call(String command, String argsJson) async {
    try {
      return jsonEncode({'result': answer(command, jsonDecode(argsJson) as Map)});
    } on StateError catch (e) {
      throw 'refused: ${e.message}';
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the rules', () {
    test('kept until held, whole catch-ups counted, every attempt counted, the gate in median time', () {
      expect(phraseCoinsRefused({
        'refused': [
          {'leaf_id': 'x', 'reason': never},
          {'leaf_id': 'y', 'reason': 'refused: other'},
        ],
      }), ['x']);
      var w = catchUpWait(null, mailbox: refusal('x'), now: 1000);
      var r = catchUpAfterSync(w, sync: {
        'caught_up': {
          'restored': [
            {'leaf_id': 'other'},
          ],
        },
      }, now: 5000);
      expect(r.arrived, isEmpty);
      expect(r.wait!.pending, ['x']);
      expect(r.wait!.tries, 1);
      expect(catchUpHeld(r.wait, [
        {'leaf_id': 'x', 'asset': 'a', 'value': '7', 'state': 'live'},
      ], 6000).wait, isNull);
      // One sync can refuse a coin at its mailbox step and restore it at its catch-up.
      r = catchUpAfterSync(null, sync: {
        'mailbox': refusal('z'),
        'caught_up': {
          'restored': [
            {'leaf_id': 'z', 'asset': 'a', 'value': '3'},
          ],
        },
      }, now: 1);
      expect(r.arrived.map((c) => c['leaf_id']), ['z']);
      w = catchUpAttempt(catchUpWait(null, mailbox: refusal('x'), now: 0), 10)!;
      expect(catchUpSyncIn(w, now: 10), kCatchUpRetryMs);
      expect(catchUpGate(null, {'caught_up': {'restored': []}, 'schedule': {'now': 1000}}, 900), 1000 + kCatchUpEveryS);
      expect(catchUpGate(500, {'caught_up': {'restored': [], 'more': true}}, 900), 0);
      expect(catchUpGate(null, {'caught_up': null}, 900), 900 + kCatchUpEveryS ~/ 2);
    });

    test('a coin still in the operator\'s word "pending" is not held yet', () {
      final w = catchUpWait(null, mailbox: refusal('x'), now: 0);
      expect(catchUpHeld(w, [
        {'leaf_id': 'x', 'state': 'pending'},
      ], 1).wait!.pending, ['x']);
    });

    test('the wait ends after six whole catch-ups, or a day', () {
      var w = catchUpWait(null, mailbox: refusal('x'), now: 0);
      for (var i = 0; i < kCatchUpTries; i++) {
        w = catchUpAfterSync(w, sync: {'caught_up': {'restored': []}}, now: i + 1).wait;
      }
      expect(w, isNull);
      w = catchUpWait(null, mailbox: refusal('x'), now: 0);
      expect(catchUpSyncIn(w, now: kCatchUpLastMs), isNull);
    });

    test('a catch-up that answers with an error ran none: it counts towards the slow cadence', () {
      var w = catchUpWait(null, mailbox: refusal('x'), now: 0);
      for (var i = 0; i < kCatchUpSlowAfter; i++) {
        w = catchUpAfterSync(w, sync: {'caught_up': {'error': 'no answer'}}, now: i).wait;
      }
      expect(w!.nulls, kCatchUpSlowAfter, reason: 'an error never resets the count');
      expect(w.tries, 0, reason: 'nor is it a whole catch-up');
      expect(catchUpSyncIn(w, now: kCatchUpSlowAfter), kCatchUpSlowMs - 1);
    });

    test('the job wakes no later than the wait\'s next sync, rounded up to a second', () {
      expect(jobWakeIn(86400, null), 86400);
      expect(jobWakeIn(null, null), isNull);
      expect(jobWakeIn(null, 60000), 60);
      expect(jobWakeIn(86400, 1), 1);
      expect(jobWakeIn(30, 600000), 30);
    });

    test('a failing node slows the attempts down, never spins', () {
      var w = catchUpWait(null, mailbox: refusal('x'), now: 0);
      for (var i = 0; i < kCatchUpSlowAfter; i++) {
        w = catchUpAttempt(w, i);
      }
      expect(catchUpSyncIn(w, now: kCatchUpSlowAfter), kCatchUpSlowMs - 1);
    });

    test('a request waits for its whole life, a restored one is the library\'s', () {
      Map<String, dynamic> s(Map<String, dynamic> q) => {
            'now': 10000000,
            'receive_requests': [
              {'owner': 'k', 'state': 'waiting', ...q},
            ],
          };
      expect(requestWaits(s({'asked_at': 10000000 - 7200, 'lapses_at': null})), isTrue);
      expect(requestWaits(s({'asked_at': 10000000 - 20 * 86400, 'lapses_at': 10000000 + 86400})), isTrue);
      expect(requestWaits(s({'asked_at': 10000000 - kRequestHoldsS - 1, 'lapses_at': null})), isFalse);
      expect(requestWaits(s({'asked_at': 10000000 - 7200, 'lapses_at': 10000000 - 1})), isFalse);
      expect(requestWaits(s({'owner': 'restored', 'asked_at': 10000000 - 7200, 'lapses_at': 10000000 + 86400})), isFalse);
      expect(requestWaits(s({'state': 'paid', 'asked_at': 10000000 - 7200})), isFalse);
    });
  });

  group('the wallet\'s upkeep', () {
    late FakeLibrary lib;
    final l = LeafService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await LeafService.forgetCare();
      lib = FakeLibrary();
      LeafService.debugLibrary = lib.call;
      l.resetReadsForTest();
      l.open = true;
    });
    tearDown(() {
      l.stopPassesForTest();
      l.open = false;
      LeafService.debugLibrary = null;
    });

    test('a request handed out two hours ago is read for at every tick, in developer mode too', () async {
      await DevMode.instance.loadFor('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
      await DevMode.instance.set(true);
      expect(DevMode.instance.on, isTrue);
      try {
        await l.tickForTest(ticking: false);
        expect(lib.mailboxReads, 1, reason: 'the name\'s codes are handed out up to a day after they are made');
      } finally {
        await DevMode.instance.set(false);
      }
    });

    test('a coin paid to another wallet\'s code is synced for at once, without the watchtowers, and shown', () async {
      lib.elsewhere.add('x');
      lib.settled.add('x');
      // The first pass reads the mailbox, which refuses the coin.
      await l.tickForTest(ticking: false);
      expect(l.catchUp?.pending, ['x']);
      expect(lib.syncs, isEmpty);
      final before = l.arrivedCount;
      // The next pass syncs for it: the library's catch-up is open, and it takes the coin in.
      await l.tickForTest(ticking: false);
      expect(lib.syncs, hasLength(1));
      expect(lib.syncs.single['args'], {'deposits': false});
      expect(lib.syncs.single['caughtUp'], isTrue);
      expect(l.arrivedCount, before + 1);
      expect(l.catchUp, isNull);
    });

    test('once a catch-up ran, the next sync for the wait waits for the library\'s clock', () async {
      lib.elsewhere.add('x');
      await l.tickForTest(ticking: false);
      await l.tickForTest(ticking: false);
      // The catch-up ran whole without the coin (the operator has not settled it yet).
      expect(lib.syncs, hasLength(1));
      expect(l.catchUp?.pending, ['x']);
      lib.settled.add('x');
      // A minute later by the wall: the library's catch-up is closed for ten minutes of its time.
      lib.now += 60;
      await l.tickForTest(ticking: false);
      expect(lib.syncs, hasLength(1));
      lib.now += kCatchUpEveryS;
      await l.tickForTest(ticking: false);
      expect(lib.syncs, hasLength(1), reason: 'a minute between two attempts, whatever the library\'s clock');
    });

    test('out of view the pass keeps its usual pace and reads no more than before (ambra#276)', () async {
      lib.requestAge = 7 * 86400;
      final b = TestWidgetsFlutterBinding.instance;
      b.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      try {
        await l.tickForTest(ticking: false);
        expect(l.plannedInForTest!.inSeconds, greaterThanOrEqualTo(50), reason: 'nextAsk, not the ten-second cap');
      } finally {
        b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      l.stopPassesForTest();
      l.resetReadsForTest();
      await l.tickForTest(ticking: false);
      expect(l.plannedInForTest!.inSeconds, lessThanOrEqualTo(LeafService.mailboxEvery.inSeconds), reason: 'in view, the ten-second cap');
    });

    test('out of view in developer mode, a week-old request is not read for at every pass', () async {
      lib.requestAge = 7 * 86400;
      await DevMode.instance.loadFor('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
      await DevMode.instance.set(true);
      final b = TestWidgetsFlutterBinding.instance;
      b.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      try {
        await l.tickForTest(ticking: false);
        expect(lib.mailboxReads, 0);
      } finally {
        b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await DevMode.instance.set(false);
      }
    });

    test('a node that throws keeps the wait\'s cadence: ten minutes after ten attempts, not a pass a minute (ambra#277)', () async {
      lib.elsewhere.add('x');
      await l.tickForTest(ticking: false);
      expect(l.catchUp?.pending, ['x']);
      lib.scheduleThrows = true;
      for (var i = 0; i < kCatchUpSlowAfter; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 3));
        await l.tickForTest(ticking: false);
      }
      expect(l.catchUp!.nulls, kCatchUpSlowAfter);
      expect(l.plannedInForTest!.inSeconds, greaterThan(9 * 60), reason: 'the next pass after ten failed attempts');
    });

    test('a catch-up that answers with an error is an attempt that ran none, never a reset (ambra#277)', () async {
      lib.elsewhere.add('x');
      lib.catchUpErrs = true;
      await l.tickForTest(ticking: false);
      await l.tickForTest(ticking: false);
      expect(lib.syncs, hasLength(1));
      expect(l.catchUp!.nulls, 1);
      expect(l.catchUp!.tries, 0);
    });

    test('a catch-up sync is followed by the watchtowers\' deposits (ambra#275)', () async {
      lib.elsewhere.add('x');
      lib.settled.add('x');
      await l.tickForTest(ticking: false);
      await l.tickForTest(ticking: false);
      expect(lib.syncs.single['args'], {'deposits': false});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(lib.commands.indexOf('deposits'), greaterThan(lib.commands.indexOf('sync')));
    });

    test('back from the background, the wallet goes on with the wait as the job left it', () async {
      lib.elsewhere.add('x');
      await l.tickForTest(ticking: false);
      expect(l.catchUp?.pending, ['x']);
      // The job took the coin in meanwhile and ended the wait.
      final p = await SharedPreferences.getInstance();
      await p.setString('ambra.leaves.catchUp', jsonEncode({'wait': null, 'openAt': lib.now + kCatchUpEveryS}));
      await l.openingSync(by: 'resume');
      expect(l.catchUp, isNull);
    });

    test('the wait survives the app closing', () async {
      lib.elsewhere.add('x');
      await l.tickForTest(ticking: false);
      final kept = jsonDecode((await SharedPreferences.getInstance()).getString('ambra.leaves.catchUp')!) as Map;
      expect((kept['wait'] as Map)['pending'], ['x']);
    });
  });

  group('the scheduled job, with the app closed (ambra#278)', () {
    const host = MethodChannel('catch-up-test/job');
    final notified = <String>[];
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      notified.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(host, (c) async {
        if (c.method == 'notify') notified.add('${(c.arguments as Map)['id']}');
        return null;
      });
    });
    Future<void> keep(CatchUpWait? w, {num? openAt}) async =>
        (await SharedPreferences.getInstance()).setString('ambra.leaves.catchUp', jsonEncode({'wait': w?.toJson(), 'openAt': openAt}));
    Future<CatchUpWait?> kept() async =>
        CatchUpWait.fromJson((jsonDecode((await SharedPreferences.getInstance()).getString('ambra.leaves.catchUp')!) as Map)['wait']);
    Map<String, dynamic> pass({Object? mailbox, Object? caughtUp, List coins = const [], int wake = 86400, int now = 1800000000}) => {
          'arrived': [],
          'schedule': {'now': now, 'next_sync_at': now + wake},
          'wake_in': wake,
          'sync': {'mailbox': mailbox ?? {'accepted': [], 'refused': []}, 'caught_up': caughtUp, 'schedule': {'now': now}},
          'coins': coins,
        };

    test('a refusal in the job starts the wait, kept for the app, and the job wakes for it', () async {
      final r = await jobOutcome(pass(mailbox: refusal('y'), caughtUp: {'restored': []}), host: host, nowMs: 1000);
      expect((await kept())!.pending, ['y']);
      // The catch-up just ran whole: the library opens it again ten minutes on.
      expect(r['wake_in'], kCatchUpEveryS);
    });

    test('a coin the app waited for, restored by the job\'s catch-up, is shown and ends the wait', () async {
      await keep(catchUpWait(null, mailbox: refusal('x'), now: 0));
      final r = await jobOutcome(pass(caughtUp: {'restored': [{'leaf_id': 'x', 'asset': 'aa', 'value': '5'}]}), host: host, nowMs: 1000);
      expect(notified, ['x']);
      expect(await kept(), isNull);
      expect(r['wake_in'], 86400);
    });

    test('a coin the wallet holds after the job ends the wait too', () async {
      await keep(catchUpWait(null, mailbox: refusal('x'), now: 0));
      await jobOutcome(pass(coins: [{'leaf_id': 'x', 'asset': 'aa', 'value': '5', 'state': 'live'}]), host: host, nowMs: 1000);
      expect(notified, ['x']);
      expect(await kept(), isNull);
    });

    test('a failed pass is an attempt: a minute on, then ten minutes after ten in a row', () async {
      await keep(catchUpWait(null, mailbox: refusal('x'), now: 0));
      expect(await jobFailed(nowMs: 1000), kCatchUpRetryMs ~/ 1000);
      for (var i = 1; i < kCatchUpSlowAfter; i++) {
        await jobFailed(nowMs: 1000 + i);
      }
      expect((await kept())!.nulls, kCatchUpSlowAfter);
      expect(await jobFailed(nowMs: 2000), kCatchUpSlowMs ~/ 1000);
    });

    test('without a wait, a failed pass names no wake time (the host retries in an hour)', () async {
      expect(await jobFailed(nowMs: 1000), isNull);
    });
  });
}
