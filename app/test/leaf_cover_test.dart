// The leaf wallet is handed the keys the main wallet handed out before it boards
// (data/leaf_service.dart coverReceiveKeys), against a stand-in library that reads its on-chain
// coins by a gap of 20 keys past the last key it handed out, as the library does. The same cases
// as the web wallet's leaves.test.mjs.
import 'package:ambra/src/data/leaf_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The library's view: keys handed out, and the coins it can see (those within 20 keys of them).
class Library {
  int handed = 0;
  final coinsAt = <int, BigInt>{}; // key -> atoms the main wallet shows there
  bool refuseAfter3 = false;
  Future<void> address() async {
    if (refuseAfter3 && handed >= 3) throw StateError('refused: the node is away');
    handed++;
  }

  BigInt onchain() => coinsAt.entries.where((e) => e.key < handed + 20).fold(BigInt.zero, (a, e) => a + e.value);
}

void main() {
  test('a coin past the library\'s window is not seen, so nothing is boarded, until the keys are handed', () async {
    final lib = Library()..coinsAt[45] = BigInt.from(50000000000000);
    var kept = 0;
    // The negative: the window (keys 0..19) does not reach key 45, so a board finds nothing.
    expect(lib.onchain(), BigInt.zero);
    final n = await coverReceiveKeys(want: 46, had: kept, handOne: lib.address, remember: (k) async => kept = k);
    expect([n, lib.handed, kept], [46, 46, 46]);
    expect(lib.onchain(), BigInt.from(50000000000000));
    // Once per key: a second pass hands nothing.
    expect(await coverReceiveKeys(want: 46, had: kept, handOne: lib.address, remember: (k) async => kept = k), 0);
    expect(lib.handed, 46);
    // A window short of the main wallet's index still misses the coin.
    final short = Library()..coinsAt[45] = BigInt.one;
    await coverReceiveKeys(want: 20, had: 0, handOne: short.address, remember: (_) async {});
    expect(short.onchain(), BigInt.zero);
  });

  test('a refusal stops the handing and keeps what was handed; a person\'s action waits', () async {
    final lib = Library()..refuseAfter3 = true;
    var kept = 0;
    final logs = <String>[];
    expect(await coverReceiveKeys(want: 10, had: 0, handOne: lib.address, remember: (k) async => kept = k, log: logs.add), 3);
    expect(kept, 3);
    expect(logs.first, contains('refused: the node is away'));
    final lib2 = Library();
    expect(await coverReceiveKeys(want: 10, had: 0, handOne: lib2.address, remember: (_) async {}, stop: () => true), 0);
    expect(lib2.handed, 0);
  });
}
