// The Stake screen's default-mode words (data/stake_words.dart): none of the words default mode
// never shows, and the pool board read in plain words (#169).
import 'package:ambra/src/data/stake_words.dart';
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no string the Stake screen shows in default mode names a protocol or developer word', () {
    for (final w in StakeWords.all()) {
      expect(forbiddenIn(w), isEmpty, reason: w);
      for (final t in ['unbond', 'signer', 'delegat', 'record', 'staker key', 'bond ']) {
        expect(w.toLowerCase().contains(t), isFalse, reason: '"$t" in: $w');
      }
    }
  });

  test('each pool says whether it is producing, in the pool board\'s verdicts', () {
    expect(poolVerdict(reliability: 1.2, eligible: true, weight: BigInt.one), StakeWords.producing);
    expect(poolVerdict(reliability: 0.7, eligible: true, weight: BigInt.one), StakeWords.missingSome);
    expect(poolVerdict(reliability: 0.087, eligible: true, weight: BigInt.one), StakeWords.mostlyOffline);
    expect(poolVerdict(reliability: 0, eligible: true, weight: BigInt.one), StakeWords.notProducing);
    expect(poolVerdict(reliability: null, eligible: true, weight: BigInt.one), StakeWords.notProducing);
    expect(poolVerdict(reliability: 2, eligible: false, weight: BigInt.one), StakeWords.tooSmall);
  });

  test('what a pool pays, from the live board\'s own sentences, in plain words', () {
    // The board's sentences as sequentiatestnet.com/pools/pools.json serves them.
    const split = 'pays every delegator its exact proportional share (split): rewards pool up on-chain and anyone may '
        'trigger the payout, operator commission 5.00%. The proportional payout most delegators expect';
    const lottery = "pays one delegator per block, drawn by stake weight from Bitcoin's proof of work (lottery), operator "
        'commission 5.00%. Each delegator earns its exact share over time, in rare lumps rather than smoothly';
    const none = 'no policy committed: this pool keeps everything the blocks it produces earn';
    expect(poolPayout(split), 'Pays each member its share of every block, less a 5% commission.');
    expect(poolPayout(lottery), 'Pays one member per block, drawn by stake: your share over time, in occasional lumps, less a 5% commission.');
    expect(poolPayout(none), StakeWords.payKeepsAll());
    for (final b in [split, lottery, none]) {
      expect(forbiddenIn(poolPayout(b)), isEmpty);
    }
    expect(poolShare(BigInt.from(9000000000000), BigInt.from(393499999990000)), '2.2% of all stake');
    expect(poolShare(BigInt.one, BigInt.from(393499999990000)), 'under 0.1% of all stake');
  });
}
