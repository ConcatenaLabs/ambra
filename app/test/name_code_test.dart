// The payment name's signed receive codes, against vectors written by the web wallet's own modules
// (sequentia-web-wallet lnaddr.js and name-stock.js, the contract), the payer's checks, and the
// stock the wallet keeps with the name service.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ambra/src/data/lnaddr.dart';
import 'package:ambra/src/data/name_key.dart';
import 'package:ambra/src/data/name_stock.dart';
import 'package:ambra/src/data/pay_code.dart';
import 'package:ambra/src/data/receive_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const domain = 'sequentiatestnet.com', base = 'https://sequentiatestnet.com/lsp';
const other = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
const addr = 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx';

/// A short receive request that lapses at [until], marked by [mark].
String sqr(int until, [int mark = 0]) => bech32mEncode('sqr', [
      1, 0, 1, 2, 3, 4, 5, 6, 7, 8, mark & 255, ...List.filled(95, 7), 0, 144,
      (until >> 24) & 255, (until >> 16) & 255, (until >> 8) & 255, until & 255,
    ]);

BigInt _decode(String pr) => throw const FormatException('no invoices here');

void main() {
  final v = jsonDecode(File('test/name_code_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final key = nameKey(v['phrase'] as String);
  final thief = nameKey(other);

  group('the web wallet\'s vectors', () {
    test('the name key, each code\'s id and signature, and the signed digests', () {
      expect(key.pub, v['pubkey']);
      for (final c in (v['codes'] as List).cast<Map>()) {
        expect(codeId(c['code'] as String), c['id']);
        expect(verifyCode(key.pub, domain, 'alice', id: c['id'], code: c['code'], sig: c['sig']), isTrue, reason: 'a JS signature verifies in Dart');
        expect(requestUntil(c['code'] as String), c['until']);
        expect(verifyCode(key.pub, domain, 'bob', id: c['id'], code: c['code'], sig: c['sig']), isFalse);
      }
      final live = v['live'] as Map;
      expect(verifyCode(key.pub, domain, 'alice', id: live['id'], code: live['code'], sig: live['sig']), isTrue);
      for (final d in (v['digests'] as List).cast<Map>()) {
        expect(hexOf(signedDigest(d['action'] as String, domain, 'alice', d['fields'] as List)), d['hex'], reason: '${d['action']}');
      }
    });

    test('the QR text and the spellings of a name', () {
      for (final q in (v['qr'] as List).cast<Map>()) {
        expect(nameQrText(q['in'] as String), q['out']);
      }
      for (final p in (v['parse'] as List).cast<Map>()) {
        final a = parseLnAddress(p['in'] as String);
        final want = p['out'] as Map?;
        expect(a == null ? null : {'name': a.name, 'domain': a.domain}, want, reason: '${p['in']}');
      }
    });

    test('the stock\'s indices and top-up plan', () {
      for (final p in (v['pick'] as List).cast<Map>()) {
        expect(
            pickStockIndices(p['count'] as int,
                nextUnused: p['nextUnused'] as int,
                held: (p['held'] as List).cast<int>(),
                handed: (p['handed'] as List).cast<int>(),
                gap: (p['gap'] as int?) ?? receiveGap),
            p['out']);
      }
      final pl = v['plan'] as Map;
      final mine = {
        for (final e in (pl['mine'] as Map).entries) '${e.key}': (index: (e.value as Map)['index'] as int, until: (e.value as Map)['until'] as int?)
      };
      final got = planTopUp(mine: mine, held: (pl['held'] as List).cast<String>(), nowS: pl['nowS'] as int, size: pl['size'] as int);
      final want = pl['out'] as Map;
      expect(got.served, want['served']);
      expect(got.drop, want['drop']);
      expect(got.keep, want['keep']);
      expect(got.make, want['make']);
    });

    test('a Dart signature, for the web wallet to verify', () {
      final code = PayCode(address: addr, ark: 'tark1qdart', sequentia: sqr(2000000000, 9)).build();
      final s = signCode(key.priv, domain, 'alice', code);
      expect(verifyCode(key.pub, domain, 'alice', id: s.id, code: s.code, sig: s.sig), isTrue);
      final out = Platform.environment['PN1_DART_SIG_OUT'];
      if (out != null) File(out).writeAsStringSync(jsonEncode({'pubkey': key.pub, 'id': s.id, 'code': s.code, 'sig': s.sig}));
    });
  });

  group('the payer', () {
    const now = 1900000000;
    final good = PayCode(address: addr, ark: 'tark1qexample', sequentia: sqr(now + 86400, 1)).build();
    final theirs = PayCode(address: 'tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7', sequentia: sqr(now + 86400, 2)).build();
    late Map<String, String> pinned;
    late NamePins pins;
    setUp(() {
      pinned = {};
      pins = (get: (a) async => pinned[a], set: (a, p) async => pinned[a] = p);
    });
    Future<LnAddressTarget> look(Map<String, Object?> body, {int status = 200}) => resolveLnAddress(
        text: 'alice@$domain',
        btc: true,
        domain: domain,
        base: base,
        decodeMsat: _decode,
        client: MockClient((r) async => http.Response(jsonEncode(body), status)),
        pins: pins,
        nowS: () => now);
    Map<String, Object?> served(({String id, String code, String sig}) s, {String? pub, bool reused = false}) =>
        {'ok': true, 'pubkey': pub ?? key.pub, 'id': s.id, 'code': s.code, 'sig': s.sig, 'fresh': !reused, 'reused': reused};
    Matcher says(String words) => throwsA(predicate((e) => '$e' == words));

    test('a signed code is paid as it is, and the key kept', () async {
      final t = await look(served(signCode(key.priv, domain, 'alice', good)));
      expect(t.code, good);
      expect(t.fresh, isTrue);
      expect(pinned['alice@$domain'], key.pub);
    });

    test('a service handing out an address of its own is refused', () async {
      await look(served(signCode(key.priv, domain, 'alice', good)));
      // Signed by another key, under the name's key.
      await expectLater(look(served(signCode(thief.priv, domain, 'alice', theirs))), says(NameWords.unsigned));
      // The name's signature over another code.
      final g = signCode(key.priv, domain, 'alice', good);
      await expectLater(look(served((id: codeId(theirs), code: theirs, sig: g.sig))), says(NameWords.unsigned));
      // No signature.
      await expectLater(look({'ok': true, 'pubkey': key.pub, 'code': theirs}), says(NameWords.unsigned));
      // Another name's code.
      await expectLater(look(served(signCode(key.priv, domain, 'bob', good))), says(NameWords.unsigned));
      // A key of the service's own, after the payer paid the name at the real one.
      await expectLater(look(served(signCode(thief.priv, domain, 'alice', theirs), pub: thief.pub)), says(NameWords.changed));
      // A signed text that is not a code.
      await expectLater(look(served(signCode(key.priv, domain, 'alice', 'hello'))), says(NameWords.unsigned));
    });

    test('a code handed out before, or lapsing, is paid without its single-use part', () async {
      var t = await look(served(signCode(key.priv, domain, 'alice', good), reused: true));
      expect(t.reused, isTrue);
      expect(PayCode.read(t.code!)!.sequentia, isNull);
      expect(PayCode.read(t.code!)!.ark, 'tark1qexample');
      expect(PayCode.read(t.code!)!.address, addr);
      final lapsing = PayCode(address: addr, sequentia: sqr(now + payMarginS - 1)).build();
      t = await look(served(signCode(key.priv, domain, 'alice', lapsing)));
      expect(PayCode.read(t.code!)!.sequentia, isNull);
    });

    test('too many lookups', () async {
      await expectLater(look({'status': 'ERROR', 'reason': NameWords.busy}, status: 429), says(NameWords.busy));
    });
  });

  test('the wallet fills its stock with signed codes inside the window, and answers a code request from it', () async {
    final held = <String>[];
    final posts = <Map>[];
    var waits = 0;
    final answered = Completer<Map>();
    final c = MockClient((r) async {
      final b = jsonDecode(r.body) as Map;
      final path = r.url.path;
      if (path.endsWith('/register')) return http.Response('{"ok":true}', 200);
      if (path.endsWith('/stock')) {
        posts.add(b);
        final ids = (b['add'] as List).map((x) => '${(x as Map)['id']}').toList();
        final drop = (b['drop'] as List).map((x) => '$x').toList();
        expect(schnorrVerify(unhex(key.pub), signedDigest('stock', domain, 'alice', [b['ts'], ids.join(','), drop.join(',')]), unhex('${b['sig']}')), isTrue);
        for (final x in (b['add'] as List).cast<Map>()) {
          expect(x['id'], codeId(x['code'] as String));
          expect(verifyCode(key.pub, domain, 'alice', id: x['id'], code: x['code'], sig: x['sig']), isTrue);
        }
        held
          ..removeWhere(drop.contains)
          ..addAll(ids);
        return http.Response(jsonEncode({'ok': true, 'held': held}), 200);
      }
      if (path.endsWith('/wait')) {
        waits++;
        if (waits == 2) {
          held.removeRange(0, 3); // three handed out to payers meanwhile
          return http.Response(jsonEncode({'ok': true, 'requests': [{'id': 'live1', 'kind': 'code'}], 'held': held}), 200);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return http.Response(jsonEncode({'ok': true, 'requests': [], 'held': held}), 200);
      }
      if (path.endsWith('/answer')) {
        if (!answered.isCompleted) answered.complete(b);
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('{"ok":false}', 404);
    });
    String? stockJson;
    var made = 0;
    final a = LnAddress(
      base: base,
      domain: domain,
      key: () => (priv: key.priv, pub: key.pub),
      invoice: (m) async => throw StateError('no'),
      code: () async => throw StateError('the stock makes codes'),
      limits: () => (min: BigInt.from(1000), max: BigInt.from(50000)),
      load: () async => null,
      save: (n) async {},
      client: () => c,
      retry: const Duration(milliseconds: 10),
      stockCode: (i) async {
        made++;
        return PayCode(address: addr, ark: 'tark1qi$i', sequentia: sqr(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3 * 86400, i)).build();
      },
      nextUnused: () => 4,
      shownIndex: () => 4,
      loadStock: () async => stockJson,
      saveStock: (j) async => stockJson = j,
      topUpEvery: Duration.zero,
    );
    await a.register('alice');
    final live = await answered.future.timeout(const Duration(seconds: 5));
    for (var i = 0; i < 200 && ((a.stock?.handed.length ?? 0) < 4 || (a.stock?.mine.length ?? 0) < defaultStockSize); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    a.stop();
    // The live answer: a new code, signed under the request's id.
    expect(verifyCode(key.pub, domain, 'alice', id: 'live1', code: live['code'], sig: live['sig']), isTrue);
    final st = a.stock!;
    expect(st.mine.length, defaultStockSize);
    final all = [...st.mine.values.map((x) => x.index), ...st.handed];
    expect(all.every((i) => i > 4 && i < 4 + receiveGap), isTrue, reason: 'inside the window, never the address on screen: $all');
    expect(st.handed.length, 4, reason: 'three handed out by the service, one answered live');
    expect(made, defaultStockSize + 1 + 3);
    expect(jsonDecode(stockJson!)['name'], 'alice');
  });

  test('after any lookups, payments, top-ups and closed spells, a restore finds every payment', () {
    // A scan from the phrase alone: batches of the gap, on while a batch holds a payment.
    int scanReach(Set<int> paid) {
      var start = 0;
      for (;;) {
        var any = false;
        for (var i = start; i < start + receiveGap; i++) {
          if (paid.contains(i)) any = true;
        }
        start += receiveGap;
        if (!any) return start - 1;
      }
    }

    var seed = 11;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    var reusedTotal = 0, handedTotal = 0;
    for (var run = 0; run < 300; run++) {
      final paid = <int>{};
      var seenNext = 0, shown = 0, ids = 0;
      var open = true;
      final stock = <({String id, int index})>[];
      ({String id, int index})? last;
      final mine = <String, StockCode>{};
      final handed = <int>[];
      final everHanded = <int>{};
      void topUp() {
        final plan = planTopUp(mine: mine, held: [for (final c in stock) c.id], nowS: 0);
        for (final id in plan.served) {
          handed.add(mine[id]!.index);
          mine.remove(id);
        }
        for (final index in pickStockIndices(plan.make, nextUnused: seenNext, held: [...mine.values.map((c) => c.index), shown], handed: handed)) {
          final id = 'c${ids++}';
          mine[id] = (index: index, until: null);
          stock.add((id: id, index: index));
        }
      }

      topUp();
      for (var step = 0; step < 400; step++) {
        final r = rnd();
        if (r < 0.05) {
          open = !open;
        } else if (r < 0.55) {
          ({String id, int index})? c;
          if (stock.isNotEmpty) {
            c = last = stock.removeAt(0);
          } else {
            c = last;
            if (c != null) reusedTotal++;
          }
          if (c != null) {
            everHanded.add(c.index);
            handedTotal++;
            if (rnd() < 0.4) paid.add(c.index);
          }
        } else if (r < 0.65) {
          shown = shown + 1 > seenNext ? shown + 1 : seenNext;
          if (shown >= seenNext + receiveGap) shown = seenNext;
        } else if (r < 0.7) {
          paid.add(shown);
        }
        if (open) {
          for (final i in paid) {
            if (i + 1 > seenNext) seenNext = i + 1;
          }
          if (shown < seenNext) shown = seenNext;
          topUp();
        }
        for (final c in stock) {
          expect(c.index - seenNext, lessThan(receiveGap));
        }
      }
      for (final i in everHanded) {
        expect(i <= scanReach({...paid, i}), isTrue, reason: 'address $i found after a restore (run $run)');
      }
    }
    expect(reusedTotal, greaterThan(0));
    expect(handedTotal, greaterThan(1000));
  });
}
