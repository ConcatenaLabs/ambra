import 'package:ambra/src/data/stakes.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:flutter_test/flutter_test.dart';

core.StakeEntry entry({
  String state = 'bonded',
  String lock = 'height',
  int? height = 100,
  int? maturesAtHeight,
  int? maturesAtTime,
  int? claimableAtAnchor,
  int? tipAnchor,
}) =>
    core.StakeEntry(
      txid: 'ab' * 32,
      vout: 0,
      value: BigInt.from(4000000000000),
      lock: lock,
      state: state,
      height: height,
      maturesAtHeight: maturesAtHeight,
      maturesAtTime: maturesAtTime == null ? null : BigInt.from(maturesAtTime),
      claimableAtAnchor: claimableAtAnchor,
      tipAnchor: tipAnchor,
    );

/// The words user mode never shows (W4.4's list).
const developerWords = [
  'leaf', 'leaves', 'round', 'plan', 'claim', 'distribution', 'expiry', 'operator',
  'forfeit', 'covenant', 'anchor', 'atoms', 'unroll', 'refresh', 'csv',
];

void main() {
  final now = DateTime.utc(2026, 10, 21, 12);

  test('the Sequence token at the staking key is every stake, every unbonding output and the record', () {
    expect(stakedTotal([BigInt.from(5), BigInt.from(7)], BigInt.from(3)), BigInt.from(15));
    expect(stakedTotal(const [], null), BigInt.zero);
  });

  test('each state reads in plain words, with no developer word', () {
    final lines = [
      stakeStatusText(entry(state: 'pending', height: null), now: now),
      stakeStatusText(entry(maturesAtHeight: 43300), tip: 200, now: now),
      stakeStatusText(entry(lock: 'time', maturesAtTime: DateTime.utc(2026, 11, 4, 12).millisecondsSinceEpoch ~/ 1000), now: now),
      stakeStatusText(entry(state: 'unbondable'), now: now),
      stakeStatusText(entry(state: 'unbonding', lock: '', claimableAtAnchor: 130000, tipAnchor: 128000), now: now),
      stakeStatusText(entry(state: 'unbonding', lock: '', height: null), now: now),
      stakeStatusText(entry(state: 'claimable', lock: ''), now: now),
    ];
    expect(lines, [
      'Waiting to confirm',
      'Locked until block 43300 (about 20 Nov 2026)',
      'Locked until about 4 Nov 2026',
      'Unlocked: you can unbond it',
      'Unbonding: can return to your wallet after Bitcoin block 130000 (about 4 Nov 2026)',
      'Unbonding, waiting to confirm',
      'Unbonded: ready to return to your wallet',
    ]);
    for (final l in lines) {
      for (final w in developerWords) {
        expect(RegExp('\\b$w', caseSensitive: false).hasMatch(l), isFalse, reason: '"$l" says "$w"');
      }
    }
  });
}
