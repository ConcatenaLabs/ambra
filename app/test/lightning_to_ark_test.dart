// What of a channel's BTC a wallet made before the ark moves there: all of it less the route's fee.
import 'package:ambra/src/data/lightning_to_ark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all of it less 1% and 10 sats; nothing below the least worth moving', () {
    expect(LightningToArk.amountToMove(BigInt.from(100000)), BigInt.from(98990));
    expect(LightningToArk.amountToMove(BigInt.from(5000)), isNull);
    expect(LightningToArk.amountToMove(BigInt.from(5200)), BigInt.from(5138));
    expect(LightningToArk.amountToMove(BigInt.zero), isNull);
  });
}
