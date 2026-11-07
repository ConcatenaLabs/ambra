import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as core;

/// Caches the last-known balances and history on disk so the UI shows them
/// instantly on launch (outdated, but not a blank loading screen) and then
/// refreshes in the background. Single-wallet, so the keys are not per-mnemonic.
class WalletCache {
  WalletCache._();
  static const _kBalances = 'ambra.cache.balances';
  static const _kTxs = 'ambra.cache.txs';
  static const _kBtc = 'ambra.cache.btcsats';

  /// Persist the last-known Bitcoin (testnet4) balance in sats, so a later
  /// testnet4-scan failure shows the last value (marked offline) instead of
  /// silently hiding the BTC row.
  static Future<void> saveBtc(String sats) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBtc, sats);
  }

  static Future<String?> loadBtc() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kBtc);
  }

  static Future<void> saveBalances(List<core.AssetBalance> b) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBalances, jsonEncode(b.map((e) => {'a': e.assetId, 'v': e.atoms}).toList()));
  }

  static Future<List<core.AssetBalance>?> loadBalances() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kBalances);
    if (s == null) return null;
    try {
      return (jsonDecode(s) as List)
          .map((m) => core.AssetBalance(assetId: m['a'] as String, atoms: m['v'] as String))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveTxs(List<core.TxRow> txs) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kTxs,
      jsonEncode(txs.map((t) => {
            'id': t.txid,
            'h': t.height,
            'ts': t.timestamp?.toString(),
            'k': t.kind,
            'f': t.fee.toString(),
            'fa': t.feeAsset,
            'd': t.deltas.map((d) => {'a': d.assetId, 'v': d.atoms}).toList(),
          }).toList()),
    );
  }

  static Future<List<core.TxRow>?> loadTxs() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kTxs);
    if (s == null) return null;
    try {
      return (jsonDecode(s) as List)
          .map((m) => core.TxRow(
                txid: m['id'] as String,
                height: m['h'] as int?,
                timestamp: m['ts'] == null ? null : BigInt.parse(m['ts'] as String),
                kind: m['k'] as String,
                fee: BigInt.parse(m['f'] as String),
                // Older cached rows predate fee_asset; fall back to '' (rendered as tSEQ).
                feeAsset: (m['fa'] as String?) ?? '',
                deltas: (m['d'] as List)
                    .map((d) => core.AssetDelta(assetId: d['a'] as String, atoms: d['v'] as String))
                    .toList(),
              ))
          .toList();
    } catch (_) {
      return null;
    }
  }

  // -- OpenAMP restricted-transfer tracker ------------------------------------
  // openampd exposes no per-holder history endpoint, so the wallet tracks its
  // OWN sent transfers locally (mirrors the web wallet's OAMP_XFERS localStorage
  // key) and re-derives confirmation + Bitcoin anchor depth from the explorer.
  static const _kOampXfers = 'ambra.oamp.transfers';

  static Future<List<OampTransfer>> loadOampTransfers() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kOampXfers);
    if (s == null) return const [];
    try {
      return (jsonDecode(s) as List).map((m) => OampTransfer.fromJson(m as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveOampTransfers(List<OampTransfer> xfers) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kOampXfers, jsonEncode(xfers.map((x) => x.toJson()).toList()));
  }

  /// Append one just-sent restricted transfer (confirmation is re-derived later).
  static Future<void> addOampTransfer(OampTransfer x) async {
    final list = List<OampTransfer>.from(await loadOampTransfers())..add(x);
    await saveOampTransfers(list);
  }

  // -- Lightning history (written by the LN pay/receive cards) -----------------
  // The LN send/receive cards persist their own records here; History only READS
  // this key, defensively, so the two never share code. Absent/empty => no rows.
  static const _kLnHistory = 'ambra.ln.history';

  static Future<List<Map<String, dynamic>>> loadLnHistory() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kLnHistory);
    if (s == null) return const [];
    try {
      final list = jsonDecode(s);
      if (list is! List) return const [];
      return [for (final e in list) if (e is Map<String, dynamic>) e];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveLnHistory(List<Map<String, dynamic>> entries) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLnHistory, jsonEncode(entries));
  }

  /// Append one Lightning pay/receive record, written by the LN cards. Shape
  /// mirrors what `_LnRow` (history_screen.dart) renders defensively: `kind`
  /// ('payment' outgoing; 'receive'/'received'/'invoice'/'settle' incoming),
  /// `ticker` + `atoms` + `precision` (preferred) or `amount_msat` (fallback),
  /// `description`, `time` (epoch millis). Extra fields (payment_hash, preimage,
  /// bolt11, destination) are carried along for future use; the reader ignores
  /// unknown keys.
  static Future<void> addLnHistory(Map<String, dynamic> entry) async {
    final list = List<Map<String, dynamic>>.from(await loadLnHistory())..add(entry);
    await saveLnHistory(list);
  }

  /// Records a payment the moment it leaves (or is first seen arriving), in the same list
  /// History's Payments card shows: `kind` 'payment' (out) or 'received' (in), `ticker`,
  /// `atoms`, `precision`, `time`, and `rail` ('btc' on the Bitcoin chain, 'ark', 'tree',
  /// 'address' (from the instant part out to an address), 'lightning'). One with `pending`
  /// true shows as pending until [settlePayment] clears it; `txid` and `chain` ('btc' or
  /// 'seq') let History look that up. An entry with a txid, or a `key`, already recorded is not
  /// added again.
  static Future<void> addPayment(Map<String, dynamic> entry) async {
    final list = List<Map<String, dynamic>>.from(await loadLnHistory());
    final txid = entry['txid'];
    if (txid != null && list.any((e) => e['txid'] == txid)) return;
    final key = entry['key'];
    if (key != null && list.any((e) => e['key'] == key)) return;
    list.add({'time': DateTime.now().millisecondsSinceEpoch, ...entry});
    await saveLnHistory(list);
  }

  /// Marks the payment of [txid] confirmed.
  static Future<void> settlePayment(String txid) async {
    final list = List<Map<String, dynamic>>.from(await loadLnHistory());
    var changed = false;
    for (final e in list) {
      if (e['txid'] == txid && e['pending'] == true) {
        e['pending'] = false;
        changed = true;
      }
    }
    if (changed) await saveLnHistory(list);
  }

  /// Settles the payment of [hash] (a Lightning payment its payee held): done when [paid],
  /// else marked come back (`returned`), so History says it was not paid.
  static Future<void> settleHeld(String hash, {required bool paid}) async {
    final list = List<Map<String, dynamic>>.from(await loadLnHistory());
    var changed = false;
    for (final e in list) {
      if (e['hash'] == hash && e['pending'] == true) {
        e['pending'] = false;
        if (!paid) e['returned'] = true;
        changed = true;
      }
    }
    if (changed) await saveLnHistory(list);
  }

  /// The payments to an address out of the tree this wallet asked for (address_payments.dart):
  /// entries with the library's `offboard` id, the `address`, the `asset` and a `stage`.
  static Future<List<Map<String, dynamic>>> addressPayments() async =>
      [for (final e in await loadLnHistory()) if (e['kind'] == 'payment' && e['offboard'] != null) e];

  /// Writes down where each payment to an address stands now ([stages]: id -> stage). One no
  /// longer 'pending' stops showing as pending. Answers whether anything changed.
  static Future<bool> setOffboardStages(Map<String, String> stages) async {
    final list = List<Map<String, dynamic>>.from(await loadLnHistory());
    var changed = false;
    for (final e in list) {
      final id = e['offboard'];
      if (id == null || !stages.containsKey('$id')) continue;
      final st = stages['$id']!;
      if (e['stage'] != st) {
        e['stage'] = st;
        e['pending'] = st == 'pending';
        changed = true;
      }
    }
    if (changed) await saveLnHistory(list);
    return changed;
  }

  /// The payments to an address that ended unmade or taken back, not yet acknowledged with OK.
  static Future<List<Map<String, dynamic>>> untoldEnds() async => [
        for (final e in await addressPayments())
          if ((e['stage'] == 'not_made' || e['stage'] == 'reclaimed') && e['told'] != true) e
      ];

  /// The person pressed OK on (or was told while it ended) payment [offboard].
  static Future<void> markTold(String offboard) async {
    final list = List<Map<String, dynamic>>.from(await loadLnHistory());
    var changed = false;
    for (final e in list) {
      if (e['offboard'] == offboard && e['told'] != true) {
        e['told'] = true;
        changed = true;
      }
    }
    if (changed) await saveLnHistory(list);
  }

  /// Of [asset], what this wallet's payments to an address still on their way give up (amount
  /// and fee): it counts as arriving in the library's balance but comes back only as change.
  static Future<BigInt> pendingOutAtoms(String asset) async {
    var n = BigInt.zero;
    for (final e in await addressPayments()) {
      if (e['stage'] != 'pending' || e['asset'] != asset) continue;
      n += (BigInt.tryParse('${e['atoms']}') ?? BigInt.zero) + (BigInt.tryParse('${e['fee_atoms'] ?? 0}') ?? BigInt.zero);
    }
    return n;
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kBalances);
    await p.remove(_kTxs);
    await p.remove(_kBtc);
    await p.remove(_kOampXfers);
    await p.remove(_kLnHistory);
    await p.remove(_kReceiveCode);
  }

  static const _kReceiveCode = 'ambra.cache.receivecode';

  /// The receive code last drawn, by its parts (address, ark address, receive request and
  /// the request's lapse), so Receive shows it at once on the next open, syncing or not,
  /// until it is paid or lapses.
  static Future<void> saveReceiveCode(Map<String, Object?> parts) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kReceiveCode, jsonEncode(parts));
  }

  static Future<Map<String, dynamic>?> loadReceiveCode() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kReceiveCode);
    if (s == null) return null;
    try {
      final v = jsonDecode(s);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }
}

/// One locally-tracked OpenAMP restricted transfer this wallet sent. Mirrors the
/// web wallet's OAMP_XFERS record. `confirmed`/`blockHash`/`anchorDepth` are
/// re-derived from the live chain (reorg-aware: a confirmed row can revert to
/// pending if its anchoring Bitcoin block is orphaned — never sticky).
class OampTransfer {
  OampTransfer({
    required this.asset,
    required this.ticker,
    required this.precision,
    required this.recipientAid,
    required this.atoms,
    required this.txid,
    required this.time,
    this.confirmed = false,
    this.blockHash,
    this.anchorDepth,
  });

  final String asset;
  final String ticker;
  final int precision;
  final String recipientAid;
  final String atoms;
  final String txid;
  final int time; // epoch millis
  bool confirmed;
  String? blockHash;
  int? anchorDepth;

  Map<String, dynamic> toJson() => {
        'asset': asset,
        'ticker': ticker,
        'precision': precision,
        'recipient_aid': recipientAid,
        'atoms': atoms,
        'txid': txid,
        'time': time,
        'confirmed': confirmed,
        'blockHash': blockHash,
        'anchorDepth': anchorDepth,
      };

  static OampTransfer fromJson(Map<String, dynamic> m) => OampTransfer(
        asset: '${m['asset']}',
        ticker: '${m['ticker']}',
        precision: m['precision'] is num ? (m['precision'] as num).toInt() : int.tryParse('${m['precision']}') ?? 8,
        recipientAid: '${m['recipient_aid']}',
        atoms: '${m['atoms']}',
        txid: '${m['txid']}',
        time: m['time'] is num ? (m['time'] as num).toInt() : int.tryParse('${m['time']}') ?? 0,
        confirmed: m['confirmed'] == true,
        blockHash: (m['blockHash'] is String && (m['blockHash'] as String).isNotEmpty) ? m['blockHash'] as String : null,
        anchorDepth: m['anchorDepth'] is num ? (m['anchorDepth'] as num).toInt() : null,
      );
}
