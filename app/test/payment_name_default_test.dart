// Every wallet holds a payment name by default (lnaddr.dart `ensure`), against a service that keeps
// names and removals per key as the web wallet's does (tooling/lsp/lnaddr.mjs and its tests in
// sequentia-web-wallet tooling/lsp/lnaddr.test.mjs): the word name with nothing asked, the same one
// after a restore, none after Remove on any device, asked again while the service does not answer
// or limits new names, and a kept name shown only once the service confirms it.
import 'dart:convert';

import 'package:ambra/src/data/lnaddr.dart';
import 'package:ambra/src/data/name_key.dart';
import 'package:ambra/src/data/word_name.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const phrase = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const domain = 'sequentiatestnet.com', base = 'https://sequentiatestnet.com/lsp';

/// The name service, in memory: one name per key, a released name kept for its key, and the keys
/// whose person removed their name (`declined`). Every message is checked against its signature.
class FakeNames {
  final names = <String, String>{}; // name -> pubkey
  final released = <String, String>{}; // name -> the key that released it
  final declined = <String>{};
  bool down = false, busy = false, tooMany = false;
  int newAllowed = 1 << 30;
  final seen = <String>[];

  bool _ok(String pub, List<int> digest, Object? sig) {
    try {
      return schnorrVerify(unhex(pub), digest, unhex('$sig'));
    } catch (_) {
      return false;
    }
  }

  http.Response _j(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

  Future<http.Response> handle(http.Request r) async {
    if (down) throw http.ClientException('fetch failed');
    final path = r.url.path.replaceFirst('/lsp/lnaddr/-/', '');
    seen.add(path);
    if (path == 'mine') {
      if (tooMany) return _j({'ok': false, 'error': 'busy', 'code': 'busy'}, 429);
      final q = r.url.queryParameters, pub = q['pubkey']!;
      if (!_ok(pub, signedDigest('mine', domain, '-', [pub, q['ts']]), q['sig'])) return _j({'ok': false}, 403);
      final n = names.entries.where((e) => e.value == pub).map((e) => e.key).firstOrNull;
      return _j({'ok': true, 'name': n, 'declined': declined.contains(pub)});
    }
    final b = jsonDecode(r.body) as Map;
    switch (path) {
      case 'register':
        final n = b['name'] as String, pub = b['pubkey'] as String;
        if (!_ok(pub, signedDigest('register', domain, n, [pub, b['ts']]), b['sig'])) return _j({'ok': false}, 403);
        if ((names[n] != null && names[n] != pub) || (released[n] != null && released[n] != pub)) {
          return _j({'ok': false, 'error': 'That name is taken. Choose another.'}, 409);
        }
        if (busy || newAllowed <= 0) {
          return _j({'ok': false, 'code': 'busy', 'error': NameWords.newBusy}, 429);
        }
        newAllowed--;
        names.removeWhere((k, v) => v == pub && k != n);
        names[n] = pub;
        released.remove(n);
        declined.remove(pub);
        return _j({'ok': true});
      case 'release':
        final n = b['name'] as String, pub = names[n];
        if (pub == null) return _j({'ok': false}, 404);
        if (!_ok(pub, signedDigest('release', domain, n, [b['ts']]), b['sig'])) return _j({'ok': false}, 403);
        names.remove(n);
        released[n] = pub;
        declined.add(pub);
        return _j({'ok': true});
      case 'decline':
        final pub = b['pubkey'] as String;
        if (!_ok(pub, signedDigest('decline', domain, '-', [pub, b['ts']]), b['sig'])) return _j({'ok': false}, 403);
        declined.add(pub);
        return _j({'ok': true});
      case 'wait':
        final n = b['name'] as String;
        if (names[n] == null) return _j({'ok': false, 'error': NameWords.noWallet}, 404);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _j({'ok': true, 'requests': []});
      case 'stock':
        return _j({'ok': true, 'held': []});
    }
    return _j({'ok': false}, 404);
  }
}

void main() {
  final key = nameKey(phrase);
  final wordName = wordNameCandidates(key.pub).first.name;

  /// A wallet on [s], its name and removal kept in [store] (one device's storage).
  LnAddress mount(FakeNames s, Map<String, Object?> store, {void Function()? onChange, bool lim = false}) => LnAddress(
        base: base,
        domain: domain,
        key: () => (priv: key.priv, pub: key.pub),
        invoice: (msat) async => throw StateError('none'),
        code: () async => 'BITCOIN:TB1QXYZ',
        limits: () => lim ? (min: BigInt.one, max: BigInt.from(1000)) : null,
        load: () async => store['name'] as String?,
        save: (n) async => store['name'] = n,
        loadRemoved: () async => store['removed'] == true,
        saveRemoved: (v) async => store['removed'] = v,
        client: () => MockClient(s.handle),
        onChange: onChange,
        retry: const Duration(milliseconds: 20),
        recheck: const Duration(milliseconds: 50),
      );

  Future<bool> until(bool Function() f) async {
    for (var i = 0; i < 200 && !f(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return f();
  }

  test('the word name with nothing asked; the same one back after a restore; none after Remove', () async {
    final s = FakeNames();
    final w = mount(s, {});
    expect(await w.ensure(), wordName);
    expect(w.isWordName, isTrue);
    expect(w.verified, isTrue);
    expect(s.names[wordName], key.pub);
    // Restored elsewhere (a fresh store): the name its key holds, not another.
    final again = mount(s, {});
    expect(await again.ensure(), wordName);
    // Developer mode (`want` says no): nothing is made by itself.
    await w.release();
    final dev = mount(s, {});
    s.declined.clear();
    expect(await dev.ensure(want: () => false), isNull);
    expect(s.names, isEmpty);
    // Removed by the person: never given again by itself, until the person takes one.
    s.declined.add(key.pub);
    final store = <String, Object?>{};
    final w2 = mount(s, store);
    expect(await w2.ensure(), isNull);
    expect(w2.removed, isTrue, reason: 'the service\'s removal is kept on this device too');
    await w2.claimWordName();
    expect(w2.removed, isFalse);
    expect(s.declined.contains(key.pub), isFalse, reason: 'taking a name clears the mark');
    await w2.release();
    expect(w2.removed, isTrue);
    expect(await w2.ensure(), isNull);
    for (final x in [w, again, dev, w2]) {
      x.stop();
    }
  });

  test('a removal holds on every device: the service keeps it per key', () async {
    final s = FakeNames();
    final a = mount(s, {});
    final name = await a.ensure();
    expect(name, isNotNull);
    await a.release();
    // Device B, the same phrase: no name made by itself, and it keeps the removal from then on.
    final bStore = <String, Object?>{};
    final b = mount(s, bStore);
    expect(await b.ensure(), isNull);
    expect(bStore['removed'], true);
    expect(s.names, isEmpty);
    // The person takes a name again on B: every device then holds it, A included.
    final chosen = await b.claimWordName();
    expect(await mount(s, {}).ensure(), chosen);
    a.stop();
    b.stop();
  });

  test('a removal only this device knows of is told to the service, signed', () async {
    final s = FakeNames();
    final w = mount(s, {'removed': true});
    expect(await w.ensure(), isNull);
    expect(s.declined, {key.pub});
    expect(s.seen, contains('decline'));
    // Another device then makes none either.
    expect(await mount(s, {}).ensure(), isNull);
    expect(s.names, isEmpty);
  });

  test('while the service does not answer: unreachable, asked again, the name once it answers', () async {
    final s = FakeNames()..down = true;
    var changes = 0;
    final w = mount(s, {}, onChange: () => changes++);
    final ensured = w.ensure();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(w.unreachable, isTrue);
    expect(w.name, isNull);
    s.down = false;
    expect(await ensured.timeout(const Duration(seconds: 5)), wordName);
    expect(w.unreachable, isFalse);
    expect(w.name, wordName);
    expect(changes, greaterThanOrEqualTo(2), reason: 'told both times, so Receive redraws by itself');
    w.stop();
  });

  test('while new names from the network are limited: refused says so, and it is asked again', () async {
    final s = FakeNames()..busy = true;
    final w = mount(s, {});
    final ensured = w.ensure();
    expect(await until(() => w.refused == 'busy'), isTrue);
    expect(w.name, isNull);
    expect(w.unreachable, isFalse);
    s.busy = false;
    expect(await ensured.timeout(const Duration(seconds: 5)), wordName);
    expect(w.refused, isNull);
    w.stop();
  });

  test('a kept name shows only once the service confirms it; a released one is dropped at once', () async {
    final s = FakeNames()..names['keptname'] = key.pub;
    final w = mount(s, {'name': 'keptname'}, lim: true);
    s.down = true;
    await w.recover();
    expect(w.name, 'keptname');
    expect(w.verified, isFalse, reason: 'not shown before the service answers');
    expect(w.unreachable, isTrue);
    s.down = false;
    await w.recover();
    expect(w.verified, isTrue);
    expect(w.unreachable, isFalse);
    // Released on another device while this one waits for payers: dropped, never shown again.
    w.start();
    s.names.remove('keptname');
    s.released['keptname'] = key.pub;
    expect(await until(() => w.name == null), isTrue);
    expect(w.verified, isFalse);
    // Changed on another device: the open wallet finds the new name.
    s.names['secondname'] = key.pub;
    final c = mount(s, {});
    await c.recover();
    expect(c.name, 'secondname');
    w.stop();
    c.stop();
  });

  test('not waiting for payers, the name is still checked: a change elsewhere shows', () async {
    final s = FakeNames()..names['firstname'] = key.pub;
    final w = mount(s, {});
    await w.recover();
    w.start();
    s.names
      ..remove('firstname')
      ..['secondname'] = key.pub;
    expect(await until(() => w.name == 'secondname' && w.verified), isTrue);
    w.stop();
  });

  test('a check refused for too many requests leaves the name shown, and is not unreachable', () async {
    final s = FakeNames()..names['shownname'] = key.pub;
    final w = mount(s, {});
    await w.recover();
    expect([w.name, w.verified, w.unreachable], ['shownname', true, false]);
    s.tooMany = true;
    await w.recover();
    expect([w.name, w.verified, w.unreachable], ['shownname', true, false]);
  });

  test('Settings says anyone can look the name up, and what a payer sees', () {
    expect(NameWords.tip,
        startsWith('Anyone can look this name up and pay you at it, in any amount they choose, and see the address each payment goes to.'));
    expect(NameWords.settingsLine('AmberFalcon@$domain'),
        'Your payment name is AmberFalcon@$domain. You can change or remove it in Settings.');
  });
}
