// ambraSnack leaves after its duration even when it carries an action, so a
// later message is shown rather than queued behind it.
//
//   cd app && flutter test test/snack_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/widgets/widgets.dart';

void main() {
  testWidgets('a snackbar with an action leaves, and the next one shows', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () {
              final m = ScaffoldMessenger.of(ctx);
              m.showSnackBar(ambraSnack('Sent · 52ad86b6…', action: SnackBarAction(label: 'Copy txid', onPressed: () {})));
              m.showSnackBar(ambraSnack('Issued asset · 9db7e6d8…'));
            },
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Sent · 52ad86b6…'), findsOneWidget);
    expect(find.text('Issued asset · 9db7e6d8…'), findsNothing);
    await tester.pump(snackDuration('Sent · 52ad86b6…') + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Sent · 52ad86b6…'), findsNothing);
    expect(find.text('Issued asset · 9db7e6d8…'), findsOneWidget);
  });

  // As long as the web wallet's toast (index.html `toast`): 9 s for a line, and a sentence past 90
  // characters longer, with an OK, never past 30 s so the queue behind it moves.
  testWidgets('a long message stays longer, with an OK that closes it', (tester) async {
    expect(snackDuration('Transaction id copied'), const Duration(seconds: 9));
    expect(snackDuration('x' * 240), const Duration(seconds: 19));
    expect(snackDuration('x' * 2000), const Duration(seconds: 30));
    final long = 'A coin this transaction spends has already been spent, most likely by another payment from this wallet. '
        'Nothing was sent: refresh and try again.';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => ScaffoldMessenger.of(ctx).showSnackBar(ambraSnack(long)),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text(long), findsOneWidget, reason: 'still there after a short line would have gone');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text(long), findsNothing);
  });

  // A sheet covers the screen's Scaffold, where a snackbar is drawn: the toast is drawn over it.
  testWidgets('a message from an open sheet is drawn over the sheet', (tester) async {
    late BuildContext sheet;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                builder: (c) {
                  sheet = c;
                  return const SizedBox(height: 300, child: Text('sheet'));
                }),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    showAmbraToast(sheet, 'Transaction id copied');
    await tester.pump();
    expect(find.text('Transaction id copied'), findsOneWidget);
    final toast = tester.getRect(find.byKey(const Key('ambra-toast')));
    final cover = tester.getRect(find.text('sheet'));
    expect(toast.bottom, greaterThan(cover.top), reason: 'drawn where the sheet is');
    // A tap reaches it, so nothing is drawn over it; and the tap closes it.
    await tester.tapAt(toast.center);
    await tester.pump();
    expect(find.text('Transaction id copied'), findsNothing);
    showAmbraToast(sheet, 'Transaction id copied');
    await tester.pump();
    expect(find.text('Transaction id copied'), findsOneWidget);
    await tester.pump(snackDuration('Transaction id copied') + const Duration(seconds: 1));
    expect(find.text('Transaction id copied'), findsNothing, reason: 'it leaves by itself');
  });
}
