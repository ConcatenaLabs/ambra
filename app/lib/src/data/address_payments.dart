// A payment to an address out of the tree (the leaf library's `offboard`) is made in the operator's
// next settlement, which the paying wallet signs its part of as it is made: a wallet closed before
// then makes nothing, and its coins stay its own. So each such payment is written down with the
// library's id for it, followed to its end in the library's `offboards`, and only then said to be
// sent; one that ended unmade, or was taken back, is said once (the web wallet's default-arca.js
// offboardStage / offboardEnds, and its instant-history.js records; sequentia-web-wallet
// docs/DEFAULT_MODE.md, Send).

import 'default_words.dart';

/// Where a payment stands, from its state in the library's `offboards` (arca
/// bark/src/arca/offboard.rs): `waiting` and `in_round` are 'pending' (a wallet closed now makes
/// nothing); `unlocking` and `paid` are 'made'; `not_made` and `reclaimed` are ends the person is
/// told of. Anything else is 'pending', never 'made'.
String offboardStage(Object? state) {
  switch ('$state') {
    case 'unlocking':
    case 'paid':
      return 'made';
    case 'not_made':
      return 'not_made';
    case 'reclaimed':
      return 'reclaimed';
    default:
      return 'pending';
  }
}

/// Whether [stage] is an end the person is told of.
bool offboardEnded(Object? stage) => stage == 'not_made' || stage == 'reclaimed';

/// The payments to an address this wallet asked for ([asked], each `{offboard, stage?}`), read
/// against the library's `offboards` answer: each one's stage now, and those that have just ended
/// unmade or taken back (the library's entry with `stage`). A record the library does not list
/// keeps its stage; one already at an end is never news again; made is never unsaid.
({Map<String, String> stages, List<Map> news}) offboardEnds(List<Map> asked, Object? offboards) {
  final byId = <String, Map>{
    for (final o in (offboards is List ? offboards : const []).whereType<Map>())
      if (o['offboard'] != null) '${o['offboard']}': o
  };
  final stages = <String, String>{};
  final news = <Map>[];
  for (final r in asked) {
    final id = r['offboard'];
    if (id == null) continue;
    final was = '${r['stage'] ?? 'pending'}';
    final o = byId['$id'];
    if (o == null || offboardEnded(was)) {
      stages['$id'] = was;
      continue;
    }
    var now = offboardStage(o['state']);
    if (was == 'made' && now == 'pending') now = 'made';
    stages['$id'] = now;
    if (now != was && offboardEnded(now)) news.add({...o, 'stage': now});
  }
  return (stages: stages, news: news);
}

/// How a payment's address is named in what the wallet says of it: its start and its end.
String shortAddress(Object? address) {
  final a = '${address ?? ''}';
  return a.length > 22 ? '${a.substring(0, 14)}…${a.substring(a.length - 4)}' : a;
}

/// The one sentence for a payment that reached an end other than made.
String offboardNewsText(String? stage, String? address, String amount, String ticker) => stage == 'reclaimed'
    ? DefaultWords.notArrived(amount, ticker, shortAddress(address))
    : DefaultWords.notMade(amount, ticker, shortAddress(address));

/// How long a payment to an address is followed from Send while its screen is open.
const kOffboardFollow = Duration(minutes: 15);

/// Whether [amount] of a payment to an address that the tree cannot pay now would be covered once
/// what is arriving there comes in ([spendable] now, [comingBack]: arriving less what payments still
/// on their way give up): the payment is then refused as still arriving, never as not enough.
bool stillArrivingCovers(BigInt amount, BigInt spendable, BigInt comingBack) =>
    comingBack > BigInt.zero && amount > spendable && amount <= spendable + comingBack;
