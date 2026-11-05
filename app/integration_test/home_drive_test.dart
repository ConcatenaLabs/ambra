// On-device drive of taking every coin home while the operator does not answer, against a local
// operator (arca's bark-cli/tests/arca_operator_for_browsers.rs), the coins paid in by the arca
// command-line wallet. The operator is cut from the phone alone by removing the `adb reverse` of
// its server's port (the host helper's `/adb`), the node still reached; Balance's card and review
// are pumped and tapped as a person does.
//
//   flutter test integration_test/home_drive_test.dart -d <device> \
//     --dart-define=AMBRA_DRIVE_HELPER=http://127.0.0.1:18651
//
// Without AMBRA_DRIVE_HELPER it does nothing.
import 'dart:convert';
import 'dart:io';

import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/user_trade.dart' show forbiddenIn;
import 'package:ambra/src/data/wallet_repository.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/rust/frb_generated.dart';
import 'package:ambra/src/screens/shell.dart';
import 'package:ambra/src/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const helper = String.fromEnvironment('AMBRA_DRIVE_HELPER');

Future<dynamic> post(String path, Object body) async {
  final c = HttpClient();
  try {
    final rq = await c.postUrl(Uri.parse('$helper$path'));
    rq.write(jsonEncode(body));
    final rs = await rq.close();
    return jsonDecode(await rs.transform(utf8.decoder).join());
  } finally {
    c.close();
  }
}

Future<dynamic> ctl(String path, [Object? body]) => post('/ctl', {'path': path, 'body': ?body});
Future<dynamic> cli(List<String> args) => post('/cli', {'args': args});
void note(String s) => print('[drive] $s'); // ignore: avoid_print

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every coin goes home with the operator gone, from Balance\'s card', (tester) async {
    if (helper.isEmpty) return;
    await RustLib.init();
    final l = LeafService.instance;
    final st = await ctl('/state') as Map;
    final x = '${st['x']}';
    final port = Uri.parse('${st['server']}').port;
    await WalletRepository.instance.persistNewWallet(await core.generateMnemonic());
    await l.join(LeafOperator(server: '${st['server']}', nodeUrl: '${st['node_url']}', nodeUser: 'arca'), 'arca');
    for (final amt in [3000000, 2000000]) {
      final code = await l.receiveCode();
      final r = await cli(['send', code!, '--asset', x, '--amount', '$amt']);
      note('paid $amt: ${jsonEncode(r).length > 100 ? jsonEncode(r).substring(0, 100) : jsonEncode(r)}');
    }
    await l.syncNow(by: 'drive');
    note('coins: ${jsonEncode([for (final c in l.coins) if (c is Map) [c['leaf_id'].toString().substring(0, 8), c['state'], c['value']]])}');

    // Balance is open, as a person's is, while the operator still answers: no card.
    await tester.pumpWidget(MaterialApp(theme: ambraTheme(), home: const Scaffold(body: BalanceTab())));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('home-take')), findsNothing);

    // The operator cut from the phone; the node still answers.
    await post('/adb', {'args': ['reverse', '--remove', 'tcp:$port']});
    // A connection the phone already holds would outlive the removal: the operator restarts on
    // the same address, which closes every one of them, and the phone cannot open another.
    note('operator restarted: ${jsonEncode(await ctl('/restart', {}))}');
    try {
      Object? err;
      try {
        await l.syncNow(by: 'drive');
      } catch (e) {
        err = e;
      }
      note('sync with the operator cut: unreachable=${l.unreachable?.why} ${err ?? ''}');
      expect(l.unreachable, isNotNull);
      expect(l.homeOffer(), isNotNull);

      for (var i = 0; i < 240 && find.byKey(const Key('home-take')).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.text(DefaultWords.homeLine), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-take')));
      for (var i = 0; i < 240 && find.byKey(const Key('home-review-when')).evaluate().isEmpty &&
          find.byKey(const Key('home-review-nothing')).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      String texts() => [
            for (final e in find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)).evaluate())
              (e.widget as Text).data ?? ''
          ].join(' | ');
      final review = texts();
      note('review: $review');
      expect(forbiddenIn(review), isEmpty);
      await tester.tap(find.byKey(const Key('home-confirm')));
      for (var i = 0; i < 600 && find.byKey(const Key('home-review-onway')).evaluate().isEmpty &&
          find.byKey(const Key('home-review-nothing')).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final done = texts();
      note('after Take them home: $done');
      expect(done.contains('on its way to your own address'), isTrue);
      await tester.tap(find.text('Done'));
      await tester.pump(const Duration(milliseconds: 300));
      await l.refresh();
      for (var i = 0; i < 20 && find.byKey(const Key('home-onway')).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      note('on their way: ${[for (final h in l.homeUnderWayNow()) '${h.leafId.substring(0, 8)} ${h.value} ${h.delay}'].join(', ')}');
      final card = [for (final e in find.byKey(const Key('home-onway')).evaluate()) (e.widget as Text).data].join(' | ');
      note('the card: $card');
      note('coins: ${jsonEncode([for (final c in l.coins) if (c is Map) [c['leaf_id'].toString().substring(0, 8), c['state']]])}');
    } finally {
      await post('/adb', {'args': ['reverse', 'tcp:$port', 'tcp:$port']});
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
