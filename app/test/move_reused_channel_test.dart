// A Move to Lightning the service reports "active" by reusing a channel the node already had,
// while the deposit is still on the node's wallet: the move is not reported done.
import 'dart:convert';

import 'package:ambra/src/data/channel_move_service.dart';
import 'package:ambra/src/data/lsp_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ChannelMove move() => ChannelMove(
      id: 'move:seq:x:02ab',
      chain: 'seq',
      asset: 'x' * 64,
      ticker: 'USDX',
      amountAtoms: '1000000000',
      nodeKey: 'seq:x:02ab',
      pollPath: null,
      startedMs: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => LspClient.client = http.Client());

  void lsp({required bool reused, required int onchainMsat}) {
    LspClient.client = MockClient((req) async {
      if (req.url.path.endsWith('/channel/open')) {
        return http.Response(jsonEncode({'ok': true, 'job_id': 'j1', 'status': 'active', 'reused_existing': reused}), 202);
      }
      if (req.url.path.endsWith('/node/onchain')) {
        return http.Response(jsonEncode({'ok': true, 'node_up': true, 'onchain_msat': onchainMsat, 'channels': 2,
          'channel_states': [{'state': 'CHANNELD_NORMAL'}, {'state': 'CHANNELD_NORMAL'}]}), 200);
      }
      return http.Response('{}', 404);
    });
  }

  test('a reused channel with the deposit still on the node is not a finished move', () async {
    lsp(reused: true, onchainMsat: 1000000000000);
    await ChannelMoveStore.put(move());
    await expectLater(ChannelMoveService.drive(move()),
        throwsA(predicate((e) => '$e'.contains('no new channel was opened for it') && '$e'.contains('stays on your Lightning node'))));
    expect(await ChannelMoveStore.list(), isEmpty);
  });

  test('a reused channel that took the deposit is done', () async {
    lsp(reused: true, onchainMsat: 0);
    final job = await ChannelMoveService.drive(move());
    expect(job.isActive, isTrue);
  });

  test('a new channel is done', () async {
    lsp(reused: false, onchainMsat: 1000000000000);
    final job = await ChannelMoveService.drive(move());
    expect(job.isActive, isTrue);
  });
}
