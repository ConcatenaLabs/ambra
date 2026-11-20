// The payment name, against a service that answers as the web wallet's (tooling/lsp/lnaddr.mjs):
// every message signed with the name key over the same digest the service checks.
import 'dart:async';
import 'dart:convert';

import 'package:ambra/src/data/btc_lightning.dart' show decodeBtcInvoice;
import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/lnaddr.dart';
import 'package:ambra/src/data/name_key.dart';
import 'package:ambra/src/data/pay_code.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const phrase = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const domain = 'sequentiatestnet.com', base = 'https://sequentiatestnet.com/lsp';

bool verifies(String pub, List<int> digest, Object? sig) => schnorrVerify(unhex(pub), digest, unhex('$sig'));

void main() {
  final key = nameKey(phrase);

  final metas = <String>[];
  LnAddress mount(MockClient c, {List<String>? log, Future<String> Function(BigInt, String)? invoice, String? kept}) {
    String? stored = kept;
    return LnAddress(
      base: base,
      domain: domain,
      key: () => (priv: key.priv, pub: key.pub),
      invoice: invoice ??
          (msat, metadata) async {
            metas.add(metadata);
            return 'lntb${msat}n1x';
          },
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
            {'id': 'r1', 'kind': 'invoice', 'msat': '21000', 'metadata': lnurlMetadata('alice', domain)},
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
    // The invoice was asked to commit to the metadata the service served, byte for byte the string
    // lnaddr.js makes (JSON with no spaces).
    expect(metas, ['[["text/plain","Payment to alice@$domain"],["text/identifier","alice@$domain"]]']);
    expect(verifies(key.pub, signedDigest('invoice', domain, 'alice', ['r1', 'lntb21000n1x']), inv['sig']), isTrue);
    final code = answers.firstWhere((x) => x['id'] == 'r2');
    expect(code['code'], 'BITCOIN:TB1QXYZ');
    expect(verifies(key.pub, signedDigest('code', domain, 'alice', ['r2', 'BITCOIN:TB1QXYZ']), code['sig']), isTrue);
  });

  test('a request naming another name\'s metadata is refused, signed, and no invoice is made', () async {
    final answers = <Map>[];
    final done = Completer<void>();
    var waits = 0, made = 0;
    final c = MockClient((r) async {
      final b = jsonDecode(r.body) as Map;
      if (r.url.path.endsWith('/wait')) {
        if (++waits == 1) {
          return http.Response(jsonEncode({'ok': true, 'requests': [
            {'id': 'r7', 'kind': 'invoice', 'msat': '5000', 'metadata': lnurlMetadata('mallory', domain)},
          ]}), 200);
        }
        await done.future;
        return http.Response('{"ok":true,"requests":[]}', 200);
      }
      answers.add(b);
      if (!done.isCompleted) done.complete();
      return http.Response('{"ok":true}', 200);
    });
    final a = mount(c, kept: 'alice', invoice: (_, _) async {
      made++;
      return 'lntb5000n1x';
    });
    await a.recover();
    a.start();
    await done.future.timeout(const Duration(seconds: 5));
    a.stop();
    expect(made, 0);
    expect(answers.single['refused'], isTrue);
    expect(verifies(key.pub, signedDigest('refuse', domain, 'alice', ['r7']), answers.single['sig']), isTrue);
  });

  test('a name\'s metadata hash is sha256 of the served string\'s UTF-8 bytes', () {
    final meta = lnurlMetadata('alice', domain);
    expect(metadataHash('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(metadataHash(meta), hexOf(sha256.convert(utf8.encode(meta)).bytes));
    expect(metadataHash(const JsonEncoder.withIndent(' ').convert(jsonDecode(meta))) == metadataHash(meta), isFalse);
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
    final a = mount(c, kept: 'alice', invoice: (_, _) async => throw StateError('the ark is closed'));
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

    test('a name at our domain is paid at the code its wallet signed', () async {
      final signed = signCode(key.priv, domain, 'bob', 'BITCOIN:TB1QBOB');
      final c = MockClient((r) async {
        expect(r.url.toString(), '$base/lnaddr/bob');
        return http.Response(jsonEncode({'ok': true, 'pubkey': key.pub, 'id': signed.id, 'code': signed.code, 'sig': signed.sig, 'fresh': true}), 200);
      });
      final t = await resolveLnAddress(text: 'bob@$domain', btc: false, domain: domain, base: base, decodeMsat: decode, client: c);
      expect(t.code, 'BITCOIN:TB1QBOB');
      expect(t.fresh, isTrue);
      // The same code unsigned: refused.
      final bare = MockClient((r) async => http.Response('{"ok":true,"code":"BITCOIN:TB1QBOB","fresh":true}', 200));
      await expectLater(resolveLnAddress(text: 'bob@$domain', btc: false, domain: domain, base: base, decodeMsat: decode, client: bare),
          throwsA(predicate((e) => '$e' == NameWords.unsigned)));
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
      for (final t in ['alice@sequentiatestnet.com', 'lightning:alice@sequentiatestnet.com', 'LIGHTNING:ALICE@SEQUENTIATESTNET.COM', '\u20bfalice@sequentiatestnet.com']) {
        final a = parseLnAddress(t);
        expect('${a?.name}@${a?.domain}', 'alice@sequentiatestnet.com', reason: t);
      }
    });
  });

  // ambra#271: Send read a bare LNURL as a Bitcoin address and opened the on-chain confirmation.
  group('an LNURL in Send', () {
    const url = 'https://sequentiatestnet.com/.well-known/lnurlp/alice';
    final lnurl = lnurlEncode(url).toUpperCase();
    BigInt decode(String pr) {
      if (!pr.startsWith('lntb')) throw const FormatException('the invoice is not a Bitcoin invoice');
      return BigInt.parse(pr.substring(4, pr.indexOf('n', 4))) * BigInt.from(100);
    }

    test('a bare LNURL, either case, lightning: in front or not, and LUD-17\'s lnurlp://', () {
      for (final t in [lnurl, lnurl.toLowerCase(), 'lightning:$lnurl', 'LIGHTNING:$lnurl', ' $lnurl\n', 'lnurlp://sequentiatestnet.com/.well-known/lnurlp/alice']) {
        expect(lnurlOfSendInput(t)?.toString(), url, reason: t);
      }
    });

    test('a code whose one way to pay is its LNURL; not one with another way, nor anything else', () {
      expect(lnurlOfSendInput('bitcoin:?lightning=$lnurl&amount=0.00001')?.toString(), url);
      expect(lnurlOfSendInput('bitcoin:tb1qxyz?lightning=$lnurl'), isNull);
      for (final t in ['tb1qxyz', 'alice@sequentiatestnet.com', 'lntb210n1x', 'lnbc1', '']) {
        expect(lnurlOfSendInput(t), isNull, reason: t);
      }
    });

    test('LUD-16\'s URL of a name is that name; any other URL is not', () {
      expect(lnurlName(Uri.parse(url)), 'alice@sequentiatestnet.com');
      expect(lnurlName(Uri.parse('https://Other.Example/.well-known/lnurlp/Bob')), 'bob@other.example');
      for (final u in ['https://x.io/lnurlp/alice', 'https://x.io/.well-known/lnurlp/alice?amount=1', 'http://x.io/.well-known/lnurlp/alice',
          'https://x.io:8443/.well-known/lnurlp/alice', 'https://x.io/.well-known/lnurlp/a/b']) {
        expect(lnurlName(Uri.parse(u)), isNull, reason: u);
      }
    });

    test('any other LNURL-pay: BTC only, an invoice of exactly the amount, in a code\'s words', () async {
      String pr = 'lntb210n1x';
      final c = MockClient((r) async {
        if (r.url.path == '/pay/42') {
          return http.Response(jsonEncode({'tag': 'payRequest', 'callback': 'https://shop.example/cb?x=1', 'minSendable': 1000, 'maxSendable': 100000000}), 200);
        }
        expect(r.url.queryParameters['amount'], '21000');
        return http.Response(jsonEncode({'pr': pr}), 200);
      });
      final u = lnurlOfSendInput(lnurlEncode('https://shop.example/pay/42'))!;
      expect(lnurlName(u), isNull);
      Future<LnAddressTarget> pay({bool btc = true, Uri? at}) =>
          resolveLnurlPay(url: at ?? u, btc: btc, msat: BigInt.from(21000), decodeMsat: decode, client: c, what: 'code');
      expect((await pay()).invoice, 'lntb210n1x');
      await expectLater(pay(btc: false), throwsA(predicate((e) => '$e' == 'This code takes BTC only.')));
      await expectLater(pay(at: Uri.parse('http://shop.example/pay/42')), throwsA(predicate((e) => '$e' == 'This code does not take payments.')));
      pr = 'lntb999n1x';
      await expectLater(pay(), throwsA(predicate((e) => '$e' == 'The code answered with an invoice for another amount.')));
    });
  });

  // ambra#280: a read of a name or an LNURL never follows a redirect from https to anything else.
  test('redirects: followed to https, refused to http', () async {
    final following = <bool>[];
    final c = MockClient((r) async {
      // The platform's client follows redirects itself unless asked not to; the wallet follows
      // them by hand, so it can refuse one.
      following.add(r.followRedirects);
      if (r.url.path == '/pay/1') return http.Response('', 302, headers: {'location': 'https://shop.example/pay/2'});
      if (r.url.path == '/pay/2') {
        return http.Response(jsonEncode({'tag': 'payRequest', 'callback': 'https://shop.example/cb', 'minSendable': 1, 'maxSendable': 100000000}), 200);
      }
      if (r.url.path == '/cb') return http.Response('', 301, headers: {'location': 'http://shop.example/cb'});
      return http.Response('{}', 404);
    });
    BigInt decode(String pr) => BigInt.from(21000);
    await expectLater(
        resolveLnurlPay(url: Uri.parse('https://shop.example/pay/1'), btc: true, msat: BigInt.from(21000), decodeMsat: decode, client: c, what: 'code'),
        throwsA(predicate((e) => '$e' == 'The address sent the request on to an address that is not secure, so nothing was sent.')));
    expect(following, isNotEmpty);
    expect(following.every((f) => !f), isTrue, reason: 'no request lets the client follow a redirect itself');
  });

  // ambra#281: the invoice must commit to the metadata the service served (LUD-06).
  group('the description hash', () {
    const meta = '[["text/plain","a coffee"]]';
    final metaHash = hexOf(sha256.convert(utf8.encode(meta)).bytes);
    // BOLT 11's example invoice (250,000 sat) with its description replaced by a description hash.
    const inv0 =
        'lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpuaztrnwngzn3kdzw5hydlzf03qdgm2hdq27cqv3agm2awhz5se903vruatfhq77w3ls4evs3ch9zw97j25emudupq63nyw24cg27h2rspfj9srp';
    final withHash = invoiceWithDescriptionHash(inv0, metaHash);
    final otherHash = invoiceWithDescriptionHash(inv0, 'ab' * 32);
    final msat = BigInt.from(250000000);

    test('the decoder reads it', () {
      expect(decodeBtcInvoice(withHash)['description_hash'], metaHash);
      expect(decodeBtcInvoice(inv0)['description_hash'], isNull);
      expect(decodeBtcInvoice(withHash)['msat'], msat);
    });

    Future<LnAddressTarget> pay(String pr, {Object? metadata = meta}) => resolveLnurlPay(
          url: Uri.parse('https://shop.example/pay'),
          btc: true,
          msat: msat,
          decodeMsat: (pr) => decodeBtcInvoice(pr)['msat'] as BigInt,
          descriptionHashOf: (pr) => decodeBtcInvoice(pr)['description_hash'] as String?,
          what: 'code',
          client: MockClient((r) async => r.url.path == '/pay'
              ? http.Response(jsonEncode({'tag': 'payRequest', 'callback': 'https://shop.example/cb', 'minSendable': 1, 'maxSendable': 1000000000, 'metadata': ?metadata}), 200)
              : http.Response(jsonEncode({'pr': pr}), 200)),
        );
    const refused = 'The code answered with an invoice for something other than this payment.';

    test('an invoice committing to the metadata is paid', () async {
      expect((await pay(withHash)).invoice, withHash);
    });
    test('one committing to something else, or to metadata the service did not serve, is not', () async {
      await expectLater(pay(otherHash), throwsA(predicate((e) => '$e' == refused)));
      await expectLater(pay(withHash, metadata: null), throwsA(predicate((e) => '$e' == refused)));
    });

    // LUD-06 no longer asks payers to check the hash, and many invoices carry none: refusing them would
    // refuse every name whose service or wallet does not commit (ambra#285).
    test('one with a plain description and no hash is paid', () async {
      expect((await pay(inv0)).invoice, inv0);
    });

    test('a name at another Sequentia domain, paid by LNURL with no name domain of its own (a custom node)', () async {
      final ours = jsonEncode([
        ['text/plain', 'Payment to carol@names.example'],
        ['text/identifier', 'carol@names.example'],
      ]);
      final c = MockClient((r) async => r.url.path == '/.well-known/lnurlp/carol'
          ? http.Response(jsonEncode({'tag': 'payRequest', 'callback': 'https://names.example/lnurlp/carol/cb', 'minSendable': 1000, 'maxSendable': 1000000000, 'metadata': ours}), 200)
          : http.Response(jsonEncode({'pr': inv0}), 200));
      final t = await resolveLnAddress(
        text: 'carol@names.example',
        btc: true,
        msat: msat,
        domain: null,
        base: 'https://node.example/lsp',
        decodeMsat: (pr) => decodeBtcInvoice(pr)['msat'] as BigInt,
        descriptionHashOf: (pr) => decodeBtcInvoice(pr)['description_hash'] as String?,
        client: c,
      );
      expect(t.invoice, inv0);
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

const _cs = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

int _polymod(List<int> v) {
  const g = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final x in v) {
    final b = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ x;
    for (var i = 0; i < 5; i++) {
      if ((b >> i) & 1 == 1) chk ^= g[i];
    }
  }
  return chk;
}

/// [inv] with its description (`d`) replaced by a description hash (`h`) of [hashHex], and a valid
/// checksum (its signature no longer matches, which the wallet's reader does not check).
String invoiceWithDescriptionHash(String inv, String hashHex) {
  final sep = inv.lastIndexOf('1');
  final hrp = inv.substring(0, sep);
  final all = [for (final ch in inv.substring(sep + 1).split('')) _cs.indexOf(ch)];
  final body = all.sublist(0, all.length - 6);
  final sig = body.sublist(body.length - 104);
  final fields = body.sublist(7, body.length - 104);
  final out = <int>[...body.sublist(0, 7)];
  for (var i = 0; i + 3 <= fields.length;) {
    final t = fields[i], len = (fields[i + 1] << 5) | fields[i + 2];
    if (t != 13 && t != 23) out.addAll(fields.sublist(i, i + 3 + len));
    i += 3 + len;
  }
  final groups = <int>[];
  var acc = 0, bits = 0;
  for (var i = 0; i < 64; i += 2) {
    acc = (acc << 8) | int.parse(hashHex.substring(i, i + 2), radix: 16);
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      groups.add((acc >> bits) & 31);
    }
  }
  groups.add((acc << (5 - bits)) & 31);
  out.addAll([23, 1, 20, ...groups]);
  out.addAll(sig);
  final ex = [...hrp.codeUnits.map((x) => x >> 5), 0, ...hrp.codeUnits.map((x) => x & 31)];
  final mod = _polymod([...ex, ...out, 0, 0, 0, 0, 0, 0]) ^ 1;
  return '${hrp}1${[...out, for (var k = 0; k < 6; k++) (mod >> (5 * (5 - k))) & 31].map((v) => _cs[v]).join()}';
}
