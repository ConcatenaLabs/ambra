import 'dart:io';

import 'package:ambra/src/data/confidential_pay.dart';
import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/on_chain_need.dart';
import 'package:ambra/src/data/stake_words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a confidential address is told from a plain one, an invoice and a code', () {
    const conf = 'tsqb1qqw4pjausmn2njdkeyn0r5lz3eaqcmwvddkjk0gcskywgpm0vzlw6hh6gqx3nc6fdeyvqnx5yqzgs6tyg2c3jj0nq9qfwjngkj';
    expect(isConfidentialAddress(conf), isTrue);
    expect(isConfidentialAddress(' ${conf.toUpperCase()} '), isTrue);
    expect(isConfidentialAddress('tb1qsfc8lg5yz0y4u2u4u3u0x3w9zr2gk0qpn2nq7d'), isFalse);
    expect(isConfidentialAddress('bitcoin:tb1qsfc8lg5yz0y4u2u4u3u0x3w9zr2gk0qpn2nq7d?sequentia=abc'), isFalse);
    expect(isConfidentialAddress('lntb20u1pjexample'), isFalse);
    expect(isConfidentialAddress(''), isFalse);
  });

  test('the fee margin is the web wallet\'s: twice 1,000 vB at 2 per vB, in the asset\'s own atoms', () {
    // At a rate of 1e8 the margin is 4,000 atoms: the web wallet moved "1,000.00004 USDX" for 1,000.
    expect(feeMarginAtoms(BigInt.from(100000000)), BigInt.from(4000));
    expect(feeMarginAtoms(BigInt.from(10000000000)), BigInt.from(40));
    expect(feeMarginAtoms(BigInt.from(300000000)), BigInt.from(1334));
    expect(() => feeMarginAtoms(BigInt.zero), throwsArgumentError);
  });

  test('a move under way to the wallet\'s address counts once, until it is paid there', () {
    const a = 'aa', b = 'bb', own = 'tb1own', other = 'tb1other';
    final offboards = [
      {'offboard': '1', 'asset': a, 'amount': '10', 'address': own, 'state': 'waiting'},
      {'offboard': '2', 'asset': a, 'amount': '20', 'address': own, 'state': 'in_round'},
      {'offboard': '3', 'asset': a, 'amount': '40', 'address': own, 'state': 'unlocking'},
      {'offboard': '4', 'asset': a, 'amount': '80', 'address': own, 'state': 'paid'},
      {'offboard': '5', 'asset': a, 'amount': '160', 'address': own, 'state': 'not_made'},
      {'offboard': '6', 'asset': a, 'amount': '320', 'address': other, 'state': 'waiting'},
      {'offboard': '7', 'asset': b, 'amount': '640', 'address': own, 'state': 'waiting'},
    ];
    final r = movesComing(offboards, own, a);
    expect(r.atoms, BigInt.from(70));
    expect(r.waiting, isTrue);
    expect(movesComing(offboards.sublist(1, 3), own, a).waiting, isFalse);
    expect(movesComing(null, own, a).atoms, BigInt.zero);
  });

  test('what the screen says while the coins move is the contract\'s sentence', () {
    expect(DefaultWords.movingOut('1.00004 USDX', DefaultWords.confidentialPurpose, 10),
        'Moving 1.00004 USDX out of the Ark so it can be sent confidentially. They are ready within 10 minutes. Keep this screen open.');
    expect(DefaultWords.notEnough('1', 'USDX'), 'Not enough USDX: 1 USDX short.');
    // A stake says the same sentences.
    expect(StakeWords.movingOut('1 tSEQ', StakeWords.purposeStake), DefaultWords.movingOut('1 tSEQ', 'staked', null));
    expect(StakeWords.notEnough('1'), 'Not enough tSEQ: 1 tSEQ short.');
    expect(StakeWords.notArrived, DefaultWords.notReady);
  });

  final u = BigInt.from(100000000), mg = BigInt.from(4000);
  ConfidentialPlan p(BigInt move, bool hides) => ConfidentialPlan(move: move, hides: hides);

  test('the round amount: the smallest power of ten above the need, at least one unit', () {
    expect(bucketAtoms(BigInt.one, 8), u);
    expect(bucketAtoms(u + BigInt.from(8000), 8), u * BigInt.from(10));
    expect(bucketAtoms(u * BigInt.from(37), 8), u * BigInt.from(100));
    expect(bucketAtoms(BigInt.from(3), 0), BigInt.from(10));
  });

  test('the web wallet\'s plan: a round amount moves out, never the payment\'s own', () {
    final ml = BigInt.from(1000000);
    expect(confidentialPlan(amount: u, margin: mg, onchain: BigInt.zero, instant: u * BigInt.from(500000), minLeaf: ml), p(u * BigInt.from(10), true));
    expect(confidentialPlan(amount: u, margin: mg, onchain: BigInt.zero, instant: u * BigInt.from(3), minLeaf: ml), p(u * BigInt.from(3), true));
    expect(confidentialPlan(amount: u, margin: mg, onchain: u * BigInt.from(4), instant: u * BigInt.from(100)), p(BigInt.zero, true));
    expect(confidentialPlan(amount: u * BigInt.from(5), margin: mg, onchain: u * BigInt.from(4), instant: u * BigInt.from(100)), p(u * BigInt.from(6), true));
    expect(confidentialPlan(amount: u, margin: mg, onchain: u + mg, instant: BigInt.zero), p(BigInt.zero, false));
    expect(confidentialPlan(amount: u, margin: mg, onchain: BigInt.zero, instant: u + mg), p(u + mg, false));
    expect(confidentialPlan(amount: u, margin: mg, onchain: BigInt.zero, instant: u).short, mg);
    expect(ownShare(amount: u, margin: mg, onchain: u * BigInt.from(10)), u * BigInt.from(9) - mg);
    expect(ownShare(amount: u, margin: mg, onchain: u + mg + mg - BigInt.one), BigInt.zero);
  });

  test('Send pays a confidential address with its amount hidden, never out of the Ark to it', () {
    final src = File('lib/src/screens/send_screen.dart').readAsStringSync();
    final review = src.substring(src.indexOf('Future<void> _review({bool moved = false})'));
    final conf = review.indexOf('if (!DevMode.instance.on && isConfidentialAddress(addr)) {');
    expect(conf, greaterThan(0));
    // Before any payment out of the Ark to an address, which a confidential one never takes.
    expect(conf, lessThan(review.indexOf('return _reviewOffboard(addr, atoms)')));
    expect(review, contains('LeafService.instance.open && confidentialSaid == null'));
    expect(review, contains('return _moveOutThenReview(label.ticker, label.precision, onchain + plan.move);'));
    expect(review, contains('own = ownShare(amount: atoms, margin: margin, onchain: onchain);'));
    expect(review, contains("extra.add(core.Recipient(address: me.address, assetId: _assetId, satoshi: own));"));
    expect(review, contains('final me = await core.receiveAddressAt(mnemonic: m, index: idx, confidential: true);'));
    expect(src, contains('...widget.extra],'));
    final move = src.substring(src.indexOf('Future<void> _moveOutThenReview('));
    expect(move, contains('purpose: DefaultWords.confidentialPurpose,'));
    expect(move, contains('return _review(moved: true);'));
    final need = File('lib/src/data/on_chain_need.dart').readAsStringSync();
    final keep = need.indexOf('leaves.keepOnChain(kMoveWait + kKeepOnChain);');
    expect(keep, greaterThan(0));
    expect(keep, lessThan(need.indexOf("await leaves.pay('offboard'")));
    expect(File('lib/src/data/leaf_service.dart').readAsStringSync(), contains(': _keptOnChain'));
  });

  test('what can be moved now, by the library\'s own refusal of a larger move', () {
    const msg = "refused: the wallet's live coins of asset 2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de hold 399999981 and an offboard of 799999961 and its fee need 800000049 (refresh 0, offboard 88), with any change at least the operator's smallest leaf of 1000000";
    expect(liveFromRefusal(msg), BigInt.from(399999981 - 88));
    expect(liveFromRefusal('the operator is unreachable'), isNull);
    expect(confidentialPlan(amount: u, margin: mg, onchain: BigInt.zero, instant: liveFromRefusal(msg), minLeaf: BigInt.from(1000000)),
        ConfidentialPlan(move: BigInt.from(399999893), hides: true));
  });
}
