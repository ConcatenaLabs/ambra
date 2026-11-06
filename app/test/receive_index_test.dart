// New code moves to a new address, never past what a scan from the phrase alone finds.
import 'package:ambra/src/data/receive_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each new code takes the next address', () {
    expect(nextReceiveIndex(4, 4), 5);
    expect(nextReceiveIndex(5, 4), 6);
    // A code shown below the next unused (a scan moved on since) goes to the next unused.
    expect(nextReceiveIndex(1, 7), 7);
  });

  test('never 20 or more past the next unused: back to it instead', () {
    expect(nextReceiveIndex(22, 4), 23);
    expect(nextReceiveIndex(23, 4), 4);
    expect(nextReceiveIndex(0, 0), 1);
    expect(nextReceiveIndex(19, 0), 0);
  });

  test('a hundred new codes in a row: every address handed out is one a restore finds', () {
    // A restore scans in batches of 20 past the last used address: with next unused n, it reads
    // every index up to n + 19 (the whole batch after the one holding n - 1, or 0..19 for n = 0).
    for (final next in [0, 1, 7, 19, 20, 33]) {
      var shown = next;
      final handed = <int>{shown};
      for (var i = 0; i < 100; i++) {
        final n = nextReceiveIndex(shown, next);
        expect(n, isNot(shown), reason: 'a new code moves to another address');
        expect(n, greaterThanOrEqualTo(next));
        expect(n, lessThan(next + receiveGap));
        handed.add(n);
        shown = n;
      }
      expect(handed.length, receiveGap, reason: 'it cycles through the whole window');
    }
  });

  test('a kept code is shown again only inside the window', () {
    expect(keptReceiveIndex(9, 4), 9);
    expect(keptReceiveIndex(23, 4), 23);
    expect(keptReceiveIndex(24, 4), 4);
    expect(keptReceiveIndex(3, 4), 4);
    expect(keptReceiveIndex(null, 4), 4);
  });
}
