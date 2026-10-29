/// The user-mode composer's engine: one market trade, in one native step.
///
/// The same rules as the web wallet's `user-trade.js` and `tooling/lsp/single-step-book.mjs`
/// (change them together). The person names what they pay, what they get and how much they pay.
/// The engine reads the single-step book (a live leaf maker's in-tree swap quotes; transparent
/// covenant orders a round can take from leaves), asks the leaf library to price each candidate
/// it can fill, picks one (the most received, then the fewest parties), and makes the ticket:
/// amount in, amount out, one cost line. On confirm it takes that one step and follows the trade
/// to Settled, or Returned when nothing traded. It never falls back to another source.
///
/// Every amount on a ticket is the library's answer (`swap_read`, `take_quote` with `spends`,
/// `settle_quote`); this file compares and adds the library's numbers and decides nothing the
/// library decides.
library;

import 'dart:convert';

import 'btc_lightning.dart';
import 'user_trade_btc.dart';

const String kUserBtc = 'BTC';

/// How long the wallet waits for a maker to complete a swap it accepted before it cancels it.
const int kMakerCompleteMs = 120000;

/// A maker's firm offer is accepted only while at least this long is left before it lapses.
const int kFirmMarginMs = 20000;

/// The most the operator's fee may be of a price, in millionths, in user mode.
const int kMaxFeePpm = 10000;

/// Words a default screen must never show. Lower case; matched as whole words.
const List<String> kUserModeForbiddenWords = [
  'rail',
  'rails',
  'round',
  'rounds',
  'leaf',
  'leaves',
  'operator',
  'covenant',
  'covenants',
  'expiry',
  'atom',
  'atoms',
  'forfeit',
  'forfeits',
  'channel',
  'channels',
  'relay',
  'maker',
  'makers',
  'hash',
  'preimage',
  'htlc',
  'submarine',
  'lsp',
  'tree',
  'anchor',
  'unroll',
  'exit',
  'checkpoint',
  'reassignment',
  'on-chain',
  'lightning',
  'bridge',
  'gateway',
];

List<String> forbiddenIn(String text) {
  final t = text.toLowerCase();
  return kUserModeForbiddenWords.where((w) => RegExp('(^|[^a-z-])${RegExp.escape(w)}([^a-z-]|\$)').hasMatch(t)).toList();
}

/// Every string the user composer shows.
class UserWords {
  static const title = 'Swap';
  static const pay = 'You pay';
  static const get = 'You get';
  static const amount = 'Amount';
  static const review = 'Review';
  static const confirm = 'Trade';
  static const cancel = 'Cancel';
  static const fees = 'Fees';
  static const included = 'included above';
  static const noFees = 'No fees';
  static String upTo(String x) => 'Up to $x can be traded now.';
  static String notOffered(String get, String pay) => 'Not offered right now: nobody offers $get for $pay in one step.';
  static String notListed(String get, String pay) => '$get for $pay is not offered.';
  static const enter = 'Enter how much you pay.';
  static const tooSmall = 'That amount is too small to trade.';
  static String noFunds(String pay) => 'You have no $pay to trade.';
  static const pricing = 'Finding the best price…';
  static const priceMoved = 'The price moved. Here is the new one.';
  static const sent = 'Sent';
  static const settled = 'Settled';
  static const returned = 'Returned: nothing traded.';
  static String returnedFees(String fees) => 'Returned: nothing traded. Fees of $fees were paid.';
  static const working = 'Working…';
  static const failed = 'This trade could not be made. Nothing moved.';
  static const recent = 'Your trades';

  static List<String> all() => [
    title,
    pay,
    get,
    amount,
    review,
    confirm,
    cancel,
    fees,
    included,
    noFees,
    upTo('X'),
    notOffered('YT', 'XT'),
    notListed('YT', 'XT'),
    enter,
    tooSmall,
    noFunds('XT'),
    pricing,
    priceMoved,
    sent,
    settled,
    returned,
    returnedFees('1 XT'),
    working,
    failed,
    recent,
  ];
}

BigInt _big(Object? v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
BigInt _ceilDiv(BigInt a, BigInt b) => (a + b - BigInt.one) ~/ b;

/// The fees as one line, each in the asset it is paid in, the asset paid first.
String costLine(List<Map<String, dynamic>> fees, String Function(String asset, BigInt atoms) fmt, String payAsset) {
  final per = <String, BigInt>{};
  for (final f in fees) {
    final a = _big(f['atoms']);
    if (a <= BigInt.zero) continue;
    per['${f['asset']}'] = (per['${f['asset']}'] ?? BigInt.zero) + a;
  }
  if (per.isEmpty) return UserWords.noFees;
  final order = per.keys.toList()..sort((a, b) => a == payAsset ? -1 : (b == payAsset ? 1 : 0));
  final parts = order.map((a) => fmt(a, per[a]!)).toList();
  final joined = parts.length > 1 ? '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}' : parts.first;
  return '${UserWords.fees} $joined, ${UserWords.included}';
}

/// The pickers' order: BTC first whatever is held, then what is held, then the rest.
List<String> pickerOrder(Iterable<String> assets, BigInt Function(String) held, String Function(String) name) {
  final rest = assets.where((a) => a != kUserBtc).toSet().toList();
  int byName(String a, String b) => name(a).compareTo(name(b));
  final h = rest.where((a) => held(a) > BigInt.zero).toList()..sort(byName);
  final o = rest.where((a) => held(a) <= BigInt.zero).toList()..sort(byName);
  return [kUserBtc, ...h, ...o];
}

/// What the library can pay now, per asset: live coins, less the coin of every open
/// offline-refresh plan.
Map<String, BigInt> spendableFrom(List coins, Map? plans) {
  final planned = <String>{};
  for (final p in ((plans ?? const {})['plans'] as List?) ?? const []) {
    if (p is Map && !RegExp(r'^(done|cancelled|stopped|finished)$').hasMatch('${p['state'] ?? ''}')) planned.add('${p['coin']}');
  }
  final out = <String, BigInt>{};
  for (final c in coins) {
    if (c is! Map || c['state'] != 'live' || planned.contains('${c['leaf_id']}')) continue;
    out['${c['asset']}'] = (out['${c['asset']}'] ?? BigInt.zero) + _big(c['value']);
  }
  return out;
}

/// One entry of the single-step book.
class BookEntry {
  BookEntry({
    required this.source,
    required this.id,
    this.maker,
    required this.rateNum,
    required this.rateDen,
    required this.maxReceive,
    required this.minReceive,
    required this.lot,
    required this.raw,
  });
  final String source; // 'leaf-maker' | 'covenant-round' | 'leaf-resting' | 'btc-gateway'
  final String id;
  final String? maker;
  final BigInt rateNum, rateDen, lot;
  BigInt maxReceive, minReceive;
  final Map<String, dynamic> raw;
}

const Map<String, int> kSourceParties = {'onchain-fill': 0, 'covenant-round': 1, 'leaf-resting': 1, 'leaf-maker': 2, 'btc-gateway': 2};

/// A live maker's quotes for the pair. A quote with BTC on one side (in satoshis) is a
/// 'btc-gateway' entry, one hash-lock between a leaf and Bitcoin Lightning; any other is a
/// 'leaf-maker' one, an in-tree swap.
List<BookEntry> makerEntries(String maker, List quotes, {required String pay, required String receive}) {
  final out = <BookEntry>[];
  for (final q in quotes) {
    if (q is! Map || q['give_asset'] != receive || q['want_asset'] != pay) continue;
    final n = _big(q['rate_num']), d = _big(q['rate_den']), max = _big(q['max_give']), min = _big(q['min_give']);
    if (n <= BigInt.zero || d <= BigInt.zero || max <= BigInt.zero || max < min) continue;
    out.add(
      BookEntry(
        source: q['give_asset'] == kUserBtc || q['want_asset'] == kUserBtc ? 'btc-gateway' : 'leaf-maker',
        id: '$maker#${q['give_asset']}:${q['want_asset']}',
        maker: maker,
        rateNum: n,
        rateDen: d,
        maxReceive: max,
        minReceive: min > BigInt.zero ? min : BigInt.one,
        lot: BigInt.zero,
        raw: Map<String, dynamic>.from(q),
      ),
    );
  }
  return out;
}

/// The relay's transparent covenant orders selling `receive` for `pay` that a round can take.
List<BookEntry> covenantRoundEntries(List<Map<String, dynamic>> offers, {required String pay, required String receive}) {
  final out = <BookEntry>[];
  for (final o in offers) {
    if (o['_verified'] == false) continue;
    if ((o['offer_asset'] ?? o['offerAsset']) != receive || (o['want_asset'] ?? o['wantAsset']) != pay) continue;
    final c = o['covenant'] ?? o['Covenant'];
    if (c is! Map) continue;
    if (o['confidential'] == true || o['Confidential'] == true) continue;
    final n = _big(c['rate_num']), d = _big(c['rate_den']), lot = _big(c['min_lot']);
    var locked = _big(o['offer_amount']);
    final st = o['_status'];
    if (st is Map && st['active_amount'] != null) locked = _big(st['active_amount']);
    if (n <= BigInt.zero || d <= BigInt.zero || locked <= BigInt.zero) continue;
    out.add(
      BookEntry(
        source: 'covenant-round',
        id: '${c['covenant_txid']}:${c['covenant_vout']}',
        rateNum: n,
        rateDen: d,
        maxReceive: locked,
        minReceive: lot > BigInt.zero ? lot : BigInt.one,
        lot: lot,
        raw: o,
      ),
    );
  }
  return out;
}

/// The relay's orders resting in the tree of the wallet's operator (`operator`, its key) that sell
/// `receive` for `pay`: sized at the relay's live size, a fill taking at least a lot and leaving
/// nothing or at least a lot. An order of another operator cannot be filled from these leaves.
List<BookEntry> restingEntries(
  List<Map<String, dynamic>> offers, {
  required String pay,
  required String receive,
  required String? operator,
}) {
  final out = <BookEntry>[];
  if (operator == null) return out;
  for (final o in offers) {
    if (o['_verified'] == false) continue;
    final t = o['resting_leaf'] ?? o['restingLeaf'];
    if (t is! Map) continue;
    if ('${t['operator_key'] ?? t['operatorKey'] ?? ''}'.toLowerCase() != operator.toLowerCase()) continue;
    if ('${t['asset_a'] ?? t['assetA']}' != receive || '${t['asset_b'] ?? t['assetB']}' != pay) continue;
    final id = '${t['order_id'] ?? t['orderId'] ?? ''}'.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) continue;
    final n = _big(t['rate_num'] ?? t['rateNum']), dd = _big(t['rate_den'] ?? t['rateDen']), lot = _big(t['min_lot'] ?? t['minLot']);
    final st = o['_status'];
    final live = st is Map && st['active_amount'] != null ? _big(st['active_amount']) : _big(t['value']);
    if (n <= BigInt.zero || dd <= BigInt.zero || live <= BigInt.zero) continue;
    out.add(
      BookEntry(
        source: 'leaf-resting',
        id: id,
        rateNum: n,
        rateDen: dd,
        maxReceive: live,
        minReceive: lot > BigInt.zero ? lot : BigInt.one,
        lot: lot,
        raw: o,
      ),
    );
  }
  return out;
}

/// What an entry gives for `pay` atoms at its price before fees, within its lot rules.
({BigInt receive, BigInt pay})? sizeEntry(BookEntry e, BigInt pay) {
  if (pay <= BigInt.zero) return null;
  var r = (pay * e.rateDen) ~/ e.rateNum;
  if (r > e.maxReceive) r = e.maxReceive;
  if (e.lot > BigInt.zero && r < e.maxReceive && e.maxReceive - r < e.lot) r = e.maxReceive - e.lot;
  if (r < e.minReceive || r <= BigInt.zero) return null;
  return (receive: r, pay: _ceilDiv(r * e.rateNum, e.rateDen));
}

/// The most received, then the fewest parties, then the lower id.
Candidate? chooseCandidate(List<Candidate> cands) {
  final list = cands.where((c) => c.receive > BigInt.zero).toList();
  list.sort((a, b) {
    final d = b.receive.compareTo(a.receive);
    if (d != 0) return d;
    final p = (kSourceParties[a.source] ?? 9) - (kSourceParties[b.source] ?? 9);
    if (p != 0) return p;
    return a.id.compareTo(b.id);
  });
  return list.isEmpty ? null : list.first;
}

List<String> admittedSources(Map? pairs, String? genesis, String pay, String receive) {
  final chain = ((pairs ?? const {})['chains'] as Map?)?[genesis];
  if (chain is! Map) return const [];
  for (final p in (chain['pairs'] as List?) ?? const []) {
    if (p is Map && p['pay'] == pay && p['receive'] == receive) return [for (final s in (p['sources'] as List?) ?? const []) '$s'];
  }
  return const [];
}

List<String> admittedReceives(Map? pairs, String? genesis, String pay) {
  final chain = ((pairs ?? const {})['chains'] as Map?)?[genesis];
  if (chain is! Map) return const [];
  return {
    for (final p in (chain['pairs'] as List?) ?? const [])
      if (p is Map && p['pay'] == pay && ((p['sources'] as List?) ?? const []).isNotEmpty) '${p['receive']}',
  }.toList();
}

class Candidate {
  Candidate({
    required this.source,
    required this.id,
    required this.entry,
    required this.receive,
    required this.give,
    required this.fees,
    this.quote,
    this.offer,
    this.terms,
    this.settle,
    this.btc,
  });
  final String source, id;
  final BookEntry entry;
  final BigInt receive, give;
  final List<Map<String, dynamic>> fees;
  final Map<String, dynamic>? quote, offer, terms, settle;

  /// A BTC trade's terms (source 'btc-gateway').
  final BtcTerms? btc;
}

class Ticket {
  Ticket({
    required this.payAsset,
    required this.receiveAsset,
    required this.amountIn,
    required this.amountOut,
    required this.fees,
    required this.source,
    this.upTo,
  });
  final String payAsset, receiveAsset, source;
  final BigInt amountIn, amountOut;
  final List<Map<String, dynamic>> fees;
  final BigInt? upTo;
  Map<String, dynamic> toJson() => {
    'payAsset': payAsset,
    'receiveAsset': receiveAsset,
    'amountIn': '$amountIn',
    'amountOut': '$amountOut',
    'fees': fees.map((f) => {'asset': f['asset'], 'atoms': '${f['atoms']}'}).toList(),
    'source': source,
    if (upTo != null) 'upTo': '$upTo',
  };
  static Ticket fromJson(Map j) => Ticket(
    payAsset: '${j['payAsset']}',
    receiveAsset: '${j['receiveAsset']}',
    amountIn: _big(j['amountIn']),
    amountOut: _big(j['amountOut']),
    fees: [for (final f in (j['fees'] as List?) ?? const []) Map<String, dynamic>.from(f as Map)],
    source: '${j['source']}',
    upTo: j['upTo'] == null ? null : _big(j['upTo']),
  );
}

class QuoteResult {
  QuoteResult.ok(this.ticket, this.choice) : why = null;
  QuoteResult.no(this.why) : ticket = null, choice = null;
  final Ticket? ticket;
  final Candidate? choice;
  final String? why; // not-listed | not-offered | no-funds | too-small
  bool get ok => ticket != null;
}

class LapsedError implements Exception {
  @override
  String toString() => 'the price is no longer held';
}

/// What the engine needs from the app.
class UserTradeDeps {
  UserTradeDeps({
    required this.run,
    required this.fetchJson,
    required this.makers,
    required this.relayBook,
    required this.admitted,
    required this.read,
    required this.write,
    this.relayFills,
    this.btc,
    this.btcRail,
    this.btcOf,
    int Function()? now,
    void Function(String)? log,
    Future<void> Function(int ms)? sleep,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       log = log ?? ((_) {}),
       sleep = sleep ?? ((ms) => Future.delayed(Duration(milliseconds: ms)));
  final Future<dynamic> Function(String command, Map<String, dynamic> args) run;
  final Future<Map<String, dynamic>> Function(String url, {Map<String, dynamic>? post}) fetchJson;
  final List<String> Function() makers;
  final Future<List<Map<String, dynamic>>> Function(String pay, String receive) relayBook;

  /// The relay's fill records of the pair: a fill of an order resting in the tree is Settled once
  /// its record (keyed by the operator's transfer id) is final.
  final Future<List<Map<String, dynamic>>> Function(String pay, String receive)? relayFills;
  final Future<({Map? pairs, String? genesis})> Function() admitted;

  /// The wallet's Bitcoin Lightning, read at each use (null, or answering null: then nothing is
  /// traded for or with BTC).
  final BtcLightning? Function()? btc;

  /// The rail [btc] answers for now (`ark` or `lightning`), and the wallet's Bitcoin Lightning on
  /// a named rail: a BTC trade is finished on the rail it was priced on. Both null: one rail.
  final String? Function()? btcRail;
  final BtcLightning? Function(String rail)? btcOf;
  final Future<String?> Function() read;
  final Future<void> Function(String value) write;
  final int Function() now;
  final void Function(String) log;
  final Future<void> Function(int ms) sleep;
}

class UserTradeEngine {
  UserTradeEngine(this.d) {
    _btcT = BtcTrades(
      run: _run,
      btc: () => d.btc?.call(),
      fetchJson: d.fetchJson,
      put: _put,
      log: d.log,
      now: d.now,
      settleStep: _settleStep,
      maxFeePpm: kMaxFeePpm,
      firmMarginMs: kFirmMarginMs,
      railNow: d.btcRail,
      railOf: d.btcOf,
    );
  }
  final UserTradeDeps d;
  late final BtcTrades _btcT;
  BtcLightning? get _btc => d.btc?.call();

  Future<dynamic> _run(String cmd, [Map<String, dynamic> args = const {}]) async {
    for (var i = 0; ; i++) {
      final t0 = d.now();
      try {
        final v = await d.run(cmd, args);
        if (d.now() - t0 > 2000) d.log('[user trade] $cmd took ${d.now() - t0} ms');
        return v;
      } catch (e) {
        if (i < 8 && '$e'.contains('Scan already in progress')) {
          await d.sleep(500 + 500 * i);
          continue;
        }
        rethrow;
      }
    }
  }

  Future<List<Map<String, dynamic>>> records() async {
    try {
      final s = await d.read();
      if (s == null) return [];
      return [for (final r in jsonDecode(s) as List) Map<String, dynamic>.from(r as Map)];
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>> _put(Map<String, dynamic> rec) async {
    final l = await records();
    final i = l.indexWhere((r) => r['id'] == rec['id']);
    if (i >= 0) {
      l[i] = rec;
    } else {
      l.add(rec);
    }
    await d.write(jsonEncode(l));
    return rec;
  }

  Future<Map<String, BigInt>> spendable() async {
    List coins;
    try {
      coins = (await _run('coins')) as List? ?? const [];
    } catch (e) {
      d.log('[user trade] no leaves: $e');
      return {};
    }
    Map? plans;
    try {
      plans = (await _run('plans')) as Map?;
    } catch (_) {}
    return spendableFrom(coins, plans);
  }

  Future<List<BookEntry>> _entries(String pay, String receive, List<String> sources) async {
    final out = <BookEntry>[];
    // A maker quotes in-tree swaps, and, with a Bitcoin Lightning node, BTC in one hash-lock.
    if (sources.contains('leaf-maker') || (sources.contains('btc-gateway') && _btc != null)) {
      for (final m in d.makers()) {
        try {
          final q = await d.fetchJson('$m/v1/quotes');
          out.addAll(makerEntries(m, (q['quotes'] as List?) ?? const [], pay: pay, receive: receive).where((e) => sources.contains(e.source)));
        } catch (e) {
          d.log('[user trade] maker $m did not answer: $e');
        }
      }
    }
    if (sources.contains('covenant-round') || sources.contains('leaf-resting')) {
      try {
        final book = await d.relayBook(pay, receive);
        if (sources.contains('covenant-round')) out.addAll(covenantRoundEntries(book, pay: pay, receive: receive));
        if (sources.contains('leaf-resting')) {
          String? operator;
          try {
            operator = '${((await _run('info')) as Map)['operator']}';
          } catch (_) {}
          out.addAll(restingEntries(book, pay: pay, receive: receive, operator: operator));
        }
      } catch (e) {
        d.log('[user trade] the book did not answer: $e');
      }
    }
    return out;
  }

  void release(String? maker, String? swap) {
    if (maker == null || swap == null) return;
    d.fetchJson('$maker/v1/release', post: {'swap': swap}).catchError((_) => <String, dynamic>{});
  }

  /// A firm offer let go of before the maker is asked again for a smaller one: the maker holds
  /// its coins for an offer until it is released, and refuses a second offer they would have paid.
  Future<void> _releaseNow(String? maker, String? swap) async {
    if (maker == null || swap == null) return;
    try {
      await d.fetchJson('$maker/v1/release', post: {'swap': swap});
    } catch (_) {}
  }

  /// Firm terms of a fill of an order resting in the tree, from the library's quote: what leaves the
  /// wallet is the coins it gives less the change; the coins the fill brings are settled in the
  /// next round at the fee a coin of their expiry pays.
  Future<Candidate?> _firmResting(BookEntry e, String pay, String receive, BigInt limit, BigInt first) async {
    var r = first;
    for (var i = 0; i < 4; i++) {
      Map q;
      try {
        q = (await _run('order_fill_resting_quote', {'order': e.id, 'amount': '$r'})) as Map;
      } catch (err) {
        // A fill spends only the wallet's coins no older than the order's: when those hold less
        // than the fill takes, the library says how much they hold, and the fill is sized to it.
        final m = RegExp(r'the outputs take (\d+) of asset \S+, more than the (\d+) the inputs hold').firstMatch('$err');
        if (m != null && BigInt.parse(m.group(1)!) > BigInt.zero) {
          final r2 = (r * BigInt.parse(m.group(2)!)) ~/ BigInt.parse(m.group(1)!) - BigInt.one;
          final s2 = r2 > BigInt.zero ? sizeEntry(e, (r2 * e.rateNum) ~/ e.rateDen) : null;
          if (s2 != null && s2.receive < r) {
            r = s2.receive;
            continue;
          }
        }
        d.log('[user trade] order_fill_resting_quote: $err');
        return null;
      }
      final gets = q['gets'] as Map?, fee = q['fee'] as Map?;
      if (gets == null || gets['asset'] != receive || _big(gets['amount']) != r || fee == null || fee['asset'] != pay) return null;
      final gives = [for (final g in (q['gives'] as List?) ?? const []) '$g'];
      final given = [
        for (final c in ((await _run('coins')) as List? ?? const []))
          if (gives.contains('${(c as Map)['leaf_id']}')) c,
      ];
      if (given.length != gives.length) return null;
      final spends = given.fold<BigInt>(BigInt.zero, (n, c) => n + _big(c['value'])) - _big(q['change']);
      var expiry = (q['served'] as Map?)?['expiry'] is num ? ((q['served'] as Map)['expiry'] as num).toInt() : 1 << 62;
      for (final c in given) {
        final x = c['expiry'];
        if (x is num && x > 0 && x.toInt() < expiry) expiry = x.toInt();
      }
      Map s;
      Map? sc;
      try {
        s = (await _run('settle_quote', {'asset': receive, 'value': '$r', 'expiry': expiry})) as Map;
        if (_big(q['change']) > BigInt.zero) {
          sc = (await _run('settle_quote', {'asset': pay, 'value': '${q['change']}', 'expiry': expiry})) as Map;
        }
      } catch (err) {
        d.log('[user trade] settle_quote: $err');
        return null;
      }
      final total = spends + (sc != null ? _big(sc['fee']) : BigInt.zero);
      if (total <= limit) {
        return Candidate(
          source: e.source,
          id: e.id,
          entry: e,
          receive: _big(s['after']),
          give: total,
          quote: Map<String, dynamic>.from(q),
          settle: {'received': s, 'change': ?sc},
          fees: [
            {'asset': pay, 'atoms': spends - _big(q['paid']) + (sc != null ? _big(sc['fee']) : BigInt.zero)},
            {'asset': receive, 'atoms': _big(s['fee'])},
          ],
        );
      }
      final s2 = sizeEntry(e, (r * e.rateNum) ~/ e.rateDen - (total - limit) - BigInt.one);
      if (s2 == null || s2.receive >= r) return null;
      r = s2.receive;
    }
    return null;
  }

  Future<Candidate?> _firm(BookEntry e, String pay, String receive, BigInt amount, BigInt have) async {
    final size = sizeEntry(e, amount < have ? amount : have);
    if (size == null) return null;
    final limit = amount < have ? amount : have;
    if (e.source == 'covenant-round') {
      var r = size.receive;
      for (var i = 0; i < 4; i++) {
        Map q;
        try {
          q = (await _run('take_quote', {'order': e.raw['_relayJson'] ?? e.raw, 'amount': '$r', 'max_fee_ppm': kMaxFeePpm})) as Map;
        } catch (err) {
          d.log('[user trade] take_quote: $err');
          return null;
        }
        var gives = _big(q['spends'] ?? q['gives']);
        // A payment to itself leaves change resting on a reassignment: it is settled in the next
        // round as part of the trade, and that fee is on the ticket too.
        Map? sc;
        final first = q['pays_itself'] as Map?;
        final ch = _big(first?['change']);
        if (ch > BigInt.zero) {
          try {
            sc = (await _run('settle_quote', {'asset': pay, 'value': '$ch', 'expiry': first!['expiry']})) as Map;
          } catch (err) {
            d.log('[user trade] settle_quote: $err');
            return null;
          }
          gives += _big(sc['fee']);
        }
        if (gives <= limit) {
          return Candidate(
            source: e.source,
            id: e.id,
            entry: e,
            receive: _big(q['filled']),
            give: gives,
            fees: [
              {
                'asset': pay,
                'atoms':
                    _big(q['fee']) + (_big(q['spends'] ?? q['gives']) - _big(q['gives'])) + (sc != null ? _big(sc['fee']) : BigInt.zero),
              },
            ],
            quote: Map<String, dynamic>.from(q),
            settle: sc != null ? {'change': sc} : null,
          );
        }
        final s2 = sizeEntry(e, (r * e.rateNum) ~/ e.rateDen - (gives - limit) - BigInt.one);
        if (s2 == null || s2.receive >= r) return null;
        r = s2.receive;
      }
      return null;
    }
    if (e.source == 'leaf-resting') return _firmResting(e, pay, receive, limit, size.receive);
    if (e.source == 'btc-gateway') {
      final t = await _btcT.firm(
        maker: e.maker,
        rateNum: e.rateNum,
        rateDen: e.rateDen,
        minReceive: e.minReceive,
        payAsset: pay,
        receiveAsset: receive,
        pay: amount,
        have: have,
        first: size.receive,
      );
      if (t == null) return null;
      return Candidate(source: e.source, id: e.id, entry: e, receive: t.receive, give: t.give, fees: t.fees, offer: t.offer, btc: t);
    }
    if (e.source == 'leaf-maker') {
      var give = size.receive;
      for (var i = 0; i < 4; i++) {
        Map<String, dynamic> o;
        try {
          o = await d.fetchJson('${e.maker}/v1/firm', post: {'give_asset': receive, 'want_asset': pay, 'give': '$give'});
        } catch (err) {
          d.log('[user trade] maker firm: $err');
          return null;
        }
        Map t;
        try {
          t = (await _run('swap_read', {'offer': o['offer']})) as Map;
        } catch (err) {
          d.log('[user trade] swap_read: $err');
          release(e.maker, '${o['swap']}');
          return null;
        }
        if ((t['gets'] as Map)['asset'] != receive || (t['gives'] as Map)['asset'] != pay || _big((t['gets'] as Map)['value']) != give) {
          release(e.maker, '${o['swap']}');
          return null;
        }
        final spend = _big((t['gives'] as Map)['value']) + _big((t['pays'] as Map)['margins']);
        if (spend > limit) {
          await _releaseNow(e.maker, '${o['swap']}');
          give = give - _ceilDiv((spend - limit) * e.rateDen, e.rateNum) - BigInt.one;
          if (give < e.minReceive) return null;
          continue;
        }
        final change = _big((t['change'] as Map?)?['value']);
        final expiry = (t['dates'] as Map?)?['expiry'];
        Map s;
        Map? sc;
        try {
          s = (await _run('settle_quote', {'asset': receive, 'value': '$give', 'expiry': expiry})) as Map;
          if (change > BigInt.zero) sc = (await _run('settle_quote', {'asset': pay, 'value': '$change', 'expiry': expiry})) as Map;
        } catch (err) {
          d.log('[user trade] settle_quote: $err');
          release(e.maker, '${o['swap']}');
          return null;
        }
        final total = spend + (sc != null ? _big(sc['fee']) : BigInt.zero);
        if (total > limit) {
          await _releaseNow(e.maker, '${o['swap']}');
          give = give - _ceilDiv((total - limit) * e.rateDen, e.rateNum) - BigInt.one;
          if (give < e.minReceive) return null;
          continue;
        }
        return Candidate(
          source: e.source,
          id: e.id,
          entry: e,
          receive: _big(s['after']),
          give: total,
          offer: o,
          terms: Map<String, dynamic>.from(t),
          settle: {'received': s, 'change': sc},
          fees: [
            {'asset': pay, 'atoms': _big((t['pays'] as Map)['margins'])},
            {'asset': receive, 'atoms': _big(s['fee'])},
            if (sc != null) {'asset': pay, 'atoms': _big(sc['fee'])},
          ],
        );
      }
      return null;
    }
    return null;
  }

  Future<QuoteResult> quote({required String pay, required String receive, required BigInt amount}) async {
    if (amount <= BigInt.zero) return QuoteResult.no('too-small');
    final ad = await d.admitted();
    final sources = admittedSources(ad.pairs, ad.genesis, pay, receive);
    if (sources.isEmpty) return QuoteResult.no('not-listed');
    // BTC is paid over the wallet's Bitcoin Lightning, never from a leaf.
    BigInt have;
    if (pay == kUserBtc) {
      final b = _btc;
      try {
        have = b == null ? BigInt.zero : await b.balance();
      } catch (_) {
        have = BigInt.zero;
      }
    } else {
      have = (await spendable())[pay] ?? BigInt.zero;
    }
    if (have <= BigInt.zero) return QuoteResult.no('no-funds');
    final es = await _entries(pay, receive, sources);
    final limit = amount < have ? amount : have;
    final ind = [
      for (final e in es)
        if (sizeEntry(e, limit) != null) (e: e, r: sizeEntry(e, limit)!.receive),
    ]..sort((a, b) => b.r.compareTo(a.r));
    // A maker quoting several levels of one pair is asked once, at the level that gives the most
    // for this size: each firm offer holds its coins.
    final seen = <String>{};
    ind.removeWhere((x) => x.e.maker != null && !seen.add('${x.e.maker}|${x.e.source}'));
    // Firm terms of the best three that give them: an entry that cannot be firmed (a resting order
    // the wallet's coins are too old for, a maker that ran short) makes way for the next.
    final cands = <Candidate>[];
    var tried = 0;
    for (final x in ind) {
      if (cands.length >= 3 || tried >= 8) break;
      tried++;
      final c = await _firm(x.e, pay, receive, amount, have);
      if (c != null) cands.add(c);
    }
    final best = chooseCandidate(cands);
    for (final c in cands) {
      if (c == best) continue;
      if (c.btc != null) {
        _btcT.drop(c.entry.maker, c.btc!);
      } else if (c.offer != null) {
        release(c.entry.maker, '${c.offer!['swap']}');
      }
    }
    if (best == null) return QuoteResult.no(es.isEmpty ? 'not-offered' : 'too-small');
    return QuoteResult.ok(
      Ticket(
        payAsset: pay,
        receiveAsset: receive,
        amountIn: best.give,
        amountOut: best.receive,
        fees: best.fees,
        source: best.source,
        upTo: have < amount && best.give <= have ? have : null,
      ),
      best,
    );
  }

  Future<Map<String, dynamic>> confirm(Candidate c, Ticket t) async {
    final id = '${d.now()}-${d.now().hashCode.toRadixString(16)}${(await records()).length}';
    final rec = await _put({'id': id, 'at': d.now(), 'source': c.source, 'state': 'confirming', 'ticket': t.toJson()});
    try {
      if (c.source == 'covenant-round') {
        rec['order'] = c.entry.id;
        rec['orderJson'] = c.entry.raw['_relayJson'] ?? c.entry.raw;
        rec['beforeParts'] = [for (final p in ((await _run('participations')) as List? ?? const [])) '${(p as Map)['participation']}'];
        // What a payment to itself costs is spent even when the take is voided later (its margins
        // come back at that coin's next refresh): a return then says so.
        rec['selfPayCost'] = '${_big(c.quote!['spends'] ?? c.quote!['gives']) - _big(c.quote!['gives'])}';
        final sc = c.settle?['change'] as Map?;
        rec['settleTargets'] = [
          if (sc != null) {'asset': sc['asset'], 'value': sc['value'], 'fee': sc['fee']},
        ];
        rec['before'] = [for (final x in ((await _run('coins')) as List? ?? const [])) '${(x as Map)['leaf_id']}'];
        await _put(rec);
        final r =
            (await _run('take', {'order': rec['orderJson'], 'amount': c.quote!['filled'], 'max_fee_ppm': kMaxFeePpm, 'shown': c.quote}))
                as Map;
        rec['take'] = r['take'];
        rec['state'] = 'sent';
        rec['sentAt'] = d.now();
        return _put(rec);
      }
      if (c.source == 'leaf-maker') {
        final exp = int.tryParse('${c.offer!['expires_at'] ?? ''}');
        if (exp != null && exp * 1000 - d.now() < kFirmMarginMs) {
          rec['state'] = 'failed';
          rec['error'] = 'the firm offer lapsed before it was confirmed';
          await _put(rec);
          release(c.entry.maker, '${c.offer!['swap']}');
          throw LapsedError();
        }
        rec['maker'] = c.entry.maker;
        rec['swap'] = c.offer!['swap'];
        rec['give'] = (c.terms!['gets'] as Map)['value'];
        rec['receiveAsset'] = (c.terms!['gets'] as Map)['asset'];
        final rcv = c.settle!['received'] as Map, chg = c.settle!['change'] as Map?;
        rec['settleTargets'] = [
          {'asset': rcv['asset'], 'value': rcv['value'], 'fee': rcv['fee']},
          if (chg != null) {'asset': chg['asset'], 'value': chg['value'], 'fee': chg['fee']},
        ];
        rec['before'] = [for (final x in ((await _run('coins')) as List? ?? const [])) '${(x as Map)['leaf_id']}'];
        await _put(rec);
        final a = (await _run('swap_accept', {'offer': c.offer!['offer'], 'shown': c.terms})) as Map;
        rec['accept'] = a['accept'];
        rec['state'] = 'sent';
        rec['sentAt'] = d.now();
        await _put(rec);
        try {
          await d.fetchJson('${rec['maker']}/v1/accept', post: {'swap': rec['swap'], 'accept': rec['accept']});
        } catch (e) {
          d.log('[user trade] the maker did not take the acceptance yet: $e');
        }
        return _put(rec);
      }
      if (c.source == 'leaf-resting') {
        final q = c.quote!;
        rec['order'] = c.entry.id;
        rec['receiveAsset'] = (q['gets'] as Map)['asset'];
        final rcv = c.settle!['received'] as Map, chg = c.settle!['change'] as Map?;
        rec['settleTargets'] = [
          {'asset': rcv['asset'], 'value': rcv['value'], 'fee': rcv['fee']},
          if (chg != null) {'asset': chg['asset'], 'value': chg['value'], 'fee': chg['fee']},
        ];
        rec['before'] = [for (final x in ((await _run('coins')) as List? ?? const [])) '${(x as Map)['leaf_id']}'];
        await _put(rec);
        final args = {'order': rec['order'], 'amount': q['filled']};
        Map r;
        try {
          r = (await _run('order_fill_resting', {...args, 'shown': q})) as Map;
        } catch (e) {
          if (!'$e'.contains('order_moved')) rethrow;
          // Another taker filled first and the order rests at a new coin: filled there only for
          // the same amount at the same price and no higher fee, as shown.
          final again = (await _run('order_fill_resting_quote', args)) as Map;
          final af = again['fee'] as Map?, qf = q['fee'] as Map;
          final same =
              again['filled'] == q['filled'] &&
              again['paid'] == q['paid'] &&
              af != null &&
              af['asset'] == qf['asset'] &&
              _big(af['amount']) <= _big(qf['amount']) &&
              _big(again['change']) == _big(q['change']);
          if (!same) throw LapsedError();
          rec['movedFrom'] = q['coin'];
          r = (await _run('order_fill_resting', {...args, 'shown': again})) as Map;
        }
        rec['transfer'] = (r['answer'] as Map?)?['transfer_id'];
        rec['state'] = 'sent';
        rec['sentAt'] = d.now();
        return _put(rec);
      }
      if (c.source == 'btc-gateway') return await _btcT.confirm(c.entry.maker!, c.btc!, rec);
      throw StateError('no such source');
    } catch (e) {
      if (e is BtcLapsed) throw LapsedError();
      // A BTC trade's step that did not answer may still have been made (the library completes it
      // at its next sync): it is looked for, and called failed only if it never shows.
      if (rec['state'] == 'confirming' && c.source == 'btc-gateway' && e is! BtcLapsed && !RegExp(r'^(Exception: )?refused\b', caseSensitive: false).hasMatch('$e')) {
        rec['uncertain'] = true;
        rec['uncertainAt'] = d.now();
        rec['error'] = '$e';
        d.log('[user trade] the step did not answer; the trade is followed: $e');
        return _put(rec);
      }
      if (rec['state'] == 'confirming') {
        rec['state'] = 'failed';
        rec['error'] = '$e';
        await _put(rec);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _participation(String pid) async {
    for (final p in ((await _run('participations')) as List? ?? const [])) {
      if (p is Map && p['participation'] == pid) return Map<String, dynamic>.from(p);
    }
    return null;
  }

  bool _releasedLive(Map? p) =>
      p != null && p['state'] == 'released' && ((p['new_leaves'] as List?) ?? const []).every((n) => (n as Map)['state'] == 'live');

  Future<Map<String, dynamic>> advance(Map<String, dynamic> rec) async {
    if (['settled', 'returned', 'failed'].contains(rec['state'])) return rec;
    if (rec['state'] == 'confirming' && rec['source'] == 'btc-gateway') {
      if (rec['hash'] == null) {
        rec['state'] = 'failed';
        rec['error'] = 'not made';
        return _put(rec);
      }
      await _btcT.found(rec);
      if (rec['state'] != 'sent' && rec['state'] != 'waiting') return rec;
    }
    if (rec['source'] == 'btc-gateway') return _btcT.advance(rec);
    if (rec['state'] == 'confirming') {
      if (rec['source'] == 'leaf-maker' && rec['swap'] != null) {
        final s = ((await _run('swaps')) as List? ?? const []).cast<Map>().where((x) => x['swap'] == rec['swap']).toList();
        if (s.isNotEmpty && s.first['role'] == 'taker') {
          rec['state'] = 'sent';
          rec['sentAt'] = d.now();
        } else {
          rec['state'] = 'failed';
          rec['error'] = 'not accepted';
        }
      } else if (rec['source'] == 'leaf-resting') {
        // A fill the app closed on is sent again by the library's next sync; the coin it brings is
        // then the wallet's.
        try {
          await _run('sync');
        } catch (_) {}
        final before = ((rec['before'] as List?) ?? const []).map((e) => '$e').toSet();
        final got = ((await _run('coins')) as List? ?? const []).cast<Map>().any(
          (c) => !before.contains('${c['leaf_id']}') && c['asset'] == rec['receiveAsset'] && c['state'] == 'live',
        );
        if (got) {
          rec['state'] = 'sent';
          rec['sentAt'] = d.now();
        } else {
          rec['state'] = 'failed';
          rec['error'] = 'not filled';
        }
      } else if (rec['source'] == 'covenant-round') {
        final known = {
          ...((rec['beforeParts'] as List?) ?? const []).map((e) => '$e'),
          for (final r in await records())
            if (r['take'] != null) '${r['take']}',
        };
        final recv = (rec['ticket'] as Map)['receiveAsset'];
        Map? found;
        for (final p in ((await _run('participations')) as List? ?? const [])) {
          if (p is Map &&
              !known.contains('${p['participation']}') &&
              ((p['new_leaves'] as List?) ?? const []).any((n) => (n as Map)['asset'] == recv)) {
            found = p;
          }
        }
        if (found != null) {
          rec['take'] = found['participation'];
          rec['state'] = 'sent';
          rec['sentAt'] = d.now();
        } else {
          rec['state'] = 'failed';
          rec['error'] = 'not taken';
        }
      }
      await _put(rec);
      if (rec['state'] != 'sent') return rec;
    }
    try {
      await _run('sync');
    } catch (e) {
      d.log('[user trade] sync: $e');
    }
    if (rec['source'] == 'leaf-resting') {
      // Settled once the relay records the fill final and the coins it brought are settled in a
      // round that is final.
      if (d.relayFills != null && rec['transfer'] != null && rec['fillFinal'] != true) {
        try {
          final t = rec['ticket'] as Map;
          for (final f in await d.relayFills!('${t['payAsset']}', '${t['receiveAsset']}')) {
            if (f['txid'] == rec['transfer']) {
              rec['fillState'] = f['state'];
              if (f['state'] == 'final') rec['fillFinal'] = true;
            }
          }
        } catch (_) {}
      }
      if (await _settleStep(rec) && (rec['fillFinal'] == true || d.relayFills == null)) {
        rec['state'] = 'settled';
        rec['settledAt'] = d.now();
      }
      return _put(rec);
    }
    if (rec['source'] == 'covenant-round') {
      final p = await _participation('${rec['take']}');
      if (p == null) return rec;
      rec['takeState'] = p['state'];
      if (_releasedLive(p)) {
        if (await _settleStep(rec)) {
          rec['state'] = 'settled';
          rec['settledAt'] = d.now();
        }
      } else if (['void', 'expired', 'refused', 'lost'].contains(p['state'])) {
        if (((p['gives'] as List?) ?? const []).every((g) => (g as Map)['state'] == 'live')) {
          rec['state'] = 'returned';
          rec['returnedAt'] = d.now();
          if (_big(rec['selfPayCost']) > BigInt.zero) {
            rec['feesPaid'] = [
              {'asset': (rec['ticket'] as Map)['payAsset'], 'atoms': rec['selfPayCost']},
            ];
          }
        }
      }
      return _put(rec);
    }
    // In-tree swap.
    final swaps = ((await _run('swaps')) as List? ?? const []).cast<Map>().where((x) => x['swap'] == rec['swap']).toList();
    final s = swaps.isEmpty ? null : swaps.first;
    rec['swapState'] = s?['state'];
    if (s?['state'] == 'cancelled') {
      rec['state'] = 'returned';
      rec['returnedAt'] = d.now();
      return _put(rec);
    }
    if (s?['state'] == 'accepted') {
      try {
        await d.fetchJson('${rec['maker']}/v1/accept', post: {'swap': rec['swap'], 'accept': rec['accept']});
      } catch (_) {}
      if (d.now() - ((rec['sentAt'] as num?)?.toInt() ?? 0) > kMakerCompleteMs) {
        try {
          final held = ((await _run('coins')) as List? ?? const []).cast<Map>().where((c) => c['state'] == 'offered').toList();
          final c = (await _run('swap_cancel', {'swap': rec['swap']})) as Map;
          if (c['cancelled'] == true) {
            rec['state'] = 'returned';
            rec['returnedAt'] = d.now();
            // A cancel moves the coins signed into the acceptance to a fresh coin of the wallet's own,
            // a transfer that leaves margins: the return names them.
            final respent = {...((c['respent'] as List?) ?? const []).map((e) => '$e')};
            if (respent.isNotEmpty) {
              final was = held.where((x) => respent.contains('${x['leaf_id']}')).fold<BigInt>(BigInt.zero, (n, x) => n + _big(x['value']));
              final before = {...((rec['before'] as List?) ?? const []).map((e) => '$e')};
              final pay = (rec['ticket'] as Map)['payAsset'];
              final got = ((await _run('coins')) as List? ?? const [])
                  .cast<Map>()
                  .where((x) => x['state'] == 'live' && !before.contains('${x['leaf_id']}') && x['asset'] == pay)
                  .fold<BigInt>(BigInt.zero, (n, x) => n + _big(x['value']));
              if (was > got) {
                rec['feesPaid'] = [
                  {'asset': pay, 'atoms': '${was - got}'},
                ];
              }
            }
          }
        } catch (e) {
          d.log('[user trade] swap_cancel: $e');
        }
      }
      return _put(rec);
    }
    if (s?['state'] != 'done') return _put(rec);
    if (await _settleStep(rec)) {
      rec['state'] = 'settled';
      rec['settledAt'] = d.now();
    }
    return _put(rec);
  }

  /// The coins a trade brings, or leaves as change on a reassignment, settled in the operator's
  /// next round at no more than the fees its ticket showed. True once every such round is final.
  Future<bool> _settleStep(Map<String, dynamic> rec) async {
    final targets = ((rec['settleTargets'] as List?) ?? const []).cast<Map>();
    if (targets.isEmpty) return true;
    if (rec['settle'] == null) {
      final before = {...((rec['before'] as List?) ?? const []).map((e) => '$e')};
      final fresh = ((await _run('coins')) as List? ?? const [])
          .cast<Map>()
          .where((c) => !before.contains('${c['leaf_id']}') && c['state'] == 'live')
          .toList();
      final coins = <Map>[];
      for (final t in targets) {
        final c = fresh.where((x) => !coins.contains(x) && x['asset'] == t['asset'] && '${x['value']}' == '${t['value']}').firstOrNull;
        if (c == null) return false;
        coins.add(c);
      }
      final ids = [for (final c in coins) c['leaf_id']];
      Map q;
      try {
        q = (await _run('quote', {'leaves': ids, 'max_fee_ppm': kMaxFeePpm})) as Map;
      } catch (e) {
        d.log('[user trade] settle quote: $e');
        return false;
      }
      for (final qc in ((q['coins'] as List?) ?? const []).cast<Map>()) {
        final i = ids.indexOf(qc['leaf_id']);
        if (i < 0 || _big(qc['fee']) > _big(targets[i]['fee'])) {
          d.log('[user trade] a settle fee rose above the ticket');
          return false;
        }
      }
      Map r;
      try {
        r = (await _run('participate', {'leaves': ids, 'max_fee_ppm': kMaxFeePpm, 'shown': q['coins']})) as Map;
      } catch (e) {
        d.log('[user trade] participate: $e');
        return false;
      }
      final parts = ((r['participations'] as List?) ?? const [])
          .cast<Map>()
          .where((p) => p['error'] == null && p['participation'] != null)
          .toList();
      if (parts.isEmpty) return false;
      rec['settle'] = {
        'coins': ids,
        'participations': [for (final p in parts) p['participation']],
      };
      await _put(rec);
      return false;
    }
    final ps = [for (final id in ((rec['settle'] as Map)['participations'] as List)) await _participation('$id')];
    rec['settleState'] = [for (final p in ps) p?['state']];
    if (ps.every(_releasedLive)) return true;
    if (ps.any((p) => p != null && ['void', 'expired', 'refused', 'lost'].contains(p['state']))) rec['settle'] = null;
    return false;
  }

  /// The assets the drill admitted against [pay] on this chain.
  Future<List<String>> admittedReceivesFor(String pay) async {
    final ad = await d.admitted();
    return admittedReceives(ad.pairs, ad.genesis, pay);
  }

  Future<List<Map<String, dynamic>>> resume() async {
    final out = <Map<String, dynamic>>[];
    for (final r in await records()) {
      if (['settled', 'returned', 'failed'].contains(r['state'])) continue;
      try {
        out.add(await advance(r));
      } catch (e) {
        d.log('[user trade] resume ${r['id']}: $e');
      }
    }
    return out;
  }
}
