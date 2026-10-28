// A wallet removed from the phone leaves nothing of itself behind: the next wallet (a new
// one, or another phrase restored) lists only what it holds, so a brand-new wallet lists
// BTC alone.
import 'package:ambra/src/data/ark_btc_service.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forget clears what was read of the removed wallet', () async {
    final l = LeafService.instance;
    l.joined = true;
    l.balance = {
      'held': {'aa': '980', 'bb': '22'},
      'arca': {
        'aa': {'pending': '5'}
      },
      'sequentia_onchain': {},
    };
    l.coins = [
      {'leaf_id': 'x', 'asset': 'aa', 'state': 'live'}
    ];
    l.schedule = {
      'pending_coins': [
        {'asset': 'cc', 'value': '7'}
      ]
    };
    expect(l.leafAtoms(), isNotEmpty);
    expect(l.arrivingAtoms(), isNotEmpty);

    await l.forget();

    expect(l.joined, isFalse);
    expect(l.open, isFalse);
    expect(l.leafAtoms(), isEmpty);
    expect(l.arrivingAtoms(), isEmpty);
    expect(l.coins, isEmpty);
  });

  test('the Bitcoin ark wallet stopped holds nothing', () {
    final a = ArkBtcService.instance;
    a.balance = {'spendable': '189188', 'pending_board': '0'};
    expect(a.held, BigInt.from(189188));
    a.stop();
    expect(a.open, isFalse);
    expect(a.held, BigInt.zero);
    expect(a.spendable, BigInt.zero);
  });
}
