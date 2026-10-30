// Payments in History the moment they move: a send recorded as it leaves (pending until its
// block), BTC arriving read from the network's view of the wallet's latest addresses.
import 'package:ambra/src/data/wallet_cache.dart';
import 'package:ambra/src/screens/history_screen.dart' show incomingBtc;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const mine = {'tb1qmine0', 'tb1qmine1'};

  test('BTC paid to the wallet is a received row, pending until its block', () {
    final rows = incomingBtc([
      {
        'txid': 'aa',
        'vin': [
          {'prevout': {'scriptpubkey_address': 'tb1qsomeoneelse', 'value': 90000}}
        ],
        'vout': [
          {'scriptpubkey_address': 'tb1qmine1', 'value': 50000},
          {'scriptpubkey_address': 'tb1qchange', 'value': 39000},
        ],
        'status': {'confirmed': false},
      },
      {
        'txid': 'bb',
        'vin': [
          {'prevout': {'scriptpubkey_address': 'tb1qx', 'value': 30000}}
        ],
        'vout': [
          {'scriptpubkey_address': 'tb1qmine0', 'value': 20000},
        ],
        'status': {'confirmed': true, 'block_time': 1790000000},
      },
      // The wallet's own send (it spends a coin of the wallet's): recorded when it left, not here.
      {
        'txid': 'cc',
        'vin': [
          {'prevout': {'scriptpubkey_address': 'tb1qmine0', 'value': 20000}}
        ],
        'vout': [
          {'scriptpubkey_address': 'tb1qmine1', 'value': 1000},
          {'scriptpubkey_address': 'tb1qthem', 'value': 18000},
        ],
        'status': {'confirmed': false},
      },
    ], mine);
    expect(rows.map((r) => r['txid']), ['aa', 'bb']);
    expect(rows[0]['atoms'], '50000');
    expect(rows[0]['pending'], isTrue);
    expect(rows[0]['kind'], 'received');
    expect(rows[1]['pending'], isFalse);
    expect(rows[1]['time'], 1790000000 * 1000);
    expect(incomingBtc('not a list', mine), isEmpty);
  });

  test('a send is recorded once as it leaves, and settled when its block comes', () async {
    SharedPreferences.setMockInitialValues({});
    await WalletCache.addPayment({'kind': 'payment', 'ticker': 'BTC', 'atoms': '1000', 'precision': 8, 'rail': 'btc', 'pending': true, 'txid': 't1', 'chain': 'btc'});
    await WalletCache.addPayment({'kind': 'payment', 'ticker': 'BTC', 'atoms': '1000', 'precision': 8, 'rail': 'btc', 'pending': true, 'txid': 't1', 'chain': 'btc'});
    await WalletCache.addPayment({'kind': 'payment', 'ticker': 'USDX', 'atoms': '5', 'precision': 8, 'rail': 'tree', 'pending': false});
    var h = await WalletCache.loadLnHistory();
    expect(h.length, 2);
    expect(h.first['pending'], isTrue);
    expect(h.first['time'], isA<int>());
    await WalletCache.settlePayment('t1');
    h = await WalletCache.loadLnHistory();
    expect(h.first['pending'], isFalse);
  });

  test('the receive code shown is kept across opens until it is replaced', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await WalletCache.loadReceiveCode(), isNull);
    await WalletCache.saveReceiveCode({'address': 'tb1qa', 'ark': 'tark1x', 'sequentia': 'arca:00', 'until': 1800000000});
    final k = await WalletCache.loadReceiveCode();
    expect(k!['address'], 'tb1qa');
    expect(k['until'], 1800000000);
    await WalletCache.clear();
    expect(await WalletCache.loadReceiveCode(), isNull);
  });
}
