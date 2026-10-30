/// The Swap tab in default mode: the pair's market, then You pay and You receive, Review, Trade.
///
/// The web wallet's `user-composer.js` (docs/DEFAULT_MODE.md "Trade" and "Market"; change them
/// together). The engine ([UserTradeEngine], `data/user_trade.dart`) reads the single-step book,
/// prices the trade with the leaf library and settles it in one native step; this widget draws it.
///
/// - The chosen pair's market shows above You pay (`widgets/market_view.dart`).
/// - Both pickers are the wallet's one asset chooser ([showAssetSheet]): a search box, your assets
///   first with their balances (BTC always), what the book offers now next, hidden assets left out
///   until searched for.
/// - The two amounts are tethered: the one typed stays as typed, the other follows the book's best
///   price now ([UserTradeEngine.estimate]), again a moment after each keystroke and every ten
///   seconds while the tab is shown. Under You pay: its balance and Max.
/// - Review shows what you pay, what you receive and one line of fees before anything is signed;
///   the trade then reads "Sent", then "Settled", or "Returned: nothing traded.", under Your
///   trades, Open then Past. Market trades only.
///
/// Every word it shows is a [UserWords] or [MarketWords] entry, none of [kUserModeForbiddenWords]
/// (user_trade_test.dart and market_view_test.dart check).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/ark_btc_lightning.dart';
import '../data/ark_btc_service.dart';
import '../data/btc_lightning.dart';
import '../data/config.dart';
import '../data/dev_mode.dart';
import '../data/asset_picker.dart' show AssetPickerItem;
import '../data/format.dart';
import '../data/hidden_assets.dart';
import '../data/leaf_rail.dart' show offerForVerify;
import '../data/leaf_service.dart';
import '../data/lightning_service.dart';
import '../data/ln_rail.dart';
import '../data/lsp_client.dart';
import '../data/market_view.dart';
import '../data/price_service.dart';
import '../data/seqln_keys.dart' as lnkeys;
import '../data/user_trade.dart';
import '../data/wallet_cache.dart';
import '../data/wallet_repository.dart';
import '../rust/api.dart' as core;
import '../widgets/asset_sheet.dart';
import '../widgets/market_view.dart';

/// The wallet's own hosted Bitcoin node, as the composer's BTC trades drive it ([HostedBtcLightning]:
/// holds under the wallet's own hash, payments capped at the ticket's route), once Lightning runs
/// for this build; null before.
BtcLightning? _btcLn;
String? _btcLnTag;
BtcLightning? appBtcLightning(String walletTag) {
  if (!LightningService.instance.configured) return null;
  if (_btcLn != null && _btcLnTag == walletTag) return _btcLn;
  Future<String>? up;
  Future<String> nodeKey() async {
    // Brought up once, and again after a failure (the node may have restarted).
    final f = up ??= () async {
      final k = await LightningService.instance.btcNodeKey();
      await LspClient.waitNodeReady(k);
      return k;
    }();
    try {
      return await f;
    } catch (_) {
      up = null;
      rethrow;
    }
  }

  // The wallet's own BTC channels, as /status reports them now: read again at each call, never
  // kept, so room a first trade's node was just given shows at once.
  Future<LegLiquidity> btcLeg() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return legLiquidity(const [], RailTarget.btc());
    final st = await LightningService.instance.getStatus(nodes: [lnkeys.ownNodeKeyForBtc(m)]);
    return legLiquidity(((st.raw['channels'] as List?) ?? const []).whereType<Map>().toList(), RailTarget.btc());
  }

  final key = 'ambra.btcln.holds.$walletTag';
  _btcLnTag = walletTag;
  return _btcLn = HostedBtcLightning(
    lsp: const LspBtcCalls(),
    nodeKey: nodeKey,
    spendable: () async => (await btcLeg()).spendable,
    receivable: () async => (await btcLeg()).receivable,
    read: () async => (await SharedPreferences.getInstance()).getString(key),
    write: (v) async => (await SharedPreferences.getInstance()).setString(key, v),
    log: (m) => debugPrint(m),
  );
}

/// The Bitcoin ark as the composer's Bitcoin Lightning: in default mode a trade's BTC is paid
/// from the ark and received into it, like every other BTC payment there.
final ArkBtcLightning _arkLn = ArkBtcLightning(const CoreArkCalls(), onMoved: () => ArkBtcService.instance.refresh());

/// The BTC rail new trades take: the ark in default mode once it is open, else the wallet's own
/// hosted Bitcoin node (developer mode always: it leaves the rails to the person).
String appBtcRail() => !DevMode.instance.on && ArkBtcService.instance.open ? 'ark' : 'lightning';

/// The wallet's Bitcoin Lightning on `rail`: the ark (null while it is not open) or the hosted node.
BtcLightning? appBtcOn(String rail, String walletTag) =>
    rail == 'ark' ? (ArkBtcService.instance.open ? _arkLn : null) : appBtcLightning(walletTag);

/// The engine as the app runs it: the leaf library through [LeafService], the maker and the
/// relay at the app's backend, the pairs list the drill keeps (the web wallet's
/// `user-mode/pairs.json`, served at [Backend.userModePairs]). One per wallet: the Swap tab and
/// a connected site's orders share it, and with it one list of trades.
final _engines = <String, UserTradeEngine>{};
UserTradeEngine appTradeEngine({required String walletTag}) => _engines[walletTag] ??= _newTradeEngine(walletTag);

UserTradeEngine _newTradeEngine(String walletTag) {
  // A read (a maker's quotes) that has not answered in 20 s is given up, so a silent maker costs
  // the price one source rather than holding it. A POST runs for as long as [kMakerPostTimeout]:
  // a firm offer or an acceptance can take minutes at a busy maker, and a firm cut short reads as
  // "too small to trade" while the maker was still pricing it (the web wallet leaves them to run).
  Future<Map<String, dynamic>> fetchJson(String url, {Map<String, dynamic>? post}) async {
    final r = post == null
        ? await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20))
        : await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode(post)).timeout(kMakerPostTimeout);
    Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      j = {};
    }
    if (r.statusCode != 200) throw Exception('${j['error'] ?? 'HTTP ${r.statusCode}'}');
    return j;
  }

  Future<List<Map<String, dynamic>>> one(String base, String quote) async {
    try {
      final r = await http.get(Uri.parse('${Backend.seqob}/v1/market/$base/$quote/orderbook')).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return const [];
      final j = jsonDecode(r.body) as Map;
      final list = (j['offers'] as List?) ?? const [];
      final statuses = (j['statuses'] as List?) ?? const [];
      final out = <Map<String, dynamic>>[];
      for (var i = 0; i < list.length; i++) {
        if (list[i] is! Map) continue;
        final o = Map<String, dynamic>.from(list[i] as Map);
        bool ok = false;
        try {
          ok = await core.seqobVerifyOffer(offerJson: jsonEncode(offerForVerify(o)));
        } catch (_) {}
        if (!ok) continue;
        // The library reads an order from the relay's own JSON; statuses[i] is what offers[i] can
        // be filled for now.
        out.add({...o, '_relayJson': Map<String, dynamic>.from(list[i] as Map), '_verified': true, '_status': i < statuses.length ? statuses[i] : null});
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // The pairs list and the chain are read once per node: a change of node reads them again.
  Map? pairsCache;
  String? genesis;
  String? readFrom;
  final key = 'ambra.usertrade.$walletTag';
  return UserTradeEngine(UserTradeDeps(
    // A trade that needs a planned coin is made through the next round, by itself; a
    // refusal user mode has plain words for is said in them.
    // The engine's own following of a trade (its syncs and reads) is not a person's action: it
    // keeps no board waiting, so coins arriving while a trade waits still move in.
    run: (cmd, args) => LeafService.instance.pay(cmd, args, true, !kFollowCommands.contains(cmd)),
    fetchJson: fetchJson,
    makers: () => [Backend.leafMaker, Backend.leafMakerBtc],
    relayBook: (pay, receive) async => [...await one(receive, pay), ...await one(pay, receive)],
    relayFills: (pay, receive) async {
      Future<List<Map<String, dynamic>>> fills(String base, String quote) async {
        try {
          final r = await http.get(Uri.parse('${Backend.seqob}/v1/market/$base/$quote/fills?limit=500')).timeout(const Duration(seconds: 30));
          if (r.statusCode != 200) return const [];
          return [for (final f in ((jsonDecode(r.body) as Map)['fills'] as List?) ?? const []) Map<String, dynamic>.from(f as Map)];
        } catch (_) {
          return const [];
        }
      }

      return [...await fills(receive, pay), ...await fills(pay, receive)];
    },
    admitted: () async {
      if (readFrom != Backend.origin) {
        pairsCache = null;
        genesis = null;
        readFrom = Backend.origin;
      }
      try {
        pairsCache ??= jsonDecode((await http.get(Uri.parse(Backend.userModePairs)).timeout(const Duration(seconds: 20))).body) as Map;
      } catch (_) {
        pairsCache = null;
      }
      if (genesis == null) {
        try {
          final h = (await http.get(Uri.parse('${Backend.esplora}/block-height/0')).timeout(const Duration(seconds: 20))).body.trim();
          if (RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) genesis = h;
        } catch (_) {}
      }
      // A pair with a supervised asset only as the operator serves it: the in-tree swap.
      return (pairs: servedPairs(pairsCache, LeafService.instance.supervisedAssets()), genesis: genesis);
    },
    read: () async => (await SharedPreferences.getInstance()).getString(key),
    write: (v) async => (await SharedPreferences.getInstance()).setString(key, v),
    btc: () => appBtcOn(appBtcRail(), walletTag),
    btcRail: appBtcRail,
    btcOf: (rail) => appBtcOn(rail, walletTag),
    // What the balance shows of an asset (on the chain and as leaves): one held but not payable
    // yet reads as not ready, and default mode is asked to board it.
    held: (a) async {
      var chain = BigInt.zero;
      for (final b in await WalletCache.loadBalances() ?? const []) {
        if (b.assetId == a) chain = BigInt.tryParse(b.atoms) ?? BigInt.zero;
      }
      return chain + (LeafService.instance.leafAtoms()[a] ?? BigInt.zero);
    },
    prepare: (_) => LeafService.instance.boardSoon(),
    // Coins a refresh plan keeps are freed for a trade in the wallet's next round.
    release: (a, leaves) => LeafService.instance.releaseFor(a, leaves),
    log: (m) => debugPrint(m),
  ));
}

/// How long the composer waits for a maker's answer to a POST (a firm offer, an acceptance).
const Duration kMakerPostTimeout = Duration(minutes: 5);

class UserComposer extends StatefulWidget {
  const UserComposer({super.key, required this.engine, required this.assets, required this.held, required this.ticker,
      required this.precision, this.admittedReceives, this.onMoved, this.known, this.isHidden, this.refValue, this.relay, this.marketGet});
  final UserTradeEngine engine;
  /// What can be paid: BTC always, and every other asset the wallet holds.
  final List<String> Function() assets;
  final BigInt Function(String asset) held;
  final String Function(String asset) ticker;
  final int Function(String asset) precision;
  final Future<List<String>> Function(String pay)? admittedReceives;
  /// Called after open trades moved on, so the app reads its balances again.
  final Future<void> Function()? onMoved;
  /// Every asset the wallet can name (the registry's), which the receive chooser's search reaches.
  final List<String> Function()? known;
  final bool Function(String asset)? isHidden;
  /// An amount's value in the reference currency, in words ("≈ 1.23 USD"), or null.
  final String? Function(String asset, BigInt atoms)? refValue;
  /// The relay's base URL, for the market view; no market view without it.
  final String Function()? relay;
  final MarketGet? marketGet;

  @override
  State<UserComposer> createState() => _UserComposerState();
}

/// How long a trade is followed every few seconds, and how often after that.
const int kFollowFastMs = 120000;
const int kFollowSlowMs = 30000;

class _UserComposerState extends State<UserComposer> {
  String? _pay, _get;
  bool _payChosen = false, _getChosen = false;
  final _amount = TextEditingController();
  final _receive = TextEditingController();
  final _amountFocus = FocusNode(), _receiveFocus = FocusNode();
  /// Which amount the person typed: 'pay' or 'receive'. The other follows the book.
  String _fixed = 'pay';
  Ticket? _ticket;
  Candidate? _choice;
  bool _busy = false;
  String? _note, _error;
  List<Map<String, dynamic>> _trades = [];
  List<String> _admitted = [];
  ({String pay, List<String> list, int at})? _offered;
  bool _offeredLoading = false;
  Timer? _timer, _estTimer, _refresh;
  int _estSeq = 0;

  String _amt(String asset, BigInt atoms) => '${formatAtoms('$atoms', widget.precision(asset))} ${widget.ticker(asset)}';

  List<String> _payList() => pickerOrder(widget.assets(), widget.held, widget.ticker);
  List<String> _offeredNow() => _offered != null && _offered!.pay == _pay ? _offered!.list.where((a) => a != _pay).toList() : const [];
  List<String> _getList() {
    final all = pickerOrder({...widget.assets(), ...?widget.known?.call()}, widget.held, widget.ticker).where((a) => a != _pay).toList();
    // BTC first, then what the book offers for this asset now, then what is admitted, then the rest.
    return {
      if (_pay != kUserBtc) kUserBtc,
      ..._offeredNow(),
      ..._admitted.where((a) => a != _pay),
      ...all,
    }.where((a) => a != _pay).toList();
  }

  String? _defaultGet(List<String> gl) {
    final o = _offeredNow();
    for (final a in gl) {
      if (o.contains(a)) return a;
    }
    return gl.isEmpty ? null : gl.first;
  }

  StreamSubscription<void>? _changed;
  bool _following = false;

  @override
  void initState() {
    super.initState();
    _loadTrades().then((_) => _follow());
    // A trade made elsewhere (a connected site's) shows at once, and is followed.
    _changed = widget.engine.changes.listen((_) async {
      await _loadTrades();
      if (!_following && !(_timer?.isActive ?? false)) _timer = Timer(const Duration(seconds: 4), _follow);
    });
    // The amount not typed follows the price every ten seconds while the tab is shown.
    _refresh = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && TickerMode.valuesOf(context).enabled) _schedule(0);
    });
  }

  @override
  void dispose() {
    _changed?.cancel();
    _timer?.cancel();
    _estTimer?.cancel();
    _refresh?.cancel();
    _amount.dispose();
    _receive.dispose();
    _amountFocus.dispose();
    _receiveFocus.dispose();
    super.dispose();
  }

  Future<void> _loadTrades() async {
    final r = await widget.engine.records();
    if (mounted) setState(() => _trades = r);
  }

  Future<void> _receivesFor(String? pay) async {
    if (pay == null || widget.admittedReceives == null) return;
    final r = await widget.admittedReceives!(pay);
    if (mounted) setState(() => _admitted = r);
  }

  /// The book's offers for what is paid, asked when that changes and again after a minute.
  Future<void> _loadOffered() async {
    final pay = _pay;
    if (pay == null || _offeredLoading) return;
    if (_offered != null && _offered!.pay == pay && DateTime.now().millisecondsSinceEpoch - _offered!.at < 60000) return;
    _offeredLoading = true;
    List<String> list = const [];
    try {
      list = await widget.engine.offered(pay);
    } catch (e) {
      debugPrint('[user composer] offers: $e');
    }
    _offeredLoading = false;
    if (!mounted) return;
    setState(() => _offered = (pay: pay, list: list, at: DateTime.now().millisecondsSinceEpoch));
    if (pay != _pay) {
      _loadOffered();
    } else if (!_getChosen && _ticket == null && !_busy) {
      final was = _get;
      setState(() => _get = _defaultGet(_getList()));
      if (_get != was) _schedule(0);
    }
  }

  void _reset() {
    _ticket = null;
    _choice = null;
    _note = null;
    _error = null;
  }

  // ---- You pay and You receive, tethered ----
  void _schedule([int ms = 350]) {
    _estTimer?.cancel();
    _estTimer = Timer(Duration(milliseconds: ms), () => _estimateNow().catchError((e) => debugPrint('[user composer] estimate: $e')));
  }

  Future<void> _estimateNow() async {
    final pay = _pay, get = _get;
    if (pay == null || get == null || _ticket != null || _busy || !mounted) return;
    final typedPay = _fixed == 'pay';
    final typed = typedPay ? _amount.text : _receive.text;
    final atoms = parseAtoms(typed.trim(), widget.precision(typedPay ? pay : get));
    final other = typedPay ? _receive : _amount;
    final otherFocus = typedPay ? _receiveFocus : _amountFocus;
    if (atoms == null || atoms <= BigInt.zero) {
      if (!otherFocus.hasFocus) other.text = '';
      setState(() => _note = null);
      return;
    }
    final seq = ++_estSeq;
    final e = await widget.engine.estimate(pay: pay, receive: get, payAtoms: typedPay ? atoms : null, receiveAtoms: typedPay ? null : atoms);
    if (!mounted || seq != _estSeq || _ticket != null || pay != _pay || get != _get) return;
    setState(() {
      if (!e.ok) {
        final p = widget.ticker(pay), g = widget.ticker(get);
        _note = switch (e.why) { 'not-listed' => UserWords.notListed(g, p), 'too-small' => UserWords.tooSmall, _ => UserWords.notOffered(g, p) };
        if (!otherFocus.hasFocus) other.text = '';
        return;
      }
      final fill = typedPay ? formatAtoms('${e.receive}', widget.precision(get)) : formatAtoms('${e.pay}', widget.precision(pay));
      if (!otherFocus.hasFocus) other.text = fill;
      _note = e.short != null ? UserWords.bookUpTo(_amt(get, e.short!.receive)) : null;
    });
  }

  Future<void> _review() async {
    setState(_reset);
    final atoms = parseAtoms(_amount.text.trim(), widget.precision(_pay!));
    if (atoms == null || atoms <= BigInt.zero) {
      setState(() => _error = UserWords.enter);
      return;
    }
    if (_get == null) return;
    setState(() => _busy = true);
    try {
      final q = await widget.engine.quote(pay: _pay!, receive: _get!, amount: atoms);
      setState(() {
        if (q.ok) {
          _ticket = q.ticket;
          _choice = q.choice;
        } else {
          final p = widget.ticker(_pay!), g = widget.ticker(_get!);
          _error = switch (q.why) {
            'no-funds' => UserWords.noFunds(p),
            'not-ready' => UserWords.notReady(p),
            'freeing' => UserWords.freeing(p),
            'too-small' => UserWords.tooSmall,
            'not-listed' => UserWords.notListed(g, p),
            _ => UserWords.notOffered(g, p),
          };
        }
      });
    } catch (e) {
      debugPrint('[user composer] quote: $e');
      setState(() => _error = e is LeafRefusal && e.plain ? e.message : UserWords.notOffered(widget.ticker(_get!), widget.ticker(_pay!)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final c = _choice, t = _ticket;
    if (c == null || t == null) return;
    setState(() => _busy = true);
    try {
      await widget.engine.confirm(c, t);
      setState(() {
        _reset();
        _amount.clear();
        _receive.clear();
      });
    } on LapsedError {
      setState(_reset);
      setState(() => _busy = false);
      await _review();
      if (mounted && _ticket != null) setState(() => _note = UserWords.priceMoved);
    } catch (e) {
      debugPrint('[user composer] confirm: $e');
      setState(() {
        _reset();
        _error = e is LeafRefusal && e.plain ? e.message : UserWords.failed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      await _loadTrades();
      _follow();
    }
  }

  /// Open trades move on every few seconds while any is open, and every half minute once older
  /// than two minutes; never while a person is pricing or confirming one.
  Future<void> _follow() async {
    _timer?.cancel();
    final openRecs = _trades.where((r) => !['settled', 'returned', 'failed'].contains(r['state'])).toList();
    if (openRecs.isEmpty || !mounted || _following) return;
    if (_busy) {
      _timer = Timer(const Duration(seconds: 4), _follow);
      return;
    }
    _following = true;
    try {
      await widget.engine.resume();
      await widget.onMoved?.call();
    } catch (e) {
      debugPrint('[user composer] resume: $e');
    } finally {
      _following = false;
    }
    await _loadTrades();
    final now = DateTime.now().millisecondsSinceEpoch;
    final young = openRecs.any((r) => now - (((r['sentAt'] ?? r['at']) as num?)?.toInt() ?? 0) < kFollowFastMs);
    if (mounted) _timer = Timer(Duration(milliseconds: young ? 4000 : kFollowSlowMs), _follow);
  }

  String _stateWord(Map r) {
    if (r['state'] == 'settled') return UserWords.settled;
    final fees = (r['feesPaid'] as List?) ?? const [];
    if (r['state'] == 'returned' && fees.isNotEmpty) {
      return UserWords.returnedFees([for (final f in fees) _amt('${(f as Map)['asset']}', BigInt.parse('${f['atoms']}'))].join(' and '));
    }
    return tradeStateWord(r, DateTime.now().millisecondsSinceEpoch) ?? UserWords.returned;
  }

  /// A picker: a button naming the asset chosen, which opens the wallet's one asset chooser.
  Widget _chooser(String key, List<String> list, String? value, void Function(String) onChanged) {
    final offered = _offeredNow().toSet();
    final tradable = key == 'ucGet' ? _admitted.toSet() : const <String>{};
    // The button reads as the asset it names, to a screen reader as on screen.
    return Semantics(
      container: true,
      button: true,
      label: '${key == 'ucPay' ? UserWords.pay : UserWords.get}: ${value == null ? '' : widget.ticker(value)}',
      excludeSemantics: true,
      child: OutlinedButton(
      key: ValueKey(key),
      onPressed: _busy
          ? null
          : () async {
              final rows = [
                for (final h in list)
                  AssetPickerItem(
                    hex: h,
                    ticker: widget.ticker(h),
                    name: h == kUserBtc ? 'Bitcoin' : SeqAssets.labelFor(h).subtitle,
                    held: widget.held(h) > BigInt.zero,
                    hidden: widget.isHidden?.call(h) ?? false,
                    offered: offered.contains(h),
                    tradable: tradable.contains(h),
                    value: widget.held(h) > BigInt.zero ? widget.refValue?.call(h, widget.held(h)) : null,
                  ),
              ];
              final picked = await showAssetSheet(context,
                  title: key == 'ucPay' ? UserWords.pay : UserWords.get,
                  rows: rows,
                  registrySearch: true,
                  balanceOf: (h) => widget.held(h) > BigInt.zero ? formatAtoms('${widget.held(h)}', widget.precision(h)) : '');
              if (picked != null && mounted) onChanged(picked);
            },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(value == null ? '…' : widget.ticker(value), key: ValueKey('$key-${value ?? ''}')),
        const SizedBox(width: 4),
        const Icon(Icons.arrow_drop_down, size: 18),
      ]),
    ));
  }

  Widget _amountField(String key, TextEditingController c, FocusNode f, String side) => TextField(
        key: ValueKey(key),
        controller: c,
        focusNode: f,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(hintText: UserWords.amount),
        onChanged: (_) {
          _fixed = side;
          setState(() {
            _error = null;
            if (_ticket != null) _reset();
          });
          _schedule();
        },
      );

  @override
  Widget build(BuildContext context) {
    final pays = _payList();
    if (_pay == null || !_payChosen || !pays.contains(_pay)) {
      final first = pays.firstWhere((a) => widget.held(a) > BigInt.zero, orElse: () => pays.first);
      if (first != _pay) {
        _pay = first;
        unawaited(_receivesFor(_pay));
      }
    }
    unawaited(_loadOffered());
    final gets = _getList();
    if (_get == null || !gets.contains(_get)) _get = _defaultGet(gets);
    final t = _ticket;
    final shown = _trades.where((r) => (r['state'] != 'confirming' || r['uncertain'] == true) && r['ticket'] is Map).toList().reversed.take(12).toList();
    bool done(Map r) => ['settled', 'returned', 'failed'].contains(r['state']);
    final dir = _pay != null && _get != null && _pay != _get ? canonicalPair(_pay!, _get!, widget.ticker) : null;
    return ListView(key: const ValueKey('userComposer'), padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
      Text(UserWords.title, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      if (dir != null && widget.relay != null) ...[
        MarketView(
            key: const ValueKey('ucMarketView'),
            base: dir.base,
            quote: dir.quote,
            ticker: widget.ticker,
            precision: widget.precision,
            relay: widget.relay!,
            get: widget.marketGet),
        const SizedBox(height: 16),
      ],
      Text(UserWords.pay, style: Theme.of(context).textTheme.labelLarge),
      Row(children: [
        _chooser('ucPay', pays, _pay, (v) {
          setState(() {
            _pay = v;
            _payChosen = true;
            _getChosen = false;
            _get = null;
            _reset();
          });
          _receivesFor(v);
          _schedule(0);
        }),
        const SizedBox(width: 12),
        Expanded(child: _amountField('ucAmount', _amount, _amountFocus, 'pay')),
      ]),
      if (_pay != null)
        Row(key: const ValueKey('ucHave'), children: [
          Expanded(child: Text(UserWords.balance(_amt(_pay!, widget.held(_pay!))), style: Theme.of(context).textTheme.bodySmall)),
          TextButton(
              key: const ValueKey('ucMax'),
              onPressed: _busy || widget.held(_pay!) <= BigInt.zero
                  ? null
                  : () {
                      _amount.text = formatAtoms('${widget.held(_pay!)}', widget.precision(_pay!));
                      _fixed = 'pay';
                      setState(() {
                        if (_ticket != null) _reset();
                      });
                      _schedule(0);
                    },
              child: const Text(UserWords.max)),
        ]),
      const SizedBox(height: 12),
      Text(UserWords.get, style: Theme.of(context).textTheme.labelLarge),
      Row(children: [
        _chooser('ucGet', gets, _get, (v) {
          setState(() {
            _get = v;
            _getChosen = true;
            _reset();
          });
          _schedule(0);
        }),
        const SizedBox(width: 12),
        Expanded(child: _amountField('ucReceive', _receive, _receiveFocus, 'receive')),
      ]),
      const SizedBox(height: 16),
      if (t != null) ...[
        _line(UserWords.pay, _amt(t.payAsset, t.amountIn), 'ucIn'),
        _line(UserWords.get, _amt(t.receiveAsset, t.amountOut), 'ucOut'),
        Text(costLine(t.fees, _amt, t.payAsset), key: const ValueKey('ucCost'), style: Theme.of(context).textTheme.bodySmall),
        if (t.upTo != null) Text(UserWords.upTo(_amt(t.payAsset, t.upTo!))),
        const SizedBox(height: 12),
      ],
      if ((_error ?? _note) != null)
        Text(_error ?? _note!, key: const ValueKey('ucNote'), style: TextStyle(color: _error != null ? Theme.of(context).colorScheme.error : null)),
      const SizedBox(height: 12),
      if (t == null)
        FilledButton(key: const ValueKey('ucReview'), onPressed: _busy || _pay == null || _get == null ? null : _review,
            child: Text(_busy ? UserWords.pricing : UserWords.review))
      else
        Row(children: [
          FilledButton(key: const ValueKey('ucConfirm'), onPressed: _busy ? null : _confirm, child: Text(_busy ? UserWords.working : UserWords.confirm)),
          const SizedBox(width: 12),
          TextButton(
              key: const ValueKey('ucCancel'),
              onPressed: _busy
                  ? null
                  : () {
                      widget.engine.drop(_choice);
                      setState(_reset);
                      _schedule(0);
                    },
              child: const Text(UserWords.cancel)),
        ]),
      if (shown.isNotEmpty) ...[
        const SizedBox(height: 24),
        Text(UserWords.recent, style: Theme.of(context).textTheme.labelLarge),
        for (final (word, group) in [(UserWords.openTrades, shown.where((r) => !done(r)).toList()), (UserWords.pastTrades, shown.where(done).take(8).toList())])
          if (group.isNotEmpty) ...[
            Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Text(word, key: ValueKey('ucGroup-$word'), style: Theme.of(context).textTheme.bodySmall)),
            for (final r in group)
              Padding(
                key: ValueKey('ucTrade-${r['id']}'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                // A short status beside the amounts; a sentence (a returned trade) on its own line
                // under them, so neither squeezes the other.
                child: Builder(builder: (_) {
                  final amounts = Text(
                      '${_amt('${(r['ticket'] as Map)['payAsset']}', BigInt.parse('${(r['ticket'] as Map)['amountIn']}'))} → ${_amt('${(r['ticket'] as Map)['receiveAsset']}', BigInt.parse('${(r['ticket'] as Map)['amountOut']}'))}');
                  final word = _stateWord(r);
                  final state = Text(word, key: ValueKey('ucState-${r['id']}'));
                  if (word.length <= 16) return Row(children: [Expanded(child: amounts), state]);
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [amounts, state]);
                }),
              ),
          ],
      ],
    ]);
  }

  Widget _line(String k, String v, String key) => Padding(
        key: ValueKey(key),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Expanded(child: Text(k)), Text(v)]),
      );
}

/// The composer's chooser and figures as the app draws them: hidden assets, values in the
/// reference currency.
bool appIsHidden(String h) => HiddenAssets.instance.isHidden(h);
String? appRefValue(String h, BigInt atoms) =>
    h == kUserBtc ? PriceService.instance.approx('BTC', '$atoms', 8) : PriceService.instance.approx(SeqAssets.labelFor(h).ticker, '$atoms', SeqAssets.labelFor(h).precision);
