import 'package:ambra/src/data/dev_mode.dart';
import 'package:ambra/src/data/portfolio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const x = '75757575757575757575757575757575757575757575757575757575757575ff';
const y = '7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f00';
const phraseA = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const phraseB = 'legal winner thank year wave sausage worth useful legal winner thank yellow';

void main() {
  test('each figure is every rail of the asset together, an asset on one rail only included', () {
    final f = {
      for (final a in assetFigures(
        onchain: {x: BigInt.from(100)},
        leaves: {x: BigInt.from(20), y: BigInt.from(5)},
        lightning: {x: BigInt.from(3), y: BigInt.zero},
      ))
        a.id: a
    };
    expect(f[x]!.total, BigInt.from(123));
    expect((f[x]!.onchain, f[x]!.leaves, f[x]!.lightning), (BigInt.from(100), BigInt.from(20), BigInt.from(3)));
    expect(f[y]!.total, BigInt.from(5), reason: 'an asset held only as leaves has its figure');
  });

  test('the Sequence token\'s figure counts what is staked, and the split names only the parts held', () {
    final f = assetFigures(
      onchain: {x: BigInt.from(100)},
      lightning: {x: BigInt.from(7)},
      staked: {y: BigInt.from(40000)},
    );
    final byId = {for (final a in f) a.id: a};
    expect(byId[y]!.total, BigInt.from(40000), reason: 'all of it staked: the asset still has its figure');
    expect(byId[x]!.total, BigInt.from(107));
    expect(splitParts(byId[x]!), [('On-chain', BigInt.from(100)), ('Lightning', BigInt.from(7))]);
    expect(splitParts(byId[y]!), [('Staked', BigInt.from(40000))]);
    expect(
        splitParts(AssetFigure(
            id: x, onchain: BigInt.one, leaves: BigInt.two, lightning: BigInt.from(3), staked: BigInt.from(4))),
        [('On-chain', BigInt.one), ('Off-chain', BigInt.two), ('Lightning', BigInt.from(3)), ('Staked', BigInt.from(4))]);
  });

  test('the headline sums every holding at its value, every asset alike, and is null when nothing is priced', () {
    final prices = {'BTC': 2.0, x: 0.5};
    double? value(String k, BigInt a) => prices[k] == null ? null : prices[k]! * a.toDouble();
    expect(
        headlineTotal([(key: 'BTC', atoms: BigInt.from(10)), (key: x, atoms: BigInt.from(123)), (key: y, atoms: BigInt.from(5))], value),
        20.0 + 61.5);
    expect(headlineTotal([(key: y, atoms: BigInt.from(5))], value), isNull);
    expect(headlineTotal([(key: x, atoms: BigInt.zero)], value), isNull);
  });

  test('the mode is user by default and kept for each wallet', () async {
    SharedPreferences.setMockInitialValues({});
    final m = DevMode.instance;
    await m.load();
    expect(m.mode, 'user');
    await m.set(true);
    expect(m.on, isFalse, reason: 'no wallet open, nothing to keep it for');
    await m.loadFor(phraseA);
    expect(m.mode, 'user');
    await m.set(true);
    expect(m.mode, 'developer');
    await m.loadFor(phraseB);
    expect(m.mode, 'user', reason: 'another wallet keeps its own mode');
    await m.loadFor(phraseA);
    expect(m.mode, 'developer');
  });

  test('the one setting kept before becomes the first wallet\'s that loads, once', () async {
    SharedPreferences.setMockInitialValues({'ambra.developer_mode': true});
    final m = DevMode.instance;
    await m.loadFor(phraseB);
    expect(m.mode, 'developer');
    await m.loadFor(phraseA);
    expect(m.mode, 'user');
    final p = await SharedPreferences.getInstance();
    expect(p.getBool('ambra.developer_mode'), isNull);
  });

  test('the mode\'s words are the ones every Sequentia wallet uses', () {
    expect(ModeWords.userLine, 'One figure per asset, and the wallet chooses how value moves.');
    expect(ModeWords.developerLine,
        'Every rail by name, side by side (on-chain, leaves and Lightning), each with its balance and its manual controls, and the developer tools.');
    expect(ModeWords.note, 'Kept for this wallet. Sites that ask the wallet for its mode follow it.');
  });
}
