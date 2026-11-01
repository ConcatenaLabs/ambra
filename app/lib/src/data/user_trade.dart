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

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'btc_lightning.dart';
import 'user_trade_btc.dart';

const String kUserBtc = 'BTC';

/// How long the wallet waits for a maker to complete a swap it accepted before it cancels it.
const int kMakerCompleteMs = 120000;

/// A maker's firm offer is accepted only while at least this long is left before it lapses.
const int kFirmMarginMs = 20000;

/// Minutes after which a received trade still settling is said to be slow.
const int kSlowSettleMin = 10;

/// How long a quote may take from Review: every source worth asking for firm terms is asked at
/// once, and one that has not answered by then is left out of the ticket (a late answer is let go
/// of). The firm terms always get at least [kQuoteFirmMinMs] of it. The web wallet's QUOTE_FIRM_MS.
const int kQuoteFirmMs = 8000;
const int kQuoteFirmMinMs = 3000;

/// How long a quote waits before it asks once more for firm terms that none gave.
const int kFirmRetryMs = 3000;

/// When the BTC desk is the only source a trade can take (buying or selling BTC), its firm terms (an
/// offer and a Bitcoin invoice) are waited for this long: there is no other answer to take instead.
const int kBtcOnlyFirmMs = 20000;

/// How long a refresh asked to get coins ready for a resting order is waited on before it is asked
/// again: its round, and the round's block being certified.
const int kReadyingMs = 10 * 60000;

/// The book's entries read while the amount was typed stand for the quote this long.
const int kEntriesFreshMs = 8000;

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
  static const get = 'You receive';
  static const amount = 'Amount';
  static const max = 'Max';
  static String balance(String x) => 'balance $x';
  // What the book can fill now, when less than asked: said beside the amounts as they are typed.
  static String bookUpTo(String x) => 'The book can fill up to $x now.';
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
  // Held, and shown in the balance, but not where a trade can pay it from yet (just arrived, or
  // still being moved in by the wallet): never "you have none".
  // [soon]: the operator calls a coin ready once its block is certified (anchor depth 0), so it is
  // ready in a minute or two.
  static String notReady(String pay, [bool soon = false]) => soon
      ? 'Your $pay is on its way: it is ready to trade in a minute or two. Nothing has moved.'
      : 'Your $pay is not ready to trade yet: it is once the next Bitcoin blocks settle it. Nothing has moved.';
  // A coin that was ready, taken back out of the chain with its Bitcoin block: still the wallet's,
  // and in its balance, while the network takes it in again.
  static String redoing(String pay) =>
      'Your $pay is being redone after a Bitcoin reorganisation: it is still yours, and ready to trade again once that settles. Nothing has moved.';
  // Kept by the wallet's plan to refresh it while the wallet is closed, which only a round can end:
  // the wallet gives it up in its next round for a coin it can trade.
  static String freeing(String pay, [bool soon = false]) => soon
      ? 'Your $pay is being made ready to trade: it is ready in a minute or two. Nothing has moved.'
      : 'Your $pay is being made ready to trade: it is ready once the next Bitcoin blocks settle it. Nothing has moved.';
  // The amount not typed, while it follows the book's price now: an estimate, said as one.
  static const about = 'about';
  // Review, while the sources are asked for terms they hold to: the shown amount is the estimate.
  static const pricing = 'Getting the exact price…';
  // The best offers are orders resting in the tree that only coins expiring later can fill: the
  // wallet refreshes its older coins in the next round, and prices the trade again once they are in.
  static String readying(String pay, [bool soon = false]) => soon
      ? 'Getting your $pay ready for this trade: it is ready in a minute or two. Nothing has moved.'
      : 'Getting your $pay ready for this trade: it is ready once the next Bitcoin blocks settle it. Nothing has moved.';
  static const opening = 'Your wallet is still opening: try again in a moment. Nothing has moved.';
  static const noFirmOffer = 'Nobody could confirm a price for this just now. Nothing has moved: try again in a moment.';
  // Held, and shown in the balance, but not where a trade pays from yet (just arrived, or still
  // being moved in by the wallet), while too little of it is ready for any offer.
  static String partReady(String ready, String pay, [bool soon = false]) => soon
      ? 'Only $ready of your $pay can be traded now, too little for any offer: the rest is on its way, ready in a minute or two. Nothing has moved.'
      : 'Only $ready of your $pay can be traded now, too little for any offer: the rest is ready once the next Bitcoin blocks settle it. Nothing has moved.';
  // BTC held at the wallet's address, which a trade cannot pay from until the wallet has moved it
  // where trades pay from: a move confirmed by [blocks] Bitcoin blocks (no time: Bitcoin's blocks
  // keep none).
  static String _blocks(int n) => n == 1 ? 'a Bitcoin block' : '$n Bitcoin blocks';
  static String btcMoving(int blocks) =>
      'Your BTC is being moved so it can be traded. It is ready after ${_blocks(blocks)}. Nothing has moved yet.';
  static String btcMore(int blocks) => 'More of your BTC is being moved so it can be traded, ready after ${_blocks(blocks)}.';
  static const priceMoved = 'The price moved. Here is the new one.';
  static const sent = 'Sent';
  static const settled = 'Settled';
  static const waitingOther = 'Waiting for the other side. Nothing has left your wallet yet.';
  // A sale for BTC whose asset is paid: the BTC comes once the other side pays it out.
  static const btcOnItsWay = 'Paid. Your BTC is on its way.';
  // What the trade brings is the wallet's; only its settling with the network is left. One word on
  // every surface, with no time: how long settling takes is the network's, not the trade's.
  static const received = 'Received, settling';
  static const receivedSlow = 'Received, and yours to use. Settling with the network is taking longer than usual.';
  static String minutes(String word, int n) => '$word ($n min)';
  static const returned = 'Returned: nothing traded.';
  static String returnedFees(String fees) => 'Returned: nothing traded. Fees of $fees were paid.';
  static const returnedLapsed = 'Returned: nothing traded. The other side\'s offer ran out while the trade waited.';
  // A trade confirmed and being sent: the screen is free at once, the trade goes on in Open.
  static const sending = 'Sending…';
  // ⇅ between the two sides: the sides change places, each amount with its asset.
  static const flip = 'Swap You pay and You receive';
  static const failed = 'This trade could not be made. Nothing moved.';
  static const recent = 'Your trades';
  static const openTrades = 'Open';
  static const pastTrades = 'Past';

  static List<String> all() => [
    title,
    pay,
    get,
    amount,
    max,
    balance('1 XT'),
    bookUpTo('1 XT'),
    openTrades,
    pastTrades,
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
    notReady('XT'),
    notReady('XT', true),
    redoing('XT'),
    freeing('XT'),
    freeing('XT', true),
    about,
    pricing,
    noFirmOffer,
    opening,
    readying('XT'),
    readying('XT', true),
    partReady('1 XT', 'XT'),
    partReady('1 XT', 'XT', true),
    btcMoving(2),
    btcMoving(1),
    btcMore(2),
    priceMoved,
    sent,
    settled,
    waitingOther,
    btcOnItsWay,
    received,
    receivedSlow,
    minutes(sent, 3),
    returned,
    returnedFees('1 XT'),
    returnedLapsed,
    sending,
    flip,
    failed,
    recent,
  ];
}

/// Whether what the trade buys is already the wallet's, only its settling left.
bool heldAlready(Map r) {
  if (r['source'] == 'btc-gateway') return r['dir'] == 'sell' ? r['btcPaid'] == true : (r['preimage'] != null && r['receiveState'] == 'received');
  if (r['source'] == 'leaf-maker') return r['swapState'] == 'done';
  if (r['source'] == 'covenant-round') return r['takeState'] == 'released';
  return false;
}

/// What the list of trades says of one: Sent, then Settled; a trade waiting on the other side or
/// on its settling says so, with the minutes it has waited once it has waited one. Null for a
/// trade returned with fees paid (the row names the fees). The web wallet's tradeStateWord().
/// The same words in the Swap tab's Open trades, in History and on every other surface: none of them
/// promises a time, the minutes waited being the only time shown.
String? tradeStateWord(Map r, int nowMs) {
  final st = r['state'];
  if (st == 'settled') return UserWords.settled;
  if (st == 'returned' && ((r['feesPaid'] as List?) ?? const []).isNotEmpty) return null;
  if (st == 'returned' && r['whyKind'] == 'lapsed') return UserWords.returnedLapsed;
  if (st == 'returned' || st == 'failed') return UserWords.returned;
  if (st == 'confirming') return UserWords.sending;
  int since(Object? t) => ((nowMs - ((t as num?)?.toInt() ?? (r['at'] as num?)?.toInt() ?? nowMs)) / 60000).floor();
  // Buying with BTC: nothing has left the wallet until its asset is held for it.
  if (st == 'waiting') {
    final m = since(r['waitingSince']);
    return m >= 1 ? UserWords.minutes(UserWords.waitingOther, m) : UserWords.waitingOther;
  }
  final m = since(r['sentAt']);
  // Received, its settling still waiting with the network after [kSlowSettleMin] minutes: said so,
  // the coins being the wallet's all along.
  final held = heldAlready(r);
  final slow = held && m >= kSlowSettleMin && ((r['settleState'] as List?) ?? const []).any((x) => x != null && x != 'released');
  final word = held
      ? (slow ? UserWords.receivedSlow : UserWords.received)
      : (r['source'] == 'btc-gateway' && r['dir'] == 'sell' ? UserWords.btcOnItsWay : UserWords.sent);
  return m >= 1 ? UserWords.minutes(word, m) : word;
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

/// The coins open offline-refresh plans keep: each plan's coin and the leaf its last step made.
Set<String> plannedLeaves(Map? plans) {
  final planned = <String>{};
  for (final p in ((plans ?? const {})['plans'] as List?) ?? const []) {
    if (p is! Map || RegExp(r'^(done|cancelled|stopped|finished)$').hasMatch('${p['state'] ?? ''}')) continue;
    planned.add('${p['coin']}');
    for (final st in (p['steps'] as List?) ?? const []) {
      if (st is Map && st['leaf_id'] != null) planned.add('${st['leaf_id']}');
    }
  }
  return planned;
}

/// What the library can pay now, per asset, out of round: its live coins, less those an open
/// offline-refresh plan keeps, and every coin given up in a refresh still waiting for a round
/// (`refresh_waiting`): the trade takes that refresh back first and pays with the coin, and its
/// quote prices it so.
Map<String, BigInt> spendableFrom(List coins, Map? plans) {
  final planned = plannedLeaves(plans);
  final out = <String, BigInt>{};
  for (final c in coins) {
    if (c is! Map || planned.contains('${c['leaf_id']}')) continue;
    if (c['state'] != 'live' && !(c['state'] == 'given' && c['refresh_waiting'] != null)) continue;
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

/// The library commands the engine runs to follow a trade, never to make one: reads and syncs.
const Set<String> kFollowCommands = {
  'sync', 'coins', 'plans', 'info', 'participations', 'swaps', 'lightning_payments', 'lightning_receives',
  'lightning_receive_ready',
};

/// The library's reads the engine runs in bursts, marked so each may answer from a look at the chain
/// another made a moment ago (the library looks afresh for anything that takes a coin or signs).
/// The web wallet's `SHARED_VIEW_READS`.
const Set<String> kSharedViewReads = {
  'info', 'coins', 'plans', 'participations', 'swaps', 'balance', 'swap_read', 'take_quote', 'settle_quote', 'quote',
  'order_fill_resting_quote', 'order_cancel_resting_quote',
};

/// How long the operator's `info` is read from the last reading.
const int kInfoMs = 5000;

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
  QuoteResult.ok(this.ticket, this.choice, {this.moving = false}) : why = null, soon = false, ready = null;
  QuoteResult.no(this.why, {this.soon = false, this.ready, this.moving = false}) : ticket = null, choice = null;
  final Ticket? ticket;
  final Candidate? choice;
  // not-listed | not-offered | no-funds | not-ready | redoing | freeing | readying | part-ready |
  // btc-moving | too-small | no-firm-offer
  final String? why;
  /// part-ready: what can be paid now.
  final BigInt? ready;
  /// BTC: more of what the wallet holds at its address is being moved where trades pay from.
  final bool moving;
  /// What is not ready yet is ready in a minute or two (the operator's anchor depth is 0).
  final bool soon;
  bool get ok => ticket != null;
}

/// The indicative amounts of [UserTradeEngine.estimate]: [pay] for [receive], and [short] when
/// the book fills less than was typed (the most one source fills now). Or [why] it has none:
/// not-listed | not-offered | too-small.
class Estimate {
  const Estimate({required BigInt this.pay, required BigInt this.receive, this.short}) : why = null;
  const Estimate.no(String this.why) : pay = null, receive = null, short = null;
  final BigInt? pay, receive;
  final ({BigInt receive, BigInt pay})? short;
  final String? why;
  bool get ok => why == null;
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
    this.held,
    this.prepare,
    this.leavesOpen,
    this.release,
    this.anchorDepth,
    this.btcAtAddress,
    this.btcMove,
    this.btcMoveBlocks,
    this.btcOnlyFirmMs,
    int? quoteFirmMs,
    int Function()? now,
    void Function(String)? log,
    Future<void> Function(int ms)? sleep,
  }) : quoteFirmMs = quoteFirmMs ?? kQuoteFirmMs,
       now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
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

  /// What the wallet shows it holds of an asset, wherever it is: with it, a pay asset held but not
  /// payable now is 'not-ready', never 'no-funds'. And a way to make such an asset ready (default
  /// mode boards on-chain coins). Both optional.
  final Future<BigInt> Function(String asset)? held;
  final void Function(String asset)? prepare;

  /// Whether the wallet's leaves are open and read (null: not said). While they are not, an asset
  /// the balance shows is never "none": the wallet is still opening.
  final bool Function()? leavesOpen;

  /// Asks the wallet to free [leaves], live coins of [asset] an open offline-refresh plan keeps, in
  /// its next round (`plan_release`), as a payment from them is. Optional: with it, a pay asset held
  /// only in such coins is 'freeing'.
  final void Function(String asset, List<String> leaves)? release;

  /// The Bitcoin blocks the operator waits for after a block is certified before a coin in it can
  /// be traded (the library's `info` `anchor_depth`), or null. Optional: at 0 a coin not ready yet
  /// is on its way, ready in a minute or two.
  final int? Function()? anchorDepth;

  /// BTC the wallet holds at its own address, confirmed, which a trade cannot pay from until the
  /// wallet moves it where trades pay its BTC from ([btc]); and a way to have at least `sats` of it
  /// moved there now (default mode: a board of the Bitcoin ark, at most what one board may carry),
  /// with the Bitcoin blocks such a move waits for. All optional: without them BTC at the address
  /// counts for nothing here.
  final Future<BigInt> Function()? btcAtAddress;
  final void Function(BigInt sats)? btcMove;
  final int Function()? btcMoveBlocks;

  /// How long a quote may take ([kQuoteFirmMs]), and, when the BTC desk is the only source the trade
  /// can take, how long it waits for its terms ([kBtcOnlyFirmMs]).
  final int quoteFirmMs;
  final int? btcOnlyFirmMs;
  final Future<String?> Function() read;
  final Future<void> Function(String value) write;
  final int Function() now;
  final void Function(String) log;
  final Future<void> Function(int ms) sleep;
}

class UserTradeEngine {
  /// Asks the wallet to free the live coins of [asset] an open offline-refresh plan keeps, in its
  /// next round ([UserTradeDeps.release]): the library pays such a coin out of round only once a
  /// round has freed it. Whether it asked.
  Future<bool> _freePlanned(String asset) async {
    if (d.release == null) return false;
    try {
      final coins = (await _run('coins')) as List? ?? const [];
      final planned = plannedLeaves((await _run('plans')) as Map?);
      final kept = [
        for (final c in coins)
          if (c is Map && c['asset'] == asset && c['state'] == 'live' && planned.contains('${c['leaf_id']}')) '${c['leaf_id']}',
      ];
      if (kept.isEmpty) return false;
      d.release!(asset, kept);
      return true;
    } catch (e) {
      d.log('[user trade] release: $e');
      return false;
    }
  }

  /// Whether the operator calls a coin ready once its block is certified (anchor depth 0).
  bool get soon {
    try {
      return d.anchorDepth?.call() == 0;
    } catch (_) {
      return false;
    }
  }

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

  /// Each asset's one figure as the balance shows it (on the chain, in the Ark, in a channel), set
  /// by the screen that shows it: an asset the person sees they hold is never "You have no …".
  BigInt Function(String asset)? figure;
  BtcLightning? get _btc => d.btc?.call();

  Future<dynamic> _run(String cmd, [Map<String, dynamic> args = const {}]) async {
    // The engine's reads come in bursts (a quote asks several candidates at once): each may answer
    // from the library's look at the chain a moment old, rather than every one looking again.
    final a = kSharedViewReads.contains(cmd) ? {...args, 'shared_view': true} : args;
    for (var i = 0; ; i++) {
      final t0 = d.now();
      try {
        final v = await d.run(cmd, a);
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
    _changes.add(null);
    return rec;
  }

  final _changes = StreamController<void>.broadcast(sync: false);

  /// Fires whenever a trade record is written: a trade a connected site made shows in the Swap
  /// tab's list at once.
  Stream<void> get changes => _changes.stream;

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
      // Every maker at once: one that does not answer costs its own wait, not the others'.
      final got = await Future.wait(d.makers().map((m) async {
        try {
          final q = await d.fetchJson('$m/v1/quotes');
          return makerEntries(m, (q['quotes'] as List?) ?? const [], pay: pay, receive: receive).where((e) => sources.contains(e.source)).toList();
        } catch (e) {
          d.log('[user trade] maker $m did not answer: $e');
          return <BookEntry>[];
        }
      }));
      for (final g in got) {
        out.addAll(g);
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

  Map? _info;
  int _infoAt = 0;

  /// What the operator's round can pay of `asset` now (its `info`'s `fundable`, read at most every
  /// [kInfoMs]), or null when the operator does not say.
  Future<BigInt?> operatorRoom(String asset) async {
    if (_info == null || d.now() - _infoAt > kInfoMs) {
      try {
        _info = (await _run('info')) as Map;
        _infoAt = d.now();
      } catch (e) {
        d.log('[user trade] info: $e');
        return null;
      }
    }
    final si = _info?['server_info'];
    final assets = si is Map ? si['assets'] : null;
    if (assets is! List) return null;
    for (final a in assets) {
      if (a is Map && a['asset'] == asset && a['fundable'] != null) return BigInt.tryParse('${a['fundable']}');
    }
    return null;
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
        // Only coins expiring no earlier than the order's coin fill it, and the wallet's that do hold
        // too little: noted, so a quote that finds no other offer gets those coins ready.
        final old = RegExp(r"that expire no earlier than the order's coin \(median time (\d+)\) keep (\d+) past their checkpoints").firstMatch('$err');
        if (old != null) {
          final t = int.parse(old.group(1)!);
          if (_tooOldFrom == null || t > _tooOldFrom!) _tooOldFrom = t;
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
      // The round pays the order's maker the asset paid out of the operator's own coins: a take
      // larger than the operator can fund now is made smaller, and one with no lot that fits is
      // not offered (it would wait in the round and come back).
      final room = await operatorRoom(pay);
      if (room != null && size.pay > room) {
        final s0 = sizeEntry(e, room);
        if (s0 == null) {
          d.log('[user trade] the operator can fund $room of the asset now: the order is passed over');
          return null;
        }
        r = s0.receive;
      }
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

  /// What can be received for [pay] in one step now: each admitted pair's asset that some source
  /// in the book offers, whatever the wallet holds. BTC counts only with the wallet's Bitcoin
  /// Lightning (the desk pays it there). The web wallet's `offered`.
  Future<List<String>> offered(String pay) async {
    final ad = await d.admitted();
    final chain = (ad.pairs?['chains'] as Map?)?[ad.genesis];
    final pairs = [
      for (final p in ((chain is Map ? chain['pairs'] : null) as List?) ?? const [])
        if (p is Map && p['pay'] == pay && p['receive'] != pay && ((p['sources'] as List?) ?? const []).isNotEmpty) p,
    ];
    final found = await Future.wait(pairs.map((p) async {
      try {
        final es = await _entries(pay, '${p['receive']}', [for (final s in p['sources'] as List) '$s']);
        return es.any((e) => e.source != 'btc-gateway' || _btc != null) ? '${p['receive']}' : null;
      } catch (_) {
        return null;
      }
    }));
    return {for (final f in found) ?f}.toList();
  }

  final _estimates = <String, ({int at, List<BookEntry> es})>{};

  /// Indicative terms in either direction, for the two amounts while a person types: the book's
  /// best single-step source for paying [payAtoms], or the least paid to receive [receiveAtoms].
  /// No maker is asked for firm terms (a firm offer holds the maker's coins); Review does that,
  /// fees and all. The book's entries are read at most every 8 seconds per pair. The web wallet's
  /// `estimate`.
  Future<Estimate> estimate({required String pay, required String receive, BigInt? payAtoms, BigInt? receiveAtoms}) async {
    final ad = await d.admitted();
    final sources = admittedSources(ad.pairs, ad.genesis, pay, receive);
    if (sources.isEmpty) return const Estimate.no('not-listed');
    final key = '$pay>$receive';
    var c = _estimates[key];
    if (c == null || d.now() - c.at > 8000) {
      List<BookEntry> es;
      try {
        es = await _entries(pay, receive, sources);
      } catch (_) {
        es = const [];
      }
      c = (at: d.now(), es: es);
      _estimates[key] = c;
    }
    final es = c.es.where((e) => (e.source != 'btc-gateway' || _btc != null) && e.maxReceive > BigInt.zero).toList();
    if (es.isEmpty) return const Estimate.no('not-offered');
    ({BigInt receive, BigInt pay})? most;
    for (final e in es) {
      if (most == null || e.maxReceive > most.receive) most = (receive: e.maxReceive, pay: _ceilDiv(e.maxReceive * e.rateNum, e.rateDen));
    }
    if (payAtoms != null) {
      if (payAtoms <= BigInt.zero) return const Estimate.no('too-small');
      ({BigInt receive, BigInt pay})? best;
      BookEntry? bestE;
      for (final e in es) {
        final s = sizeEntry(e, payAtoms);
        if (s != null && (best == null || s.receive > best.receive)) {
          best = s;
          bestE = e;
        }
      }
      if (best == null) return const Estimate.no('too-small');
      // Short only when the source cannot take the whole amount (its size or its lot rules): what the
      // price's rounding leaves of the amount, less than one atom of what is received, is not. The
      // web wallet's rule.
      final short = best.receive < (payAtoms * bestE!.rateDen) ~/ bestE.rateNum;
      return Estimate(pay: payAtoms, receive: best.receive, short: short ? most : null);
    }
    final r = receiveAtoms ?? BigInt.zero;
    if (r <= BigInt.zero) return const Estimate.no('too-small');
    BigInt? least;
    for (final e in es) {
      if (r > e.maxReceive || r < e.minReceive) continue;
      final p = _ceilDiv(r * e.rateNum, e.rateDen);
      if (least == null || p < least) least = p;
    }
    if (least != null) return Estimate(pay: least, receive: r);
    return r > most!.receive ? Estimate(pay: most.pay, receive: most.receive, short: most) : const Estimate.no('too-small');
  }

  /// The least expiry (median time) a resting order's coin asked of the wallet's coins in this quote,
  /// when one refused them for expiring sooner; null otherwise.
  int? _tooOldFrom;

  /// When the wallet last asked a refresh of an asset's coins for a resting order, so a quote asked
  /// again while that round runs says so rather than asking again.
  final _readyingSince = <String, int>{};

  /// Refreshes the wallet's live coins of [asset] that expire before median time [from], in the
  /// operator's next round (planned ones through their release): its new coins expire later than any
  /// order resting now. Whether coins are being made ready. The web wallet's `readyCoins`.
  Future<bool> _readyCoins(String asset, int from) async {
    final since = _readyingSince[asset];
    if (since != null && d.now() - since < kReadyingMs) return true;
    try {
      final coins = [
        for (final c in ((await _run('coins')) as List? ?? const []))
          if (c is Map && c['asset'] == asset && c['state'] == 'live') c,
      ];
      final planned = plannedLeaves((await _run('plans')) as Map?);
      final old = coins.where((c) => ((c['expiry'] as num?) ?? 0) < from).toList();
      if (old.isEmpty) return false;
      final kept = [for (final c in old) if (planned.contains('${c['leaf_id']}')) '${c['leaf_id']}'];
      final free = [for (final c in old) if (!planned.contains('${c['leaf_id']}')) '${c['leaf_id']}'];
      if (kept.isNotEmpty) d.release?.call(asset, kept);
      if (free.isNotEmpty) {
        final q = (await _run('quote', {'leaves': free, 'max_fee_ppm': kMaxFeePpm})) as Map?;
        await _run('participate', {'leaves': free, 'max_fee_ppm': kMaxFeePpm, 'shown': q?['coins']});
      }
      _readyingSince[asset] = d.now();
      d.log('[user trade] coins refreshed for a resting order: ${free.length + kept.length}');
      return true;
    } catch (e) {
      d.log('[user trade] getting coins ready: $e');
      return false;
    }
  }

  /// A firm answer within [ms], or null: a source that answers later is let go of ([drop]), so the
  /// offer it holds frees the maker's coins. The web wallet's `inTime`.
  Future<Candidate?> _inTime(Future<Candidate?> f, int ms) {
    var tooLate = false;
    final settled = f.then<Candidate?>((c) {
      if (tooLate) {
        if (c != null) {
          d.log('[user trade] a source answered after the quote, let go: ${c.source}');
          drop(c);
        }
        return null;
      }
      return c;
    }, onError: (Object e) {
      d.log('[user trade] firm: $e');
      return null;
    });
    return Future.any<Candidate?>([
      settled,
      Future.delayed(Duration(milliseconds: ms < 0 ? 0 : ms), () {
        tooLate = true;
        return null;
      }),
    ]);
  }

  /// What the wallet can pay of BTC for a trade now: what its Bitcoin Lightning holds.
  Future<BigInt> _btcHave() async {
    final b = _btc;
    try {
      return b == null ? BigInt.zero : await b.balance();
    } catch (_) {
      return BigInt.zero;
    }
  }

  /// BTC at the wallet's own address, or on its way onto the ark, which it can move where trades pay from.
  Future<BigInt> _btcAtAddress() async {
    try {
      return d.btcAtAddress == null ? BigInt.zero : await d.btcAtAddress!();
    } catch (_) {
      return BigInt.zero;
    }
  }

  int get btcMoveBlocks {
    try {
      return d.btcMoveBlocks?.call() ?? 2;
    } catch (_) {
      return 2;
    }
  }

  /// The ticket for paying [amount] of [pay] for [receive]: every source worth asking is asked for
  /// firm terms at once, and the quote takes what has answered within [UserTradeDeps.quoteFirmMs] of
  /// Review (the BTC desk alone, [kBtcOnlyFirmMs]); a late answer is let go of. The web wallet's
  /// `quote`.
  Future<QuoteResult> quote({required String pay, required String receive, required BigInt amount}) async {
    final started = DateTime.now().millisecondsSinceEpoch;
    _tooOldFrom = null;
    if (amount <= BigInt.zero) return QuoteResult.no('too-small');
    final ad = await d.admitted();
    final sources = admittedSources(ad.pairs, ad.genesis, pay, receive);
    if (sources.isEmpty) return QuoteResult.no('not-listed');
    final soonNow = soon;
    // BTC is paid over the wallet's Bitcoin Lightning (in default mode its Bitcoin ark), never from a
    // leaf. BTC the wallet holds at its address is moved there for the trade, by itself.
    BigInt have;
    var moving = false;
    if (pay == kUserBtc) {
      have = await _btcHave();
      if (have < amount && d.btcMove != null) {
        final atAddress = await _btcAtAddress();
        if (atAddress > BigInt.zero) {
          try {
            d.btcMove!(amount - have);
            moving = true;
          } catch (e) {
            d.log('[user trade] btc move: $e');
          }
          if (have <= BigInt.zero) return QuoteResult.no('btc-moving', moving: true);
        }
      }
    } else {
      have = (await spendable())[pay] ?? BigInt.zero;
    }
    if (have <= BigInt.zero) {
      // What the wallet shows it holds, though no trade can pay from it now: the wallet is asked to
      // make it ready (default mode boards coins on the chain by itself).
      BigInt held = BigInt.zero;
      if (d.held != null) {
        try {
          held = await d.held!(pay);
        } catch (_) {}
      }
      try {
        final f = figure?.call(pay);
        if (f != null && f > held) held = f;
      } catch (_) {}
      // The leaves are not open yet (the app has just started): what they hold is not known to be
      // payable or not, so the trade waits for them, priced again by itself.
      if (held > BigInt.zero && pay != kUserBtc && d.leavesOpen != null && !d.leavesOpen!()) return QuoteResult.no('opening');
      if (held > BigInt.zero) {
        // Live coins an open offline-refresh plan keeps: the library pays them only in a round, so
        // the wallet gives them up in its next one for coins a trade can pay from.
        if (pay != kUserBtc && await _freePlanned(pay)) return QuoteResult.no('freeing', soon: soonNow);
        try {
          d.prepare?.call(pay);
        } catch (_) {}
        // Coins a Bitcoin reorganisation took back out of the chain, being redone: never a loss.
        if (pay != kUserBtc) {
          try {
            final coins = (await _run('coins')) as List? ?? const [];
            if (coins.any((c) => c is Map && c['asset'] == pay && c['redoing'] == true)) return QuoteResult.no('redoing');
          } catch (_) {}
        }
        return QuoteResult.no('not-ready', soon: soonNow);
      }
      return QuoteResult.no('no-funds');
    }
    // The entries read for the estimate a moment ago stand: the firm terms are what the ticket shows.
    final fresh = _estimates['$pay>$receive'];
    final es = fresh != null && d.now() - fresh.at <= kEntriesFreshMs ? fresh.es : await _entries(pay, receive, sources);
    final limit = amount < have ? amount : have;
    final ind = [
      for (final e in es)
        if ((e.source != 'btc-gateway' || _btc != null) && sizeEntry(e, limit) != null) (e: e, r: sizeEntry(e, limit)!.receive),
    ]..sort((a, b) => b.r.compareTo(a.r));
    // A maker quoting several levels of one pair is asked once, at the level that gives the most
    // for this size: each firm offer holds its coins.
    final seen = <String>{};
    ind.removeWhere((x) => x.e.maker != null && !seen.add('${x.e.maker}|${x.e.source}'));
    // The amount would trade, but what the wallet can pay now is less than any offer takes: the rest
    // of what it holds is not ready yet. Said so, never "too small".
    if (ind.isEmpty && have < amount && es.any((e) => sizeEntry(e, amount) != null)) {
      if (pay != kUserBtc && await _freePlanned(pay)) return QuoteResult.no('freeing', soon: soonNow);
      if (pay == kUserBtc && moving) return QuoteResult.no('btc-moving', moving: true);
      return QuoteResult.no('part-ready', ready: have, soon: soonNow);
    }
    // Firm terms of the best eight, all asked at once, within the quote's time: an entry that cannot
    // be firmed, or that has not answered by then, is left out, and a late answer is let go of. When
    // none gives firm terms and there is time left, they are asked once more a moment later.
    final worth = ind.take(8).toList();
    final btcOnly = worth.isNotEmpty && worth.every((x) => x.e.source == 'btc-gateway');
    final window = btcOnly ? (d.btcOnlyFirmMs ?? kBtcOnlyFirmMs) : d.quoteFirmMs;
    final w = math.max(window, d.quoteFirmMs);
    // Wall-clock time: the person's wait (d.now may be a test's stand-in clock).
    final int until = math.max(started + w, DateTime.now().millisecondsSinceEpoch + math.min(kQuoteFirmMinMs, w));
    final cands = <Candidate>[];
    for (var round = 0; round < 2 && cands.isEmpty; round++) {
      if (round > 0) {
        final left = until - DateTime.now().millisecondsSinceEpoch;
        if (left < math.min(kFirmRetryMs + 2000, w ~/ 2)) break;
        await d.sleep(kFirmRetryMs);
      }
      final got = await Future.wait(
          worth.map((x) => _inTime(_firm(x.e, pay, receive, amount, have), until - DateTime.now().millisecondsSinceEpoch)));
      for (final c in got) {
        if (c != null) cands.add(c);
      }
    }
    final best = chooseCandidate(cands);
    for (final c in cands) {
      if (c != best) drop(c);
    }
    // Less is free than the amount needs, and the rest is in coins an offline-refresh plan keeps:
    // those are freed through the wallet's next round, never called too small.
    if (best == null && pay != kUserBtc && have < amount && await _freePlanned(pay)) return QuoteResult.no('freeing', soon: soonNow);
    // No firm offer, and the resting orders refused the wallet's coins only for expiring before the
    // order's coin: those are refreshed in the next round, and the trade is priced again once in.
    if (best == null && _tooOldFrom != null && pay != kUserBtc && await _readyCoins(pay, _tooOldFrom!)) {
      return QuoteResult.no('readying', soon: soonNow);
    }
    // Offered, but nobody gave firm terms: that is not the amount's fault.
    if (best == null) return QuoteResult.no(es.isEmpty ? 'not-offered' : (ind.isNotEmpty ? 'no-firm-offer' : 'too-small'));
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
      moving: moving,
    );
  }

  /// Lets go of a priced candidate nobody takes (a review declined or lapsed): a maker's firm
  /// offer and a BTC desk's quote stop holding coins for it.
  void drop(Candidate? c) {
    if (c == null) return;
    if (c.btc != null) {
      _btcT.drop(c.entry.maker, c.btc!);
    } else if (c.offer != null) {
      release(c.entry.maker, '${c.offer!['swap']}');
    }
  }

  /// Trades this engine is confirming now: their records read `confirming` while the step is taken,
  /// and following them ([advance]) waits until it is.
  final _confirmingNow = <String>{};
  bool confirmingNow(Object? id) => _confirmingNow.contains('$id');

  /// Confirms a ticket's choice. The record is written at once, so the trade shows in Open as
  /// "Sending…" whatever the screen does next; [started] is told its id before the step is taken.
  /// Answers the record once the one step is taken; [advance] follows it from there.
  Future<Map<String, dynamic>> confirm(Candidate c, Ticket t, {void Function(String id)? started}) async {
    final id = '${d.now()}-${d.now().hashCode.toRadixString(16)}${(await records()).length}';
    _confirmingNow.add(id);
    final rec = await _put({'id': id, 'at': d.now(), 'source': c.source, 'state': 'confirming', 'ticket': t.toJson()});
    started?.call(id);
    try {
      return await _confirm(c, rec);
    } finally {
      _confirmingNow.remove(id);
      _changes.add(null);
    }
  }

  Future<Map<String, dynamic>> _confirm(Candidate c, Map<String, dynamic> rec) async {
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

  final _advancing = <String, Future<Map<String, dynamic>>>{};

  /// Moves one trade on. A trade already being moved on (the Swap tab and a connected site both
  /// follow trades) is not moved twice at once: the second call waits for the first.
  Future<Map<String, dynamic>> advance(Map<String, dynamic> rec) {
    final id = '${rec['id']}';
    // The callback returns nothing: returning the removed future would wait on itself.
    return _advancing[id] ??= _advance(rec).whenComplete(() {
      _advancing.remove(id);
    });
  }

  Future<Map<String, dynamic>> _advance(Map<String, dynamic> rec) async {
    if (['settled', 'returned', 'failed'].contains(rec['state'])) return rec;
    // Its step is being taken here now: nothing to look for yet.
    if (_confirmingNow.contains('${rec['id']}')) return rec;
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
