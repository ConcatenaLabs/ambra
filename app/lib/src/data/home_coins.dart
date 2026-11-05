/// Every coin home, with the operator gone: the web wallet's `default-arca.js` (`homeHours`,
/// `homeSummary`, `homeOnWay`, `homeCoins`, `unreachableOf`, `noMoreThan`, `homeQuote`, `homeTake`,
/// `homeUnderWay`) in Dart, the same names and rules; change them together. Nothing here asks the
/// operator, and nothing is decided here: which coin can go, its path, its fees and its claim are
/// the leaf library's (`exit_quote`, `exit`, `channel_exit`). Nothing here prices anything: the fees
/// are the quotes'. Its words are default mode's (`DefaultWords.home*`, the web wallet's
/// docs/DEFAULT_MODE.md, "When the service does not answer").
library;

BigInt _big(Object? v) {
  if (v is BigInt) return v;
  if (v is int) return BigInt.from(v);
  return BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
}

/// The hours a wait of [seconds] reads as, rounded up; 0 for none.
int homeHours(num? seconds) {
  final n = seconds?.toDouble() ?? 0;
  return n.isFinite && n > 0 ? (n / 3600).ceil() : 0;
}

/// A coin as the home functions carry it.
class HomeCoin {
  const HomeCoin(this.leafId, this.asset, this.value);
  final String leafId, asset, value;
  static HomeCoin of(Map c) => HomeCoin('${c['leaf_id']}', '${c['asset']}', '${c['value'] ?? ''}');
}

class HomeQuoted {
  const HomeQuoted(this.coin, this.quote);
  final HomeCoin coin;
  final Map quote;
}

class HomeRefused {
  const HomeRefused(this.coin, this.error);
  final HomeCoin coin;
  final Object error;
}

/// homeQuote's answer: each coin's exit quoted, the channel leaves set apart, and what the
/// library refused.
class HomeQuote {
  final quotes = <HomeQuoted>[];
  final channels = <HomeCoin>[];
  final refused = <HomeRefused>[];
}

class HomeFee {
  const HomeFee(this.asset, this.atoms);
  final String asset;
  final BigInt atoms;
}

class HomeAsset {
  HomeAsset(this.asset);
  final String asset;
  BigInt atoms = BigInt.zero;
  final fees = <String, BigInt>{};
  List<HomeFee> get feeList => [for (final e in fees.entries) HomeFee(e.key, e.value)];
}

class HomeSummary {
  HomeSummary(this.assets, this.refused, this.delaySeconds, this.count);
  final List<HomeAsset> assets;
  final List<HomeFee> refused; // asset and atoms that cannot go now
  final num delaySeconds;
  final int count;
}

/// What taking every coin home would move and cost, by asset, from the library's quotes: each
/// coin's value, and the fees the wallet pays (the claim's, and those of the steps a coin of the
/// wallet's pays; steps paid from their own reserve cost the holder nothing), each in its own
/// asset; the longest exit delay; a channel's value with no fee known before it goes; and what the
/// library refused. Atoms throughout.
HomeSummary homeSummary(HomeQuote? q) {
  final by = <String, HomeAsset>{};
  HomeAsset row(String a) => by.putIfAbsent(a, () => HomeAsset(a));
  num delay = 0;
  var count = 0;
  for (final x in q?.quotes ?? const <HomeQuoted>[]) {
    final r = row(x.coin.asset);
    r.atoms += _big(x.coin.value);
    count++;
    void fee(Object? f) {
      for (final y in f is List ? f : const []) {
        if (y is Map) r.fees['${y['asset']}'] = (r.fees['${y['asset']}'] ?? BigInt.zero) + _big(y['amount']);
      }
    }

    final steps = x.quote['steps'];
    for (final st in steps is List ? steps : const []) {
      if (st is Map && st['paid_by'] != 'its own reserve') fee(st['fee']);
    }
    final claim = x.quote['claim'];
    if (claim is Map && claim['error'] == null) fee(claim['fee']);
    final d = x.quote['exit_delay_seconds'];
    if (d is num && d > delay) delay = d;
  }
  for (final c in q?.channels ?? const <HomeCoin>[]) {
    row(c.asset).atoms += _big(c.value);
    count++;
  }
  final refused = <String, BigInt>{};
  for (final r in q?.refused ?? const <HomeRefused>[]) {
    refused[r.coin.asset] = (refused[r.coin.asset] ?? BigInt.zero) + _big(r.coin.value);
  }
  return HomeSummary(by.values.toList(), [for (final e in refused.entries) HomeFee(e.key, e.value)], delay, count);
}

/// One coin on its way home (homeUnderWay), with when it was sent and its delay where this wallet
/// sent it.
class HomeWay {
  const HomeWay(this.leafId, this.asset, this.value, this.at, this.delay);
  final String leafId, asset, value;
  final int? at; // ms since the epoch
  final num? delay; // seconds
}

class HomeOnWay {
  HomeOnWay(this.asset);
  final String asset;
  BigInt atoms = BigInt.zero;
  int hours = 0;
}

/// The coins on their way home, by asset, with the hours left before the last of each arrives,
/// at [nowMs].
List<HomeOnWay> homeOnWay(List<HomeWay> list, int nowMs) {
  final by = <String, HomeOnWay>{};
  for (final h in list) {
    final r = by.putIfAbsent(h.asset, () => HomeOnWay(h.asset));
    r.atoms += _big(h.value);
    final d = h.delay, at = h.at;
    if (d != null && d > 0 && at != null && at > 0) {
      final hrs = homeHours((at + d * 1000 - nowMs) / 1000);
      if (hrs > r.hours) r.hours = hrs;
    }
  }
  return by.values.toList();
}

/// The coin states the library still holds for the wallet, and of them those a holder can send
/// home: all but one already on its way out (`exiting`).
const kHomeFrom = ['pending', 'live', 'offered', 'sending', 'given', 'forfeited'];
List<Map> homeCoins(Object? coins) => [
      for (final c in coins is List ? coins : const [])
        if (c is Map && kHomeFrom.contains(c['state'])) c
    ];

/// Whether the operator cannot be reached, as the library last said.
class Unreachable {
  const Unreachable(this.why, this.note);
  final String why;
  final String? note;
}

/// A sync's `unreachable` (present only then), else an `info`'s (`server_info.unreachable`):
/// ([known] true, the value) where this answer says, the value null when the operator answered;
/// [known] false when this answer says nothing either way.
({bool known, Unreachable? value}) unreachableOf(Object? answer, String kind) {
  if (answer is! Map) return (known: false, value: null);
  if (kind == 'sync') {
    final u = answer['unreachable'];
    if (u == null || u == false) return (known: true, value: null);
    return (known: true, value: Unreachable(u is Map ? '${u['why'] ?? ''}' : '$u', u is Map && u['note'] != null ? '${u['note']}' : null));
  }
  final si = answer['server_info'];
  if (si is! Map) return (known: false, value: null);
  final u = si['unreachable'];
  return (known: true, value: u == null || u == false ? null : Unreachable('$u', null));
}

/// Whether the fees [now] ({asset: atoms}) are, in every asset, no more than [shown].
bool noMoreThan(Object? now, Object? shown) {
  final n = now is Map ? now : const {};
  final s = shown is Map ? shown : const {};
  return n.entries.every((e) => _big(e.value) <= _big(s[e.key] ?? 0));
}

typedef HomeRun = Future<dynamic> Function(String command, Map<String, dynamic> args);

/// Each coin's way home, quoted by the library: every coin [homeCoins] names, a channel leaf
/// ([channelIds]) set apart. Asks nothing of the operator.
Future<HomeQuote> homeQuote(HomeRun run, Object? coins, [Iterable<String> channelIds = const []]) async {
  final out = HomeQuote();
  final ch = channelIds.toSet();
  for (final c in homeCoins(coins)) {
    final coin = HomeCoin.of(c);
    if (ch.contains(coin.leafId)) {
      out.channels.add(coin);
      continue;
    }
    try {
      final q = await run('exit_quote', {'leaf_id': coin.leafId});
      out.quotes.add(HomeQuoted(coin, q is Map ? q : const {}));
    } catch (e) {
      out.refused.add(HomeRefused(coin, e));
    }
  }
  return out;
}

class HomeStarted {
  const HomeStarted(this.coin, this.value);
  final HomeCoin coin;
  final Object? value;
}

/// homeTake's answer: what went, what was refused, and what this wallet sent, by leaf, for its
/// words ({asset, value, at, delay}).
class HomeTaken {
  final started = <HomeStarted>[];
  final refused = <HomeRefused>[];
  final kept = <String, Map<String, dynamic>>{};
}

/// What [homeQuote] quoted, sent home: each coin's exit broadcast only on the fees its quote
/// showed (`shown`), a channel's by `channel_exit`. Coins of one tree share the first steps of
/// their way out: once one coin's exit has put them on the chain, the next coin's are fewer and its
/// fees lower than quoted, and the library refuses the fees shown; that coin is quoted again and
/// goes only for no more than the person was shown for it, in every asset.
Future<HomeTaken> homeTake(HomeRun run, HomeQuote q, {int Function()? now, void Function(String)? log}) async {
  final out = HomeTaken();
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  Future<dynamic> exitOn(HomeCoin coin, Map quote) {
    final args = <String, dynamic>{'leaf_id': coin.leafId, 'shown': quote['unroll'] ?? const {}};
    if (quote['fee_asset'] != null) args['fee_asset'] = quote['fee_asset'];
    return run('exit', args);
  }

  Future<void> go(HomeCoin coin, Future<dynamic> Function() f, num? delay) async {
    try {
      final v = await f();
      out.started.add(HomeStarted(coin, v));
      out.kept[coin.leafId] = {'asset': coin.asset, 'value': coin.value, 'at': clock(), 'delay': delay};
      final b = v is Map ? v['broadcast'] : null;
      final txids = [for (final x in b is List ? b : const []) if (x is Map) x['txid']];
      log?.call('[leaves] home: ${coin.leafId} ${v is Map ? v['state'] ?? '' : ''} ${txids.join(' ')}');
    } catch (e) {
      out.refused.add(HomeRefused(coin, e));
      log?.call('[leaves] home: ${coin.leafId} refused: $e');
    }
  }

  for (final x in q.quotes) {
    await go(x.coin, () async {
      try {
        return await exitOn(x.coin, x.quote);
      } catch (e) {
        if (!'$e'.contains('fees changed since they were shown')) rethrow;
        final again = await run('exit_quote', {'leaf_id': x.coin.leafId});
        if (again is! Map || !noMoreThan(again['unroll'], x.quote['unroll'])) rethrow;
        return await exitOn(x.coin, again);
      }
    }, x.quote['exit_delay_seconds'] is num ? x.quote['exit_delay_seconds'] as num : null);
  }
  for (final c in q.channels) {
    await go(c, () => run('channel_exit', {'leaf_id': c.leafId}), null);
  }
  return out;
}

/// The coins on their way home, as the library holds them (exiting, and not a coin a watchtower
/// took out while the wallet was away, which default mode does not speak of), each with when it
/// was sent and its delay where this wallet sent it ([kept], homeTake's). Those a person sent, and
/// while the operator cannot be reached ([unreachable]) every one; a coin the wallet takes home by
/// itself on its date while the operator answers is not said. [kept] comes back with what of it is
/// still on its way.
({List<HomeWay> list, Map<String, Map> kept}) homeUnderWay(Object? coins, Map<String, Map> kept, bool unreachable) {
  final list = <HomeWay>[];
  final all = coins is List ? coins : const [];
  for (final c in all) {
    if (c is! Map || c['state'] != 'exiting' || c['kept_safe'] == true) continue;
    final id = '${c['leaf_id']}';
    if (!kept.containsKey(id) && !unreachable) continue;
    final h = kept[id] ?? const {};
    list.add(HomeWay(id, '${c['asset']}', '${c['value'] ?? ''}', h['at'] is int ? h['at'] as int : null,
        h['delay'] is num ? h['delay'] as num : null));
  }
  final on = list.map((h) => h.leafId).toSet();
  final left = all.isEmpty
      ? kept
      : {
          for (final e in kept.entries)
            if (on.contains(e.key) || !all.any((c) => c is Map && '${c['leaf_id']}' == e.key)) e.key: e.value
        };
  return (list: list, kept: left);
}
