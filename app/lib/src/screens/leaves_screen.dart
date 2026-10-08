import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/config.dart';
import '../data/format.dart';
import '../data/leaf_service.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Developer mode: the leaf rail by name. Join an operator, the leaf balance per
/// asset and state, receive (a request shown and shared), send to a request,
/// settle now, every coin with its dates, and the exit drill. Every refusal is
/// shown as the wallet library says it.
class LeavesScreen extends StatefulWidget {
  const LeavesScreen({super.key});
  @override
  State<LeavesScreen> createState() => _LeavesScreenState();
}

class _LeavesScreenState extends State<LeavesScreen> {
  final svc = LeafService.instance;

  @override
  void initState() {
    super.initState();
    svc.addListener(_changed);
    if (svc.open) svc.refresh();
  }

  @override
  void dispose() {
    svc.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AmbraColors.bg,
      appBar: AppBar(
        backgroundColor: AmbraColors.bg,
        foregroundColor: AmbraColors.txt,
        title: const Text('Leaves', style: AmbraText.title),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('leaves-list'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (!svc.joined) const _JoinCard() else ...[
              _StatusCard(svc: svc),
              const SizedBox(height: 14),
              _BalanceCard(svc: svc),
              const SizedBox(height: 14),
              const _ReceiveCard(),
              const SizedBox(height: 14),
              const _SendCard(),
              const SizedBox(height: 14),
              const _SettleCard(),
              const SizedBox(height: 14),
              _CoinsCard(svc: svc),
              const SizedBox(height: 14),
              const _BoardCard(),
              const SizedBox(height: 14),
              const _RefusalsCard(),
            ],
          ],
        ),
      ),
    );
  }
}

/// A refusal as the library says it.
class RefusalText extends StatelessWidget {
  const RefusalText(this.refusal, {super.key});
  final LeafRefusal refusal;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: SelectableText(
          refusal.message,
          key: const Key('leaf-refusal'),
          style: const TextStyle(color: AmbraColors.red, fontSize: 13),
        ),
      );
}

String _short(String s, [int n = 10]) => s.length <= n * 2 ? s : '${s.substring(0, n)}…${s.substring(s.length - 6)}';

String _amount(String asset, Object? atoms) {
  final l = SeqAssets.labelFor(asset);
  return '${formatAtoms('${atoms ?? '0'}', l.precision)} ${l.ticker}';
}

/// A median time as a date and how far it is from the chain's now.
String _when(Object? t, Object? now) {
  if (t is! num) return 'not yet known';
  final d = DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000, isUtc: true);
  final date = '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)} UTC';
  if (now is! num) return date;
  final s = (t - now).toInt();
  final rel = s >= 0 ? 'in ${_span(s)}' : '${_span(-s)} ago';
  return '$date ($rel)';
}

String _two(int v) => v.toString().padLeft(2, '0');

String _span(int s) {
  if (s < 3600) return '${s ~/ 60} min';
  if (s < 86400) return '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
  return '${s ~/ 86400} d ${(s % 86400) ~/ 3600} h';
}

// ---------------------------------------------------------------------------
// Join
// ---------------------------------------------------------------------------

class _JoinCard extends StatefulWidget {
  const _JoinCard();
  @override
  State<_JoinCard> createState() => _JoinCardState();
}

class _JoinCardState extends State<_JoinCard> {
  final _server = TextEditingController();
  final _node = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  LeafRefusal? _err;
  bool _busy = false;

  Future<void> _join() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await LeafService.instance.join(
        LeafOperator(
          server: _server.text.trim(),
          nodeUrl: _node.text.trim(),
          nodeUser: _user.text.trim().isEmpty ? null : _user.text.trim(),
        ),
        _password.text,
      );
    } catch (e) {
      _err = LeafRefusal.of(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('Join an operator'),
          const SizedBox(height: 8),
          const Text(
              'An operator holds coins of many people in one output on Sequentia, as leaves of a tree. '
              'Each leaf is yours: it pays and receives off the chain with the operator\'s co-signature, '
              'and you can always take it on-chain yourself. Joining pins the operator\'s key and your node\'s chain, '
              'and restores the leaves of this wallet\'s recovery phrase.',
              style: AmbraText.sub),
          const SizedBox(height: 12),
          AmbraField(key: const Key('join-server'), label: 'Operator URL', controller: _server, hint: 'https://host/operator', mono: true),
          const SizedBox(height: 10),
          AmbraField(key: const Key('join-node'), label: 'Node RPC URL', controller: _node, hint: 'https://host/node', mono: true),
          const SizedBox(height: 10),
          AmbraField(key: const Key('join-user'), label: 'Node user (optional)', controller: _user, mono: true),
          const SizedBox(height: 10),
          AmbraField(key: const Key('join-password'), label: 'Node password (optional)', controller: _password, obscure: true),
          const SizedBox(height: 14),
          PrimaryButton(key: const Key('join-go'), label: 'Join', icon: Icons.login, busy: _busy, onPressed: _busy ? null : _join),
          if (_err != null) RefusalText(_err!),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

class _StatusCard extends StatefulWidget {
  const _StatusCard({required this.svc});
  final LeafService svc;
  @override
  State<_StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<_StatusCard> {
  bool _busy = false;
  LeafRefusal? _err;
  String? _note;

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await widget.svc.syncNow();
      final n = arrivals(r['mailbox']).length;
      _note = 'Synced: $n received from the mailbox.';
    } catch (e) {
      _err = LeafRefusal.of(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.svc;
    final sch = s.schedule;
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionLabel('Operator'),
        const SizedBox(height: 8),
        Text(s.operator?.server ?? '', style: AmbraText.mono),
        const SizedBox(height: 4),
        Text(s.open ? 'Open on this phone' : 'Not open', style: AmbraText.sub),
        if (sch != null) ...[
          const SizedBox(height: 4),
          Text('Next sync: ${sch['next_sync_at'] == null ? 'nothing waits' : _when(sch['next_sync_at'], sch['now'])}',
              key: const Key('leaf-next-sync'), style: AmbraText.sub),
          if (sch['why'] != null) Text('${sch['why']}', style: AmbraText.sub),
        ],
        if (s.lastSync != null) Text('Last sync: ${s.lastSync!.toLocal()}', style: AmbraText.sub),
        const SizedBox(height: 12),
        SecondaryButton(key: const Key('leaf-sync'), label: _busy ? 'Syncing…' : 'Sync now', icon: Icons.sync, onPressed: _busy ? null : _sync),
        if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!, key: const Key('leaf-sync-note'), style: AmbraText.sub)),
        if (_err != null) RefusalText(_err!),
        if (_err == null && s.lastError != null) RefusalText(s.lastError!),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Balance
// ---------------------------------------------------------------------------

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.svc});
  final LeafService svc;
  @override
  Widget build(BuildContext context) {
    final b = svc.balance;
    final arca = (b?['arca'] as Map?) ?? const {};
    final onchain = (b?['sequentia_onchain'] as Map?) ?? const {};
    final assets = {...arca.keys, ...onchain.keys}.map((e) => '$e').toList()..sort();
    return AmbraCard(
      key: const Key('leaf-balance'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionLabel('Leaf balance'),
        const SizedBox(height: 8),
        const Text('BTC: none in leaves. A tree on Sequentia holds no BTC; BTC stays on its own chain and on Lightning.',
            style: AmbraText.sub),
        if (assets.isEmpty)
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('No leaves yet.', style: AmbraText.muted)),
        for (final a in assets) ...[
          const SizedBox(height: 10),
          Text(SeqAssets.labelFor(a).ticker, style: AmbraText.body),
          for (final e in ((arca[a] as Map?) ?? const {}).entries)
            Text('${_amount(a, e.value)} ${e.key}', style: AmbraText.mono),
          if (onchain[a] != null) Text('${_amount(a, onchain[a])} on-chain, for boards and exit fees', style: AmbraText.mono),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Receive
// ---------------------------------------------------------------------------

class _ReceiveCard extends StatefulWidget {
  const _ReceiveCard();
  @override
  State<_ReceiveCard> createState() => _ReceiveCardState();
}

class _ReceiveCardState extends State<_ReceiveCard> {
  final _asset = TextEditingController();
  final _amount = TextEditingController();
  String? _request;
  LeafRefusal? _err;
  bool _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _err = null;
      _request = null;
    });
    try {
      final r = await LeafService.instance.run('receive', {
        if (_asset.text.trim().isNotEmpty) 'asset': _asset.text.trim(),
        if (_amount.text.trim().isNotEmpty) 'amount': _amount.text.trim(),
      });
      _request = (r is Map ? r['request'] : null)?.toString() ?? jsonEncode(r);
      await LeafService.instance.refresh();
    } catch (e) {
      _err = LeafRefusal.of(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _share() async {
    final r = _request;
    if (r == null) return;
    try {
      await const MethodChannel('ambra/leaves').invokeMethod('share', {'text': r});
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: r));
    }
  }

  @override
  Widget build(BuildContext context) => AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('Receive'),
          const SizedBox(height: 8),
          AmbraField(key: const Key('recv-asset'), label: 'Asset id (optional)', controller: _asset, mono: true),
          const SizedBox(height: 10),
          AmbraField(key: const Key('recv-amount'), label: 'Amount in atoms (optional)', controller: _amount, mono: true),
          const SizedBox(height: 12),
          PrimaryButton(key: const Key('recv-go'), label: 'Make a request', icon: Icons.qr_code, busy: _busy, onPressed: _busy ? null : _go),
          if (_request != null) ...[
            const SizedBox(height: 14),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(data: _request!, size: 200),
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(_request!, key: const Key('recv-request'), style: AmbraText.mono.copyWith(fontSize: 11)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: SecondaryButton(
                    label: 'Copy',
                    icon: Icons.copy,
                    onPressed: () => Clipboard.setData(ClipboardData(text: _request!))),
              ),
              const SizedBox(width: 10),
              Expanded(child: SecondaryButton(key: const Key('recv-share'), label: 'Share', icon: Icons.share, onPressed: _share)),
            ]),
          ],
          if (_err != null) RefusalText(_err!),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

class _SendCard extends StatefulWidget {
  const _SendCard();
  @override
  State<_SendCard> createState() => _SendCardState();
}

class _SendCardState extends State<_SendCard> {
  final _request = TextEditingController();
  final _amount = TextEditingController();
  final _asset = TextEditingController();
  String? _done;
  LeafRefusal? _err;
  bool _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _err = null;
      _done = null;
    });
    try {
      final r = await LeafService.instance.run('send', {
        'request': _request.text.trim(),
        if (_amount.text.trim().isNotEmpty) 'amount': _amount.text.trim(),
        if (_asset.text.trim().isNotEmpty) 'asset': _asset.text.trim(),
      });
      _done = const JsonEncoder.withIndent(' ').convert(r);
      await LeafService.instance.refresh();
    } catch (e) {
      _err = LeafRefusal.of(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('Send to a request'),
          const SizedBox(height: 8),
          AmbraField(key: const Key('send-request'), label: 'Receive request', controller: _request, mono: true, maxLines: 3),
          const SizedBox(height: 10),
          AmbraField(key: const Key('send-amount'), label: 'Amount in atoms (if the request names none)', controller: _amount, mono: true),
          const SizedBox(height: 10),
          AmbraField(key: const Key('send-asset'), label: 'Asset id (if the request names none)', controller: _asset, mono: true),
          const SizedBox(height: 12),
          PrimaryButton(key: const Key('send-go'), label: 'Send', icon: Icons.north_east, busy: _busy, onPressed: _busy ? null : _go),
          if (_done != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SelectableText(_done!, key: const Key('send-done'), style: AmbraText.mono.copyWith(fontSize: 11)),
            ),
          if (_err != null) RefusalText(_err!),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Settle now
// ---------------------------------------------------------------------------

class _SettleCard extends StatefulWidget {
  const _SettleCard();
  @override
  State<_SettleCard> createState() => _SettleCardState();
}

class _SettleCardState extends State<_SettleCard> {
  List<dynamic>? _quote;
  String? _done;
  LeafRefusal? _err;
  bool _busy = false;

  Future<void> _ask() async {
    setState(() {
      _busy = true;
      _err = null;
      _done = null;
    });
    try {
      final q = await LeafService.instance.run('quote');
      _quote = (q is Map ? q['coins'] as List? : null) ?? const [];
    } catch (e) {
      _err = LeafRefusal.of(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _settle() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await LeafService.instance.run('participate', {'shown': _quote});
      _done = const JsonEncoder.withIndent(' ').convert(r);
      _quote = null;
      await LeafService.instance.refresh();
    } catch (e) {
      _err = LeafRefusal.of(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('Settle now'),
          const SizedBox(height: 8),
          const Text(
              'A coin received off the chain is operator-confirmed until it is refreshed into a leaf of its own in the '
              'operator\'s next round. Settling asks for that refresh now; the fee is shown before anything is signed.',
              style: AmbraText.sub),
          const SizedBox(height: 12),
          SecondaryButton(key: const Key('settle-quote'), label: 'Show the fee', icon: Icons.receipt_long, onPressed: _busy ? null : _ask),
          if (_quote != null) ...[
            const SizedBox(height: 10),
            if (_quote!.isEmpty) const Text('No coin to settle.', style: AmbraText.muted),
            for (final c in _quote!)
              SelectableText(jsonEncode(c), key: const Key('settle-fee'), style: AmbraText.mono.copyWith(fontSize: 11)),
            if (_quote!.isNotEmpty) ...[
              const SizedBox(height: 10),
              PrimaryButton(key: const Key('settle-go'), label: 'Settle at this fee', icon: Icons.check, busy: _busy, onPressed: _busy ? null : _settle),
            ],
          ],
          if (_done != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SelectableText(_done!, key: const Key('settle-done'), style: AmbraText.mono.copyWith(fontSize: 11)),
            ),
          if (_err != null) RefusalText(_err!),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Coins, their dates, and the exit drill
// ---------------------------------------------------------------------------

class _CoinsCard extends StatefulWidget {
  const _CoinsCard({required this.svc});
  final LeafService svc;
  @override
  State<_CoinsCard> createState() => _CoinsCardState();
}

class _CoinsCardState extends State<_CoinsCard> {
  final Map<String, String> _exitSaid = {};
  final Map<String, LeafRefusal> _exitErr = {};
  String? _busy;

  Future<void> _exit(String leaf) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: const Text('Run the exit drill?', style: AmbraText.title),
        content: const Text(
            'This takes the coin on-chain without the operator: its path from the batch is published, and once the '
            'exit delay has run, it is claimed to an address of this wallet. Run it again, or sync, to move it on.',
            style: AmbraText.muted),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(key: const Key('exit-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('Exit')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = leaf;
      _exitErr.remove(leaf);
    });
    try {
      final r = await LeafService.instance.run('exit', {'leaf_id': leaf});
      _exitSaid[leaf] = const JsonEncoder.withIndent(' ').convert(r);
      await LeafService.instance.refresh();
    } catch (e) {
      _exitErr[leaf] = LeafRefusal.of(e);
    }
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final coins = widget.svc.coins;
    final now = widget.svc.schedule?['now'];
    return AmbraCard(
      key: const Key('leaf-coins'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionLabel('Coins and their dates'),
        if (coins.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('No coins yet.', style: AmbraText.muted)),
        for (final c in coins.whereType<Map>()) ...[
          const Divider(color: AmbraColors.line),
          Text('${_amount('${c['asset']}', c['value'])} · ${c['state']} · ${c['kind']}', style: AmbraText.body),
          Text(_short('${c['leaf_id']}'), style: AmbraText.mono.copyWith(fontSize: 11)),
          if ((c['standing'] ?? '') != '' && c['standing'] != c['state']) Text('${c['standing']}', style: AmbraText.sub),
          if (c['refresh_from'] != null) Text('Refresh from ${_when(c['refresh_from'], now)}', style: AmbraText.sub),
          if (c['home_from'] != null) Text('Home from ${_when(c['home_from'], now)}', style: AmbraText.sub),
          if (c['exit_by'] != null) Text('Exit by ${_when(c['exit_by'], now)}', style: AmbraText.sub),
          if ('${c['note'] ?? ''}'.isNotEmpty) Text('${c['note']}', style: AmbraText.sub),
          if (!{'spent', 'exited', 'lost'}.contains(c['state'])) ...[
            const SizedBox(height: 6),
            SecondaryButton(
              key: Key('exit-${c['leaf_id']}'),
              label: _busy == c['leaf_id'] ? 'Exiting…' : (c['state'] == 'exiting' ? 'Exit drill: next step' : 'Exit drill'),
              icon: Icons.logout,
              onPressed: _busy != null ? null : () => _exit('${c['leaf_id']}'),
            ),
          ],
          if (_exitSaid[c['leaf_id']] != null)
            SelectableText(_exitSaid[c['leaf_id']]!, style: AmbraText.mono.copyWith(fontSize: 11)),
          if (_exitErr[c['leaf_id']] != null) RefusalText(_exitErr[c['leaf_id']]!),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Board
// ---------------------------------------------------------------------------

class _BoardCard extends StatefulWidget {
  const _BoardCard();
  @override
  State<_BoardCard> createState() => _BoardCardState();
}

class _BoardCardState extends State<_BoardCard> {
  final _asset = TextEditingController();
  final _amount = TextEditingController();
  String? _address;
  String? _done;
  LeafRefusal? _err;
  bool _busy = false;

  Future<void> _addr() async {
    try {
      final r = await LeafService.instance.run('address');
      setState(() => _address = r is Map ? '${r['address']}' : '$r');
    } catch (e) {
      setState(() => _err = LeafRefusal.of(e));
    }
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _err = null;
      _done = null;
    });
    try {
      final r = await LeafService.instance.run('board', {'asset': _asset.text.trim(), 'amount': _amount.text.trim()});
      _done = const JsonEncoder.withIndent(' ').convert(r);
      await LeafService.instance.refresh();
    } catch (e) {
      _err = LeafRefusal.of(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('Board from on-chain'),
          const SizedBox(height: 8),
          const Text('A board turns an on-chain coin of the leaf wallet into a leaf. Pay the coin to its address first.',
              style: AmbraText.sub),
          const SizedBox(height: 10),
          SecondaryButton(label: 'Show the leaf wallet\'s address', icon: Icons.account_balance_wallet_outlined, onPressed: _addr),
          if (_address != null) SelectableText(_address!, style: AmbraText.mono.copyWith(fontSize: 12)),
          const SizedBox(height: 10),
          AmbraField(label: 'Asset id', controller: _asset, mono: true),
          const SizedBox(height: 10),
          AmbraField(label: 'Amount in atoms', controller: _amount, mono: true),
          const SizedBox(height: 12),
          PrimaryButton(label: 'Board', icon: Icons.upload, busy: _busy, onPressed: _busy ? null : _go),
          if (_done != null) SelectableText(_done!, style: AmbraText.mono.copyWith(fontSize: 11)),
          if (_err != null) RefusalText(_err!),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Refusals
// ---------------------------------------------------------------------------

class _RefusalsCard extends StatefulWidget {
  const _RefusalsCard();
  @override
  State<_RefusalsCard> createState() => _RefusalsCardState();
}

class _RefusalsCardState extends State<_RefusalsCard> {
  List<dynamic>? _rows;
  LeafRefusal? _err;

  Future<void> _load() async {
    try {
      final r = await LeafService.instance.run('refusals');
      setState(() => _rows = (r as List?) ?? const []);
    } catch (e) {
      setState(() => _err = LeafRefusal.of(e));
    }
  }

  @override
  Widget build(BuildContext context) => AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('What the wallet refused'),
          const SizedBox(height: 8),
          SecondaryButton(label: 'Show', icon: Icons.block, onPressed: _load),
          if (_rows != null && _rows!.isEmpty) const Text('Nothing refused.', style: AmbraText.muted),
          for (final r in (_rows ?? const []).whereType<Map>())
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${r['what']}: ${r['reason']}', style: AmbraText.sub),
            ),
          if (_err != null) RefusalText(_err!),
        ]),
      );
}
