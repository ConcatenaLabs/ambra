// On-device drive of Receive in default mode against the live testnet (the web wallet's
// docs/DEFAULT_MODE.md, Receive): a new wallet joins the operator, shows its receive code, New code
// moves the address, a payment name puts its LNURL-pay in the code, an amount in BTC and in an asset
// carry their invoices, and the Confidential switch shows the confidential address alone. A
// screenshot of each, through the Flutter engine (an emulator's own screen capture reads Flutter's
// SurfaceView back as black).
//
//   AMBRA_SHOTS=<dir> flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/receive_drive_test.dart -d <device> --dart-define=AMBRA_RECEIVE_DRIVE=1
//
// Without AMBRA_RECEIVE_DRIVE it does nothing: it needs the live testnet and makes a payment name.
import 'dart:math';

import 'package:ambra/src/data/ark_btc_service.dart';
import 'package:ambra/src/data/dev_mode.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/payment_name_service.dart';
import 'package:ambra/src/data/wallet_cache.dart';
import 'package:ambra/src/data/wallet_repository.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/rust/frb_generated.dart';
import 'package:ambra/src/screens/shell.dart';
import 'package:ambra/src/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const on = bool.fromEnvironment('AMBRA_RECEIVE_DRIVE');
void note(String s) => print('[receive drive] $s'); // ignore: avoid_print

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Receive: New code, a payment name, amounts, Confidential', (tester) async {
    if (!on) return;
    await binding.convertFlutterSurfaceToImage();
    await RustLib.init();
    await WalletRepository.instance.persistNewWallet(await core.generateMnemonic());
    final m = await WalletRepository.instance.readMnemonic();
    await DevMode.instance.loadFor(m!);
    await LeafService.instance.start();
    await ArkBtcService.instance.start();
    await PaymentNameService.instance.start();
    await tester.pumpWidget(MaterialApp(theme: ambraTheme(), home: const Scaffold(body: SafeArea(child: ReceiveTab()))));

    // Pumps until `done` or `secs` pass.
    Future<bool> until(bool Function() done, int secs) async {
      for (var i = 0; i < secs * 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (done()) return true;
      }
      return false;
    }

    Future<String?> addr() async => (await WalletCache.loadReceiveCode())?['address']?.toString();
    final joined = await until(() => LeafService.instance.open && ArkBtcService.instance.open, 240);
    note('joined: $joined');
    await until(() => false, 8);
    expect(find.byKey(const Key('receive-code-qr')), findsOneWidget);
    await binding.takeScreenshot('ambra-1-code');
    final a1 = await addr();

    await tester.tap(find.byKey(const Key('receive-code-new')));
    await until(() => false, 8);
    final a2 = await addr();
    note('New code: $a1 -> $a2');
    expect(a2, isNot(equals(a1)));
    await binding.takeScreenshot('ambra-2-new-code');

    final name = 'am5m${Random().nextInt(1 << 30).toRadixString(36)}';
    await PaymentNameService.instance.register(name);
    note('name: ${PaymentNameService.instance.address}');
    await until(() => false, 8);
    await binding.takeScreenshot('ambra-3-name');
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await until(() => false, 2);
    await binding.takeScreenshot('ambra-3b-name-card');
    await tester.drag(find.byType(ListView), const Offset(0, 500));

    await tester.enterText(find.byKey(const Key('receive-btc-amount')), '0.0002');
    await until(() => false, 10);
    await binding.takeScreenshot('ambra-4-amount-btc');
    final menu = find.byKey(const Key('receive-amount-asset'));
    if (menu.evaluate().isNotEmpty) {
      await tester.enterText(find.byKey(const Key('receive-btc-amount')), '1');
      await tester.tap(menu);
      await until(() => false, 2);
      final usdx = find.text('USDX').last;
      if (usdx.evaluate().isNotEmpty) {
        await tester.tap(usdx);
        await until(() => false, 12);
        await binding.takeScreenshot('ambra-5-amount-usdx');
      }
    }
    await tester.enterText(find.byKey(const Key('receive-btc-amount')), '');
    await until(() => false, 6);

    await tester.ensureVisible(find.byKey(const Key('receive-confidential')));
    await tester.tap(find.byKey(const Key('receive-confidential')));
    await until(() => false, 6);
    expect(find.byKey(const Key('receive-confidential-on')), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await until(() => false, 2);
    await binding.takeScreenshot('ambra-6-confidential');
    await tester.ensureVisible(find.byKey(const Key('receive-confidential-on')));
    await until(() => false, 2);
    await binding.takeScreenshot('ambra-6b-confidential-line');

    await PaymentNameService.instance.release();
    note('name released');
  }, timeout: const Timeout(Duration(minutes: 12)));
}
