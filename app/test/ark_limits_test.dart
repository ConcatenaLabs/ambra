// The Bitcoin ark's limits are the server's own, read from its info: a board is cut to its largest
// coin, none is made below its least board or before its info is read, and a Lightning move into
// the ark is held to the largest coin too. The figures are Second's mainnet server's.
//
// What default mode keeps in the Bitcoin ark, in USD (ark_limits.dart, the web wallet's
// ark-limits.js and the cases of its ark-limits.test.mjs): it rests at 1500, refilled from the
// wallet's own address only below a quarter of it; payments received take it up to 3000, and then
// all above 1500 moves to the address in one move. One payment of 1500 or more goes to the address
// straight away. Sequentia's Ark has no figures.
import 'package:ambra/src/data/ark_btc_service.dart';
import 'package:ambra/src/data/ark_limits.dart';
import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/lightning_to_ark.dart';
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;
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

  group('the band (ark-limits.test.mjs)', () {
    test('the limits: 1500, 3000 and 1500 USD of BTC; none for Sequentia\'s assets', () {
      const btc = ArkFigures(board: 1500, hold: 3000, direct: 1500);
      const none = ArkFigures(board: null, hold: null, direct: null);
      expect(kArkLimits, const ArkLimits(btc: btc, asset: none));
      expect(arkLimits(null), const ArkLimits(btc: btc, asset: none));
      expect(kRefillBelow, 0.25);
      expect(arkLimits({'btc': {'board': 300}}).btc, const ArkFigures(board: 300, hold: 3000, direct: 1500),
          reason: 'a figure left out keeps its default');
      expect(arkLimits({'btc': {'board': null, 'hold': null, 'direct': null}}).btc, none, reason: 'null: no limit');
      expect(arkLimits({'btc': {'board': 'x', 'hold': -1}}).btc, btc, reason: 'a figure that is not one keeps its default');
      expect(arkLimits({'btc': {'board': 8000, 'hold': 6000}}).btc, const ArkFigures(board: 8000, hold: 8000, direct: 1500),
          reason: 'hold is never under board');
      expect(arkLimitsNow(), kArkLimits, reason: 'a test build sets no figures of its own');
    });

    test('USD in atoms', () {
      expect(usdAtoms(1000, 100000, 8), b(1000000), reason: '1000 USD of BTC at 100000: 0.01 BTC');
      expect(usdAtoms(5000, 1, 2), b(500000), reason: '5000 USD of a dollar token with 2 decimals');
      expect(usdAtoms(10000, 0.5, 0), b(20000));
      expect(usdAtoms(1000, 0, 8), isNull, reason: 'no price, no figure');
      expect(usdAtoms(1000, null, 8), isNull);
    });

    test('the wallet refills the ark only below a quarter of its resting level, in one move', () {
      BigInt? btc(int held) => boardRoom(held: b(held), limitUsd: kArkLimits.btc.board, price: 100000, precision: 8);
      expect(btc(0), b(1500000), reason: 'an empty ark takes 1500 USD of the address\'s BTC');
      expect(btc(374000), b(1126000), reason: 'under 375 USD: back up to 1500 in one move');
      expect(btc(375000), BigInt.zero, reason: 'from 375 USD on, nothing is moved in');
      expect(btc(1000000), BigInt.zero);
      expect(btc(2000000), BigInt.zero);
      expect(boardRoom(held: BigInt.zero, limitUsd: kArkLimits.asset.board, price: 1, precision: 2), isNull,
          reason: 'Sequentia: no limit');
      expect(boardRoom(held: BigInt.zero, limitUsd: 5000, price: null, precision: 2), isNull,
          reason: 'an unpriced kind has no limit');
    });

    test('at the ceiling everything above the resting level moves out, in one move', () {
      final l = kArkLimits.btc;
      BigInt btc(BigInt held) => moveOutAtoms(held: held, board: l.board, hold: l.hold, price: 100000, precision: 8);
      expect(btc(b(2999999)), BigInt.zero, reason: 'under 3000 USD it all stays');
      expect(btc(b(3000000)), b(1500000), reason: 'at 3000 USD, 1500 moves: the ark is back at 1500');
      expect(btc(b(4400000)), b(2900000), reason: 'all above 1500, in one move');
      final a = kArkLimits.asset;
      expect(moveOutAtoms(held: BigInt.from(9).pow(20), board: a.board, hold: a.hold, price: 1, precision: 2), BigInt.zero,
          reason: 'Sequentia: nothing moves out');
      expect(moveOutAtoms(held: BigInt.from(9).pow(20), board: 1500, hold: 3000, price: null, precision: 8), BigInt.zero,
          reason: 'no price, no move');
    });

    test('one BTC payment of 1500 USD or more goes to the address straight away; none on Sequentia', () {
      expect(directUsd(kArkLimits.btc), 1500);
      expect(directUsd(kArkLimits.asset), isNull);
      bool btc(int atoms) => goesToAddress(atoms: b(atoms), direct: kArkLimits.btc.direct, price: 100000, precision: 8);
      expect(btc(1499999), isFalse, reason: 'under 1500 USD: the ark');
      expect(btc(1500000), isTrue, reason: '1500 USD: the address');
      expect(goesToAddress(atoms: BigInt.from(9).pow(20), direct: kArkLimits.asset.direct, price: 1, precision: 2), isFalse,
          reason: 'Sequentia: never');
      final w = DefaultWords.byAddressLarge(usdFigure(1500));
      expect(w, 'A payment of 1,500 USD or more goes to the address.');
      expect(forbiddenIn(w), isEmpty);
      expect(usdFigure(15), '15');
      expect(usdFigure(0.5), '0.5');
    });

    test('a BTC board carries no more than the band leaves room for, nor less than the least board', () {
      // ArkBtcService.boardPlan with a cap: the web wallet's boardAmount(utxos, info, 0n, 2, cap).
      BigInt? plan(int have, int? cap) =>
          ArkBtcService.boardPlan(have: b(have), fee: b(244), min: b(10000), max: b(5000000), cap: cap == null ? null : b(cap));
      expect(plan(3000000, null), b(3000000 - 244), reason: 'no cap: the coins less the fee');
      expect(plan(3000000, 1000000), b(1000000));
      expect(plan(3000000, 5000), isNull, reason: 'a cap under the least board boards nothing');
      expect(plan(3000000, 0), isNull, reason: 'no room: nothing');
    });
  });
}
