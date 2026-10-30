// The wallet's asset sheet (Send and the swap composer) on a small screen:
//
//   - pickerOrder puts native BTC first, listed at 0, then the held assets, then
//     the rest, with no id twice;
//   - the sheet scrolls through any number of rows on a 320x480 screen and the
//     last one can be picked; BTC is the first row; the empty search shows BTC and
//     the held assets only, and typing reaches every other row.
//
//   cd app && flutter test test/asset_sheet_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/asset_picker.dart';
import 'package:ambra/src/data/swap_route.dart' show kBtcSentinel;
import 'package:ambra/src/widgets/asset_sheet.dart';

String hexN(int i) => i.toRadixString(16).padLeft(64, '0');

void main() {
  group('pickerOrder', () {
    test('BTC first even when not held, then held, then the rest, no repeats', () {
      final order = pickerOrder(held: [hexN(3), hexN(1)], known: [hexN(1), hexN(2), kBtcSentinel, hexN(3)]);
      expect(order, [kBtcSentinel, hexN(3), hexN(1), hexN(2)]);
    });
    test('an empty wallet still lists BTC', () {
      expect(pickerOrder(held: const []), [kBtcSentinel]);
    });
    test('BTC named among the held does not move or repeat it', () {
      expect(pickerOrder(held: [hexN(5), kBtcSentinel]), [kBtcSentinel, hexN(5)]);
    });
  });

  group('showAssetSheet on a small screen', () {
    // 40 held assets: far more than a 480-px screen shows at once.
    List<AssetPickerItem> rows() => [
          const AssetPickerItem(hex: kBtcSentinel, ticker: 'BTC', name: 'Bitcoin'),
          for (var i = 1; i <= 40; i++) AssetPickerItem(hex: hexN(i), ticker: 'A$i', held: true),
          AssetPickerItem(hex: 'f' * 64, ticker: 'NOTHELD', name: 'Not held'),
        ];

    Future<String?> open(WidgetTester tester, {required bool registrySearch}) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      String? picked = 'unset';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                picked = await showAssetSheet(ctx,
                    title: 'Choose asset', rows: rows(), registrySearch: registrySearch, balanceOf: (_) => '0');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('BTC is the first row, and the last held row is reachable by scrolling', (tester) async {
      await open(tester, registrySearch: true);
      final list = find.byKey(const ValueKey('asset-sheet-list'));
      expect(list, findsOneWidget);
      // BTC is the first tile of the list.
      final firstTile = find.descendant(of: list, matching: find.byType(ListTile)).first;
      expect(find.descendant(of: firstTile, matching: find.text('BTC')), findsOneWidget);
      // The 40th asset is off screen until the list is scrolled to it.
      expect(find.text('A40'), findsNothing);
      await tester.scrollUntilVisible(find.text('A40'), 200, scrollable: find.descendant(of: list, matching: find.byType(Scrollable)));
      await tester.pumpAndSettle();
      expect(find.text('A40'), findsOneWidget);
      // The sheet never overflows (a RenderFlex overflow would fail the test).
      expect(tester.takeException(), isNull);
    });

    testWidgets('picking the last row returns its id', (tester) async {
      String? got;
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => got = await showAssetSheet(ctx, title: 'Choose asset', rows: rows(), registrySearch: true),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('asset-sheet-list'));
      await tester.scrollUntilVisible(find.text('A40'), 200, scrollable: find.descendant(of: list, matching: find.byType(Scrollable)));
      await tester.tap(find.text('A40'));
      await tester.pumpAndSettle();
      expect(got, hexN(40));
    });

    testWidgets('the empty search hides an asset not held; typing finds it', (tester) async {
      await open(tester, registrySearch: true);
      expect(find.text('NOTHELD'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('asset-sheet-search')), 'nothe');
      await tester.pumpAndSettle();
      expect(find.text('NOTHELD'), findsOneWidget);
      expect(find.text('BTC'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the shared chooser: groups, the book first, the cap (docs/DEFAULT_MODE.md "Asset pickers")', () {
    test('before a search: your assets (BTC first), then what the book offers, hidden left out', () {
      final items = [
        const AssetPickerItem(hex: kBtcSentinel, ticker: 'BTC'),
        AssetPickerItem(hex: hexN(1), ticker: 'HELD', held: true),
        AssetPickerItem(hex: hexN(2), ticker: 'HID', held: true, hidden: true),
        AssetPickerItem(hex: hexN(3), ticker: 'OFF', offered: true),
        AssetPickerItem(hex: hexN(4), ticker: 'TRD', tradable: true),
        AssetPickerItem(hex: hexN(5), ticker: 'REST'),
      ];
      final m = pickerMatches(items, '');
      final g = pickerGroups(m, '');
      expect(g.groups.map((x) => x.$1), [PickerWords.yours, PickerWords.assets]);
      expect(g.groups[0].$2.map((x) => x.ticker), ['BTC', 'HELD']);
      expect(g.groups[1].$2.map((x) => x.ticker), ['OFF', 'TRD']);
      // A search reaches the hidden one and the rest, under All assets.
      final s = pickerGroups(pickerMatches(items, 'r'), 'r');
      expect(s.groups.single.$1, PickerWords.assets);
      expect(pickerGroups(pickerMatches(items, 'h'), 'h').groups.map((x) => x.$1), [PickerWords.yours]);
    });
    test('many matches show the first forty, then how many more', () {
      final items = [for (var i = 1; i <= 50; i++) AssetPickerItem(hex: hexN(i), ticker: 'A$i')];
      final g = pickerGroups(pickerMatches(items, 'a'), 'a');
      expect(g.groups.single.$2, hasLength(40));
      expect(g.more, 10);
      expect(PickerWords.more(g.more), '+10 more · keep typing to find them.');
    });
    test('a pasted id is an asset only where the chooser allows it', () {
      final items = [const AssetPickerItem(hex: kBtcSentinel, ticker: 'BTC')];
      expect(pickerMatches(items, 'ab' * 32, paste: false), isEmpty);
      expect(pickerMatches(items, 'ab' * 32).single.pasted, isTrue);
    });
  });
}
