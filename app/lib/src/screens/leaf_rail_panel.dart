import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../data/config.dart';
import '../data/format.dart';
import '../data/leaf_rail.dart';
import '../data/leaf_service.dart';
import '../rust/api.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// The swap composer's leaf panel (developer mode), shown in place of the composer's own
/// placement while a leg is on Leaf (see [leafShape] in `data/leaf_rail.dart`). Market,
/// Leaf to Leaf: a take from leaves of the best on-chain order the round can take, and
/// accepting another wallet's in-tree swap offer. Limit, Leaf to Leaf: an in-tree swap
/// offered to another wallet, and its completion. Every check, amount and refusal is the
/// leaf library's ([LeafService.run]); the panel shows its answers before anything is
/// signed.
class LeafRailPanel extends StatefulWidget {
  const LeafRailPanel({
    super.key,
    required this.pay,
    required this.recv,
    required this.payRail,
    required this.recvRail,
    required this.mode,
    required this.payAmount,
    required this.recvAmount,
    required this.amount,
    this.run,
    this.fetchOffers,
  });

  final String? pay;
  final String? recv;
  final SettleRail? payRail;
  final SettleRail? recvRail;
  final String mode;
  final TextEditingController payAmount;
  final TextEditingController recvAmount;

  /// `amt(asset, atoms)`: an amount as the composer names it.
  final String Function(String asset, Object? atoms) amount;

  /// The leaf library (tests replace it).
  final Future<dynamic> Function(String command, Map<String, dynamic> args)? run;

  /// The relay's offers of the pair, both orientations, in the relay's own JSON (tests
  /// replace it).
  final Future<List<Map<String, dynamic>>> Function(String a, String b)? fetchOffers;

  @override
  State<LeafRailPanel> createState() => _LeafRailPanelState();
}

class _LeafRailPanelState extends State<LeafRailPanel> {
  bool _busy = false;
  String? _error;
  String? _note;
  Map<String, dynamic>? _takeQuote;
  Map<String, dynamic>? _takeOrder;
  int? _window;
  Map<String, dynamic>? _offer;
  Map<String, dynamic>? _read;
  String? _readText;
  String? _acceptText;
  final _offerIn = TextEditingController();
  final _acceptIn = TextEditingController();

  Future<dynamic> _run(String cmd, [Map<String, dynamic> args = const {}]) =>
      widget.run != null ? widget.run!(cmd, args) : LeafService.instance.pay(cmd, args);

  Future<List<Map<String, dynamic>>> _offers(String a, String b) async {
    if (widget.fetchOffers != null) return widget.fetchOffers!(a, b);
    Future<List<Map<String, dynamic>>> one(String base, String quote) async {
      try {
        final r = await http.get(Uri.parse('${Backend.seqob}/v1/market/$base/$quote/orderbook'));
        if (r.statusCode != 200) return const [];
        final list = (jsonDecode(r.body)['offers'] as List?) ?? const [];
        final out = <Map<String, dynamic>>[];
        for (final e in list) {
          if (e is! Map) continue;
          final o = Map<String, dynamic>.from(e);
          // The relay is untrusted: only offers whose signature checks are offered.
          bool ok = false;
          try {
            ok = await core.seqobVerifyOffer(offerJson: jsonEncode(offerForVerify(o)));
          } catch (_) {}
          if (ok) out.add(o);
        }
        return out;
      } catch (_) {
        return const [];
      }
    }

    return [...await one(a, b), ...await one(b, a)];
  }

  @override
  void didUpdateWidget(LeafRailPanel old) {
    super.didUpdateWidget(old);
    if (old.pay != widget.pay || old.recv != widget.recv || old.mode != widget.mode || old.payRail != widget.payRail || old.recvRail != widget.recvRail) {
      _takeQuote = null;
      _read = null;
      _error = null;
      _note = null;
    }
  }

  @override
  void dispose() {
    _offerIn.dispose();
    _acceptIn.dispose();
    super.dispose();
  }

  Future<void> _step(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      await f();
    } catch (e) {
      _error = LeafRefusal.of(e).message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// An amount the composer holds, in atoms of `asset` (read at the asset's precision).
  BigInt _atoms(String asset, TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return BigInt.zero;
    return parseAtoms(t, SeqAssets.labelFor(asset).precision) ?? BigInt.zero;
  }

  Widget _rows(List<(String, String)> rows, String key) => Column(
        key: ValueKey(key),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 120, child: Text(k, style: AmbraText.sub)),
                Expanded(child: Text(v, style: AmbraText.body)),
              ]),
            ),
        ],
      );

  Widget _textOut(String text, String key) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SelectableText(text, key: ValueKey(key), style: AmbraText.mono.copyWith(fontSize: 11), maxLines: 6),
        const SizedBox(height: 6),
        SecondaryButton(label: 'Copy', icon: Icons.copy, onPressed: () => Clipboard.setData(ClipboardData(text: text))),
      ]);

  @override
  Widget build(BuildContext context) {
    final shape = leafShape(pay: widget.pay, recv: widget.recv, payRail: widget.payRail, recvRail: widget.recvRail, mode: widget.mode);
    final children = <Widget>[
      const SectionLabel('Leaves'),
      const SizedBox(height: 6),
    ];
    switch (shape.kind) {
      case LeafShapeKind.none:
        return const SizedBox.shrink();
      case LeafShapeKind.pending:
        children.add(const Text('Choose how the other side settles.', style: AmbraText.sub));
      case LeafShapeKind.refused:
        children.add(Text(shape.why ?? '', key: const ValueKey('leafRefused'), style: const TextStyle(color: AmbraColors.red)));
      case LeafShapeKind.take:
        children.addAll(_take());
        children.add(const SizedBox(height: 18));
        children.addAll(_accept());
      case LeafShapeKind.swap:
        children.addAll(_offerUi());
    }
    if (_error != null) {
      children.addAll([const SizedBox(height: 10), Text(_error!, key: const ValueKey('leafError'), style: const TextStyle(color: AmbraColors.red))]);
    }
    if (_note != null) {
      children.addAll([const SizedBox(height: 10), Text(_note!, key: const ValueKey('leafNote'), style: const TextStyle(color: AmbraColors.green))]);
    }
    return AmbraCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children));
  }

  // ---- a take from leaves ----
  List<Widget> _take() {
    final pay = widget.pay!, recv = widget.recv!;
    if (_takeQuote == null) {
      return [
        const Text('Fills the best on-chain order the operator\'s round can take. Enter what you receive.', style: AmbraText.sub),
        const SizedBox(height: 10),
        PrimaryButton(
          key: const ValueKey('leafTakeReview'),
          label: 'Review the take',
          busy: _busy,
          onPressed: () => _step(() async {
            final amount = _atoms(recv, widget.recvAmount);
            if (amount <= BigInt.zero) throw Exception('Enter how much you receive.');
            final best = bestLeafOrder(await _offers(recv, pay), pay: pay, recv: recv, amount: amount);
            if (best == null) throw Exception('No on-chain order rests that the operator\'s round can take.');
            final q = Map<String, dynamic>.from(await _run('take_quote', {'order': best, 'amount': '$amount'}) as Map);
            final info = Map<String, dynamic>.from((await _run('info')) as Map);
            final fills = ((info['server_info'] as Map?)?['fills'] as Map?) ?? const {};
            _takeOrder = best;
            _takeQuote = q;
            _window = (fills['forfeit_window_seconds'] as num?)?.toInt();
          }),
        ),
      ];
    }
    final q = _takeQuote!;
    return [
      _rows(takeRows(q, widget.amount, windowSeconds: _window), 'leafTakeRows'),
      const Text(
          'The fill is final once the round\'s block is certified and its Bitcoin anchor buried. The take goes ahead only on what is shown.',
          style: AmbraText.sub),
      const SizedBox(height: 10),
      PrimaryButton(
        key: const ValueKey('leafTakeGo'),
        label: 'Take it',
        busy: _busy,
        onPressed: () => _step(() async {
          final r = Map<String, dynamic>.from(await _run('take', {'order': _takeOrder, 'amount': q['filled'], 'shown': q}) as Map);
          _takeQuote = null;
          _note = 'Taken (${'${r['take']}'.substring(0, 12)}…): the forfeit goes in at the next sync once the operator builds the round; the leaf comes once the round is final.';
          LeafService.instance.syncNow(by: 'take').ignore();
        }),
      ),
      const SizedBox(height: 8),
      SecondaryButton(label: 'Cancel', onPressed: () => setState(() => _takeQuote = null)),
    ];
  }

  // ---- accepting another wallet's offer ----
  List<Widget> _accept() {
    if (_read == null) {
      return [
        AmbraField(key: const ValueKey('leafOfferIn'), label: 'Accept another wallet\'s swap offer', controller: _offerIn, hint: 'Paste the offer', mono: true, maxLines: 3),
        const SizedBox(height: 8),
        SecondaryButton(
          label: 'Read the offer',
          icon: Icons.search,
          onPressed: _busy
              ? null
              : () => _step(() async {
                    final t = _offerIn.text.trim();
                    if (t.isEmpty) throw Exception('Paste the offer first.');
                    _read = Map<String, dynamic>.from(await _run('swap_read', {'offer': t}) as Map);
                    _readText = t;
                  }),
        ),
        if (_acceptText != null) ...[
          const SizedBox(height: 10),
          const Text('Send this acceptance back to the wallet that offered: it completes the swap.', style: AmbraText.sub),
          _textOut(_acceptText!, 'leafAcceptText'),
        ],
      ];
    }
    return [
      _rows(swapReadRows(_read!, widget.amount), 'leafReadRows'),
      PrimaryButton(
        key: const ValueKey('leafAcceptGo'),
        label: 'Accept',
        busy: _busy,
        onPressed: () => _step(() async {
          final a = Map<String, dynamic>.from(await _run('swap_accept', {'offer': _readText, 'shown': _read}) as Map);
          _acceptText = '${a['accept']}';
          _read = null;
          _offerIn.clear();
        }),
      ),
      const SizedBox(height: 8),
      SecondaryButton(label: 'Cancel', onPressed: () => setState(() => _read = null)),
    ];
  }

  // ---- an in-tree swap offered, then completed ----
  List<Widget> _offerUi() {
    final pay = widget.pay!, recv = widget.recv!;
    return [
      const Text(
          'Offers the two amounts above to another wallet that holds leaves of this operator. Nothing is signed until it accepts and you complete it.',
          style: AmbraText.sub),
      const SizedBox(height: 10),
      PrimaryButton(
        key: const ValueKey('leafOffer'),
        label: 'Make the offer',
        busy: _busy,
        onPressed: () => _step(() async {
          final give = _atoms(pay, widget.payAmount), want = _atoms(recv, widget.recvAmount);
          if (give <= BigInt.zero || want <= BigInt.zero) throw Exception('Enter both amounts: what you give and what you want.');
          _offer = Map<String, dynamic>.from(
              await _run('swap_offer', {'give_asset': pay, 'give': '$give', 'want_asset': recv, 'want': '$want'}) as Map);
        }),
      ),
      if (_offer != null) ...[
        const SizedBox(height: 10),
        _rows(swapOfferRows(_offer!, widget.amount), 'leafOfferRows'),
        const Text('Give this offer to the other wallet; paste its acceptance below.', style: AmbraText.sub),
        _textOut('${_offer!['offer']}', 'leafOfferText'),
      ],
      const SizedBox(height: 14),
      AmbraField(key: const ValueKey('leafAcceptIn'), label: 'Complete a swap you offered', controller: _acceptIn, hint: 'Paste the acceptance', mono: true, maxLines: 3),
      const SizedBox(height: 8),
      if (_offer != null) _rows(swapOfferRows(_offer!, widget.amount), 'leafCompleteRows'),
      PrimaryButton(
        key: const ValueKey('leafCompleteGo'),
        label: 'Complete the swap',
        busy: _busy,
        onPressed: () => _step(() async {
          final t = _acceptIn.text.trim();
          if (t.isEmpty) throw Exception('Paste the acceptance first.');
          final d = Map<String, dynamic>.from(await _run('swap_complete', {'accept': t}) as Map);
          _note = 'Swap ${'${d['swap']}'.substring(0, 12)}… done: both assets moved in one reassignment.';
          _offer = null;
          _acceptIn.clear();
          LeafService.instance.refresh().ignore();
        }),
      ),
    ];
  }
}
