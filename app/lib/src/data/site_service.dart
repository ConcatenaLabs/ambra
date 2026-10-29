/// The paired sites as the app runs them: [SiteLink] over the core's crypto and dart:io's
/// WebSocket, the pairings kept per wallet in secure storage, and the provider protocol's
/// methods served from this wallet ([SiteOrders] for the orders). An approval is the app's
/// sheet ([ask]); one shows at a time, and one left unanswered for five minutes is declined.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as core;
import '../rust/api/nostr.dart' as pairing;
import '../screens/user_composer.dart' show appTradeEngine;
import 'ark_btc_service.dart';
import 'config.dart';
import 'dev_mode.dart';
import 'leaf_rail.dart' show offerForVerify;
import 'leaf_service.dart';
import 'seqob_client.dart';
import 'site_link.dart';
import 'site_orders.dart';
import 'wallet_cache.dart';
import 'wallet_repository.dart';

class FfiSiteCrypto implements SiteCrypto {
  const FfiSiteCrypto();
  @override
  Future<({String secret, String pubkey})> newKeys() async {
    final k = pairing.pairingNewKeys();
    return (secret: k.secretHex, pubkey: k.pubkeyHex);
  }

  @override
  Future<String> seal(String secret, String peer, int createdAt, String plaintext) async =>
      pairing.pairingSeal(secretHex: secret, peerHex: peer, createdAt: BigInt.from(createdAt), plaintext: plaintext);

  @override
  Future<({String from, int createdAt, String text})> open(String secret, String eventJson) async {
    final m = pairing.pairingOpen(secretHex: secret, eventJson: eventJson);
    return (from: m.fromHex, createdAt: m.createdAt.toInt(), text: m.text);
  }
}

/// The pairings of the open wallet, in secure storage (each holds its pairing's secret key).
class SecureSiteStore implements SiteStore {
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  String get _key => 'ambra.sites.${DevMode.instance.tag ?? 'default'}';
  @override
  Future<List<SitePairing>> load() async {
    try {
      final s = await _storage.read(key: _key);
      if (s == null || s.isEmpty) return [];
      return [for (final j in jsonDecode(s) as List) SitePairing.fromJson(j as Map)];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<SitePairing> all) => _storage.write(key: _key, value: jsonEncode([for (final p in all) p.toJson()]));
}

class AmbraSites {
  AmbraSites._();
  static final AmbraSites instance = AmbraSites._();

  late final SiteLink link = SiteLink(
    crypto: const FfiSiteCrypto(),
    connect: IoRelaySocket.open,
    store: SecureSiteStore(),
    serve: _serve,
    log: (m) => debugPrint(m),
  );

  /// Shows an approval and answers whether its owner approved it. Set by the app.
  Future<bool> Function(SiteApproval a)? ask;

  Timer? _follow;
  String? _startedFor;

  /// Listens for the open wallet's sites (the shell is up, the wallet unlocked).
  Future<void> start() async {
    final tag = DevMode.instance.tag ?? 'default';
    if (link.running && _startedFor == tag) return;
    if (link.running) await link.stop();
    _startedFor = tag;
    await link.start();
    _follow?.cancel();
    // The site's orders move on while the app is open: trades are followed, and an order placed
    // here is listed on the book once it rests.
    _follow = Timer.periodic(const Duration(seconds: 60), (_) {
      if (link.sites.isNotEmpty) unawaited(orders().follow());
    });
  }

  Future<void> stop() async {
    _follow?.cancel();
    _follow = null;
    _startedFor = null;
    await link.stop();
  }

  SiteOrders? _orders;
  String? _ordersTag;
  SiteOrders orders() {
    final tag = DevMode.instance.tag ?? 'default';
    if (_orders != null && _ordersTag == tag) return _orders!;
    final engine = appTradeEngine(walletTag: tag);
    final key = 'ambra.siteorders.$tag';
    const reads = {'schedule', 'orders'};
    _ordersTag = tag;
    return _orders = SiteOrders(SiteOrderDeps(
      quote: engine.quote,
      confirm: engine.confirm,
      drop: engine.drop,
      advance: engine.advance,
      records: engine.records,
      leaves: (cmd, args) => reads.contains(cmd) ? LeafService.instance.run(cmd, args) : LeafService.instance.pay(cmd, args, true),
      meta: (h) {
        final l = SeqAssets.labelFor(h);
        return (ticker: l.ticker, precision: l.precision);
      },
      read: () async => (await SharedPreferences.getInstance()).getString(key),
      write: (v) async => (await SharedPreferences.getInstance()).setString(key, v),
      list: _listOrder,
      log: (m) => debugPrint(m),
    ));
  }

  /// Lists an order placed from leaves on the book: the library's unsigned offer for it, signed
  /// with this wallet's book key, posted.
  static Future<Map<String, dynamic>> _listOrder(Map<String, dynamic> o, Map<String, dynamic> rec) async {
    final offer = o['offer'];
    if (offer is! Map || offer['offer_id'] == null) throw StateError('not listable: ${offer is Map ? offer['note'] : 'no offer'}');
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw StateError('no wallet is open');
    final hexed = offerForVerify(Map<String, dynamic>.from(offer));
    final signed = jsonDecode(await core.seqobSignOffer(mnemonic: m, offerJson: jsonEncode(hexed))) as Map<String, dynamic>;
    await SeqObClient.postOffer(signed);
    debugPrint('[sites] listed order ${o['order']} at ${o['rests_at']} as ${offer['offer_id']}');
    return {'relay_expires': offer['expires_at_unix']};
  }

  Future<void> _queue = Future.value();

  /// One approval at a time; declined when its owner does not answer within five minutes.
  Future<bool> approve(SiteApproval a) {
    final c = Completer<bool>();
    _queue = _queue.then((_) async {
      final f = ask;
      if (f == null) return c.complete(false);
      try {
        c.complete(await f(a).timeout(kSiteWindow, onTimeout: () => false));
      } catch (_) {
        if (!c.isCompleted) c.complete(false);
      }
    });
    return c.future;
  }

  Future<Map<String, dynamic>> _account() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw StateError('the wallet is locked');
    final a = await core.receiveAddressAt(mnemonic: m, index: 0, confidential: false);
    return {'network': 'sequentia-testnet', 'address': a.address};
  }

  /// `getBalances`: on-chain Sequentia assets, testnet4 BTC, and apart from them what is held as
  /// leaves and BTC in the Bitcoin ark (the wallet's one figure per asset is their sum).
  Future<Map<String, dynamic>> _balances() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw StateError('the wallet is locked');
    // A read the site waits on briefly (SeqDEX gives one 20 s): a sync that takes longer leaves
    // the figures the wallet last read, and goes on by itself.
    const wait = Duration(seconds: 8);
    final chainF = core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora).then((s) => s.balances);
    final btcF = core.btcSync(mnemonic: m, t4Api: Backend.testnet4).then((b) => b.balanceSats);
    List<core.AssetBalance> chain;
    try {
      chain = await chainF.timeout(wait);
    } catch (e) {
      debugPrint('[sites] balances from the last read: $e');
      chain = await WalletCache.loadBalances() ?? const [];
    }
    String btc;
    try {
      btc = await btcF.timeout(wait);
    } catch (_) {
      btc = await WalletCache.loadBtc() ?? '0';
    }
    final l = LeafService.instance;
    final ark = ArkBtcService.instance;
    return {
      'assets': {for (final b in chain) if ((BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero) b.assetId: b.atoms},
      'btc': btc,
      'leaves': {for (final e in (l.joined ? l.leafAtoms() : const <String, BigInt>{}).entries) if (e.value > BigInt.zero) e.key: '${e.value}'},
      'btc_ark': ark.open ? '${ark.held}' : '0',
    };
  }

  Future<Object?> _serve(SitePairing site, String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'getCapabilities':
        return {'provider': 'ambra', 'network': 'sequentia-testnet', 'methods': kSiteMethods, 'events': <String>[]};
      case 'getWalletMode':
        return {'mode': DevMode.instance.mode};
      case 'connect':
        // The pairing its owner approved is the site's connection.
        return _account();
      case 'getAccounts':
        return {
          'accounts': [await _account()],
        };
      case 'getBalances':
        return _balances();
      case 'getOrders':
        unawaited(orders().follow());
        return orders().orders(site.origin);
      case 'placeOrder':
        return _approved(site, () => orders().quote(params, site.origin), (id) => orders().confirm(id), orders().drop);
      case 'cancelOrder':
        return _approved(site, () => orders().quoteCancel(params, site.origin), (id) => orders().confirmCancel(id), (_) {});
    }
    throw StateError('unknown method: $method');
  }

  Future<Object?> _approved(SitePairing site, Future<SiteReview> Function() review, Future<Map<String, dynamic>> Function(String id) go,
      void Function(String id) drop) async {
    final SiteReview r;
    try {
      r = await review();
    } on SiteRefusal catch (e) {
      throw StateError(e.message);
    }
    final ok = await approve(SiteApproval(r.title, r.text, r.rows));
    if (!ok) {
      drop(r.id);
      throw StateError(SiteLinkWords.rejected);
    }
    try {
      return await go(r.id);
    } on SiteRefusal catch (e) {
      throw StateError(e.message);
    }
  }
}
