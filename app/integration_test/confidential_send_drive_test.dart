// On-device drive of a confidential payment in default mode against the live testnet (the web
// wallet's docs/DEFAULT_MODE.md, Send): a wallet that holds USDX only for instant payments pays a
// confidential address. Send first moves a round amount out of the Ark ("Moving … out of the Ark so
// it can be sent confidentially…"), then reviews the payment ("Anyone reading the chain can see
// that this payment is USDX, but not how much."), and pays it on the chain beside the wallet's own
// confidential output. A screenshot of each, through the Flutter engine.
//
// The wallet's phrase is saved before the build (it is the regression wallet the build names); the
// drive prints the wallet's address, and waits (up to 40 minutes) for USDX to arrive there and be
// moved in for instant payments, which the wallet does by itself.
//
//   flutter build apk --debug --target-platform android-x64 \
//     --target=integration_test/confidential_send_drive_test.dart \
//     --dart-define=AMBRA_CONF_DRIVE=true --dart-define=AMBRA_CONF_PHRASE="$(cat <phrase file>)" \
//     --dart-define=AMBRA_CONF_TO=<tsqb1 address>
//   AMBRA_SHOTS=<dir> flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/confidential_send_drive_test.dart -d <device> \
//     --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk
//
// Without AMBRA_CONF_DRIVE it does nothing.
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/dev_mode.dart';
import 'package:ambra/src/data/wallet_repository.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/rust/frb_generated.dart';
import 'package:ambra/src/screens/send_screen.dart';
import 'package:ambra/src/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const on = bool.fromEnvironment('AMBRA_CONF_DRIVE');
const phrase = String.fromEnvironment('AMBRA_CONF_PHRASE');
const to = String.fromEnvironment('AMBRA_CONF_TO');
const usdx = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de';
void note(String s) => print('[conf drive] ${DateTime.now().toUtc().toIso8601String()} $s'); // ignore: avoid_print

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Send to a confidential address from instant holdings', (tester) async {
    if (!on) return;
    await binding.convertFlutterSurfaceToImage();
    await RustLib.init();
    if (await WalletRepository.instance.readMnemonic() == null) {
      await WalletRepository.instance.persistNewWallet(phrase.trim());
    }
    final m = await WalletRepository.instance.readMnemonic();
    await DevMode.instance.loadFor(m!);
    note('developer mode: ${DevMode.instance.on}');
    await LeafService.instance.start();
    note('fund: ${await core.receiveAddress(mnemonic: m)}');

    Future<bool> until(bool Function() done, int secs) async {
      for (var i = 0; i < secs * 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (done()) return true;
      }
      return false;
    }

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final joined = await until(() => LeafService.instance.open, 240);
    note('joined: $joined');
    final unit = BigInt.from(100000000);
    // What lands at the address is moved in by the wallet's own upkeep, as the app's screens ask
    // for it: asked here every 30 s while the drive waits.
    var held = false;
    for (var i = 0; i < 80 && !held; i++) {
      await LeafService.instance.refresh();
      await LeafService.instance.autoBoard();
      held = await until(() => LeafService.instance.spendableAtoms(usdx) >= unit * BigInt.from(5), 30);
    }
    note('held for instant payments: ${LeafService.instance.spendableAtoms(usdx)} atoms ($held)');
    // Send opened once the coins are held, as a person opens it.
    await tester.pumpWidget(MaterialApp(theme: ambraTheme(), home: const Scaffold(body: SafeArea(child: SendTab(isActive: true)))));
    await until(() => false, 20);
    await binding.takeScreenshot('ambra-conf-0-send');

    await tester.enterText(find.byType(TextField).at(0), to);
    await tester.enterText(find.byType(TextField).at(1), '1');
    await tester.tap(find.byKey(const ValueKey('send-asset-picker')));
    await until(() => false, 2);
    await tester.tap(find.text('USDX').last);
    await until(() => false, 3);
    final t0 = DateTime.now();
    await tester.tap(find.byKey(const Key('send-review')));
    final moving = await until(() => find.byKey(const Key('send-moving')).evaluate().isNotEmpty || find.text('Confirm payment').evaluate().isNotEmpty, 120);
    if (find.byKey(const Key('send-moving')).evaluate().isNotEmpty) {
      final t = (tester.widget(find.byKey(const Key('send-moving'))) as Text).data;
      note('Send says: $t');
      await binding.takeScreenshot('ambra-conf-1-moving');
    } else {
      note('no move shown ($moving)');
    }
    final reviewed = await until(() => find.text('Confirm payment').evaluate().isNotEmpty, 2700);
    note('review after ${DateTime.now().difference(t0).inSeconds} s: $reviewed');
    final said = find.byKey(const Key('send-by-address-note'));
    if (said.evaluate().isNotEmpty) note('review says: ${(tester.widget(said) as Text).data}');
    await until(() => find.text('estimating…').evaluate().isEmpty, 60);
    await binding.takeScreenshot('ambra-conf-2-review');
    expect(reviewed, isTrue);
    await tester.tap(find.text('Confirm & sign'));
    final sent = await until(() => find.textContaining('Sent · ').evaluate().isNotEmpty, 120);
    if (sent) note('the wallet says: ${(tester.widget(find.textContaining('Sent · ')) as Text).data}');
    await binding.takeScreenshot('ambra-conf-3-sent');
    expect(sent, isTrue);
  }, timeout: const Timeout(Duration(minutes: 100)));
}
