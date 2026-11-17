// The leaf rail's waits as default mode says them: finality at anchor depth 0, settle-first, the
// finding words of a restore, and a payment that waits written down so it is made once (the web
// wallet's settle-first, send-arriving, restore-finding, wait-and-go and pending-sends tests).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/pending_sends.dart';

String _refusal(Map<String, dynamic> e) => jsonEncode({'error': e});

class _Frb {
  _Frb(this.message);
  final String message;
}

void main() {
  group('finality at anchor depth 0', () {
    test('a settlement\'s coin is the wallet\'s in about a minute, never an invented anchor wait', () {
      expect(roundMinutes(0), 1);
      expect(roundMinutes(null), 1);
      expect(causeWhen('round', roundMin: roundMinutes(0)), 'about a minute');
      expect(boardMinutes(0), 5);
      expect(causeWhen('board', boardMin: boardMinutes(0)), 'usually within 5 minutes');
      // Only an operator that counts Bitcoin blocks adds their ten minutes each.
      expect(roundMinutes(1), 15);
      expect(boardMinutes(2), 25);
      expect(causeWhen('return'), 'within about two days');
      expect(statedSeconds('round'), 180);
      expect(arrivingCause({'state': 'exiting'}), 'return');
      expect(arrivingCause({'kind': 'board'}), 'board');
      expect(arrivingCause({'state': 'pending'}), 'round');
    });

    test('settle first usually takes 6 minutes on the testnet\'s settings', () {
      expect(settleMinutes(60, 60, 0, held: true), 6);
      expect(settleMinutes(60, 60, 0), 5);
      expect(settleMinutes(null, null, null), 5);
      // Each block of anchor depth the operator counts adds ten minutes; a published pass time
      // counts three passes for the release, one to build the settlement.
      expect(settleMinutes(60, 60, 1, held: true), 16);
      expect(settleMinutes(60, 60, 0, passSeconds: 20), 5);
      expect(settleMinutesOf({
        'anchor_depth': 0,
        'server_info': {'fills': {'round_interval_seconds': 60, 'block_seconds': 60}, 'batches': {'no_sweep': true}},
      }), 6);
      expect(settleMinutesOf(null), 5);
    });

    test('the time told is set by the first answer and moves back only with the step', () {
      final t = DateTime.utc(2026, 11, 17, 12);
      final a = nextFinalBy(null, {'usual_in_seconds': 300, 'final_in_seconds': 900, 'waiting_for': 'round'}, t)!;
      expect(a.at, t.add(const Duration(minutes: 5)));
      // A step that moves on keeps the time; a slower answer makes it late, not later.
      final b = nextFinalBy(a, {'usual_in_seconds': 600, 'waiting_for': 'block'}, t.add(const Duration(minutes: 1)))!;
      expect(b.at, a.at);
      expect(b.step, 'block');
      // A step that goes back (a new settlement) sets it again.
      final c = nextFinalBy(b, {'usual_in_seconds': 240, 'waiting_for': 'round'}, t.add(const Duration(minutes: 2)))!;
      expect(c.at, t.add(const Duration(minutes: 6)));
      expect(nextFinalBy(c, {'ready': true}, t), c);
      expect(nextFinalBy(null, {'ready': false}, t), isNull);
    });

    test('the words count down, then say it takes longer', () {
      final t = DateTime.utc(2026, 11, 17, 12);
      expect(settleWords(null, 6, t), 'Goes through within about 6 minutes');
      expect(settleWords(null, null, t), 'Goes through in about a minute');
      final by = t.add(const Duration(minutes: 4, seconds: 10));
      expect(settleWords(by, 6, t), 'Goes through within about 5 minutes');
      expect(settleWords(by, 6, by), 'Goes through in about a minute');
      expect(settleWords(by, 6, by.add(const Duration(minutes: 3))), DefaultWords.goesThroughLate);
    });
  });

  group('settle first, then go', () {
    test('money still arriving settles first, then the payment goes by itself', () async {
      final calls = <String>[];
      final waits = <ReleaseWait?>[];
      var asks = 0;
      Future<dynamic> run(String cmd, Map<String, dynamic> a) async {
        calls.add(cmd);
        switch (cmd) {
          case 'send':
            if (calls.where((c) => c == 'settle_first').length < 2) {
              throw _Frb(_refusal({
                'kind': 'settle_first', 'message': 'refused: settle first', 'asset': 'aa', 'coins': ['c1'],
                'final_in_seconds': 900, 'usual_in_seconds': 360, 'waiting_for': 'round',
              }));
            }
            return {'sent': '5'};
          case 'settle_first':
            asks++;
            expect(a, {'coins': ['c1']});
            return asks < 2 ? {'ready': false, 'usual_in_seconds': 300, 'waiting_for': 'block'} : {'ready': true};
          case 'sync':
            return {'mailbox': {'accepted': []}};
        }
        return null;
      }

      final t = DateTime.utc(2026, 11, 17);
      final out = await payThroughRelease('send', {'request': 'r', 'asset': 'aa'},
          run: run, now: () => t, sleep: (_) async {}, onWait: (w) => waits.add(w == null ? null : ReleaseWait(
              command: w.command, coins: w.coins, asset: w.asset, since: w.since, why: w.why, finalBy: w.finalBy)));
      expect(out, {'sent': '5'});
      expect(calls, ['send', 'settle_first', 'sync', 'settle_first', 'send']);
      expect(waits.first!.why, 'settle');
      expect(waits.first!.finalBy!.at, t.add(const Duration(minutes: 6)), reason: 'the refusal says how long at once');
      expect(waits.last, isNull);
    });

    test('a settle that never ends says nothing was sent, in plain words', () async {
      var t = DateTime.utc(2026, 11, 17);
      Future<dynamic> run(String cmd, Map<String, dynamic> a) async {
        if (cmd == 'send') throw _Frb(_refusal({'kind': 'settle_first', 'message': 'x', 'asset': 'aa'}));
        if (cmd == 'settle_first') {
          expect(a, {'asset': 'aa'}, reason: 'no coins named: the asset');
          return {'ready': false};
        }
        return {};
      }

      await expectLater(payThroughRelease('send', const {}, run: run, now: () => t, sleep: (d) async => t = t.add(d)),
          throwsA(isA<LeafRefusal>().having((r) => r.message, 'message', DefaultWords.settleGaveUp).having((r) => r.plain, 'plain', true)));
    });

    test('an offboard quote is answered as the library gave it', () async {
      await expectLater(
          payThroughRelease('offboard_quote', const {}, run: (c, a) async => throw _Frb(_refusal({'kind': 'settle_first', 'message': 'x'}))),
          throwsA(isA<LeafRefusal>().having((r) => r.kind, 'kind', 'settle_first')));
    });

    test('a coin the operator does not call live yet is asked again, never shown', () async {
      final calls = <String>[];
      var n = 0;
      final out = await payThroughRelease('send', const {}, sleep: (_) async {}, run: (c, a) async {
        calls.add(c);
        if (c == 'send' && n++ < 2) throw _Frb(_refusal({'kind': 'server_refused', 'code': 'not_live', 'message': 'pending, not live'}));
        return c == 'send' ? {'sent': '1'} : {};
      });
      expect(out, {'sent': '1'});
      expect(calls, ['send', 'sync', 'send', 'sync', 'send']);
    });

    test('a payment while the wallet\'s own refresh of its asset is in a round waits for that round', () async {
      final calls = <String>[];
      var ended = false;
      final out = await payThroughRelease('send', {'asset': 'aa'}, sleep: (_) async {}, run: (c, a) async {
        calls.add(c);
        switch (c) {
          case 'send':
            if (!ended) throw _Frb(_refusal({'kind': 'refused', 'message': 'refused: 5 of aa in live coins, 3 held'}));
            return {'sent': '5'};
          case 'coins':
            final r = [{'leaf_id': 'g1', 'asset': 'aa', 'state': ended ? 'spent' : 'given'}];
            if (calls.where((x) => x == 'coins').length >= 3) ended = true;
            return r;
        }
        return {};
      });
      expect(out, {'sent': '5'});
      expect(calls.first, 'send');
      expect(calls.last, 'send');
    });

    test('channels that would cover it are closed into the next round, then it goes', () async {
      final calls = <String>[];
      var closed = false;
      final out = await payThroughRelease('send', const {}, sleep: (_) async {}, run: (c, a) async {
        calls.add(c);
        switch (c) {
          case 'send':
            if (!closed) throw _Frb(_refusal({'kind': 'in_channel', 'message': 'x', 'asset': 'aa', 'close': ['ch1'], 'side': '7'}));
            return {'sent': '7'};
          case 'quote':
            expect(a, {'leaves': ['ch1']});
            return {'coins': ['q']};
          case 'participate':
            expect(a['shown'], ['q']);
            return {};
          case 'coins':
            closed = true;
            return [{'leaf_id': 'ch1', 'state': 'spent'}];
        }
        return {};
      });
      expect(out, {'sent': '7'});
      expect(calls, ['send', 'quote', 'participate', 'sync', 'coins', 'send']);
    });
  });

  group('finding what the wallet holds', () {
    test('the line says it finds, then that it is slow, long, or that the service does not answer', () {
      final t = DateTime.utc(2026, 11, 17);
      expect(restoreWords(null), isNull);
      expect(restoreWords(RestoreState(since: t)), DefaultWords.finding);
      expect(restoreWords(RestoreState(since: t, slow: 'slow')), DefaultWords.findingSlow);
      expect(restoreWords(RestoreState(since: t, slow: 'long')), DefaultWords.findingLong);
      expect(restoreWords(RestoreState(since: t, slow: 'slow', stalled: 'unreachable')), DefaultWords.findingStalled);
      expect(LeafService.restoreRetry, const Duration(seconds: 30));
      expect(LeafService.restoreSlow, const Duration(minutes: 2));
      expect(LeafService.restoreLong, const Duration(minutes: 30));
      expect(LeafService.historySlice, const Duration(milliseconds: 500));
    });
  });

  group('a payment that waits is made once', () {
    Map<String, dynamic> rec(String id, String state, DateTime at) =>
        {'id': id, 'kind': 'code', 'asset': 'aa', 'atoms': '5', 'to': 'r', 'command': 'send', 'args': {}, 'at': at.millisecondsSinceEpoch, 'state': state};

    test('one waiting is asked again; one being asked is never, and said once', () {
      final s = MapPendingStore();
      final t = DateTime.utc(2026, 11, 17, 12);
      putPending(s, 'w', rec('a', 'waiting', t));
      putPending(s, 'w', rec('b', 'asking', t));
      putPending(s, 'w', rec('c', 'waiting', t.subtract(const Duration(hours: 4))));
      final got = takePending(s, 'w', t.add(const Duration(minutes: 1)));
      expect(got.resume.map((r) => r['id']), ['a']);
      expect(got.dropped.map((r) => r['why']), ['asking', 'lapsed']);
      expect(pendingSends(s, 'w').map((r) => r['id']), ['a']);
      final ends = pendingEnds(s, 'w');
      expect(ends.map((e) => e['why']), ['unknown', 'lapsed']);
      expect(pendingEndText(ends.first, '5', 'USDX'), DefaultWords.pendingMaybeSent('5', 'USDX'));
      expect(pendingEndText(ends.last, '5', 'USDX'), DefaultWords.pendingNotSent('5', 'USDX'));
      markEndTold(s, 'w', 'b');
      expect(pendingEnds(s, 'w').map((e) => e['id']), ['c']);
    });

    test('the same payment asked again while one waits is named, and a stage is written before each ask', () {
      final s = MapPendingStore();
      final r = rec('a', 'asking', DateTime.utc(2026, 11, 17));
      final write = stageWriter(s, 'w', r);
      write('waiting');
      expect(pendingSends(s, 'w').single['state'], 'waiting');
      expect(samePending(s, 'w', asset: 'aa', atoms: '5', to: 'r'), isNotNull);
      expect(samePending(s, 'w', asset: 'aa', atoms: '6', to: 'r'), isNull);
      dropPending(s, 'w', 'a');
      expect(pendingSends(s, 'w'), isEmpty);
      expect(s.m, isEmpty);
    });
  });
}
