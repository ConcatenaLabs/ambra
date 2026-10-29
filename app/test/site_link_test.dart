// The site pairing (data/site_link.dart): the pairing code read, and the wire against fake relays
// and a stand-in for the core's crypto (ambra_core's nostr.rs has its own tests, against the
// NIP-44 vectors, and the device drive runs both against nostr-tools over a public relay).
import 'dart:async';
import 'dart:convert';

import 'package:ambra/src/data/site_link.dart';
import 'package:flutter_test/flutter_test.dart';

final client = 'ab' * 32;
const relay1 = 'wss://relay.one', relay2 = 'wss://relay.two';
String code({String? protocol = kSiteProtocol, String? secret = 'c0ffee', List<String> relays = const [relay1, relay2]}) =>
    'nostrconnect://$client?${[for (final r in relays) 'relay=${Uri.encodeComponent(r)}', if (secret != null) 'secret=$secret', 'name=SeqDEX', 'url=https%3A%2F%2Fsequentiatestnet.com%2Fdex%2F', if (protocol != null) 'protocol=$protocol'].join('&')}';

/// Events are plain JSON here: `content` is the message, unencrypted.
class FakeCrypto implements SiteCrypto {
  var n = 0;
  @override
  Future<({String secret, String pubkey})> newKeys() async => (secret: 'sec${++n}', pubkey: 'cd' * 32);
  @override
  Future<String> seal(String secret, String peer, int createdAt, String plaintext) async => jsonEncode({
        'id': 'e${n++}',
        'pubkey': 'cd' * 32,
        'created_at': createdAt,
        'kind': kConnectKind,
        'tags': [
          ['p', peer]
        ],
        'content': plaintext,
      });
  @override
  Future<({String from, int createdAt, String text})> open(String secret, String eventJson) async {
    final e = jsonDecode(eventJson) as Map;
    if (e['content'] == 'garbage') throw StateError('invalid MAC');
    return (from: '${e['pubkey']}', createdAt: e['created_at'] as int, text: '${e['content']}');
  }
}

class FakeSocket implements RelaySocket {
  final ctl = StreamController<dynamic>();
  final sent = <List>[];
  @override
  Stream<dynamic> get messages => ctl.stream;
  @override
  void send(String text) => sent.add(jsonDecode(text) as List);
  @override
  Future<void> close() => ctl.close();
  List<Map> events() => [for (final f in sent) if (f[0] == 'EVENT') f[1] as Map];
}

class MemStore implements SiteStore {
  List<Map<String, dynamic>> saved = [];
  @override
  Future<List<SitePairing>> load() async => [for (final j in saved) SitePairing.fromJson(j)];
  @override
  Future<void> save(List<SitePairing> all) async => saved = [for (final p in all) p.toJson()];
}

Future<void> settle() => Future.delayed(const Duration(milliseconds: 20));

void main() {
  test('a pairing code: its key, relays, secret, name and the address it claims', () {
    final u = parsePairingUri(code());
    expect([u.clientPubkey, u.relays, u.secret, u.name, u.url], [client, [relay1, relay2], 'c0ffee', 'SeqDEX', 'https://sequentiatestnet.com/dex/']);
  });

  test('a code without the protocol, a secret or a relay is refused', () {
    expect(() => parsePairingUri(code(protocol: null)), throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('provider protocol'))));
    expect(() => parsePairingUri(code(protocol: 'nip46')), throwsFormatException);
    expect(() => parsePairingUri(code(secret: null)), throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('no secret'))));
    expect(() => parsePairingUri(code(secret: '')), throwsFormatException);
    expect(() => parsePairingUri(code(relays: const [])), throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('no way'))));
    expect(() => parsePairingUri(code(relays: const ['https://not.a.relay'])), throwsFormatException);
    expect(() => parsePairingUri('bitcoin:tb1qxyz'), throwsFormatException);
    expect(() => parsePairingUri('nostrconnect://abcd?secret=1&protocol=$kSiteProtocol&relay=wss://r'), throwsFormatException);
  });

  test('the words keep out of default mode\'s forbidden words', () {
    expect(siteLinkForbidden(), isEmpty);
  });

  group('the wire', () {
    late Map<String, FakeSocket> sockets;
    late SiteLink link;
    late List<(String, Map)> served;
    late MemStore store;
    var clock = 1761700000;

    setUp(() async {
      sockets = {};
      served = [];
      store = MemStore();
      link = SiteLink(
        crypto: FakeCrypto(),
        connect: (url) async => sockets[url] = FakeSocket(),
        store: store,
        serve: (site, method, params) async {
          served.add((method, params));
          if (method == 'placeOrder') throw StateError(SiteLinkWords.rejected);
          return {'ok': method};
        },
        now: () => clock,
      );
      await link.start();
      await link.pair(parsePairingUri(code()));
      await settle();
    });

    void deliver(String relay, Map<String, dynamic> msg, {int? at, String? from, String? content, String id = 'x'}) {
      sockets[relay]!.ctl.add(jsonEncode([
        'EVENT',
        'sub',
        {
          'id': id,
          'pubkey': from ?? client,
          'created_at': at ?? clock,
          'kind': kConnectKind,
          'tags': [
            ['p', 'cd' * 32]
          ],
          'content': content ?? jsonEncode(msg),
        }
      ]));
    }

    List<Map> answers() => [for (final e in sockets[relay1]!.events()) jsonDecode('${e['content']}') as Map];

    test('the pairing sends the secret back on every relay, and subscribes to this wallet\'s key', () {
      for (final r in [relay1, relay2]) {
        final s = sockets[r]!;
        final req = s.sent.firstWhere((f) => f[0] == 'REQ');
        expect((req[2] as Map)['#p'], ['cd' * 32]);
        expect((req[2] as Map)['kinds'], [kConnectKind]);
        final ev = s.events().single;
        expect(ev['tags'], [
          ['p', client]
        ]);
        expect((jsonDecode('${ev['content']}') as Map)['result'], 'c0ffee');
      }
      expect(store.saved.single['client'], client);
    });

    test('a request is answered once, on every relay, whichever relay brought it', () async {
      deliver(relay1, {'id': 'r1', 'method': 'getCapabilities', 'params': {}}, id: 'ev1');
      deliver(relay2, {'id': 'r1', 'method': 'getCapabilities', 'params': {}}, id: 'ev1');
      deliver(relay2, {'id': 'r1', 'method': 'getCapabilities', 'params': {}}, id: 'ev2'); // the same id again
      await settle();
      expect(served.length, 1);
      expect(answers().last, {'id': 'r1', 'result': {'ok': 'getCapabilities'}});
      expect(sockets[relay2]!.events().length, 2);
    });

    test('a refusal is a plain error string', () async {
      deliver(relay1, {'id': 'r2', 'method': 'placeOrder', 'params': {'type': 'market'}}, id: 'ev3');
      await settle();
      expect(answers().last, {'id': 'r2', 'error': 'the user rejected the request'});
    });

    test('dropped: a request more than five minutes off, another key\'s, one that does not open', () async {
      deliver(relay1, {'id': 'r3', 'method': 'getBalances'}, at: clock - 301, id: 'ev4');
      deliver(relay1, {'id': 'r4', 'method': 'getBalances'}, at: clock + 301, id: 'ev5');
      deliver(relay1, {'id': 'r5', 'method': 'getBalances'}, from: 'ef' * 32, id: 'ev6');
      deliver(relay1, {}, content: 'garbage', id: 'ev7');
      await settle();
      expect(served, isEmpty);
      deliver(relay1, {'id': 'r6', 'method': 'getBalances'}, at: clock - 299, id: 'ev8');
      await settle();
      expect(served.single.$1, 'getBalances');
    });

    test('forget sends disconnect; a site\'s disconnect forgets it', () async {
      final p = link.sites.single;
      await link.forget(p);
      expect(answers().last, {'event': 'disconnect'});
      expect(link.sites, isEmpty);
      expect(store.saved, isEmpty);
      await link.pair(parsePairingUri(code()));
      await settle();
      deliver(relay1, {'event': 'disconnect'}, id: 'ev9');
      await settle();
      expect(link.sites, isEmpty);
    });
  });
}
