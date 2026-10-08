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
}
