// The payment name, against a service that answers as the web wallet's (tooling/lsp/lnaddr.mjs):
// every message signed with the name key over the same digest the service checks.
import 'dart:async';
import 'dart:convert';

import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/lnaddr.dart';
import 'package:ambra/src/data/name_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const phrase = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const domain = 'sequentiatestnet.com', base = 'https://sequentiatestnet.com/lsp';

bool verifies(String pub, List<int> digest, Object? sig) => schnorrVerify(unhex(pub), digest, unhex('$sig'));

void main() {
  final key = nameKey(phrase);

  LnAddress mount(MockClient c, {List<String>? log, Future<String> Function(BigInt)? invoice, String? kept}) {
    String? stored = kept;
    return LnAddress(
      base: base,
      domain: domain,
      key: () => (priv: key.priv, pub: key.pub),
      invoice: invoice ?? (msat) async => 'lntb${msat}n1x',
      code: () async => 'BITCOIN:TB1QXYZ',
      limits: () => (min: BigInt.from(1000), max: BigInt.from(50000)),
      load: () async => stored,
      save: (n) async => stored = n,
      client: () => c,
      log: log?.add,
      retry: const Duration(milliseconds: 10),
      now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
  }

  test('register signs the name, the key and the time; release signs the name and the time', () async {
    final bodies = <String, Map>{};
    final c = MockClient((r) async {
      final b = jsonDecode(r.body) as Map;
      bodies[r.url.path] = b;
      if (r.url.path.endsWith('/wait')) return http.Response('{"ok":true,"requests":[]}', 200);
      return http.Response('{"ok":true}', 200);
    });
    final a = mount(c);
    expect(await a.register('Alice'), 'alice');
    expect(a.address, 'alice@$domain');
    expect(a.lnurl, 'https://$domain/.well-known/lnurlp/alice');
    final reg = bodies['/lsp/lnaddr/-/register']!;
    expect(reg['pubkey'], key.pub);
    expect(verifies(key.pub, signedDigest('register', domain, 'alice', [key.pub, 1700000000]), reg['sig']), isTrue);
    await a.release();
    final rel = bodies['/lsp/lnaddr/-/release']!;
    expect(verifies(key.pub, signedDigest('release', domain, 'alice', [1700000000]), rel['sig']), isTrue);
    expect(a.name, isNull);
    a.stop();
  });

  test('a bad name is refused before anything is sent; a taken one in the service\'s words', () async {
    var calls = 0;
    final c = MockClient((r) async {
      calls++;
      return http.Response('{"ok":false,"error":"That name is taken. Choose another.","code":"taken"}', 409);
    });
    final a = mount(c);
    await expectLater(a.register('ab'), throwsA(predicate((e) => '$e' == NameWords.badName)));
    expect(calls, 0);
    await expectLater(a.register('alice'), throwsA(predicate((e) => '$e' == NameWords.taken)));
    expect(a.name, isNull);
  });

  test('the link answers an invoice request and a code request, each signed', () async {
    final answers = <Map>[];
    var waits = 0;
    final done = Completer<void>();
    final c = MockClient((r) async {
      final b = jsonDecode(r.body) as Map;
      if (r.url.path.endsWith('/wait')) {
        waits++;
        expect(verifies(key.pub, signedDigest('wait', domain, 'alice', [1700000000, 1000, 50000]), b['sig']), isTrue);
        expect(b['min_sat'], '1000');
        expect(b['max_sat'], '50000');
        if (waits == 1) {
          return http.Response(jsonEncode({'ok': true, 'requests': [
            {'id': 'r1', 'kind': 'invoice', 'msat': '21000'},
            {'id': 'r2', 'kind': 'code'},
          ]}), 200);
        }
        await done.future;
        return http.Response('{"ok":true,"requests":[]}', 200);
      }
      if (r.url.path.endsWith('/answer')) {
        answers.add(b);
        if (answers.length == 2 && !done.isCompleted) done.complete();
      }
      return http.Response('{"ok":true}', 200);
    });
    final a = mount(c, kept: 'alice');
    await a.recover();
    a.start();
    await done.future.timeout(const Duration(seconds: 5));
    a.stop();
    final inv = answers.firstWhere((x) => x['id'] == 'r1');
    expect(inv['pr'], 'lntb21000n1x');
    expect(verifies(key.pub, signedDigest('invoice', domain, 'alice', ['r1', 'lntb21000n1x']), inv['sig']), isTrue);
    final code = answers.firstWhere((x) => x['id'] == 'r2');
    expect(code['code'], 'BITCOIN:TB1QXYZ');
    expect(verifies(key.pub, signedDigest('code', domain, 'alice', ['r2', 'BITCOIN:TB1QXYZ']), code['sig']), isTrue);
  });

  test('a request the wallet cannot answer is refused, signed', () async {
    final answers = <Map>[];
    final done = Completer<void>();
    var waits = 0;
    final c = MockClient((r) async {
      final b = jsonDecode(r.body) as Map;
      if (r.url.path.endsWith('/wait')) {
        if (++waits == 1) return http.Response(jsonEncode({'ok': true, 'requests': [{'id': 'r9', 'kind': 'invoice', 'msat': '5000'}]}), 200);
        await done.future;
        return http.Response('{"ok":true,"requests":[]}', 200);
      }
      answers.add(b);
      if (!done.isCompleted) done.complete();
      return http.Response('{"ok":true}', 200);
    });
    final a = mount(c, kept: 'alice', invoice: (_) async => throw StateError('the ark is closed'));
    await a.recover();
    a.start();
    await done.future.timeout(const Duration(seconds: 5));
    a.stop();
    expect(answers.single['refused'], true);
    expect(verifies(key.pub, signedDigest('refuse', domain, 'alice', ['r9']), answers.single['sig']), isTrue);
  });

  test('a name the service no longer knows under this key is dropped', () async {
    final c = MockClient((r) async => http.Response('{"ok":false,"error":"No wallet goes by that name."}', 404));
    final a = mount(c, kept: 'alice');
    await a.recover();
    a.start();
    for (var i = 0; i < 50 && a.name != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(a.name, isNull);
    a.stop();
  });

  group('paying a name', () {
    BigInt decode(String pr) {
      if (!pr.startsWith('lntb')) throw const FormatException('the invoice is not a Bitcoin invoice');
      return BigInt.parse(pr.substring(4, pr.indexOf('n', 4))) * BigInt.from(100);
    }

    test('a name at our domain is paid at the code its wallet gives', () async {
      final c = MockClient((r) async {
        expect(r.url.toString(), '$base/lnaddr/bob');
        return http.Response('{"ok":true,"code":"BITCOIN:TB1QBOB","fresh":true}', 200);
      });
      final t = await resolveLnAddress(text: 'bob@$domain', btc: false, domain: domain, base: base, decodeMsat: decode, client: c);
      expect(t.code, 'BITCOIN:TB1QBOB');
    });

    test('an offline wallet, in the service\'s words', () async {
      final c = MockClient((r) async => http.Response(jsonEncode({'status': 'ERROR', 'reason': NameWords.offline}), 200));
      await expectLater(resolveLnAddress(text: 'bob@$domain', btc: true, domain: domain, base: base, decodeMsat: decode, client: c),
          throwsA(predicate((e) => '$e' == NameWords.offline)));
    });

    test('another service\'s name: BTC only, an invoice of exactly the amount', () async {
      String pr = 'lntb210n1x';
      final c = MockClient((r) async {
        if (r.url.path == '/.well-known/lnurlp/carol') {
          return http.Response(jsonEncode({'tag': 'payRequest', 'callback': 'https://other.example/cb?x=1', 'minSendable': 1000, 'maxSendable': 100000000}), 200);
        }
        expect(r.url.queryParameters['amount'], '21000');
        expect(r.url.queryParameters['x'], '1');
        return http.Response(jsonEncode({'pr': pr}), 200);
      });
      Future<LnAddressTarget> pay({bool btc = true, BigInt? msat}) => resolveLnAddress(
          text: 'carol@other.example', btc: btc, msat: msat ?? BigInt.from(21000), domain: domain, base: base, decodeMsat: decode, client: c);
      expect((await pay()).invoice, 'lntb210n1x');
      await expectLater(pay(btc: false), throwsA(predicate((e) => '$e' == 'This address takes BTC only.')));
      await expectLater(pay(msat: BigInt.from(100)), throwsA(predicate((e) => '$e'.startsWith('This address takes between'))));
      pr = 'lntb999n1x';
      await expectLater(pay(), throwsA(predicate((e) => '$e' == 'The address answered with an invoice for another amount.')));
      pr = 'lnsq210n1x';
      await expectLater(pay(), throwsA(predicate((e) => '$e' == 'The address answered with an invoice that is not for BTC.')));
    });

    test('names are read as LUD-16 writes them', () {
      expect(parseLnAddress('Alice@SequentiaTestnet.com')?.name, 'alice');
      expect(parseLnAddress('lightning:a.b+c@x.io')?.domain, 'x.io');
      expect(parseLnAddress('tb1qxyz'), isNull);
    });
  });

  test('the name\'s words say none of default mode\'s forbidden words', () {
    for (final s in NameWords.all()) {
      for (final w in DefaultWords.forbidden) {
        final hit = RegExp('(^|[^A-Za-z])${RegExp.escape(w)}(s|es)?(\$|[^A-Za-z])', caseSensitive: false).hasMatch(s);
        expect(hit, isFalse, reason: '"$s" says "$w"');
      }
    }
  });
}
