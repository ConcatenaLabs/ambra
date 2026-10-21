import 'package:flutter/material.dart';

import '../data/asset_picker.dart';
import '../theme/theme.dart';

/// The wallet's one asset sheet, used by Send and by the swap composer.
///
/// The rows come in the caller's order, and that order is the rule: native BTC
/// first, then the assets the wallet holds, then everything else it can name
/// (see [pickerOrder]). With [registrySearch] the empty search shows BTC plus the
/// assets held, minus those hidden on the Balance tab; typing searches every row
/// by ticker, name or id, and a pasted 64-hex id that matches nothing becomes a
/// row of its own ([pickerMatches]); [onPasted] hears that pick. Without it (a fee
/// picker) the search only filters [rows]: fee assets come from the node's list,
/// so an invented id there would be a fee no producer takes.
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
    required this.onPasted,
  });
  final String title;
  final List<AssetPickerItem> rows;
  final String Function(String hex)? balanceOf;
  final bool registrySearch;
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
        ? pickerMatches(rows, q)
        : (q.isEmpty
            ? rows
            : rows
                .where((it) => it.ticker.toLowerCase().contains(ql) || (it.name?.toLowerCase().contains(ql) ?? false))
                .toList());
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
                  decoration: InputDecoration(
                    hintText: widget.registrySearch ? 'Search assets, or paste an asset id' : 'Search assets',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            if (shown.isEmpty && q.isNotEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No asset matches your search.', style: AmbraText.muted),
              )
            else if (shown.isEmpty && !widget.registrySearch)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No assets available.', style: AmbraText.muted),
              ),
            Flexible(
              child: ListView(
                key: const ValueKey('asset-sheet-list'),
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  for (final it in shown)
                    ListTile(
                      key: ValueKey('asset-row-${it.hex}'),
                      title: Text(it.ticker, style: AmbraText.body),
                      subtitle: it.name != null
                          ? Text(it.name!, style: AmbraText.sub)
                          : (it.pasted ? const Text('Unregistered asset · by its id', style: AmbraText.sub) : null),
                      trailing: widget.balanceOf != null ? Text(widget.balanceOf!(it.hex), style: AmbraText.mono) : null,
                      onTap: () {
                        if (it.pasted) widget.onPasted?.call(it.hex);
                        Navigator.pop(context, it.hex);
                      },
                    ),
                  // The empty search holds only BTC and your assets: say how to reach the rest.
                  if (widget.registrySearch && q.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text('Type to search every registry asset, or paste an asset id.', style: AmbraText.sub),
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
