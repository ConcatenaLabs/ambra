/// Sites paired with this wallet by a `nostrconnect://` code, and the requests they send.
///
/// The extension's `doc/PAIRING.md` is the wire: a site (SeqDEX) shows
/// `nostrconnect://<its key>?relay=wss://…&secret=…&name=…&url=…&protocol=sequentia-provider-1`
/// as a QR code or a link. The owner approves the pairing here; the wallet makes a key pair of
/// its own for that pairing and answers on every relay the code names with one kind-24133 event
/// carrying the secret. From then on the site sends `{id, method, params}` and the wallet answers
/// `{id, result}` or `{id, error}`, each a kind-24133 event, NIP-44 v2 encrypted, signed by its
/// sender (the crypto is `ambra_core`'s `nostr.rs`). The methods are the provider protocol's
/// (the extension's `doc/PROVIDER.md`): the account, the balances, the mode and the site's
/// orders ([SiteOrders]). Every order is shown on this phone first, and nothing is signed until
/// its owner approves it.
///
/// The link runs while the app is open: a site's request reaches the phone while Ambra is in the
/// foreground, and a request sent while it is closed goes unanswered (the site says so).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'user_trade.dart' show forbiddenIn;

/// The protocol a pairing code must name: the provider protocol's methods, not NIP-46's.
const kSiteProtocol = 'sequentia-provider-1';

/// The event kind every message travels in.
const kConnectKind = 24133;

/// How far a request's time may be from this phone's clock, and how long an approval waits.
const kSiteWindow = Duration(minutes: 5);

const kSiteMethods = ['getCapabilities', 'getWalletMode', 'connect', 'getAccounts', 'getBalances', 'placeOrder', 'getOrders', 'cancelOrder'];

/// The words of the pairing screens and sheets (the web wallet's docs/DEFAULT_MODE.md: none of
/// its forbidden words).
class SiteLinkWords {
  static const entry = 'Connect to a site';
  static const entryLine = 'Trade on a site such as SeqDEX from this wallet. Every trade is shown here for you to approve.';
  static const scan = 'Scan the site\'s code';
  static const paste = 'Paste the site\'s link';
  static const pasteHint = 'nostrconnect://…';
  static const pasteGo = 'Continue';
  static String pairTitle(String name) => 'Connect to $name?';
  static const pairText =
      'The site will see your address and balances, and can ask you to trade. Every trade is shown here first, and nothing moves until you approve it.';
  static const site = 'Site';
  static const saysItIs = 'Says it is';
  static const check = 'Check this address against the page in front of you: any page can show any address in its code.';
  static const noAddress = 'gives no address';
  static const approve = 'Approve';
  static const decline = 'Decline';
  static const connected = 'Connected';
  static const paired = 'Connected sites';
  static const none = 'No site is connected.';
  static const forget = 'Forget';
  static const openOnly = 'A site reaches this wallet while Ambra is open.';
  static String connectedTo(String name) => 'Connected to $name.';
  static const rejected = 'the user rejected the request';

  static List<String> all() => [entry, entryLine, scan, paste, pasteGo, pairTitle('SeqDEX'), pairText, site, saysItIs, check, noAddress, approve,
      decline, connected, paired, none, forget, openOnly, connectedTo('SeqDEX')];
}

/// A pairing code, read.
class PairingUri {
  PairingUri({required this.clientPubkey, required this.relays, required this.secret, required this.name, required this.url});
  final String clientPubkey, secret, name;
  final List<String> relays;

  /// The site's own claim of its address (null when it gives none).
  final String? url;
}

/// Reads a `nostrconnect://` pairing code. Refuses one without a secret, a relay, or
/// `protocol=sequentia-provider-1` (a Nostr signer's code is not a site's).
PairingUri parsePairingUri(String text) {
  final t = text.trim();
  final m = RegExp(r'^nostrconnect://([0-9a-fA-F]{64})\?(.*)$', dotAll: true).firstMatch(t);
  if (m == null) throw const FormatException('This is not a site\'s connection code.');
  final q = Uri.splitQueryString(m.group(2)!);
  final all = <String, List<String>>{};
  for (final part in m.group(2)!.split('&')) {
    final i = part.indexOf('=');
    if (i <= 0) continue;
    final k = Uri.decodeQueryComponent(part.substring(0, i));
    (all[k] ??= []).add(Uri.decodeQueryComponent(part.substring(i + 1)));
  }
  if ((q['protocol'] ?? '') != kSiteProtocol) {
    throw const FormatException('This code is not for a wallet: it does not name the Sequentia provider protocol.');
  }
  final secret = (q['secret'] ?? '').trim();
  if (secret.isEmpty || secret.length > 256) throw const FormatException('This code has no secret: ask the site for a new one.');
  final relays = <String>[];
  for (final r in all['relay'] ?? const <String>[]) {
    final u = Uri.tryParse(r.trim());
    if (u == null || !(u.scheme == 'wss' || u.scheme == 'ws') || u.host.isEmpty) continue;
    final s = u.toString();
    if (!relays.contains(s)) relays.add(s);
  }
  if (relays.isEmpty) throw const FormatException('This code names no way to reach the site.');
  final name = (q['name'] ?? '').trim();
  final url = (q['url'] ?? '').trim();
  final u = Uri.tryParse(url);
  return PairingUri(
    clientPubkey: m.group(1)!.toLowerCase(),
    relays: relays.take(6).toList(),
    secret: secret,
    name: name.isEmpty ? 'A site' : (name.length > 64 ? name.substring(0, 64) : name),
    url: url.isNotEmpty && u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty ? url : null,
  );
}

/// One paired site: its key and relays, what it says it is, and this wallet's key for it.
class SitePairing {
  SitePairing({
    required this.clientPubkey,
    required this.relays,
    required this.name,
    required this.url,
    required this.secretHex,
    required this.pubkeyHex,
    required this.pairedAt,
    List<String>? answered,
  }) : answered = answered ?? [];
  final String clientPubkey, name, secretHex, pubkeyHex;
  final String? url;
  final List<String> relays;
  final int pairedAt;

  /// The ids of the last requests answered (a repeated id is dropped).
  final List<String> answered;

  /// The site as its orders are kept and shown: its address, or its key when it gives none.
  String get origin => url ?? 'nostr:$clientPubkey';

  Map<String, dynamic> toJson() => {
    'client': clientPubkey,
    'relays': relays,
    'name': name,
    'url': url,
    'secret': secretHex,
    'pubkey': pubkeyHex,
    'at': pairedAt,
    'answered': answered,
  };

  static SitePairing fromJson(Map j) => SitePairing(
    clientPubkey: '${j['client']}',
    relays: [for (final r in (j['relays'] as List?) ?? const []) '$r'],
    name: '${j['name']}',
    url: j['url'] as String?,
    secretHex: '${j['secret']}',
    pubkeyHex: '${j['pubkey']}',
    pairedAt: (j['at'] as num?)?.toInt() ?? 0,
    answered: [for (final a in (j['answered'] as List?) ?? const []) '$a'],
  );
}

/// What an approval shows: a title, a sentence and rows.
class SiteApproval {
  SiteApproval(this.title, this.text, this.rows);
  final String title, text;
  final List<(String, String)> rows;
}

/// The crypto of a pairing (ambra_core's `nostr.rs` in the app; a fake in tests).
abstract class SiteCrypto {
  Future<({String secret, String pubkey})> newKeys();
  Future<String> seal(String secret, String peer, int createdAt, String plaintext);
  Future<({String from, int createdAt, String text})> open(String secret, String eventJson);
}

/// A relay connection (dart:io WebSocket in the app; a fake in tests).
abstract class RelaySocket {
  Stream<dynamic> get messages;
  void send(String text);
  Future<void> close();
}

/// What the wallet serves a paired site: one method and its answer. Throws a message the site
/// receives as the error.
typedef SiteServe = Future<Object?> Function(SitePairing site, String method, Map<String, dynamic> params);

/// The persistent list of pairings of the open wallet.
abstract class SiteStore {
  Future<List<SitePairing>> load();
  Future<void> save(List<SitePairing> all);
}

/// The relays, the pairings and the requests.
class SiteLink extends ChangeNotifier {
  SiteLink({
    required this.crypto,
    required this.connect,
    required this.store,
    required this.serve,
    int Function()? now,
    void Function(String)? log,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000),
       log = log ?? ((_) {});

  final SiteCrypto crypto;
  final Future<RelaySocket> Function(String url) connect;
  final SiteStore store;
  SiteServe serve;
  final int Function() now;
  final void Function(String) log;

  List<SitePairing> sites = [];
  bool running = false;
  final _relays = <String, _Relay>{};
  final _seenEvents = <String>{};
  final _rng = Random.secure();

  String _rid() => List.generate(8, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  /// Loads the open wallet's pairings and listens on their relays.
  Future<void> start() async {
    sites = await store.load();
    running = true;
    _sync();
    notifyListeners();
  }

  /// Stops listening (the wallet locked, closed or removed).
  Future<void> stop() async {
    running = false;
    for (final r in _relays.values) {
      await r.close();
    }
    _relays.clear();
    sites = [];
    notifyListeners();
  }

  /// Pairs with a site whose code its owner approved: a key of this pairing, and the secret back
  /// on every relay the code names.
  Future<SitePairing> pair(PairingUri u) async {
    final k = await crypto.newKeys();
    sites.removeWhere((s) => s.clientPubkey == u.clientPubkey);
    final p = SitePairing(clientPubkey: u.clientPubkey, relays: u.relays, name: u.name, url: u.url, secretHex: k.secret,
        pubkeyHex: k.pubkey, pairedAt: now());
    sites.add(p);
    await store.save(sites);
    running = true;
    _sync();
    await _send(p, {'id': _rid(), 'result': u.secret});
    notifyListeners();
    return p;
  }

  /// Forgets a site: it hears `disconnect`, and nothing of it is kept.
  Future<void> forget(SitePairing p) async {
    try {
      await _send(p, {'event': 'disconnect'});
    } catch (e) {
      log('[sites] disconnect: $e');
    }
    sites.removeWhere((s) => s.clientPubkey == p.clientPubkey);
    await store.save(sites);
    _sync();
    notifyListeners();
  }

  /// Opens each relay the pairings name, closes the others, and asks each for the events
  /// addressed to this wallet's keys.
  void _sync() {
    if (!running) return;
    final want = <String, List<String>>{};
    for (final s in sites) {
      for (final r in s.relays) {
        (want[r] ??= []).add(s.pubkeyHex);
      }
    }
    for (final url in _relays.keys.toList()) {
      if (!want.containsKey(url)) unawaited(_relays.remove(url)!.close());
    }
    want.forEach((url, keys) {
      final r = _relays[url] ??= _Relay(url, this);
      r.subscribe(keys);
    });
  }

  Future<void> _send(SitePairing p, Map<String, dynamic> msg) async {
    final ev = await crypto.seal(p.secretHex, p.clientPubkey, now(), jsonEncode(msg));
    final frame = jsonEncode(['EVENT', jsonDecode(ev)]);
    var sent = 0;
    for (final url in p.relays) {
      final r = _relays[url] ??= _Relay(url, this);
      if (r.publish(frame)) sent++;
    }
    log('[sites] sent ${msg['id'] ?? msg['event']} to ${p.name} on $sent of ${p.relays.length} relays');
  }

  /// An event a relay delivered.
  Future<void> onEvent(Map ev) async {
    final eid = '${ev['id']}';
    if (!_seenEvents.add(eid)) return;
    if (_seenEvents.length > 2000) _seenEvents.remove(_seenEvents.first);
    if (ev['kind'] != kConnectKind) return;
    final tags = (ev['tags'] as List?) ?? const [];
    final to = tags.whereType<List>().where((t) => t.length > 1 && t[0] == 'p').map((t) => '${t[1]}').toSet();
    final site = sites.where((s) => to.contains(s.pubkeyHex) && s.clientPubkey == ev['pubkey']).firstOrNull;
    if (site == null) return;
    final ({String from, int createdAt, String text}) m;
    try {
      m = await crypto.open(site.secretHex, jsonEncode(ev));
    } catch (e) {
      log('[sites] dropped an event that does not open: $e');
      return;
    }
    if (m.from != site.clientPubkey) return;
    if ((m.createdAt - now()).abs() > kSiteWindow.inSeconds) {
      log('[sites] dropped a request ${m.createdAt - now()} s off this phone\'s clock');
      return;
    }
    Map msg;
    try {
      msg = jsonDecode(m.text) as Map;
    } catch (_) {
      return;
    }
    if (msg['event'] == 'disconnect') {
      sites.removeWhere((s) => s.clientPubkey == site.clientPubkey);
      await store.save(sites);
      _sync();
      notifyListeners();
      return;
    }
    final id = msg['id'];
    final method = msg['method'];
    if (id is! String || id.isEmpty || method is! String) return;
    if (site.answered.contains(id)) {
      log('[sites] dropped repeated request $id');
      return;
    }
    site.answered.add(id);
    if (site.answered.length > 200) site.answered.removeAt(0);
    await store.save(sites);
    final params = msg['params'] is Map ? Map<String, dynamic>.from(msg['params'] as Map) : <String, dynamic>{};
    Map<String, dynamic> answer;
    try {
      answer = {'id': id, 'result': await serve(site, method, params)};
    } catch (e) {
      answer = {'id': id, 'error': e is Exception || e is Error ? _plain(e) : '$e'};
    }
    log('[sites] $method from ${site.name}: ${answer.containsKey('error') ? 'error ${answer['error']}' : 'answered'}');
    if (sites.any((s) => s.clientPubkey == site.clientPubkey)) await _send(site, answer);
  }

  static String _plain(Object e) {
    final s = '$e';
    return s.replaceFirst(RegExp(r'^(Exception|FormatException|Invalid argument\(s\)|Bad state): '), '');
  }
}

/// One relay: its socket, kept open with a backoff, its subscription, and what waits to be sent.
class _Relay {
  _Relay(this.url, this.link) {
    _open();
  }
  final String url;
  final SiteLink link;
  RelaySocket? _ws;
  StreamSubscription? _sub;
  List<String> _keys = [];
  final _queue = <String>[];
  bool _closed = false;
  int _backoff = 2;
  final _subId = 'ambra-${Random.secure().nextInt(1 << 30).toRadixString(16)}';

  Future<void> _open() async {
    if (_closed) return;
    try {
      final ws = await link.connect(url);
      if (_closed) {
        await ws.close();
        return;
      }
      _ws = ws;
      _backoff = 2;
      _sub = ws.messages.listen(_onMessage, onDone: _lost, onError: (_) => _lost(), cancelOnError: true);
      _req();
      for (final f in _queue) {
        ws.send(f);
      }
      _queue.clear();
      link.log('[sites] relay $url open');
    } catch (e) {
      link.log('[sites] relay $url: $e');
      _retry();
    }
  }

  void _lost() {
    _ws = null;
    _sub?.cancel();
    _sub = null;
    _retry();
  }

  void _retry() {
    if (_closed) return;
    final s = _backoff;
    _backoff = min(_backoff * 2, 60);
    Timer(Duration(seconds: s), _open);
  }

  void _req() {
    final ws = _ws;
    if (ws == null || _keys.isEmpty) return;
    ws.send(jsonEncode([
      'REQ',
      _subId,
      {
        'kinds': [kConnectKind],
        '#p': _keys,
        'since': link.now() - kSiteWindow.inSeconds,
      },
    ]));
  }

  void subscribe(List<String> keys) {
    final k = keys.toSet().toList()..sort();
    if (listEquals(k, _keys)) return;
    _keys = k;
    _req();
  }

  /// Sends a frame now, or once the relay is open. True when it went out now.
  bool publish(String frame) {
    final ws = _ws;
    if (ws == null) {
      _queue.add(frame);
      if (_queue.length > 50) _queue.removeAt(0);
      return false;
    }
    ws.send(frame);
    return true;
  }

  void _onMessage(dynamic data) {
    List m;
    try {
      m = jsonDecode('$data') as List;
    } catch (_) {
      return;
    }
    if (m.isEmpty) return;
    if (m[0] == 'EVENT' && m.length >= 3 && m[2] is Map) {
      unawaited(link.onEvent(m[2] as Map));
    } else if (m[0] == 'OK' && m.length >= 4 && m[2] != true) {
      link.log('[sites] relay $url refused an event: ${m[3]}');
    } else if (m[0] == 'NOTICE' || m[0] == 'CLOSED') {
      link.log('[sites] relay $url: $m');
    }
  }

  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    await _ws?.close();
    _ws = null;
  }
}

/// A relay over dart:io's WebSocket.
class IoRelaySocket implements RelaySocket {
  IoRelaySocket._(this._ws);
  final WebSocket _ws;
  static Future<RelaySocket> open(String url) async {
    final ws = await WebSocket.connect(url).timeout(const Duration(seconds: 20));
    ws.pingInterval = const Duration(seconds: 30);
    return IoRelaySocket._(ws);
  }

  @override
  Stream<dynamic> get messages => _ws;
  @override
  void send(String text) => _ws.add(text);
  @override
  Future<void> close() => _ws.close();
}

/// Whether every string of the pairing screens keeps out of default mode's forbidden words.
List<String> siteLinkForbidden() => [for (final w in SiteLinkWords.all()) ...forbiddenIn(w)];
