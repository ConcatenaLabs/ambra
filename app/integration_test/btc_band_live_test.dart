// On-device drive of the Bitcoin ark's band (ark_limits.dart) and the operator's Lightning limit
// (ln_max_payment.dart) against the live testnet, in default mode, with a new wallet and BTC from
// the faucet. Small figures are set for the drive ([debugArkLimits], a debug build only):
//
//  1. the operator's published limit on one payment received over its Bitcoin node: Receive's code
//     for exactly that many sats carries an invoice, one sat more carries none (no band figures);
//  2. at 15/30/15 USD: a code for 15 USD or more carries neither the ark's address nor an invoice,
//     and Receive says so; Send pays such an amount to a code's address and says why first;
//  3. at 70/140/70 USD: the faucet's BTC, once confirmed, is moved into the ark up to 70 USD, in
//     one move (the refill);
//  4. at 15/30/15 USD: the ark, now over 30 USD, moves everything above 15 USD to the wallet's own
//     address in one move (the move down).
//
//   flutter test integration_test/btc_band_live_test.dart -d <device> --dart-define=AMBRA_LIVE_DRIVE=true \
//     [--dart-define=AMBRA_DRIVE_MNEMONIC="<a test wallet's phrase>"]
import 'dart:async';
import 'dart:convert';

import 'package:ambra/src/data/api_client.dart';
import 'package:ambra/src/data/ark_btc_service.dart';
import 'package:ambra/src/data/ark_limits.dart';
import 'package:ambra/src/data/btc_state.dart';
import 'package:ambra/src/data/config.dart';
import 'package:ambra/src/data/faucet_wallet.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/ln_max_payment.dart';
import 'package:ambra/src/data/pay_code.dart';
import 'package:ambra/src/data/price_service.dart';
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;
import 'package:ambra/src/data/wallet_repository.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/rust/frb_generated.dart';
import 'package:ambra/src/screens/send_screen.dart';
import 'package:ambra/src/screens/shell.dart';
import 'package:ambra/src/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const live = bool.fromEnvironment('AMBRA_LIVE_DRIVE');
void note(String s) => print('[drive ${DateTime.now().toUtc().toIso8601String().substring(11, 19)}] $s'); // ignore: avoid_print

const small = ArkLimits(btc: ArkFigures(board: 15, hold: 30, direct: 15), asset: ArkFigures(board: null, hold: null, direct: null));
const refill = ArkLimits(btc: ArkFigures(board: 70, hold: 140, direct: 70), asset: ArkFigures(board: null, hold: null, direct: null));
// The refill's figures with no `direct`: the operator's limit alone decides the code's invoice.
const lnOnly = ArkLimits(btc: ArkFigures(board: 70, hold: 140, direct: null), asset: ArkFigures(board: null, hold: null, direct: null));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Bitcoin ark\'s band and the operator\'s Lightning limit, live', (tester) async {
    if (!live) return;
    await RustLib.init();
    await PriceService.instance.load();
    // The wallet a run before left on the device is driven again (its coins, the faucet's one
    // payment to it); a new one only when there is none.
    const given = String.fromEnvironment('AMBRA_DRIVE_MNEMONIC');
    var m = given.isNotEmpty ? given : await WalletRepository.instance.readMnemonic();
    if (given.isNotEmpty) await WalletRepository.instance.persistNewWallet(given);
    if (m == null) {
      m = await core.generateMnemonic();
      await WalletRepository.instance.persistNewWallet(m);
    }
    final addr0 = (await core.receiveAddressAt(mnemonic: m, index: 0, confidential: false)).address;
    note('wallet address $addr0; BTC at ${PriceService.instance.usdPrice('BTC')} USD');
    final ark = ArkBtcService.instance, l = LeafService.instance;
    debugArkLimits = refill;
    unawaited(l.start());
    unawaited(ark.start());
    Future<void> until(bool Function() ok, String what, {int seconds = 300}) async {
      final t0 = DateTime.now();
      while (!ok()) {
        if (DateTime.now().difference(t0).inSeconds > seconds) throw StateError('timed out: $what');
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    await until(() => ark.open && ark.limitsRead, 'the ark open');
    await until(() => l.open && l.info != null, 'the leaf wallet joined', seconds: 600);
    note('ark open (least board ${ark.minBoard}), the operator joined');

    // The faucet's BTC, on the chain, asked for now: its block is waited for below.
    try {
      final f = await ApiClient.faucet(addr0, asset: 'BTC', wallet: faucetWalletIdOf(addr0));
      note('faucet: ${f.amount} BTC');
    } catch (e) {
      note('faucet: $e');
    }

    // Receive, as a person sees it: the code, copied.
    await tester.pumpWidget(MaterialApp(theme: ambraTheme(), home: const Scaffold(body: ReceiveTab())));
    await until(() => find.byKey(const Key('receive-btc-amount')).evaluate().isNotEmpty, 'Receive');
    String? shownCode;
    final say = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      final x = RegExp(r'^\[ambra-receive\] code \d+ chars, QR version \d+: (\S+)$').firstMatch(m ?? '');
      if (x != null) shownCode = x.group(1);
      say(m, wrapWidth: wrapWidth);
    };
    // Each amount on a Receive opened afresh, as a person opening it to ask for that amount.
    Future<String> codeFor(String amount) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(theme: ambraTheme(), home: const Scaffold(body: ReceiveTab())));
      await until(() => find.byKey(const Key('receive-btc-amount')).evaluate().isNotEmpty, 'Receive');
      final field = find.descendant(of: find.byKey(const Key('receive-btc-amount')), matching: find.byType(TextField));
      await tester.ensureVisible(field);
      await tester.showKeyboard(field);
      await tester.pump(const Duration(milliseconds: 300));
      tester.testTextInput.enterText(amount);
      await tester.pump(const Duration(seconds: 1));
      final shown = tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).controller.text;
      note('the amount field reads "$shown" (asked "$amount")');
      String? got;
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        // The code Receive shows, as it says it in its log (the clipboard is not readable from a
        // test on Android).
        final t = shownCode ?? '';
        PayCode? c;
        try {
          c = PayCode.read(t);
        } catch (_) {}
        final want = amount.isEmpty ? null : amount;
        if (c != null && c.amount == want && (want == null || i > 6)) {
          got = t;
          break;
        }
      }
      return got ?? '';
    }

    // 1. The operator's limit on one payment received over its Bitcoin node. The live figure (some
    // 0.09 BTC) is above what the ark's own server makes an invoice for, so the drive stands for an
    // operator that publishes a small one: the published figure, set in the operator's info as the
    // wallet holds it, is what the code follows.
    debugArkLimits = lnOnly;
    final liveInfo = l.info!;
    note('the operator publishes max_payment ${jsonEncode(lnNodeOf(liveInfo, 'BTC')?['max_payment'])} for its Bitcoin node');
    Map<String, dynamic> withLimit(String send, String receive) {
      final i = jsonDecode(jsonEncode(liveInfo)) as Map<String, dynamic>;
      ((i['server_info'] as Map)['lightning']['bitcoin']['node'] as Map)['max_payment'] = {'send': send, 'receive': receive};
      return i;
    }
    l.info = withLimit('5000', '20000');
    final most = lnMaxPayment(l.info, 'BTC', 'in');
    expect(most, BigInt.from(20000));
    String btc(BigInt sats) => formatBtc(sats);
    final atMost = PayCode.read(await codeFor(btc(most!)))!;
    final over = PayCode.read(await codeFor(btc(most + BigInt.one)))!;
    note('a code for ${btc(most)} BTC: invoice ${atMost.lightning != null}, ark ${atMost.ark != null}; '
        'for ${btc(most + BigInt.one)} BTC: invoice ${over.lightning != null}, ark ${over.ark != null}');
    expect(atMost.lightning, isNotNull);
    expect(over.lightning, isNull, reason: 'above the operator\'s limit the code carries no invoice: it is paid on the chain');
    l.info = liveInfo;

    // 2. The band's `direct` at 15 USD.
    debugArkLimits = small;
    final p = PriceService.instance.usdPrice('BTC')!;
    final d = usdAtoms(15, p, 8)!;
    final under = PayCode.read(await codeFor(btc(d - BigInt.from(100))))!;
    final atD = PayCode.read(await codeFor(btc(d)))!;
    final why = find.byKey(const Key('receive-why')).evaluate().map((e) => (e.widget as Text).data).join();
    note('a code for ${btc(d - BigInt.from(100))} BTC: invoice ${under.lightning != null}, ark ${under.ark != null}; '
        'for ${btc(d)} BTC (15 USD): invoice ${atD.lightning != null}, ark ${atD.ark != null}; Receive says "$why"');
    expect(under.ark, isNotNull);
    expect(atD.ark, isNull);
    expect(atD.lightning, isNull);
    expect(why, 'A payment of 15 USD or more goes to the address.');
    expect(forbiddenIn(why), isEmpty);
    final payee = await codeFor(btc(BigInt.from(10000)));

    // 3. The refill, at 70/140/70: the faucet's coin, once confirmed, moved into the ark up to 70 USD.
    debugArkLimits = refill;
    final cap = usdAtoms(70, p, 8)!;
    note('waiting for the faucet\'s coin to confirm; the band\'s resting level is $cap sat');
    var held = BigInt.zero;
    for (var i = 0; i < 360; i++) {
      final b = await core.btcSync(mnemonic: m, t4Api: Backend.testnet4);
      BtcState.instance.observe(btc: b);
      await ark.autoBoard();
      held = ark.held;
      if (ark.boardsMade > 0 || ark.held > BigInt.zero) break;
      await tester.pump(const Duration(seconds: 10));
    }
    note('refill: ${ark.boardsMade} board(s); the ark holds $held sat (cap $cap); boardError ${ark.boardError}');
    expect(held > BigInt.zero && held <= cap, isTrue);

    // 4. Send, with what the ark can spend now: at a `direct` of 5 USD (the resting level kept at
    // 70 meanwhile, so nothing moves out first), then the move down at 15/30/15 when the ark can
    // spend enough for it.
    debugArkLimits = const ArkLimits(btc: ArkFigures(board: 70, hold: 140, direct: 5), asset: ArkFigures(board: null, hold: null, direct: null));
    final d5 = usdAtoms(5, p, 8)!;
    for (var i = 0; i < 540 && ark.spendable < d5 + BigInt.from(1000); i++) {
      await tester.pump(const Duration(seconds: 10));
      await ark.refresh();
    }
    // Send pays the code's address for 15 USD or more, and says why first.
    await tester.pumpWidget(MaterialApp(theme: ambraTheme(), home: const Scaffold(body: SendTab())));
    await until(() => find.byType(TextField).evaluate().length >= 2, 'Send', seconds: 180);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), payee);
    await tester.enterText(fields.at(1), btc(d5));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('send-review')));
    String? said;
    for (var i = 0; i < 60 && said == null; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      for (final k in ['send-why', 'send-btc-by-address-note']) {
        final e = find.byKey(Key(k)).evaluate();
        if (e.isNotEmpty) said = (e.first.widget as Text).data;
      }
    }
    note('Send of ${btc(d5)} BTC (5 USD) to a receive code, the ark spending ${ark.spendable} sat: "$said"');
    expect(said, startsWith('A payment of 5 USD or more goes to the address.'));
    for (final k in ['send-btc-confirm']) {
      if (find.byKey(Key(k)).evaluate().isNotEmpty) await tester.tap(find.text('Cancel'));
    }
    await tester.pump(const Duration(milliseconds: 500));

    // The operator's limit on one payment sent over its Bitcoin node, 5,000 sat as published: a
    // code's invoice for 10,000 sat, which the ark could pay, goes to the code's address instead
    // (6,000 sat typed, under the `direct` figure).
    l.info = withLimit('5000', '20000');
    // On Send opened afresh.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(theme: ambraTheme(), home: const Scaffold(body: SendTab())));
    await until(() => find.byType(TextField).evaluate().length >= 2, 'Send', seconds: 180);
    final fields2 = find.byType(TextField);
    // The code of a wallet that holds no ark here: its address and its invoice only.
    final pc = PayCode.read(payee)!;
    final noArk = PayCode(address: pc.address!, amount: pc.amount, lightning: pc.lightning).build();
    await tester.enterText(fields2.at(0), noArk);
    await tester.enterText(fields2.at(1), btc(BigInt.from(6000)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('send-review')));
    said = null;
    for (var i = 0; i < 60 && said == null; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      for (final k in ['send-why', 'send-btc-by-address-note']) {
        final e = find.byKey(Key(k)).evaluate();
        if (e.isNotEmpty) said = (e.first.widget as Text).data;
      }
    }
    note('Send of 0.00006 BTC to a code whose invoice (0.0001 BTC) is above the operator\'s 5000-sat limit: "$said"');
    expect(said, startsWith('This can\u2019t arrive in seconds right now, so it goes to the address.'));
    l.info = liveInfo;
    for (final k in ['send-btc-confirm']) {
      if (find.byKey(Key(k)).evaluate().isNotEmpty) await tester.tap(find.text('Cancel'));
    }
    await tester.pumpWidget(const SizedBox());

    debugArkLimits = small;
    final before = ark.held;
    final expectOut = moveOutAtoms(held: before, board: 15, hold: 30, price: p, precision: 8);
    note('the ark holds $before sat, spendable ${ark.spendable}; above 15 USD: $expectOut sat');
    if (ark.spendable > expectOut + BigInt.from(20000)) {
      await ark.holdTick(force: true);
      await ark.refresh();
      note('after the move down the ark holds ${ark.held} sat');
      expect(ark.held < before, isTrue);
    } else {
      note('the move down waits until the ark can spend it and its fee (not run in this pass)');
    }
    debugPrint = say;
  }, timeout: const Timeout(Duration(hours: 3)));
}

String formatBtc(BigInt sats) {
  final s = sats.toString().padLeft(9, '0');
  return '${s.substring(0, s.length - 8)}.${s.substring(s.length - 8)}'.replaceFirst(RegExp(r'\.?0+$'), '');
}
