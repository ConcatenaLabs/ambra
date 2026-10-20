// The Contracts screen renders the summary the kit's contract engine wrote for a
// spend, and signs only the digest of the summary it showed. The fixtures are the
// engine's own summaries from `ambra_core/tests/contracts.rs` on a regtest chain
// (a faucet drip, a Pignus vault repaid with this wallet's coins); that test signs
// and confirms both spends.
import 'dart:convert';
import 'dart:io';

import 'package:ambra/src/data/contract_summary.dart';
import 'package:ambra/src/screens/contracts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/contracts/$name.json').readAsStringSync()) as Map<String, dynamic>;

List<String> rows(Map<String, dynamic> s) =>
    [for (final sec in summarySections(s)) for (final (k, v) in sec.rows) '${sec.title} | $k | $v'];

void main() {
  test('a drip: the template, the path, the five checks and the balance change', () {
    final r = rows(fixture('drip'));
    bool has(String w) => r.any((x) => x.contains(w));
    for (final w in [
      'Template | It names itself | sequentia/faucet-drip v1 (not checked by any registry)',
      'Path | Path | drip (simplicity leaf drip)',
      'Your balance change | This wallet | 500.00000000 tSEQ',
      'Checked before signing | 1. Known template |',
      'Checked before signing | 2. Output recomputed | the engine derived',
      'Checked before signing | 3. Program run | the contract\'s program (input 0) ran against the final transaction',
      'Checked before signing | 4. Shown | this screen; it signs digest ',
      'Checked before signing | 5. Contract key | FAUCET_KEY is this wallet\'s contract key at m/8383h/1h/0h/0/0',
    ]) {
      expect(has(w), isTrue, reason: '$w\n${r.join('\n')}');
    }
  });

  test('a vault repaid with this wallet\'s coins: every input, the keyless path, the borrower', () {
    final r = rows(fixture('repay'));
    bool has(String w) => r.any((x) => x.contains(w));
    for (final w in [
      'Path | Path | repay (simplicity leaf vault)',
      'What it spends | Input 0 | the contract\'s coin',
      'What it spends | Input 1 | this wallet\'s coin',
      'signed with its funding key m/84h/1h/0h/0/0',
      'SHA-256 of this wallet\'s script',
      'Values the spender chose | PATH | Left(Left(()))',
      'Your balance change | This wallet | -2.00002000 YDEBT',
      'Where the coins go | Pays output 1 | 2.00000000 YDEBT',
      'Checked before signing | 5. Contract key | path repay takes no signature, so no contract key signs',
      'Checked before signing | Path chosen by | PATH = Left(Left(',
    ]) {
      expect(has(w), isTrue, reason: '$w\n${r.join('\n')}');
    }
  });

  testWidgets('the screen shows the summary and signs only the digest it showed', (tester) async {
    tester.view.physicalSize = const Size(1200, 12000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final shown = fixture('repay');
    final signed = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: ContractsScreen(
        initialAsk: '{"templateHash": "6b17…"}',
        prepare: (ask) async => jsonEncode(shown),
        sign: (digest) async { signed.add(digest); return 'aa' * 32; },
      ),
    ));
    await tester.tap(find.byKey(const Key('contract-review')));
    await tester.pumpAndSettle();
    expect(find.text('Sign this contract spend?'), findsOneWidget);
    expect(find.textContaining('path repay takes no signature', findRichText: true), findsWidgets);
    expect(find.textContaining('this screen; it signs digest ${shown['digest']}', findRichText: true), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('contract-sign')));
    await tester.tap(find.byKey(const Key('contract-sign')));
    await tester.pumpAndSettle();
    expect(signed, [shown['digest']]);
    expect(find.textContaining('Broadcast ${'aa' * 32}', findRichText: true), findsOneWidget);
  });

  testWidgets('a refusal is shown in the engine\'s words, and nothing is offered to sign', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ContractsScreen(
        prepare: (ask) async => throw 'refused: input 1 is said to hold 1200000000 atoms of x; this wallet\'s own record of t:1 is 1200000000 atoms of y, so it is not spent as shown',
        sign: (digest) async => fail('nothing is signed'),
      ),
    ));
    await tester.tap(find.byKey(const Key('contract-review')));
    await tester.pumpAndSettle();
    expect(find.textContaining('so it is not spent as shown'), findsOneWidget);
    expect(find.byKey(const Key('contract-sign')), findsNothing);
  });
}
