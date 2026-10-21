// Covenant terms name asset A in the byte order the leaf baked: internal
// (reversed) for current covenants, display for older ones. covenantLocks takes
// either, so the SBTC checks recognise a current covenant.
//
//   cd app && flutter test test/covenant_terms_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ambra/src/data/seqob_client.dart';

const usdx = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de';
const usdxInternal = 'deb9044d8fa54b848820dd7d71150dc1c0ba65cd6e76a7ca606a5eda3955512a';
const eurx = 'e39685e718516156679088d9400d11a1eb82bf7cc27c5b9f5a614b8c91246d13';

void main() {
  test('revHex reverses the bytes and is its own inverse', () {
    expect(revHex(usdx), usdxInternal);
    expect(revHex(revHex(eurx)), eurx);
  });
  test('a covenant locking the asset in either byte order is recognised', () {
    expect(covenantLocks({'asset_a': usdxInternal}, usdx), isTrue);
    expect(covenantLocks({'assetA': usdx.toUpperCase()}, usdx), isTrue);
  });
  test('another asset, no terms, or no id is not', () {
    expect(covenantLocks({'asset_a': revHex(eurx)}, usdx), isFalse);
    expect(covenantLocks(null, usdx), isFalse);
    expect(covenantLocks({'asset_a': usdxInternal}, ''), isFalse);
  });

  group('resolveCovenantVout', () {
    final body = jsonEncode({
      'vout': [
        {'scriptpubkey': '0014aa'},
        {'scriptpubkey': '5120bb'},
      ]
    });

    test('waits out the 404 of a transaction esplora has not indexed yet', () async {
      var calls = 0;
      final vout = await resolveCovenantVout('t', '5120BB', wait: Duration.zero, get: (_) async {
        calls++;
        return calls < 3 ? http.Response('Transaction not found', 404) : http.Response(body, 200);
      });
      expect(vout, 1);
      expect(calls, 3);
    });

    test('gives up after its tries, and at once on any other error', () async {
      var calls = 0;
      await expectLater(
          resolveCovenantVout('t', '5120bb', tries: 4, wait: Duration.zero, get: (_) async {
            calls++;
            return http.Response('', 404);
          }),
          throwsA(predicate((e) => '$e'.contains('returned 404'))));
      expect(calls, 4);
      calls = 0;
      await expectLater(
          resolveCovenantVout('t', '5120bb', wait: Duration.zero, get: (_) async {
            calls++;
            return http.Response('', 500);
          }),
          throwsA(predicate((e) => '$e'.contains('returned 500'))));
      expect(calls, 1);
    });

    test('a transaction without the covenant output is refused', () async {
      await expectLater(resolveCovenantVout('t', '5120cc', get: (_) async => http.Response(body, 200)),
          throwsA(predicate((e) => '$e'.contains('not found'))));
    });
  });
}
