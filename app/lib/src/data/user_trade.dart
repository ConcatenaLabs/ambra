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

/// How long the sources are given to answer for firm terms, from the moment they are asked: every
/// source worth asking is asked at once, and one whose answer has not come by then is left out of
/// the ticket (a late answer is let go of). It counts from the asking, never from Review: what the
/// wallet itself does first, behind whatever its library is busy with, is not taken out of a
/// maker's time. The web wallet's QUOTE_FIRM_MS.
const int kQuoteFirmMs = 8000;

/// How many sources are asked for firm terms at once: each one's check runs on the wallet's library,
/// one command at a time, so every source more holds the first answer back (eight took 2 to 5 s each
/// on a phone, and none came within the window). The web wallet's FIRM_AT_ONCE.
const int kFirmAtOnce = 4;

/// How long, past [kQuoteFirmMs], the wallet's own reading of firm terms a source gave in time (the
/// library's check of an offer, of a fee) may take while no other firm terms are in hand: the
/// library answers one command at a time, and a sync it was running holds that check up. The web
/// wallet's QUOTE_READ_MS.
const int kQuoteReadMs = 30000;

/// What the wallet can pay, as last read, stands for a quote this long: a quote never waits behind
/// the library to learn it (each quote reads it again behind the price). The web wallet's
/// HOLDINGS_FRESH_MS.
const int kHoldingsFreshMs = 60000;

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

/// The longest a trade that settles first waits for its coins when the library has not said how long
/// they take, before it comes back with nothing traded; when it says (`final_in_seconds`), twice that
/// and [kSettleMarginMs], if longer. The web wallet's SETTLE_MOST_MS and SETTLE_MARGIN_MS.
const int kSettleMostMs = 10 * 60000;
const int kSettleMarginMs = 120000;

/// A trade whose coins must settle first is shown at the book's price now: it goes once they are
/// through only for at least that price less the fees last seen for the asset paid, less this slack
/// in parts per ten thousand. The web wallet's SETTLE_SLACK_BP.
final BigInt kSettleSlackBp = BigInt.from(100);

/// A settling trade priced again and refused once more for coins that wait for a round asks the other
/// side again only after the wait that refusal gave, and at least this long after. The web wallet's
/// REPRICE_AGAIN_MS.
const int kRepriceAgainMs = 30000;

/// How long a settling trade may wait, by the library's `final_in_seconds`. The web wallet's
/// settleBound().
int settleBound(Object? finalInSeconds) {
  final s = finalInSeconds is num ? finalInSeconds : num.tryParse('${finalInSeconds ?? ''}');
  if (s == null || s <= 0) return kSettleMostMs;
  return math.max(kSettleMostMs, (2 * s * 1000).round() + kSettleMarginMs);
}

/// How many offers of one trade may be gone (each priced again at once) before it is returned. The
/// web wallet's GONE_MOST.
const int kGoneMost = 3;

/// How long a trade whose other side's offer is gone keeps asking for a price within what was
/// accepted (the wallet busy, no firm offer yet) before it is returned. The web wallet's
/// REPRICE_MOST_MS.
const int kRepriceMostMs = 60000;

/// A pair offered within this long that nobody offers now: a maker reading its coins again after a
/// trade quotes nothing for up to about 90 s, so the wallet asks again, every
/// [kOfferedAgainEveryMs], rather than saying the pair is not offered. The web wallet's
/// OFFERED_AGAIN_MS and OFFERED_AGAIN_EVERY_MS.
const int kOfferedAgainMs = 3 * 60000;
const int kOfferedAgainEveryMs = 5000;

/// The trade records kept: every unfinished trade's, always, since it is what lets a restart resume
/// or return the trade; and the newest ended ones, up to [kKeepEnded] of them and [kKeepBytes] in
/// all, the oldest out first. History draws its trade rows from these records, so a trade that ended
/// before the newest [kKeepEnded] is no longer a row there: the coins it brought are in the balance.
/// The web wallet's KEEP_ENDED and KEEP_BYTES.
const int kKeepEnded = 200;
const int kKeepBytes = 1000000;
const List<String> kEndedStates = ['settled', 'returned', 'failed', 'undone'];

/// [list] (oldest first) with its oldest ended records dropped until at most [keep] ended ones are
/// left and the whole is at most [bytes] long as JSON. An unfinished record is never dropped. An ended
/// record keeps no list of what the wallet held before it (`before`, `beforeParts`): only an
/// unfinished trade looks for what it brought among them, and each list is the wallet's whole coin
/// history. The web wallet's boundedRecords().
List<Map<String, dynamic>> boundedRecords(List<Map<String, dynamic>> list0, int keep, int bytes) {
  bool ended(Map r) => kEndedStates.contains(r['state']);
  final list = [
    for (final r in list0)
      if (ended(r) && (r.containsKey('before') || r.containsKey('beforeParts')))
        (Map<String, dynamic>.from(r)
          ..remove('before')
          ..remove('beforeParts'))
      else
        r,
  ];
  final size = [for (final r in list) utf8.encode(jsonEncode(r)).length + 1];
  var endedLeft = list.where(ended).length;
  var total = size.fold<int>(1, (a, b) => a + b);
  final drop = <int>{};
  for (var i = 0; i < list.length && (endedLeft > keep || total > bytes); i++) {
    if (!ended(list[i])) continue;
    drop.add(i);
    endedLeft--;
    total -= size[i];
  }
  return drop.isEmpty ? list : [for (var i = 0; i < list.length; i++) if (!drop.contains(i)) list[i]];
}

/// A trade whose record could not be kept: nothing is signed for it ([UserWords.storageFull]).
class StorageFullError implements Exception {
  @override
  String toString() => UserWords.storageFull;
}

/// A maker's refusal over HTTP, with the body it answered (a completion the operator refused says
/// `gone`, and may carry the offer the maker made in its place).
class MakerError implements Exception {
  MakerError(this.message, [this.body = const {}]);
  final String message;
  final Map body;
  @override
  String toString() => message;
}

/// Whether refusal [e] says a coin the wallet held ([held], the leaf ids it held before the step) is
/// spent already: the operator's `double_spend`, naming the coin. The web wallet's spentElsewhere().
/// Whether [e] is the library's refusal of a take because the order was filled or refunded by
/// someone else first (`order <outpoint> is spent, in a block or in the node's mempool`): the offer
/// is gone, and the trade is priced again as for a gone offer.
bool orderTaken(Object e) => RegExp(r"\border \S+ is spent, in a block or in the node's mempool").hasMatch('$e');

bool spentElsewhere(Object e, List? held) {
  final m = '$e';
  if (!m.contains('double_spend')) return false;
  final named = RegExp(r'\b[0-9a-fA-F]{64}\b').firstMatch(m)?.group(0)?.toLowerCase();
  return named != null && (held ?? const []).map((x) => '$x'.toLowerCase()).contains(named);
}

/// What a trade priced again has paid already, in the asset paid: a cancel's respend margins.
BigInt paidAlready(Map r) => _big(r['cancelFees']);

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
  'claim',
  'claims',
  'distribution',
  'distributions',
  'lapse',
  'lapses',
  'locktime',
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
  /// Still at it past the makers' window: the wallet is checking the price it was given.
  static const pricingLong = 'Still getting the exact price: this can take up to half a minute…';
  // The best offers are orders resting in the tree that only coins expiring later can fill: the
  // wallet refreshes its older coins in the next round, and prices the trade again once they are in.
  static String readying(String pay, [bool soon = false]) => soon
      ? 'Getting your $pay ready for this trade: it is ready in a minute or two. Nothing has moved.'
      : 'Getting your $pay ready for this trade: it is ready once the next Bitcoin blocks settle it. Nothing has moved.';
  static const opening = 'Your wallet is still opening: try again in a moment. Nothing has moved.';
  static const noFirmOffer = 'Nobody could confirm a price for this just now. Nothing has moved: try again in a moment.';
  /// The wallet's own library was busy finishing something it started for longer than Review waits.
  static const walletBusy = 'Your wallet is still finishing something it started, so it could not get a price in time. Nothing has moved: try again in a moment.';
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
  // What is paid waits for the network to settle it first, and the wallet has not said how long: the
  // trade goes ahead by itself after, and no time is promised until the wallet says one.
  static const settling = 'Goes through by itself once what you pay is ready';
  // A ticket accepted before what it pays is settled: the book's price now, and the least it goes for
  // once settled, its fees taken; less than that and it comes back.
  static String atLeast(String x) => 'You receive at least $x after fees, or the trade comes back and nothing is traded.';
  static String goesThrough(int minutes) => minutes <= 1 ? 'Goes through in about a minute' : 'Goes through within about $minutes minutes';
  static const goesThroughLate = 'Taking longer than usual: this goes ahead by itself, or is returned with nothing traded';
  // A trade that waited for its coins past the most it was to wait.
  static const returnedLate = 'Returned: nothing traded. It took too long to get ready.';
  static const sent = 'Sent';
  static const settled = 'Settled';
  // Buying with BTC, until what is bought is held for the wallet (its round, then that round's block
  // certified): the wallet pays its BTC only then, and only while the app runs. Closed before that,
  // nothing is traded and nothing is paid. [m]: the minutes left of the wait the library states.
  static String waitingOther(int m) =>
      'Keep the app open: your BTC is paid once what you buy is held for you, within about $m minute${m == 1 ? '' : 's'}. Nothing has left your wallet yet. If the app closes first, nothing is traded.';
  // The same, past the wait the library stated by [kSettleLateMs].
  static const waitingOtherLate =
      'Keep the app open: this is taking longer than usual. Your BTC is paid once what you buy is held for you, and nothing has left your wallet yet. If the app closes first, nothing is traded.';
  // Buying with BTC, the BTC being paid: seconds.
  static const btcPaying = 'Paying your BTC. Keep the app open a moment more.';
  // Buying with BTC, the BTC paid and its proof handed on, what was bought being collected: it comes
  // to the wallet on any device, open or not (the operator holds what claims it).
  static const btcCollecting = 'Paid. What you bought is arriving, and it comes to your wallet even if the app closes.';
  // A trade whose taking back waits for an answer that has not come: the wallet asks again by itself.
  static const sentAwaiting = 'Sent, waiting for an answer: nothing more is needed from you';
  // A sale for BTC whose asset is paid: the BTC comes once the other side pays it out.
  static const btcOnItsWay = 'Paid. Your BTC is on its way.';
  // What the trade brings is the wallet's; only its settling with the network is left. One word on
  // every surface, with no time: how long settling takes is the network's, not the trade's.
  static const received = 'Received, settling';
  // A trade whose coins settle in the operator's next round: the wait the wallet gives a round of
  // this operator ([settleMinutesOf]), stated when the settle starts.
  static String receivedWithin(int n) => 'Received, settling (within about $n min)';
  static const receivedSlow = 'Received, and yours to use. Settling with the network is taking longer than usual.';
  static String minutes(String word, int n) => '$word ($n min)';
  static const returned = 'Returned: nothing traded.';
  static String returnedFees(String fees) => 'Returned: nothing traded. Fees of $fees were paid.';
  static const returnedLapsed = 'Returned: nothing traded. The other side\'s offer ran out while the trade waited.';
  // A trade priced again after its other side's offer was gone, whose price then moved past what was
  // accepted: nothing traded.
  static const returnedMoved = 'Returned: nothing traded. The price moved while it waited.';
  // A trade priced again, whose coins were no longer the wallet's to pay with (spent by another
  // payment, or another device of the wallet).
  static const returnedGone = 'Returned: nothing traded. Your wallet no longer holds what it was to pay.';
  // A pair offered a moment ago that nobody offers now: asked again by itself.
  // Nobody offers the pair now, and a purchase of the wallet's own paid with BTC is still to pay: the
  // other side holds what it sells for that purchase until it is paid, so this one waits for it.
  static const btcAhead = 'You have a purchase paid with BTC under way: this one can be priced once that one is paid. Nothing has moved.';
  static String offeredAgain(String get, String pay) => 'Getting a price for $get for $pay: it takes a moment. Nothing has moved.';
  // The trade's record could not be kept on the phone: the trade is not made, nothing signed.
  static const storageFull = 'The trade was not made: this phone has no room left to keep its record. Nothing was signed.';
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
    pricingLong,
    noFirmOffer,
    walletBusy,
    opening,
    readying('XT'),
    readying('XT', true),
    partReady('1 XT', 'XT'),
    partReady('1 XT', 'XT', true),
    btcMoving(2),
    btcMoving(1),
    btcMore(2),
    priceMoved,
    settling,
    atLeast('1 YT'),
    goesThrough(1),
    goesThrough(6),
    goesThroughLate,
    returnedLate,
    sent,
    settled,
    waitingOther(1),
    waitingOther(6),
    waitingOtherLate,
    btcPaying,
    btcCollecting,
    sentAwaiting,
    btcOnItsWay,
    received,
    receivedWithin(6),
    receivedSlow,
    minutes(sent, 3),
    returned,
    returnedFees('1 XT'),
    returnedLapsed,
    returnedMoved,
    returnedGone,
    offeredAgain('YT', 'XT'),
    btcAhead,
    storageFull,
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

/// What the list of trades says of one: Sent, then Settled. A purchase paid with BTC waiting for
/// what it buys states the wait the leaf library states (`lightning_receive_ready`, kept in `waitBy`;
/// before its first answer, its figure for the operator's next round, `waitFirstBy`), and past it by
/// [kSettleLateMs] that it takes longer. A received trade settling in a round states the wait the
/// wallet gives a round of its operator (`settleMin`, set when the settle starts), and past it by
/// [kSettleLateMs] that settling takes longer. Otherwise the minutes waited, once it has waited one:
/// a minutes count is never a promise. Null for a trade returned with fees paid (the row names the
/// fees). The web wallet's tradeStateWord(); the same words in the Swap tab's Open trades, in History
/// and on every other surface.
String? tradeStateWord(Map r, int nowMs) {
  final st = r['state'];
  if (st == 'settled') return UserWords.settled;
  if (st == 'returned' && ((r['feesPaid'] as List?) ?? const []).isNotEmpty) return null;
  if (st == 'returned' && r['whyKind'] == 'lapsed') return UserWords.returnedLapsed;
  if (st == 'returned' && r['whyKind'] == 'moved') return UserWords.returnedMoved;
  if (st == 'returned' && r['whyKind'] == 'gone') return UserWords.returnedGone;
  if (st == 'returned' && r['whyKind'] == 'late') return UserWords.returnedLate;
  // Confirmed, and what it pays being settled first: it goes ahead by itself once through, within
  // the wait the library last said (`finalBy`), and past that by [kSettleLateMs], that it takes
  // longer; before the library has said, no time.
  if (st == 'settling') {
    final by = (r['finalBy'] as num?)?.toInt();
    if (by == null) return UserWords.settling;
    return nowMs > by + kSettleLateMs ? UserWords.goesThroughLate : UserWords.goesThrough(math.max(1, ((by - nowMs) / 60000).ceil()));
  }
  if (st == 'returned' || st == 'failed') return UserWords.returned;
  if (st == 'confirming') return UserWords.sending;
  int? ms(Object? v) => (v as num?)?.toInt();
  int since(Object? t) => ((nowMs - (ms(t) ?? ms(r['at']) ?? nowMs)) / 60000).floor();
  // Buying with BTC: nothing has left the wallet until its asset is held for it.
  if (st == 'waiting') {
    final wb = r['waitBy'];
    final by = (wb is Map ? ms(wb['finalBy']) : null) ??
        ms(r['waitFirstBy']) ??
        ((ms(r['waitingSince']) ?? ms(r['at']) ?? nowMs) + settleMinutesOf(null) * 60000);
    if (nowMs > by + kSettleLateMs) return UserWords.waitingOtherLate;
    return UserWords.waitingOther(math.max(1, ((by - nowMs) / 60000).ceil()));
  }
  // Priced again after its other side's offer was gone: still Sent, until it goes or comes back.
  if (st == 'repricing') return UserWords.sent;
  final m = since(r['sentAt']);
  final held = heldAlready(r);
  final settling = held && ((r['settleState'] as List?) ?? const []).any((x) => x != null && x != 'released');
  // Settling in a round: the wait stated, and past it by [kSettleLateMs] that it takes longer. A
  // minutes count since the trade was sent would read as a promise it is not.
  final settleMin = ms(r['settleMin']);
  if (settling && settleMin != null && settleMin > 0) {
    final lateAt = (ms(r['settleSince']) ?? ms(r['sentAt']) ?? ms(r['at']) ?? nowMs) + settleMin * 60000 + kSettleLateMs;
    return nowMs > lateAt ? UserWords.receivedSlow : UserWords.receivedWithin(settleMin);
  }
  if (held && r['settle'] != null && settleMin == null) return UserWords.received;
  // Received, its settling still waiting with the network after [kSlowSettleMin] minutes: said so,
  // the coins being the wallet's all along.
  final String word;
  if (held) {
    word = m >= kSlowSettleMin && settling ? UserWords.receivedSlow : UserWords.received;
  } else if (r['source'] == 'btc-gateway' && r['dir'] == 'sell') {
    word = UserWords.btcOnItsWay;
  } else if (r['source'] == 'btc-gateway' && r['dir'] != 'sell') {
    word = r['preimage'] != null && r['posted'] == true ? UserWords.btcCollecting : UserWords.btcPaying;
  } else {
    word = r['awaiting'] == true ? UserWords.sentAwaiting : UserWords.sent;
  }
  return m >= 1 ? UserWords.minutes(word, m) : word;
}

/// Whether the open trades [recs] are followed every few seconds at [nowMs], rather than every
/// [kFollowSlowMs]: a trade sent within [kFollowFastMs]; one that waits (a purchase paid with BTC
/// waiting for its asset: its BTC is paid the moment the asset is); and one received whose settling
/// is still under way, until it is called late ([kSlowSettleMin]). The web wallet's followFast.
bool followFast(List<Map> recs, int nowMs) => recs.any((r) {
      final age = nowMs - (((r['sentAt'] ?? r['at']) as num?)?.toInt() ?? 0);
      if (r['state'] == 'waiting' || r['state'] == 'repricing' || age < kFollowFastMs) return true;
      final settling = heldAlready(r) && ((r['settleState'] as List?) ?? const []).any((x) => x != null && x != 'released');
      return settling && age < kSlowSettleMin * 60000;
    });

/// How long a trade is followed every few seconds after it is sent, and how often after that.
const int kFollowFastMs = 120000;
const int kFollowSlowMs = 30000;

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
    this.about,
    this.finalBy,
  });
  final String payAsset, receiveAsset, source;
  final BigInt amountIn, amountOut;
  final List<Map<String, dynamic>> fees;
  final BigInt? upTo;

  /// A ticket accepted before what it pays is settled (source 'settling'): what it receives at the
  /// book's price now ([about]; [amountOut] is the least it goes for), and when the library said
  /// those coins would be through ([finalBy], ms; null while it has not said).
  final BigInt? about;
  final int? finalBy;
  bool get indicative => about != null;
  Map<String, dynamic> toJson() => {
    'payAsset': payAsset,
    'receiveAsset': receiveAsset,
    'amountIn': '$amountIn',
    'amountOut': '$amountOut',
    'fees': fees.map((f) => {'asset': f['asset'], 'atoms': '${f['atoms']}'}).toList(),
    'source': source,
    if (upTo != null) 'upTo': '$upTo',
    if (about != null) 'about': '$about',
    if (about != null) 'indicative': true,
    if (finalBy != null) 'finalBy': finalBy,
  };
  static Ticket fromJson(Map j) => Ticket(
    payAsset: '${j['payAsset']}',
    receiveAsset: '${j['receiveAsset']}',
    amountIn: _big(j['amountIn']),
    amountOut: _big(j['amountOut']),
    fees: [for (final f in (j['fees'] as List?) ?? const []) Map<String, dynamic>.from(f as Map)],
    source: '${j['source']}',
    upTo: j['upTo'] == null ? null : _big(j['upTo']),
    about: j['about'] == null ? null : _big(j['about']),
    finalBy: (j['finalBy'] as num?)?.toInt(),
  );
}

class QuoteResult {
  QuoteResult.ok(this.ticket, this.choice, {this.moving = false}) : why = null, soon = false, ready = null, again = false, coins = const [], wait = null;
  QuoteResult.no(this.why, {this.soon = false, this.ready, this.moving = false, this.again = false, this.coins = const [], this.wait})
      : ticket = null,
        choice = null;
  final Ticket? ticket;
  final Candidate? choice;
  // not-listed | not-offered | no-funds | not-ready | redoing | freeing | readying | part-ready |
  // btc-moving | too-small | no-firm-offer | wallet-busy | opening | btc-ahead | settle-first (only
  // inside the engine: [UserTradeEngine.quote] answers it with a ticket that settles first)
  final String? why;
  /// part-ready: what can be paid now.
  final BigInt? ready;
  /// BTC: more of what the wallet holds at its address is being moved where trades pay from.
  final bool moving;
  /// What is not ready yet is ready in a minute or two (the operator's anchor depth is 0).
  final bool soon;
  /// not-offered: the pair was offered a moment ago ([kOfferedAgainMs]), so it is asked again.
  final bool again;
  /// settle-first: the coins the library named to put through the next round (none: every coin of
  /// the asset that waits for one), and the wait its refusal gave (`final_in_seconds`,
  /// `usual_in_seconds`, `waiting_for`), or null.
  final List<String> coins;
  final Map<String, dynamic>? wait;
  bool get ok => ticket != null;
}

/// The indicative amounts of [UserTradeEngine.estimate]: [pay] for [receive], and [short] when
/// the book fills less than was typed (the most one source fills now). Or [why] it has none:
/// not-listed | not-offered | too-small.
class Estimate {
  const Estimate({required BigInt this.pay, required BigInt this.receive, this.short}) : why = null, again = false;
  const Estimate.no(String this.why, {this.again = false}) : pay = null, receive = null, short = null;
  final BigInt? pay, receive;
  final ({BigInt receive, BigInt pay})? short;
  final String? why;
  /// not-offered: the pair was offered a moment ago ([kOfferedAgainMs]), so it is asked again.
  final bool again;
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
    this.quoteReadMs,
    this.keepEnded,
    this.keepBytes,
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

  /// How long past [quoteFirmMs] the wallet's own check of firm terms that came in time may run
  /// while none is in hand ([kQuoteReadMs]).
  final int? quoteReadMs;

  /// The bounds of the trade records kept ([kKeepEnded], [kKeepBytes]); tests set them smaller.
  final int? keepEnded, keepBytes;
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

  // One sync serves every trade moving on at the same time, and the next starts no sooner than
  // 10 s, or twice what the last one took, after it ended: a phone's sync takes 20 to 40 s on a
  // busy operator, and a sync per open trade every pass kept the library busy all the time, so a
  // payment to the wallet waited behind them (the web wallet's syncShared, paced by cost).
  Future<void>? _syncing;
  int? _syncEnd;
  int _syncCost = 0;
  Future<void> _syncShared() {
    final running = _syncing;
    if (running != null) return running;
    final end = _syncEnd;
    final gap = _syncCost * 2 > 10000 ? _syncCost * 2 : 10000;
    if (end != null && d.now() - end < gap) return Future.value();
    final t0 = d.now();
    final f = _run('sync').then((_) {}, onError: (Object e) => d.log('[user trade] sync: $e')).whenComplete(() {
      _syncCost = d.now() - t0;
      _syncEnd = d.now();
      _syncing = null;
    });
    _syncing = f;
    return f;
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

  /// Writes one record, one write at a time (each reads the list the last one left), bounded
  /// ([boundedRecords]). A store that refuses the write is tried again with fewer ended trades kept,
  /// then with none; one that refuses even that refuses the trade ([StorageFullError]): [confirm]
  /// writes the record before anything is signed, so a trade whose record cannot be kept is never
  /// signed. A record's first write in an ended state stamps when it ended (`endedAt`).
  Future<Map<String, dynamic>> _put(Map<String, dynamic> rec) {
    final f = _writes.then((_) => _putNow(rec));
    _writes = f.then((_) {}, onError: (_) {});
    return f;
  }

  Future<void> _writes = Future.value();

  Future<Map<String, dynamic>> _putNow(Map<String, dynamic> rec) async {
    if (kEndedStates.contains(rec['state']) && rec['endedAt'] == null) rec['endedAt'] = d.now();
    final l = await records();
    final i = l.indexWhere((r) => r['id'] == rec['id']);
    if (i >= 0) {
      l[i] = rec;
    } else {
      l.add(rec);
    }
    final keep = d.keepEnded ?? kKeepEnded, bytes = d.keepBytes ?? kKeepBytes;
    Object? refused;
    for (final (k, b) in [(keep, bytes), (keep ~/ 4, bytes ~/ 4), (0, 0)]) {
      try {
        await d.write(jsonEncode(boundedRecords(l, k, b)));
        refused = null;
        break;
      } catch (e) {
        refused = e;
      }
    }
    if (refused != null) {
      d.log('[user trade] the trade records could not be written: $refused');
      throw StorageFullError();
    }
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
    final sp = spendableFrom(coins, plans);
    _holdings = (sp: sp, at: d.now());
    return sp;
  }

  /// What the wallet can pay, as last read ([kHoldingsFreshMs]), and a reading under way.
  ({Map<String, BigInt> sp, int at})? _holdings;
  Future<Map<String, BigInt>>? _holdingsRead;
  Future<Map<String, BigInt>> _readHoldingsSoon() =>
      _holdingsRead ??= spendable().whenComplete(() => _holdingsRead = null);

  /// What the wallet can pay for a quote: the last reading while it is fresh (read again behind the
  /// quote, never ahead of it), else a reading now. A reading too high is caught by the source's
  /// own check (the library refuses what the coins cannot pay, and the terms are asked again for
  /// less); the person never waits on the library's queue to learn it.
  Future<Map<String, BigInt>> _spendableForQuote() async {
    final h = _holdings;
    if (h != null && d.now() - h.at < kHoldingsFreshMs) {
      unawaited(_readHoldingsSoon().then((_) {}, onError: (_) {}));
      return h.sp;
    }
    return _readHoldingsSoon();
  }

  Future<List<BookEntry>> _entries(String pay, String receive, List<String> sources) async {
    final out = <BookEntry>[];
    // A maker quotes in-tree swaps, and, with a Bitcoin Lightning node, BTC in one hash-lock.
    if (sources.contains('leaf-maker') || (sources.contains('btc-gateway') && _btc != null)) {
      // Every maker at once: one that does not answer costs its own wait, not the others'.
      final got = await Future.wait(d.makers().map((m) async {
        try {
          final q = await d.fetchJson('$m/v1/quotes');
          // Every pair the maker offers now, not only the one asked: a pair asked next that it offered
          // a moment ago and offers not now is asked again ([kOfferedAgainMs]), not refused.
          for (final x in (q['quotes'] as List?) ?? const []) {
            if (x is Map && x['want_asset'] != null && x['give_asset'] != null && _big(x['max_give']) > BigInt.zero) {
              _offeredAt['${x['want_asset']}>${x['give_asset']}'] = d.now();
            }
          }
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
    if (out.isNotEmpty) _offeredAt['$pay>$receive'] = d.now();
    return out;
  }

  /// When each directed pair (pay>receive) last had an entry: see [kOfferedAgainMs].
  final _offeredAt = <String, int>{};

  /// Whether the pair was offered a moment ago, though nobody offers it now.
  bool offeredAgain(String pay, String receive) {
    final at = _offeredAt['$pay>$receive'];
    return at != null && d.now() - at < kOfferedAgainMs;
  }

  Map? _info;
  int _infoAt = 0;

  /// What the operator's round can pay of `asset` now (its `info`'s `fundable`, read at most every
  /// [kInfoMs]), or null when the operator does not say.
  Future<BigInt?> operatorRoom(String asset) async {
    final info = await _operatorInfo();
    if (info == null) return null;
    final si = info['server_info'];
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
  ///
  /// Each asking again is one library command more that every other waits behind: none is asked
  /// again on a refusal the same as the last, which a smaller fill did not change (four such asks
  /// held a wallet for ten minutes).
  Future<Candidate?> _firmResting(BookEntry e, String pay, String receive, BigInt limit, BigInt first) async {
    var r = first;
    String? lastRefusal;
    for (var i = 0; i < 4; i++) {
      Map q;
      try {
        q = (await _run('order_fill_resting_quote', {'order': e.id, 'amount': '$r'})) as Map;
      } catch (err) {
        // A fill spends only the wallet's coins no older than the order's: when those hold less
        // than the fill takes, the library says how much they hold, and the fill is sized to it.
        final m = RegExp(r'the outputs take (\d+) of asset \S+, more than the (\d+) the inputs hold').firstMatch('$err');
        final same = m != null && lastRefusal == m.group(0);
        if (m != null) lastRefusal = m.group(0);
        if (m != null && !same && BigInt.parse(m.group(1)!) > BigInt.zero) {
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
        _noteLiveShort(err);
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

  /// What the last check of a maker's offer added to its price (its margins, and settling the
  /// change), by the asset paid.
  final _marginsSeen = <String, BigInt>{};

  Future<Candidate?> _firm(BookEntry e, String pay, String receive, BigInt amount, BigInt have, {int? until, int? hard}) async {
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
          _noteLiveShort(err);
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
      // The next offer of an asset is asked for what the last check added to its price less, so the
      // check does not send it back for a smaller one.
      final guess = _marginsSeen[pay] ?? BigInt.zero;
      final fitted = guess > BigInt.zero && limit > guess ? sizeEntry(e, limit - guess) : null;
      var give = fitted?.receive ?? size.receive;
      // The offer a maker made in place of one whose completion the operator refused: taken as the
      // maker's firm offer here, at its own size, rather than asking again.
      var made = _madeAgain[e.maker];
      if (made != null && made['give_asset'] == receive && made['want_asset'] == pay) {
        _madeAgain.remove(e.maker);
        give = _big(made['give']);
      } else {
        made = null;
      }
      for (var i = 0; i < 4; i++) {
        Map<String, dynamic> o;
        if (i == 0 && made != null) {
          o = made;
        } else {
          try {
            // A maker that has not answered by the quote's deadline is left out of it; should its offer
            // come later, it is let go of at once. An offer asked again for less, after the wallet's
            // check, is given the makers' time again, never past [hard].
            final f = d.fetchJson('${e.maker}/v1/firm', post: {'give_asset': receive, 'want_asset': pay, 'give': '$give'});
            if (until == null) {
              o = await f;
            } else {
              final nowMs = DateTime.now().millisecondsSinceEpoch;
              final askBy = i == 0 ? until : math.min(nowMs + d.quoteFirmMs, hard ?? until);
              final left = askBy - nowMs;
              o = await f.timeout(Duration(milliseconds: left < 1000 ? 1000 : left), onTimeout: () {
                f.then((late) => release(e.maker, '${late['swap']}'), onError: (_) {});
                throw TimeoutException('the maker did not answer in time');
              });
            }
          } catch (err) {
            d.log('[user trade] maker firm: $err');
            return null;
          }
        }
        Map t;
        try {
          t = (await _run('swap_read', {'offer': o['offer']})) as Map;
        } catch (err) {
          d.log('[user trade] swap_read: $err');
          _noteLiveShort(err);
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
        _marginsSeen[pay] = total - _big((t['gives'] as Map)['value']);
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
    // While the amount is typed, what the wallet can pay is read behind it, so Review finds it.
    final h = _holdings;
    if (pay != kUserBtc && (h == null || d.now() - h.at > 10000)) unawaited(_readHoldingsSoon().then((_) {}, onError: (_) {}));
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
    if (es.isEmpty) return Estimate.no('not-offered', again: offeredAgain(pay, receive));
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

  /// Whether a source's check in this quote found the wallet's coins of the asset paid not live now
  /// (given up in a refresh, received and not yet settled): the trade waits on them, and says so.
  bool _liveShort = false;

  /// What a source's check in this quote found waiting only for a round (the library's
  /// `settle_first`: coins arriving, at the operator's depth limit, or of a format the other side
  /// does not read), with the coins it named and the longest wait it gave: the trade settles them
  /// first, and goes.
  ({List<String> coins, Map<String, dynamic>? wait})? _settleSeen;
  void _noteLiveShort(Object err) {
    if ('$err'.contains(' in live coins')) _liveShort = true;
    if (refusalKind(err) == 'settle_first') {
      final f = refusalFields(err);
      final coins = {...?_settleSeen?.coins, for (final c in (f['coins'] as List?) ?? const []) '$c'}.toList();
      final prev = _settleSeen?.wait;
      final fin = f['final_in_seconds'];
      final longer = fin is num && (prev == null || fin > ((prev['final_in_seconds'] as num?) ?? -1));
      _settleSeen = (
        coins: coins,
        wait: longer ? {'final_in_seconds': fin, 'usual_in_seconds': f['usual_in_seconds'], 'waiting_for': f['waiting_for']} : prev,
      );
    }
  }

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

  /// The firm terms of [fs] once all are in, or at [soft] (ms, wall clock) when one is in hand, or
  /// at [hard] whatever is in: the sources' own deadline is [soft], and what the wallet reads of an
  /// answer that came in time may run to [hard] while nothing else is in hand. One that comes later
  /// is let go of ([drop]), so the offer it holds frees the maker's coins. The web wallet's `firmsBy`.
  Future<List<Candidate?>> _firmsBy(List<Future<Candidate?>> fs, int soft, int hard) {
    final out = Completer<List<Candidate?>>();
    final got = <Candidate?>[];
    var left = fs.length;
    Timer? softTimer, hardTimer;
    void finish() {
      if (out.isCompleted) return;
      softTimer?.cancel();
      hardTimer?.cancel();
      out.complete(List.of(got));
    }

    if (fs.isEmpty) return Future.value(const []);
    for (final f in fs) {
      f.then<Candidate?>((c) => c, onError: (Object e) {
        d.log('[user trade] firm: $e');
        return null;
      }).then((c) {
        left--;
        if (out.isCompleted) {
          if (c != null) {
            d.log('[user trade] a source answered after the quote, let go: ${c.source}');
            drop(c);
          }
          return;
        }
        if (c != null) got.add(c);
        if (left == 0 || (c != null && DateTime.now().millisecondsSinceEpoch >= soft)) finish();
      });
    }
    int ms(int t) => math.max(0, t - DateTime.now().millisecondsSinceEpoch);
    softTimer = Timer(Duration(milliseconds: ms(soft)), () {
      if (got.isNotEmpty) finish();
    });
    hardTimer = Timer(Duration(milliseconds: ms(hard)), finish);
    return out.future;
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
  /// the asking (the BTC desk alone, [kBtcOnlyFirmMs]); a late answer is let go of. The web wallet's
  /// `quote`.
  Future<QuoteResult> quote({required String pay, required String receive, required BigInt amount}) async {
    var q = await _quote(pay: pay, receive: receive, amount: amount);
    if (!q.ok && q.why == 'settle-first') q = await _waitAndGo(q, pay: pay, receive: receive, amount: amount);
    // A price paid with BTC that nobody offers now, while such a purchase is under way: said as that,
    // never "it takes a moment" for as long as it lasts.
    if (!q.ok && pay == kUserBtc && const ['not-offered', 'no-firm-offer'].contains(q.why) && await _btcBuyOpen()) {
      return QuoteResult.no('btc-ahead');
    }
    return q;
  }

  /// A quote whose coins wait only for a round (`settle-first`) is answered with a ticket the person
  /// can accept now: the book's price for the amount ([Ticket.about]), the least it goes for
  /// ([kSettleSlackBp] under it, after the fees last seen and the refresh's fee), and the wait the
  /// library's refusal gave. Asking moves and commits nothing: no coin is given to a round until the
  /// person accepts ([confirm] writes a trade that waits for the coins, has them settled, is priced
  /// again once they are through, and goes by itself at that price or better, or comes back). The
  /// refresh's fee, where the operator charges one, is the library's read-only `quote` of those
  /// coins. The web wallet's waitAndGo.
  Future<QuoteResult> _waitAndGo(QuoteResult q, {required String pay, required String receive, required BigInt amount}) async {
    var refresh = BigInt.zero;
    try {
      final coins = ((await _run('coins')) as List? ?? const []).whereType<Map>().toList();
      final live = {for (final c in coins) if (c['state'] == 'live') '${c['leaf_id']}'};
      final named = q.coins.isNotEmpty ? q.coins : [for (final c in coins) if (c['asset'] == pay) '${c['leaf_id']}'];
      final leaves = named.where(live.contains).toList();
      if (leaves.isNotEmpty) {
        final r = (await _run('quote', {'leaves': leaves, 'max_fee_ppm': kMaxFeePpm})) as Map?;
        for (final c in ((r?['coins'] as List?) ?? const []).whereType<Map>()) {
          refresh += _big(c['fee']);
        }
      }
    } catch (e) {
      d.log('[user trade] the refresh\'s fee: $e');
    }
    final fees = (_marginsSeen[pay] ?? BigInt.zero) + refresh;
    final e = await estimate(pay: pay, receive: receive, payAtoms: fees > BigInt.zero && fees < amount ? amount - fees : amount);
    // Nobody offers the pair now: said so, as for any trade.
    if (!e.ok && const ['not-listed', 'too-small', 'not-offered'].contains(e.why)) return QuoteResult.no(e.why, again: e.again);
    // No price to show before the round: said in the words of coins being made ready, and asked
    // again by the composer; nothing moved.
    if (!e.ok) return QuoteResult.no('readying', soon: soon);
    final about = e.receive!;
    final least = about - _ceilDiv(about * kSettleSlackBp, BigInt.from(10000));
    if (least <= BigInt.zero) return QuoteResult.no('too-small');
    final fb = nextFinalBy(null, q.wait, d.now());
    final feeList = [if (refresh > BigInt.zero) <String, dynamic>{'asset': pay, 'atoms': refresh}];
    final ticket = Ticket(
      payAsset: pay,
      receiveAsset: receive,
      amountIn: amount,
      amountOut: least,
      fees: feeList,
      source: 'settling',
      about: about,
      finalBy: fb?['finalBy'] as int?,
    );
    final entry = BookEntry(
        source: 'settling', id: 'settling', rateNum: BigInt.one, rateDen: BigInt.one, maxReceive: least, minReceive: BigInt.one, lot: BigInt.zero, raw: const {});
    return QuoteResult.ok(
      ticket,
      Candidate(source: 'settling', id: 'settling', entry: entry, receive: least, give: amount, fees: feeList, settle: {
        'coins': q.coins,
        'finalBy': fb?['finalBy'],
        'finalStep': fb?['step'],
        'settleMost': q.wait != null ? settleBound(q.wait!['final_in_seconds']) : null,
      }),
    );
  }

  /// Puts a settling trade's coins through the next round: the ones the library named, else every
  /// coin of the asset paid that waits for a round (the library gives up nothing twice). The one
  /// place the engine words the library's `settle_first`.
  Future<dynamic> _settleAsk(Map<String, dynamic> rec) {
    final coins = [for (final c in (rec['settleCoins'] as List?) ?? const []) '$c'];
    return _run('settle_first', coins.isNotEmpty ? {'coins': coins} : {'asset': (rec['ticket'] as Map)['payAsset']});
  }

  /// A confirmed trade whose coins are settled first: once through, priced again for the amount
  /// accepted and confirmed into the same record only at the price accepted or better; returned with
  /// words when it moved, or when it waited past its bound (`settleMost`, else [kSettleMostMs]). The
  /// web wallet's advanceSettling.
  Future<Map<String, dynamic>> _advanceSettling(Map<String, dynamic> rec) async {
    final since = ((rec['settleSince'] ?? rec['at']) as num?)?.toInt() ?? d.now();
    Future<Map<String, dynamic>> late() {
      rec['state'] = 'returned';
      rec['whyKind'] = 'late';
      rec['returnedAt'] = d.now();
      rec['error'] = 'settling first took too long';
      return _put(rec);
    }

    Map? v;
    try {
      v = (await _settleAsk(rec)) as Map?;
    } catch (e) {
      d.log('[user trade] settle_first: $e');
      if (RegExp('no command|unknown command', caseSensitive: false).hasMatch('$e')) {
        rec['state'] = 'failed';
        rec['error'] = '$e';
        return _put(rec);
      }
    }
    // The record as stored now: never written back over a state another follow moved it to.
    final stored = (await records()).where((r) => r['id'] == rec['id']).firstOrNull;
    if (stored == null || stored['state'] != 'settling') return stored ?? rec;
    // How long it may wait: what the library first said it takes, twice, with a margin, kept on the
    // record so a restart holds it to the same bound; and when it said it would be through.
    if (v != null && v['ready'] != true && v['final_in_seconds'] != null) {
      rec['settleMost'] ??= settleBound(v['final_in_seconds']);
      final prev = rec['finalBy'] != null ? {'finalBy': rec['finalBy'], 'step': rec['finalStep']} : null;
      final n = nextFinalBy(prev, v, d.now());
      rec['finalBy'] = n?['finalBy'];
      rec['finalStep'] = n?['step'];
      await _put(rec);
    }
    final upTo = (rec['settleMost'] as num?)?.toInt() ?? kSettleMostMs;
    final after = (rec['repriceAfter'] as num?)?.toInt();
    if (v == null || v['ready'] != true || (after != null && d.now() < after)) {
      if (d.now() - since > upTo) return late();
      unawaited(_syncShared());
      return rec;
    }
    await _syncShared();
    return _repriceWithin(rec, upTo, since);
  }

  /// Whether a purchase paid with BTC is under way and still to pay.
  Future<bool> _btcBuyOpen() async => (await records()).any((r) =>
      r['source'] == 'btc-gateway' &&
      r['ticket'] is Map &&
      (r['ticket'] as Map)['payAsset'] == kUserBtc &&
      !kEndedStates.contains(r['state']) &&
      r['preimage'] == null);

  Future<QuoteResult> _quote({required String pay, required String receive, required BigInt amount}) async {
    _tooOldFrom = null;
    _liveShort = false;
    _settleSeen = null;
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
      have = (await _spendableForQuote())[pay] ?? BigInt.zero;
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
    // Firm terms of the best [kFirmAtOnce], all asked at once, within the quote's time: an entry that cannot
    // be firmed, or that has not answered by then, is left out, and a late answer is let go of. When
    // none gives firm terms and there is time left, they are asked once more a moment later.
    // The next best [kFirmAtOnce] are asked in the second round when the first gave none; with no
    // more to ask, the first ones again a moment later.
    final ranked = ind.take(2 * kFirmAtOnce).toList();
    final btcOnly = ranked.isNotEmpty && ranked.every((x) => x.e.source == 'btc-gateway');
    final window = btcOnly ? (d.btcOnlyFirmMs ?? kBtcOnlyFirmMs) : d.quoteFirmMs;
    final w = math.max(window, d.quoteFirmMs);
    // Wall-clock time: the person's wait (d.now may be a test's stand-in clock), from the asking.
    final int until = DateTime.now().millisecondsSinceEpoch + w;
    final int readMs = d.quoteReadMs ?? kQuoteReadMs;
    final cands = <Candidate>[];
    for (var round = 0; round < 2 && cands.isEmpty; round++) {
      final next = ranked.skip(round * kFirmAtOnce).take(kFirmAtOnce).toList();
      final worth = next.isNotEmpty ? next : ranked.take(kFirmAtOnce).toList();
      if (round > 0) {
        final left = until - DateTime.now().millisecondsSinceEpoch;
        if (left < math.min(kFirmRetryMs + 2000, w ~/ 2)) break;
        if (next.isEmpty) await d.sleep(kFirmRetryMs);
      }
      final got = await _firmsBy([for (final x in worth) _firm(x.e, pay, receive, amount, have, until: until, hard: until + readMs)], until, until + readMs);
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
    // Nobody gave firm terms because what the wallet holds of the asset is not live now: it is being
    // made ready, never "nobody could confirm".
    // A source's check found what the trade needs waiting only for a round, or the wallet's coins of
    // the asset not live now (just received, being settled): settled first, then priced again and
    // traded, never "nobody could confirm".
    final settleSeen = _settleSeen;
    if (best == null && (settleSeen != null || _liveShort) && pay != kUserBtc) {
      return QuoteResult.no('settle-first', coins: settleSeen?.coins ?? const [], wait: settleSeen?.wait);
    }
    if (best == null) {
      return QuoteResult.no(es.isEmpty ? 'not-offered' : (ind.isNotEmpty ? 'no-firm-offer' : 'too-small'), again: es.isEmpty && offeredAgain(pay, receive));
    }
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
  ///
  /// [prior]: a trade priced again ('repricing') goes on in its own record, so it is never made twice;
  /// what it paid already ([paidAlready]) is counted in what it pays and in its fees.
  Future<Map<String, dynamic>> confirm(Candidate c, Ticket t, {void Function(String id)? started, Map<String, dynamic>? prior}) async {
    // What the wallet can pay changes with this trade: the next quote reads it afresh.
    _holdings = null;
    final id = prior != null ? '${prior['id']}' : '${d.now()}-${d.now().hashCode.toRadixString(16)}${(await records()).length}';
    final tj = t.toJson();
    // A ticket accepted while what it pays waits for a round: the trade is written waiting for those
    // coins, bound to the least the ticket names, and goes by itself once they are through
    // ([_advanceSettling]). Nothing is signed to anyone until then.
    if (c.source == 'settling') {
      final st = c.settle ?? const {};
      final rec = await _put({
        'id': id,
        'at': d.now(),
        'source': 'settling',
        'state': 'settling',
        'ticket': tj,
        'accepted': tj,
        'settledFirst': true,
        'settleCoins': st['coins'] ?? const [],
        'settleSince': d.now(),
        'finalBy': st['finalBy'],
        'finalStep': st['finalStep'],
        if (st['settleMost'] != null) 'settleMost': st['settleMost'],
      });
      started?.call(id);
      unawaited(_settleAsk(rec).then((_) {}, onError: (Object e) => d.log('[user trade] settle_first: $e')));
      return rec;
    }
    final cf = prior != null ? paidAlready(prior) : BigInt.zero;
    if (cf > BigInt.zero) {
      tj['amountIn'] = '${t.amountIn + cf}';
      tj['fees'] = [...tj['fees'] as List, {'asset': t.payAsset, 'atoms': '$cf'}];
    }
    _confirmingNow.add(id);
    final Map<String, dynamic> rec;
    try {
      rec = await _put({
        'id': id,
        'at': prior?['at'] ?? d.now(),
        'source': c.source,
        'state': 'confirming',
        'ticket': tj,
        if (prior != null) 'accepted': prior['accepted'] ?? prior['ticket'],
        if (prior != null && (prior['state'] == 'settling' || prior['settledFirst'] == true)) 'settledFirst': true,
        if (prior?['settleSince'] != null) 'settleSince': prior!['settleSince'],
        if (prior?['settleMost'] != null) 'settleMost': prior!['settleMost'],
        if (prior?['gave'] != null) 'gave': prior!['gave'],
        if (prior?['cancelFees'] != null) 'cancelFees': prior!['cancelFees'],
      });
    } catch (_) {
      _confirmingNow.remove(id);
      rethrow;
    }
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
        await _handAccept(rec);
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
      // What it pays waits only for a round (the library's `settle_first`, or its coins of the asset
      // not live yet: just received, still arriving): nothing moved. The trade is kept, with the
      // price the person accepted as its bound, while those coins go through the next round; then it
      // is priced again and goes ahead by itself ([_advanceSettling]), or comes back with words. The
      // same when the operator refused the step for coins too many payments from a round
      // (`depth_limit`): a round cures it. The offer is let go of now. Never a failure.
      final kind = refusalKind(e), code = refusalCode(e);
      final payAsset = '${(rec['ticket'] as Map)['payAsset']}';
      final deep = code == 'depth_limit' || RegExp(r'\(\d{3} depth_limit\)').hasMatch('$e');
      // A round the payment waited for inside the wallet's library that did not end in time (its own
      // round, or the one freeing planned coins) is the same wait: the trade keeps waiting for it.
      final notLive = payAsset != kUserBtc &&
          RegExp(r" in live coins|own round did not end in time|next round did not free the coins").hasMatch('$e');
      if (rec['state'] == 'confirming' && (kind == 'settle_first' || code == 'settle_gave_up' || deep || notLive)) {
        drop(c);
        final f = kind == 'settle_first' ? refusalFields(e) : const <String, dynamic>{};
        rec['state'] = 'settling';
        rec['settleCoins'] = [for (final x in (f['coins'] as List?) ?? const []) '$x'];
        rec['settleSince'] ??= d.now();
        rec['accepted'] ??= rec['ticket'];
        rec['error'] = null;
        final fb = nextFinalBy(null, f, d.now());
        if (fb != null) {
          rec['finalBy'] = fb['finalBy'];
          rec['finalStep'] = fb['step'];
        }
        if (f['final_in_seconds'] != null) rec['settleMost'] ??= settleBound(f['final_in_seconds']);
        d.log('[user trade] what it pays settles first; the trade goes once it is through: ${rec['id']}');
        final put = await _put(rec);
        unawaited(_settleAsk(rec).then((_) {}, onError: (Object x) => d.log('[user trade] settle_first: $x')));
        return put;
      }
      // A step refused, before anything was signed to the other side, because a coin of the wallet's
      // it paid from is spent elsewhere (another device of the wallet gave it to a round): the library
      // has caught up and holds what replaced it, so the trade is priced again into the same record
      // under what was accepted, as a gone offer is ([_advanceGone]).
      if (rec['state'] == 'confirming' &&
          isRefusal(e) &&
          (spentElsewhere(e, rec['before'] as List?) || orderTaken(e)) &&
          const ['leaf-resting', 'covenant-round', 'leaf-maker'].contains(c.source)) {
        drop(c);
        rec['gave'] = [
          ...((rec['gave'] as List?) ?? const []),
          {if (rec['order'] != null) 'order': rec['order'] else 'swap': rec['swap'], 'why': _short('$e'), 'whose': 'taker'},
        ];
        d.log('[user trade] a coin it paid from was spent elsewhere; pricing again: ${rec['id']}');
        if ((rec['gave'] as List).length >= kGoneMost) {
          rec['state'] = 'returned';
          rec['error'] = 'the offers were gone ${(rec['gave'] as List).length} times';
          if (paidAlready(rec) > BigInt.zero) {
            rec['feesPaid'] = [
              {'asset': (rec['ticket'] as Map)['payAsset'], 'atoms': '${paidAlready(rec)}'},
            ];
          }
          return _put(rec);
        }
        rec['state'] = 'repricing';
        rec['repriceSince'] = d.now();
        rec['accepted'] ??= rec['ticket'];
        rec['error'] = null;
        return _put(rec);
      }
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
  /// It moves on from its record as stored when it starts, never from a copy read before another
  /// follow moved it on, so a copy that is behind is never written back over it.
  Future<Map<String, dynamic>> advance(Map<String, dynamic> rec) {
    final id = '${rec['id']}';
    // The callback returns nothing: returning the removed future would wait on itself.
    return _advancing[id] ??= () async {
      final cur = (await records()).where((r) => '${r['id']}' == id).firstOrNull ?? rec;
      return _advance(cur);
    }().whenComplete(() {
      _advancing.remove(id);
    });
  }

  Future<Map<String, dynamic>> _advance(Map<String, dynamic> rec) async {
    if (kEndedStates.contains(rec['state'])) return rec;
    // Its step is being taken here now: nothing to look for yet.
    if (_confirmingNow.contains('${rec['id']}')) return rec;
    // Priced again after its other side's offer was gone: it goes ahead in the same record only at
    // the price accepted or better.
    if (rec['state'] == 'settling') return _advanceSettling(rec);
    if (rec['state'] == 'repricing') {
      return _repriceWithin(rec, kRepriceMostMs, ((rec['repriceSince'] ?? rec['at']) as num?)?.toInt() ?? d.now());
    }
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
    await _syncShared();
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
      // The maker has not completed it: the acceptance is handed over again (it may have missed it),
      // and after the wait the coins are taken back. An answer that the offer is gone (the operator
      // refused the maker's completion) cannot change: the trade is priced again at once.
      if (rec['gone'] != null) return _advanceGone(rec);
      if (rec['makerDone'] != true) {
        await _handAccept(rec);
        if (rec['gone'] != null) return _advanceGone(rec);
      }
      // A maker that says the swap is done completed it: what it pays the wallet is read from the
      // mailbox now, and the coins signed into it are not taken back while it is waited on
      // ([kMakerCompleteMs] more); a maker that says done and never completes holds no price of the
      // person's for good.
      final doneAt = (rec['makerDoneAt'] as num?)?.toInt();
      if (rec['makerDone'] == true && doneAt != null && d.now() - doneAt <= kMakerCompleteMs) {
        try {
          await _run('mailbox');
        } catch (e) {
          d.log('[user trade] mailbox: $e');
        }
        final s2 = ((await _run('swaps')) as List? ?? const []).cast<Map>().where((x) => x['swap'] == rec['swap']).firstOrNull;
        rec['swapState'] = s2?['state'];
        if (s2?['state'] != 'done') return _put(rec);
        if (await _settleStep(rec)) {
          rec['state'] = 'settled';
          rec['settledAt'] = d.now();
        }
        return _put(rec);
      }
      if (d.now() - ((rec['sentAt'] as num?)?.toInt() ?? 0) > kMakerCompleteMs) {
        try {
          final held = ((await _run('coins')) as List? ?? const []).cast<Map>().where((c) => c['state'] == 'offered').toList();
          final c = (await _run('swap_cancel', {'swap': rec['swap']})) as Map;
          rec['awaiting'] = c['cancelled'] != true && c['done'] != true && c['unknown'] == true;
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

  static String _short(String m) => m.length > 300 ? m.substring(0, 300) : m;

  /// Hands a maker the wallet's acceptance of its offer. A maker that answers done completed it
  /// (`makerDone`); one whose completion the operator refused answers that the offer is gone
  /// (`gone`, with the offer it made in its place, if any), and the trade is priced again.
  Future<void> _handAccept(Map<String, dynamic> rec) async {
    try {
      final a = await d.fetchJson('${rec['maker']}/v1/accept', post: {'swap': rec['swap'], 'accept': rec['accept']});
      if (a['state'] == 'done') {
        rec['makerDone'] = true;
        rec['makerDoneAt'] ??= d.now();
      }
    } catch (e) {
      d.log('[user trade] the maker did not take the acceptance yet: $e');
      if (e is MakerError && e.body['gone'] != null) rec['gone'] = Map<String, dynamic>.from(e.body);
    }
  }

  /// The offer a maker made in place of one whose completion the operator refused: taken as that
  /// maker's firm offer at the next price of the pair, rather than asking again.
  final _madeAgain = <String, Map<String, dynamic>>{};

  /// A trade whose maker answered that its offer is gone: the operator refused the completion, so the
  /// acceptance cannot complete there. Its coins are taken back at once (the library's cancel: a coin
  /// of the wallet's given up elsewhere, by a second device, is found then, and the acceptance
  /// cancelled with nothing respent), then the trade is priced again for what was accepted and goes
  /// ahead in the same record only at that price or better ([_repriceWithin]); the offer the maker
  /// made in its place is taken first when it is there. Offers gone [kGoneMost] times over: the trade
  /// is returned. A cancel that cannot be made yet is asked again at the next advance; one that finds
  /// the swap done goes on as done. The web wallet's advanceGone.
  Future<Map<String, dynamic>> _advanceGone(Map<String, dynamic> rec) async {
    final gone = Map<String, dynamic>.from(rec['gone'] as Map);
    final pay = '${(rec['ticket'] as Map)['payAsset']}';
    final held = ((await _run('coins')) as List? ?? const []).cast<Map>().where((c) => c['state'] == 'offered' || c['state'] == 'sending').toList();
    Map c;
    try {
      c = (await _run('swap_cancel', {'swap': rec['swap']})) as Map;
    } catch (e) {
      d.log('[user trade] swap_cancel: $e');
      return _put(rec);
    }
    if (c['done'] == true) {
      rec['gone'] = null;
      rec['awaiting'] = false;
      return _put(rec);
    }
    if (c['cancelled'] != true) {
      // Not known yet whether the coins came back: asked again at the next advance.
      rec['awaiting'] = c['unknown'] == true;
      d.log('[user trade] the acceptance stands for now: ${c['note'] ?? c['error']}');
      return _put(rec);
    }
    rec['awaiting'] = false;
    final respent = {...((c['respent'] as List?) ?? const []).map((e) => '$e')};
    if (respent.isNotEmpty) {
      final was = held.where((x) => respent.contains('${x['leaf_id']}')).fold<BigInt>(BigInt.zero, (n, x) => n + _big(x['value']));
      final before = {...((rec['before'] as List?) ?? const []).map((e) => '$e')};
      final got = ((await _run('coins')) as List? ?? const [])
          .cast<Map>()
          .where((x) => x['state'] == 'live' && !before.contains('${x['leaf_id']}') && x['asset'] == pay)
          .fold<BigInt>(BigInt.zero, (n, x) => n + _big(x['value']));
      if (was > got) rec['cancelFees'] = '${_big(rec['cancelFees']) + was - got}';
    }
    d.log('[user trade] the maker\'s offer is gone; pricing again: ${rec['id']}');
    rec['gave'] = [
      ...((rec['gave'] as List?) ?? const []),
      {'swap': rec['swap'], 'why': _short('${gone['error'] ?? ''}'), 'whose': gone['whose']},
    ];
    final offer = gone['offer'] is Map ? Map<String, dynamic>.from(gone['offer'] as Map) : null;
    if ((rec['gave'] as List).length >= kGoneMost) {
      if (offer?['swap'] != null) release('${rec['maker']}', '${offer!['swap']}');
      rec['gone'] = null;
      rec['state'] = 'returned';
      rec['returnedAt'] = d.now();
      rec['error'] = 'the makers\' offers were gone ${(rec['gave'] as List).length} times';
      if (paidAlready(rec) > BigInt.zero) {
        rec['feesPaid'] = [
          {'asset': pay, 'atoms': '${paidAlready(rec)}'},
        ];
      }
      return _put(rec);
    }
    if (offer?['swap'] != null && rec['maker'] != null) {
      _madeAgain['${rec['maker']}'] = {...offer!, 'give_asset': (rec['ticket'] as Map)['receiveAsset'], 'want_asset': pay};
    }
    rec['gone'] = null;
    rec['state'] = 'repricing';
    rec['repriceSince'] = d.now();
    rec['accepted'] ??= rec['ticket'];
    await _put(rec);
    return _repriceWithin(rec, kRepriceMostMs, rec['repriceSince'] as int);
  }

  /// Prices a trade again for the amount accepted (`accepted`), and confirms it into the same record
  /// only at the price accepted or better (no less received, no more paid, and no less received for
  /// what is paid); returns it with words when the price moved, or once [mostMs] have passed since
  /// [since] with no price. The record as stored is read again before it is written: another follow
  /// may have moved it on meanwhile. The web wallet's repriceWithin.
  Future<Map<String, dynamic>> _repriceWithin(Map<String, dynamic> rec, int mostMs, int since) async {
    final t = rec['ticket'] as Map;
    final accepted = (rec['accepted'] ?? t) as Map;
    final pay = '${t['payAsset']}', receive = '${t['receiveAsset']}';
    final state = rec['state'];
    // Priced for at most one received atom's price above what the ticket pays, so the maker's
    // rounding gives the same ticket at the same price.
    final aIn = _big(accepted['amountIn']), aOut = _big(accepted['amountOut']);
    final step = aOut > BigInt.zero ? _ceilDiv(aIn, aOut) : BigInt.zero;
    final upTo = aIn + step;
    bool within(QuoteResult q) =>
        q.ok && q.ticket!.amountOut >= aOut && q.ticket!.amountIn <= upTo && q.ticket!.amountOut * aIn >= aOut * q.ticket!.amountIn;
    var q = await _quote(pay: pay, receive: receive, amount: upTo);
    // The maker's offer made in place of a gone one, if this price did not take it: let go of.
    final left = rec['maker'] != null ? _madeAgain.remove('${rec['maker']}') : null;
    if (left != null) release('${rec['maker']}', '${left['swap']}');
    Future<Map<String, dynamic>> back() {
      if (paidAlready(rec) > BigInt.zero) {
        rec['feesPaid'] = [
          {'asset': pay, 'atoms': '${paidAlready(rec)}'},
        ];
      }
      rec['returnedAt'] = d.now();
      return _put(rec);
    }

    // A ticket the maker's depth capped, whose next atom costs more than the ticket's price: priced
    // once more at exactly what the ticket paid.
    if (q.ok && !within(q) && upTo > aIn) {
      drop(q.choice);
      q = await _quote(pay: pay, receive: receive, amount: aIn);
    }
    final stored = (await records()).where((r) => r['id'] == rec['id']).firstOrNull;
    if (stored == null || stored['state'] != state) {
      if (q.ok) drop(q.choice);
      return stored ?? rec;
    }
    if (!q.ok && q.why == 'settle-first') {
      // What it pays waits for a round (again): settled first, its own wait the trade's time, and the
      // other side asked again only once that wait is through; past the bound, returned.
      if (state == 'settling' && d.now() - since > mostMs) {
        rec['state'] = 'returned';
        rec['whyKind'] = 'late';
        rec['error'] = 'settling first took too long';
        return back();
      }
      rec['settleCoins'] = q.coins;
      if (state != 'settling') {
        rec['state'] = 'settling';
        rec['settleSince'] = d.now();
        unawaited(_settleAsk(rec).then((_) {}, onError: (Object e) => d.log('[user trade] settle_first: $e')));
      }
      final w = q.wait;
      if (w != null) {
        final prev = rec['finalBy'] != null ? {'finalBy': rec['finalBy'], 'step': rec['finalStep']} : null;
        final n = nextFinalBy(prev, w, d.now());
        if (n != null) {
          rec['finalBy'] = n['finalBy'];
          rec['finalStep'] = n['step'];
        }
      }
      final secs = w == null ? null : (w['usual_in_seconds'] ?? w['final_in_seconds']) as num?;
      rec['repriceAfter'] = d.now() + math.max(kRepriceAgainMs, ((secs ?? 0) * 1000).round());
      return _put(rec);
    }
    if (!q.ok) {
      // Nobody offers it this moment: a maker quotes nothing while it reads its coins again after a
      // trade, so within the time given it is asked again at the next advance.
      if (d.now() - since <= mostMs && const ['wallet-busy', 'no-firm-offer', 'not-offered', 'opening'].contains(q.why)) return _put(rec);
      // What it was to pay is no longer the wallet's: said so, not as a price that moved.
      rec['state'] = 'returned';
      rec['whyKind'] = q.why == 'no-funds' ? 'gone' : 'moved';
      rec['error'] = 'no price within the bound: ${q.why}';
      return back();
    }
    if (!within(q)) {
      drop(q.choice);
      rec['state'] = 'returned';
      rec['whyKind'] = 'moved';
      rec['error'] = 'the price moved past the bound accepted';
      return back();
    }
    d.log('[user trade] priced again; going ahead at the price accepted: ${rec['id']}');
    try {
      return await confirm(q.choice!, q.ticket!, prior: stored);
    } catch (e) {
      d.log('[user trade] going ahead again: $e');
      return (await records()).where((r) => r['id'] == rec['id']).firstOrNull ?? rec;
    }
  }

  /// The operator's `info`, read at most every [kInfoMs], or null.
  Future<Map?> _operatorInfo() async {
    if (_info == null || d.now() - _infoAt > kInfoMs) {
      try {
        _info = (await _run('info')) as Map;
        _infoAt = d.now();
      } catch (e) {
        d.log('[user trade] info: $e');
        return _info;
      }
    }
    return _info;
  }

  /// The coins a trade brings, or leaves as change on a reassignment, settled in the operator's
  /// next round at no more than the fees its ticket showed. True once every such round is final.
  /// A coin the library has already given up to a round of its own (its refresh of received coins
  /// takes a coin as soon as it lands) is settled by that round, followed under its own id; one
  /// paid on out of round leaves nothing of the trade to settle.
  Future<bool> _settleStep(Map<String, dynamic> rec) async {
    final targets = ((rec['settleTargets'] as List?) ?? const []).cast<Map>();
    if (targets.isEmpty) return true;
    if (rec['settle'] == null) {
      final before = {...((rec['before'] as List?) ?? const []).map((e) => '$e')};
      final all = ((await _run('coins')) as List? ?? const [])
          .cast<Map>()
          .where((c) => !before.contains('${c['leaf_id']}'))
          .toList();
      final coins = <Map>[];
      final targetOf = <String, Map>{};
      final taken = <String, String>{};
      final used = <Map>{};
      for (final t in targets) {
        // A target that names its coin is that coin; otherwise the coin of its asset and value.
        final id = t['leaf_id'];
        final c = id != null
            ? all.where((x) => x['leaf_id'] == id).firstOrNull
            : all
                .where((x) =>
                    !used.contains(x) &&
                    x['asset'] == t['asset'] &&
                    '${x['value']}' == '${t['value']}' &&
                    (x['state'] == 'live' || _roundOf(x) != null))
                .firstOrNull;
        if (c != null) used.add(c);
        final pid = _roundOf(c);
        if (pid != null) {
          taken['${c!['leaf_id']}'] = pid;
          continue;
        }
        if (c != null && c['state'] == 'live') {
          coins.add(c);
          targetOf['${c['leaf_id']}'] = t;
          continue;
        }
        if (c != null && id != null && (c['state'] == 'spent' || c['state'] == 'given')) continue;
        final why = id != null ? 'coin $id is not live yet' : 'no live coin of ${t['value']} of ${t['asset']} yet';
        if (rec['settleWhy'] != why) {
          rec['settleWhy'] = why;
          d.log('[user trade] settle waits: $why');
        }
        return false;
      }
      if (coins.isEmpty && taken.isEmpty) return true;
      final ids = [for (final c in coins) c['leaf_id']];
      final parts = <String>[];
      if (ids.isNotEmpty) {
        Map q;
        try {
          q = (await _run('quote', {'leaves': ids, 'max_fee_ppm': kMaxFeePpm})) as Map;
        } catch (e) {
          d.log('[user trade] settle quote: $e');
          return false;
        }
        for (final qc in ((q['coins'] as List?) ?? const []).cast<Map>()) {
          final t = targetOf['${qc['leaf_id']}'];
          if (t == null || _big(qc['fee']) > _big(t['fee'])) {
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
        final ok = ((r['participations'] as List?) ?? const [])
            .cast<Map>()
            .where((p) => p['error'] == null && p['participation'] != null)
            .toList();
        if (ok.isEmpty) return false;
        parts.addAll([for (final p in ok) '${p['participation']}']);
      }
      rec['settle'] = {
        'coins': [...ids, ...taken.keys],
        'participations': {...parts, ...taken.values}.toList(),
      };
      // The wait the row states ([tradeStateWord]): the wallet's figure for a round of this operator.
      if (rec['settleMin'] == null) {
        rec['settleMin'] = settleMinutesOf(await _operatorInfo());
        rec['settleSince'] = d.now();
      }
      await _put(rec);
      return false;
    }
    final ps = [for (final id in ((rec['settle'] as Map)['participations'] as List)) await _participation('$id')];
    rec['settleState'] = [for (final p in ps) p?['state']];
    if (ps.every(_releasedLive)) return true;
    if (ps.any((p) => p != null && ['void', 'expired', 'refused', 'lost'].contains(p['state']))) rec['settle'] = null;
    return false;
  }

  /// The participation of the wallet's own that took coin [c]: named on a coin given up to it
  /// (`refresh_waiting`, or the library's note `participation <id>`), and on one it spent once
  /// released (`spent_by`).
  static String? _roundOf(Map? c) {
    if (c == null) return null;
    String? named(Object? v) => RegExp(r'^participation ([0-9a-f]{64})$').firstMatch('${v ?? ''}')?.group(1);
    if (c['state'] == 'given') return (c['refresh_waiting'] as String?) ?? named(c['note']);
    if (c['state'] == 'spent') return named(c['spent_by']);
    return null;
  }

  /// The assets the drill admitted against [pay] on this chain.
  Future<List<String>> admittedReceivesFor(String pay) async {
    final ad = await d.admitted();
    return admittedReceives(ad.pairs, ad.genesis, pay);
  }

  Future<List<Map<String, dynamic>>> resume() async {
    final out = <Map<String, dynamic>>[];
    for (final r in await records()) {
      if (kEndedStates.contains(r['state'])) continue;
      try {
        out.add(await advance(r));
      } catch (e) {
        d.log('[user trade] resume ${r['id']}: $e');
      }
    }
    return out;
  }
}
