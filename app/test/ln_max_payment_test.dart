// One payment over Lightning is held to the limit the operator publishes for its node, per asset
// and direction (`max_payment` in its info: by default a tenth of what the node can carry, less what
// it keeps for swaps). The operator enforces it; the wallet reads it and pays on the chain above it.
// It holds no share of its own. An operator that publishes none: 1,500 USD a payment. The cases of
// the web wallet's ln-capacity.test.mjs, against ln_max_payment.dart.
import 'dart:convert';

import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/ln_max_payment.dart';
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;
import 'package:flutter_test/flutter_test.dart';

const usdx = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de';
// The operator's info as arcad publishes it: each node's capacity and the limit it sets from it.
final Map<String, dynamic> info = {
  'server_info': {
    'assets': [
      {
        'asset': usdx,
        'lightning': {
          'state': 'up', 'channels': 4, 'spendable': '2688516826484', 'receivable': '2254603160348',
          'max_payment': {'send': '268851682648', 'receive': '225460316034'},
          'payment_limit': {'share_ppm': 100000, 'reserve': '0'},
        },
      }
    ],
    'lightning': {
      'bitcoin': {
        'node': {
          'state': 'up', 'channels': 4, 'spendable': '208639990', 'receivable': '88526452',
          'max_payment': {'send': '10863999', 'receive': '3852645'},
          'payment_limit': {'share_ppm': 100000, 'reserve': '50000000'},
        },
      },
      'send': {'timeout_seconds': 777600},
      'receive': {'block_seconds': 60},
    },
  },
};

void main() {
  BigInt b(int v) => BigInt.from(v);
  // An operator that publishes its capacity and no limit.
  final bare = jsonDecode(jsonEncode(info)) as Map<String, dynamic>;
  ((bare['server_info']['assets'] as List)[0]['lightning'] as Map).remove('max_payment');
  (bare['server_info']['lightning']['bitcoin']['node'] as Map).remove('max_payment');

  test('the limit is the operator\'s, read per asset and direction', () {
    expect(lnMaxPayment(info, usdx, 'out'), BigInt.parse('268851682648'));
    expect(lnMaxPayment(info, usdx, 'in'), BigInt.parse('225460316034'));
    expect(lnMaxPayment(info, 'BTC', 'out'), b(10863999));
    expect(lnMaxPayment(info, 'BTC', 'in'), b(3852645));
    expect(lnMaxPayment(info, 'ff' * 32, 'out'), isNull, reason: 'no node: nothing published');
    expect(lnMaxPayment(bare, usdx, 'out'), isNull, reason: 'no limit published');
    expect(lnMaxPayment(bare, 'BTC', 'in'), isNull);
    expect(lnMaxPayment(info['server_info'] as Map, 'BTC', 'in'), b(3852645), reason: 'server_info itself');
    expect(lnMaxPayment(null, 'BTC', 'in'), isNull, reason: 'no operator');
    expect(fitsMax(b(3852645), b(3852645)), isTrue, reason: 'at the limit');
    expect(fitsMax(b(3852646), b(3852645)), isFalse, reason: 'one atom over');
    expect(fitsMax(BigInt.from(9).pow(30), null), isTrue, reason: 'none published: the fallback decides');
  });

  test('a down node publishes 0: nothing fits', () {
    final down = jsonDecode(jsonEncode(info)) as Map<String, dynamic>;
    down['server_info']['lightning']['bitcoin']['node']['max_payment'] = {'send': '0', 'receive': '0'};
    expect(lnFits(down, 'BTC', 'out', b(1), price: 100000, precision: 8), isFalse);
  });

  test('the wallet holds a payment to the operator\'s limit, or to 1,500 USD when it publishes none', () {
    // Published: the limit, whatever the price.
    expect(lnFits(info, 'BTC', 'in', b(3852645), price: 100000, precision: 8), isTrue);
    expect(lnFits(info, 'BTC', 'in', b(3852646), price: 100000, precision: 8), isFalse);
    expect(lnFits(info, 'BTC', 'out', b(10863999), price: null, precision: 8), isTrue);
    // None published: 1,500 USD. At 100,000 USD a BTC that is 1,500,000 sat.
    expect(kLnFallbackUsd, 1500);
    expect(lnFits(bare, 'BTC', 'out', b(1500000), price: 100000, precision: 8), isTrue);
    expect(lnFits(bare, 'BTC', 'out', b(1500001), price: 100000, precision: 8), isFalse);
    expect(lnFits(null, usdx, 'in', b(150000), price: 1, precision: 2), isTrue, reason: '1,500 USDX');
    expect(lnFits(null, usdx, 'in', b(150001), price: 1, precision: 2), isFalse);
    expect(lnFits(bare, usdx, 'out', BigInt.from(9).pow(30), price: null, precision: 2), isTrue,
        reason: 'an asset the feed does not value is not held');
    expect(lnFits(info, 'BTC', 'out', null, price: 100000, precision: 8), isTrue, reason: 'no amount: nothing to hold');
  });

  test('the words for a payment the way in seconds cannot carry say none of the forbidden words', () {
    for (final w in [DefaultWords.byAddressNoWay, DefaultWords.invoiceNoWay, DefaultWords.giveCode]) {
      expect(forbiddenIn(w), isEmpty, reason: w);
    }
  });
}
