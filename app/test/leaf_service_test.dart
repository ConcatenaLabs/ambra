import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/leaf_service.dart';

class _FrbLike {
  _FrbLike(this.message);
  final String message;
}

void main() {
  group('LeafRefusal.of', () {
    test('reads the library refusal in its own words', () {
      final r = LeafRefusal.of(_FrbLike(
          '{"error":{"kind":"server_refused","message":"the server refused cosign_transfer (409 key_reused): an output\'s key already owns a leaf","code":"key_reused","status":409}}'));
      expect(r.kind, 'server_refused');
      expect(r.code, 'key_reused');
      expect(r.status, 409);
      expect(r.message, "the server refused cosign_transfer (409 key_reused): an output's key already owns a leaf");
      expect('$r', r.message);
    });
    test('keeps any other text whole', () {
      expect(LeafRefusal.of(_FrbLike('no answer')).message, 'no answer');
      expect(LeafRefusal.of(StateError('x')).message, contains('x'));
    });
  });

  test('arrivals are the mailbox accepted coins', () {
    expect(arrivals(null), isEmpty);
    expect(arrivals({'note': 'the witness did not succeed'}), isEmpty);
    final a = arrivals({
      'accepted': [
        {'leaf_id': 'l1', 'asset': 'aa', 'value': '300000', 'kind': 'transfer'}
      ]
    });
    expect(a.single['value'], '300000');
  });

  test('something moving: a pending coin, or a participation not done', () {
    expect(inFlight([{'state': 'live'}], []), isFalse);
    expect(inFlight([{'state': 'pending'}], []), isTrue);
    expect(inFlight([], [{'state': 'waiting'}]), isTrue);
    expect(inFlight([], [{'state': 'done'}]), isFalse);
  });

  test('a request handed out in the last hour is read every tick', () {
    final s = {
      'now': 10000,
      'receive_requests': [
        {'state': 'waiting', 'asked_at': 9000}
      ]
    };
    expect(freshRequestWaits(s, DateTime.now()), isTrue);
    expect(freshRequestWaits({...s, 'now': 20000}, DateTime.now()), isFalse);
    expect(
        freshRequestWaits({
          'now': 10000,
          'receive_requests': [
            {'state': 'lapsed', 'asked_at': 9000}
          ]
        }, DateTime.now()),
        isFalse);
  });

  test('the app asks the schedule again within a minute, every 30 s while moving', () {
    expect(nextAsk(null, true), const Duration(seconds: 30));
    expect(nextAsk({'now': 100, 'next_sync_at': 120}, false), const Duration(seconds: 20));
    expect(nextAsk({'now': 100, 'next_sync_at': 100000}, false), LeafService.tick);
    expect(nextAsk({'now': 100, 'next_sync_at': 50}, false), const Duration(seconds: 5));
    expect(nextAsk({'now': 100, 'next_sync_at': null}, false), LeafService.tick);
  });

  test('the app syncs when the time the schedule first gave arrives, though the schedule moves it on and is not due', () {
    var d = syncDecision({'now': 1000, 'next_sync_at': 4600, 'due': false}, null, false);
    expect((d.sync, d.why, d.held), (false, null, 4600));
    d = syncDecision({'now': 2000, 'next_sync_at': 5600, 'due': false}, d.held, false);
    expect((d.sync, d.held), (false, 4600), reason: 'the time first given is held, not the one read now');
    d = syncDecision({'now': 4600, 'next_sync_at': 8200, 'due': false}, d.held, false);
    expect((d.sync, d.why, d.held), (true, 'time', null));
    d = syncDecision({'now': 1, 'next_sync_at': 9, 'due': true}, 5, false);
    expect((d.sync, d.why), (true, 'schedule'));
    d = syncDecision({'now': 1, 'next_sync_at': 9, 'due': false}, null, true);
    expect((d.sync, d.why), (true, 'moving'));
  });

  test('care runs at the first sync, then at most every ten minutes, and scans 20 past the kit\'s next index', () {
    final t = DateTime.utc(2026, 10, 21, 12);
    expect(careDue(null, t), isTrue, reason: 'never run: due');
    expect(careDue(t, t.add(const Duration(minutes: 9, seconds: 59))), isFalse);
    expect(careDue(t, t.add(const Duration(minutes: 10))), isTrue);
    expect(careArgs(7), {'scan': 27, 'plan_within': 4294967295});
    expect(kPlanEveryRoundLeaf, 4294967295, reason: 'every leaf of a round planned at its first care');
  });

  test('a care answer is counted part by part, refusals named', () {
    final sum = careSummary({
      'claims': [
        {'claim': 'c1', 'leaf_id': 'l1', 'value': '5', 'taken_up': {}},
        {'claim': 'c2', 'state': 'pending', 'note': 'not open'},
        {'claim': 'c3', 'refused': 'gone'},
      ],
      'cancelled': [
        {'plan_id': 'p1', 'coin': 'x', 'state': 'cancelled'}
      ],
      'planned': [
        {'plan_id': 'p2'},
        {'coin': 'y', 'asset': 'a', 'error': 'the operator will not plan in this asset'}
      ],
      'refreshing': [
        {'coin': 'z', 'participation': 'q', 'state': 'waiting', 'error': null}
      ],
      'not_yet_planned': 4,
      'plan_within': 864000,
      'max_fee_ppm': 2000,
    });
    expect((sum.claimed, sum.cancelled, sum.planned, sum.refreshing, sum.later), (1, 1, 1, 1, 4));
    expect(sum.refusals, ['c3: gone', 'y: the operator will not plan in this asset']);
    expect(careSummary(null).claimed, 0);
    expect(careSummary({'claims': {'error': 'no operator'}}).refusals, ['claims: no operator']);
  });

  group('paying a planned coin through the next round', () {
    const planned = '{"error":{"kind":"planned","message":"the wallet holds 100 of asset aa in live coins; 900 more is in coins an offline-refresh plan names","asset":"aa","release":["c1","c2"]}}';

    test('a planned refusal names its asset and the coins to release', () {
      final r = LeafRefusal.of(_FrbLike(planned));
      expect(r.kind, 'planned');
      expect(r.asset, 'aa');
      expect(r.release, ['c1', 'c2']);
      expect(LeafRefusal.of(_FrbLike('{"error":{"kind":"refused","message":"no"}}')).release, isEmpty);
    });

    test('the released coins are done once none is held or in the round', () {
      expect(releaseDone([], ['c1']), isTrue, reason: 'gone from the store');
      expect(releaseDone([{'leaf_id': 'c1', 'state': 'live'}], ['c1']), isFalse);
      for (final st in ['pending', 'given', 'offered', 'sending', 'forfeited']) {
        expect(releaseDone([{'leaf_id': 'c1', 'state': st}], ['c1']), isFalse, reason: st);
      }
      expect(releaseDone([{'leaf_id': 'c1', 'state': 'spent'}, {'leaf_id': 'c2', 'state': 'refreshed'}], ['c1', 'c2']), isTrue);
      expect(releaseDone([{'leaf_id': 'c1', 'state': 'spent'}, {'leaf_id': 'c2', 'state': 'live'}], ['c1', 'c2']), isFalse);
    });

    test('a planned leaf is the current coin of an open or stopped plan', () {
      final m = plannedCoins({
        'plans': [
          {'plan_id': 'p1', 'coin': 'a', 'state': 'open', 'steps': [{'leaf_id': null}]},
          {'plan_id': 'p2', 'coin': 'b', 'state': 'stopped', 'steps': [{'leaf_id': 'b2'}, {'leaf_id': null}]},
          {'plan_id': 'p3', 'coin': 'c', 'state': 'cancelled', 'steps': []},
        ]
      });
      expect(m.keys.toSet(), {'a', 'b2'});
      expect(m['b2']!['plan_id'], 'p2');
      expect(plannedCoins(null), isEmpty);
    });

    // A fake leaf wallet: `send` is refused `planned` until the released coins are gone.
    ({List<String> calls, Future<dynamic> Function(String, Map<String, dynamic>) run}) wallet({int roundsUntilFree = 2, bool plannedAgain = false}) {
      final calls = <String>[];
      var released = false, syncs = 0, refusedTwice = false;
      Future<dynamic> run(String cmd, Map<String, dynamic> args) async {
        calls.add(cmd);
        switch (cmd) {
          case 'send':
            if (!released || (plannedAgain && !refusedTwice)) {
              if (released) refusedTwice = true;
              if (released) {
                released = false;
                syncs = 0;
              }
              throw _FrbLike(planned);
            }
            return {'sent': '900'};
          case 'plan_release':
            expect(args['leaves'], ['c1', 'c2']);
            released = true;
            return {'participation': 'p'};
          case 'sync':
            syncs++;
            return {'mailbox': {'accepted': []}};
          case 'coins':
            final free = released && syncs >= roundsUntilFree;
            return [
              {'leaf_id': 'c1', 'state': free ? 'spent' : 'given'},
              {'leaf_id': 'c2', 'state': free ? 'spent' : 'live'},
              {'leaf_id': 'n1', 'state': 'live'},
            ];
        }
        throw _FrbLike('{"error":{"kind":"refused","message":"no such command"}}');
      }

      return (calls: calls, run: run);
    }

    test('release, sync until that round is final, ask again: no prompt', () async {
      final w = wallet();
      final waits = <ReleaseWait?>[];
      final slept = <Duration>[];
      final out = await payThroughRelease('send', {'request': 'r'},
          run: w.run, sleep: (d) async => slept.add(d), onWait: waits.add);
      expect(out, {'sent': '900'});
      expect(w.calls, ['send', 'plan_release', 'sync', 'coins', 'sync', 'coins', 'send']);
      expect(slept, [kReleasePoll]);
      expect(kReleasePoll, const Duration(seconds: 15));
      expect(waits.length, 2);
      expect(waits.first!.coins, ['c1', 'c2']);
      expect(waits.first!.asset, 'aa');
      expect(waits.first!.command, 'send');
      expect(waits.last, isNull, reason: 'the wait ends');
    });

    test('a release that falls short is asked again, at most three releases', () async {
      final w = wallet(plannedAgain: true, roundsUntilFree: 1);
      expect(await payThroughRelease('send', const {}, run: w.run, sleep: (_) async {}), {'sent': '900'});
      expect(w.calls.where((c) => c == 'plan_release').length, 2);
      var n = 0;
      Future<dynamic> always(String cmd, Map<String, dynamic> a) async {
        if (cmd == 'send') {
          n++;
          throw _FrbLike(planned);
        }
        if (cmd == 'coins') return [];
        return {};
      }

      await expectLater(payThroughRelease('send', const {}, run: always, sleep: (_) async {}),
          throwsA(isA<LeafRefusal>().having((r) => r.kind, 'kind', 'planned')));
      expect(n, 1 + kReleaseTries);
      expect(kReleaseTries, 3);
    });

    test('every other refusal is the library\'s, untouched, and nothing is released', () async {
      final calls = <String>[];
      await expectLater(
          payThroughRelease('send', const {}, run: (cmd, a) async {
            calls.add(cmd);
            throw _FrbLike('{"error":{"kind":"server_refused","message":"(409 frozen) the issuer froze it","code":"frozen","status":409}}');
          }),
          throwsA(isA<LeafRefusal>().having((r) => r.code, 'code', 'frozen').having((r) => r.message, 'message', '(409 frozen) the issuer froze it')));
      expect(calls, ['send']);
    });

    test('a round that does not come within three hours: nothing paid, ask again later', () async {
      var t = DateTime.utc(2026, 10, 22);
      final w = wallet(roundsUntilFree: 1 << 30);
      await expectLater(
          payThroughRelease('send', const {}, run: w.run, now: () => t, sleep: (d) async => t = t.add(d)),
          throwsA(isA<LeafRefusal>().having((r) => r.message, 'message', kReleaseTimeout)));
      expect(kReleaseWait, const Duration(hours: 3));
      expect(w.calls.where((c) => c == 'sync').length, 3 * 3600 ~/ 15 + 1);
      expect(w.calls.where((c) => c == 'send').length, 1, reason: 'not asked again after the timeout');
    });
  });
}
