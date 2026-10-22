/// The Swap tab in user mode: what I pay, what I get, how much, one button.
///
/// The engine ([UserTradeEngine], `data/user_trade.dart`) reads the single-step book, prices the
/// trade with the leaf library and settles it in one native step; this widget draws it. Before
/// the button confirms it shows three lines: what you pay, what you get, and the fees. After it,
/// the trade reads "Sent", then "Settled", or "Returned: nothing traded." Market trades only.
/// Both pickers list BTC first. Every word it shows is a [UserWords] entry, none of
/// [kUserModeForbiddenWords] (user_trade_test.dart checks both).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/btc_lightning.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/leaf_rail.dart' show offerForVerify;
import '../data/leaf_service.dart';
import '../data/lightning_service.dart';
import '../data/ln_rail.dart';
import '../data/lsp_client.dart';
import '../data/seqln_keys.dart' as lnkeys;
import '../data/user_trade.dart';
import '../data/wallet_repository.dart';
import '../rust/api.dart' as core;

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

  // The wallet's own BTC channels, as /status reports them.
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

/// The engine as the app runs it: the leaf library through [LeafService], the maker and the
/// relay at the app's backend, the pairs list the drill keeps (the web wallet's
/// `user-mode/pairs.json`, served at [Backend.userModePairs]).
UserTradeEngine appTradeEngine({required String walletTag}) {
  Future<Map<String, dynamic>> fetchJson(String url, {Map<String, dynamic>? post}) async {
    final r = post == null
        ? await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30))
        : await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode(post)).timeout(const Duration(seconds: 60));
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
    run: (cmd, args) => LeafService.instance.pay(cmd, args, true),
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
    btc: () => appBtcLightning(walletTag),
    log: (m) => debugPrint(m),
  ));
}

class UserComposer extends StatefulWidget {
  const UserComposer({super.key, required this.engine, required this.assets, required this.held, required this.ticker,
      required this.precision, this.admittedReceives, this.onMoved});
  final UserTradeEngine engine;
  final List<String> Function() assets;
  final BigInt Function(String asset) held;
  final String Function(String asset) ticker;
  final int Function(String asset) precision;
  final Future<List<String>> Function(String pay)? admittedReceives;
  /// Called after open trades moved on, so the app reads its balances again.
  final Future<void> Function()? onMoved;

  @override
  State<UserComposer> createState() => _UserComposerState();
}

class _UserComposerState extends State<UserComposer> {
  String? _pay, _get;
  bool _payChosen = false;
  final _amount = TextEditingController();
  Ticket? _ticket;
  Candidate? _choice;
  bool _busy = false;
  String? _note, _error;
  List<Map<String, dynamic>> _trades = [];
  List<String> _firstReceives = [];
  Timer? _timer;

  String _amt(String asset, BigInt atoms) => '${formatAtoms('$atoms', widget.precision(asset))} ${widget.ticker(asset)}';

  List<String> _payList() => pickerOrder(widget.assets(), widget.held, widget.ticker);
  List<String> _getList() {
    final all = pickerOrder(widget.assets(), widget.held, widget.ticker).where((a) => a != _pay).toList();
    return {
      if (all.contains(kUserBtc)) kUserBtc,
      ..._firstReceives.where((a) => a != _pay && a != kUserBtc),
      ...all,
    }.toList();
  }

  @override
  void initState() {
    super.initState();
    _loadTrades().then((_) => _follow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _loadTrades() async {
    final r = await widget.engine.records();
    if (mounted) setState(() => _trades = r);
  }

  Future<void> _receivesFor(String? pay) async {
    if (pay == null || widget.admittedReceives == null) return;
    final r = await widget.admittedReceives!(pay);
    if (mounted) setState(() => _firstReceives = r);
  }

  void _reset() {
    _ticket = null;
    _choice = null;
    _note = null;
    _error = null;
  }

  Future<void> _review() async {
    setState(_reset);
    final atoms = parseAtoms(_amount.text, widget.precision(_pay!));
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

  Future<void> _follow() async {
    _timer?.cancel();
    final open = _trades.any((r) => !['settled', 'returned', 'failed'].contains(r['state']));
    if (!open || !mounted) return;
    try {
      await widget.engine.resume();
      await widget.onMoved?.call();
    } catch (e) {
      debugPrint('[user composer] resume: $e');
    }
    await _loadTrades();
    if (mounted) _timer = Timer(const Duration(seconds: 4), _follow);
  }

  String _stateWord(Map r) {
    if (r['state'] == 'settled') return UserWords.settled;
    final fees = (r['feesPaid'] as List?) ?? const [];
    if (r['state'] == 'returned' && fees.isNotEmpty) {
      return UserWords.returnedFees([for (final f in fees) _amt('${(f as Map)['asset']}', BigInt.parse('${f['atoms']}'))].join(' and '));
    }
    if (r['state'] == 'returned' || r['state'] == 'failed') return UserWords.returned;
    return UserWords.sent;
  }

  Widget _picker(String key, List<String> list, String? value, void Function(String) onChanged) => DropdownButton<String>(
        key: ValueKey(key),
        value: list.contains(value) ? value : null,
        items: [for (final a in list) DropdownMenuItem(value: a, child: Text(widget.ticker(a), key: ValueKey('$key-$a')))],
        onChanged: _busy ? null : (v) => v == null ? null : onChanged(v),
      );

  @override
  Widget build(BuildContext context) {
    final pays = _payList();
    if (_pay == null || !_payChosen) {
      final first = pays.firstWhere((a) => widget.held(a) > BigInt.zero, orElse: () => pays.first);
      if (first != _pay) {
        _pay = first;
        unawaited(_receivesFor(_pay));
      }
    }
    final gets = _getList();
    if (_get == null || !gets.contains(_get)) _get = gets.isEmpty ? null : gets.first;
    final t = _ticket;
    final shown = _trades.where((r) => r['state'] != 'confirming' && r['ticket'] is Map).toList().reversed.take(8).toList();
    return ListView(key: const ValueKey('userComposer'), padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
      Text(UserWords.title, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 16),
      Text(UserWords.pay, style: Theme.of(context).textTheme.labelLarge),
      Row(children: [
        _picker('ucPay', pays, _pay, (v) {
          setState(() {
            _pay = v;
            _payChosen = true;
            if (_get == v) _get = null;
            _reset();
          });
          _receivesFor(v);
        }),
        const SizedBox(width: 12),
        Expanded(
            child: TextField(
                key: const ValueKey('ucAmount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(hintText: UserWords.amount),
                onChanged: (_) {
                  if (_ticket != null) setState(_reset);
                })),
      ]),
      if (_pay != null) Text(_amt(_pay!, widget.held(_pay!)), key: const ValueKey('ucHave'), style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      Text(UserWords.get, style: Theme.of(context).textTheme.labelLarge),
      _picker('ucGet', gets, _get, (v) => setState(() {
            _get = v;
            _reset();
          })),
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
                      final c = _choice;
                      if (c?.offer != null) widget.engine.release(c!.entry.maker, '${c.offer!['swap']}');
                      setState(_reset);
                    },
              child: const Text(UserWords.cancel)),
        ]),
      if (shown.isNotEmpty) ...[
        const SizedBox(height: 24),
        Text(UserWords.recent, style: Theme.of(context).textTheme.labelLarge),
        for (final r in shown)
          Padding(
            key: ValueKey('ucTrade-${r['id']}'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(
                  child: Text(
                      '${_amt('${(r['ticket'] as Map)['payAsset']}', BigInt.parse('${(r['ticket'] as Map)['amountIn']}'))} → ${_amt('${(r['ticket'] as Map)['receiveAsset']}', BigInt.parse('${(r['ticket'] as Map)['amountOut']}'))}')),
              Text(_stateWord(r), key: ValueKey('ucState-${r['id']}')),
            ]),
          ),
      ],
    ]);
  }

  Widget _line(String k, String v, String key) => Padding(
        key: ValueKey(key),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Expanded(child: Text(k)), Text(v)]),
      );
}
