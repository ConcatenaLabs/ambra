import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/problem_report.dart';
import 'package:ambra/src/screens/report_screen.dart';

const phrase = 'abandon ability able about above absent absorb abstract absurd abuse access accident';

void main() {
  test('scrub removes addresses, keys, invoices and long hex', () {
    final t = scrub('pay tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx failed; '
        'key cVt4o7BGAig1UXywgGSmARhxMdzP5qvQsxKkSsc1XEkw3tDTQFpy; '
        'tx 4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b; '
        'invoice lntb1u1pjxyz0pp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypq; '
        'blinded tsqb1qqgdh2u7x3l5w0e5c8m2ux2zftqlhlzt0j7xh4m7m8a6dnrcgzvsunpp5w9sxzxe');
    for (final leak in ['tb1qw508', 'cVt4o7', '4a5e1e4b', 'lntb1u1', 'tsqb1qq']) {
      expect(t.contains(leak), isFalse, reason: leak);
    }
    expect(t, contains('pay [address] failed'));
    expect(scrub('The trade could not be made. Nothing moved.'), 'The trade could not be made. Nothing moved.');
  });

  test('three words of the phrase in order are refused', () {
    expect(carriesPhrase('my words are abandon ability able', phrase), isTrue);
    expect(carriesPhrase('Absorb, abstract; absurd!', phrase), isTrue);
    expect(carriesPhrase('I was able to send, then the app froze', phrase), isFalse);
    expect(carriesPhrase('abandon able ability', phrase), isFalse);
    final r = buildReport(version: '0', mode: 'user', description: 'phrase: about above absent');
    expect(refusal(r, phrase), ReportWords.phrase);
    expect(refusal(buildReport(version: '0', mode: 'user', description: '  '), phrase), ReportWords.needDescription);
    expect(refusal(buildReport(version: '0', mode: 'user', description: 'The swap hung'), phrase), isNull);
  });

  test('the error log keeps the last twenty, scrubbed, folding a repeat', () {
    final log = ErrorLog();
    for (var i = 0; i < 25; i++) {
      log.note('failed $i');
    }
    log.note('failed 24');
    log.note(Exception('send to tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx refused'));
    final l = log.list();
    expect(l.length, ReportLimits.errors);
    expect(l.first.message, 'failed 6');
    expect(l[l.length - 2].message, 'failed 24');
    expect(l.last.message, 'Exception: send to [address] refused');
  });

  test('the payload follows the intake contract and carries no address unless given', () {
    final r = buildReport(
      version: '1.2.3',
      mode: 'user',
      description: ' x ' * 3000,
      accountCode: ' a1b2c3d4e5 ',
      errors: [ReportError(DateTime.utc(2026, 10, 29, 12), 'bad tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx')],
      context: {'platform': 'android 15', 'network': 'testnet', 'empty': ''},
    );
    expect(r.keys.toList(), ['v', 'wallet', 'version', 'mode', 'description', 'account_code', 'errors', 'context']);
    expect(r['wallet'], 'ambra-mobile');
    expect(r['mode'], 'default');
    expect((r['description'] as String).length, ReportLimits.description);
    expect(r['account_code'], 'a1b2c3d4e5');
    expect((r['errors'] as List).single, {'at': '2026-10-29T12:00:00.000Z', 'message': 'bad [address]'});
    expect(r['context'], {'platform': 'android 15', 'network': 'testnet'});
    final withAddr = buildReport(version: '0', mode: 'developer', description: 'd', addresses: ['tb1qexample']);
    expect(withAddr['attached'], {'addresses': ['tb1qexample']});
    expect(withAddr['mode'], 'developer');
  });

  test('every answer of the intake is said in the wallet\'s words', () async {
    final report = buildReport(version: '0', mode: 'user', description: 'd');
    MockClient answer(int status, [Object body = const {}]) => MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.headers['Content-Type'], startsWith('application/json'));
          expect(jsonDecode(req.body), report);
          return http.Response(jsonEncode(body), status);
        });
    final ok = await sendReport(report, client: answer(201, {'id': 7, 'account': 'linked'}));
    expect(ok.words, 'Report sent. Its number is #7. Thank you. If it is accepted, it is credited to your Emissio account.');
    expect((await sendReport(report, client: answer(201, {'id': 8, 'account': 'unknown'}))).words,
        'Report sent. Its number is #8. Thank you. That account code was not found, so the report was sent without it.');
    expect((await sendReport(report, client: answer(409))).words, ReportWords.already);
    expect((await sendReport(report, client: answer(429))).words, ReportWords.tooMany);
    expect((await sendReport(report, client: answer(413))).words, ReportWords.tooLarge);
    expect((await sendReport(report, client: answer(500))).words, ReportWords.failed);
    final down = MockClient((_) async => throw http.ClientException('no route'));
    expect((await sendReport(report, client: down)).words, ReportWords.failed);
  });

  test('the words say none of default mode\'s forbidden words, and no dashes', () {
    for (final s in ReportWords.all()) {
      for (final w in DefaultWords.forbidden) {
        expect(RegExp('(^|[^a-z-])${RegExp.escape(w.toLowerCase())}([^a-z-]|\$)').hasMatch(s.toLowerCase()), isFalse,
            reason: '"$s" says "$w"');
      }
      expect(RegExp('[—–]').hasMatch(s), isFalse, reason: s);
    }
  });

  testWidgets('the screen refuses the phrase, shows the address only when ticked, and sends', (tester) async {
    final sent = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      sent.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'id': 3, 'account': 'linked'}), 201);
    });
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: ReportScreen(
        phrase: () async => phrase,
        address: () async => 'tb1qtestaddress',
        client: client,
        url: Uri.parse('http://intake.test/api/problem-reports'),
      ),
    ));
    expect(find.text(ReportWords.title), findsOneWidget);

    await tester.enterText(find.descendant(of: find.byKey(const Key('report-text')), matching: find.byType(TextField)),
        'my words: absent absorb abstract');
    await tester.tap(find.byKey(const Key('report-send')));
    await tester.pumpAndSettle();
    expect(find.text(ReportWords.phrase), findsOneWidget);
    expect(sent, isEmpty);

    await tester.enterText(find.descendant(of: find.byKey(const Key('report-text')), matching: find.byType(TextField)),
        'The faucet paid but the balance stayed at 0.');
    await tester.pump();
    expect(find.text(ReportWords.phrase), findsNothing, reason: 'an edit clears the refusal');
    await tester.enterText(find.descendant(of: find.byKey(const Key('report-code')), matching: find.byType(TextField)), 'a1b2c3d4e5');
    expect(find.text('tb1qtestaddress'), findsNothing);
    await tester.tap(find.byKey(const Key('report-address')));
    await tester.pumpAndSettle();
    expect(find.text(ReportWords.addressesWill), findsOneWidget);
    expect(find.text('tb1qtestaddress'), findsOneWidget);

    await tester.tap(find.text(ReportWords.preview));
    await tester.pumpAndSettle();
    final shown = jsonDecode(tester.widget<SelectableText>(find.byKey(const Key('report-payload'))).data!) as Map<String, dynamic>;

    await tester.ensureVisible(find.byKey(const Key('report-send')));
    await tester.tap(find.byKey(const Key('report-send')));
    await tester.pumpAndSettle();
    expect(sent.single, shown, reason: 'what is sent is what was shown');
    expect(sent.single['wallet'], 'ambra-mobile');
    expect(sent.single['attached'], {'addresses': ['tb1qtestaddress']});
    expect(sent.single['account_code'], 'a1b2c3d4e5');
    expect(find.text('Report sent. Its number is #3. Thank you. If it is accepted, it is credited to your Emissio account.'),
        findsOneWidget);
  });
}
