// The testnet faucet, once per wallet, through the app's own ApiClient against a real
// sequentia-faucet (its node CLI a stand-in, so no coins move) behind a local front door that
// forwards the client's address as the site's does. Skipped without FAUCET_DIR.
//
//   cd app && FAUCET_DIR=/path/to/sequentia-faucet flutter test test/faucet_once_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/api_client.dart';
import 'package:ambra/src/data/config.dart';
import 'package:ambra/src/data/faucet_wallet.dart';

const _addr0 = 'tb1q6rz28mcfaxtmd6v789l9rrlrusdprr9pqcpvkl';
const _id0 = '0dc441add97a52d9e9f9254c6d6a7aaf530c1cca887a08d9b188cb3a6b196803';
final _dir = Platform.environment['FAUCET_DIR'];

void main() {
  Process? faucet;
  HttpServer? door;
  Directory? work;
  final posted = <Map<String, dynamic>>[];

  setUpAll(() async {
    if (_dir == null) return;
    work = await Directory.systemTemp.createTemp('ambra-faucet-once-');
    final cli = File('${work!.path}/cli')
      ..writeAsStringSync('#!/bin/sh\ncase "\$*" in *getbalance*) echo 0; exit 0;; esac\necho ${'cd' * 32}\n');
    await Process.run('chmod', ['755', cli.path]);
    final probe = await ServerSocket.bind('127.0.0.1', 0);
    final fport = probe.port;
    await probe.close();
    faucet = await Process.start('node', ['$_dir/server.js'], environment: {
      'FAUCET_PORT': '$fport', 'FAUCET_CLI': cli.path, 'FAUCET_DATADIR': '/nowhere',
      'FAUCET_LEDGER': '${work!.path}/claims.jsonl',
    }, includeParentEnvironment: false);
    await faucet!.stdout.transform(utf8.decoder).firstWhere((l) => l.contains('listening'));
    door = await HttpServer.bind('127.0.0.1', 0);
    final client = HttpClient();
    door!.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.method == 'POST') posted.add(jsonDecode(body) as Map<String, dynamic>);
      final path = req.uri.path.replaceFirst('/faucet', '');
      final up = await client.openUrl(req.method, Uri.parse('http://127.0.0.1:$fport${path.isEmpty ? '/' : path}${req.uri.hasQuery ? '?${req.uri.query}' : ''}'));
      up.headers.set('content-type', 'application/json');
      up.headers.set('x-forwarded-for', '198.51.100.${posted.length + 1}');
      up.write(body);
      final r = await up.close();
      req.response.statusCode = r.statusCode;
      req.response.headers.contentType = ContentType.json;
      await req.response.addStream(r);
      await req.response.close();
    });
    Backend.origin = 'http://127.0.0.1:${door!.port}';
  });
  tearDownAll(() async {
    faucet?.kill();
    await door?.close(force: true);
    await work?.delete(recursive: true);
  });

  test('a request names the wallet; the second is refused in the faucet\'s words', () async {
    final wallet = faucetWalletIdOf(_addr0);
    expect(wallet, _id0);
    expect(await ApiClient.faucetClaimed(wallet), <String>{});
    final paid = await ApiClient.faucet(_addr0, asset: 'USDX', wallet: wallet);
    expect(paid.asset, 'USDX');
    expect(paid.amount, '500000');
    expect(posted.single, {'address': _addr0, 'asset': 'USDX', 'wallet': _id0});
    expect(await ApiClient.faucetClaimed(wallet), {'USDX'});
    try {
      await ApiClient.faucet('tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7', asset: 'USDX', wallet: wallet);
      fail('a second USDX was paid');
    } on FaucetRefused catch (e) {
      expect(e.alreadyPaid, isTrue);
      expect(e.message,
          'This wallet has already received its USDX from the faucet. The faucet pays each asset once per wallet. To get more, trade for it in the wallet.');
    }
    // tSEQ is one asset among the others, still offered.
    expect((await ApiClient.faucet(_addr0, wallet: wallet)).asset, 'tSEQ');
    expect(await ApiClient.faucetClaimed(wallet), {'tSEQ', 'USDX'});
  }, skip: _dir == null ? 'set FAUCET_DIR to a sequentia-faucet checkout' : false);
}
