import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'btc_state.dart';
import 'lsp_client.dart';

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
///
/// Once a channel is emptied and closing it is cheap and safe ([closeVerdict]), it is closed
/// cooperatively to an address of the wallet ([_closeEmptied]), whose coins are then boarded by
/// themselves; what it paid stays in the figure until the wallet's own scan counts it
/// ([closing]). Otherwise it stays, and developer mode says why ([closeWhy]). The same rules as
/// the web wallet's and Ambra browser's `lightning-to-ark.js`.
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

  /// What each asset's channels held when its move began: while it moves, the asset's figure
  /// counts the channels and the move together at no more than this, whether the channels were
  /// read before the payment left them or after ([channelPart]).
  final Map<String, BigInt> movingFrom = {};

  /// The channels' part of [asset]'s figure, [read] as last read: with what is moving added,
  /// at most what they held when the move began.
  BigInt channelPart(String asset, BigInt read) {
    final m = movingAssets[asset];
    if (m == null) return read;
    final from = movingFrom[asset];
    final sum = read + m;
    return from != null && sum > from ? from : sum;
  }

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
    await _checkClosed();
    final last = _lastTry;
    if (last != null && DateTime.now().difference(last) < retry) return;
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    _running = true;
    try {
      final st = await ln.getStatus(nodes: [lnkeys.ownNodeKeyForBtc(m)]);
      // Only a channel locked in can pay: one still opening is counted in the figure, not paid from.
      final all = ((st.raw['channels'] as List?) ?? const []).whereType<Map>().toList();
      final channels = all.where(channelLockedIn).toList();
      final spendable = legLiquidity(channels, RailTarget.btc()).spendable;
      final amount = withinAllowance(amountToMove(spendable), await LnPaymentLimit.instance.allowanceAtoms(LnPaymentLimit.kBtcKey));
      if (amount == null) {
        if (amountToMove(spendable) == null) await _closeEmptied(m, 'BTC', all, min: BigInt.from(minMove));
        return;
      }
      _lastTry = DateTime.now();
      final invoice = await ark.invoice(amount);
      await _markOwnInvoice(invoice);
      moving = amount;
      notifyListeners();
      debugPrint('[ambra-ln-ark] moving $amount sat of $spendable from the channel to the ark');
      final r = await ln.payInvoice(bolt11: invoice, asset: kLnBtc);
      debugPrint('[ambra-ln-ark] paid: ${r.paid}');
      await ark.refresh();
      if (r.paid) {
        moving = null;
        final again = await ln.getStatus(nodes: [lnkeys.ownNodeKeyForBtc(m)]);
        await _closeEmptied(m, 'BTC', ((again.raw['channels'] as List?) ?? const []).whereType<Map>().toList(),
            min: BigInt.from(minMove));
      }
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
    if (_assetsRunning || DevMode.instance.on) return;
    if (!leaves.open || !ln.configured || leaves.personBusy) {
      return _why(!leaves.open ? 'the leaf wallet is not open' : (!ln.configured ? 'no Lightning here' : 'a person asked for something'));
    }
    _assetsRunning = true;
    try {
      final receives = await _receives(leaves);
      _setMoving(receives, leaves.coins);
      final last = _lastAssetTry;
      if (last != null && DateTime.now().difference(last) < const Duration(minutes: 2)) return;
      _lastAssetTry = DateTime.now();
      final legs = lightningLegs(leaves.info);
      if (legs.isEmpty) return _why('the operator receives no asset over Lightning');
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final nodes = [for (final a in legs) lnkeys.ownNodeKeyForAsset(m, a)];
      final givenUp = await _givenUp();
      final st = await ln.getStatus(nodes: nodes);
      // Only a channel locked in can pay: one still opening is counted in the figure, not paid from.
      final all = ((st.raw['channels'] as List?) ?? const []).whereType<Map>().toList();
      final channels = all.where(channelLockedIn).toList();
      await _checkClosed();
      for (final asset in legs) {
        if (leaves.personBusy) break;
        final a8 = asset.substring(0, 8);
        if (receivesUnderWay(receives, asset, DateTime.now(), givenUp: givenUp)) {
          _why('$a8: a move is under way');
          continue;
        }
        final refused = _assetRefused[asset];
        if (refused != null && DateTime.now().difference(refused) < retry) {
          _why('$a8: refused at $refused, tried again later');
          continue;
        }
        final spendable = legLiquidity(channels, RailTarget.asset(hex: asset)).spendable;
        final min = minLeaves(leaves.info)[asset];
        if (amountToMove(spendable, min: min) == null) await _closeEmptied(m, asset, all, min: min ?? BigInt.one);
        if (spendable <= BigInt.zero) {
          _why('$a8: nothing to pay from a channel that is locked in');
          continue;
        }
        final allowance = await LnPaymentLimit.instance.allowanceAtoms(asset);
        final amount = withinAllowance(amountToMove(spendable, min: min), allowance, min: min);
        if (amount == null) {
          _why('$a8: $spendable in the channel, too little to move (smallest leaf $min, the day\'s limit $allowance)');
          continue;
        }
        try {
          movingFrom[asset] = legLiquidity(channels, RailTarget.asset(hex: asset)).balance;
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

  // ---- emptied channels: closed when that is cheap and safe, or kept with the reason ----

  /// A close is made only when what comes back is at least this many times its fee.
  static const closeWorth = 4;

  /// How long what a close paid stays in the figure at most, waiting for the wallet's scan.
  static const closeHold = Duration(hours: 2);

  /// How long a close that never answered is held before the channel is looked at again.
  static const closePending = Duration(minutes: 15);

  /// How long the hosted node waits for the routing peer before closing unilaterally.
  static const closeUnilateralSeconds = 600;

  static const _kClosed = 'ambra.lnToArk.closed';

  /// Why each emptied channel stays open (by short channel id), for developer mode; null once
  /// it is closed.
  final Map<String, String?> closeWhy = {};

  /// The closes this wallet made, by short channel id: when, its transaction, its kind ('BTC' or
  /// an asset id), what it held, and when the wallet's scan counted it. Kept across restarts.
  Map<String, Map<String, dynamic>> _closed = {};
  bool _closedLoaded = false;
  bool _closing = false;

  Future<void> _loadClosed() async {
    if (_closedLoaded) return;
    final p = await SharedPreferences.getInstance();
    try {
      final j = jsonDecode(p.getString(_kClosed) ?? '{}');
      if (j is Map) _closed = {for (final e in j.entries) if (e.value is Map) '${e.key}': Map<String, dynamic>.from(e.value as Map)};
    } catch (_) {}
    _closedLoaded = true;
  }

  Future<void> _saveClosed() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Records past the hold are no longer needed for the figure; a day of them keeps a channel
    // from being closed twice.
    _closed.removeWhere((_, v) => now - ((v['at'] as num?)?.toInt() ?? 0) > const Duration(days: 1).inMilliseconds);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kClosed, jsonEncode(_closed));
  }

  /// What cooperative closes paid the wallet that its own scan does not count yet, in [kind]'s
  /// atoms ('BTC' or an asset id): the channel has left [listed] (the channels as last read),
  /// and its balance is on its way to the wallet's address.
  BigInt closing(String kind, List<Map> listed) =>
      closingOf(_closed, kind, listed, DateTime.now());

  /// Closes each emptied channel of [kind] in [channels] when that is cheap and safe; otherwise
  /// says why it stays ([closeWhy]). [min] is the least a move is in that kind.
  Future<void> _closeEmptied(String mnemonic, String kind, List<Map> channels, {required BigInt min}) async {
    if (_closing || DevMode.instance.on) return;
    await _loadClosed();
    final btc = kind == 'BTC';
    final target = btc ? RailTarget.btc() : RailTarget.asset(hex: kind);
    final moving = btc ? this.moving != null : movingAssets.containsKey(kind);
    for (final c in channels) {
      if ('${c['node_key'] ?? ''}'.isEmpty || !channelMatches(c, target)) continue;
      final id = '${c['short_channel_id'] ?? c['scid'] ?? c['node_key']}';
      final was = _closed[id];
      if (was != null &&
          !(was['type'] == 'closing' &&
              DateTime.now().millisecondsSinceEpoch - ((was['at'] as num?)?.toInt() ?? 0) > closePending.inMilliseconds)) {
        continue;
      }
      final left = _big(c['balance_units'] ?? c['spendable_units'] ?? 0);
      BigInt? fee;
      try {
        fee = await _closeFee(kind);
      } catch (_) {}
      final v = closeVerdict(channel: c, left: left, spendable: _big(c['spendable_units'] ?? 0), fee: fee, min: min, moving: moving);
      closeWhy[id] = v.why;
      if (!v.close) {
        _why('${kind.length > 8 ? kind.substring(0, 8) : kind} channel $id stays open: ${v.why}');
        continue;
      }
      _closing = true;
      // Held in the figure from the moment the channel leaves the service's list, before its
      // close has answered.
      _closed[id] = {'at': DateTime.now().millisecondsSinceEpoch, 'txid': null, 'type': 'closing', 'kind': kind, 'left': '$left'};
      await _saveClosed();
      notifyListeners();
      try {
        debugPrint('[ambra-ln-ark] closing the emptied ${btc ? 'BTC' : kind.substring(0, 8)} channel $id, $left left in it, fee about $fee');
        final chain = btc ? 'btc' : 'seq';
        final nodeKey = await LightningService.instance.connectNode(mnemonic, chain: chain, asset: btc ? null : kind);
        final dest = (await core.receiveAddressAt(mnemonic: mnemonic, index: BtcState.instance.unifiedNext, confidential: false)).address;
        // The device refuses a close of this side's balance to any script it was not told is ours.
        await LightningService.instance.approveCloseDestination(nodeKey, await core.addressScriptPubkey(address: dest));
        final scid = '${c['short_channel_id'] ?? c['scid'] ?? ''}';
        final r = await LspClient.channelClose(
            chain: chain,
            destination: dest,
            asset: btc ? null : kind,
            node: nodeKey,
            scid: scid.isEmpty ? null : scid,
            unilateraltimeout: closeUnilateralSeconds,
            // The service answers once the peer has signed, or after the unilateral timeout.
            timeout: const Duration(seconds: closeUnilateralSeconds + 60));
        _closed[id] = {
          'at': DateTime.now().millisecondsSinceEpoch,
          'txid': r.closingTxid,
          'type': r.type,
          'kind': kind,
          'left': '$left',
          'address': r.destination ?? dest,
        };
        closeWhy[id] = null;
        debugPrint('[ambra-ln-ark] closed $id: ${r.type ?? ''} ${r.closingTxid ?? ''}');
      } on TimeoutException catch (e) {
        // Asked, and not answered: the close may well be under way, so the channel is not asked
        // again, and what it held stays in the figure, until [closePending] has passed.
        closeWhy[id] = 'its close was asked and not answered yet';
        debugPrint('[ambra-ln-ark] close of $id not answered: $e');
      } catch (e) {
        _closed.remove(id);
        closeWhy[id] = 'its close was refused now, and is tried again later: $e';
        debugPrint('[ambra-ln-ark] close of $id refused: $e');
      } finally {
        await _saveClosed();
        _closing = false;
        notifyListeners();
      }
    }
  }

  /// What closing a channel of [kind] costs this side, in its atoms: about 200 vB at the
  /// default fee rate (2 sat/vB on testnet4; 2 of the policy unit per vB on Sequentia, valued in
  /// the asset at the fee exchange rates). Null when the asset has no rate now.
  Future<BigInt?> _closeFee(String kind) async {
    if (kind == 'BTC') return BigInt.from(400);
    final rates = await ApiClient.feeRates();
    final rate = rates[kind] ?? rates[SeqAssets.labelFor(kind).ticker];
    if (rate == null || rate <= BigInt.zero) return null;
    final policy = BigInt.from(400) * BigInt.from(100000000);
    return (policy + rate - BigInt.one) ~/ rate;
  }

  /// Asks the chain whether each close's payment is there, and marks it counted once the
  /// wallet's own scan of that chain ran after it was first seen there.
  Future<void> _checkClosed() async {
    await _loadClosed();
    var changed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final v in _closed.values) {
      final txid = v['txid'];
      if (txid is! String || txid.isEmpty || v['seen'] != null || v['type'] == 'unilateral') continue;
      if (now - ((v['at'] as num?)?.toInt() ?? 0) >= closeHold.inMilliseconds) continue;
      final btc = v['kind'] == 'BTC';
      if (v['found'] == null) {
        try {
          final r = await http.get(Uri.parse('${btc ? Backend.testnet4 : Backend.esplora}/tx/$txid/status'), headers: Backend.authHeaders)
              .timeout(const Duration(seconds: 15));
          if (r.statusCode != 200) continue;
        } catch (_) {
          continue;
        }
        v['found'] = now;
        changed = true;
      }
      final scanned = btc ? BtcState.instance.btcScanAt : BtcState.instance.seqScanAt;
      if (scanned != null && scanned.millisecondsSinceEpoch > (v['found'] as num).toInt()) {
        v['seen'] = scanned.millisecondsSinceEpoch;
        changed = true;
      }
    }
    if (changed) {
      await _saveClosed();
      notifyListeners();
    }
  }

  static BigInt _big(Object? v) => BigInt.tryParse('$v'.split('.').first) ?? BigInt.zero;

  final Set<String> _said = {};

  /// Logs why the asset channels' move did nothing, once per reason.
  void _why(String why) {
    if (_said.add(why)) debugPrint('[ambra-ln-ark] assets: $why');
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
    movingFrom.removeWhere((a, _) => !next.containsKey(a));
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

/// Whether an emptied channel is closed now, and if not, why it stays (developer mode's words).
/// [left]: this side's balance in it; [fee]: what its close is estimated to cost this side, or
/// null when it cannot be priced; [min]: the least a move is. User mode never pays from a
/// channel, so one that holds too little to move is emptied; one that holds nothing of the
/// wallet's stays.
({bool close, String? why}) closeVerdict(
    {required Map channel, required BigInt left, required BigInt spendable, BigInt? fee, required BigInt min, bool moving = false}) {
  if (moving) return (close: false, why: 'a move from it is still on its way');
  if (!channelLockedIn(channel)) return (close: false, why: 'it is not open for payments now, so it cannot be closed cooperatively');
  if (LightningToArk.amountToMove(spendable, min: min) != null) return (close: false, why: 'it still holds enough to move');
  if (left <= BigInt.zero) return (close: false, why: 'nothing of this wallet’s is left in it');
  if (fee == null) return (close: false, why: 'its closing fee cannot be priced now');
  if (left < fee * BigInt.from(LightningToArk.closeWorth)) {
    return (close: false, why: 'closing it would cost too much of the $left left in it (about $fee)');
  }
  return (close: true, why: null);
}

/// What the closes in [closed] paid that the wallet's scan does not count yet, in [kind]'s
/// atoms. A channel still in [listed] is counted by the figure itself; a unilateral close pays
/// the node's own address after its delay, not the wallet's, and is not held; a close that never
/// answered is held only for [LightningToArk.closePending].
BigInt closingOf(Map<String, Map<String, dynamic>> closed, String kind, List<Map> listed, DateTime now) {
  final open = {
    for (final c in listed)
      if ('${c['state'] ?? ''}'.toUpperCase().startsWith('CHANNELD')) '${c['short_channel_id'] ?? c['scid'] ?? c['node_key']}',
  };
  final at = now.millisecondsSinceEpoch;
  var n = BigInt.zero;
  closed.forEach((id, v) {
    if (v['kind'] != kind || v['type'] == 'unilateral' || v['seen'] != null) return;
    final when = (v['at'] as num?)?.toInt() ?? 0;
    if (at - when >= LightningToArk.closeHold.inMilliseconds) return;
    final txid = v['txid'];
    final answered = txid is String && txid.isNotEmpty;
    if (!answered && at - when > LightningToArk.closePending.inMilliseconds) return;
    if (open.contains(id)) return;
    n += BigInt.tryParse('${v['left'] ?? ''}') ?? BigInt.zero;
  });
  return n;
}
