/// The wallet's Bitcoin Lightning, as the user-mode composer's BTC trades ask for it (the
/// `btc` of [UserTradeDeps]; the calls are the ones `user_trade_btc.dart` makes). It drives the
/// wallet's own hosted Bitcoin node through the service's API, the node keyless and every
/// signature the device's. The Dart twin of the web wallet's `btc-lightning.js`: change them
/// together.
///
/// The invoice it makes for a trade is a hold under a hash of the wallet's own: the preimage is
/// drawn here, kept in the wallet's store before anything is asked of the node, and given to the
/// node only to settle a payment already held there for the whole amount. Neither the hosted node
/// nor the service hosting it learns it first, so neither can hand it to the other side of a trade
/// before that side has paid. A payment out is the node's `pay`, its routing fee capped at the one
/// the ticket showed, and is called failed only when the node says no attempt is left in flight.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as c;

import 'lsp_client.dart';

BigInt _big(Object? v) => v is BigInt ? v : (BigInt.tryParse('${v ?? 0}') ?? BigInt.zero);
String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A payment held under a hold is settled only while its HTLC has at least this many blocks left.
const int kSettleMarginBlocks = 3;

/// How long a hold's invoice runs.
const int kHoldExpirySeconds = 3600;

// ---------------------------------------------------------------------------------------------
// BOLT11, as the wallet reads a Bitcoin invoice: its network, amount, hash, final delta, when it
// was made and how long it runs. The node stays the authority; this lets the wallet refuse an
// invoice that cannot be the one it asked for before anything is sent.
// ---------------------------------------------------------------------------------------------

const String _cs = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

int _polymod(List<int> values) {
  const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final v in values) {
    final b = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if ((b >> i) & 1 == 1) chk ^= gen[i];
    }
  }
  return chk;
}

List<int> _expand(String hrp) => [...hrp.codeUnits.map((c) => c >> 5), 0, ...hrp.codeUnits.map((c) => c & 31)];

/// A Bitcoin invoice read: `{sats, msat, payment_hash, expires_at, min_final_cltv}`; throws on an
/// invoice that is not a whole, checksummed Bitcoin invoice with an amount and a hash.
Map<String, dynamic> decodeBtcInvoice(String invoice) {
  var s = invoice.trim().toLowerCase();
  if (s.startsWith('lightning:')) s = s.substring('lightning:'.length);
  final sep = s.lastIndexOf('1');
  if (sep < 1) throw const FormatException('not a BOLT11 invoice');
  final hrp = s.substring(0, sep);
  final vals = [for (final ch in s.substring(sep + 1).split('')) _cs.indexOf(ch)];
  if (vals.any((v) => v < 0) || vals.length < 7 + 104 + 6) throw const FormatException('not a BOLT11 invoice');
  if (_polymod([..._expand(hrp), ...vals]) != 1) throw const FormatException('the invoice checksum does not verify');
  final m = RegExp(r'^ln(bcrt|tbs|bc|tb)(\d*)([munp]?)$').firstMatch(hrp);
  if (m == null) throw const FormatException('the invoice is not a Bitcoin invoice');
  if ((m.group(2) ?? '').isEmpty) throw const FormatException('the invoice names no amount');
  final n = BigInt.parse(m.group(2)!);
  final BigInt msat;
  switch (m.group(3)) {
    case 'm':
      msat = n * BigInt.from(100000000);
    case 'u':
      msat = n * BigInt.from(100000);
    case 'n':
      msat = n * BigInt.from(100);
    case 'p':
      if (n % BigInt.from(10) != BigInt.zero) throw const FormatException('the invoice amount is below a millisatoshi');
      msat = n ~/ BigInt.from(10);
    default:
      msat = n * BigInt.from(100000000000);
  }
  var ts = 0;
  for (var i = 0; i < 7; i++) {
    ts = ts * 32 + vals[i];
  }
  final end = vals.length - 104 - 6;
  String? hash;
  int? cltv, expiry;
  var i = 7;
  while (i + 3 <= end) {
    final type = vals[i], len = (vals[i + 1] << 5) | vals[i + 2];
    i += 3;
    if (i + len > end) break;
    final data = vals.sublist(i, i + len);
    int asInt() => data.fold(0, (a, g) => a * 32 + g);
    if (type == 1 && len == 52 && hash == null) {
      var acc = 0, bits = 0;
      final out = <int>[];
      for (final g in data) {
        acc = ((acc << 5) | g) & 0xffff;
        bits += 5;
        if (bits >= 8) {
          bits -= 8;
          if (out.length < 32) out.add((acc >> bits) & 0xff);
        }
      }
      hash = _hex(out);
    }
    if (type == 24 && cltv == null) cltv = asInt();
    if (type == 6 && expiry == null) expiry = asInt();
    i += len;
  }
  if (hash == null) throw const FormatException('the invoice carries no payment hash');
  return {
    'sats': msat ~/ BigInt.from(1000),
    'msat': msat,
    'payment_hash': hash,
    'expires_at': ts + (expiry ?? 3600),
    'min_final_cltv': cltv ?? 18,
  };
}

// ---------------------------------------------------------------------------------------------
// What the engine asks of a Bitcoin Lightning wallet.
// ---------------------------------------------------------------------------------------------

abstract class BtcLightning {
  /// Sats the wallet's channels can send now.
  Future<BigInt> balance();

  /// An invoice for `sats` under a new hash of the wallet's: `{invoice, payment_hash, expires_at}`.
  Future<Map<String, dynamic>> invoice({required BigInt sats, String description = 'trade'});

  /// `{sats, msat, payment_hash, expires_at, min_final_cltv}`.
  Future<Map<String, dynamic>> decode(String invoice);

  /// An invoice of the wallet's: `{status: paid|unpaid|expired|unknown, preimage?}`.
  Future<Map<String, dynamic>> invoiceStatus(String hash);
  Future<void> cancelInvoice(String hash);

  /// `{state: complete, preimage} | {state: pending} | {state: failed, reason}`.
  Future<Map<String, dynamic>> pay({required String invoice, BigInt? maxFeeSats, int? maxDelay});

  /// `{state: none|pending|complete|failed, preimage?}`.
  Future<Map<String, dynamic>> payStatus(String hash);

  /// The route a payment of the invoice would take now: its fee in sats and its whole lock in
  /// blocks; null when the wallet cannot say (then the invoice's final delta is the bound).
  Future<({BigInt fee, int delay})?> payRoute(String invoice);
}

/// The service's calls on the wallet's own node.
abstract class BtcLsp {
  Future<Map<String, dynamic>> invoice(Map<String, dynamic> body);
  Future<Map<String, dynamic>> invoiceStatus(String nodeKey, String hash);
  Future<void> settle(String nodeKey, String hash, String preimage);
  Future<Map<String, dynamic>> pay(Map<String, dynamic> body);
  Future<Map<String, dynamic>> payStatus(String nodeKey, String hash);
  Future<Map<String, dynamic>> payQuote(String nodeKey, String bolt11);
}

/// [BtcLsp] over [LspClient].
class LspBtcCalls implements BtcLsp {
  const LspBtcCalls();
  String _q(String nodeKey, String k, String v) => '?node=${Uri.encodeComponent(nodeKey)}&$k=${Uri.encodeComponent(v)}';
  @override
  Future<Map<String, dynamic>> invoice(Map<String, dynamic> body) => LspClient.call('/node/invoice', post: body);
  @override
  Future<Map<String, dynamic>> invoiceStatus(String nodeKey, String hash) =>
      LspClient.call('/node/invoice-status${_q(nodeKey, 'payment_hash', hash)}');
  @override
  Future<void> settle(String nodeKey, String hash, String preimage) =>
      LspClient.call('/node/settle', post: {'node_key': nodeKey, 'payment_hash': hash, 'preimage': preimage});
  @override
  Future<Map<String, dynamic>> pay(Map<String, dynamic> body) => LspClient.call('/node/pay', post: body, timeout: const Duration(seconds: 90));
  @override
  Future<Map<String, dynamic>> payStatus(String nodeKey, String hash) => LspClient.call('/node/pay-status${_q(nodeKey, 'payment_hash', hash)}');
  @override
  Future<Map<String, dynamic>> payQuote(String nodeKey, String bolt11) => LspClient.call('/node/pay-quote${_q(nodeKey, 'bolt11', bolt11)}');
}

/// The wallet's own hosted Bitcoin node as a [BtcLightning].
class HostedBtcLightning implements BtcLightning {
  HostedBtcLightning({
    required this.lsp,
    required this.nodeKey,
    required this.spendable,
    this.receivable,
    required this.read,
    required this.write,
    Random? random,
    int Function()? now,
    void Function(String)? log,
  }) : random = random ?? Random.secure(),
       now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       log = log ?? ((_) {});

  final BtcLsp lsp;

  /// The node's registry key, the node and its signer brought up first (cheap once up).
  final Future<String> Function() nodeKey;
  final Future<BigInt> Function() spendable;

  /// Sats the wallet's own channels can receive now; when given, a hold for more is refused before
  /// anything is drawn or asked.
  final Future<BigInt> Function()? receivable;

  /// The holds' store (one JSON object, hash -> record), kept per wallet.
  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  final Random random;
  final int Function() now;
  final void Function(String) log;

  Future<Map<String, dynamic>> _holds() async {
    try {
      final s = await read();
      return s == null ? {} : Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> _keep(String h, Map<String, dynamic> rec) async {
    final all = await _holds();
    all[h] = rec;
    await write(jsonEncode(all));
  }

  Map<String, dynamic> _read(String invoice) {
    final d = decodeBtcInvoice(invoice);
    return d;
  }

  @override
  Future<BigInt> balance() => spendable();

  @override
  Future<Map<String, dynamic>> invoice({required BigInt sats, String description = 'trade'}) async {
    if (receivable != null && await receivable!() < sats) throw Exception('the node cannot receive that much now');
    final pre = List<int>.generate(32, (_) => random.nextInt(256));
    final h = c.sha256.convert(pre).toString();
    // Kept before the node is asked: a hold whose preimage the wallet lost could never be settled.
    await _keep(h, {'preimage': _hex(pre), 'sats': '$sats', 'at': now()});
    final key = await nodeKey();
    final r = await lsp.invoice({
      'node_key': key,
      'amount': sats.toInt(),
      'payment_hash': h,
      'bolt11': true,
      'expiry': kHoldExpirySeconds,
      'description': description,
    });
    final b = r['bolt11'];
    if (b is! String || b.isEmpty) throw Exception('the node made no invoice for the hold');
    final d = _read(b);
    if (d['payment_hash'] != h || d['sats'] != sats) throw Exception('the node\'s invoice is not the hold asked for');
    await _keep(h, {...(await _holds())[h] as Map<String, dynamic>, 'invoice': b, 'expires_at': d['expires_at']});
    return {'invoice': b, 'payment_hash': h, 'expires_at': d['expires_at']};
  }

  @override
  Future<Map<String, dynamic>> decode(String invoice) async => _read(invoice);

  @override
  Future<Map<String, dynamic>> invoiceStatus(String hash) async {
    final all = await _holds();
    final rec = all[hash] == null ? null : Map<String, dynamic>.from(all[hash] as Map);
    if (rec == null) return {'status': 'unknown'};
    if (rec['settled'] == true) return {'status': 'paid', 'preimage': rec['preimage']};
    if (rec['cancelled'] == true) return {'status': 'expired'};
    final key = await nodeKey();
    final st = await lsp.invoiceStatus(key, hash);
    if (st['state'] == 'settled') {
      await _keep(hash, {...rec, 'settled': true});
      return {'status': 'paid', 'preimage': rec['preimage']};
    }
    if (st['state'] == 'accepted') {
      final whole = st['received_msat'] != null && _big(st['received_msat']) >= _big(rec['sats']) * BigInt.from(1000);
      final exp = st['htlc_expiry'], tip = st['btc_tip'];
      final room = exp is num && tip is num && exp - tip >= kSettleMarginBlocks;
      if (!whole || !room) {
        log('[btc lightning] a held payment is not settled: ${!whole ? 'it is short of the amount' : 'too close to its expiry'}');
        return {'status': 'unpaid'};
      }
      await lsp.settle(key, hash, '${rec['preimage']}');
      await _keep(hash, {...rec, 'settled': true});
      return {'status': 'paid', 'preimage': rec['preimage']};
    }
    if (st['state'] == 'cancelled') return {'status': 'expired'};
    final ex = rec['expires_at'];
    if (ex is num && now() / 1000 > ex) return {'status': 'expired'};
    if (st['state'] == 'unknown') {
      // The node forgot the hold (its plugin keeps holds in memory, and the node restarted): a
      // payment arriving now would be failed back, so the hold is registered again.
      try {
        await lsp.invoice({'node_key': key, 'amount': _big(rec['sats']).toInt(), 'payment_hash': hash});
      } catch (e) {
        log('[btc lightning] hold again: $e');
      }
    }
    return {'status': 'unpaid'};
  }

  /// A hold of a trade that will not happen is never settled.
  @override
  Future<void> cancelInvoice(String hash) async {
    final all = await _holds();
    final rec = all[hash];
    if (rec is Map && rec['settled'] != true) await _keep(hash, {...Map<String, dynamic>.from(rec), 'cancelled': true});
  }

  @override
  Future<Map<String, dynamic>> pay({required String invoice, BigInt? maxFeeSats, int? maxDelay}) async {
    final d = _read(invoice);
    final key = await nodeKey();
    Map<String, dynamic> r;
    try {
      r = await lsp.pay({
        'node_key': key,
        'bolt11': invoice,
        'wantHash': d['payment_hash'],
        'amount_msat': (d['msat'] as BigInt).toInt(),
        'min_final_cltv': d['min_final_cltv'],
        if (maxDelay != null && maxDelay > 0) 'max_cltv': maxDelay,
        'maxfee_msat': ((maxFeeSats ?? BigInt.zero) * BigInt.from(1000)).toInt(),
      });
    } on LspHttpException catch (e) {
      // Refused before anything was sent: a check of the invoice, or the device declining it.
      if (e.status == 400 || e.status == 403) return {'state': 'failed', 'reason': e.message};
      return payStatus('${d['payment_hash']}');
    } catch (_) {
      // Anything else may have left a payment in flight: the node's own record decides.
      return payStatus('${d['payment_hash']}');
    }
    if (r['paid'] == true && r['preimage'] is String) return {'state': 'complete', 'preimage': r['preimage']};
    return payStatus('${d['payment_hash']}');
  }

  @override
  Future<Map<String, dynamic>> payStatus(String hash) async {
    final key = await nodeKey();
    Map<String, dynamic> st;
    try {
      st = await lsp.payStatus(key, hash);
    } catch (e) {
      log('[btc lightning] pay status: $e');
      return {'state': 'pending'};
    }
    if (st['state'] == 'complete' && st['preimage'] is String) return {'state': 'complete', 'preimage': st['preimage']};
    if (st['state'] == 'failed') return {'state': 'failed', 'reason': 'no route paid it'};
    if (st['state'] == 'none') return {'state': 'none'};
    return {'state': 'pending'};
  }

  @override
  Future<({BigInt fee, int delay})?> payRoute(String invoice) async {
    final key = await nodeKey();
    final q = await lsp.payQuote(key, invoice);
    if (q['route_found'] != true || q['fee_msat'] == null) throw Exception('no route to the payee now');
    return (fee: (_big(q['fee_msat']) + BigInt.from(999)) ~/ BigInt.from(1000), delay: (q['delay'] as num).toInt());
  }
}
