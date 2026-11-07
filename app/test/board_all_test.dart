// The automatic board of everything held less its own fee, against a library that prices a
// board's coins at a size before it knows the real one (wallet.rs board_tx: value plus the fee of
// 300 vB must be held, then the real fee of the smaller transaction is charged).
import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/stake_words.dart';
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

  test('a coin that reaches the address after a board never vanishes from the figure (sequentia-web-wallet#574)', () {
    final l = LeafService.instance;
    final at = DateTime.now().subtract(const Duration(seconds: 30));
    // 1 OILX boarded whole, fee included; a second 1 OILX reaches the address, and a scan begun
    // after the board holds the board's spend and the new coin at once.
    final one = BigInt.from(100000000);
    l.debugBoarded('z', spent: one, held: one, at: at);
    expect(l.onchainLessBoards('z', one, readFrom: at.add(const Duration(seconds: 5))), one);
    // A scan begun before the board, holding the board's coin and the new one: the new one stays.
    l.debugBoarded('z', spent: one, held: one, at: at);
    expect(l.onchainLessBoards('z', one * BigInt.two, readFrom: at.subtract(const Duration(seconds: 5))), one);
    // One that has not seen the boarded coin yet takes nothing off for it: the leaf counts it.
    expect(l.onchainLessBoards('z', BigInt.zero, readFrom: at.subtract(const Duration(seconds: 5))), BigInt.zero);
    // Other coins the library had not read when it boarded stay counted.
    l.debugBoarded('z', spent: BigInt.from(1000), held: BigInt.from(1000), at: at);
    expect(l.onchainLessBoards('z', BigInt.from(1500), readFrom: at.subtract(const Duration(seconds: 5))), BigInt.from(500));
  });

  test('a payment to an address states the most the whole way to the other wallet takes, not the settlement alone', () {
    expect(addressArrivalMinutes(60, 60), 10);
    expect(addressArrivalMinutes(60, null), 10);
    expect(addressArrivalMinutes(600, 60), 20);
    expect(addressArrivalMinutes(60, 600), 45);
    expect(addressArrivalMinutes(null, 60), isNull);
    expect(addressArrivalMinutes(0, 60), isNull);
    // Every payment measured on the testnet (189 to 356 s from Send) is within what is stated.
    for (final s in [189, 223, 231, 313, 317, 340, 356]) {
      expect(s <= addressArrivalMinutes(60, 60)! * 60, isTrue);
    }
    expect(DefaultWords.arrivesIn(addressArrivalMinutes(60, 60)), 'It arrives within 10 minutes.');
    expect(DefaultWords.arrivesIn(null), 'It arrives shortly.');
    expect(StakeWords.movingOut('1 tSEQ', 'staked', 10), 'Moving 1 tSEQ out of the Ark so it can be staked. They are ready within 10 minutes. Keep this screen open.');
  });

  test('the same payment to an address asked again while the first is on its way is never said to be sent twice', () {
    expect(offboardAlready({'offboard': 'ab', 'state': 'pending', 'already': true}), isTrue);
    expect(offboardAlready({'offboard': 'ab', 'state': 'pending'}), isFalse);
    expect(offboardAlready(null), isFalse);
    expect(DefaultWords.sentAlready('1', 'OILX', '${DefaultWords.arrivesIn(10)} ${DefaultWords.keepOpen}'),
        '1 OILX to this address is already on its way, so nothing more was sent. It arrives within 10 minutes. Keep this screen open meanwhile. To pay the same again, send once it has arrived.');
    expect(DefaultWords.sentThen('1', 'OILX', '${DefaultWords.arrivesIn(10)} ${DefaultWords.keepOpen}'),
        'Sent 1 OILX. It arrives within 10 minutes. Keep this screen open meanwhile.');
  });
}
