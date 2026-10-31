import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'seqln_keys.dart' as lnkeys;
import 'ark_btc_service.dart';
import 'config.dart';
import 'dev_mode.dart';
import 'leaf_service.dart';
import 'ln_payment_limit.dart';
import 'lightning_service.dart';
import 'ln_rail.dart';
import 'wallet_repository.dart';

/// User mode keeps BTC on the Bitcoin ark and every other asset in the operator's tree, where
/// each is sent in seconds and needs no channel. A wallet made before that holds balances in its
/// own Lightning channels: this moves them, as the wallet's own upkeep.
///
///   BTC      an invoice of the wallet's own ark, paid from its BTC channel ([tick]).
///   assets   a Lightning receive of the wallet's own leaf wallet (`lightning_receive`: an
///            invoice of the operator's node in the asset, under a hash whose preimage only the
///            wallet holds), paid from its channel in that asset ([tickAssets]). The operator
///            holds the payment until it has put the wallet's leaf in the asset's next round; the
///            leaf wallet's sync then claims the leaf with the preimage, which settles the payment.
///            An asset the operator serves without a Lightning node, or one that cannot be held
///            in a channel at all (a supervised asset), has nothing to move here.
///
/// Nothing is asked and nothing is lost: until a move is paid the balance stays in the channel,
/// spendable as before and in the asset's one figure; while it is on its way it stays in the
/// figure and is said to be moving ([moving], [movingAssets]); a payment that fails comes back
/// to the channel. A move that fails is tried again after [retry]; one is never made while
/// something a person asked for runs, nor in developer mode, where channels are the person's to
/// use.
class LightningToArk extends ChangeNotifier {
  LightningToArk._();
  static final LightningToArk instance = LightningToArk._();

  /// The least worth moving, in sats: below it the routing fee is too large a share.
  static const minMove = 5000;

  /// How long after a move, or a move that failed, before the channel is looked at again.
  static const retry = Duration(minutes: 15);

  DateTime? _lastTry;
  bool _running = false;

  /// What is on its way from the channel to the ark, in sats, or null.
  BigInt? moving;

  /// How long a move the phone's daily limit refused waits before it is tried again.
  static const limitWait = Duration(hours: 6);

  /// A move of [amount] held to what the phone's daily Lightning limit allows ([allowance], in
  /// the same atoms; null when it cannot be valued now): at most nine tenths of it, so the
  /// payment's fee and the day's other payments fit, and what is left moves on a later day.
  /// Null when nothing worth moving is left ([min]: the least a move must be).
  static BigInt? withinAllowance(BigInt? amount, BigInt? allowance, {BigInt? min}) {
    if (amount == null || allowance == null) return amount;
    final cap = allowance * BigInt.from(9) ~/ BigInt.from(10);
    final a = amount < cap ? amount : cap;
    return a >= (min ?? BigInt.from(minMove)) && a > BigInt.zero ? a : null;
  }

  /// What of each asset is on its way from its channel to the tree, in atoms: paid from the
  /// channel, its leaf not yet the wallet's.
  Map<String, BigInt> movingAssets = const {};

  DateTime? _lastAssetTry;
  bool _assetsRunning = false;
  final Map<String, DateTime> _assetRefused = {};

  /// The hashes of the receives this wallet paid from its own channels, kept across restarts.
  static const _kPaid = 'ambra.lnToArk.paid';

  /// What of [spendable] sats in the channel is moved: all of it less the routing fee the
  /// channel must also pay (1% and 10 sats, the hosted nodes' fee bound), or null when that is
  /// below [minMove].
  /// For an asset, [min] is the operator's smallest leaf in it, which the move must reach.
  static BigInt? amountToMove(BigInt spendable, {BigInt? min}) {
    final fee = spendable ~/ BigInt.from(100) + BigInt.from(10);
    final a = spendable - fee;
    return a >= (min ?? BigInt.from(minMove)) && a > BigInt.zero ? a : null;
  }

  /// One look at the wallet's own BTC channel; a move when it holds enough.
  Future<void> tick() async {
    final ark = ArkBtcService.instance;
    final ln = LightningService.instance;
    if (_running || DevMode.instance.on || !ark.open || !ln.configured || LeafService.instance.personBusy) return;
    final last = _lastTry;
    if (last != null && DateTime.now().difference(last) < retry) return;
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    _running = true;
    try {
      final st = await ln.getStatus(nodes: [lnkeys.ownNodeKeyForBtc(m)]);
      // Only a channel locked in can pay: one still opening is counted in the figure, not paid from.
      final channels = ((st.raw['channels'] as List?) ?? const []).whereType<Map>().where(channelLockedIn).toList();
      final spendable = legLiquidity(channels, RailTarget.btc()).spendable;
      final amount = withinAllowance(amountToMove(spendable), await LnPaymentLimit.instance.allowanceAtoms(LnPaymentLimit.kBtcKey));
      if (amount == null) return;
      _lastTry = DateTime.now();
      final invoice = await ark.invoice(amount);
      await _markOwnInvoice(invoice);
      moving = amount;
      notifyListeners();
      debugPrint('[ambra-ln-ark] moving $amount sat of $spendable from the channel to the ark');
      final r = await ln.payInvoice(bolt11: invoice, asset: kLnBtc);
      debugPrint('[ambra-ln-ark] paid: ${r.paid}');
      await ark.refresh();
    } catch (e) {
      // A payment over what the phone's daily limit leaves is tried again once the day has
      // moved on.
      _lastTry = LnPaymentLimit.isRefusal(e) ? DateTime.now().add(limitWait - retry) : DateTime.now();
      debugPrint('[ambra-ln-ark] not moved now: $e');
    } finally {
      moving = null;
      _running = false;
      notifyListeners();
    }
  }

  /// One look at the wallet's own asset channels; for each asset the operator receives over
  /// Lightning and the channel holds enough of, a move into the tree.
  Future<void> tickAssets() async {
    final leaves = LeafService.instance;
    final ln = LightningService.instance;
    if (_assetsRunning || DevMode.instance.on || !leaves.open || !ln.configured || leaves.personBusy) return;
    _assetsRunning = true;
    try {
      final receives = await _receives(leaves);
      _setMoving(receives, leaves.coins);
      final last = _lastAssetTry;
      if (last != null && DateTime.now().difference(last) < const Duration(minutes: 2)) return;
      _lastAssetTry = DateTime.now();
      final legs = lightningLegs(leaves.info);
      if (legs.isEmpty) return;
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final nodes = [for (final a in legs) lnkeys.ownNodeKeyForAsset(m, a)];
      final givenUp = await _givenUp();
      final st = await ln.getStatus(nodes: nodes);
      // Only a channel locked in can pay: one still opening is counted in the figure, not paid from.
      final channels = ((st.raw['channels'] as List?) ?? const []).whereType<Map>().where(channelLockedIn).toList();
      for (final asset in legs) {
        if (leaves.personBusy) break;
        if (receivesUnderWay(receives, asset, DateTime.now(), givenUp: givenUp)) continue;
        final refused = _assetRefused[asset];
        if (refused != null && DateTime.now().difference(refused) < retry) continue;
        final spendable = legLiquidity(channels, RailTarget.asset(hex: asset)).spendable;
        final min = minLeaves(leaves.info)[asset];
        final amount = withinAllowance(amountToMove(spendable, min: min), await LnPaymentLimit.instance.allowanceAtoms(asset), min: min);
        if (amount == null) continue;
        try {
          await _moveAsset(leaves, ln, asset, amount, spendable);
        } catch (e) {
          _assetRefused[asset] = DateTime.now();
          debugPrint('[ambra-ln-ark] ${asset.substring(0, 8)} not moved now: $e');
        }
      }
      _setMoving(await _receives(leaves), leaves.coins);
    } catch (e) {
      debugPrint('[ambra-ln-ark] asset channels not read now: $e');
    } finally {
      _assetsRunning = false;
    }
  }

  Future<void> _moveAsset(LeafService leaves, LightningService ln, String asset, BigInt amount, BigInt spendable) async {
    // What the operator charges and what the claim's margins take is the library's to check
    // (its bound refuses more); a quote refused says why nothing moves.
    await leaves.run('lightning_receive_quote', {'asset': asset, 'amount': '$amount'});
    final r = await leaves.run('lightning_receive', {'asset': asset, 'amount': '$amount', 'description': 'Ambra: from the channel to the tree'})
        as Map;
    final hash = '${r['payment_hash']}';
    await _markPaid(hash);
    final ticker = SeqAssets.labelFor(asset).ticker;
    debugPrint('[ambra-ln-ark] moving $amount of $spendable $ticker (${asset.substring(0, 8)}) from the channel to the tree, '
        'leaf ${r['value']}, fee ${r['fee']}, hash $hash');
    _setMoving(await _receives(leaves), leaves.coins);
    try {
      // Held by the operator until the leaf's round: the call may outlast its wait, and the
      // payment goes on; the leaf wallet's sync claims the leaf and settles it.
      final p = await ln.payInvoice(bolt11: '${r['invoice']}', asset: asset);
      debugPrint('[ambra-ln-ark] ${asset.substring(0, 8)} paid: ${p.paid}');
    } on TimeoutException catch (e) {
      debugPrint('[ambra-ln-ark] ${asset.substring(0, 8)} payment still on its way: $e (the receive is followed by its hash)');
    } catch (e) {
      // Refused before anything left the channel (no route, the phone's limit): the receive is
      // given up, and nothing is moving.
      debugPrint('[ambra-ln-ark] ${asset.substring(0, 8)} not moved now: $e');
      await _unmarkPaid(hash);
      _assetRefused[asset] = LnPaymentLimit.isRefusal(e) ? DateTime.now().add(limitWait - retry) : DateTime.now();
    }
  }

  Future<Map> _receives(LeafService leaves) async {
    try {
      return ((await leaves.run('lightning_receives')) as Map?) ?? const {};
    } catch (_) {
      return const {};
    }
  }

  static const _kOwnInvoices = 'ambra.lnToArk.invoices';

  /// The ark invoices this wallet paid from its own channel: a move within the wallet, which
  /// History does not list as money received.
  Future<Set<String>> ownInvoices() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_kOwnInvoices) ?? const []).toSet();
  }

  Future<void> _markOwnInvoice(String invoice) async {
    final p = await SharedPreferences.getInstance();
    final l = p.getStringList(_kOwnInvoices) ?? <String>[];
    await p.setStringList(_kOwnInvoices, [...l.length > 50 ? l.sublist(l.length - 50) : l, invoice]);
  }

  Future<Set<String>> _paid() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_kPaid) ?? const []).toSet();
  }

  Future<void> _markPaid(String hash) async {
    final p = await SharedPreferences.getInstance();
    final l = p.getStringList(_kPaid) ?? <String>[];
    if (!l.contains(hash)) await p.setStringList(_kPaid, [...l.length > 50 ? l.sublist(l.length - 50) : l, hash]);
  }

  /// A receive whose payment was refused: neither moving nor under way.
  Future<void> _unmarkPaid(String hash) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kPaid, [...(p.getStringList(_kPaid) ?? const <String>[]).where((h) => h != hash)]);
    final g = p.getStringList(_kGivenUp) ?? <String>[];
    await p.setStringList(_kGivenUp, [...g.length > 50 ? g.sublist(g.length - 50) : g, hash]);
  }

  static const _kGivenUp = 'ambra.lnToArk.givenUp';

  Future<Set<String>> _givenUp() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_kGivenUp) ?? const []).toSet();
  }

  Future<void> _setMoving(Map receives, List<dynamic> coins) async {
    final next = movingOf(receives, coins, await _paid());
    if (!mapEquals(next, movingAssets)) {
      movingAssets = next;
      notifyListeners();
    }
  }
}

/// The assets the operator receives over Lightning (`info.server_info.assets[].lightning`: up
/// and receiving). A supervised asset is never one: it cannot be held in a channel.
List<String> lightningLegs(Map? info) {
  final si = info?['server_info'];
  final assets = si is Map ? si['assets'] : null;
  if (assets is! List) return const [];
  return [
    for (final a in assets.whereType<Map>())
      if (a['asset'] is String && a['supervised'] == null && a['lightning'] is Map && a['lightning']['state'] == 'up' &&
          a['lightning']['receives'] == true)
        a['asset'] as String,
  ];
}

/// Whether a Lightning receive of [asset] is under way ([receives]: the leaf wallet's
/// `lightning_receives`): asked and its invoice not lapsed, or held and its leaf coming. One
/// whose payment the wallet saw refused ([givenUp]) is not.
bool receivesUnderWay(Map receives, String asset, DateTime now, {Set<String> givenUp = const {}}) {
  for (final e in receives.entries) {
    final r = e.value;
    if (r is! Map || r['asset'] != asset || givenUp.contains(e.key)) continue;
    final st = r['state'];
    if (st == 'issuing' || st == 'claiming') return true;
    if (st == 'requested' || st == 'waiting') {
      final exp = (r['expires_at'] as num?)?.toInt();
      if (exp == null || exp * 1000 > now.millisecondsSinceEpoch) return true;
    }
  }
  return false;
}

/// What of each asset is on its way from the wallet's channel to its tree: each receive it paid
/// ([paid]) not yet received, until its leaf is a coin of the wallet's ([coins]: the leaf
/// counts in the figure from then).
Map<String, BigInt> movingOf(Map receives, List<dynamic> coins, Set<String> paid, {DateTime? now}) {
  final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final out = <String, BigInt>{};
  final leafValues = <String>{
    for (final c in coins.whereType<Map>())
      if (c['state'] == 'receiving') '${c['asset']}:${c['value']}',
  };
  receives.forEach((hash, r) {
    if (r is! Map || !paid.contains(hash)) return;
    if (r['state'] != 'waiting' && r['state'] != 'issuing') return;
    // An invoice that lapsed unpaid moved nothing.
    final exp = (r['expires_at'] as num?)?.toInt();
    if (r['state'] == 'waiting' && exp != null && exp * 1000 <= at) return;
    if (leafValues.contains('${r['asset']}:${r['value']}')) return;
    final a = BigInt.tryParse('${r['amount'] ?? ''}');
    if (a == null || a <= BigInt.zero) return;
    out['${r['asset']}'] = (out['${r['asset']}'] ?? BigInt.zero) + a;
  });
  return out;
}

/// Whether channel [c] is locked in and can pay now (`CHANNELD_NORMAL`). [channelActive] also
/// takes one still waiting for its funding to confirm, which counts in the figure but routes
/// nothing.
bool channelLockedIn(Map c) => '${c['state'] ?? ''}'.toUpperCase() == 'CHANNELD_NORMAL';
