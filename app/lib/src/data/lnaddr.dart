import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'name_key.dart';
import 'name_stock.dart';
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
/// the service holds open until a payer asks something. A wallet that is not open has no link: a
/// Lightning payer is told it is offline.
///
/// A Sequentia wallet paying the name is never stuck on that: the wallet leaves a stock of receive
/// codes with the service (name_stock.dart), each at an address of its own within what a restore
/// finds, each signed by the name's key ([signCode]). The service hands each out once; the payer's
/// wallet checks the signature against the key published beside the name and refuses a code that
/// fails, so a service broken into can withhold codes but never hand out an address of its own. The
/// payer also keeps the key it first paid a name at (`pins`) and refuses a code under another. When
/// the stock runs out the service hands out the most recent code again (`reused`); the payer then
/// pays it without its single-use Sequentia part.

final nameRe = RegExp(r'^[a-z0-9_-]{3,32}$');

/// The words the wallet says about its name: the contract's (sequentia-web-wallet
/// `docs/DEFAULT_MODE.md`, Receive). Default mode's never name the protocol; developer mode's
/// `dev*` lines do.
class NameWords {
  static const label = 'Your payment name';
  static const tip = 'Other wallets can pay you at this name, in any amount they choose. A Sequentia wallet can pay it '
      'while this wallet is closed; other wallets, while it is open.';
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
  // Receive, when the wallet has a name: the picture is the name.
  static const qrTip = 'Any asset, any amount, a new receive code of yours for each payer. A Sequentia wallet can pay '
      'this name while this wallet is closed; other wallets, while it is open.';
  static const public = 'Anyone who has your name can look it up and get a receive code of yours.';
  static const copyName = 'Copy name';
  static const copiedName = 'Name copied';
  static const showFull = 'Show full code';
  static const showName = 'Show name';
  static const fullTip = "For a wallet that can't look names up, or to pay without a connection. Each code is paid once; "
      'a new one shows when it is.';
  // What Send says when a name's code does not check out. Nothing is sent.
  static const unsigned = 'This name gave a receive code its wallet did not sign, so nothing was sent. '
      'Ask the recipient for their full code.';
  static const changed = 'This name now belongs to another wallet than the one you paid before, so nothing was sent. '
      'Ask the recipient for their full code.';
  static const busy = 'Too many lookups from your network. Try again in a minute.';
  static const devLabel = 'Lightning address';
  static const devTip = 'LNURL-pay (LUD-06, LUD-16) at this service: a payer picks the amount and this wallet makes the '
      'invoice on the Bitcoin ark while it is open. A Sequentia wallet paying it is given one of the signed receive codes '
      'this wallet leaves with the service.';

  static List<String> all() => [label, tip, none, choose, hint, save, cancel, saving, copy, copied, remove, removing,
        badName, taken, noWallet, offline, qrTip, public, copyName, copiedName, showFull, showName, fullTip, unsigned,
        changed, busy];
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
/// takes `.` and `+`; another service's names are read with them. `lightning:` in front (either
/// case) and BIP353's `₿name@domain` are read too.
({String name, String domain})? parseLnAddress(String text) {
  final m = RegExp(r'^\s*(?:lightning:|\u20bf)?([a-z0-9._+-]+)@([a-z0-9.-]+\.[a-z]{2,})\s*$', caseSensitive: false).firstMatch(text);
  if (m == null) return null;
  return (name: m.group(1)!.toLowerCase(), domain: m.group(2)!.toLowerCase());
}

/// What Receive's QR code holds for a name: `name@domain` in lower case and nothing else. Of the
/// spellings a payer's wallet may scan it is the one the most read as a payment name: LUD-16 gives
/// the name in lower case, `lightning:` in front of it is refused by some wallets' scanners (and in
/// upper case by more), and BIP353's `₿name@domain` needs a DNS record most wallets would look for
/// first. Ambra reads all three (lnaddr.js `nameQrText`).
String nameQrText(String address) => address.trim().toLowerCase();

/// A code's id: the first 16 bytes of its SHA-256, in hex. The stock names codes by it.
String codeId(String code) => hexOf(sha256.convert(utf8.encode(code)).bytes).substring(0, 32);

/// A receive code signed for `name@domain` by the name's key. The signature says only "this is a
/// receive code of this name at this service"; the same digest signs a code the open wallet gives for
/// one request ([id] the request's), so a payer checks both alike.
({String id, String code, String sig}) signCode(List<int> priv, String domain, String name, String code, [String? id]) {
  final i = id ?? codeId(code);
  return (id: i, code: code, sig: signWith(priv, signedDigest('code', domain, name, [i, code])));
}

bool verifyCode(String pubHex, String domain, String name, {required Object? id, required Object? code, required Object? sig}) {
  if (code is! String || code.isEmpty || id is! String || id.isEmpty || sig is! String) return false;
  try {
    final pub = unhex(pubHex), s = unhex(sig);
    if (pub.length != 32 || s.length != 64) return false;
    return schnorrVerify(pub, signedDigest('code', domain, name, [id, code]), s);
  } catch (_) {
    return false;
  }
}

/// When a code's single-use Sequentia part lapses (seconds), or null when it has none or says none.
int? requestUntil(String code) {
  PayCode? c;
  try {
    c = PayCode.read(code);
  } catch (_) {}
  final seq = c?.sequentia;
  if (seq == null) return null;
  final short = readShortRequest(seq);
  final u = short != null ? short.request['until'] : libraryRequest(seq)?['until'];
  return u is int ? u : (u is num ? u.toInt() : null);
}

/// How long before its Sequentia part lapses a payer still pays it there.
const payMarginS = 600;

/// The key a payer's wallet first paid each name at (persisted per wallet).
typedef NamePins = ({Future<String?> Function(String address) get, Future<void> Function(String address, String pub) set});

/// The LNURL-pay URL of `name@domain` (LUD-16).
String lnurlpUrl(String name, String domain) => 'https://$domain/.well-known/lnurlp/$name';

/// What a payment to a name pays: our domain's name, its receive code ([code], any asset, paid as
/// any code); another domain's, BTC only, an invoice of exactly [msat] ([invoice]).
class LnAddressTarget {
  const LnAddressTarget({this.code, this.invoice, this.fresh = false, this.reused = false});
  final String? code;
  final String? invoice;
  final bool fresh;
  final bool reused;
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
    throw LnAddressError('${j['reason'] ?? 'The address refused the payment.'}', status: r.statusCode);
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
  NamePins? pins,
  int Function()? nowS,
}) async {
  final a = parseLnAddress(text);
  if (a == null) throw const LnAddressError('not a payment name');
  final c = client ?? http.Client();
  if (domain != null && a.domain == domain.toLowerCase()) {
    if (nameProblem(a.name) != null) throw const LnAddressError(NameWords.noWallet);
    Map<String, dynamic> j;
    try {
      j = await _getJson(c, Uri.parse('$base/lnaddr/${a.name}'), timeout);
    } on LnAddressError catch (e) {
      if (e.status == 429) throw const LnAddressError(NameWords.busy);
      rethrow;
    }
    final code = j['code'];
    if (code is! String || code.isEmpty) throw const LnAddressError(NameWords.noWallet);
    // The name key's signature over the name, the domain and the code, and the key the payer paid
    // the name at before: anything else is refused and nothing is sent.
    final addr = '${a.name}@${a.domain}';
    final pub = '${j['pubkey'] ?? ''}'.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pub) || !verifyCode(pub, a.domain, a.name, id: j['id'], code: code, sig: j['sig'])) {
      throw const LnAddressError(NameWords.unsigned);
    }
    String? pinned;
    try {
      pinned = pins == null ? null : await pins.get(addr);
    } catch (_) {}
    if (pinned != null && pinned != pub) throw const LnAddressError(NameWords.changed);
    PayCode? pc;
    try {
      pc = PayCode.read(code);
    } catch (_) {}
    if (pc == null || (pc.address == null && pc.ark == null && pc.sequentia == null)) {
      throw const LnAddressError(NameWords.unsigned);
    }
    if (pinned == null && pins != null) {
      try {
        await pins.set(addr, pub);
      } catch (_) {}
    }
    final reused = j['reused'] == true;
    final until = requestUntil(code);
    final now = nowS != null ? nowS() : DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final stale = pc.sequentia != null && (reused || (until != null && until - now < payMarginS));
    if (stale && pc.address == null) throw const LnAddressError(NameWords.offline);
    // Without its single-use part: what is left of the signed code, rebuilt from its own parts.
    final out = stale ? PayCode(address: pc.address, ark: pc.ark).build() : code;
    return LnAddressTarget(code: out, fresh: j['fresh'] == true && !reused, reused: reused);
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
/// The stock (name_stock.dart), left out by a wallet that keeps none:
///   [stockCode]  a receive code of the wallet's own at address `index`, with a new Sequentia part
///                and ark address and no amount, or null when none can be made now
///   [nextUnused] the first address index neither chain has seen paid
///   [shownIndex] the index of the address Receive shows, or null
///   [loadStock]/[saveStock] the stock's record, per wallet
/// With a stock, a code the service asks for while the wallet is open is made the same way.
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
    this.stockCode,
    this.nextUnused,
    this.shownIndex,
    this.loadStock,
    this.saveStock,
    this.stockSize = defaultStockSize,
    this.topUpEvery = const Duration(seconds: 15),
  })  : _client = client ?? http.Client.new,
        _now = now ?? DateTime.now;

  final Future<String?> Function(int index)? stockCode;
  final int Function()? nextUnused;
  final int? Function()? shownIndex;
  final Future<String?> Function()? loadStock;
  final Future<void> Function(String? json)? saveStock;
  final int stockSize;
  final Duration topUpEvery;

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
  Future<int?>? _topping;
  DateTime _toppedAt = DateTime.fromMillisecondsSinceEpoch(0);
  ({String? name, Map<String, StockCode> mine, List<int> handed})? _stock;

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

  /// The stock this wallet made for its name: its codes (id -> index, lapse) and the indices
  /// handed out, most recent last.
  Future<({String? name, Map<String, StockCode> mine, List<int> handed})> _stockRec() async {
    var r = _stock;
    if (r == null && loadStock != null) {
      try {
        final j = jsonDecode(await loadStock!() ?? 'null');
        if (j is Map && j['mine'] is Map && j['handed'] is List) {
          r = (
            name: j['name'] as String?,
            mine: {
              for (final e in (j['mine'] as Map).entries)
                if (e.value is Map && (e.value as Map)['index'] is int)
                  '${e.key}': (index: (e.value as Map)['index'] as int, until: (e.value as Map)['until'] as int?)
            },
            handed: (j['handed'] as List).whereType<int>().toList(),
          );
        }
      } catch (_) {}
    }
    if (r == null || r.name != _name) r = (name: _name, mine: <String, StockCode>{}, handed: <int>[]);
    return _stock = r;
  }

  Future<void> _keepStock(({String? name, Map<String, StockCode> mine, List<int> handed}) r) async {
    if (r.handed.length > handedKeep) r.handed.removeRange(0, r.handed.length - handedKeep);
    _stock = r;
    try {
      await saveStock?.call(jsonEncode({
        'name': r.name,
        'mine': {for (final e in r.mine.entries) e.key: {'index': e.value.index, 'until': e.value.until}},
        'handed': r.handed,
      }));
    } catch (_) {}
  }

  /// The stock as kept now (for tests and the developer view).
  ({String? name, Map<String, StockCode> mine, List<int> handed})? get stock => _stock;

  /// New codes at addresses the stock may use, signed.
  Future<List<({int index, int? until, ({String id, String code, String sig}) signed})>> _makeCodes(
      int count, ({String? name, Map<String, StockCode> mine, List<int> handed}) rec, ({List<int> priv, String pub}) k, String n) async {
    final held = [...rec.mine.values.map((c) => c.index), shownIndex?.call()];
    final out = <({int index, int? until, ({String id, String code, String sig}) signed})>[];
    for (final index in pickStockIndices(count, nextUnused: nextUnused?.call() ?? 0, held: held, handed: rec.handed)) {
      final c = await stockCode!(index);
      if (c == null || c.isEmpty) continue;
      out.add((index: index, until: requestUntil(c), signed: signCode(k.priv, domain, n, c)));
    }
    return out;
  }

  Future<Map<String, dynamic>> _stockPost(({List<int> priv, String pub}) k, String n, List<({String id, String code, String sig})> add, List<String> drop) {
    final t = _ts();
    return _post('stock', {
      'name': n,
      'ts': t,
      'add': [for (final a in add) {'id': a.id, 'code': a.code, 'sig': a.sig}],
      'drop': drop,
      'sig': signWith(k.priv, signedDigest('stock', domain, n, [t, add.map((a) => a.id).join(','), drop.join(',')])),
    });
  }

  /// Fills the stock up to [stockSize], replacing codes near their lapse. [held]: the ids the
  /// service holds, when the caller has them. -> the number held after, or null when not run.
  Future<int?> topUp([List<String>? held]) {
    if (stockCode == null || _name == null) return Future.value(null);
    final running = _topping;
    if (running != null) return running;
    final f = _topUp(held).catchError((Object e) {
      log?.call('[lnaddr] stock: $e');
      return null;
    }).whenComplete(() => _topping = null);
    return _topping = f;
  }

  Future<int?> _topUp(List<String>? held) async {
    final k = key();
    final n = _name;
    if (k == null || n == null) return null;
    final rec = await _stockRec();
    held ??= ((await _stockPost(k, n, const [], const []))['held'] as List? ?? const []).map((x) => '$x').toList();
    final plan = planTopUp(mine: rec.mine, held: held, nowS: _ts(), size: stockSize);
    for (final id in plan.served) {
      rec.handed.add(rec.mine[id]!.index);
      rec.mine.remove(id);
    }
    for (final id in plan.drop) {
      rec.mine.remove(id);
    }
    final made = plan.make > 0 ? await _makeCodes(plan.make, rec, k, n) : const <({int index, int? until, ({String id, String code, String sig}) signed})>[];
    if (n != _name) return null;
    await _keepStock(rec);
    if (made.isEmpty && plan.drop.isEmpty) return held.length;
    final j = await _stockPost(k, n, [for (final m in made) m.signed], plan.drop);
    for (final m in made) {
      rec.mine[m.signed.id] = (index: m.index, until: m.until);
    }
    await _keepStock(rec);
    _toppedAt = _now();
    return (j['held'] as List? ?? const []).length;
  }

  Future<String> register(String wanted) async {
    final n = wanted.trim().toLowerCase();
    final p = nameProblem(n);
    if (p != null) throw LnAddressError(p);
    final k = _keyOrThrow(), t = _ts();
    await _post('register', {'name': n, 'pubkey': k.pub, 'ts': t, 'sig': signWith(k.priv, signedDigest('register', domain, n, [k.pub, t]))});
    await _keep(n);
    start();
    unawaited(topUp());
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
        String c;
        if (stockCode != null) {
          final rec = await _stockRec();
          final made = await _makeCodes(1, rec, k, n);
          if (made.isEmpty) throw StateError('no code');
          c = made.first.signed.code;
          rec.handed.add(made.first.index);
          await _keepStock(rec);
        } else {
          c = await code();
        }
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
        // The stock, topped up while the wallet is open: at most every [topUpEvery].
        final held = j['held'];
        if (held is List && stockCode != null && _now().difference(_toppedAt) >= topUpEvery) {
          final ids = held.map((x) => '$x').toList();
          final rec = await _stockRec();
          final plan = planTopUp(mine: rec.mine, held: ids, nowS: _ts(), size: stockSize);
          if (plan.make > 0 || plan.drop.isNotEmpty || plan.served.isNotEmpty) {
            _toppedAt = _now();
            unawaited(topUp(ids));
          }
        }
      }
    } finally {
      _running = false;
    }
  }

  void start() {
    _stopped = false;
    if (!_running && _name != null) {
      unawaited(_loop());
      unawaited(topUp());
    }
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
