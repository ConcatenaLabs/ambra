// The node's own report of a hosted node (`GET /node/onchain`) and when it means a Move to
// Lightning is still owed a channel. Pure HTTP, mocked.
//   cd app && flutter test test/node_onchain_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ambra/src/data/lsp_client.dart';

void main() {
  tearDown(() => LspClient.client = http.Client());

  Future<NodeOnchain?> read(int status, Map<String, dynamic> body) {
    LspClient.client = MockClient((req) async {
      expect(req.url.path, endsWith('/node/onchain'));
      expect(req.url.queryParameters['node'], 'seq:abc:02ff');
      return http.Response(jsonEncode(body), status);
    });
    return LspClient.nodeOnchain('seq:abc:02ff');
  }

  test('a deposit that never became a channel is owed one', () async {
    final n = (await read(200, {
      'ok': true, 'node_up': true, 'onchain_msat': 1000000000000, 'channels': 0, 'channel_states': [],
      'stranded': true,
    }))!;
    expect(n.onchainAtoms, BigInt.from(1000000000));
    expect(n.owesChannel, isTrue);
  });

  test('coins a closed channel returned are not a move', () async {
    final n = (await read(200, {
      'ok': true, 'node_up': true, 'onchain_msat': 5000000, 'channels': 0,
      'channel_states': [{'funding_txid': 'aa', 'funding_outnum': 0, 'state': 'ONCHAIN'}],
    }))!;
    expect(n.owesChannel, isFalse);
  });

  test('a node waiting for its device says nothing', () async {
    final n = (await read(200, {'ok': true, 'node_up': false, 'onchain_msat': 0, 'channels': 0, 'channel_states': null}))!;
    expect(n.nodeUp, isFalse);
    expect(n.channelStates, isNull);
    expect(n.owesChannel, isFalse);
  });

  test('a node with its channel open owes nothing', () async {
    final n = (await read(200, {
      'ok': true, 'node_up': true, 'onchain_msat': 20000000, 'channels': 1,
      'channel_states': [{'state': 'CHANNELD_NORMAL'}],
    }))!;
    expect(n.owesChannel, isFalse);
  });

  test('a node never provisioned is null', () async {
    expect(await read(404, {'ok': false, 'error': 'unknown node key'}), isNull);
  });
}
