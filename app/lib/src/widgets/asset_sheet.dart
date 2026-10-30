import 'package:flutter/material.dart';

import '../data/asset_picker.dart';
import '../theme/theme.dart';

/// The wallet's one asset chooser, used wherever a person picks an asset: Send, the fee asset,
/// both sides of a trade in either mode (docs/DEFAULT_MODE.md "Asset pickers", the web wallet's
/// `asset-picker.js`).
///
/// The rows come in the caller's order, and that order is the rule: native BTC
/// first, then the assets the wallet holds, then everything else it can name
/// (see [pickerOrder]). With [registrySearch] the empty search shows "Your assets" (BTC plus the
/// assets held, minus those hidden on the Balance tab) and what the book offers or trades for the
/// other side; typing searches every row by ticker, name or id, hidden ones included, under "All
/// assets", the first forty then how many more ([pickerGroups]). With [allowPaste] too (developer
/// mode's swap, where an unknown asset can be traded) a pasted 64-hex id that matches nothing
/// becomes a row of its own ([pickerMatches]); [onPasted] hears that pick. Without
/// [registrySearch] (a fee picker) the search only filters [rows]: fee assets come from the node's
/// list, so an invented id there would be a fee no producer takes.
///
/// The list scrolls inside a sheet capped at 70% of the height left above the
/// keyboard, so any number of assets fits a small screen and the last row is
/// never stuck behind the navigation bar or the keyboard.
Future<String?> showAssetSheet(
  BuildContext context, {
  required String title,
  required List<AssetPickerItem> rows,
  String Function(String hex)? balanceOf,
  bool registrySearch = false,
  bool allowPaste = false,
  void Function(String hex)? onPasted,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AmbraColors.panel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => _AssetSheet(
      title: title,
      rows: rows,
      balanceOf: balanceOf,
      registrySearch: registrySearch,
      allowPaste: allowPaste,
      onPasted: onPasted,
    ),
  );
}

class _AssetSheet extends StatefulWidget {
  const _AssetSheet({
    required this.title,
    required this.rows,
    required this.balanceOf,
    required this.registrySearch,
    required this.allowPaste,
    required this.onPasted,
  });
  final String title;
  final List<AssetPickerItem> rows;
  final String Function(String hex)? balanceOf;
  final bool registrySearch;
  final bool allowPaste;
  final void Function(String hex)? onPasted;

  @override
  State<_AssetSheet> createState() => _AssetSheetState();
}

class _AssetSheetState extends State<_AssetSheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final keyboard = mq.viewInsets.bottom;
    final q = _search.text.trim();
    final ql = q.toLowerCase();
    final rows = widget.rows;
    final shown = widget.registrySearch
        ? pickerMatches(rows, q, paste: widget.allowPaste)
        : (q.isEmpty
            ? rows
            : rows
                .where((it) => it.ticker.toLowerCase().contains(ql) || (it.name?.toLowerCase().contains(ql) ?? false))
                .toList());
    final laid = widget.registrySearch ? pickerGroups(shown, q) : null;
    Widget tile(AssetPickerItem it) {
      final bal = widget.balanceOf?.call(it.hex);
      return ListTile(
        key: ValueKey('asset-row-${it.hex}'),
        title: Text(it.ticker, style: AmbraText.body),
        subtitle: it.name != null && it.name!.isNotEmpty
            ? Text(it.name!, style: AmbraText.sub)
            : (it.pasted ? const Text('Unregistered asset · by its id', style: AmbraText.sub) : null),
        trailing: bal == null && it.value == null
            ? null
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (bal != null) Text(bal, style: AmbraText.mono),
                if (it.value != null && it.value!.isNotEmpty) Text(it.value!, style: AmbraText.sub),
              ]),
        onTap: () {
          if (it.pasted) widget.onPasted?.call(it.hex);
          Navigator.pop(context, it.hex);
        },
      );
    }

    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text(t, key: ValueKey('asset-sheet-group-$t'), style: AmbraText.sub),
        );
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: (mq.size.height - keyboard) * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.all(16), child: Text(widget.title, style: AmbraText.title)),
            // A registry-searching picker always has the box (the rest of the registry is only
            // reachable by typing); a plain one only when the list is long.
            if (widget.registrySearch || rows.length > 6)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const ValueKey('asset-sheet-search'),
                  controller: _search,
                  style: AmbraText.body,
                  decoration: const InputDecoration(
                    hintText: PickerWords.search,
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            if (shown.isEmpty && (q.isNotEmpty || !widget.registrySearch))
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(PickerWords.none, style: AmbraText.muted),
              ),
            Flexible(
              child: ListView(
                key: const ValueKey('asset-sheet-list'),
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  if (laid == null)
                    for (final it in shown) tile(it)
                  else ...[
                    for (final g in laid.groups) ...[label(g.$1), for (final it in g.$2) tile(it)],
                    if (laid.more > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Text(PickerWords.more(laid.more), style: AmbraText.sub),
                      ),
                  ],
                  // The empty search holds only your assets and what the book offers: say how to
                  // reach the rest.
                  if (widget.registrySearch && q.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(widget.allowPaste ? PickerWords.hint : PickerWords.hintSearch, style: AmbraText.sub),
                    ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
