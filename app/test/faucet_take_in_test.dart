// A faucet payment to the receive code is taken in by a mailbox read, never a whole sync, so the
// faucet screen says Received within seconds of the faucet's answer (sequentia-faucet#25).
//
//   cd app && flutter test test/faucet_take_in_test.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/api_client.dart';
import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;

void main() {
  test('the mailbox is read every two seconds until the coin is there', () async {
    var t = DateTime(2026);
    var reads = 0;
    var there = false;
    final got = await readUntil(
      came: () => there,
      read: () async {
        reads++;
        if (reads == 3) there = true;
      },
      now: () => t,
      sleep: (d) async => t = t.add(d),
    );
    expect(got, isTrue);
    expect(reads, 3);
    expect(t.difference(DateTime(2026)), const Duration(seconds: 4));
  });

  test('a coin another read took in first counts with no read; one that never comes ends at 45 s', () async {
    var reads = 0;
    expect(await readUntil(came: () => true, read: () async => reads++), isTrue);
    expect(reads, 0);
    var t = DateTime(2026);
    expect(
        await readUntil(came: () => false, read: () async => reads++, now: () => t, sleep: (d) async => t = t.add(d)),
        isFalse);
    expect(t.difference(DateTime(2026)), takeInWithin);
    expect(takeInWithin, const Duration(seconds: 45));
    expect(reads, 23);
  });

  test('a read the library does not answer in time (busy with a sync) is not waited for', () async {
    final sw = Stopwatch()..start();
    final got = await readUntil(
        came: () => false, read: () => Completer<void>().future, within: const Duration(milliseconds: 300));
    expect(got, isFalse);
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('the faucet busy is told apart from a refusal the address would get past', () {
    final busy = FaucetRefused.of(429, {'error': 'The faucet has many requests waiting; please try again in a minute.', 'reason': 'busy', 'claimed': false});
    expect(busy.busy, isTrue);
    expect(busy.alreadyPaid, isFalse);
    expect(busy.status, 429);
    final paid = FaucetRefused.of(429, {'error': 'This wallet has already received its USDX from the faucet.', 'reason': 'wallet', 'claimed': true});
    expect(paid.busy, isFalse);
    expect(paid.alreadyPaid, isTrue);
    expect(FaucetRefused.of(503, {'error': 'The faucet has no USDX in leaves to pay now; please try again later.'}).busy, isFalse);
  });

  test('the words while the coin is on its way are the web wallet\'s, and say nothing of how it travels', () {
    final s = DefaultWords.faucetOnItsWay('5,000', 'OILX');
    expect(s, 'The faucet sent 5,000 OILX. It shows in your balance as soon as your wallet has taken it in, usually within a few minutes.');
    expect(forbiddenIn(s), isEmpty);
  });

  test('the faucet screen takes the coin in by the mailbox, never by a sync, and keeps a busy faucet off the address', () {
    final src = File('lib/src/screens/faucet_screen.dart').readAsStringSync();
    final i = src.indexOf('if (_userTree) {');
    final tree = src.substring(i, src.indexOf('if (_asLeaf && _leafOffered)', i));
    expect(tree.contains('openingSync'), isFalse);
    expect(tree.contains('syncNow'), isFalse);
    expect(tree, contains('final got = await LeafService.instance.takeIn(hex, since: since);'));
    expect(tree, contains('DefaultWords.faucetOnItsWay(r.amount, r.asset)'));
    expect(tree, contains('if (e is FaucetRefused && (e.alreadyPaid || e.busy)) rethrow;'));
  });
}
