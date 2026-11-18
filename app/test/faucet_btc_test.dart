// The faucet pays BTC on the Bitcoin ark when the wallet gives it a receive code carrying its ark
// address, as the web wallet's requestFaucetBtc does: on the chain it pays its smallest tier, which
// can be the ark's least board, and less the board's fee that BTC could never move into the ark
// where trades and payments in seconds take BTC from.
//
//   cd app && flutter test test/faucet_btc_test.dart

import 'package:ambra/src/data/api_client.dart';
import 'package:ambra/src/data/pay_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const addr = 'tb1qxm8zewmgn4n8a9xp7s8yt3lqjdz568gtxennx8';
  const ark = 'tark1pnglpcr3qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';

  test('with an ark address: a code the faucet reads both from, the ark first', () {
    final to = faucetBtcTo(addr, ark);
    final c = PayCode.read(to)!;
    expect(c.address, addr);
    expect(c.ark, ark);
  });

  test('without one: the chain address as it is', () {
    expect(faucetBtcTo(addr, null), addr);
    expect(faucetBtcTo(addr, ''), addr);
  });
}
