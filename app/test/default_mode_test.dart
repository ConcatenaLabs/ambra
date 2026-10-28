import 'dart:convert';

import 'package:ambra/src/data/leaf_service.dart';
import 'package:flutter_test/flutter_test.dart';

String hexOf(String s) => utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  const op = 'b6f4c5924ad81947658cf85bb93d9267efc54c7fcb2e4577e8c954c68fa087bb';
  final gen = 'aa' * 32;

  group('requestFor (a receive code this wallet pays in the tree)', () {
    String code(Map<String, Object?> j, {String word = 'request'}) => '$word:${hexOf(jsonEncode(j))}';

    test('a request naming this operator and chain', () {
      final j = requestFor(code({'kind': 'request', 'operator': op, 'genesis_hash': gen, 'owner': 'ab'}),
          operator: op, genesis: gen);
      expect(j?['owner'], 'ab');
    });
    test('any word before the colon, and an older wallet\'s key', () {
      expect(requestFor(code({'arca_request': 1, 'operator': op, 'genesis_hash': gen}, word: 'arca'), operator: op, genesis: gen),
          isNotNull);
    });
    test('another operator, another chain, another kind, or not a code at all', () {
      expect(requestFor(code({'kind': 'request', 'operator': 'cd' * 32, 'genesis_hash': gen}), operator: op, genesis: gen), isNull);
      expect(requestFor(code({'kind': 'request', 'operator': op, 'genesis_hash': 'bb' * 32}), operator: op, genesis: gen), isNull);
      expect(requestFor(code({'kind': 'swap-offer', 'operator': op, 'genesis_hash': gen}), operator: op, genesis: gen), isNull);
      for (final t in ['tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx', 'lntb1u1p…', 'request:zz', 'request:', ':00', '']) {
        expect(requestFor(t, operator: op, genesis: gen), isNull, reason: t);
      }
    });
  });

  test('minLeaves: served assets with a smallest leaf published', () {
    final m = minLeaves({
      'assets': [
        {'asset': 'a1', 'min_leaf': '1000000'},
        {'asset': 'a2', 'min_leaf': null, 'min_leaf_value': 1},
        {'asset': 'a3', 'min_leaf': '12'},
      ]
    });
    expect(m, {'a1': BigInt.from(1000000), 'a3': BigInt.from(12)});
    expect(minLeaves(null), isEmpty);
  });

  test('boardFee reads a board quote', () {
    expect(boardFee({'fee': {'asset': 'a1', 'amount': '2245'}, 'vsize': 200}), BigInt.from(2245));
    expect(boardFee({'fee': 'x'}), isNull);
    expect(boardFee(null), isNull);
  });

  test('arrivingAtomsOf: leaves not final yet, per asset', () {
    final a = arrivingAtomsOf({
      'arca': {
        'a1': {'pending': '500', 'live': '7'},
        'a2': {'operator-confirmed': '9'},
      }
    });
    expect(a, {'a1': BigInt.from(500)});
    expect(arrivingAtomsOf(null), isEmpty);
    final b = arrivingAtomsOf({
      'arca': {
        'a1': {'pending': '500'}
      }
    }, {
      'pending_coins': [
        {'leaf_id': 'x', 'asset': 'a1', 'value': '20'},
        {'leaf_id': 'y', 'asset': 'a3', 'value': '7'},
      ]
    });
    expect(b, {'a1': BigInt.from(520), 'a3': BigInt.from(7)});
  });
}
