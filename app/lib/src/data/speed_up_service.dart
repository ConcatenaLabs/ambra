import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';
import 'dev_mode.dart';
import 'wallet_repository.dart';

/// Default mode speeds up, by itself, every Sequentia transaction of the wallet's that waits for a
/// block (child pays for parent): one that has waited [stuckBlocks] blocks gets a child that spends
/// its output to the wallet and pays for both, at twice the default rate for the pair, the rate
/// doubling at each further wait, at most [maxRaises] times. The child pays in the asset the
/// waiting transaction paid in when a producer prices it, and otherwise in a priced asset the
/// wallet holds; never a fallback to one asset. The rule is the web wallet's (`speed-up.js`), and
/// the words are the default-mode contract's (sequentia-web-wallet `docs/DEFAULT_MODE.md`).
/// Developer mode does nothing by itself: a transaction's details offer Speed up instead. The
/// leaf wallet's own steps on the chain (an exit, its claim) are sped up by the leaf library.
class SpeedUpService {
  SpeedUpService._();
  static final instance = SpeedUpService._();

  static const stuckBlocks = 2;
  static const maxRaises = 6;
  static const defaultKvb = 2000.0;
  static const spedUp = 'Taking longer than usual: the wallet paid a little more to speed it up.';

  static const _kBook = 'ambra.sped.book';
  static const _kChildren = 'ambra.sped.children';

  /// Each speed-up the wallet made, child -> the transaction it sped up.
  Map<String, String> children = {};
  bool _running = false;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    try {
      children = Map<String, String>.from(jsonDecode(p.getString(_kChildren) ?? '{}') as Map);
    } catch (_) {
      children = {};
    }
  }

  /// Whether `txid` is waiting and the wallet has sped it up.
  bool isSpedUp(String txid) => children.containsValue(txid);

  /// The transactions due a speed-up now, from `book` ({txid: {seen, raises, raisedAt}}): each first
  /// seen waiting at `tip`, due once it has waited [stuckBlocks] blocks, and as long after each raise.
  static List<String> dueNow(Map<String, dynamic> book, List<String> waiting, int tip) {
    book.removeWhere((k, _) => !waiting.contains(k));
    final due = <String>[];
    for (final id in waiting) {
      final e = (book[id] ??= {'seen': tip, 'raises': 0, 'raisedAt': null}) as Map;
      if (tip < (e['seen'] as int) + stuckBlocks) continue;
      if (e['raisedAt'] != null && tip < (e['raisedAt'] as int) + stuckBlocks) continue;
      if ((e['raises'] as int) >= maxRaises) continue;
      due.add(id);
    }
    return due;
  }

  Future<void> tick() async {
    if (DevMode.instance.on || _running) return;
    _running = true;
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      await load();
      final p = await SharedPreferences.getInstance();
      Map<String, dynamic> book;
      try {
        book = Map<String, dynamic>.from(jsonDecode(p.getString(_kBook) ?? '{}') as Map);
      } catch (_) {
        book = {};
      }
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      final txs = await core.walletTransactions(mnemonic: m, esploraUrl: Backend.esplora);
      final waiting = txs
          .where((t) => t.height == null && !children.containsKey(t.txid) && (t.kind == 'outgoing' || t.kind == 'incoming'))
          .map((t) => t.txid)
          .toList();
      final due = dueNow(book, waiting, s.tipHeight);
      if (due.isNotEmpty) {
        Map<String, BigInt> rates = {};
        try {
          rates = await ApiClient.feeRates();
        } catch (_) {}
        bool priced(String a) => a.isEmpty || a == SeqAssets.policy || (rates[a] ?? BigInt.zero) > BigInt.zero;
        for (final id in due) {
          final e = book[id] as Map;
          try {
            final tx = txs.firstWhere((t) => t.txid == id);
            String? asset = priced(tx.feeAsset) ? tx.feeAsset : null;
            asset ??= s.balances.map((b) => b.assetId).firstWhere(priced, orElse: () => '');
            final target = defaultKvb * math.pow(2, (e['raises'] as int) + 1);
            final rate = await core.cpfpSuggestedFeerate(mnemonic: m, esploraUrl: Backend.esplora, parentTxid: id, targetFeerate: target);
            final fa = (asset.isEmpty || asset == SeqAssets.policy) ? null : core.FeeAsset(assetId: asset, rate: rates[asset]!);
            final pset = await core.buildCpfpTx(mnemonic: m, esploraUrl: Backend.esplora, parentTxid: id, feeRateSatKvb: rate, feeAsset: fa);
            final signed = await core.signPset(mnemonic: m, pset: pset);
            final child = await core.finalizeAndBroadcast(mnemonic: m, esploraUrl: Backend.esplora, pset: signed);
            children[child] = id;
            debugPrint('[speed up] $id by $child at $target a kvB for the pair');
          } catch (err) {
            debugPrint('[speed up] $id: $err');
          }
          e['raises'] = (e['raises'] as int) + 1;
          e['raisedAt'] = s.tipHeight;
        }
        await p.setString(_kChildren, jsonEncode(children));
      }
      await p.setString(_kBook, jsonEncode(book));
    } catch (err) {
      debugPrint('[speed up] the pass failed: $err');
    } finally {
      _running = false;
    }
  }
}
