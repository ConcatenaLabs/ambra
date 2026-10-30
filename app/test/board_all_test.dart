// The automatic board of everything held less its own fee, against a library that prices a
// board's coins at a size before it knows the real one (wallet.rs board_tx: value plus the fee of
// 300 vB must be held, then the real fee of the smaller transaction is charged).
import 'package:ambra/src/data/leaf_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final held = BigInt.parse('49799999999221');
  final min = BigInt.from(1000000);
  const realFee = 30, firstGuess = 60;

  Future<dynamic> Function(String, [Map<String, dynamic>]) library(List<String> calls) =>
      (String cmd, [Map<String, dynamic> a = const {}]) async {
        final v = BigInt.parse('${a['amount']}');
        calls.add('$cmd $v');
        if (v + BigInt.from(firstGuess) > held) {
          throw LeafRefusal('refused', 'the wallet holds $held of asset x on-chain that it can spend, and needs ${v + BigInt.from(firstGuess)}');
        }
        final fee = {'asset': 'x', 'amount': '$realFee'};
        if (cmd == 'board') {
          expect(a['shown'], fee);
          return {'boarded': true};
        }
        return {'fee': fee};
      };

  test('everything less the fee is boarded, after the library asks for more room once', () async {
    final calls = <String>[];
    final r = await boardAll(library(calls), asset: 'x', held: held, min: min);
    expect(r, isNotNull);
    expect(r!.$2, BigInt.from(realFee));
    expect(r.$1 + r.$2 <= held, isTrue);
    expect(calls.last, startsWith('board '));
    // The first quote of held less the real fee is refused; the room is doubled; then it boards.
    expect(calls.where((c) => c.startsWith('board_quote')).length, 3);
  });

  test('nothing is boarded below the smallest leaf, nor when a person asks meanwhile', () async {
    expect(await boardAll(library([]), asset: 'x', held: BigInt.from(1000020), min: min), isNull);
    expect(await boardAll(library([]), asset: 'x', held: held, min: min, stop: () => true), isNull);
  });

  test('a board\'s coins are not counted on the chain and as arriving at once', () {
    final l = LeafService.instance;
    expect(l.onchainLessBoards('y', BigInt.from(500)), BigInt.from(500));
    l.debugBoarded('y', spent: BigInt.from(470), held: BigInt.from(500));
    // The chain reading has not seen the board's spend: the board's coins come off.
    expect(l.onchainLessBoards('y', BigInt.from(500)), BigInt.from(30));
    // Once it has, the reading is taken as it is, and the record goes.
    expect(l.onchainLessBoards('y', BigInt.from(30)), BigInt.from(30));
    expect(l.onchainLessBoards('y', BigInt.from(500)), BigInt.from(500));
  });
}
