import 'dart:convert';

import 'package:ambra/src/data/placed_orders.dart';
import 'package:ambra/src/data/seqob_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('a record written at the broadcast keeps its unknown output through storage', () {
    final rec = PlacedCovenant(
      covTxid: 'aa' * 32,
      covVout: kVoutUnknown,
      pay: 'p',
      receive: 'r',
      sellAtoms: '100000000',
      recvAtoms: '90000000',
      makerIndex: 3,
      covenantSpkHex: '5120${'bb' * 32}',
      preparedJson: '{}',
      expiryLocktime: 0,
      posted: false,
      createdMs: 1,
    );
    final back = PlacedCovenant.fromJson(jsonDecode(jsonEncode(rec.toJson())) as Map<String, dynamic>);
    expect(back.covVout, kVoutUnknown);
    expect(back.key, '${'aa' * 32}:-1');
  });

  test('the reclaim locates the output of such a record, waiting out the explorer\'s 404', () async {
    var calls = 0;
    final vout = await resolveCovenantVout('cc' * 32, '5120${'bb' * 32}', wait: Duration.zero, get: (u) async {
      calls++;
      if (calls == 1) return http.Response('not found', 404);
      return http.Response(jsonEncode({
        'vout': [
          {'scriptpubkey': '0014${'11' * 20}'},
          {'scriptpubkey': '5120${'bb' * 32}'},
        ]
      }), 200);
    });
    expect(vout, 1);
    expect(calls, 2);
  });
}
