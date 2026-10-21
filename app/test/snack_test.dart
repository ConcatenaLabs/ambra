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
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Sent · 52ad86b6…'), findsNothing);
    expect(find.text('Issued asset · 9db7e6d8…'), findsOneWidget);
  });
}
