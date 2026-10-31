// History in default mode: BTC another wallet paid into the ark is listed as received (#150),
// and a board, a move within the wallet, is not listed as money sent (#151).
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/screens/history_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> movement(int id, String subsystem, int sats,
        {String status = 'successful', Map<String, dynamic> metadata = const {}, List received = const []}) =>
    {
      'id': id,
      'status': status,
      'subsystem': {'name': subsystem, 'kind': 'x'},
      'metadata': metadata,
      'effective_balance': sats,
      'received_on': received,
      'time': {'created_at': '2026-10-31T10:00:00+01:00', 'completed_at': '2026-10-31T10:00:05+01:00'},
    };

void main() {
  test('a payment to the ark and a paid invoice are received; nothing else is', () {
    final rows = arkReceipts([
      movement(1, 'bark.arkoor', 10000),
      movement(2, 'bark.lightning_receive', 30000, metadata: {'payment_hash': 'aa'}),
      movement(3, 'bark.board', 59518), // the wallet's own on-chain BTC, moved in
      movement(4, 'bark.arkoor', -2000), // sent
      movement(5, 'bark.lightning_receive', 5000, status: 'pending'),
      movement(6, 'bark.lightning_receive', 40000, received: [{'destination': {'type': 'invoice', 'value': 'lntbOWN'}}]),
      movement(7, 'bark.lightning_receive', 7000, metadata: {'payment_hash': 'tradehash'}),
      movement(8, 'bark.round', 0),
    ], {'lntbOWN', 'tradehash'});
    expect([for (final r in rows) r['key']], ['ark:1', 'ark:2']);
    expect(rows.first['kind'], 'received');
    expect(rows.first['ticker'], 'BTC');
    expect(rows.first['atoms'], '10000');
    expect(rows.first['rail'], 'ark');
    expect(rows.first['time'], DateTime.parse('2026-10-31T10:00:05+01:00').millisecondsSinceEpoch);
  });

  test('a board is left out of the payments', () {
    core.TxRow tx(String id) => core.TxRow(txid: id, kind: 'outgoing', fee: BigInt.zero, feeAsset: 'x', deltas: const []);
    final txs = [tx('a'), tx('board'), tx('b')];
    expect([for (final t in withoutBoards(txs, {'board'})) t.txid], ['a', 'b']);
    expect(withoutBoards(txs, {}), same(txs));
  });

  test('the boards the operator names, by their transaction', () {
    expect(
        boardTxidsOf([
          {'leaf_id': 'l1', 'server': {'state': 'credited', 'txid': 't1'}},
          {'leaf_id': 'l2', 'server': {'error': 'unreachable'}},
          {'leaf_id': 'l3'},
        ]),
        {'t1'});
    expect(boardTxidsOf(null), isEmpty);
  });
}
