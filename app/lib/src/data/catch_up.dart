/// A payment to a code another wallet of the phrase handed out: the rules that take it in within
/// seconds. The web wallet's `leaves.js` (`requestWaits`, `catchUpWait` and the functions beside
/// it) and the extension's `src/leaf-schedule.js` hold the same rules: change them together.
///
/// The payment name hands out the codes every wallet of a phrase leaves with the name service, so a
/// payer can be given a code another store of the same phrase made: the phrase open in Ambra
/// browser or the web wallet, or a store this phone held before. The library takes such a coin at
/// the mailbox read that meets it, asking the operator for it by id. A coin the operator does not
/// serve yet, or an operator without reads by id, is refused there ("a coin for owner nonce …,
/// which this wallet never drew"), once; only the library's catch-up between stores of one phrase,
/// a step of `sync`, then takes it in. The library runs that step at most once every
/// [kCatchUpEveryS] of median time (the chain's clock, the `now` of every `schedule`), and the step
/// reads only what the operator has settled, so a catch-up run seconds after the payment can end
/// whole without it.
///
/// So the wallet keeps the refused coins ([CatchUpWait.pending], by leaf id) and syncs for them
/// whenever the library's catch-up is open again, until each one is held: a catch-up restored it,
/// or the wallet's coins list it. Between two attempts at least [kCatchUpRetryMs] pass, whatever the
/// library answered or threw, and [kCatchUpSlowMs] once [kCatchUpSlowAfter] attempts in a row ran
/// no catch-up (the operator or the node not answering). The wait ends once every coin is held,
/// after [kCatchUpTries] whole catch-ups without one of them (about an hour of the library's
/// cadence; the library's own catch-ups and daily sync still look for it), or at the latest
/// [kCatchUpLastMs] after it began.
library;

/// A receive request handed out before requests carried a lapse date (`lapses_at` null) counts as
/// waiting for this long from when it was handed out: the life every request now has.
const int kRequestHoldsS = 27 * 86400;

final RegExp kNeverDrew = RegExp(r'which this wallet never drew');
const int kCatchUpEveryS = 600;
const int kCatchUpRetryMs = 60000;
const int kCatchUpSlowAfter = 10;
const int kCatchUpSlowMs = 10 * 60000;
const int kCatchUpTries = 6;
const int kCatchUpLastMs = 24 * 3600000;

/// Whether a receive request this wallet handed out still waits, however long ago: the codes the
/// wallet's payment name leaves with the name service are such requests, handed out to payers up to
/// a day after they were made. While one waits, the wallet reads its mailbox at every tick, so a
/// payment to the name or to an older code shows within a tick instead of at the library's next
/// daily sync. A restored request (`owner: restored`) is the library's to follow.
bool requestWaits(Map<String, dynamic>? schedule) {
  final now = schedule?['now'];
  if (now is! num) return false;
  final rs = schedule?['receive_requests'];
  if (rs is! List) return false;
  return rs.any((r) {
    if (r is! Map || r['state'] != 'waiting' || r['owner'] == 'restored') return false;
    final l = r['lapses_at'], a = r['asked_at'];
    final lapses = l is num ? l : (a is num ? a + kRequestHoldsS : null);
    return lapses != null && lapses > now;
  });
}

List _listed(Object? v) => v is List ? v : const [];

/// The leaf ids of the coins a mailbox answer refused as paid to another store's code.
List<String> phraseCoinsRefused(Object? mailbox) => [
      for (final r in _listed(mailbox is Map ? mailbox['refused'] : null))
        if (r is Map && r['leaf_id'] != null && kNeverDrew.hasMatch('${r['reason'] ?? ''}')) '${r['leaf_id']}',
    ];

/// Whether a sync's catch-up ran to its end: its `caught_up` is the catch-up's answer (null when
/// none ran), `{error}` when it failed, and carries `more` when its time ran out before the end.
bool caughtUpWhole(Object? sync) {
  final c = sync is Map ? sync['caught_up'] : null;
  return c is Map && c['error'] == null && (c['more'] == null || c['more'] == false);
}

bool _more(Map c) => c['more'] != null && c['more'] != false;

/// When the library's catch-up is open next ([openAt], median-time seconds; 0 open now; null not
/// known), after a sync's answer, [libNow] being the library's median time then (the answer's own
/// `schedule.now` first): a whole catch-up closes it for [kCatchUpEveryS]; one cut short (`more`)
/// or failed is open again at once (the library has not stamped it). A sync that ran none while
/// the time was not known says one ran within the last [kCatchUpEveryS]: half of it is taken, so a
/// wallet opened again soon after one runs neither a burst of syncs nor the whole wait.
num? catchUpGate(num? openAt, Object? sync, num? libNow) {
  final s = sync is Map ? sync['schedule'] : null;
  final at = s is Map && s['now'] is num ? s['now'] as num : libNow;
  final c = sync is Map ? sync['caught_up'] : null;
  if (c is Map) {
    if (_more(c) || c['error'] != null) return 0;
    return at != null ? at + kCatchUpEveryS : openAt;
  }
  if (openAt == null && at != null) return at + kCatchUpEveryS ~/ 2;
  return openAt;
}

/// The wait for coins of the phrase: since when, the leaf ids still out, the whole catch-ups since
/// it began ([tries]), the attempts in a row that ran no catch-up ([nulls]), and the last attempt
/// (times in ms).
class CatchUpWait {
  const CatchUpWait({required this.since, required this.pending, this.tries = 0, this.nulls = 0, this.attemptAt});
  final int since;
  final List<String> pending;
  final int tries;
  final int nulls;
  final int? attemptAt;

  CatchUpWait copy({List<String>? pending, int? tries, int? nulls, int? attemptAt}) => CatchUpWait(
      since: since, pending: pending ?? this.pending, tries: tries ?? this.tries, nulls: nulls ?? this.nulls, attemptAt: attemptAt ?? this.attemptAt);

  Map<String, dynamic> toJson() => {'since': since, 'pending': pending, 'tries': tries, 'nulls': nulls, 'attemptAt': attemptAt};

  static CatchUpWait? fromJson(Object? j) {
    if (j is! Map || j['since'] is! num || j['pending'] is! List) return null;
    return CatchUpWait(
      since: (j['since'] as num).toInt(),
      pending: [for (final x in j['pending'] as List) '$x'],
      tries: (j['tries'] as num?)?.toInt() ?? 0,
      nulls: (j['nulls'] as num?)?.toInt() ?? 0,
      attemptAt: (j['attemptAt'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) => other is CatchUpWait && '${other.toJson()}' == '${toJson()}';
  @override
  int get hashCode => '${toJson()}'.hashCode;
}

bool _ended(CatchUpWait? w, int now) =>
    w == null || w.pending.isEmpty || w.tries >= kCatchUpTries || now - w.since >= kCatchUpLastMs;

/// A mailbox answer that refused coins of the phrase adds them (a second refusal keeps the start).
CatchUpWait? catchUpWait(CatchUpWait? w, {Object? mailbox, required int now}) {
  if (w != null && _ended(w, now)) w = null;
  final ids = phraseCoinsRefused(mailbox);
  if (ids.isEmpty) return w;
  final base = w ?? CatchUpWait(since: now, pending: const []);
  return base.copy(pending: {...base.pending, ...ids}.toList());
}

/// An attempt that threw (the schedule or the sync): it counts towards the cadence.
CatchUpWait? catchUpAttempt(CatchUpWait? w, int now) => w?.copy(attemptAt: now, nulls: w.nulls + 1);

/// A coin of the wait the wallet now holds: what it is shown as on arrival.
typedef CaughtIn = Map<String, dynamic>;

({CatchUpWait? wait, List<CaughtIn> arrived}) _take(CatchUpWait? w, Map<String, Map> found, int now) {
  if (w == null) return (wait: null, arrived: const []);
  final arrived = <CaughtIn>[];
  final pending = <String>[];
  for (final id in w.pending) {
    final c = found[id];
    if (c != null) {
      arrived.add({'leaf_id': id, 'asset': c['asset'], 'value': '${c['value'] ?? ''}', 'kind': c['kind'] ?? 'caught up'});
    } else {
      pending.add(id);
    }
  }
  final next = w.copy(pending: pending);
  return (wait: _ended(next, now) ? null : next, arrived: arrived);
}

/// After a sync: its own mailbox's refusals join the wait first (the sync's catch-up runs after its
/// mailbox step, so one sync can refuse a coin and restore it), then what its catch-up restored is
/// taken off, and the attempt is counted. A catch-up that answered with an error (`{error}`) ran
/// none: it counts towards the slow cadence ([kCatchUpSlowAfter]) like a sync that ran none, and
/// never resets that count.
({CatchUpWait? wait, List<CaughtIn> arrived}) catchUpAfterSync(CatchUpWait? w, {required Object? sync, required int now}) {
  w = catchUpWait(w, mailbox: sync is Map ? sync['mailbox'] : null, now: now);
  if (w == null) return (wait: null, arrived: const []);
  final c = sync is Map ? sync['caught_up'] : null;
  final ran = c is Map && c['error'] == null;
  final counted = w.copy(attemptAt: now, tries: w.tries + (caughtUpWhole(sync) ? 1 : 0), nulls: ran ? 0 : w.nulls + 1);
  final found = <String, Map>{
    for (final r in _listed(ran ? c['restored'] : null))
      if (r is Map && r['leaf_id'] != null) '${r['leaf_id']}': r,
  };
  return _take(counted, found, now);
}

/// After the wallet's coins were read: a coin the store lists in any state but the operator's word
/// `pending` is held.
({CatchUpWait? wait, List<CaughtIn> arrived}) catchUpHeld(CatchUpWait? w, Object? coins, int now) {
  final found = <String, Map>{
    for (final c in _listed(coins))
      if (c is Map && c['leaf_id'] != null && c['state'] != 'pending') '${c['leaf_id']}': c,
  };
  return _take(w, found, now);
}

/// How long until the wallet syncs for the wait, in ms (0: now; null: no wait): once the library's
/// catch-up is open ([openAt] against [libNow], the library's median time as last read, counted at
/// one second a second), and once the cadence since the last attempt allows.
int? catchUpSyncIn(CatchUpWait? w, {required int now, num? libNow, num? openAt}) {
  if (_ended(w, now)) return null;
  final gap = w!.nulls >= kCatchUpSlowAfter ? kCatchUpSlowMs : kCatchUpRetryMs;
  final retry = w.attemptAt == null ? 0 : w.attemptAt! + gap - now;
  final gate = openAt == null || libNow == null ? 0 : ((openAt - libNow) * 1000).toInt();
  return [0, retry, gate].reduce((a, b) => a > b ? a : b);
}

/// When the scheduled job must wake, in seconds: the library's [libraryWake] (seconds, or null when
/// nothing waits), and no later than the wait's next sync ([waitMs], from [catchUpSyncIn]; null
/// when no wait), rounded up to a whole second.
int? jobWakeIn(Object? libraryWake, int? waitMs) {
  final lib = libraryWake is num ? libraryWake.toInt() : null;
  final wait = waitMs == null ? null : (waitMs + 999) ~/ 1000;
  if (lib == null) return wait;
  if (wait == null) return lib;
  return wait < lib ? wait : lib;
}
