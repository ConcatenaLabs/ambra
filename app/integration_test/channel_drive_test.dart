// On-device drive of payments that arrive at once over channel leaves, against a local operator
// that makes them (arca's bark-cli/tests/arca_operator_for_browsers.rs with
// ARCA_OPERATOR_CHANNELS), the other side the arca command-line wallet. A host helper forwards the
// harness's control calls and runs that wallet (`/ctl`, `/cli`, `/wait_credit`); the device
// reaches the helper, the operator's server and the node through `adb reverse`.
//
//   flutter test integration_test/channel_drive_test.dart -d <device> \
//     --dart-define=AMBRA_DRIVE_HELPER=http://127.0.0.1:18651
//
// Without AMBRA_DRIVE_HELPER it does nothing. The steps:
//  1. the app joins the operator with a new wallet; the command-line wallet pays its receive code;
//     the app's own care (`careArgs`, channels) asks for a channel; a round makes it;
//  2. the receive code names the channel once it is live and final;
//  3. twelve payments, six each way, alternating: the command-line wallet pays the app's code (the app's channel
//     read moves its figure), and the app pays the command-line wallet's channel code through
//     `LeafService.pay('send')`, the call the Send review makes; each timed, no block made;
//  4. a payment the receiving channel cannot take is paid as any other payment to a receive code.
import 'dart:convert';
import 'dart:io';

import 'package:ambra/src/data/leaf_service.dart';
import 'package:ambra/src/data/pay_code.dart' show libraryRequest;
import 'package:ambra/src/data/wallet_repository.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/rust/frb_generated.dart';
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

void note(String s) => debugPrintSynchronously('[drive] $s');
void debugPrintSynchronously(String s) => print(s); // ignore: avoid_print

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('payments arrive at once over channel leaves, each way', (tester) async {
    if (helper.isEmpty) return;
    await RustLib.init();
    final l = LeafService.instance;
    final st = await ctl('/state') as Map;
    final x = '${st['x']}';
    await WalletRepository.instance.persistNewWallet(await core.generateMnemonic());
    await l.join(LeafOperator(server: '${st['server']}', nodeUrl: '${st['node_url']}', nodeUser: 'arca'), 'arca');
    note('joined ${st['server']}');

    BigInt fig() => l.leafAtoms()[x] ?? BigInt.zero;
    Future<void> until(bool Function() ok, String what, {int seconds = 240}) async {
      final t0 = DateTime.now();
      while (!ok()) {
        if (DateTime.now().difference(t0).inSeconds > seconds) throw StateError('timed out: $what');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
    }

    // 1. Coins, then a channel by the app's own care.
    final code0 = await l.receiveCode();
    final p0 = await cli(['send', code0!, '--asset', x, '--amount', '4000000']);
    note('the command-line wallet paid the app 4000000: ${jsonEncode(p0).substring(0, 120)}');
    await l.syncNow(by: 'drive');
    await until(() => fig() >= BigInt.from(3990000), 'the app holds the payment');
    await l.careIfDue(force: true);
    note('care: ${jsonEncode(l.lastCare?['channels'])}');
    final careCli = await cli(['care', '--channels']);
    note('cli care: ${jsonEncode(careCli is Map ? careCli['channels'] : careCli)}');
    final r1 = await ctl('/round', {});
    note('round: ${jsonEncode(r1)}');
    for (var i = 0; i < 60 && !l.channels.any((c) => c is Map && c['coin_state'] == 'live' && c['final'] == true); i++) {
      await l.syncNow(by: 'drive');
      await cli(['sync']);
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    }
    final chA = l.channels.whereType<Map>().firstWhere((c) => c['coin_state'] == 'live' && c['final'] == true);
    note('the app\'s channel ${chA['leaf_id']}: side ${chA['balance']}, operator ${chA['operator_side']}');
    final cliList = await cli(['channel', 'list']) as List;
    final chB = cliList.cast<Map>().firstWhere((c) => '${c['state'] ?? c['coin_state']}' == 'live' || c['live'] == true, orElse: () => cliList.first as Map);
    note('the command-line wallet\'s channel: ${jsonEncode(chB).substring(0, 200)}');

    // 2. The code names the channel.
    final code1 = await l.receiveCode();
    final named = libraryRequest(code1!)?['channels'];
    note('the app\'s code names: ${jsonEncode(named)}');
    expect(named is Map && named[x] == chA['leaf_id'], isTrue, reason: 'the receive code names the app\'s channel');
    expect(l.channelsVersion, greaterThan(0));

    // 3. Six payments each way, alternating; the app's reads run on its own schedule (300 ms in use).
    final tip0 = (await ctl('/state') as Map)['tip'];
    final cliCode = await cli(['channel', 'code']);
    final cliText = cliCode is Map ? '${cliCode['code'] ?? cliCode['text']}' : '$cliCode';
    final times = <String>[];
    for (final (dir, amt) in [
      ('in', 100000), ('out', 70000), ('in', 25000), ('out', 40000), ('in', 5000), ('out', 15000),
      ('in', 60000), ('out', 30000), ('in', 12000), ('out', 8000), ('in', 33000), ('out', 21000),
    ]) {
      if (dir == 'in') {
        final before = fig();
        final code = await l.receiveCode();
        final t0 = DateTime.now();
        final r = await cli(['send', code!, '--asset', x, '--amount', '$amt']);
        await until(() => fig() >= before + BigInt.from(amt), 'the app sees $amt', seconds: 20);
        final ms = DateTime.now().difference(t0).inMilliseconds;
        times.add('cli->app $amt: ${ms}ms (route ${r is Map ? r['route'] : r})');
        note(times.last);
        expect(fig(), before + BigInt.from(amt));
        expect(ms, lessThan(1000));
      } else {
        final ch = (await cli(['channel', 'list']) as List).cast<Map>();
        final mine = ch.firstWhere((c) => c['asset'] == x);
        final above = '${mine['credit'] ?? 0}';
        final before = fig();
        l.holdReads(const Duration(minutes: 5)); // the review is open
        l.holdReads(Duration.zero); // Send tapped
        final t0 = DateTime.now();
        final r = await l.pay('send', {'request': cliText, 'amount': '$amt', 'asset': x}, true);
        final sentMs = DateTime.now().difference(t0).inMilliseconds;
        await l.refresh(); // as the Send screen does once its payment is made
        final w = await post('/wait_credit', {'leaf': mine['leaf_id'], 'above': above, 'timeout': 20000}) as Map;
        final ms = DateTime.now().difference(t0).inMilliseconds;
        times.add('app->cli $amt: Sent in ${sentMs}ms, in the receiver\'s channel ${ms}ms (route ${r is Map ? r['route'] : r}; credit ${w['credit']})');
        note(times.last);
        expect(BigInt.parse('${w['credit']}') - BigInt.parse(above), BigInt.from(amt));
        expect(fig(), before - BigInt.from(amt));
        expect(sentMs, lessThan(1000));
      }
    }
    final tip1 = (await ctl('/state') as Map)['tip'];
    note('tip before $tip0, after $tip1: ${tip0 == tip1 ? 'no block made' : 'BLOCKS MADE'}');
    expect(tip1, tip0);

    // 4. More than the app's channel can take: paid as any other payment to a receive code.
    final ch = l.channels.whereType<Map>().firstWhere((c) => c['leaf_id'] == chA['leaf_id']);
    final big = BigInt.parse('${ch['operator_side']}') + BigInt.from(50000);
    final before = fig();
    final code = await l.receiveCode();
    final t0 = DateTime.now();
    final r = await cli(['send', code!, '--asset', x, '--amount', '$big']);
    note('cli->app $big (past the channel\'s room ${ch['operator_side']}): ${jsonEncode(r).substring(0, 200)}');
    for (var i = 0; i < 60 && fig() < before + big; i++) {
      await l.syncNow(by: 'drive');
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    }
    final chAfter = l.channels.whereType<Map>().firstWhere((c) => c['leaf_id'] == chA['leaf_id']);
    note('fallback: arrived in ${DateTime.now().difference(t0).inMilliseconds}ms; figure ${fig()} (want ${before + big}); '
        'channel credit ${ch['credit']} -> ${chAfter['credit']}');
    expect(fig(), before + big);
    expect('${chAfter['credit']}', '${ch['credit']}', reason: 'the channel did not move');
    note('DONE ${jsonEncode(times)}');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
