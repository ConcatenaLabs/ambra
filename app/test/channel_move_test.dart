// A DEPOSIT ON A NODE WITH NO CHANNEL MUST BE WRITTEN DOWN, AND EVERY PHASE MUST HAVE WORDS.
//
// A Move to Lightning puts the user's funds on their hosted node and then asks the LSP for a
// channel. Between those two things the funds are recoverable but only by someone who remembers a
// channel is owed, and nobody did: the sheet polled 120 times at 2s, said "the channel is still
// opening; check back shortly" and kept no record — so there was nothing to check back on, and a
// closed sheet or a killed app left the deposit stranded.
//
// These pin the two properties that make the move survivable:
//   1. The RECORD. Written before the channel is asked for, upserted per node, preserved through a
//      failure, and removed only when the channel is actually active.
//   2. The COPY. Every phase the LSP's worker reports has words, including the ones between the
//      deposit and the channel (`syncing`, `connecting`) that the old three-entry map lacked — that
//      omission is what left "Waiting for the deposit to confirm on-chain..." frozen on screen for
//      an hour while the deposit had confirmed in the next block.
//
//   cd app && flutter test test/channel_move_test.dart
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/channel_move_service.dart';

const MethodChannel _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const String _listKey = 'ambra.ln.channelMoves';

const String _tseq = 'c8eccacf0953e1931cd31e434d8319101cc36e6c38b0e2104d8687552fae3e40';
const String _nodeA = 'seq:$_tseq:03aaaa';
const String _nodeB = 'seq:$_tseq:03bbbb';

/// An in-memory flutter_secure_storage backend over the plugin MethodChannel, so the store's
/// put/list/remove is exercised for real rather than mocked away.
class _FakeSecureStorage {
  final Map<String, String> data = {};

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    switch (call.method) {
      case 'read':
        return data[args['key'] as String];
      case 'write':
        data[args['key'] as String] = args['value'] as String;
        return null;
      case 'delete':
        data.remove(args['key'] as String);
        return null;
      case 'containsKey':
        return data.containsKey(args['key'] as String);
      case 'readAll':
        return Map<String, String>.from(data);
      case 'deleteAll':
        data.clear();
        return null;
      default:
        return null;
    }
  }

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, _handle);
    addTearDown(() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
  }
}

ChannelMove _rec({String nodeKey = _nodeA, String? poll, String ticker = 'tSEQ'}) => ChannelMove(
      id: ChannelMoveService.idFor(nodeKey),
      chain: 'seq',
      asset: _tseq,
      ticker: ticker,
      amountAtoms: '15000000000', // 150 tSEQ at precision 8
      nodeKey: nodeKey,
      pollPath: poll,
      startedMs: 1789589997000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the record', () {
    test('survives a JSON round-trip, amount included', () {
      final r = _rec(poll: '/channel/open/abc');
      final back = ChannelMove.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.id, r.id);
      expect(back.chain, 'seq');
      expect(back.asset, _tseq);
      expect(back.ticker, 'tSEQ');
      // The amount is the whole point of the record: it is what the re-issued /channel/open asks for.
      expect(back.amountAtoms, '15000000000');
      expect(BigInt.parse(back.amountAtoms), BigInt.from(15000000000));
      expect(back.nodeKey, _nodeA);
      expect(back.pollPath, '/channel/open/abc');
      expect(back.startedMs, r.startedMs);
    });

    test('a record with no job yet round-trips as no job, not as a literal null', () {
      final back = ChannelMove.fromJson(jsonDecode(jsonEncode(_rec().toJson())) as Map<String, dynamic>);
      expect(back.pollPath, isNull);
    });

    test('withPoll changes only the job, so nothing else can drift on an update', () {
      final r = _rec();
      final w = r.withPoll('/channel/open/xyz');
      expect(w.pollPath, '/channel/open/xyz');
      expect(w.id, r.id);
      expect(w.amountAtoms, r.amountAtoms);
      expect(w.nodeKey, r.nodeKey);
      expect(w.asset, r.asset);
      expect(w.startedMs, r.startedMs);
    });

    test('the id is per hosted node, so two legs never collide', () {
      expect(ChannelMoveService.idFor(_nodeA), isNot(ChannelMoveService.idFor(_nodeB)));
      expect(ChannelMoveService.idFor(_nodeA), ChannelMoveService.idFor(_nodeA));
    });
  });

  group('the store', () {
    test('a saved move is on disk and reads back', () async {
      _FakeSecureStorage().install();
      await ChannelMoveStore.put(_rec());
      final all = await ChannelMoveStore.list();
      expect(all.length, 1);
      expect(all.first.nodeKey, _nodeA);
      expect(all.first.pollPath, isNull);
    });

    test('learning the job id upserts rather than piling up a second record', () async {
      _FakeSecureStorage().install();
      await ChannelMoveStore.put(_rec());
      await ChannelMoveStore.put(_rec(poll: '/channel/open/abc'));
      final all = await ChannelMoveStore.list();
      expect(all.length, 1, reason: 'the same node must not accumulate records');
      expect(all.first.pollPath, '/channel/open/abc');
    });

    test('two nodes keep two records, newest first', () async {
      _FakeSecureStorage().install();
      await ChannelMoveStore.put(_rec(nodeKey: _nodeA));
      await ChannelMoveStore.put(_rec(nodeKey: _nodeB, ticker: 'tSEQ'));
      final all = await ChannelMoveStore.list();
      expect(all.length, 2);
      expect(all.first.nodeKey, _nodeB);
    });

    test('removing one leaves the other alone', () async {
      _FakeSecureStorage().install();
      await ChannelMoveStore.put(_rec(nodeKey: _nodeA));
      await ChannelMoveStore.put(_rec(nodeKey: _nodeB));
      await ChannelMoveStore.remove(ChannelMoveService.idFor(_nodeA), reason: 'test');
      final all = await ChannelMoveStore.list();
      expect(all.length, 1);
      expect(all.first.nodeKey, _nodeB);
    });

    test('an undecodable store reads as empty and is NOT overwritten', () async {
      final fake = _FakeSecureStorage();
      fake.install();
      fake.data[_listKey] = 'not json at all';
      expect(await ChannelMoveStore.list(), isEmpty);
      // The bytes stand for funds sitting on a node with no channel. A read must never drop them.
      expect(fake.data[_listKey], 'not json at all');
    });
  });

  group('an unknown job means ask again, not give up', () {
    test("the LSP's own wording is recognised", () {
      // Verbatim from lsp-server.mjs's /channel/open/<id> handler, as LspClient._decode rethrows it.
      expect(ChannelMoveService.isUnknownJob(Exception('unknown channel job id')), isTrue);
      expect(ChannelMoveService.isUnknownJob(Exception('Unknown Channel Job Id')), isTrue);
    });

    test('a real failure is not mistaken for one', () {
      expect(ChannelMoveService.isUnknownJob(Exception('deposit did not confirm before timeout')), isFalse);
      expect(ChannelMoveService.isUnknownJob(Exception('could not connect your Lightning node to the routing peer')),
          isFalse);
      expect(ChannelMoveService.isUnknownJob(Exception('channel open failed')), isFalse);
    });
  });

  group('the phase copy', () {
    // Every status runChannelOpen sets, plus the one startChannelOpen seeds the job with, plus the
    // phases the client adds on its own. Drifting from this list is the defect these exist for.
    const serverPhases = <String>[
      'pending_deposit',
      'syncing',
      'connecting',
      'opening',
      'awaiting_lockin',
      'active',
    ];
    const clientPhases = <String>[
      'deposit-address',
      'sending',
      'sent',
      'opening-request',
      'reconnecting',
    ];

    test('every phase either side reports has words', () {
      for (final p in [...serverPhases, ...clientPhases]) {
        final copy = movePhaseCopy(p);
        expect(copy, isNotNull, reason: "phase '$p' has no copy: the line would keep showing the previous phase");
        expect(copy!.length, greaterThan(10), reason: "phase '$p' says almost nothing");
      }
    });

    test('syncing points at the wallet, not at the chain', () {
      // THE regression. This is the phase a parked node sits in, and it used to inherit
      // "Waiting for the deposit to confirm on-chain..." — true of the previous phase, not this one.
      final copy = movePhaseCopy('syncing')!;
      expect(copy.toLowerCase(), contains('keep the app open'));
      expect(copy.toLowerCase(), isNot(contains('confirm on-chain')));
    });

    test('an unrecognised phase still moves the line', () {
      final copy = movePhaseCopy('some_future_phase');
      expect(copy, isNotNull);
      expect(copy, contains('some_future_phase'),
          reason: 'vague beats stale: an unknown phase must not leave the last line in place');
    });

    test('nothing to say leaves the line alone', () {
      // 'failed' is silent on purpose: the thrown error carries the real reason.
      for (final v in <String?>[null, '', '   ', 'failed']) {
        expect(movePhaseCopy(v), isNull, reason: "'$v' should not overwrite the line");
      }
    });
  });

  test('the client outlasts the server, so the user reads the real verdict', () {
    // CHANNEL_WATCH_MS defaults to 3_600_000 in lsp-server.mjs: the job fails itself with a reason
    // at one hour. Giving up before that reports OUR impatience as the channel's failure, which is
    // exactly what four minutes of polling did.
    expect(ChannelMoveService.watchWindow, greaterThan(const Duration(hours: 1)));
    expect(ChannelMoveService.fastPoll, lessThanOrEqualTo(ChannelMoveService.slowPoll));
  });
}
