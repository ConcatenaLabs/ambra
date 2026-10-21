import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/screens/history_screen.dart';
import 'package:flutter_test/flutter_test.dart';

const usdx = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de';
const eurx = 'e39685e718516156679088d9400d11a1eb82bf7cc27c5b9f5a614b8c91246d13';

void main() {
  test('a covenant fill shows both legs, paid then received', () {
    // A fill: 0.2 USDX in, 0.18 EURX out, the fee in EURX.
    final line = swapLine([
      core.AssetDelta(assetId: eurx, atoms: '-18001336'),
      core.AssetDelta(assetId: usdx, atoms: '20000000'),
    ]);
    expect(line, '-0.18001336 EURX → +0.2 USDX');
  });

  test('a one-sided movement is not a swap line', () {
    expect(swapLine([core.AssetDelta(assetId: usdx, atoms: '5')]), isNull);
  });
}
