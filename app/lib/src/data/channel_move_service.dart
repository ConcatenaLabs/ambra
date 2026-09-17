// ---------------------------------------------------------------------------
// channel_move_service.dart — a Move to Lightning that outlives the sheet it started in.
//
// The move is two steps with a gap in the middle that nobody owned: the wallet sends the deposit
// on-chain itself (its own money, its own signature), and the LSP then watches for it and drives
// the device-co-signed `fundchannel`. Between those, the funds are ON the hosted node with no
// channel — recoverable, but only by someone who remembers a channel is owed.
//
// The sheet used to be that someone, and it was bad at it. It polled 120 times at 2s and then said
// "the channel is still opening; check back shortly" — a four-minute budget against a server that
// watches for an hour. Worse, "check back shortly" was a promise it could not keep: nothing was
// written down, so there was nothing to check back on. Close the sheet, or let the OS kill the app,
// and the deposit sat on the node with no record anywhere that a channel was owed.
//
// So the job is persisted the moment the deposit is broadcast, and the poll loop lives here rather
// than in a widget's State:
//   * the budget outlasts the LSP's own watch window, so the error the user reads is the SERVER's
//     real reason rather than the client running out of patience;
//   * closing the sheet no longer abandons anything — [drive] keeps running;
//   * [resume] re-drives every persisted move on cold start, so an app kill is survivable too.
//
// Re-issuing is safe. `POST /channel/open` is idempotent by design (the LSP's A10 guard adopts an
// already-opening channel instead of funding a second one), so a move whose job id we have lost —
// reaped by the server, or never recorded — is finished by asking again, NOT by depositing again.
// The record is removed only when the channel is actually active.
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'lightning_service.dart';
import 'lsp_client.dart';
import 'store_log.dart';
import 'wallet_repository.dart';

/// What to SAY for each phase of a move. ONE map, covering every phase the LSP's channel-open
/// worker reports and every phase the client adds — including the ones between the deposit and the
/// channel (`syncing`, `connecting`), which the old three-entry map in the Balance tab lacked.
///
/// That mattered: the caller spoke only when the map had an entry, so an unlisted phase left the
/// PREVIOUS line on screen. A job parked in `syncing` (the node is up but not answering, usually
/// because it is waiting on this device's signer) kept the sheet saying "Waiting for the deposit to
/// confirm on-chain…" — pointing the user at the chain when the deposit had confirmed in the next
/// block and the thing that needed them was their own wallet.
const Map<String, String> _phaseCopy = {
  'deposit-address': 'Getting your hosted node deposit address…',
  'sending': 'Signing and sending the on-chain deposit…',
  'sent': 'Deposit sent; waiting for confirmation…',
  'opening-request': 'Asking your Lightning node to open the channel…',
  'pending_deposit': 'Waiting for the deposit to confirm on-chain…',
  'syncing': 'Waiting for your Lightning node to answer — keep the app open, it needs your device to sign…',
  'connecting': 'Connecting your node to the routing peer (your device co-signs the handshake)…',
  'opening': 'Opening the Lightning channel (your device is co-signing the funding)…',
  'awaiting_lockin': 'Channel funding broadcast; waiting for it to confirm…',
  'reconnecting': 'Connection hiccup — reconnecting (your deposit is safe; this will finish)…',
  'active': 'Channel active.',
};

/// The line for [phase], or null to leave the current line alone. An unrecognised phase still
/// returns words: vague beats stale, so a phase added server-side degrades to imprecise rather
/// than to a frozen line that is no longer true. `failed` is null on purpose — the thrown error
/// carries the real reason and generic copy would replace it.
String? movePhaseCopy(String? phase) {
  final p = (phase ?? '').trim();
  if (p.isEmpty || p == 'failed') return null;
  return _phaseCopy[p] ?? 'Working on your Lightning channel ($p)…';
}

/// A Move to Lightning whose deposit is already on the hosted node, and whose channel is therefore
/// still owed. Holds no secret: the deposit was signed and broadcast before this is written, and
/// the channel funding is signed by the device, not from anything in here.
class ChannelMove {
  ChannelMove({
    required this.id,
    required this.chain,
    required this.asset,
    required this.ticker,
    required this.amountAtoms,
    required this.nodeKey,
    required this.pollPath,
    required this.startedMs,
  });

  /// Stable identity: one move in flight per hosted node, so re-driving upserts rather than piling up.
  final String id;
  final String chain; // 'btc' | 'seq'
  final String? asset; // seq only: the asset id being moved
  final String ticker; // for the copy the user reads
  final String amountAtoms; // base units, as text (BigInt does not survive JSON)
  final String nodeKey; // the user's OWN provisioned node
  final String? pollPath; // the LSP job to poll; null until /channel/open has been issued
  final int startedMs;

  ChannelMove withPoll(String? poll) => ChannelMove(
        id: id,
        chain: chain,
        asset: asset,
        ticker: ticker,
        amountAtoms: amountAtoms,
        nodeKey: nodeKey,
        pollPath: poll,
        startedMs: startedMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'chain': chain,
        'asset': asset,
        'ticker': ticker,
        'amountAtoms': amountAtoms,
        'nodeKey': nodeKey,
        'pollPath': pollPath,
        'startedMs': startedMs,
      };

  static ChannelMove fromJson(Map<String, dynamic> j) => ChannelMove(
        id: '${j['id'] ?? ''}',
        chain: '${j['chain'] ?? 'seq'}',
        asset: j['asset']?.toString(),
        ticker: '${j['ticker'] ?? ''}',
        amountAtoms: '${j['amountAtoms'] ?? '0'}',
        nodeKey: '${j['nodeKey'] ?? ''}',
        pollPath: j['pollPath']?.toString(),
        startedMs: (j['startedMs'] as num?)?.toInt() ?? 0,
      );
}

/// Persistent store of moves whose channel is still owed. Mirrors `PlacedOrders`: one JSON list
/// under one key, newest first, upserted by id.
class ChannelMoveStore {
  static const _key = 'ambra.ln.channelMoves';
  static const _storage = FlutterSecureStorage();

  static Future<List<ChannelMove>> list() async {
    final s = await _storage.read(key: _key);
    if (s == null || s.isEmpty) return [];
    try {
      final arr = jsonDecode(s) as List<dynamic>;
      return arr.map((e) => ChannelMove.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      // Preserved on disk, not drivable by this build: never drop a record that stands for funds
      // sitting on a node with no channel.
      storeLog('channel move: store UNREADABLE ($e) - nothing driven, records stay persisted');
      return [];
    }
  }

  static Future<void> _save(List<ChannelMove> items) =>
      _storage.write(key: _key, value: jsonEncode(items.map((e) => e.toJson()).toList()));

  /// Add or replace a record by its id (newest first).
  static Future<void> put(ChannelMove rec) async {
    final items = await list();
    items.removeWhere((e) => e.id == rec.id);
    items.insert(0, rec);
    await _save(items);
    storeLog('channel move: saved ${rec.id} (${rec.ticker}, poll=${rec.pollPath ?? 'none yet'})');
  }

  /// Remove ONE record — only ever because its channel is active. [reason] is logged: a record
  /// that stands for funds must never vanish quietly.
  static Future<void> remove(String id, {String reason = 'unspecified'}) async {
    final items = await list();
    items.removeWhere((e) => e.id == id);
    await _save(items);
    storeLog('channel move: removed $id ($reason)');
  }
}

class ChannelMoveService {
  ChannelMoveService._();

  /// The client's patience. The LSP watches a channel open for `CHANNEL_WATCH_MS` (1h by default)
  /// and then fails the job with a reason; we outlast that on purpose, so what the user reads is
  /// the server's real verdict rather than our own impatience. The old four minutes reported a
  /// failure for a channel that was opening perfectly well.
  static const Duration watchWindow = Duration(minutes: 70);

  /// Poll briskly while the user is likely watching, then settle down. A move that has gone quiet
  /// is waiting on a block, not on us.
  static const Duration fastPoll = Duration(seconds: 2);
  static const Duration slowPoll = Duration(seconds: 5);
  static const Duration fastFor = Duration(minutes: 2);

  /// Transient poll failures to tolerate before giving up — the channel keeps opening server-side,
  /// so a dropped request must not fail the move. Mirrors the web's fundChannel maxPollErrors.
  static const int maxPollErrors = 24;

  /// The LSP's answer when a job id it never had (or has since reaped) is polled. Matched rather
  /// than inferred from a status code: it means "ask again", not "this move failed".
  static bool isUnknownJob(Object e) =>
      RegExp(r'unknown channel job', caseSensitive: false).hasMatch('$e');

  /// The id for a move on [nodeKey]: one in flight per hosted node.
  static String idFor(String nodeKey) => 'move:$nodeKey';

  /// Drive [rec] to an active channel, reporting each phase through [onStep].
  ///
  /// Issues `/channel/open` when the record has no job yet, and re-issues it if the job id turns
  /// out to be unknown (reaped by the server, or lost with the app). Re-issuing never re-deposits:
  /// the LSP funds from the balance already on the node, and adopts an opening channel rather than
  /// opening a second one. Removes the record once the channel is active; leaves it in place on
  /// every failure, so the move stays resumable.
  static Future<ChannelJob> drive(ChannelMove rec, {void Function(String)? onStep}) async {
    void say(String s) {
      try {
        onStep?.call(s);
      } catch (_) {/* a caller's setState after dispose must not fail the move */}
    }

    var record = rec;
    Future<ChannelJob> issue() async {
      say(movePhaseCopy('opening-request')!);
      final started = await LspClient.channelOpen(
        chain: record.chain,
        amount: int.parse(record.amountAtoms),
        asset: record.asset,
        node: record.nodeKey,
      );
      record = record.withPoll(started.poll ?? started.jobId);
      await ChannelMoveStore.put(record);
      return started;
    }

    // Where this move stands right now: poll the job we recorded, ask for one if we never got a job
    // id, and ask again if the id we have turns out to be unknown. A single expression, so `job` is
    // never a conditionally-assigned local.
    Future<ChannelJob> firstJob() async {
      if ((record.pollPath ?? '').isEmpty) return issue();
      try {
        return await LspClient.channelOpenPoll(record.pollPath!);
      } catch (e) {
        if (!isUnknownJob(e)) rethrow;
        storeLog('channel move: ${record.id} job is gone - re-issuing /channel/open');
        return issue();
      }
    }

    var job = await firstJob();

    final startedAt = DateTime.now();
    final deadline = startedAt.add(watchWindow);
    var pollErrs = 0;
    for (;;) {
      final copy = movePhaseCopy(job.status);
      if (copy != null) say(copy);
      if (job.isActive) {
        await ChannelMoveStore.remove(record.id, reason: 'channel active');
        return job;
      }
      if (job.isFailed) throw Exception(job.error ?? 'the channel could not be opened');
      if (DateTime.now().isAfter(deadline)) {
        throw Exception('the channel open is taking longer than the server watches for it; '
            'your deposit is safe on your own node, and reopening the app picks this up again');
      }
      await Future<void>.delayed(
          DateTime.now().difference(startedAt) < fastFor ? fastPoll : slowPoll);
      final poll = record.pollPath;
      if ((poll ?? '').isEmpty) {
        job = await issue();
        continue;
      }
      try {
        job = await LspClient.channelOpenPoll(poll!);
        pollErrs = 0; // a good poll clears the transient-error streak
      } catch (e) {
        if (isUnknownJob(e)) {
          storeLog('channel move: ${record.id} job vanished mid-poll - re-issuing');
          job = await issue();
          continue;
        }
        if (++pollErrs > maxPollErrors) rethrow;
        say(movePhaseCopy('reconnecting')!);
      }
    }
  }

  /// Re-drive every persisted move. Called on cold start, so a deposit that landed before the app
  /// was killed still gets its channel without the user having to know a channel was owed.
  ///
  /// Each record is driven INDEPENDENTLY: one node that will not come up must not hold up another
  /// node's channel. The device signer is attached first — the hosted node is keyless, so a move
  /// driven without it cannot be co-signed.
  static Future<void> resume({void Function(String)? onStep}) async {
    if (!LightningService.instance.configured) return;
    final recs = await ChannelMoveStore.list();
    if (recs.isEmpty) return;
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) {
      storeLog('channel move resume: wallet locked - ${recs.length} record(s) stay persisted');
      return;
    }
    storeLog('channel move resume: ${recs.length} record(s)');
    for (final rec in recs) {
      try {
        await LightningService.instance.connectNode(m, chain: rec.chain, asset: rec.asset);
        await drive(rec, onStep: onStep);
      } catch (e) {
        // The record stays: the funds are on the node and the next resume tries again.
        storeLog('channel move resume: ${rec.id} not finished ($e) - record kept');
      }
    }
  }
}
