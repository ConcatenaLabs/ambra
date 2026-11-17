// A payment in the tree that waits for its coins to settle first (a receive code's `send`, an
// address's `offboard`, through LeafService.payPending) is written down while it waits, so that an
// app closed meanwhile makes it when the wallet is next open, once and only once (the web wallet's
// pending-sends.js; sequentia-web-wallet docs/DEFAULT_MODE.md, Send).
//
// Each record is {id, kind: 'code' | 'address', asset, atoms, to, command, args, history?, at,
// state}. Its state is what the library was last told: 'asking' while the library is asked to pay
// it (it may sign), 'waiting' after an answer that signed nothing (it waits for a round). A wallet
// that opens finds:
//   - 'waiting': nothing of it was signed: asked again, with what was reviewed;
//   - 'asking': the app closed while the library was being asked, and it may have paid: never asked
//     again (dropped, and said once on Balance: [DefaultWords.pendingMaybeSent]).
// A record ends (is removed) once the payment is made or refused, and lapses after [kPendingMost].

import 'dart:convert';

import 'default_words.dart';

/// Where the records are kept: SharedPreferences in the app, a map in the tests.
abstract class PendingStore {
  String? getString(String key);
  void setString(String key, String value);
  void remove(String key);
}

/// A [PendingStore] over a map.
class MapPendingStore implements PendingStore {
  final Map<String, String> m = {};
  @override
  String? getString(String key) => m[key];
  @override
  void setString(String key, String value) => m[key] = value;
  @override
  void remove(String key) => m.remove(key);
}

const kPendingSendsKey = 'ambra.leaves.pendingSends';
const kPendingEndsKey = 'ambra.leaves.pendingEnds';

/// The longest a payment waits to be made after its review: the longest a payment waits for a
/// round (kReleaseWait).
const kPendingMost = Duration(hours: 3);

String _keyOf(String tag) => '$kPendingSendsKey.$tag';
String _endsKey(String tag) => '$kPendingEndsKey.$tag';

List<Map<String, dynamic>> _list(PendingStore s, String key) {
  try {
    final v = jsonDecode(s.getString(key) ?? '[]');
    return v is List ? [for (final r in v) if (r is Map) Map<String, dynamic>.from(r)] : [];
  } catch (_) {
    return [];
  }
}

void _save(PendingStore s, String key, List<Map<String, dynamic>> list) {
  if (list.isEmpty) {
    s.remove(key);
  } else {
    s.setString(key, jsonEncode(list));
  }
}

/// The payments written down and not ended.
List<Map<String, dynamic>> pendingSends(PendingStore s, String tag) => _list(s, _keyOf(tag));

/// Writes [rec] down (replacing the record of its id).
Map<String, dynamic> putPending(PendingStore s, String tag, Map<String, dynamic> rec) {
  final list = pendingSends(s, tag).where((r) => r['id'] != rec['id']).toList()..add(rec);
  _save(s, _keyOf(tag), list);
  return rec;
}

/// Ends the record of [id].
void dropPending(PendingStore s, String tag, String id) =>
    _save(s, _keyOf(tag), pendingSends(s, tag).where((r) => r['id'] != id).toList());

/// Writes each stage of [rec] down before the library is asked, so an app that closes then finds
/// it as it was.
void Function(String stage) stageWriter(PendingStore s, String tag, Map<String, dynamic> rec) => (stage) {
      rec['state'] = stage;
      putPending(s, tag, rec);
    };

/// What a wallet that opens does with the records it finds at [now]: those it asks again
/// (`resume`, kept until they end) and those it drops (`dropped`, each with `why`: 'asking' or
/// 'lapsed', removed here and noted as ends).
({List<Map<String, dynamic>> resume, List<Map<String, dynamic>> dropped}) takePending(PendingStore s, String tag, DateTime now) {
  final resume = <Map<String, dynamic>>[], dropped = <Map<String, dynamic>>[];
  for (final r in pendingSends(s, tag)) {
    if (r['id'] == null) continue;
    final at = (r['at'] as num?)?.toInt() ?? 0;
    if (now.millisecondsSinceEpoch - at > kPendingMost.inMilliseconds) {
      dropped.add({...r, 'why': 'lapsed'});
    } else if (r['state'] == 'waiting') {
      resume.add(r);
    } else {
      dropped.add({...r, 'why': 'asking'});
    }
  }
  _save(s, _keyOf(tag), resume);
  for (final d in dropped) {
    noteEnd(s, tag, d, d['why'] == 'asking' ? 'unknown' : 'lapsed', now);
  }
  return (resume: resume, dropped: dropped);
}

/// The same payment (asset, amount, recipient) written down and not ended: a second one asked
/// while it is open would pay it twice. Null when there is none.
Map<String, dynamic>? samePending(PendingStore s, String tag, {required String asset, required String atoms, required String to}) {
  for (final r in pendingSends(s, tag)) {
    if (r['asset'] == asset && '${r['atoms']}' == atoms && r['to'] == to) return r;
  }
  return null;
}

/// The ends to say once on Balance: `why` is 'refused' or 'lapsed' (nothing left the wallet), or
/// 'unknown' (the app closed while the library was asked; it may have gone).
List<Map<String, dynamic>> pendingEnds(PendingStore s, String tag) => _list(s, _endsKey(tag));

void noteEnd(PendingStore s, String tag, Map<String, dynamic> rec, String why, DateTime now) {
  final list = pendingEnds(s, tag).where((e) => e['id'] != rec['id']).toList()
    ..add({
      'id': rec['id'],
      'kind': rec['kind'],
      'asset': rec['asset'],
      'atoms': '${rec['atoms']}',
      'to': rec['to'],
      if (rec['ticker'] != null) 'ticker': rec['ticker'],
      if (rec['precision'] != null) 'precision': rec['precision'],
      'why': why,
      'at': now.millisecondsSinceEpoch,
    });
  _save(s, _endsKey(tag), list.length > 20 ? list.sublist(list.length - 20) : list);
}

void markEndTold(PendingStore s, String tag, String id) =>
    _save(s, _endsKey(tag), pendingEnds(s, tag).where((e) => e['id'] != id).toList());

/// The one sentence Balance says of an end ([pendingEnds]), [amount] and [ticker] as shown.
String pendingEndText(Map end, String amount, String ticker) =>
    end['why'] == 'unknown' ? DefaultWords.pendingMaybeSent(amount, ticker) : DefaultWords.pendingNotSent(amount, ticker);
