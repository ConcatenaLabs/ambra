import 'package:ambra/src/data/stakes.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/screens/stake_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

core.StakeEntry entry({
  String txid = '',
  String state = 'bonded',
  String lock = 'height',
  int? height = 100,
  int? maturesAtHeight,
  int? maturesAtTime,
  int? claimableAtAnchor,
  int? tipAnchor,
}) =>
    core.StakeEntry(
      txid: txid.isEmpty ? 'ab' * 32 : txid,
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

  testWidgets('the stake list offers Unbond once a lock has passed and Return once unbonding is over', (tester) async {
    StakeHoldings.instance.debugSet([
      entry(txid: '11' * 32, maturesAtHeight: 43300),
      entry(txid: '22' * 32, lock: 'time', state: 'unbondable'),
      entry(txid: '33' * 32, lock: '', state: 'claimable'),
    ]);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: StakesSection(autoLoad: false)))));
    expect(find.text('Your stakes'), findsOneWidget);
    expect(find.text('Unbond'), findsOneWidget);
    expect(find.text('Return to wallet'), findsOneWidget);
    expect(find.textContaining('Locked until block 43300'), findsOneWidget);
    expect(find.text('Unlocked: you can unbond it'), findsOneWidget);
    expect(find.text('Unbonded: ready to return to your wallet'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('40') && (w.data ?? '').endsWith(' tSEQ')),
        findsNWidgets(3));
    StakeHoldings.instance.clear();
  });
}
