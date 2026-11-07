// What Ambra mobile says of a payment, and only what is so (TS1): a payment to an address out of
// the tree is "Sent" only once the leaf library has made it, and one never made says so once
// (sequentia-web-wallet#604); coins still arriving are said to be arriving, with when, never
// "Not enough" (web#607); default mode's on-chain review is the default-mode one (ambra#241); the
// arriving lines under a figure are developer mode's (ambra#239); and the leaf wallet's schedule
// never ends when a pass comes due during another sync (the board RX1 waited 25 min for).
//
//   cd app && flutter test test/address_payments_test.dart
import 'dart:io';

import 'package:ambra/src/data/address_payments.dart';
import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/wallet_cache.dart';
import 'package:ambra/src/screens/history_screen.dart' show paymentRowForTest;
import 'package:ambra/src/screens/send_screen.dart' show chainReviewSheetForTest;
import 'package:ambra/src/screens/shell.dart' show PaymentEndsCard;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const asset = '4dfe69c334a9cdf4005ddf3889bba1bc397703fa8da669254877f3209caf7c8f';
const addr = 'tb1q68apqvgwpsnewuwvtjy2xra4g3phq23quqzedu';
const id = 'c21516a41cd39b103984ca3403ca8fe14bc430ea1ce72ccc0828b9df4e4e2934';

Future<void> asked({String? stage = 'pending', String atoms = '100000000', String fee = '0'}) => WalletCache.addPayment({
      'kind': 'payment', 'ticker': 'OILX', 'atoms': atoms, 'precision': 8, 'rail': 'address', 'pending': true,
      'asset': asset, 'address': addr, 'fee_atoms': fee, 'offboard': id, 'stage': ?stage,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only unlocking and paid are made; waiting, in_round and anything unknown are not', () {
    expect(offboardStage('waiting'), 'pending');
    expect(offboardStage('in_round'), 'pending');
    expect(offboardStage('unlocking'), 'made');
    expect(offboardStage('paid'), 'made');
    expect(offboardStage('not_made'), 'not_made');
    expect(offboardStage('reclaimed'), 'reclaimed');
    expect(offboardStage(null), 'pending');
    expect(offboardStage('new'), 'pending');
  });

  test('the live case: a payment whose wallet closed after Send ends not made, and is said once', () async {
    await asked();
    var r = offboardEnds(await WalletCache.addressPayments(), [
      {'offboard': id, 'state': 'waiting'}
    ]);
    expect(r.stages[id], 'pending');
    expect(r.news, isEmpty);
    // The library's answer read on the testnet for the web wallet's payment (RX1 p3).
    final live = [
      {'address': addr, 'amount': '100000000', 'asset': asset, 'offboard': id, 'script': '0014d1fa10310e0c279771cc5c88a30fb54443702a20', 'state': 'not_made'}
    ];
    r = offboardEnds(await WalletCache.addressPayments(), live);
    expect(r.stages[id], 'not_made');
    expect(r.news.length, 1);
    expect(await WalletCache.setOffboardStages(r.stages), isTrue);
    final ends = await WalletCache.untoldEnds();
    expect(ends.length, 1);
    expect(ends.single['pending'], isFalse);
    expect(offboardNewsText(ends.single['stage'], ends.single['address'], '1', 'OILX'),
        'Your payment of 1 OILX to tb1q68apqvgwps…zedu was not made: nothing left your wallet. Send it again.');
    expect(offboardEnds(await WalletCache.addressPayments(), live).news, isEmpty);
    await WalletCache.markTold(id);
    expect(await WalletCache.untoldEnds(), isEmpty);
  });

  test('made stays made under a lagging read; taken back says it did not arrive', () async {
    await asked(stage: 'made');
    expect(offboardEnds(await WalletCache.addressPayments(), [
      {'offboard': id, 'state': 'in_round'}
    ]).stages[id], 'made');
    expect(offboardNewsText('reclaimed', addr, '1', 'OILX'),
        'Your payment of 1 OILX to tb1q68apqvgwps…zedu did not arrive. Report a problem, so it can be put right.');
  });

  test('"Sending" until made, then "Sent"; the sentences are the contract\'s, in a phone\'s words', () {
    expect(DefaultWords.sendingLater('1', 'OILX'), 'Sending 1 OILX. Keep this screen open until it is sent.');
    expect(DefaultWords.sentMade('1', 'OILX', 10), 'Sent 1 OILX. It arrives within 10 minutes.');
    expect(DefaultWords.rowNotMade, 'Not sent');
    expect(DefaultWords.rowNotMadeSub, 'Nothing left your wallet.');
    expect(DefaultWords.rowNotArrived, 'Did not arrive');
    expect(DefaultWords.newsOk, 'OK');
    // The send screen never says "Sent" for a payment to an address before the follow says made.
    final src = File('lib/src/screens/send_screen.dart').readAsStringSync();
    final body = src.substring(src.indexOf('Future<void> _reviewOffboard('), src.indexOf('Future<bool> _maybeArkBtc('));
    expect(body.contains('DefaultWords.sentThen('), isFalse);
    expect(RegExp(r"if \(stage == 'made'\) \{\s*sending\.close\(\);\s*messenger\.showSnackBar\(ambraSnack\(DefaultWords\.sentMade\(").hasMatch(body), isTrue);
  });

  test('what is still arriving is said with when, never as not enough (web#607)', () async {
    final oilx = BigInt.from(100000000);
    // The live case: the coin given up to the payment before, its change arriving.
    expect(stillArrivingCovers(oilx, BigInt.zero, BigInt.from(500000000000)), isTrue);
    expect(stillArrivingCovers(oilx, BigInt.zero, BigInt.zero), isFalse);
    expect(stillArrivingCovers(oilx, BigInt.from(50000000), BigInt.from(10000000)), isFalse);
    expect(stillArrivingCovers(oilx, oilx, BigInt.from(5)), isFalse);
    expect(DefaultWords.stillArrivingWithin('OILX', 10), 'Part of this OILX is still arriving: it can be sent within 10 minutes.');
    expect(DefaultWords.stillArrivingWithin('OILX', null), DefaultWords.stillArriving('OILX'));
    // What a payment still on its way gives up comes back only as its change.
    await asked(fee: '3000');
    expect(await WalletCache.pendingOutAtoms(asset), BigInt.from(100003000));
    await WalletCache.setOffboardStages({id: 'made'});
    expect(await WalletCache.pendingOutAtoms(asset), BigInt.zero);
  });

  testWidgets('Balance says an unmade payment once, and OK takes it away', (t) async {
    await asked(stage: 'not_made');
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: PaymentEndsCard())));
    await t.pumpAndSettle();
    expect(find.text('Your payment of 1 OILX to tb1q68apqvgwps…zedu was not made: nothing left your wallet. Send it again.'), findsOneWidget);
    await t.tap(find.byKey(const Key('payment-end-ok-$id')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('payment-ends-card')), findsNothing);
  });

  testWidgets('History: an unmade payment reads "Not sent", nothing left, its amount struck', (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: paymentRowForTest({
      'kind': 'payment', 'ticker': 'OILX', 'atoms': '100000000', 'precision': 8, 'rail': 'address', 'pending': false,
      'offboard': id, 'stage': 'not_made', 'time': 1790000000000,
    }))));
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.textContaining('Nothing left your wallet.'), findsOneWidget);
    final amt = t.widget<Text>(find.byKey(const Key('payment-not-made-amount')));
    expect(amt.style!.decoration, TextDecoration.lineThrough);
  });

  testWidgets('default mode reviews a payment on the chain as every other payment (ambra#241)', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: chainReviewSheetForTest(address: addr, amountStr: '1', ticker: 'OILX', dev: false))));
    await t.pump();
    expect(find.text('Send 1 OILX?'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    for (final gone in ['Confirm payment', 'Network', 'sequentia-testnet', 'Confirm & sign', 'Network fee (est.)', 'Fee paid in']) {
      expect(find.textContaining(gone), findsNothing, reason: gone);
    }
    await t.pumpWidget(MaterialApp(home: Scaffold(body: chainReviewSheetForTest(address: addr, amountStr: '1', ticker: 'OILX', dev: true))));
    await t.pump();
    expect(find.text('Confirm payment'), findsOneWidget);
  });

  test('the lines under a figure that say part of it is on its way are developer mode\'s (ambra#239)', () {
    final src = File('lib/src/screens/shell.dart').readAsStringSync();
    for (final cond in [
      'if (widget.dev && (widget.moving ?? BigInt.zero) > BigInt.zero)',
      'if (widget.dev && _arrivingOnly > BigInt.zero)',
      'if (widget.dev && _redoing > BigInt.zero)',
      'if (widget.dev && (widget.keptSafe ?? BigInt.zero) > BigInt.zero)',
    ]) {
      expect(src.contains(cond), isTrue, reason: cond);
    }
    for (final old in ['if (!widget.dev && _arrivingOnly', 'if (!widget.dev && _redoing', 'if (!widget.dev && (widget.moving', 'if (!widget.dev && (widget.keptSafe']) {
      expect(src.contains(old), isFalse, reason: old);
    }
    // BTC's row: the same.
    expect(src.contains('if (widget.dev)\n        ListenableBuilder(\n          listenable: LightningToArk.instance,'), isTrue);
  });

  test('a pass that comes due while another sync runs waits for it, never ends the schedule', () async {
    final l = LeafService.instance;
    l.open = true;
    try {
      await l.tickForTest(ticking: true);
      expect(l.passPlanned, isTrue);
    } finally {
      l.stopPassesForTest();
      l.open = false;
    }
  });
}
