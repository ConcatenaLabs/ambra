import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/ln_rail.dart';
import 'package:ambra/src/data/seqln_keys.dart';

void main() {
  final x = 'aa' * 32;
  Map btcChannel({String state = 'CHANNELD_NORMAL', String? nodeKey = 'btc:02ab', int balance = 500000, int spendable = 400000}) => {
        'node_key': ?nodeKey,
        'leg': 'btc',
        'asset_label': 'BTC',
        'state': state,
        'balance_units': balance,
        'spendable_units': spendable,
        'receivable_units': 100000,
      };

  group('the one figure a picker and the composer read', () {
    test('BTC held only in the wallet\'s own Bitcoin Lightning node counts, the reserve included', () {
      final held = heldFigure(onchain: BigInt.zero, leaves: BigInt.from(7), channels: [btcChannel()], target: RailTarget.btc());
      expect(held, BigInt.from(500000), reason: 'the balance row\'s Lightning figure; BTC has no leaves');
      expect(legLiquidity([btcChannel()], RailTarget.btc()).spendable, BigInt.from(400000), reason: 'what can be paid stays the spendable');
    });

    test('BTC on the Bitcoin ark counts in BTC\'s figure, and never in an asset\'s', () {
      final ark = BigInt.from(299300);
      expect(heldFigure(onchain: BigInt.zero, leaves: BigInt.zero, channels: const [], target: RailTarget.btc(), ark: ark), ark);
      expect(heldFigure(onchain: BigInt.from(1000), leaves: BigInt.zero, channels: [btcChannel()], target: RailTarget.btc(), ark: ark),
          BigInt.from(1000 + 500000 + 299300));
      expect(heldFigure(onchain: BigInt.from(5), leaves: BigInt.from(7), channels: const [], target: RailTarget.asset(hex: x, ticker: 'XT'), ark: ark),
          BigInt.from(12));
    });

    test('on-chain and Lightning add up; a channel not the wallet\'s own, or not open, counts nothing', () {
      expect(heldFigure(onchain: BigInt.from(1000), leaves: BigInt.zero, channels: [btcChannel()], target: RailTarget.btc()), BigInt.from(501000));
      expect(heldFigure(onchain: BigInt.zero, leaves: BigInt.zero, channels: [btcChannel(nodeKey: null)], target: RailTarget.btc()), BigInt.zero);
      expect(heldFigure(onchain: BigInt.zero, leaves: BigInt.zero, channels: [btcChannel(state: 'ONCHAIN')], target: RailTarget.btc()), BigInt.zero);
    });

    test('an asset counts on-chain, leaves and its own channel; a BTC channel is not the asset\'s', () {
      final ch = {'node_key': 'seq:$x:02cd', 'asset': x, 'state': 'CHANNELD_NORMAL', 'balance_units': 30, 'spendable_units': 20};
      final t = RailTarget.asset(hex: x, ticker: 'XT');
      expect(heldFigure(onchain: BigInt.from(5), leaves: BigInt.from(7), channels: [ch, btcChannel()], target: t), BigInt.from(42));
    });
  });

  test('the node keys Lightning is read for: BTC first, one per asset, an odd id or a failed derivation skipped', () {
    final keys = ownNodeKeysFor('m', ['bb' * 32, 'not-an-asset', 'cc' * 32, 'bb' * 32],
        btc: (_) => 'btc:k', asset: (_, a) => a.startsWith('cc') ? throw StateError('no key') : 'seq:$a:k');
    expect(keys, ['btc:k', 'seq:${'bb' * 32}:k']);
    expect(ownNodeKeysFor('m', ['dd' * 32], btc: (_) => throw StateError('locked'), asset: (_, a) => 'seq:$a:k'), ['seq:${'dd' * 32}:k'],
        reason: 'the asset nodes are still read');
  });
}
