// The composer's trade records are bounded, and the rows state only waits the wallet can stand by.
// The same cases as the web wallet's user-trade-records.test.mjs, trade-state-words.test.mjs,
// follow-settling.test.mjs and waiting-promises.test.mjs, as far as the app's engine has them.
import 'dart:convert';

import 'package:ambra/src/data/user_trade.dart';
import 'package:ambra/src/data/user_trade_btc.dart';
import 'package:flutter_test/flutter_test.dart';

final x = 'aa' * 32, y = 'bb' * 32;
const signing = ['transfer', 'swap_offer', 'swap_accept', 'participate', 'order_fill_resting', 'take', 'lightning_pay', 'lightning_receive'];

Map<String, dynamic> ended(int i, [int pad = 4000]) => {
      'id': 'old-$i',
      'at': 1000 + i,
      'state': 'settled',
      'ticket': {'note': 'x' * pad},
      'before': ['c' * 64],
    };
Map<String, dynamic> open(String id) => {
      'id': id,
      'at': 999,
      'state': 'sent',
      'ticket': {'note': 'still moving'},
      'before': ['c' * 64],
    };

/// An engine over a store holding at most [quota] characters, as a full phone does.
({UserTradeEngine eng, List<String> calls, String? Function() saved}) over(String? kept, int quota) {
  String? stored = kept;
  final calls = <String>[];
  final eng = UserTradeEngine(UserTradeDeps(
    run: (cmd, a) async {
      calls.add(cmd);
      return [];
    },
    fetchJson: (_, {post}) async => {},
    makers: () => [],
    relayBook: (_, _) async => [],
    admitted: () async => (pairs: null, genesis: 'g'),
    read: () async => stored,
    write: (v) async {
      if (v.length > quota) throw StateError('no room');
      stored = v;
    },
  ));
  return (eng: eng, calls: calls, saved: () => stored);
}

final ticket = Ticket(payAsset: x, receiveAsset: y, amountIn: BigInt.one, amountOut: BigInt.one, fees: const [], source: 'none-such');
Candidate choice() => Candidate(
    source: 'none-such',
    id: 'n',
    entry: BookEntry(
        source: 'none-such', id: 'n', rateNum: BigInt.one, rateDen: BigInt.one, maxReceive: BigInt.one, minReceive: BigInt.one, lot: BigInt.zero, raw: const {}),
    receive: BigInt.one,
    give: BigInt.one,
    fees: const []);

void main() {
  test('a list grown past the bound still saves, with the newest ended trades and the new one', () async {
    final list = [for (var i = 0; i < 600; i++) ended(i)];
    final o = over(jsonEncode(list), 2500000);
    await o.eng.confirm(choice(), ticket).catchError((_) => <String, dynamic>{});
    final after = (jsonDecode(o.saved()!) as List).cast<Map>();
    final ids = [for (final r in after) '${r['id']}'];
    expect(ids.any((id) => !id.startsWith('old-')), isTrue, reason: 'the new trade\'s record is kept');
    final kept = after.where((r) => r['state'] == 'settled').toList();
    expect(kept.length <= kKeepEnded, isTrue);
    expect(o.saved()!.length <= kKeepBytes + 10000, isTrue);
    expect(kept.last['id'], 'old-599', reason: 'the newest ended trade stays');
    expect(ids, isNot(contains('old-0')), reason: 'the oldest goes first');
    expect(kept.every((r) => !r.containsKey('before')), isTrue, reason: 'an ended record keeps no list of what the wallet held');
  });

  test('an unfinished trade\'s record survives the trim, however old', () async {
    final list = [open('oldest-open'), for (var i = 0; i < 400; i++) ended(i, 100), open('newer-open')];
    final o = over(jsonEncode(list), 10000000);
    await o.eng.confirm(choice(), ticket).catchError((_) => <String, dynamic>{});
    final after = (jsonDecode(o.saved()!) as List).cast<Map>();
    final ids = [for (final r in after) '${r['id']}'];
    expect(ids, containsAll(['oldest-open', 'newer-open']));
    // The new trade, refused at its step, is an ended one too.
    expect(after.where((r) => kEndedStates.contains(r['state'])), hasLength(kKeepEnded));
    expect(ids.first, 'oldest-open', reason: 'the order is kept');
    expect(after.first['before'], isNotNull, reason: 'an unfinished trade keeps what it saw');
  });

  test('a store with no room refuses the trade before anything is signed, in plain words', () async {
    final kept = jsonEncode([open('moving')]);
    final o = over(kept, kept.length + 10);
    await expectLater(o.eng.confirm(choice(), ticket), throwsA(isA<StorageFullError>()));
    expect(UserWords.storageFull, contains('Nothing was signed'));
    expect(o.calls.where(signing.contains), isEmpty, reason: 'no command that signs was asked');
    expect([for (final r in jsonDecode(o.saved()!) as List) (r as Map)['id']], ['moving']);
  });

  test('a received trade settling in a round states the wait for its round, then that it takes longer', () {
    const t0 = 1000000;
    final rec = {
      'source': 'leaf-maker',
      'state': 'sent',
      'sentAt': t0,
      'swapState': 'done',
      'settle': {'participations': ['p']},
      'settleState': ['pending'],
      'settleMin': 6,
      'settleSince': t0,
    };
    expect(tradeStateWord(rec, t0 + 60000), UserWords.receivedWithin(6));
    expect(UserWords.receivedWithin(6), 'Received, settling (within about 6 min)');
    expect(tradeStateWord(rec, t0 + 6 * 60000), UserWords.receivedWithin(6), reason: 'at the stated wait');
    // Past the stated wait and not yet late: "within about 6 min" is no longer true (web #821).
    expect(tradeStateWord(rec, t0 + 7 * 60000), UserWords.receivedDue);
    expect(tradeStateWord(rec, t0 + 6 * 60000 + kSettleLateMs), UserWords.receivedDue);
    expect(tradeStateWord(rec, t0 + 6 * 60000 + kSettleLateMs + 1), UserWords.receivedSlow);
    expect(forbiddenIn(UserWords.receivedDue), isEmpty);
    // A settle started before the wait was recorded: no count of minutes, which reads as a promise,
    // and still that it takes longer after kSlowSettleMin (web #819).
    final old = {...rec}..remove('settleMin');
    expect(tradeStateWord(old, t0 + 3 * 60000), UserWords.received);
    expect(tradeStateWord(old, t0 + kSlowSettleMin * 60000 + 1), UserWords.receivedSlow);
  });

  test('before its round starts a received trade counts no minutes, and says it takes longer in time (web #820)', () {
    const t0 = 1000000;
    final r = {'source': 'leaf-maker', 'swapState': 'done', 'state': 'sent', 'at': t0, 'sentAt': t0};
    expect(tradeStateWord(r, t0 + 3 * 60000), UserWords.received);
    expect(tradeStateWord(r, t0 + 9 * 60000), UserWords.received);
    expect(tradeStateWord(r, t0 + kSlowSettleMin * 60000 + 1), UserWords.receivedSlow);
  });

  test('a round the library no longer lists still counts as settling, with or without a stated wait', () {
    const t0 = 1000000;
    for (final st in [
      [null],
      ['released', null]
    ]) {
      final old = {
        'source': 'leaf-maker',
        'swapState': 'done',
        'state': 'sent',
        'at': t0,
        'sentAt': t0,
        'settle': {'participations': ['p']},
        'settleState': st,
      };
      expect(tradeStateWord(old, t0 + kSlowSettleMin * 60000 + 1), UserWords.receivedSlow, reason: 'no wait stated, $st');
      final r = {...old, 'settleMin': 6, 'settleSince': t0};
      expect(tradeStateWord(r, t0 + 3 * 60000), UserWords.receivedWithin(6), reason: 'stated wait, $st');
      expect(tradeStateWord(r, t0 + 7 * 60000), UserWords.receivedDue, reason: 'past the wait, $st');
      expect(tradeStateWord(r, t0 + 6 * 60000 + kSettleLateMs + 1), UserWords.receivedSlow, reason: 'late, $st');
    }
  });

  test('the wallet\'s figure for a round: 6 minutes on the testnet, longer for a deeper anchor', () {
    expect(settleMinutesOf(null), 5);
    expect(
        settleMinutesOf({
          'server_info': {
            'fills': {'round_interval_seconds': 60, 'block_seconds': 60},
            'batches': {'no_sweep': true},
          },
          'anchor_depth': 0,
        }),
        6);
    expect(settleMinutesOf({'anchor_depth': 2}), 25);
    expect(settleMinutes(60, 60, 0, passSeconds: 20), 5);
  });

  test('a stated wait is kept while its step stands or moves on, and set again only when the step goes back', () {
    var w = nextFinalBy(null, {'ready': false, 'usual_in_seconds': 120, 'waiting_for': 'round'}, 0);
    expect(w, {'finalBy': 120000, 'step': 'round'});
    w = nextFinalBy(w, {'ready': false, 'usual_in_seconds': 300, 'waiting_for': 'block'}, 60000);
    expect(w!['finalBy'], 120000, reason: 'a step slower than usual makes it late, not later');
    expect(w['step'], 'block');
    w = nextFinalBy(w, {'ready': false, 'final_in_seconds': 200, 'waiting_for': 'round'}, 90000);
    expect(w!['finalBy'], 290000, reason: 'a new round sets it again');
    expect(nextFinalBy(w, {'ready': true}, 100000), w);
  });

  test('settling and waiting trades are followed every few seconds until the settle is late', () {
    const now = 10 * 60000;
    final settling = {
      'source': 'leaf-maker',
      'state': 'sent',
      'sentAt': now - 3 * 60000,
      'swapState': 'done',
      'settleState': ['pending'],
    };
    expect(followFast([settling], now), isTrue);
    expect(followFast([{...settling, 'settleState': ['released']}], now), isFalse);
    expect(followFast([{...settling, 'sentAt': 0}], now + 1), isFalse, reason: 'late: followed slowly');
    expect(followFast([{'state': 'waiting', 'sentAt': 0, 'source': 'btc-gateway'}], now), isTrue);
    expect(followFast([{'state': 'sent', 'sentAt': now - 60000, 'source': 'leaf-maker'}], now), isTrue);
  });

  test('every word a row can say is in the word list and names no developer word', () {
    for (final w in [UserWords.waitingOther(3), UserWords.waitingOtherLate, UserWords.btcPaying, UserWords.btcCollecting, UserWords.receivedWithin(6),
        UserWords.returnedMoved, UserWords.returnedGone, UserWords.offeredAgain('YT', 'XT'), UserWords.storageFull, UserWords.sentAwaiting]) {
      expect(forbiddenIn(w), isEmpty, reason: w);
    }
    for (final w in [UserWords.waitingOtherLate, UserWords.btcPaying, UserWords.btcCollecting, UserWords.receivedWithin(6), UserWords.storageFull]) {
      expect(UserWords.all(), contains(w));
    }
  });
}
