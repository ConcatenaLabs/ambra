// The Bitcoin ark's limits are the server's own, read from its info: a board is cut to its largest
// coin, none is made below its least board or before its info is read, and a Lightning move into
// the ark is held to the largest coin too. The figures are Second's mainnet server's.
import 'package:ambra/src/data/ark_btc_service.dart';
import 'package:ambra/src/data/lightning_to_ark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final s = ArkBtcService.instance;
  BigInt b(int v) => BigInt.from(v);

  test('before the server\'s info is read: no limits, no board', () {
    s.balance = {'spendable': '0'};
    expect(s.limitsRead, isFalse);
    expect(s.minBoard, isNull);
    expect(s.maxBoard, isNull);
    expect(ArkBtcService.boardPlan(have: b(30000000), fee: b(300), min: s.minBoard, max: s.maxBoard), isNull);
  });

  test('Second\'s figures: a board above the largest coin is cut to it, one below the least is not made', () {
    s.balance = {'spendable': '0', 'max_board': '10000000', 'min_board': '50000', 'board_confirmations': 2};
    expect(s.limitsRead, isTrue);
    expect(s.maxBoard, b(10000000));
    expect(s.minBoard, b(51000));
    expect(s.boardConfirmations, 2);
    BigInt? plan(int have) => ArkBtcService.boardPlan(have: b(have), fee: b(300), min: s.minBoard, max: s.maxBoard);
    // 0.3 BTC at the address: a board of 0.1 BTC, the rest left for later boards.
    expect(plan(30000000), b(10000000));
    expect(plan(10000300), b(10000000));
    expect(plan(2000000), b(1999700));
    // 40,000 sat, and anything short of the least board with the margin, is not boarded.
    expect(plan(40000), isNull);
    expect(plan(51299), isNull);
    expect(plan(51300), b(51000));
  });

  test('a server that names no largest coin: everything less the fee', () {
    s.balance = {'spendable': '0', 'max_board': null, 'min_board': '50000'};
    expect(s.maxBoard, isNull);
    expect(ArkBtcService.boardPlan(have: b(30000000), fee: b(300), min: s.minBoard, max: s.maxBoard), b(29999700));
  });

  test('a Lightning move into the ark is held to its largest coin', () {
    expect(LightningToArk.withinArk(b(30000000), b(10000000)), b(10000000));
    expect(LightningToArk.withinArk(b(98990), b(10000000)), b(98990));
    expect(LightningToArk.withinArk(b(30000000), null), b(30000000));
    expect(LightningToArk.withinArk(null, b(10000000)), isNull);
  });
}
