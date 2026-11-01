import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/portfolio.dart';
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;
import 'package:ambra/src/data/vesting.dart';
import 'package:flutter_test/flutter_test.dart';

final a = 'aa' * 32, b = 'bb' * 32;

// 3 November 2026 12:00 UTC, and the same day later on; 1 December 2026.
const nov3 = 1793707200, nov3late = 1793743200, dec1 = 1796126400;

Map<String, dynamic> claim(String asset, int value, int vest, {String state = 'vesting', String? held, bool words = true}) => {
      'distribution': 'd1', 'index': 0, 'key': 'k', 'address': null, 'named_as': 'openamp',
      'asset': asset, 'value': value, 'state': state, 'leaf_id': 'l', 'deadline': vest + 604800,
      'expiry': null, 'held': held, 'vest': vest, 'vests': words ? dateWords(vest) : null, 'note': 'n',
    };

void main() {
  test('the date in words is the library\'s', () {
    expect(dateWords(nov3), '3 November 2026');
    expect(dateWords(dec1), '1 December 2026');
  });

  test('claims become one line for each asset and day, earliest first, held and other states left out', () {
    final lots = vestingLots([
      claim(a, 30000000000, dec1),
      claim(a, 10000000000, nov3late),
      claim(a, 5000000000, nov3, words: false),
      claim(b, 7, nov3),
      claim(a, 99, nov3, state: 'open'),
      claim(a, 99, nov3, held: 'leaf'),
      {'state': 'vesting', 'vest': nov3}, // no asset or value
      'not a claim',
    ]);
    expect(lots.map((l) => '${l.asset == a ? 'A' : 'B'} ${l.atoms} ${l.vests} ${l.vest}'), [
      'A 15000000000 3 November 2026 $nov3',
      'B 7 3 November 2026 $nov3',
      'A 30000000000 1 December 2026 $dec1',
    ]);
    expect(vestingAtomsOf(lots), {a: BigInt.from(45000000000), b: BigInt.from(7)});
    expect(vestingLots(null), isEmpty);
    expect(vestingLots({'error': 'x'}), isEmpty);
  });

  test('the figure counts what vests; what can be spent does not', () {
    final lots = vestingLots([claim(a, 100, nov3)]);
    final f = assetFigures(onchain: const {}, leaves: {a: BigInt.from(5)}, vesting: vestingAtomsOf(lots));
    expect(f.single.total, BigInt.from(105));
    // An asset held only this way still has its figure.
    final only = assetFigures(onchain: const {}, vesting: vestingAtomsOf(lots));
    expect(only.single.id, a);
    expect(only.single.total, BigInt.from(100));
    // Default mode's details name only Staked from the parts; developer mode names the claims too.
    expect(splitParts(only.single, dev: false), isEmpty);
    expect(splitParts(only.single), [('Vesting', BigInt.from(100))]);
  });

  test('an amount that needs what has not vested says from when, with the earliest date that covers it', () {
    final lots = vestingLots([claim(a, 10000000000, nov3), claim(a, 30000000000, dec1)]);
    // Within what can be spent: no sentence.
    expect(vestingShort(lots, a, BigInt.from(500), BigInt.from(500)), isNull);
    // Needs the first date's.
    final s1 = vestingShort(lots, a, BigInt.from(10000000500), BigInt.from(500))!;
    expect(s1.atoms, BigInt.from(10000000000));
    expect(s1.vests, '3 November 2026');
    // Needs the second date's.
    expect(vestingShort(lots, a, BigInt.from(10000000501), BigInt.from(500))!.vests, '1 December 2026');
    // More than everything: the action's own refusal.
    expect(vestingShort(lots, a, BigInt.from(40000000501), BigInt.from(500)), isNull);
    // Another asset vests nothing.
    expect(vestingShort(lots, b, BigInt.from(1), BigInt.zero), isNull);
    expect(notVestedSentence(lots, a, BigInt.from(10000000000), BigInt.zero, ticker: 'ORNG', precision: 8),
        '100 ORNG of this vests on 3 November 2026, and can be used from then. Nothing has moved.');
  });

  test('the sentences are the contract\'s', () {
    expect(DefaultWords.vests('100', 'ORNG', '3 November 2026'), '100 ORNG vests on 3 November 2026');
    expect(DefaultWords.vestsOn('3 November 2026'), 'Vests on 3 November 2026');
  });

  test('the operator\'s vesting refusal is said plainly, and nothing else is', () {
    expect(vestingRefusal('vesting', 'leaf 0a:1 vests at median time $nov3: nothing moves it before then'),
        'Part of this vests on 3 November 2026, and can be used from then. Nothing has moved.');
    expect(vestingRefusal('vesting', 'something else'), DefaultWords.notVestedYet);
    expect(vestingRefusal('value', 'median time $nov3'), isNull);
    final plain = plainRefusal(LeafRefusal('refused', 'leaf x vests at median time $nov3: nothing moves it before then', code: 'vesting'));
    expect(plain.plain, isTrue);
    expect(plain.message, 'Part of this vests on 3 November 2026, and can be used from then. Nothing has moved.');
  });

  test('a claim past its date and not taken up asks for care at once', () {
    expect(vestedOpen([claim(a, 1, nov3, state: 'open')]), isTrue);
    expect(vestedOpen([claim(a, 1, nov3, state: 'open', held: 'leaf')]), isFalse);
    expect(vestedOpen([claim(a, 1, nov3)]), isFalse);
    expect(vestedOpen([{'state': 'open', 'held': null, 'vest': null}]), isFalse);
  });

  test('no vesting sentence says a forbidden word', () {
    for (final s in [
      DefaultWords.vests('100', 'ORNG', '3 November 2026'),
      DefaultWords.vestsOn('3 November 2026'),
      DefaultWords.notVested('100', 'ORNG', '3 November 2026'),
      DefaultWords.vestingRefused('3 November 2026'),
      DefaultWords.notVestedYet,
    ]) {
      expect(forbiddenIn(s), isEmpty, reason: s);
    }
    expect(forbiddenIn('Your claim from the distribution'), ['claim', 'distribution']);
    expect(forbiddenIn('It lapses after the locktime'), ['lapses', 'locktime']);
  });
}
