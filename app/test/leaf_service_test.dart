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
    expect(careArgs(7), {'scan': 27});
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
}
