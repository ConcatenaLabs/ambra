// A payment to the receive code is read between the commands of the wallet's own upkeep (a sync
// and the care, claims and bond's watch after it), not only once the whole pass is over: the pass
// takes up to a minute, and every other read of the library waited for it (the user-mode
// reliability run measured receives of 61 to 127 s on the phone).
//
//   cd app && flutter test test/reads_between_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/src/data/leaf_service.dart').readAsStringSync();
  String body(String start, String end) {
    final i = src.indexOf(start);
    expect(i, greaterThanOrEqualTo(0), reason: start);
    final j = src.indexOf(end, i + start.length);
    return src.substring(i, j < 0 ? src.length : j);
  }

  test('a sync is followed by a read between each of the steps after it', () {
    final sync = body('Future<Map<String, dynamic>> syncNow(', 'Future<void> careIfDue(');
    expect(RegExp(r'await _readsBetween\(\);').allMatches(sync).length, greaterThanOrEqualTo(3));
    // A sync reads the mailbox itself.
    expect(sync, contains('_mailReadAt = lastSync;'));
  });

  test('care reads between itself, the claims and the bond’s watch', () {
    final care = body('Future<void> careIfDue(', 'Future<void> readClaims(');
    final reads = care.indexOf('await _readsBetween();');
    expect(reads, greaterThan(0));
    expect(reads, lessThan(care.indexOf('await watchBond();')));
  });

  test('the reads are the mailbox when due and the channels when due, never while a person asks', () {
    final between = body('Future<void> _readsBetween()', '/// The channels as the wallet holds them;');
    expect(between, contains('_asking > 0'));
    expect(between, contains("run('mailbox')"));
    expect(between, contains('freshRequestWaits(schedule, now) ? fastAsk : mailboxEvery'));
    expect(between, contains('_readChannelsNow()'));
    // A channel read from between the steps does not wait for the pass it is part of.
    final channel = body('Future<void> _readChannelsNow()', 'DateTime? _mailReadAt;');
    expect(channel.contains('!_ticking'), isFalse);
  });
}
