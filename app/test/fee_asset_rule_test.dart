// The wallet rule for the fee asset (lib/src/data/fee_asset_rule.dart), which every
// place Ambra builds a Sequentia transaction asks:
//
//   1. the asset moved, when the node accepts it and the wallet holds a coin of it;
//   2. else the accepted asset whose largest coin covers the most fees
//      (largest coin x node rate);
//   3. else none: never a tSEQ fallback.
//
//   cd app && flutter test test/fee_asset_rule_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/config.dart';
import 'package:ambra/src/data/fee_asset_rule.dart';

const tseq = SeqAssets.policy;
const usdx = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de';
const gold = '3a0f9192219db59f8d7f87d93ac6311095dfe1255d149727b87baaa7d2cc71a1';
const oilx = '4dfe69c334a9cdf4005ddf3889bba1bc397703fa8da669254877f3209caf7c8f';
const unlisted = 'deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb';

BigInt b(num v) => BigInt.from(v);

// The live testnet feed's shape: keyed by ticker, tSEQ by its ticker too.
final feed = {'tSEQ': b(36168727), 'USDX': b(100000000), 'GOLD': b(415530000000), 'OILX': b(9725000000)};

void main() {
  group('feeRateFor', () {
    test('reads tSEQ by its ticker, or by "bitcoin" where a feed names it so', () {
      expect(feeRateFor(feed, tseq), b(36168727));
      expect(feeRateFor({'bitcoin': b(100000000)}, tseq), b(100000000));
    });
    test('an asset the feed leaves out is not accepted, tSEQ included', () {
      expect(feeRateFor(feed, unlisted), isNull);
      expect(feeRateFor({'USDX': b(100000000)}, tseq), isNull);
    });
  });

  group('walletFeeAsset', () {
    test('rule 1: the asset moved pays when the node accepts it', () {
      final coins = {usdx: b(10e8), gold: b(10e8), tseq: b(1000e8)};
      expect(walletFeeAsset(moved: usdx, rates: feed, largestCoin: coins), usdx);
      expect(walletFeeAsset(moved: tseq, rates: feed, largestCoin: coins), tseq);
    });

    test('rule 2: an unaccepted asset moved -> the largest coin by value, not tSEQ', () {
      // 1000 tSEQ ~ 361.7 reference units; 10 GOLD ~ 41,553; 10 USDX = 10.
      final coins = {unlisted: b(5e8), usdx: b(10e8), gold: b(10e8), tseq: b(1000e8)};
      expect(walletFeeAsset(moved: unlisted, rates: feed, largestCoin: coins), gold);
    });

    test('rule 2 weighs the largest single coin, not the balance or the atom count', () {
      // OILX: one coin of 3 (~291.75 ref). USDX: one coin of 200 (200 ref). tSEQ: 500 (~180.8 ref).
      final coins = {oilx: b(3e8), usdx: b(200e8), tseq: b(500e8)};
      expect(walletFeeAsset(moved: null, rates: feed, largestCoin: coins), oilx);
      // The same holdings with tSEQ's coin at 1000 (~361.7 ref): now tSEQ, by value alone.
      expect(walletFeeAsset(moved: null, rates: feed, largestCoin: {...coins, tseq: b(1000e8)}), tseq);
    });

    test('the moved asset with no coin of it held falls to rule 2', () {
      expect(walletFeeAsset(moved: usdx, rates: feed, largestCoin: {gold: b(1)}), gold);
    });

    test('an excluded asset (a covenant\'s sold asset, a whole-balance move) never pays', () {
      final coins = {usdx: b(10e8), gold: b(10e8)};
      expect(walletFeeAsset(moved: usdx, rates: feed, largestCoin: coins, exclude: {usdx}), gold);
      expect(walletFeeAsset(moved: gold, rates: feed, largestCoin: coins, exclude: {gold}), usdx);
    });

    test('rule 3: nothing accepted is held -> none; tSEQ is not invented', () {
      expect(walletFeeAsset(moved: unlisted, rates: feed, largestCoin: {unlisted: b(1e8)}), isNull);
      expect(walletFeeAsset(moved: usdx, rates: const {}, largestCoin: {usdx: b(1e8), tseq: b(1e8)}), isNull);
      // A feed that leaves tSEQ out: a wallet holding only tSEQ has no fee asset.
      expect(walletFeeAsset(moved: tseq, rates: {'USDX': b(1e8)}, largestCoin: {tseq: b(1000e8)}), isNull);
    });
  });

  group('rates in the fee asset\'s own units', () {
    test('a typed rate and the reference rate convert both ways', () {
      // 2 reference atoms/vB in tSEQ at 36,168,727: 5.53 tSEQ atoms/vB = 5.53e-8 tSEQ/vB.
      final perVb = assetRateFromReference(2, b(36168727), 8);
      expect((perVb - 5.5296e-8).abs() < 1e-11, isTrue, reason: '$perVb');
      expect((referenceKvbFromAssetRate(perVb, b(36168727), 8) - 2000).abs() < 1e-6, isTrue);
      expect(formatAssetRate(perVb), '0.0000000553');
    });
    test('a fixed reference fee in an asset\'s atoms rounds up', () {
      expect(feeAtomsIn(b(100000000), b(2000)), b(2000));
      expect(feeAtomsIn(b(36168727), b(2000)), b(5530));
      expect(feeAtomsIn(b(415530000000), b(2000)), b(1));
    });
  });
}
