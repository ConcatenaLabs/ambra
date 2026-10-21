import 'dart:convert';

import 'package:ambra/src/data/drip_rate.dart';
import 'package:flutter_test/flutter_test.dart';

const tseq = 'c8eccacf0953e1931cd31e434d8319101cc36e6c38b0e2104d8687552fae3e40';
String internal(String display) =>
    [for (var i = 0; i < 64; i += 2) display.substring(i, i + 2)].reversed.join();

String ask({int? rate}) => jsonEncode({
      'templateHash': '12986f202fbfb850f7699c5d5188f261f276de6c7038142f0a28bbb672b5af34',
      'instance': {'params': {'ASSET': internal(tseq)}},
      'drip': {'coin': {'txid': 'aa', 'vout': 0}, 'amount': 200000000, 'ratePerKvb': ?rate},
    });

void main() {
  test('the drip asset is read from the instance in display order', () {
    expect(dripAsset(jsonDecode(ask()) as Map), tseq);
  });

  test('a tSEQ drip at the node rate: 2,000 reference atoms a kvB is 5,538 tSEQ atoms at a rate of 36,120,000', () {
    // tSEQ at 0.3612 reference units: rate 36,120,000. ceil(2000e8 / 36,120,000) = 5,538.
    final out = jsonDecode(dripAskAtNodeRate(ask(), {'bitcoin': BigInt.from(36120000)})) as Map;
    expect(out['drip']['ratePerKvb'], 5538);
  });

  test('a dollar asset at rate 1e8 pays the reference rate itself', () {
    final usdx = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de';
    final a = jsonEncode({
      'instance': {'params': {'ASSET': internal(usdx)}},
      'drip': {'amount': 1},
    });
    final out = jsonDecode(dripAskAtNodeRate(a, {usdx: BigInt.from(100000000)})) as Map;
    expect(out['drip']['ratePerKvb'], 2000);
  });

  test('a rate the ask names stands, and a request that is not a drip is unchanged', () {
    expect(dripAskAtNodeRate(ask(rate: 6000), {}), ask(rate: 6000));
    const plain = '{"templateHash":"x","instance":{},"request":{}}';
    expect(dripAskAtNodeRate(plain, {}), plain);
  });

  test('an asset the node does not price cannot pay a drip fee', () {
    expect(() => dripAskAtNodeRate(ask(), {}), throwsA(contains('does not price')));
  });
}
