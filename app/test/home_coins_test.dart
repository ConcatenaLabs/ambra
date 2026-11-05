// Every coin home with the operator gone (home_coins.dart): the cases of the web wallet's
// default-arca.test.mjs and leaves.test.mjs for homeSummary, homeOnWay, homeQuote, homeTake and
// homeUnderWay, and the words.
import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/home_coins.dart';
import 'package:ambra/src/data/leaf_service.dart' show LeafRefusal;
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;
import 'package:flutter_test/flutter_test.dart';

final a = 'aa' * 32, b = 'bb' * 32, x = 'cc' * 32;

void main() {
  BigInt n(int v) => BigInt.from(v);

  test('taking every coin home: what it moves and what the holder pays, by asset, from the quotes', () {
    final q = HomeQuote();
    q.quotes.add(HomeQuoted(HomeCoin('1', a, '1000'), {
      'exit_delay_seconds': 130000,
      'steps': [
        {'fee': [{'asset': a, 'amount': '192'}], 'paid_by': 'its own reserve'},
        {'fee': [{'asset': b, 'amount': '7'}], 'paid_by': 'a fee coin of the wallet\'s'},
      ],
      'claim': {'fee': [{'asset': a, 'amount': '88'}]},
    }));
    q.quotes.add(HomeQuoted(HomeCoin('2', a, '500'), {'exit_delay_seconds': 1000, 'steps': [], 'claim': {'error': 'not yet'}}));
    q.channels.add(HomeCoin('c', b, '40'));
    q.refused.add(HomeRefused(HomeCoin('3', a, '9'), Exception('no')));
    final s = homeSummary(q);
    expect(s.count, 3);
    expect(s.delaySeconds, 130000);
    final ra = s.assets.firstWhere((r) => r.asset == a);
    expect(ra.atoms, n(1500));
    expect([for (final f in ra.feeList) '${f.asset.substring(0, 2)}:${f.atoms}'], ['bb:7', 'aa:88'],
        reason: 'a step its reserve pays costs the holder nothing');
    final rb = s.assets.firstWhere((r) => r.asset == b);
    expect(rb.atoms, n(40));
    expect(rb.feeList, isEmpty);
    expect([for (final r in s.refused) '${r.asset.substring(0, 2)}:${r.atoms}'], ['aa:9']);
    expect(homeSummary(null).count, 0);
    expect(homeHours(130000), 37);
    expect(homeHours(0), 0);
    const now = 10000000;
    final w = homeOnWay([HomeWay('1', a, '10', now - 3600000, 7200), HomeWay('2', a, '5', now, null)], now);
    expect(w.length, 1);
    expect(w.single.atoms, n(15));
    expect(w.single.hours, 1);
    for (final s in [
      DefaultWords.homeWhen(37), DefaultWords.homeWhen(0), DefaultWords.homeOnWay('1', 'USDX', 3), DefaultWords.homeOnWay('1', 'USDX', 0),
      DefaultWords.homeAsset('1', 'USDX', '0.1 USDX'), DefaultWords.homeNotNow('1', 'USDX'), DefaultWords.homeLine, DefaultWords.homeNothing,
      DefaultWords.homeTitle, DefaultWords.homeButton, DefaultWords.homeConfirm, DefaultWords.homeQuoting, DefaultWords.homeWorking,
    ]) {
      expect(forbiddenIn(s), isEmpty, reason: s);
    }
    expect(DefaultWords.homeAsset('50', 'USDX', '0.00000145 USDX'), '50 USDX, network fees about 0.00000145 USDX');
  });

  test('whether the operator can be reached, as a sync or an info says', () {
    final s = unreachableOf({'unreachable': {'why': 'gone', 'note': 'refused'}}, 'sync');
    expect(s.known, isTrue);
    expect(s.value?.why, 'gone');
    expect(s.value?.note, 'refused');
    expect(unreachableOf({'mailbox': {'error': 'x'}}, 'sync').value, isNull, reason: 'a sync without it: it answered');
    expect(unreachableOf({'mailbox': {}}, 'sync').known, isTrue);
    expect(unreachableOf({'server_info': {'unreachable': 'down'}}, 'info').value?.why, 'down');
    expect(unreachableOf({'operator': 'x'}, 'info').known, isFalse, reason: 'an info without server_info says nothing');
    expect(unreachableOf(null, 'sync').known, isFalse);
  });

  test('every coin held but one already on its way is offered; a channel goes by its own steps', () async {
    final runs = <List<Object?>>[];
    Future<dynamic> run(String c, Map<String, dynamic> args) async {
      runs.add([c, args]);
      if (c == 'exit_quote') {
        return {'asset': x, 'value': '10', 'fee_asset': x, 'exit_delay_seconds': 130000, 'steps': [], 'unroll': {x: '197'}, 'claim': {}};
      }
      if (c == 'exit' || c == 'channel_exit') return {'state': 'unrolling', 'broadcast': [{'txid': 't'}]};
      throw StateError(c);
    }

    final coins = [
      {'leaf_id': 'a1', 'state': 'live', 'asset': x, 'value': '10'},
      {'leaf_id': 'a2', 'state': 'given', 'asset': x, 'value': '10'},
      {'leaf_id': 'ch1', 'state': 'live', 'asset': x, 'value': '10'},
      {'leaf_id': 'out', 'state': 'exiting', 'asset': x, 'value': '10'},
      {'leaf_id': 'spent', 'state': 'spent', 'asset': x, 'value': '10'},
    ];
    expect(homeCoins(coins).map((c) => c['leaf_id']), ['a1', 'a2', 'ch1']);
    final q = await homeQuote(run, coins, ['ch1']);
    expect(q.quotes.map((e) => e.coin.leafId), ['a1', 'a2']);
    expect(q.channels.map((e) => e.leafId), ['ch1']);
    final r = await homeTake(run, q, now: () => 5);
    expect(r.started.length, 3);
    expect(r.refused, isEmpty);
    final exits = [for (final e in runs) if (e[0] == 'exit') e[1]];
    expect(exits.first, {'leaf_id': 'a1', 'shown': {x: '197'}, 'fee_asset': x}, reason: 'broadcast only on the fees the quote showed');
    expect([for (final e in runs) if (e[0] == 'channel_exit') e[1]], [{'leaf_id': 'ch1'}]);
    expect(runs.any((e) => ['participate', 'send', 'refresh_received'].contains(e[0])), isFalse,
        reason: 'nothing asks the operator for anything');
    // On its way: what the library holds as exiting (a coin a watchtower took out aside), with the
    // delay of what this wallet sent.
    final later = [
      {'leaf_id': 'a1', 'state': 'exiting', 'asset': x, 'value': '10'},
      {'leaf_id': 'a2', 'state': 'exiting', 'asset': x, 'value': '10'},
      {'leaf_id': 'ch1', 'state': 'exiting', 'asset': x, 'value': '10'},
      {'leaf_id': 'gone', 'state': 'exiting', 'asset': x, 'value': '10'},
      {'leaf_id': 'safe', 'state': 'exiting', 'kept_safe': true, 'asset': x, 'value': '10'},
    ];
    final way = homeUnderWay(later, r.kept, true);
    expect([for (final h in way.list) [h.leafId, h.delay]], [['a1', 130000], ['a2', 130000], ['ch1', null], ['gone', null]]);
    final answering = homeUnderWay(later, r.kept, false);
    expect(answering.list.map((h) => h.leafId), ['a1', 'a2', 'ch1'],
        reason: 'while the operator answers, only what a person sent is said');
    final arrived = homeUnderWay([{'leaf_id': 'a1', 'state': 'exited', 'asset': x, 'value': '10'}], r.kept, false);
    expect(arrived.list, isEmpty);
    expect(arrived.kept.keys, ['a2', 'ch1'], reason: 'what arrived is forgotten; what the library no longer lists is kept');
  });

  test('a coin whose shared steps another coin already took out goes on its lower fees, never on higher ones', () async {
    final runs = <List<Object?>>[];
    final quotes = <String, int>{'a1': 0, 'a2': 0, 'a3': 0};
    Future<dynamic> run(String c, Map<String, dynamic> args) async {
      runs.add([c, args]);
      final l = '${args['leaf_id']}';
      if (c == 'exit_quote') {
        quotes[l] = quotes[l]! + 1;
        final fee = quotes[l] == 1 ? '197' : (l == 'a2' ? '36' : '500');
        return {'asset': x, 'value': '10', 'fee_asset': x, 'exit_delay_seconds': 100, 'steps': [], 'unroll': {x: fee}, 'claim': {}};
      }
      if (c == 'exit') {
        if (l != 'a1' && (args['shown'] as Map)[x] == '197') {
          throw LeafRefusal('refused', 'refused: the exit\'s fees changed since they were shown; they are now {"$x":"36"}');
        }
        return {'state': 'unrolling', 'broadcast': []};
      }
      throw StateError(c);
    }

    final coins = [for (final l in ['a1', 'a2', 'a3']) {'leaf_id': l, 'state': 'live', 'asset': x, 'value': '10'}];
    final r = await homeTake(run, await homeQuote(run, coins));
    expect(r.started.map((s) => s.coin.leafId), ['a1', 'a2']);
    expect(r.refused.map((s) => s.coin.leafId), ['a3'], reason: 'a new quote above what was shown is not taken');
    expect([for (final e in runs) if (e[0] == 'exit' && (e[1] as Map)['leaf_id'] == 'a2') ((e[1] as Map)['shown'] as Map)[x]], ['197', '36']);
    expect(runs.any((e) => e[0] == 'exit' && (e[1] as Map)['leaf_id'] == 'a3' && ((e[1] as Map)['shown'] as Map)[x] == '500'), isFalse);
    expect(noMoreThan({x: '36'}, {x: '197'}), isTrue);
    expect(noMoreThan({x: '198'}, {x: '197'}), isFalse);
    expect(noMoreThan({b: '1'}, {x: '197'}), isFalse, reason: 'a fee in an asset not shown is more');
  });
}
