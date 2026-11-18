// On-device drive of default mode's everyday operations against the live testnet, the ones a
// many-operation run makes: Receive (the one card, its payment name), money in from the faucet
// (assets in seconds, BTC on the chain), Send to a receive code through the Send screen, a trade
// each way between two assets and each way with BTC through the Swap tab's engine
// (`appTradeEngine`, the code the tab runs), and BTC out to an address through the Send screen.
// Each operation logs the time the wallet stated, if any, and the time it took; a screenshot of
// each screen is saved through the Flutter engine (an emulator's own screen capture reads Flutter's
// SurfaceView back as black).
//
//   AMBRA_SHOTS=<dir> flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/default_ops_drive_test.dart -d <device> --dart-define=AMBRA_OPS_DRIVE=true
//
// Without AMBRA_OPS_DRIVE it does nothing: it needs the live testnet, takes faucet coins and makes a
// payment name. The wallet's phrase is printed once as `[ops drive] phrase: …` so the run's coins
// are never stranded; keep it out of any record that is shared.
import 'package:ambra/src/data/api_client.dart';
import 'package:ambra/src/data/ark_btc_service.dart';
import 'package:ambra/src/data/config.dart';
import 'package:ambra/src/data/dev_mode.dart';
import 'package:ambra/src/data/faucet_wallet.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/pay_code.dart' show lnurlEncode;
import 'package:ambra/src/data/payment_name_service.dart';
import 'package:ambra/src/data/user_trade.dart';
import 'package:ambra/src/data/wallet_repository.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/rust/frb_generated.dart';
import 'package:ambra/src/screens/send_screen.dart';
import 'package:ambra/src/screens/shell.dart';
import 'package:ambra/src/screens/swap_screen.dart';
import 'package:ambra/src/screens/user_composer.dart' show appTradeEngine;
import 'package:ambra/src/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const on = bool.fromEnvironment('AMBRA_OPS_DRIVE');
// Optional steps against a second wallet the operator of the drive runs beside it (a leaf store in
// Node, sequentia-web-wallet's tooling/leaf-node.mjs, or any wallet of the operator's):
//   AMBRA_DRIVE_PAYER_CODE  a receive code of that wallet: Send pays it 5 USDX, for its payments back
//   AMBRA_DRIVE_LNURL_NAME  a payment name at the node's domain: Send pays its bare LNURL 1 USDX (ambra#271)
//   AMBRA_DRIVE_OTHER_STORE the drive prints `[ops drive] other-store ready: <name>` and waits for a
//                           payment to its name, which the operator makes to a code another store of
//                           the phrase left as the name's stock, and says how soon it showed (ambra#270)
const payerCode = String.fromEnvironment('AMBRA_DRIVE_PAYER_CODE');
const lnurlName = String.fromEnvironment('AMBRA_DRIVE_LNURL_NAME');
const otherStore = bool.fromEnvironment('AMBRA_DRIVE_OTHER_STORE');
void note(String s) => print('[ops drive] $s'); // ignore: avoid_print

String hexOf(String ticker) {
  for (final id in SeqAssets.resolvedIds) {
    if (SeqAssets.labelFor(id).ticker == ticker) return id;
  }
  throw StateError('no asset $ticker');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('default mode: receive, send, trade each pair, BTC in and out', (tester) async {
    if (!on) return;
    await binding.convertFlutterSurfaceToImage();
    await RustLib.init();
    // The wallet a previous run left on the device is driven again, so its coins keep working;
    // a new one's phrase is printed once, so its coins are never stranded.
    var mnemonic = await WalletRepository.instance.readMnemonic();
    if (mnemonic == null) {
      mnemonic = await core.generateMnemonic();
      note('phrase: $mnemonic');
      await WalletRepository.instance.persistNewWallet(mnemonic);
    } else {
      note('the wallet already on the device');
    }
    await DevMode.instance.loadFor(mnemonic);
    expect(DevMode.instance.on, isFalse);
    final l = LeafService.instance;
    await l.start();
    await ArkBtcService.instance.start();
    await PaymentNameService.instance.start();
    final failed = <String>[];
    void check(String what, bool ok) {
      note('${ok ? 'ok' : 'FAILED'}: $what');
      if (!ok) failed.add(what);
    }

    Future<bool> until(bool Function() done, int secs, {Duration step = const Duration(milliseconds: 500)}) async {
      final end = DateTime.now().add(Duration(seconds: secs));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(step);
        if (done()) return true;
      }
      return false;
    }

    Future<bool> untilAsync(Future<bool> Function() done, int secs) async {
      final end = DateTime.now().add(Duration(seconds: secs));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(seconds: 2));
        if (await done()) return true;
      }
      return false;
    }

    double since(DateTime t) => DateTime.now().difference(t).inMilliseconds / 1000;
    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      await binding.takeScreenshot(name);
    }

    Future<void> show(Widget w) async {
      await tester.pumpWidget(MaterialApp(theme: ambraTheme(), home: Scaffold(body: SafeArea(child: w))));
      await tester.pump(const Duration(seconds: 1));
    }

    // ---- Join, and Receive's one card with the wallet's payment name.
    var t = DateTime.now();
    check('joined', await until(() => l.open && ArkBtcService.instance.open, 300));
    note('join: ${since(t)} s');
    await show(const ReceiveTab(isActive: true));
    t = DateTime.now();
    check('receive card', await until(() => find.byKey(const Key('receive-card')).evaluate().isNotEmpty, 60));
    final nameAsked = t;
    // The service makes ten new names per network at once, then one every ten minutes: the name
    // is checked again at the end of the drive, and the card shows the code meanwhile.
    note('name now: ${PaymentNameService.instance.named}');
    await until(() => false, 3);
    final forbidden = forbiddenIn(tester.allWidgets.whereType<Text>().map((w) => w.data ?? '').join(' '));
    check('no forbidden word on Receive ($forbidden)', forbidden.isEmpty);
    await shot('ops-1-receive');
    await tester.tap(find.byKey(const Key('receive-more')));
    await until(() => false, 2);
    await shot('ops-2-receive-more');

    // ---- Money in: assets from the faucet as instant payments, BTC on the chain.
    final info = await core.receiveAddressAt(mnemonic: mnemonic, index: 0, confidential: false);
    final wallet = faucetWalletIdOf(info.address);
    for (final ticker in ['USDX', 'EURX']) {
      t = DateTime.now();
      await until(() => false, 10);
      if ((l.leafAtoms()[hexOf(ticker)] ?? BigInt.zero) > BigInt.zero) {
        note('$ticker already held: ${l.leafAtoms()[hexOf(ticker)]}');
        continue;
      }
      try {
        final made = await l.pay('receive', {'asset': hexOf(ticker)});
        final r = await ApiClient.faucetLeaf('${(made as Map)['request']}', asset: ticker, wallet: wallet);
        final got = await until(() => (l.leafAtoms()[hexOf(ticker)] ?? BigInt.zero) > BigInt.zero, 120);
        check('faucet $ticker received (${r.amount}) in ${since(t)} s', got);
      } catch (e) {
        check('faucet $ticker: $e', false);
      }
    }
    t = DateTime.now();
    try {
      if (ArkBtcService.instance.held == BigInt.zero) {
        final r = await ApiClient.faucet(faucetBtcTo(info.address, await ArkBtcService.instance.address()), asset: 'BTC', wallet: wallet);
        note('faucet BTC: ${r.amount} sent ${r.ark ? 'on the Bitcoin ark' : 'on the chain'}');
      }
    } catch (e) {
      check('faucet BTC: $e', false);
    }
    await show(const BalanceTab(isActive: true));
    await until(() => false, 4);
    await shot('ops-3-balance');

    // ---- Send 1 USDX to a receive code, through the Send screen as a person does.
    final usdx = hexOf('USDX');
    final made = await l.pay('receive', {'asset': usdx});
    final code = '${(made as Map)['request']}';
    await show(const SendTab(isActive: true));
    check('Send screen loads', await until(() => find.byType(TextField).evaluate().length >= 2, 120));
    await tester.tap(find.byKey(const Key('send-asset-picker')));
    await until(() => false, 2);
    check('USDX offered on Send', find.text('USDX').evaluate().isNotEmpty);
    if (find.text('USDX').evaluate().isNotEmpty) await tester.tap(find.text('USDX').last);
    await until(() => false, 2);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), code);
    await tester.enterText(fields.at(1), '1');
    await until(() => false, 1);
    await shot('ops-4-send-form');
    check('Send names no fee asset in default mode', find.text('Pay fee in').evaluate().isEmpty);
    await tester.ensureVisible(find.text('Review & send'));
    await tester.tap(find.text('Review & send'));
    final reviewed = await until(() => find.byKey(const Key('send-code-confirm')).evaluate().isNotEmpty, 60);
    check('Send review opens', reviewed);
    if (reviewed) {
      await shot('ops-5-send-review');
      t = DateTime.now();
      await tester.tap(find.byKey(const Key('send-code-confirm')));
      final sent = await until(() => find.textContaining('Sent 1 USDX').evaluate().isNotEmpty, 120);
      check('Send 1 USDX to a receive code: ${since(t)} s', sent);
      await shot('ops-6-sent');
    }

    // ---- Send to what a person pastes: [to], [ticker], [amount]; the review it opens is pressed.
    Future<void> sendTo(String what, String to, String ticker, String amount) async {
      await show(const SendTab(isActive: true));
      await until(() => find.byType(TextField).evaluate().length >= 2, 120);
      await tester.tap(find.byKey(const Key('send-asset-picker')));
      await until(() => false, 2);
      if (find.text(ticker).evaluate().isNotEmpty) await tester.tap(find.text(ticker).last);
      await until(() => false, 2);
      await tester.enterText(find.byType(TextField).at(0), to);
      await tester.enterText(find.byType(TextField).at(1), amount);
      await tester.ensureVisible(find.text('Review & send'));
      final t0 = DateTime.now();
      await tester.tap(find.text('Review & send'));
      final inTree = find.byKey(const Key('send-code-confirm'));
      final onChain = find.byKey(const Key('send-review-send'));
      final out = find.byKey(const Key('send-offboard-confirm'));
      final opened = await until(() => inTree.evaluate().isNotEmpty || onChain.evaluate().isNotEmpty || out.evaluate().isNotEmpty, 90);
      check('$what: the review opens in ${since(t0)} s', opened);
      if (!opened) return;
      check('$what: paid in seconds, not on the chain', inTree.evaluate().isNotEmpty);
      await shot('ops-${what.replaceAll(RegExp(r'[^a-z0-9]+'), '-')}');
      if (inTree.evaluate().isEmpty) return;
      final t1 = DateTime.now();
      await tester.tap(inTree);
      check('$what: sent in ${since(t1)} s', await until(() => find.textContaining('Sent $amount $ticker').evaluate().isNotEmpty, 120));
    }

    if (payerCode.isNotEmpty) await sendTo('5 USDX to the other wallet', payerCode, 'USDX', '5');
    if (lnurlName.isNotEmpty) {
      final lnurl = lnurlEncode('https://sequentiatestnet.com/.well-known/lnurlp/$lnurlName').toUpperCase();
      note('a bare LNURL: ${lnurl.substring(0, 16)}…');
      await sendTo('1 USDX to a bare LNURL', lnurl, 'USDX', '1');
    }
    if (otherStore) {
      final named = await until(() => PaymentNameService.instance.named != null, 1200, step: const Duration(seconds: 2));
      check('a payment name to be paid at', named);
      if (named) {
        final before = l.arrivedCount;
        final held = l.leafAtoms()[usdx] ?? BigInt.zero;
        await show(const BalanceTab(isActive: true));
        note('other-store ready: ${PaymentNameService.instance.named}');
        final t0 = DateTime.now();
        final came = await until(() => l.arrivedCount > before || (l.leafAtoms()[usdx] ?? BigInt.zero) > held, 900,
            step: const Duration(milliseconds: 250));
        check('a payment to the name at another store\'s code shown ${since(t0)} s after the marker', came);
        note('other-store arrival: catch-up wait ${l.catchUp?.toJson()}');
        await shot('ops-other-store-arrived');
      }
    }

    // ---- Trades through the Swap tab's engine.
    final eng = appTradeEngine(walletTag: DevMode.instance.tag ?? 'default');
    Future<void> trade(String name, String pay, String receive, BigInt amount, int secs) async {
      final t0 = DateTime.now();
      QuoteResult? q;
      // BTC just received on the chain is moved where trades pay from once it confirms on Bitcoin
      // (about ten minutes on testnet4): asked for up to fifteen minutes.
      for (var i = 0; i < (pay == kUserBtc ? 60 : 20); i++) {
        q = await eng.quote(pay: pay, receive: receive, amount: amount);
        if (q.ok) break;
        note('$name: no quote yet (${q.why})');
        await until(() => false, 15);
      }
      if (q == null || !q.ok) return check('$name: quoted (${q?.why})', false);
      Map<String, dynamic> r;
      try {
        r = await eng.confirm(q.choice!, q.ticket!);
      } catch (e) {
        return check('$name: confirm threw $e', false);
      }
      final words = <String>{};
      var end = DateTime.now().add(Duration(seconds: secs));
      while (DateTime.now().isBefore(end)) {
        final w = tradeStateWord(r, DateTime.now().millisecondsSinceEpoch) ?? '';
        if (words.add(w)) note('$name at ${since(t0)} s: ${r['state']}: $w');
        if (const ['settled', 'returned', 'failed'].contains(r['state'])) break;
        await until(() => false, 3);
        r = await eng.advance((await eng.records()).firstWhere((x) => x['id'] == r['id']));
      }
      check('$name settled in ${since(t0)} s (${r['state']})', r['state'] == 'settled');
    }

    final eurx = hexOf('EURX');
    await trade('USDX→EURX', usdx, eurx, BigInt.from(5) * BigInt.from(100000000), 600);
    await trade('EURX→USDX', eurx, usdx, BigInt.from(2) * BigInt.from(100000000), 600);
    await show(const SwapTab(isActive: true));
    await until(() => false, 3);
    await shot('ops-7-swap-rows');

    // BTC trades wait for the faucet's BTC to reach where trades pay from.
    t = DateTime.now();
    final btcIn = await untilAsync(() async {
      await ArkBtcService.instance.refresh();
      return ArkBtcService.instance.held > BigInt.zero;
    }, 1500);
    check('BTC in: held where trades pay from after ${since(t)} s (${ArkBtcService.instance.held} sat)', btcIn);
    if (btcIn) {
      await trade('BTC→USDX', kUserBtc, usdx, BigInt.from(20000), 900);
      await trade('USDX→BTC', usdx, kUserBtc, BigInt.from(10) * BigInt.from(100000000), 1800);
    }

    // ---- BTC out to an address, through the Send screen.
    final btcAddr = (await core.receiveAddressAt(mnemonic: mnemonic, index: 1, confidential: false)).address;
    await show(const SendTab(isActive: true));
    await until(() => find.byType(TextField).evaluate().length >= 2, 120);
    await tester.tap(find.byKey(const Key('send-asset-picker')));
    await until(() => false, 2);
    final btcRow = find.text('BTC');
    if (btcRow.evaluate().length > 1) await tester.tap(btcRow.last);
    await until(() => false, 2);
    await tester.enterText(find.byType(TextField).at(0), btcAddr);
    await tester.enterText(find.byType(TextField).at(1), '0.00005');
    await tester.ensureVisible(find.text('Review & send'));
    await tester.tap(find.text('Review & send'));
    final btcReview = await until(
        () => find.byKey(const Key('send-btc-confirm')).evaluate().isNotEmpty ||
            find.byKey(const Key('send-review-send')).evaluate().isNotEmpty,
        90);
    check('BTC out review opens', btcReview);
    if (btcReview) {
      await shot('ops-8-btc-review');
      t = DateTime.now();
      final confirm = find.byKey(const Key('send-btc-confirm')).evaluate().isNotEmpty
          ? find.byKey(const Key('send-btc-confirm'))
          : find.byKey(const Key('send-review-send'));
      await tester.tap(confirm);
      final sent = await until(() => find.textContaining('Sent').evaluate().isNotEmpty, 300);
      check('BTC out sent: ${since(t)} s', sent);
      await shot('ops-9-btc-sent');
    }

    await show(const BalanceTab(isActive: true));
    await until(() => false, 5);
    await shot('ops-10-balance-end');
    await show(const ReceiveTab(isActive: true));
    final named = await until(() => PaymentNameService.instance.named != null, 720);
    check('payment name made with nothing asked, ${since(nameAsked)} s after Receive opened', named);
    note('name: ${PaymentNameService.instance.named}');
    await until(() => false, 3);
    await shot('ops-11-receive-name');
    note('failed: ${failed.length} ${failed.join(' | ')}');
    expect(failed, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 90)));
}
