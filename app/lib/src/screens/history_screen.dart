import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../rust/api.dart' as core;
import '../data/ark_btc_service.dart';
import '../data/btc_state.dart';
import '../data/default_words.dart';
import '../data/config.dart';
import '../data/dev_mode.dart';
import '../data/format.dart';
import '../data/leaf_service.dart';
import '../data/lightning_to_ark.dart';
import '../data/price_service.dart';
import '../data/speed_up_service.dart';
import '../data/user_trade.dart';
import '../data/wallet_cache.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'rescue_screen.dart';
import 'sign_screen.dart';
import 'user_composer.dart' show appTradeEngine;

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key, this.isActive = false});
  final bool isActive;
  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  List<core.TxRow>? _txs;
  String? _error;
  List<OampTransfer> _oamp = const []; // locally-tracked restricted transfers
  List<Map<String, dynamic>> _ln = const []; // Lightning history (written by the LN cards)
  List<Map<String, dynamic>> _trades = const []; // the Swap tab's trades, one row each
  StreamSubscription<void>? _tradesChanged;
  String? _tradesTag;

  @override
  void initState() {
    super.initState();
    _loadCached(); // show last-known history at once, refresh below
    _load(); // eager: load at launch (also reloads on activation)
    // At launch History loads before the leaf wallet opens; once it is open the list is read
    // again, so the wallet's own boards are known and left out.
    LeafService.instance.addListener(_onLeaves);
    _loadSidecars(); // restricted-transfer tracker + Lightning history
    _loadTrades();
    // While History is there, pending payments are looked up again every half minute.
    _paymentsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (widget.isActive) unawaited(_refreshPayments());
    });
  }

  @override
  void dispose() {
    LeafService.instance.removeListener(_onLeaves);
    _paymentsTimer?.cancel();
    _tradesChanged?.cancel();
    super.dispose();
  }

  /// The trades of the Swap tab's composer (default mode's and a connected site's), read from its
  /// engine and again whenever one changes: each is one row here, however many legs it has.
  Future<void> _loadTrades() async {
    final tag = DevMode.instance.tag ?? 'default';
    final engine = appTradeEngine(walletTag: tag);
    if (_tradesTag != tag) {
      _tradesChanged?.cancel();
      _tradesTag = tag;
      _tradesChanged = engine.changes.listen((_) => _loadTrades());
    }
    final r = await engine.records();
    if (mounted) setState(() => _trades = tradeHistoryRows(r));
  }

  Future<void> _loadCached() async {
    var txs = await WalletCache.loadTxs();
    if (txs != null && !DevMode.instance.on) txs = withoutBoards(txs, LeafService.instance.boardTxids);
    if (txs != null && mounted && _txs == null) setState(() => _txs = txs);
  }

  /// Load (then re-derive) the restricted-transfer tracker and the Lightning
  /// history. Both fail soft to whatever is on disk.
  Future<void> _loadSidecars() async {
    final xfers = await WalletCache.loadOampTransfers();
    final ln = await WalletCache.loadLnHistory();
    if (mounted) setState(() { _oamp = xfers; _ln = ln; });
    await _refreshOamp();
    await _refreshPayments();
  }

  Timer? _paymentsTimer;

  /// Payments as they move: BTC arriving at the wallet's latest addresses is added as soon as
  /// the Bitcoin network has it (pending until its block), and every pending payment with a
  /// transaction is looked up and marked done once confirmed. Fails soft to what is on disk.
  Future<void> _refreshPayments() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m != null) {
        final next = BtcState.instance.unifiedNext;
        final mine = <String>{};
        for (var i = next > 4 ? next - 4 : 0; i <= next; i++) {
          mine.add((await core.receiveAddressAt(mnemonic: m, index: i, confidential: false)).address);
        }
        for (final a in mine) {
          final r = await http.get(Uri.parse('${Backend.testnet4}/address/$a/txs'), headers: Backend.authHeaders)
              .timeout(const Duration(seconds: 20));
          if (r.statusCode != 200) continue;
          for (final e in incomingBtc(jsonDecode(r.body), mine)) {
            await WalletCache.addPayment(e);
          }
        }
      }
    } catch (_) {/* transient: what is on disk stays */}
    // BTC another wallet paid into the ark (to its address, or an invoice of the receive code).
    try {
      final own = {
        ...await LightningToArk.instance.ownInvoices(),
        for (final t in await appTradeEngine(walletTag: DevMode.instance.tag ?? 'default').records())
          if (t['hash'] is String) t['hash'] as String,
      };
      for (final e in arkReceipts(await ArkBtcService.instance.history(), own)) {
        await WalletCache.addPayment(e);
      }
    } catch (_) {}
    for (final e in await WalletCache.loadLnHistory()) {
      // A payment out of the ark its payee held: taken, or come back, since it left.
      final hash = e['hash'];
      if (e['pending'] == true && hash is String) {
        final st = await ArkBtcService.instance.payState(hash);
        if (st == 'complete' || st == 'came-back') await WalletCache.settleHeld(hash, paid: st == 'complete');
        continue;
      }
      final txid = e['txid'];
      if (e['pending'] != true || txid is! String) continue;
      try {
        final base = e['chain'] == 'seq' ? Backend.esplora : Backend.testnet4;
        final r = await http.get(Uri.parse('$base/tx/$txid/status'), headers: Backend.authHeaders)
            .timeout(const Duration(seconds: 20));
        if (r.statusCode == 200 && (jsonDecode(r.body) as Map)['confirmed'] == true) await WalletCache.settlePayment(txid);
      } catch (_) {}
    }
    final ln = await WalletCache.loadLnHistory();
    if (mounted) setState(() => _ln = ln);
  }

  /// Re-check every tracked restricted transfer against the Sequentia explorer
  /// and the Bitcoin anchor. Reorg-aware: a confirmed transfer reverts to
  /// pending if its anchoring Bitcoin block (and so the Sequentia block) is
  /// orphaned (anchoring supremacy) — never sticky, always re-derived live.
  Future<void> _refreshOamp() async {
    final xfers = await WalletCache.loadOampTransfers();
    if (xfers.isEmpty) {
      if (mounted) setState(() => _oamp = xfers);
      return;
    }
    var changed = false;
    await Future.wait(xfers.map((x) async {
      try {
        final r = await http
            .get(Uri.parse('${Backend.esplora}/tx/${x.txid}/status'), headers: Backend.authHeaders)
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) return;
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final confirmed = j['confirmed'] == true;
        if (confirmed != x.confirmed) {
          x.confirmed = confirmed;
          changed = true;
          if (!confirmed) x.anchorDepth = null; // dropped back to the mempool
        }
        final bh = j['block_hash'];
        if (confirmed && bh is String && bh.isNotEmpty && bh != x.blockHash) {
          x.blockHash = bh;
          changed = true;
        }
        if (x.confirmed && x.blockHash != null) {
          final ar = await http
              .get(Uri.parse(Backend.anchor(x.blockHash!)), headers: Backend.authHeaders)
              .timeout(const Duration(seconds: 20));
          if (ar.statusCode != 200) return;
          final aj = jsonDecode(ar.body) as Map<String, dynamic>;
          final ah = aj['anchorheight'];
          final anchorH = ah is num ? ah.toInt() : int.tryParse('$ah');
          if (anchorH == null) return;
          final tr = await http
              .get(Uri.parse('${Backend.testnet4}/blocks/tip/height'), headers: Backend.authHeaders)
              .timeout(const Duration(seconds: 20));
          if (tr.statusCode != 200) return;
          final tip = int.tryParse(tr.body.trim());
          if (tip == null) return;
          final d = tip - anchorH + 1;
          final depth = d < 0 ? 0 : d;
          if (depth != x.anchorDepth) {
            x.anchorDepth = depth;
            changed = true;
          }
        }
      } catch (_) {/* transient — leave this entry as last known, don't drop it */}
    }));
    if (changed) await WalletCache.saveOampTransfers(xfers);
    if (mounted) setState(() => _oamp = xfers);
  }

  @override
  void didUpdateWidget(HistoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-pull when the tab is opened so newly-confirmed/received txs show up
    // without restarting the app.
    if (widget.isActive && !oldWidget.isActive) {
      _load();
      _loadSidecars();
      _loadTrades();
    }
  }

  bool _loadedWithLeaves = false;
  void _onLeaves() {
    if (_loadedWithLeaves || !LeafService.instance.open || !mounted) return;
    _loadedWithLeaves = true;
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      var txs = await core.walletTransactions(mnemonic: m, esploraUrl: Backend.esplora);
      // A board moves the wallet's own coins into the instant part: nothing left the wallet,
      // so default mode lists no payment for it (developer mode keeps every transaction).
      if (!DevMode.instance.on) {
        final boards = await LeafService.instance.boardTransactions();
        txs = withoutBoards(txs, boards);
      }
      txs.sort((a, b) {
        if (a.height == null && b.height == null) return 0;
        if (a.height == null) return -1; // unconfirmed first
        if (b.height == null) return 1;
        return b.height!.compareTo(a.height!);
      });
      WalletCache.saveTxs(txs); // persist for the next launch
      if (mounted) {
        setState(() {
          _txs = txs;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _txs == null) setState(() => _error = friendlyError(e)); // keep last-good on reload
    }
  }

  @override
  Widget build(BuildContext context) {
    final txs = _txs;
    return RefreshIndicator(
      onRefresh: () async {
        await _load();
        await _loadTrades();
        await _refreshOamp();
        final ln = await WalletCache.loadLnHistory();
        if (mounted) setState(() => _ln = ln);
      },
      color: AmbraColors.amber,
      backgroundColor: AmbraColors.panel,
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
        const Text('History', style: AmbraText.h1),
        const SizedBox(height: 16),
        if (_trades.isNotEmpty) ...[
          AmbraCard(
            key: const ValueKey('historyTrades'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(children: [for (final r in _trades) _TradeRow(rec: r)]),
          ),
          const SizedBox(height: 16),
        ],
        if (_error != null)
          AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red)))
        else if (txs == null)
          const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
        else if (txs.isEmpty)
          const AmbraCard(child: Text('No transactions yet.', style: AmbraText.muted))
        else
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(children: [for (final t in txs) _TxRowView(tx: t, onRescued: () => _load())]),
          ),
        if (_ln.isNotEmpty) ...[
          const SizedBox(height: 22),
          // Default mode names no way a payment travelled.
          SectionLabel(DevMode.instance.on ? 'Lightning' : 'Payments'),
          const SizedBox(height: 8),
          _LnHistoryCard(entries: _ln),
        ],
        if (_oamp.isNotEmpty) ...[
          const SizedBox(height: 22),
          const SectionLabel('Restricted transfers (OpenAMP)'),
          const SizedBox(height: 8),
          _OampHistoryCard(xfers: _oamp),
        ],
        const SizedBox(height: 22),
        SecondaryButton(
          label: 'Sign an OpenAMP request',
          icon: Icons.draw,
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SignScreen())),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Restricted-transfer (OpenAMP) tracker — locally-tracked sent transfers, with
// a pending/confirmed chip, an explorer link, and a Bitcoin anchor-depth chip.
// openampd has no per-holder history endpoint, so the wallet follows its OWN
// sends until confirmed. Nothing is labelled final at 0-conf.
// ---------------------------------------------------------------------------
class _OampHistoryCard extends StatelessWidget {
  const _OampHistoryCard({required this.xfers});
  final List<OampTransfer> xfers;

  @override
  Widget build(BuildContext context) {
    final rows = xfers.reversed.toList();
    return AmbraCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(children: [for (final x in rows) _OampRow(x: x)]),
    );
  }
}

class _OampRow extends StatelessWidget {
  const _OampRow({required this.x});
  final OampTransfer x;

  Future<void> _open(BuildContext context) async {
    final url = Uri.parse(Backend.explorerTx(x.txid));
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {/* fall through to copy */}
    if (context.mounted) {
      Clipboard.setData(ClipboardData(text: url.toString()));
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack('Explorer link copied'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = !x.confirmed;
    final when = DateTime.fromMillisecondsSinceEpoch(x.time).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${when.year}-${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)}';
    final aidShort = x.recipientAid.length > 10 ? '${x.recipientAid.substring(0, 10)}…' : x.recipientAid;
    final status = pending
        ? 'pending, not final at 0-conf'
        : (x.anchorDepth != null ? 'Bitcoin anchor depth ${x.anchorDepth}' : 'confirmed, anchor depth pending');

    return InkWell(
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          _Badge(
            text: pending ? 'PENDING' : 'CONFIRMED',
            fg: pending ? AmbraColors.amber2 : AmbraColors.green,
            bg: pending ? const Color(0xFF241C0A) : const Color(0xFF10241A),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x.txid.substring(0, 12)}…', style: AmbraText.mono.copyWith(fontSize: 12)),
              const SizedBox(height: 3),
              Text('$ts · to $aidShort', style: AmbraText.sub, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(status, style: AmbraText.sub.copyWith(color: pending ? AmbraColors.amber2 : AmbraColors.dim)),
            ]),
          ),
          const SizedBox(width: 10),
          Text('${formatAtoms(x.atoms, x.precision)} ${x.ticker}',
              style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontWeight: FontWeight.w700, fontSize: 14)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lightning history — payments/receives/settles written by the LN cards. This
// tab only READS the shared record; it renders defensively (any missing field
// degrades gracefully). Only the pure-LN rail is instant + final.
// ---------------------------------------------------------------------------
class _LnHistoryCard extends StatelessWidget {
  const _LnHistoryCard({required this.entries});
  final List<Map<String, dynamic>> entries;

  @override
  Widget build(BuildContext context) {
    // Newest first when a `time` field is present; otherwise keep insertion order.
    final rows = List<Map<String, dynamic>>.from(entries);
    rows.sort((a, b) {
      final ta = a['time'] is num ? (a['time'] as num).toInt() : 0;
      final tb = b['time'] is num ? (b['time'] as num).toInt() : 0;
      return tb.compareTo(ta);
    });
    return AmbraCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(children: [for (final e in rows) _LnRow(entry: e)]),
    );
  }
}

class _LnRow extends StatelessWidget {
  const _LnRow({required this.entry});
  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final kind = '${entry['kind'] ?? 'payment'}'.toLowerCase();
    final rail = entry['rail'] is String ? entry['rail'] as String : 'lightning';
    final pending = entry['pending'] == true;
    final incoming = kind == 'receive' || kind == 'received' || kind == 'invoice' || kind == 'settle';
    final badge = DevMode.instance.on && rail == 'lightning' ? (incoming ? 'LN IN' : 'LN OUT') : (incoming ? 'IN' : 'OUT');
    final color = incoming ? AmbraColors.green : AmbraColors.amber2;
    final bg = incoming ? const Color(0xFF10241A) : const Color(0xFF241C0A);

    // Amount: prefer explicit atoms + ticker, else msat, else omit.
    String amount = '';
    final ticker = entry['ticker'] is String ? entry['ticker'] as String : '';
    if (entry['atoms'] != null && ticker.isNotEmpty) {
      final prec = entry['precision'] is num ? (entry['precision'] as num).toInt() : 8;
      amount = '${formatAtoms('${entry['atoms']}', prec)} $ticker';
    } else if (entry['amount_msat'] != null) {
      final msat = BigInt.tryParse('${entry['amount_msat']}') ?? BigInt.zero;
      amount = '${(msat ~/ BigInt.from(1000))} sat';
    }

    final desc = entry['description'] is String && (entry['description'] as String).isNotEmpty
        ? entry['description'] as String
        : (DevMode.instance.on && rail == 'lightning'
            ? (incoming ? 'Lightning invoice' : 'Lightning payment')
            : (incoming ? 'Received' : 'Sent'));
    final t = entry['time'] is num ? (entry['time'] as num).toInt() : 0;
    String sub = desc;
    if (t > 0) {
      final w = DateTime.fromMillisecondsSinceEpoch(t).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      sub = '$desc · ${w.year}-${two(w.month)}-${two(w.day)} ${two(w.hour)}:${two(w.minute)}';
    }
    final returned = entry['returned'] == true;
    if (pending) {
      sub = '$sub · ${entry['chain'] == 'btc' ? 'Waiting for a Bitcoin block' : (entry['hash'] != null ? DefaultWords.onItsWay : 'Pending')}';
    }
    if (returned) sub = '$sub · ${DefaultWords.cameBack}';
    final title = returned ? DefaultWords.notPaid : DevMode.instance.on
        ? (rail == 'lightning'
            ? (incoming ? 'Received over Lightning' : 'Lightning payment')
            : '${incoming ? 'Received' : 'Sent'} · ${const {'btc': 'Bitcoin chain', 'ark': 'Bitcoin ark', 'tree': 'in the tree', 'address': 'out to an address'}[rail] ?? rail}')
        : (incoming ? 'Received' : 'Sent');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        _Badge(text: badge, fg: color, bg: bg),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 3),
            Text(sub, style: AmbraText.sub, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (amount.isNotEmpty) ...[
          const SizedBox(width: 10),
          Text('${incoming ? '+' : '-'}$amount',
              style: AmbraText.mono.copyWith(color: color, fontWeight: FontWeight.w700, fontSize: 14)),
        ],
      ]),
    );
  }
}

/// The Swap tab's trades as History lists them, newest first: every trade that was made (one
/// whose step did not answer while it is looked for), not one still being confirmed.
List<Map<String, dynamic>> tradeHistoryRows(List<Map<String, dynamic>> records) {
  int at(Map r) => ((r['sentAt'] ?? r['at']) as num?)?.toInt() ?? 0;
  final rows = [
    for (final r in records)
      if (r['ticket'] is Map && (r['state'] != 'confirming' || r['uncertain'] == true) && r['state'] != 'failed') r,
  ]..sort((a, b) => at(b).compareTo(at(a)));
  return rows;
}

/// One trade's row (docs/DEFAULT_MODE.md "History"): "Swapped `pay` for `get`", then the time and,
/// while it is not settled, its status; on the right "-`pay`" and "+`get`", and the fee when there
/// was one. A trade returned moved nothing: no amounts, its status says so.
class TradeHistoryLine {
  TradeHistoryLine(Map rec, {required String Function(String asset, BigInt atoms) fmt, int? nowMs}) {
    final t = rec['ticket'] as Map;
    final pay = '${t['payAsset']}', get = '${t['receiveAsset']}';
    final inA = BigInt.tryParse('${t['amountIn']}') ?? BigInt.zero, outA = BigInt.tryParse('${t['amountOut']}') ?? BigInt.zero;
    title = 'Swapped ${fmt(pay, inA)} for ${fmt(get, outA)}';
    final st = rec['state'];
    returned = st == 'returned';
    status = st == 'settled' ? null : (tradeStateWord(rec, nowMs ?? DateTime.now().millisecondsSinceEpoch) ?? UserWords.returned);
    if (returned && ((rec['feesPaid'] as List?) ?? const []).isNotEmpty) {
      status = UserWords.returnedFees([for (final f in rec['feesPaid'] as List) fmt('${(f as Map)['asset']}', BigInt.parse('${f['atoms']}'))].join(' and '));
    }
    minus = returned ? null : '-${fmt(pay, inA)}';
    plus = returned ? null : '+${fmt(get, outA)}';
    final fees = <String, BigInt>{};
    for (final f in (t['fees'] as List?) ?? const []) {
      final a = BigInt.tryParse('${(f as Map)['atoms']}') ?? BigInt.zero;
      if (a > BigInt.zero) fees['${f['asset']}'] = (fees['${f['asset']}'] ?? BigInt.zero) + a;
    }
    fee = returned || fees.isEmpty ? null : 'fee ${[for (final e in fees.entries) fmt(e.key, e.value)].join(' + ')}';
    final ms = ((rec['sentAt'] ?? rec['at']) as num?)?.toInt() ?? 0;
    final w = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    time = ms > 0 ? '${w.year}-${two(w.month)}-${two(w.day)} ${two(w.hour)}:${two(w.minute)}' : '';
  }
  late final String title, time;
  late final String? status, minus, plus, fee;
  late final bool returned;
}

String _tradeAmt(String asset, BigInt atoms) => asset == kUserBtc
    ? '${formatAtoms('$atoms', 8)} BTC'
    : '${formatAtoms('$atoms', SeqAssets.labelFor(asset).precision)} ${SeqAssets.labelFor(asset).ticker}';

class _TradeRow extends StatelessWidget {
  const _TradeRow({required this.rec});
  final Map<String, dynamic> rec;

  @override
  Widget build(BuildContext context) {
    final l = TradeHistoryLine(rec, fmt: _tradeAmt);
    final small = [if (l.time.isNotEmpty) l.time, ?l.status].join(' · ');
    return Padding(
      key: ValueKey('historyTrade-${rec['id']}'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Badge(text: 'SWAP', fg: AmbraColors.blue, bg: Color(0xFF0D1F2A)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.title, style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 3),
            Text(small, style: AmbraText.sub),
          ]),
        ),
        if (l.minus != null) ...[
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(l.minus!, style: AmbraText.mono.copyWith(color: AmbraColors.amber2, fontSize: 13)),
            Text(l.plus!, style: AmbraText.mono.copyWith(color: AmbraColors.green, fontSize: 13)),
            if (l.fee != null) Text(l.fee!, style: AmbraText.sub.copyWith(fontSize: 11)),
          ]),
        ],
      ]),
    );
  }
}

class _TxRowView extends StatelessWidget {
  const _TxRowView({required this.tx, required this.onRescued});
  final core.TxRow tx;
  final VoidCallback onRescued;

  core.AssetDelta? _top() {
    core.AssetDelta? top;
    BigInt best = BigInt.from(-1);
    for (final d in tx.deltas) {
      final v = (BigInt.tryParse(d.atoms) ?? BigInt.zero).abs();
      if (v > best) {
        best = v;
        top = d;
      }
    }
    return top;
  }

  @override
  Widget build(BuildContext context) {
    final (fg, bg, text) = _badgeFor(tx.kind);
    final top = _top();
    String amount = '';
    Color amountColor = AmbraColors.dim;
    final swap = tx.kind == 'swap' ? swapLine(tx.deltas) : null;
    if (swap != null) {
      amount = swap;
      amountColor = AmbraColors.txt;
    } else if (top != null) {
      final label = SeqAssets.labelFor(top.assetId);
      final atoms = BigInt.tryParse(top.atoms) ?? BigInt.zero;
      final neg = atoms.isNegative;
      final formatted = formatAtoms(atoms.toString(), label.precision);
      amount = '${neg ? '' : '+'}$formatted ${label.ticker}';
      amountColor = neg ? AmbraColors.amber2 : AmbraColors.green;
    }
    final when = tx.height == null
        ? (!DevMode.instance.on && SpeedUpService.instance.isSpedUp(tx.txid) ? SpeedUpService.spedUp : 'unconfirmed')
        : 'block ${tx.height}';

    return InkWell(
      onTap: () async {
        final rescuedTxid = await showTxDetail(context, tx);
        if (rescuedTxid != null && context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Rescue broadcast · ${rescuedTxid.substring(0, 16)}…')));
          onRescued();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          _Badge(text: text, fg: fg, bg: bg),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${tx.txid.substring(0, 12)}…', style: AmbraText.mono.copyWith(fontSize: 12)),
              const SizedBox(height: 3),
              Text(when, style: AmbraText.sub),
            ]),
          ),
          const SizedBox(width: 10),
          Text(amount,
              style: AmbraText.mono.copyWith(color: amountColor, fontWeight: FontWeight.w700, fontSize: 14)),
        ]),
      ),
    );
  }
}

/// A swap's two legs in one line, "−paid A → +got B": the asset that left the wallet (the largest
/// outflow) and the one that came in (the largest inflow). Null when either leg is missing.
String? swapLine(List<core.AssetDelta> deltas) {
  core.AssetDelta? out, inn;
  for (final d in deltas) {
    final v = BigInt.tryParse(d.atoms) ?? BigInt.zero;
    if (v.isNegative && (out == null || v < BigInt.parse(out.atoms))) out = d;
    if (v > BigInt.zero && (inn == null || v > BigInt.parse(inn.atoms))) inn = d;
  }
  if (out == null || inn == null) return null;
  String leg(core.AssetDelta d) {
    final l = SeqAssets.labelFor(d.assetId);
    return '${formatAtoms(d.atoms, l.precision)} ${l.ticker}';
  }

  return '${leg(out)} → +${leg(inn)}';
}

(Color, Color, String) _badgeFor(String kind) {
  switch (kind) {
    case 'incoming':
      return (AmbraColors.green, const Color(0xFF10241A), 'IN');
    case 'outgoing':
      return (AmbraColors.amber2, const Color(0xFF241C0A), 'OUT');
    case 'burn':
      return (AmbraColors.amber2, const Color(0xFF241C0A), 'BURN');
    case 'swap':
      return (AmbraColors.blue, const Color(0xFF0D1F2A), 'SWAP');
    case 'issuance':
    case 'reissuance':
      return (AmbraColors.blue, const Color(0xFF0D1F2A), 'ISSUE');
    default:
      return (AmbraColors.dim, AmbraColors.panelDeep, kind.toUpperCase());
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.fg, required this.bg});
  final String text;
  final Color fg;
  final Color bg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: fg.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
      );
}

// ---------------------------------------------------------------------------
// Transaction detail — full breakdown + explorer link, opened on tap.
// Returns a txid if a rescue was broadcast from here (caller refreshes).
// ---------------------------------------------------------------------------
Future<String?> showTxDetail(BuildContext context, core.TxRow tx) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => _TxDetailSheet(tx: tx),
  );
}

String _kindTitle(String kind) {
  switch (kind) {
    case 'incoming':
      return 'Received';
    case 'outgoing':
      return 'Sent';
    case 'issuance':
      return 'Asset issuance';
    case 'reissuance':
      return 'Asset reissuance';
    case 'burn':
      return 'Burn';
    case 'redeposit':
      return 'Internal transfer';
    case 'swap':
      return 'Swap';
    default:
      return 'Transaction';
  }
}

/// The network fee rendered in its REAL asset (Sequentia's any-asset fee market),
/// not a hardcoded "tSEQ". An empty fee_asset (older cached rows) falls back to
/// the policy asset.
String _feeText(core.TxRow tx) {
  final feeLabel = SeqAssets.labelFor(tx.feeAsset.isEmpty ? SeqAssets.policy : tx.feeAsset);
  return '${formatAtoms(tx.fee.toString(), feeLabel.precision)} ${feeLabel.ticker}';
}

String _fmtTime(BigInt? ts) {
  if (ts == null) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _TxDetailSheet extends StatelessWidget {
  const _TxDetailSheet({required this.tx});
  final core.TxRow tx;

  Future<void> _openExplorer(BuildContext context) async {
    final url = Uri.parse(Backend.explorerTx(tx.txid));
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {/* no browser / blocked — fall through to copy */}
    if (context.mounted) {
      Clipboard.setData(ClipboardData(text: url.toString()));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Couldn\'t open a browser; explorer link copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final (fg, bg, badge) = _badgeFor(tx.kind);
    final settled = tx.height != null;
    final showFee = tx.fee > BigInt.zero &&
        (tx.kind == 'outgoing' || tx.kind == 'burn' || tx.kind == 'issuance' || tx.kind == 'reissuance');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              _Badge(text: badge, fg: fg, bg: bg),
              const SizedBox(width: 12),
              Text(_kindTitle(tx.kind), style: AmbraText.h1),
            ]),
            const SizedBox(height: 18),
            AmbraCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(children: [
                _DetailRow('Status', settled ? 'Settled · block ${tx.height} (anchor-bound to Bitcoin)' : 'Pending; not yet in a block'),
                _DetailRow('Date', _fmtTime(tx.timestamp)),
                _DetailRow('Network', 'sequentia-testnet'),
                if (showFee) _DetailRow('Network fee', _feeText(tx)),
              ]),
            ),
            const SizedBox(height: 14),
            const SectionLabel('Amount'),
            const SizedBox(height: 8),
            AmbraCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(children: [for (final d in tx.deltas) _DeltaRow(delta: d)]),
            ),
            const SizedBox(height: 14),
            const SectionLabel('Transaction ID'),
            const SizedBox(height: 8),
            SelectableText(tx.txid, style: AmbraText.mono.copyWith(fontSize: 13)),
            const SizedBox(height: 16),
            SecondaryButton(label: 'View in explorer', icon: Icons.open_in_new, onPressed: () => _openExplorer(context)),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Copy transaction id',
              icon: Icons.copy,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: tx.txid));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Transaction id copied')));
              },
            ),
            // Developer mode offers the rescues; default mode speeds up by itself.
            if (!settled && DevMode.instance.on) ...[
              const SizedBox(height: 10),
              PrimaryButton(
                label: 'Speed up / bump fee',
                icon: Icons.bolt,
                onPressed: () async {
                  final txid = await showRescueActions(context, tx);
                  if (txid != null && context.mounted) Navigator.of(context).pop(txid);
                },
              ),
            ],
            const SizedBox(height: 6),
            GhostButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
          ]),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 96, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.body)),
        ]),
      );
}

class _DeltaRow extends StatelessWidget {
  const _DeltaRow({required this.delta});
  final core.AssetDelta delta;
  @override
  Widget build(BuildContext context) {
    final label = SeqAssets.labelFor(delta.assetId);
    final atoms = BigInt.tryParse(delta.atoms) ?? BigInt.zero;
    final neg = atoms.isNegative;
    final amount = '${neg ? '' : '+'}${formatAtoms(atoms.toString(), label.precision)} ${label.ticker}';
    final approx = PriceService.instance.approx(label.ticker, atoms.toString(), label.precision);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.ticker,
                style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 14)),
            if (label.subtitle != null) ...[
              const SizedBox(height: 2),
              Text(label.subtitle!, style: AmbraText.sub, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ]),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          Text(amount,
              style: AmbraText.mono.copyWith(
                  color: neg ? AmbraColors.amber2 : AmbraColors.green, fontWeight: FontWeight.w700, fontSize: 14)),
          if (approx != null) ...[
            const SizedBox(height: 2),
            Text(approx, style: AmbraText.sub),
          ],
        ]),
      ]),
    );
  }
}

/// The BTC payments into the wallet among an address's transactions (testnet4 esplora's
/// `/address/:a/txs`): each one paying [mine] and spending none of [mine] (a transaction that
/// spends the wallet's own coins is one of its own sends, recorded when it left). Pending
/// until confirmed.
List<Map<String, dynamic>> incomingBtc(Object? txs, Set<String> mine) {
  if (txs is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final t in txs.whereType<Map>()) {
    final vin = t['vin'] is List ? t['vin'] as List : const [];
    if (vin.any((i) => i is Map && i['prevout'] is Map && mine.contains((i['prevout'] as Map)['scriptpubkey_address']))) continue;
    var sats = 0;
    for (final o in (t['vout'] is List ? t['vout'] as List : const []).whereType<Map>()) {
      if (mine.contains(o['scriptpubkey_address']) && o['value'] is num) sats += (o['value'] as num).toInt();
    }
    if (sats <= 0) continue;
    final st = t['status'] is Map ? t['status'] as Map : const {};
    final confirmed = st['confirmed'] == true;
    final at = st['block_time'] is num ? (st['block_time'] as num).toInt() * 1000 : DateTime.now().millisecondsSinceEpoch;
    out.add({
      'kind': 'received',
      'ticker': 'BTC',
      'atoms': '$sats',
      'precision': 8,
      'rail': 'btc',
      'chain': 'btc',
      'txid': '${t['txid']}',
      'pending': !confirmed,
      'time': at,
    });
  }
  return out;
}

/// [txs] less the wallet's own boards ([boards]: their transaction ids).
List<core.TxRow> withoutBoards(List<core.TxRow> txs, Set<String> boards) =>
    boards.isEmpty ? txs : [for (final t in txs) if (!boards.contains(t.txid)) t];

/// The ark's movements ([movements]: Bark's history) that are money received from another
/// wallet, as History's payment rows: a payment to the ark's address, or an invoice of the ark
/// paid, settled, and none of the wallet's own moves ([own]: invoices it paid from its own
/// channel, hashes of its trades).
List<Map<String, dynamic>> arkReceipts(List<Map> movements, Set<String> own) {
  final out = <Map<String, dynamic>>[];
  for (final m in movements) {
    final sub = m['subsystem'];
    final name = sub is Map ? sub['name'] : null;
    if (name != 'bark.arkoor' && name != 'bark.lightning_receive') continue;
    if ('${m['status']}'.toLowerCase() != 'successful') continue;
    final sats = BigInt.tryParse('${m['effective_balance'] ?? ''}');
    if (sats == null || sats <= BigInt.zero) continue;
    final text = jsonEncode(m);
    if (own.any((o) => o.isNotEmpty && text.contains(o))) continue;
    final t = m['time'];
    final at = t is Map ? DateTime.tryParse('${t['completed_at'] ?? t['created_at'] ?? ''}') : null;
    out.add({
      'kind': 'received',
      'ticker': 'BTC',
      'atoms': '$sats',
      'precision': 8,
      'rail': 'ark',
      'key': 'ark:${m['id']}',
      'time': ?at?.millisecondsSinceEpoch,
    });
  }
  return out;
}
