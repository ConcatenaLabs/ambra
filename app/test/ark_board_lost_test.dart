// A board whose funding transaction the network never took no longer stops every board after it.
import 'package:ambra/src/data/ark_btc_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final s = ArkBtcService.instance;

  test('a board the network knows is waited on; one unknown is waited on for a while only', () async {
    final boards = [
      {'funding_txid': 'aa', 'amount': '30000'}
    ];
    expect(await s.boardsLost(boards, status: (_) async => 200), isFalse);
    // Unknown, first seen now: wait.
    expect(await s.boardsLost(boards, status: (_) async => 404), isFalse);
    // The explorer unreachable: no verdict.
    expect(await s.boardsLost(boards, status: (_) async => throw Exception('offline')), isFalse);
    expect(await s.boardsLost(null), isFalse);
    expect(await s.boardsLost(const []), isFalse);
  });

  test('unknown to the network for ten minutes: boarded again', () async {
    final boards = [
      {'funding_txid': 'dd'}
    ];
    final t0 = DateTime(2026, 10, 30, 12);
    expect(await s.boardsLost(boards, status: (_) async => 404, at: t0), isFalse);
    expect(await s.boardsLost(boards, status: (_) async => 404, at: t0.add(const Duration(minutes: 9))), isFalse);
    expect(await s.boardsLost(boards, status: (_) async => 404, at: t0.add(const Duration(minutes: 11))), isTrue);
    // Seen on the network meanwhile: waited on again.
    expect(await s.boardsLost(boards, status: (_) async => 200, at: t0.add(const Duration(minutes: 12))), isFalse);
  });

  test('two boards, one known: waited on', () async {
    final boards = [
      {'funding_txid': 'bb'},
      {'funding_txid': 'cc'}
    ];
    expect(await s.boardsLost(boards, status: (t) async => t == 'bb' ? 404 : 200), isFalse);
  });
}
