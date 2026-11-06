// Word names (word_name.dart) against vectors written by the web wallet's word-name.js (the
// contract), and over a service that answers as the web wallet's: a third word only when two are
// taken, and a wallet restored from its phrase gets the same name, shown the same.
import 'dart:convert';
import 'dart:io';

import 'package:ambra/src/data/lnaddr.dart';
import 'package:ambra/src/data/name_key.dart';
import 'package:ambra/src/data/word_name.dart';
import 'package:ambra/src/data/word_name_list.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const phrase = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const other = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
const domain = 'sequentiatestnet.com', base = 'https://sequentiatestnet.com/lsp';

void main() {
  final v = jsonDecode(File('test/word_name_vectors.json').readAsStringSync()) as Map<String, dynamic>;

  test('the list: 831 words of letters, each once, the same list as the web wallet\'s', () {
    expect(wordNameList.length, 831);
    expect(wordNameList.length, v['count']);
    expect(wordNameList.every((w) => RegExp(r'^[a-z]{3,5}$').hasMatch(w)), isTrue);
    expect(wordNameList.toSet().length, wordNameList.length);
    final sha = sha256.convert(utf8.encode(wordNameList.join('\n'))).toString();
    expect(sha, wordNameListSha256);
    expect(sha, v['listSha256']);
  });

  test('every key\'s candidates and display forms match the web wallet\'s', () {
    expect(wordNameCandidateCount, v['candidates']);
    for (final k in (v['keys'] as List).cast<Map>()) {
      final pub = k['pub'] as String;
      final got = wordNameCandidates(pub);
      final want = (k['candidates'] as List).cast<Map>();
      expect(got.length, want.length);
      for (var i = 0; i < got.length; i++) {
        expect(got[i].name, want[i]['name'], reason: '$pub #$i');
        expect(got[i].words, want[i]['words']);
        expect(nameProblem(got[i].name), isNull);
      }
      expect(got.first.words.length, 2);
      expect(got.skip(1).every((c) => c.words.length == 3), isTrue);
      expect([for (final c in got) displayName(c.name.toUpperCase(), pub)], k['display'], reason: 'typed in capitals, shown the same');
      expect(wordNameCandidates(pub.toUpperCase()).map((c) => c.name).toList(), got.map((c) => c.name).toList());
    }
    for (final o in (v['others'] as List).cast<Map>()) {
      expect(displayName(o['name'] as String, o['pub'] as String), o['display']);
    }
    expect(displayName(wordNameCandidates(nameKey(phrase).pub).first.name, null), wordNameCandidates(nameKey(phrase).pub).first.name);
  });

  /// A name service in memory, answering register, mine and wait as the web wallet's does.
  MockClient service(Map<String, String> names) => MockClient((r) async {
        final path = r.url.path;
        if (path.endsWith('/lnaddr/-/mine')) {
          final pub = r.url.queryParameters['pubkey'];
          final n = names.entries.where((e) => e.value == pub).map((e) => e.key).firstOrNull;
          return http.Response(jsonEncode({'ok': true, 'name': n}), 200);
        }
        final b = jsonDecode(r.body) as Map;
        if (path.endsWith('/register')) {
          final n = '${b['name']}', pub = '${b['pubkey']}';
          expect(schnorrVerify(unhex(pub), signedDigest('register', domain, n, [pub, b['ts']]), unhex('${b['sig']}')), isTrue);
          final had = names[n];
          if (had != null && had != pub) return http.Response('{"ok":false,"error":"That name is taken. Choose another.","code":"taken"}', 409);
          names.removeWhere((_, p) => p == pub);
          names[n] = pub;
          return http.Response(jsonEncode({'ok': true, 'name': n}), 200);
        }
        if (path.endsWith('/wait')) return http.Response('{"ok":true,"requests":[]}', 200);
        return http.Response('{"ok":true,"held":[]}', 200);
      });

  LnAddress wallet(MockClient c, String words) {
    final k = nameKey(words);
    String? kept;
    return LnAddress(
      base: base,
      domain: domain,
      key: () => (priv: k.priv, pub: k.pub),
      invoice: (_) async => throw StateError('no'),
      code: () async => throw StateError('no'),
      limits: () => null,
      load: () async => kept,
      save: (n) async => kept = n,
      client: () => c,
      retry: const Duration(milliseconds: 10),
    );
  }

  String caps(List<String> w) => w.map((x) => x[0].toUpperCase() + x.substring(1)).join();

  test('a third word only when two are taken; restored from the phrase: the same name, shown the same', () async {
    final names = <String, String>{};
    final c = service(names);
    final mine = wordNameCandidates(nameKey(phrase).pub);
    // Another wallet holds this wallet's two-word name already.
    names[mine[0].name] = nameKey(other).pub;
    final w = wallet(c, phrase);
    expect(await w.claimWordName(), mine[1].name);
    expect(w.display, '${caps(mine[1].words)}@$domain');
    expect(w.address, '${mine[1].name}@$domain', reason: 'the name itself is lower case');
    expect(nameQrText(w.address!), '${mine[1].name}@$domain');
    expect(w.isWordName, isTrue);
    w.stop();

    // Restored from the phrase alone, elsewhere: the same name, shown the same.
    final again = wallet(c, phrase);
    expect(await again.recover(), mine[1].name);
    expect(again.display, w.display);
    expect(again.isWordName, isTrue);
    again.stop();

    // The service lost its record: the same phrase gets the same name again.
    names.clear();
    names[mine[0].name] = nameKey(other).pub;
    final fresh = wallet(c, phrase);
    expect(await fresh.recover(), isNull);
    expect(await fresh.claimWordName(), mine[1].name);
    expect(fresh.display, w.display);
    fresh.stop();

    // A wallet holding a name of its own choosing swaps it for its word name in one step.
    final o = wallet(c, other);
    names.remove(mine[0].name);
    await o.register('my-own-name');
    expect(o.isWordName, isFalse);
    expect(o.display, 'my-own-name@$domain', reason: 'a name of another kind is shown as it is');
    final ow = await o.claimWordName();
    expect(ow, wordNameCandidates(nameKey(other).pub).first.name);
    expect(names.containsKey('my-own-name'), isFalse, reason: 'the old name is free');
    o.stop();
  });

  test('every candidate taken: the plain sentence, and nothing registered', () async {
    final names = <String, String>{};
    for (final c in wordNameCandidates(nameKey(phrase).pub)) {
      names[c.name] = nameKey(other).pub;
    }
    final w = wallet(service(names), phrase);
    await expectLater(w.claimWordName(), throwsA(predicate((e) => '$e' == NameWords.noWordName)));
    expect(w.name, isNull);
  });
}
