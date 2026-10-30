import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/ark_btc_service.dart';
import '../data/asset_picker.dart';
import '../data/btc_state.dart';
import '../data/config.dart';
import '../data/default_words.dart';
import '../data/dev_mode.dart';
import '../data/fee_asset_rule.dart';
import '../data/format.dart';
import '../data/hidden_assets.dart';
import '../data/leaf_service.dart';
import '../data/lightning_service.dart';
import '../data/ln_rail.dart';
import '../data/openamp_service.dart';
import '../data/pay_code.dart';
import '../data/price_service.dart';
import '../data/seqln_keys.dart' as lnkeys;
import '../data/subswap_service.dart' show bolt11AmountMsat;
import '../data/wallet_cache.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/asset_sheet.dart';
import '../widgets/ln_cards.dart';
import '../widgets/widgets.dart';
import 'scan_screen.dart';

class SendTab extends StatefulWidget {
  const SendTab({super.key, this.isActive = false});
  final bool isActive;
  @override
  State<SendTab> createState() => _SendTabState();
}

class _SendTabState extends State<SendTab> {
  final _addr = TextEditingController();
  final _amount = TextEditingController();
  final _feeRateCtl = TextEditingController(); // sat/vB, optional; empty = network default
  List<core.AssetBalance> _balances = [];
  core.BtcBalance? _btc; // parent-chain (testnet4) balance, sendable like any asset
  List<Map> _lnChannels = const []; // this wallet's own Lightning channels, for the picker's holdings
  Map<String, BigInt> _feeRates = {};
  Map<String, BigInt> _largestCoins = {}; // each asset's largest coin, for the fee-asset rule
  String _assetId = _btcId; // BTC is the first-class default pick (principle 2), not tSEQ
  String? _feeAsset; // the fee asset's id; null = the wallet holds nothing the node accepts
  bool _feeManual = false; // true once the user explicitly picks a fee asset
  bool _loading = true;
  bool _sendingInTree = false; // a payment to a receive code is on its way

  /// The way chosen out of a receive code in the recipient field (its receive request,
  /// its ark address or its address), for the payment being reviewed; null when the field
  /// holds a single destination.
  String? _route;

  /// The destination of the payment being reviewed.
  String get _to => _route ?? _addr.text.trim();

  /// Picks the way a receive code ([PayCode]) is paid, without asking, instant first: an
  /// asset to its receive request when this wallet's instant part holds it; BTC to its ark
  /// address when the ark holds the amount, else to its invoice when the ark or Lightning
  /// pays it; anything else to its address ([_byAddress] then says so in plain words).
  String? _routeOf(PayCode code) {
    _byAddress = false;
    if (_isBtc) {
      final sats = parseAtoms(_amount.text, 8);
      final ark = ArkBtcService.instance;
      final some = sats != null && sats > BigInt.zero;
      if (code.ark != null && ark.open && some && sats <= ark.spendable) return code.ark;
      final inv = code.lightning;
      if (inv != null) {
        final msat = bolt11AmountMsat(inv);
        final want = msat == null ? sats : msat ~/ BigInt.from(1000);
        if (want != null && ((ark.open && want <= ark.spendable) || want <= _lnAtoms(_btcId))) return inv;
      }
      _byAddress = code.address != null;
      return code.address ?? code.ark;
    }
    final seq = code.sequentia;
    final paid = seq == null ? null : LeafService.instance.payable(seq);
    if (paid != null) {
      final label = SeqAssets.labelFor(_assetId);
      final atoms = parseAtoms(_amount.text, label.precision);
      // Paid from the instant part when it holds the amount; the review says so otherwise.
      if (atoms == null || atoms <= LeafService.instance.spendableAtoms(_assetId) || code.address == null) return paid;
    }
    _byAddress = code.address != null;
    return code.address;
  }

  /// A payment that just left, in History at once ([WalletCache.addPayment]): pending while
  /// it waits for a block ([txid] given), done otherwise.
  Future<void> _logSent(String ticker, BigInt atoms, int precision, String rail, {String? txid, String? chain}) async {
    try {
      await WalletCache.addPayment({
        'kind': 'payment',
        'ticker': ticker,
        'atoms': atoms.toString(),
        'precision': precision,
        'rail': rail,
        'pending': txid != null,
        'txid': ?txid,
        'chain': ?chain,
      });
    } catch (_) {/* history tracking is best-effort */}
  }

  /// Whether the payment being reviewed is a receive code paid at its address, because no
  /// instant way fits: the review says so ([DefaultWords.byAddress]).
  bool _byAddress = false;
  String? _error;

  /// The synthetic asset id for parent-chain Bitcoin in the picker/state.
  static const _btcId = 'BTC';

  @override
  void initState() {
    super.initState();
    _btc = BtcState.instance.last; // show BTC at once if the Balance tab already scanned
    _loadCached(); // render the form from last-known balances at once
    _load(); // eager: load at launch (also reloads on activation)
  }

  /// Show the send form instantly using the last-known balances (shared with the
  /// Balance tab's cache), so a cold start never blocks on a spinner. The live
  /// sync below refreshes balances and fee rates in the background.
  Future<void> _loadCached() async {
    final b = await WalletCache.loadBalances();
    if (b == null || !mounted || _balances.isNotEmpty) return; // don't clobber a finished sync
    setState(() {
      // Restricted (OpenAMP) assets are sendable among equals; show last-known.
      _balances = [...b, ...OpenAmpService.instance.balances];
      if (!_feeManual) _feeAsset = _defaultFeeFor(_assetId);
      _loading = false;
    });
  }

  @override
  void didUpdateWidget(SendTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-sync when the tab is opened so newly-received assets are sendable
    // without restarting the app. Form fields are preserved across the reload.
    if (widget.isActive && !oldWidget.isActive) _load();
  }

  @override
  void dispose() {
    _addr.dispose();
    _amount.dispose();
    _feeRateCtl.dispose();
    super.dispose();
  }

  /// Asset ids the wallet actually holds (balance > 0). tSEQ is not privileged,
  /// so it only appears here when funded — just like every other asset.
  List<String> _heldIds() => _balances
      .where((b) => (BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero)
      .map((b) => b.assetId)
      .toList();

  bool get _isBtc => _assetId == _btcId;

  /// Atoms of [id] spendable in this wallet's own Lightning channels (BTC included).
  BigInt _lnAtoms(String id) {
    if (_lnChannels.isEmpty) return BigInt.zero;
    final t = id == _btcId ? RailTarget.btc() : RailTarget.asset(hex: id, ticker: SeqAssets.labelFor(id).ticker);
    return legLiquidity(_lnChannels, t).spendable;
  }

  /// Atoms of [id] in this wallet's leaves (none until it joined an operator; BTC is never a leaf).
  BigInt _leafAtoms(String id) =>
      LeafService.instance.joined ? (LeafService.instance.leafAtoms()[id] ?? BigInt.zero) : BigInt.zero;

  /// BTC the Bitcoin ark holds (user mode keeps BTC there).
  BigInt _arkSats(String id) =>
      id == _btcId && ArkBtcService.instance.open ? ArkBtcService.instance.held : BigInt.zero;

  /// What the wallet holds of [id] on every rail: on-chain, Lightning, leaves and, for BTC in
  /// user mode, the Bitcoin ark.
  BigInt _totalOf(String id) =>
      (BigInt.tryParse(_balanceOf(id)) ?? BigInt.zero) + _lnAtoms(id) + _leafAtoms(id) + _arkSats(id);

  /// The picker's rows in the wallet's order: BTC first (listed even at 0), then every
  /// asset held on any rail, then every other asset the wallet can name, for the search.
  List<String> _pickerIds() {
    final candidates = <String>{
      for (final b in _balances) b.assetId,
      if (LeafService.instance.joined) ...LeafService.instance.leafAtoms().keys,
      for (final c in _lnChannels)
        if ('${c['leg'] ?? ''}' != 'btc' && '${c['asset'] ?? ''}'.isNotEmpty) '${c['asset']}',
    };
    return pickerOrder(
      held: candidates.where((id) => _totalOf(id) > BigInt.zero),
      known: SeqAssets.resolvedIds,
    );
  }

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      // Fee rates are independent of the chain sync; fetch + apply them first so
      // fee pricing stays correct even if the sync is slow or fails.
      try {
        final rates = await ApiClient.feeRates();
        if (mounted && rates.isNotEmpty) setState(() => _feeRates = rates);
      } catch (_) {/* fee-rate list unavailable; the default fee still works */}
      // Scan the parent chain concurrently; a BTC failure must not block sending
      // Sequentia assets, so it resolves to null on error.
      final btcF = () async {
        try {
          return await core.btcSync(mnemonic: m, t4Api: Backend.testnet4);
        } catch (_) {
          return null;
        }
      }();
      final ampF = OpenAmpService.instance.refresh(m); // restricted assets, fail-soft
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      final btc = await btcF;
      final amp = await ampF;
      final lnCh = await _ownChannels(m, s.balances);
      WalletCache.saveBalances(s.balances); // keep the shared cache fresh
      if (btc != null) BtcState.instance.observe(btc: btc, seqNext: s.nextIndex);
      if (!mounted) return;
      setState(() {
        _error = null; // a successful load clears any earlier (transient) error
        _balances = [...s.balances, ...amp];
        _largestCoins = largestCoinsOf(s);
        if (btc != null) _btc = btc;
        if (lnCh != null) _lnChannels = lnCh;
        // The send asset is the user's pick, BTC until they make one (principle 2); a
        // reload never moves it, and never to tSEQ.
        // Default the fee to the asset being sent (asset-agnostic). Keep the
        // user's manual fee choice while they still hold it; otherwise re-apply
        // the default for the current send asset.
        if (_feeManual && _feeAsset != null && !_heldIds().contains(_feeAsset)) {
          _feeManual = false;
        }
        if (!_feeManual) _feeAsset = _defaultFeeFor(_assetId);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          // Keep last-good data on a transient reload error; only surface it when
          // there's nothing to show. Send has no pull-to-refresh, so don't tell
          // the user to "pull down" — the error card carries a Retry button.
          if (_balances.isEmpty) _error = friendlyError(e, pullToRefresh: false);
          _loading = false;
        });
      }
    }
  }

  /// This wallet's own Lightning channels (best-effort: null when Lightning is off or
  /// the provider does not answer), so an asset held only in a channel is still listed
  /// among the wallet's holdings. Keyed like the Balance tab: a node key for BTC and for
  /// every asset the wallet can name or holds.
  Future<List<Map>?> _ownChannels(String m, List<core.AssetBalance> balances) async {
    if (!LightningService.instance.configured) return null;
    try {
      final nodes = <String>{
        lnkeys.ownNodeKeyForBtc(m),
        for (final id in SeqAssets.resolvedIds) lnkeys.ownNodeKeyForAsset(m, id),
        for (final b in balances) lnkeys.ownNodeKeyForAsset(m, b.assetId),
      }.toList();
      final st = await LightningService.instance.getStatus(nodes: nodes);
      return ((st.raw['channels'] as List?) ?? const [])
          .whereType<Map>()
          .where((c) => '${c['node_key'] ?? ''}'.isNotEmpty)
          .toList();
    } catch (_) {
      return null;
    }
  }

  core.AssetBalance? get _selected {
    for (final b in _balances) {
      if (b.assetId == _assetId) return b;
    }
    return null;
  }

  /// The node's rate for an asset from its fee-rate feed; null = not accepted for fees.
  BigInt? _rateFor(String hex) => feeRateFor(_feeRates, hex);

  /// The fee asset's ticker, or a dash when the wallet holds nothing the node accepts.
  String get _feeLabel => _feeAsset == null ? '—' : SeqAssets.labelFor(_feeAsset!).ticker;

  /// True when the send asset is a restricted (OpenAMP enclave) asset — moved via
  /// the enclave transfer flow, not an on-chain PSET, and addressed by account id.
  bool get _isRestricted => OpenAmpService.instance.isRestricted(_assetId);

  /// The fee picker's rows: every asset held on-chain that the node accepts for fees,
  /// tSEQ judged like any other. Restricted (enclave-held) assets cannot pay an
  /// on-chain fee.
  List<String> _feeOptions() => _heldIds()
      .where((id) => !OpenAmpService.instance.isRestricted(id) && _rateFor(id) != null)
      .toList();

  /// The fee asset by the wallet rule ([walletFeeAsset]): the asset sent when the node
  /// accepts it, else the accepted asset whose largest coin covers the most fees; null
  /// when the wallet holds nothing the node accepts. Never a tSEQ fallback.
  String? _defaultFeeFor(String assetId) => walletFeeAsset(
        moved: assetId,
        rates: _feeRates,
        // Before the first sync of this session, the cached balances stand in for the largest coins.
        largestCoin: _largestCoins.isNotEmpty
            ? _largestCoins
            : {for (final b in _balances) b.assetId: BigInt.tryParse(b.atoms) ?? BigInt.zero},
      );

  Future<void> _pickAsset() async {
    final rows = [
      for (final id in _pickerIds())
        AssetPickerItem(
          hex: id,
          ticker: id == _btcId ? 'BTC' : SeqAssets.labelFor(id).ticker,
          name: id == _btcId ? 'Bitcoin' : SeqAssets.labelFor(id).subtitle,
          held: id == _btcId || _totalOf(id) > BigInt.zero,
          hidden: HiddenAssets.instance.isHidden(id),
        ),
    ];
    final picked = await showAssetSheet(
      context,
      title: 'Choose asset',
      rows: rows,
      registrySearch: true,
      balanceOf: (id) => formatAtoms(_totalOf(id).toString(), id == _btcId ? 8 : SeqAssets.labelFor(id).precision),
    );
    if (picked != null) {
      setState(() {
        _assetId = picked;
        // Re-apply the "fee in the asset being sent" default for the new asset.
        // (BTC pays its own fee in BTC, so the fee-asset picker doesn't apply.)
        _feeManual = false;
        _feeAsset = _defaultFeeFor(picked);
        _feeRateCtl.clear(); // the rate unit differs (sat/vB for BTC, asset/vB otherwise)
      });
    }
  }

  Future<void> _pickFee() async {
    final picked = await showAssetSheet(
      context,
      title: 'Pay fee in',
      rows: [
        for (final id in _feeOptions())
          AssetPickerItem(hex: id, ticker: SeqAssets.labelFor(id).ticker, name: SeqAssets.labelFor(id).subtitle),
      ],
      balanceOf: (id) => formatAtoms(_balanceOf(id), SeqAssets.labelFor(id).precision),
    );
    if (picked != null) {
      setState(() {
        _feeManual = true;
        _feeAsset = picked;
      });
    }
  }

  String _balanceOf(String id) {
    if (id == _btcId) return _btc?.balanceSats ?? '0';
    for (final b in _balances) {
      if (b.assetId == id) return b.atoms;
    }
    return '0';
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(ambraSnack(m));

  /// Scan a QR into the recipient field. Accepts a plain address or a BIP21-style
  /// URI (scheme:address?amount=...); the build step validates the address.
  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (raw == null || !mounted) return;
    // A receive code is kept whole: its other ways to pay (instant ones) are in its query.
    try {
      final code = PayCode.read(raw);
      if (code != null && (code.ark != null || code.sequentia != null || code.lightning != null)) {
        setState(() {
          _addr.text = raw.trim();
          if (_isBtc && code.amount != null && double.tryParse(code.amount!) != null) _amount.text = code.amount!;
        });
        return;
      }
    } on FormatException catch (e) {
      return _snack(e.message);
    }
    var s = raw.trim();
    if (s.contains(':')) s = s.substring(s.indexOf(':') + 1); // drop any URI scheme
    String? amount;
    final q = s.indexOf('?');
    if (q >= 0) {
      amount = Uri.splitQueryString(s.substring(q + 1))['amount'];
      s = s.substring(0, q);
    }
    setState(() {
      _addr.text = s;
      if (amount != null && double.tryParse(amount) != null) _amount.text = amount;
    });
  }

  Future<void> _review() async {
    _route = null;
    try {
      final code = PayCode.read(_addr.text);
      if (code != null) {
        _route = _routeOf(code);
        if (_route == null) return _snack(DefaultWords.codeTakesAssets);
      }
    } on FormatException catch (e) {
      return _snack(e.message);
    }
    // User mode: BTC the Bitcoin ark holds pays a BTC invoice, an ark address or (BTC
    // picked) a Bitcoin address, chosen without asking; what the ark cannot cover takes
    // the path it always took.
    if (!DevMode.instance.on && ArkBtcService.instance.open) {
      final routed = await _maybeArkBtc();
      if (routed || !mounted) return;
    }
    // A Lightning invoice in the recipient field is paid over Lightning, whatever asset is picked:
    // the invoice names its own amount, and the pay screen its asset.
    final invoice = bolt11Of(_to);
    if (invoice != null && LightningService.instance.configured) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LnPayScreen(invoice: invoice)));
      return;
    }
    // A receive code of another wallet on this wallet's operator: paid off the chain, in
    // seconds. Anything else (an address, an invoice, an account id) takes the path it
    // always took.
    if (LeafService.instance.paysInTree(_to)) {
      if (_isBtc || _isRestricted) {
        return _snack(DefaultWords.codeTakesAssets);
      }
      return _reviewInTree();
    }
    LeafService.instance.personActed(); // the wallet's own upkeep keeps off the coins this send spends
    if (_isBtc) return _reviewBtc();
    if (_isRestricted) return _reviewOpenamp();
    final label = SeqAssets.labelFor(_assetId);
    final addr = _to;
    final atoms = parseAtoms(_amount.text, label.precision);
    if (addr.isEmpty) return _snack('Enter a recipient address');
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter a valid amount');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large.'); // u64 FFI guard
    final bal = BigInt.tryParse(_selected?.atoms ?? '0') ?? BigInt.zero;
    // User mode: what the chain cannot cover the instant part pays, out to the address.
    if (atoms > bal && !DevMode.instance.on && LeafService.instance.open) {
      if (atoms <= LeafService.instance.spendableAtoms(_assetId)) return _reviewOffboard(addr, atoms);
      if (atoms <= bal + _leafAtoms(_assetId)) return _snack(DefaultWords.addressNotNow);
    }
    if (atoms > bal) return _snack('Amount exceeds your ${label.ticker} balance');

    // Fund checks (fees are multi-asset — another asset's balance can't cover a
    // fee), so the user isn't asked to authorize a doomed payment.
    final feeHex = _feeAsset;
    final feeRate = feeHex == null ? null : _rateFor(feeHex);
    if (feeHex == null || feeRate == null) return _snack(noFeeAssetMessage);
    // The fee comes out of the same asset when it is the one sent: leave a little behind.
    if (feeHex == _assetId && atoms == bal) {
      return _snack('Leave a little ${label.ticker} for the network fee; send a bit less.');
    }
    final feeBal = BigInt.tryParse(_balanceOf(feeHex)) ?? BigInt.zero;
    if (feeBal <= BigInt.zero) return _snack('You have no $_feeLabel to pay the fee with.');
    final feeAsset = feeAssetParam(feeHex, feeRate);

    // Optional fee rate in the chosen asset's own units per vByte (never sat/vB,
    // which is a Bitcoin unit). Convert it to the internal rate lwk needs:
    // r × 10^precision × R / 1e5, where R is the asset's published rate (tSEQ's
    // included). Empty = the network default.
    double? feeRateSatKvb;
    final frText = _feeRateCtl.text.trim();
    if (frText.isNotEmpty) {
      final fr = double.tryParse(frText);
      if (fr == null || fr <= 0) return _snack('Enter a valid fee rate, or leave it blank.');
      final label = SeqAssets.labelFor(feeHex);
      feeRateSatKvb = fr * math.pow(10, label.precision) * feeRate.toDouble() / 100000;
    }

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _ReviewSheet(
        address: addr,
        assetId: _assetId,
        atoms: atoms,
        ticker: label.ticker,
        amountStr: formatAtoms(atoms.toString(), label.precision),
        feeAsset: feeAsset,
        feeLabel: _feeLabel,
        feeRateSatKvb: feeRateSatKvb,
        note: _byAddress && !DevMode.instance.on ? DefaultWords.byAddress(DefaultWords.arrivesNextBlock) : null,
      ),
    );
    if (txid != null && mounted) {
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack(
        'Sent · ${txid.substring(0, 16)}…',
        action: SnackBarAction(
          label: 'Copy txid',
          textColor: AmbraColors.amber,
          onPressed: () => Clipboard.setData(ClipboardData(text: txid)),
        ),
      ));
      _load();
    }
  }

  /// Review + send a parent-chain Bitcoin (testnet4) payment. BTC pays its own fee
  /// in BTC (sat/vB), so there's no fee-asset market here — a different path from
  /// the Sequentia send above.
  Future<void> _reviewBtc() async {
    final addr = _to;
    final atoms = parseAtoms(_amount.text, 8); // BTC has 8 decimals
    if (addr.isEmpty) return _snack('Enter a recipient address');
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter a valid amount');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large.');
    final bal = BigInt.tryParse(_balanceOf(_btcId)) ?? BigInt.zero;
    if (atoms > bal) return _snack('Amount exceeds your BTC balance');

    double feeRate = 0; // 0 => the core uses the testnet4 default
    final frText = _feeRateCtl.text.trim();
    if (frText.isNotEmpty) {
      final fr = double.tryParse(frText);
      if (fr == null || fr <= 0) return _snack('Enter a valid fee rate (sat/vB), or leave it blank.');
      feeRate = fr;
    }

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _BtcReviewSheet(
        address: addr,
        amountSats: atoms,
        amountStr: formatAtoms(atoms.toString(), 8),
        feeRate: feeRate,
        note: _byAddress && !DevMode.instance.on ? DefaultWords.byAddress(DefaultWords.arrivesAfterBlock) : null,
      ),
    );
    if (txid != null) unawaited(_logSent('BTC', atoms, 8, 'btc', txid: txid, chain: 'btc'));
    if (txid != null && mounted) {
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack(
        'Sent BTC · ${txid.substring(0, 16)}…',
        action: SnackBarAction(
          label: 'Copy txid',
          textColor: AmbraColors.amber,
          onPressed: () => Clipboard.setData(ClipboardData(text: txid)),
        ),
      ));
      _load();
    }
  }

  /// User mode: a payment to an address out of the leaves (the library's `offboard`),
  /// quoted first and made only on the quote shown.
  Future<void> _reviewOffboard(String address, BigInt atoms) async {
    final label = SeqAssets.labelFor(_assetId);
    final args = {'asset': _assetId, 'amount': atoms.toString(), 'address': address};
    final Map quote;
    try {
      final q = await LeafService.instance.run('offboard_quote', args);
      if (q is! Map) throw LeafRefusal('refused', 'no quote');
      quote = q;
    } catch (_) {
      return _snack(DefaultWords.addressNotNow);
    }
    if (!mounted) return;
    final amountStr = formatAtoms(atoms.toString(), label.precision);
    final feeAtoms = BigInt.tryParse('${(quote['fee'] is Map) ? (quote['fee'] as Map)['amount'] : 0}') ?? BigInt.zero;
    final arrives = DefaultWords.arrivesIn(LeafService.instance.roundMinutes());
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(DefaultWords.review(amountStr, label.ticker), style: AmbraText.title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(arrives, style: AmbraText.muted),
          if (feeAtoms > BigInt.zero) ...[
            const SizedBox(height: 8),
            Text(DefaultWords.fee(formatAtoms(feeAtoms.toString(), label.precision), label.ticker), style: AmbraText.muted),
          ],
        ]),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(key: const Key('send-offboard-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sendingInTree = true);
    try {
      await LeafService.instance.pay('offboard', {...args, 'shown': quote}, true);
      unawaited(_logSent(label.ticker, atoms, label.precision, 'address'));
      if (!mounted) return;
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack(DefaultWords.sentThen(amountStr, label.ticker, arrives)));
      await LeafService.instance.refresh();
    } catch (e) {
      if (mounted) _snack(LeafRefusal.of(e).message);
    } finally {
      if (mounted) setState(() => _sendingInTree = false);
    }
    _load();
  }

  /// Pays out of the Bitcoin ark when the destination is one it pays and it holds the
  /// amount; answers whether it took the payment (or refused it in plain words).
  Future<bool> _maybeArkBtc() async {
    final ark = ArkBtcService.instance;
    final raw = _to;
    final inv = bolt11Of(raw);
    final dest = inv ?? raw;
    final btcInvoice = inv != null && RegExp(r'^lntb[0-9]', caseSensitive: false).hasMatch(inv);
    final kind = ark.kindOf(dest);
    BigInt? sats;
    if (kind == 'lightning' && btcInvoice) {
      final msat = bolt11AmountMsat(inv);
      if (msat == null) return false; // an invoice naming no amount: the old path asks for one
      sats = msat ~/ BigInt.from(1000);
    } else if (kind == 'ark' || (kind == 'onchain' && _isBtc)) {
      sats = parseAtoms(_amount.text, 8);
      if (sats == null || sats <= BigInt.zero) {
        _snack('Enter a valid amount');
        return true;
      }
    } else {
      return false;
    }
    if (sats > ark.spendable) {
      if (kind == 'onchain') return false; // an address is paid as before
      // An invoice the wallet's own Lightning holds enough for is paid there, at once.
      if (kind == 'lightning' && LightningService.instance.configured && sats <= _lnAtoms(_btcId)) return false;
      _snack(DefaultWords.btcUpTo(formatAtoms(ark.spendable.toString(), 8)));
      return true;
    }
    final amountStr = formatAtoms(sats.toString(), 8);
    final fast = kind != 'onchain';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(DefaultWords.review(amountStr, 'BTC'), style: AmbraText.title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('To  ${dest.length > 24 ? '${dest.substring(0, 12)}…${dest.substring(dest.length - 8)}' : dest}',
              style: AmbraText.muted),
          const SizedBox(height: 6),
          Text(fast ? DefaultWords.reviewLine : DefaultWords.arrivesAfterBlock, style: AmbraText.muted),
        ]),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(key: const Key('send-btc-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return true;
    setState(() => _sendingInTree = true);
    final started = DateTime.now();
    try {
      await ark.send(dest, kind == 'lightning' ? null : sats);
      final secs = DateTime.now().difference(started).inMilliseconds / 1000;
      unawaited(_logSent('BTC', sats, 8, kind == 'onchain' ? 'address' : (kind == 'lightning' ? 'lightning' : 'ark')));
      if (!mounted) return true;
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(
          ambraSnack(fast ? DefaultWords.sent(amountStr, 'BTC', secs) : DefaultWords.btcSentAfterBlock(amountStr)));
    } catch (e) {
      debugPrint('ark send refused: $e');
      if (mounted) setState(() => _sendingInTree = false);
      // Never worse than before: an invoice or an address the ark could not pay goes the
      // way it always went; an ark address has no other way.
      if (kind != 'ark') return false;
      if (mounted) _snack(DefaultWords.couldNotSend);
    } finally {
      if (mounted) setState(() => _sendingInTree = false);
    }
    _load();
    return true;
  }

  /// A payment to a receive code ([LeafService.paysInTree]): off the chain, from this
  /// wallet's leaves, as the library's `send`. User mode says a refusal in its plain words.
  Future<void> _reviewInTree() async {
    final label = SeqAssets.labelFor(_assetId);
    final atoms = parseAtoms(_amount.text, label.precision);
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter a valid amount');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large.');
    final instant = _leafAtoms(_assetId) - LeafService.instance.frozenAtoms(_assetId);
    final amountStr = formatAtoms(atoms.toString(), label.precision);
    if (atoms > instant) {
      final arriving = LeafService.instance.arrivingAtoms()[_assetId] ?? BigInt.zero;
      if (atoms <= instant + arriving) {
        return _snack(DefaultWords.stillArriving(label.ticker));
      }
      return _snack('Amount exceeds your ${label.ticker} balance');
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(DefaultWords.review(amountStr, label.ticker), style: AmbraText.title),
        content: const Text(DefaultWords.reviewLine, style: AmbraText.muted),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(key: const Key('send-code-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sendingInTree = true);
    final started = DateTime.now();
    try {
      await LeafService.instance.pay(
          'send', {'request': _to, 'amount': atoms.toString(), 'asset': _assetId}, !DevMode.instance.on);
      final secs = DateTime.now().difference(started).inMilliseconds / 1000;
      unawaited(_logSent(label.ticker, atoms, label.precision, 'tree'));
      if (!mounted) return;
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(ambraSnack(DefaultWords.sent(amountStr, label.ticker, secs)));
      await LeafService.instance.refresh();
    } catch (e) {
      if (mounted) _snack(LeafRefusal.of(e).message);
    } finally {
      if (mounted) setState(() => _sendingInTree = false);
    }
    _load();
  }

  /// Review + send a restricted (OpenAMP) asset. The enclave holds the funds; the
  /// recipient is addressed by their OpenAMP account id (AID), not an address, and
  /// the fee is taken by conversion inside the enclave (no any-asset fee market).
  /// The wallet drafts the transfer, Schnorr-signs each sighash on-device, and
  /// completes it — the signing key never leaves the phone.
  Future<void> _reviewOpenamp() async {
    final label = SeqAssets.labelFor(_assetId);
    final recipient = _addr.text.trim();
    final atoms = parseAtoms(_amount.text, label.precision);
    if (recipient.isEmpty) return _snack('Enter a recipient account id (AID)');
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter a valid amount');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large.');
    final bal = BigInt.tryParse(_selected?.atoms ?? '0') ?? BigInt.zero;
    if (atoms > bal) return _snack('Amount exceeds your ${label.ticker} balance');

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _OpenampReviewSheet(
        recipientAid: recipient,
        assetId: _assetId,
        atoms: atoms,
        ticker: label.ticker,
        amountStr: formatAtoms(atoms.toString(), label.precision),
      ),
    );
    if (txid != null && mounted) {
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack(
        'Sent · ${txid.substring(0, txid.length < 16 ? txid.length : 16)}…',
        action: SnackBarAction(
          label: 'Copy txid',
          textColor: AmbraColors.amber,
          onPressed: () => Clipboard.setData(ClipboardData(text: txid)),
        ),
      ));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = SeqAssets.labelFor(_assetId);
    final held = _heldIds();
    final canPickFee = _feeOptions().length > 1; // more than one held asset to choose from
    final canSend = !_loading && _error == null;
    final prec = _isBtc ? 8 : label.precision;
    final balStr = formatAtoms(_balanceOf(_assetId), prec);
    // The form spends on-chain coins; when part of the holding sits in Lightning or
    // leaves, the field says which part it can send.
    final elsewhere = _lnAtoms(_assetId) + _leafAtoms(_assetId) > BigInt.zero;
    // Nothing anywhere: no asset on any rail, and no BTC on the chain, in Lightning or on the ark.
    final nothingHeld = !{...held, if (LeafService.instance.joined) ...LeafService.instance.leafAtoms().keys}
            .any((id) => _totalOf(id) > BigInt.zero) &&
        _totalOf(_btcId) == BigInt.zero;
    return Column(
      children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
            const Text('Send', style: AmbraText.h1),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
            else if (_error != null)
              AmbraCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(_error!, style: const TextStyle(color: AmbraColors.red)),
                  const SizedBox(height: 14),
                  SecondaryButton(label: 'Retry', icon: Icons.refresh, onPressed: _load),
                ]),
              )
            else ...[
              if (nothingHeld) ...[
                const AmbraCard(
                    child: Text(
                        'Nothing to send yet. Get free testnet coins from the faucet (More tab), '
                        'or receive funds to your address.',
                        style: AmbraText.muted)),
                const SizedBox(height: 18),
              ],
              const SectionLabel('Asset'),
              const SizedBox(height: 8),
              _PickerField(
                key: const ValueKey('send-asset-picker'),
                label: _isBtc ? 'BTC' : label.ticker,
                trailing: !DevMode.instance.on
                    ? 'balance ${formatAtoms(_totalOf(_assetId).toString(), prec)}'
                    : (elsewhere ? '$balStr on-chain' : 'balance $balStr'),
                onTap: _pickAsset,
              ),
              const SizedBox(height: 18),
              AmbraField(
                label: _isRestricted
                    ? 'Recipient account id (AID)'
                    : (LeafService.instance.open && !DevMode.instance.on ? DefaultWords.recipient : 'Recipient address'),
                controller: _addr,
                hint: _isRestricted
                    ? 'their OpenAMP account id'
                    : (LeafService.instance.open && !DevMode.instance.on
                        ? DefaultWords.recipientHint
                        : (LightningService.instance.configured ? 'tb1…, tsqb1… or a Lightning invoice' : 'tb1… or tsqb1…')),
                mono: true,
                suffix: _isRestricted
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.qr_code_scanner, color: AmbraColors.amber2),
                        tooltip: 'Scan QR',
                        onPressed: _scan,
                      ),
              ),
              const SizedBox(height: 18),
              AmbraField(label: 'Amount (${_isBtc ? 'BTC' : label.ticker})', controller: _amount, hint: '0.0'),
              const SizedBox(height: 18),
              if (_isRestricted) ...[
                // Restricted (OpenAMP) assets move inside the enclave; the fee is
                // taken by conversion there, so there's no any-asset fee market.
                const Text('Restricted asset: sent via the OpenAMP enclave to a recipient '
                    'account id. The fee is taken by conversion inside the enclave.',
                    style: AmbraText.sub),
              ] else if (_isBtc) ...[
                // Parent-chain Bitcoin pays its own fee in BTC (sat/vB is a Bitcoin
                // unit and only correct here); there's no any-asset fee market.
                if (DevMode.instance.on) ...[
                  const Text('Bitcoin (testnet4): the fee is paid in BTC at the rate below.', style: AmbraText.sub),
                  const SizedBox(height: 16),
                  AmbraField(label: 'Fee rate (sat/vB, optional)', controller: _feeRateCtl, hint: 'default 2'),
                ] else
                  const Text(DefaultWords.btcFee, style: AmbraText.sub),
              ] else ...[
                const SectionLabel('Pay fee in'),
                const SizedBox(height: 8),
                _PickerField(
                  label: _feeLabel,
                  trailing: canPickFee ? 'any asset you hold' : null,
                  onTap: canPickFee ? _pickFee : null,
                ),
                const SizedBox(height: 10),
                if (_feeAsset == null)
                  const WarnCallout(noFeeAssetMessage)
                else
                  Text(
                    DevMode.instance.on
                        ? 'Fee paid in $_feeLabel at the node\'s published rate. '
                            'Confirmation depends on producers accepting it.'
                        : DefaultWords.feeIn(_feeLabel),
                    style: AmbraText.sub,
                  ),
                // The fee rate in the chosen asset's own units per vByte (e.g. OILX/vB, tSEQ/vB);
                // the actual fee is shown, estimated, on the review screen. Blank = network default.
                // Developer mode only: default mode has no fee-rate field.
                if (DevMode.instance.on) ...[
                  const SizedBox(height: 16),
                  AmbraField(label: 'Fee rate ($_feeLabel/vB, optional)', controller: _feeRateCtl, hint: ''),
                ],
              ],
            ],
          ]),
        ),
        if (canSend)
          BottomActionBar(children: [
            PrimaryButton(
                key: const Key('send-review'),
                label: 'Review & send',
                icon: Icons.north_east,
                busy: _sendingInTree,
                onPressed: _sendingInTree ? null : _review),
          ]),
      ],
    );
  }
}

class _PickerField extends StatelessWidget {
  const _PickerField({super.key, required this.label, this.trailing, this.onTap});
  final String label;
  final String? trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AmbraRadii.input),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AmbraColors.panelDeep,
          border: Border.all(color: AmbraColors.line),
          borderRadius: BorderRadius.circular(AmbraRadii.input),
        ),
        child: Row(children: [
          Text(label, style: AmbraText.body),
          const Spacer(),
          if (trailing != null) Text(trailing!, style: AmbraText.sub),
          if (onTap != null) ...[const SizedBox(width: 8), const Icon(Icons.expand_more, color: AmbraColors.dim, size: 20)],
        ]),
      ),
    );
  }
}

class _ReviewSheet extends StatefulWidget {
  const _ReviewSheet({
    required this.address,
    required this.assetId,
    required this.atoms,
    required this.ticker,
    required this.amountStr,
    required this.feeAsset,
    required this.feeLabel,
    required this.feeRateSatKvb,
    this.note,
  });
  /// A plain sentence over the figures (a receive code paid at its address, and why).
  final String? note;
  final String address;
  final String assetId;
  final BigInt atoms;
  final String ticker;
  final String amountStr;
  final core.FeeAsset? feeAsset;
  final String feeLabel;
  final double? feeRateSatKvb;

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  bool _busy = false; // signing + broadcasting
  bool _loading = true; // building the tx to estimate the fee
  String? _error;
  String? _pset; // built up front so the fee estimate is the exact tx we send
  core.PsetFee? _feeEst;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  /// Build the actual transaction now so the review can show the real fee (in
  /// the chosen asset), then reuse that exact PSET on confirm.
  Future<void> _prepare() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final pset = await core.buildSendTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        recipients: [core.Recipient(address: widget.address, assetId: widget.assetId, satoshi: widget.atoms)],
        feeRateSatKvb: widget.feeRateSatKvb,
        feeAsset: widget.feeAsset,
      );
      core.PsetFee? fee;
      try {
        fee = await core.psetFee(pset: pset);
      } catch (_) {/* the estimate is best-effort; the send still works */}
      if (mounted) {
        setState(() {
          _pset = pset;
          _feeEst = fee;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _pretty(e);
          _loading = false;
        });
      }
    }
  }

  /// The estimated fee in the asset it's paid in, plus the reference equivalent.
  String _feeEstStr() {
    final f = _feeEst!;
    final label = SeqAssets.labelFor(f.assetId);
    final amt = formatAtoms(f.atoms, label.precision);
    final ref = PriceService.instance.refValue(label.ticker, f.atoms, label.precision);
    final refStr = ref != null ? '  (≈ ${PriceService.instance.fmtRef(ref)} ${PriceService.instance.ref})' : '';
    return '$amt ${label.ticker}$refStr';
  }

  Future<void> _confirm() async {
    final pset = _pset;
    if (pset == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled; payment not sent.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final signed = await core.signPset(mnemonic: m, pset: pset);
      final txid = await core.finalizeAndBroadcast(mnemonic: m, esploraUrl: Backend.esplora, pset: signed);
      if (mounted) Navigator.pop(context, txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _pretty(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Confirm payment', style: AmbraText.h1),
          if (widget.note != null) ...[
            const SizedBox(height: 10),
            Text(widget.note!, key: const Key('send-by-address-note'), style: AmbraText.sub),
          ],
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('Amount', '${widget.amountStr} ${widget.ticker}'),
              _Row('To', widget.address, mono: true),
              _Row('Network', 'sequentia-testnet'),
              _Row('Fee paid in', widget.feeLabel),
              _Row('Network fee (est.)', _loading ? 'estimating…' : (_feeEst != null ? _feeEstStr() : 'unavailable')),
            ]),
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(
              label: 'Confirm & sign',
              busy: _busy,
              icon: Icons.fingerprint,
              onPressed: (_busy || _loading || _pset == null) ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

/// Review + broadcast a parent-chain Bitcoin (testnet4) payment. Builds + signs
/// up front (via [core.btcPrepare]) so the review shows the real fee, then
/// broadcasts that exact transaction on confirm.
class _BtcReviewSheet extends StatefulWidget {
  const _BtcReviewSheet({
    required this.address,
    required this.amountSats,
    required this.amountStr,
    required this.feeRate,
    this.note,
  });
  /// A plain sentence over the figures (a receive code paid at its address, and why).
  final String? note;
  final String address;
  final BigInt amountSats;
  final String amountStr;
  final double feeRate;

  @override
  State<_BtcReviewSheet> createState() => _BtcReviewSheetState();
}

class _BtcReviewSheetState extends State<_BtcReviewSheet> {
  bool _busy = false; // broadcasting
  bool _loading = true; // building + signing to estimate the fee
  String? _error;
  core.BtcTx? _tx;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final tx = await core.btcPrepare(
        mnemonic: m,
        t4Api: Backend.testnet4,
        address: widget.address,
        amountSats: widget.amountSats,
        feeRate: widget.feeRate,
      );
      if (mounted) {
        setState(() {
          _tx = tx;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _pretty(e);
          _loading = false;
        });
      }
    }
  }

  String _feeStr() {
    final tx = _tx!;
    final amt = formatAtoms(tx.feeSats, 8);
    final ref = PriceService.instance.refValue('BTC', tx.feeSats, 8);
    final refStr = ref != null ? '  (≈ ${PriceService.instance.fmtRef(ref)} ${PriceService.instance.ref})' : '';
    return '$amt BTC$refStr · ${tx.inputs} input${tx.inputs == 1 ? '' : 's'}, ${tx.vsize} vB';
  }

  String _totalStr() {
    final fee = BigInt.tryParse(_tx!.feeSats) ?? BigInt.zero;
    return '${formatAtoms((widget.amountSats + fee).toString(), 8)} BTC';
  }

  Future<void> _confirm() async {
    final tx = _tx;
    if (tx == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled; payment not sent.';
        });
        return;
      }
      final txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: tx.hex);
      if (mounted) Navigator.pop(context, txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _pretty(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Confirm Bitcoin payment', style: AmbraText.h1),
          if (widget.note != null) ...[
            const SizedBox(height: 10),
            Text(widget.note!, key: const Key('send-btc-by-address-note'), style: AmbraText.sub),
          ],
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('Amount', '${widget.amountStr} BTC'),
              _Row('To', widget.address, mono: true),
              _Row('Network', 'Bitcoin testnet4'),
              _Row('Network fee', _loading ? 'estimating…' : (_tx != null ? _feeStr() : 'unavailable')),
              if (!_loading && _tx != null) _Row('Total', _totalStr()),
            ]),
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(
              label: 'Confirm & send',
              busy: _busy,
              icon: Icons.fingerprint,
              onPressed: (_busy || _loading || _tx == null) ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

/// Review + send a restricted (OpenAMP) asset. Two-phase, like [_ReviewSheet]:
/// `_prepare` drafts the transfer and VERIFIES it on-device (recompute every
/// enclave sighash, refuse on any mismatch, decode the real effects) before the
/// user sees anything; `_confirm` signs the locally recomputed digests and
/// completes it. The signing key never leaves the phone, and the wallet never
/// blind-signs the server's digest (spec 0.4(3)).
class _OpenampReviewSheet extends StatefulWidget {
  const _OpenampReviewSheet({
    required this.recipientAid,
    required this.assetId,
    required this.atoms,
    required this.ticker,
    required this.amountStr,
  });
  final String recipientAid;
  final String assetId;
  final BigInt atoms;
  final String ticker;
  final String amountStr;

  @override
  State<_OpenampReviewSheet> createState() => _OpenampReviewSheetState();
}

class _OpenampReviewSheetState extends State<_OpenampReviewSheet> {
  bool _busy = false; // signing + completing
  bool _loading = true; // drafting + verifying + decoding
  String? _error;
  OpenampPrepared? _prepared;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final prepared = await OpenAmpService.instance.prepareTransfer(
        mnemonic: m,
        assetId: widget.assetId,
        recipientAid: widget.recipientAid,
        atoms: widget.atoms,
      );
      if (mounted) {
        setState(() {
          _prepared = prepared;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _pretty(e);
          _loading = false;
        });
      }
    }
  }

  String _tickerOf(String assetHex) => SeqAssets.labelFor(assetHex).ticker;
  int _precisionOf(String assetHex) => SeqAssets.labelFor(assetHex).precision;

  /// The decoded, locally verified effects as review rows.
  List<Widget> _effectRows() {
    final p = _prepared;
    if (p == null) return const [];
    final e = p.effects;
    final rows = <Widget>[];
    final spent = e.myInputsSpent.length;
    rows.add(_Row('Spending', '$spent of your ${widget.ticker} enclave ${spent == 1 ? 'output' : 'outputs'}'));
    if (p.convertAtoms != null && p.convertAtoms! > BigInt.zero) {
      rows.add(_Row('Fee (converted)',
          '${formatAtoms(p.convertAtoms!.toString(), _precisionOf(widget.assetId))} ${widget.ticker} (in-asset)'));
    }
    for (final o in e.outputs) {
      if (o.isFee) continue; // the fee is summarised above
      final amt = (o.value != null && o.asset != null)
          ? '${formatAtoms(o.value!.toString(), _precisionOf(o.asset!))} ${_tickerOf(o.asset!)}'
          : 'confidential';
      final dest = o.mine ? 'to you (change/receipt)' : 'to recipient';
      rows.add(_Row('Output', '$amt · $dest'));
    }
    return rows;
  }

  Future<void> _confirm() async {
    final prepared = _prepared;
    if (prepared == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled; payment not sent.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final txid = await OpenAmpService.instance.completePrepared(prepared, m);
      if (mounted) Navigator.pop(context, txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _pretty(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _prepared;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Confirm transfer', style: AmbraText.h1),
          const SizedBox(height: 18),
          if (_loading)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
          else if (p != null) ...[
            AmbraCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(children: [
                _Row('Amount', '${widget.amountStr} ${widget.ticker}'),
                _Row('To (AID)', widget.recipientAid, mono: true),
                _Row('Via', 'OpenAMP enclave (verified on-device)'),
                ..._effectRows(),
              ]),
            ),
            if (p.effects.anyConfidential)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                    'This transfer contains confidential outputs the wallet cannot fully decode. '
                    'Review carefully before signing.',
                    style: TextStyle(color: AmbraColors.red)),
              ),
          ],
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(
              label: 'Confirm & sign',
              busy: _busy,
              icon: Icons.fingerprint,
              onPressed: (_busy || _loading || _prepared == null) ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.k, this.v, {this.mono = false});
  final String k;
  final String v;
  final bool mono;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 90, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: mono ? AmbraText.mono : AmbraText.body)),
        ]),
      );
}

String _pretty(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  if (s.toLowerCase().contains('insufficient') || s.contains('InsufficientFunds')) {
    return 'Not enough funds to cover the amount plus the network fee. Try a smaller amount.';
  }
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
