import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'name_key.dart';
import 'pay_code.dart';

/// A wallet's payment name: `name@sequentiatestnet.com`, a Lightning address (LNURL-pay, LUD-06 and
/// LUD-16) that any Lightning wallet pays in an amount it chooses, and that a Sequentia wallet pays
/// in any asset. The web wallet's `lnaddr.js`, in the same words and with the same signatures, so a
/// name is the same name in every Sequentia wallet of its phrase; the service is the web wallet's
/// (`tooling/lsp/lnaddr.mjs` in sequentia-web-wallet).
///
/// A Lightning wallet pays the name over LNURL-pay: the payer picks the amount, then the service
/// asks the recipient's open wallet for an invoice of the Bitcoin ark for that amount and hands it
/// back. A Sequentia wallet asks the service for the name's receive code (`GET /lnaddr/<name>`) and
/// pays it as any code. Everything the wallet tells the service is signed with its name key
/// ([nameKey], BIP340): registering, releasing, waiting for requests and each answer. Each message
/// names the service's domain, and an answer names the request it answers.
///
/// While the wallet holds a name it keeps one link with the service ([LnAddress.start]): a request
/// the service holds open until a payer asks something. A wallet that is not open has no link, and a
/// payer is told it is offline.

final nameRe = RegExp(r'^[a-z0-9_-]{3,32}$');

/// The words the wallet says about its name: the contract's (sequentia-web-wallet
/// `docs/DEFAULT_MODE.md`, Receive). Default mode's never name the protocol; developer mode's
/// `dev*` lines do.
class NameWords {
  static const label = 'Your payment name';
  static const tip = 'Other wallets can pay you at this name, in any amount they choose, while this wallet is open.';
  static const none = 'Choose a name other wallets can pay you at, in any amount they choose.';
  static const choose = 'Choose a name';
  static const hint = 'yourname';
  static const save = 'Save';
  static const cancel = 'Cancel';
  static const saving = 'Saving…';
  static const copy = 'Copy';
  static const copied = 'Copied';
  static const remove = 'Remove name';
  static const removing = 'Removing…';
  static const badName = 'A name has 3 to 32 characters: lowercase letters, digits, - and _.';
  static const taken = 'That name is taken. Choose another.';
  static const noWallet = 'No wallet goes by that name.';
  static const offline = "The recipient's wallet is offline. Try again when it is open.";
  static const devLabel = 'Lightning address';
  static const devTip = 'LNURL-pay (LUD-06, LUD-16) at this service: a payer picks the amount and this wallet makes the '
      'invoice on the Bitcoin ark while it is open. A Sequentia wallet paying it is given a new receive code.';

  static List<String> all() => [label, tip, none, choose, hint, save, cancel, saving, copy, copied, remove, removing,
        badName, taken, noWallet, offline];
}

/// Why [name] can't be a name, or null.
String? nameProblem(String name) => nameRe.hasMatch(name) ? null : NameWords.badName;

/// The digest a message to the service signs: its action, the service's domain, the name and the
/// action's own fields, each on its own line.
List<int> signedDigest(String action, String domain, String name, [List<Object?> fields = const []]) {
  final parts = ['sequentia-lnaddr/1', action, domain, name, ...fields.map((f) => '${f ?? ''}')];
  if (parts.any((p) => p.contains('\n') || p.contains('\r'))) throw ArgumentError('a signed field holds a line break');
  return sha256.convert(utf8.encode(parts.join('\n'))).bytes;
}

String signWith(List<int> priv, List<int> digest) => hexOf(schnorrSign(priv, digest));

/// `name@domain` as LUD-16 writes it, or null for anything else. The user part of LUD-16 also
/// takes `.` and `+`; another service's names are read with them.
({String name, String domain})? parseLnAddress(String text) {
  final m = RegExp(r'^\s*(?:lightning:)?([a-z0-9._+-]+)@([a-z0-9.-]+\.[a-z]{2,})\s*$', caseSensitive: false).firstMatch(text);
  if (m == null) return null;
  return (name: m.group(1)!.toLowerCase(), domain: m.group(2)!.toLowerCase());
}

/// The LNURL-pay URL of `name@domain` (LUD-16).
String lnurlpUrl(String name, String domain) => 'https://$domain/.well-known/lnurlp/$name';

/// What a payment to a name pays: our domain's name, its receive code ([code], any asset, paid as
/// any code); another domain's, BTC only, an invoice of exactly [msat] ([invoice]).
class LnAddressTarget {
  const LnAddressTarget({this.code, this.invoice});
  final String? code;
  final String? invoice;
}

Future<Map<String, dynamic>> _getJson(http.Client c, Uri url, Duration timeout) async {
  http.Response r;
  try {
    r = await c.get(url, headers: {'accept': 'application/json'}).timeout(timeout);
  } catch (_) {
    throw const LnAddressError('The address could not be reached. Check your connection and try again.');
  }
  Object? j;
  try {
    j = jsonDecode(r.body);
  } catch (_) {}
  if (j is Map && '${j['status'] ?? ''}'.toUpperCase() == 'ERROR') {
    throw LnAddressError('${j['reason'] ?? 'The address refused the payment.'}');
  }
  if (r.statusCode < 200 || r.statusCode >= 300 || j is! Map) {
    throw const LnAddressError('The address could not be reached. Check your connection and try again.');
  }
  return Map<String, dynamic>.from(j);
}

/// A sentence the wallet shows as it is.
class LnAddressError implements Exception {
  const LnAddressError(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

String _btc(BigInt msat) {
  final v = msat ~/ BigInt.from(1000);
  final s = '${v ~/ BigInt.from(100000000)}.${(v % BigInt.from(100000000)).toString().padLeft(8, '0')}';
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// What a payment to the name [text] pays (lnaddr.js `resolveLnAddress`). [decodeMsat] reads an
/// invoice's amount and throws on one that is not a Bitcoin invoice.
Future<LnAddressTarget> resolveLnAddress({
  required String text,
  required bool btc,
  BigInt? msat,
  required String? domain,
  required String base,
  required BigInt Function(String invoice) decodeMsat,
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final a = parseLnAddress(text);
  if (a == null) throw const LnAddressError('not a payment name');
  final c = client ?? http.Client();
  if (domain != null && a.domain == domain.toLowerCase()) {
    if (nameProblem(a.name) != null) throw const LnAddressError(NameWords.noWallet);
    final j = await _getJson(c, Uri.parse('$base/lnaddr/${a.name}'), timeout);
    final code = j['code'];
    if (code is! String || code.isEmpty) throw const LnAddressError(NameWords.noWallet);
    return LnAddressTarget(code: code);
  }
  if (!btc) throw const LnAddressError('This address takes BTC only.');
  if (msat == null || msat <= BigInt.zero) throw const LnAddressError('Enter an amount.');
  final p = await _getJson(c, Uri.parse(lnurlpUrl(Uri.encodeComponent(a.name), a.domain)), timeout);
  if (p['tag'] != 'payRequest' || p['callback'] is! String) throw const LnAddressError('This address does not take payments.');
  final cb = Uri.tryParse(p['callback'] as String);
  if (cb == null || cb.scheme != 'https') throw const LnAddressError('This address does not take payments.');
  final min = BigInt.tryParse('${p['minSendable'] ?? 1}') ?? BigInt.one;
  final max = BigInt.tryParse('${p['maxSendable'] ?? 0}') ?? BigInt.zero;
  if (msat < min || (max > BigInt.zero && msat > max)) {
    throw LnAddressError('This address takes between ${_btc(min + BigInt.from(999))} and ${_btc(max)} BTC.');
  }
  final r = await _getJson(c, cb.replace(queryParameters: {...cb.queryParameters, 'amount': '$msat'}), timeout);
  final pr = '${r['pr'] ?? ''}';
  BigInt got;
  try {
    got = decodeMsat(pr);
  } on FormatException catch (e) {
    if (e.message.contains('not a Bitcoin')) throw const LnAddressError('The address answered with an invoice that is not for BTC.');
    throw const LnAddressError('The address answered with an invoice that does not read.');
  } catch (_) {
    throw const LnAddressError('The address answered with an invoice that does not read.');
  }
  if (got != msat) throw const LnAddressError('The address answered with an invoice for another amount.');
  return LnAddressTarget(invoice: pr);
}

/// The wallet's side of its name (lnaddr.js `mountLnAddress`): registering and releasing it, and
/// while it holds one, the link that answers the service's requests.
///   [base]     the service's root (the node's `/lsp`)
///   [domain]   the names' domain
///   [key]      the name key, or null while the wallet is locked
///   [invoice]  a Bitcoin invoice of exactly the msat asked (the Bitcoin ark's)
///   [code]     a receive code of the wallet's own, new for the payer
///   [limits]   the sats the wallet takes now, or null while it can't take any
///   [load]/[save] the name, per wallet
class LnAddress {
  LnAddress({
    required this.base,
    required this.domain,
    required this.key,
    required this.invoice,
    required this.code,
    required this.limits,
    required this.load,
    required this.save,
    http.Client Function()? client,
    this.log,
    this.onChange,
    this.retry = const Duration(seconds: 5),
    DateTime Function()? now,
  })  : _client = client ?? http.Client.new,
        _now = now ?? DateTime.now;

  final String base;
  final String domain;
  final ({List<int> priv, String pub})? Function() key;
  final Future<String> Function(BigInt msat) invoice;
  final Future<String> Function() code;
  final ({BigInt min, BigInt max})? Function() limits;
  final Future<String?> Function() load;
  final Future<void> Function(String? name) save;
  final http.Client Function() _client;
  final void Function(String)? log;
  final void Function()? onChange;
  final Duration retry;
  final DateTime Function() _now;

  String? _name;
  bool _running = false, _stopped = true;
  http.Client? _waiting;

  String? get name => _name;
  String? get address => _name == null ? null : '$_name@$domain';
  bool get running => _running;

  /// The LNURL-pay a receive code carries for the name, or null without one.
  String? get lnurl => _name == null ? null : lnurlpUrl(_name!, domain);

  int _ts() => _now().millisecondsSinceEpoch ~/ 1000;

  ({List<int> priv, String pub}) _keyOrThrow() {
    final k = key();
    if (k == null) throw const LnAddressError('Your wallet is locked; unlock it and try again.');
    return k;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body, {http.Client? via}) async {
    final c = via ?? _client();
    http.Response r;
    try {
      r = await c.post(Uri.parse('$base/lnaddr/-/$path'), headers: {'content-type': 'application/json'}, body: jsonEncode(body));
    } catch (_) {
      throw const LnAddressError('The name could not be saved. Check your connection and try again.');
    } finally {
      if (via == null) c.close();
    }
    Object? j;
    try {
      j = jsonDecode(r.body);
    } catch (_) {}
    if (r.statusCode < 200 || r.statusCode >= 300 || j is! Map || j['ok'] == false) {
      throw LnAddressError(j is Map && j['error'] is String ? j['error'] as String : 'The name could not be saved. Check your connection and try again.',
          status: r.statusCode);
    }
    return Map<String, dynamic>.from(j);
  }

  Future<void> _keep(String? n) async {
    _name = n;
    try {
      await save(n);
    } catch (_) {}
    onChange?.call();
  }

  /// The name kept for this wallet, then the one its key holds at the service (a wallet restored
  /// elsewhere finds it).
  Future<String?> recover() async {
    try {
      _name ??= await load();
    } catch (_) {}
    final k = key();
    if (k == null) return _name;
    final c = _client();
    try {
      final r = await c.get(Uri.parse('$base/lnaddr/-/mine?pubkey=${k.pub}'));
      final j = jsonDecode(r.body);
      if (r.statusCode == 200 && j is Map && j['ok'] == true) {
        final n = j['name'] is String ? j['name'] as String : null;
        if (n != _name) await _keep(n);
      }
    } catch (_) {
    } finally {
      c.close();
    }
    onChange?.call();
    return _name;
  }

  Future<String> register(String wanted) async {
    final n = wanted.trim().toLowerCase();
    final p = nameProblem(n);
    if (p != null) throw LnAddressError(p);
    final k = _keyOrThrow(), t = _ts();
    await _post('register', {'name': n, 'pubkey': k.pub, 'ts': t, 'sig': signWith(k.priv, signedDigest('register', domain, n, [k.pub, t]))});
    await _keep(n);
    start();
    return n;
  }

  Future<void> release() async {
    final n = _name;
    if (n == null) return;
    final k = _keyOrThrow(), t = _ts();
    await _post('release', {'name': n, 'ts': t, 'sig': signWith(k.priv, signedDigest('release', domain, n, [t]))});
    await _keep(null);
    stop();
  }

  Future<void> _answer(String n, ({List<int> priv, String pub}) k, Map req) async {
    final id = '${req['id']}';
    Map<String, Object?> body;
    try {
      if (req['kind'] == 'invoice') {
        final pr = await invoice(BigInt.parse('${req['msat']}'));
        body = {'name': n, 'id': id, 'pr': pr, 'sig': signWith(k.priv, signedDigest('invoice', domain, n, [id, pr]))};
      } else if (req['kind'] == 'code') {
        final c = await code();
        body = {'name': n, 'id': id, 'code': c, 'sig': signWith(k.priv, signedDigest('code', domain, n, [id, c]))};
      } else {
        return;
      }
    } catch (e) {
      log?.call('[lnaddr] request ${req['kind']} not answered: $e');
      body = {'name': n, 'id': id, 'refused': true, 'sig': signWith(k.priv, signedDigest('refuse', domain, n, [id]))};
    }
    try {
      await _post('answer', body);
    } catch (e) {
      log?.call('[lnaddr] answer: $e');
    }
  }

  Future<void> _loop() async {
    _running = true;
    final seen = <String>{};
    try {
      while (!_stopped && _name != null) {
        final k = key(), lim = limits();
        if (k == null || lim == null) {
          await Future<void>.delayed(retry);
          continue;
        }
        final n = _name!, t = _ts();
        final c = _waiting = _client();
        Map<String, dynamic> j;
        try {
          j = await _post('wait', {
            'name': n, 'ts': t, 'min_sat': '${lim.min}', 'max_sat': '${lim.max}',
            'sig': signWith(k.priv, signedDigest('wait', domain, n, [t, lim.min, lim.max])),
          }, via: c);
        } catch (e) {
          if (_stopped) break;
          // The service no longer knows the name under this key: it was released elsewhere.
          if (e is LnAddressError && (e.status == 404 || e.status == 403)) {
            await _keep(null);
            break;
          }
          log?.call('[lnaddr] wait: $e');
          await Future<void>.delayed(retry);
          continue;
        } finally {
          c.close();
          _waiting = null;
        }
        for (final req in (j['requests'] as List? ?? const []).whereType<Map>()) {
          final id = '${req['id']}';
          if (!seen.add(id)) continue;
          if (seen.length > 200) seen.remove(seen.first);
          unawaited(_answer(n, k, req));
        }
      }
    } finally {
      _running = false;
    }
  }

  void start() {
    _stopped = false;
    if (!_running && _name != null) unawaited(_loop());
  }

  void stop() {
    _stopped = true;
    try {
      _waiting?.close();
    } catch (_) {}
  }
}

/// A new receive code for a payer of the name: the address, the ark's and the receive request.
String nameCode({required String address, String? ark, String? sequentia}) =>
    PayCode(address: address, ark: ark, sequentia: sequentia).build();
