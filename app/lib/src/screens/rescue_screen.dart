import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/asset_picker.dart';
import '../data/config.dart';
import '../data/fee_asset_rule.dart';
import '../data/format.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/asset_sheet.dart';
import '../widgets/widgets.dart';

enum RescueMode { bump, replace, cpfp }

/// Action chooser for an unconfirmed tx → runs the chosen rescue. Returns a
/// txid if one was broadcast (caller refreshes history).
Future<String?> showRescueActions(BuildContext context, core.TxRow tx) async {
  final outgoing = tx.kind == 'outgoing' ||
      tx.deltas.any((d) => (BigInt.tryParse(d.atoms) ?? BigInt.zero) < BigInt.zero);
  final action = await showModalBottomSheet<RescueMode>(
    context: context,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16), child: Text('Rescue unconfirmed payment', style: AmbraText.title)),
        if (outgoing)
          ListTile(
            leading: const Icon(Icons.trending_up, color: AmbraColors.amber2),
            title: const Text('Bump fee', style: AmbraText.body),
            subtitle: const Text('Re-send the same payment at a higher fee (RBF)', style: AmbraText.sub),
            onTap: () => Navigator.pop(context, RescueMode.bump),
          ),
        if (outgoing)
          ListTile(
            leading: const Icon(Icons.edit_outlined, color: AmbraColors.amber2),
            title: const Text('Replace', style: AmbraText.body),
            subtitle: const Text('Replace it with new outputs (different address, asset, or amount)',
                style: AmbraText.sub),
            onTap: () => Navigator.pop(context, RescueMode.replace),
          ),
        ListTile(
          leading: const Icon(Icons.bolt, color: AmbraColors.amber2),
          title: const Text('Speed up', style: AmbraText.body),
          subtitle: const Text('Pay a child fee in any asset to pull it in (CPFP)', style: AmbraText.sub),
          onTap: () => Navigator.pop(context, RescueMode.cpfp),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (action == null || !context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) =>
        action == RescueMode.replace ? _RescueReplaceSheet(tx: tx) : _RescueFeeSheet(tx: tx, mode: action),
  );
}

/// The fee asset and rate of a rescue. The asset follows the wallet rule
/// ([walletFeeAsset]) from the asset the transaction moves; the rate field is in
/// that asset's own units per vByte, and keeps its value in reference terms when
/// the user picks another asset.
class _RescueFee {
  _RescueFee(this.refPerVb);
  final rate = TextEditingController();
  double refPerVb; // reference atoms per vByte
  Map<String, BigInt> rates = {};
  Map<String, BigInt> largest = {};
  String? asset; // null = nothing the node accepts

  String get label => asset == null ? '—' : SeqAssets.labelFor(asset!).ticker;

  /// Held assets the node accepts for fees, tSEQ judged like any other.
  List<String> options(Map<String, BigInt> held) =>
      [for (final e in held.entries) if (e.value > BigInt.zero && feeRateFor(rates, e.key) != null) e.key];

  void choose(String? moved, {String? spendsAllOf}) {
    asset = walletFeeAsset(moved: moved, rates: rates, largestCoin: largest, exclude: {?spendsAllOf});
    show();
  }

  void show() {
    final a = asset;
    if (a == null) return;
    rate.text = formatAssetRate(assetRateFromReference(refPerVb, feeRateFor(rates, a)!, SeqAssets.labelFor(a).precision));
  }

  /// Keep what is typed, in reference terms, before the asset changes.
  void remember() {
    final a = asset;
    final v = double.tryParse(rate.text.trim());
    if (a == null || v == null || v <= 0) return;
    refPerVb = referenceKvbFromAssetRate(v, feeRateFor(rates, a)!, SeqAssets.labelFor(a).precision) / 1000;
  }

  /// The core's arguments for what is typed, or an error to show.
  ({core.FeeAsset? param, double kvb, String? error}) read() {
    final a = asset;
    if (a == null) return (param: null, kvb: 0, error: noFeeAssetMessage);
    final v = double.tryParse(rate.text.trim());
    if (v == null || v <= 0) return (param: null, kvb: 0, error: 'Enter a fee rate');
    final r = feeRateFor(rates, a)!;
    return (param: feeAssetParam(a, r), kvb: referenceKvbFromAssetRate(v, r, SeqAssets.labelFor(a).precision), error: null);
  }

  Future<void> pick(BuildContext context, Map<String, BigInt> held, VoidCallback changed) async {
    final picked = await showAssetSheet(
      context,
      title: 'Pay fee in',
      rows: [
        for (final id in options(held))
          AssetPickerItem(hex: id, ticker: SeqAssets.labelFor(id).ticker, name: SeqAssets.labelFor(id).subtitle),
      ],
      balanceOf: (id) => formatAtoms((held[id] ?? BigInt.zero).toString(), SeqAssets.labelFor(id).precision),
    );
    if (picked == null) return;
    remember();
    asset = picked;
    show();
    changed();
  }
}

Map<String, BigInt> _heldMap(List<core.AssetBalance> balances) =>
    {for (final b in balances) b.assetId: BigInt.tryParse(b.atoms) ?? BigInt.zero};

class _RescueFeeSheet extends StatefulWidget {
  const _RescueFeeSheet({required this.tx, required this.mode});
  final core.TxRow tx;
  final RescueMode mode;
  @override
  State<_RescueFeeSheet> createState() => _RescueFeeSheetState();
}

class _RescueFeeSheetState extends State<_RescueFeeSheet> {
  final _fee = _RescueFee(10); // an aggressive rescue rate: 10 reference atoms per vByte
  List<core.AssetBalance> _balances = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _isBump => widget.mode == RescueMode.bump;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _fee.rate.dispose();
    super.dispose();
  }

  /// The asset the stuck transaction paid its fee in: the one it moves for the rule.
  String get _txFeeAsset => widget.tx.feeAsset.isEmpty ? SeqAssets.policy : widget.tx.feeAsset;

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      Map<String, BigInt> rates = {};
      try {
        rates = await ApiClient.feeRates();
      } catch (_) {}
      double? suggested;
      if (!_isBump) {
        try {
          // Target 10 sat/vB (10000 sat/kvB) for the whole package; the returned
          // child rate (sat/kvB) is sized from the parent's vsize.
          suggested = await core.cpfpSuggestedFeerate(
              mnemonic: m, esploraUrl: Backend.esplora, parentTxid: widget.tx.txid, targetFeerate: 10000.0);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _balances = s.balances;
        _fee.rates = rates;
        _fee.largest = largestCoinsOf(s);
        // The suggested child rate is in reference atoms per kvB.
        if (suggested != null && suggested > 0) {
          final vb = (suggested / 1000).ceil();
          _fee.refPerVb = (vb < 1 ? 1 : vb).toDouble();
        }
        _fee.choose(_txFeeAsset);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  String _balanceOf(String id) {
    for (final b in _balances) {
      if (b.assetId == id) return b.atoms;
    }
    return '0';
  }

  Future<void> _confirm() async {
    final f = _fee.read();
    if (f.error != null) {
      setState(() => _error = f.error);
      return;
    }
    final rate = f.kvb;
    final feeAsset = f.param;
    final feeBal = BigInt.tryParse(_balanceOf(_fee.asset!)) ?? BigInt.zero;
    if (feeBal <= BigInt.zero) {
      setState(() => _error = 'You have no ${_fee.label} to pay the fee with.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final String pset;
      if (_isBump) {
        pset = await core.buildRbfBumpTx(
            mnemonic: m, esploraUrl: Backend.esplora, txid: widget.tx.txid, feeRateSatKvb: rate, feeAsset: feeAsset);
      } else {
        pset = await core.buildCpfpTx(
            mnemonic: m, esploraUrl: Backend.esplora, parentTxid: widget.tx.txid, feeRateSatKvb: rate, feeAsset: feeAsset);
      }
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
    final held = _heldMap(_balances);
    final canFeeAsset = _fee.options(held).length > 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: _loading
            ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_isBump ? 'Bump fee' : 'Speed up (CPFP)', style: AmbraText.h1),
                const SizedBox(height: 6),
                Text(
                  _isBump
                      ? 'Re-broadcasts the same payment with a higher fee. Must exceed the original (in reference value).'
                      : 'Spends the stuck output with a high-fee child to pull both in. Can\'t fix a wrong fee asset; use Replace.',
                  style: AmbraText.sub,
                ),
                const SizedBox(height: 18),
                const SectionLabel('Pay fee in'),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(AmbraRadii.input),
                  onTap: canFeeAsset ? () => _fee.pick(context, held, () => setState(() {})) : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: AmbraColors.panelDeep,
                      border: Border.all(color: AmbraColors.line),
                      borderRadius: BorderRadius.circular(AmbraRadii.input),
                    ),
                    child: Row(children: [
                      Text(_fee.label, style: AmbraText.body),
                      const Spacer(),
                      if (canFeeAsset) const Icon(Icons.expand_more, color: AmbraColors.dim, size: 20),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                AmbraField(label: 'Fee rate (${_fee.label}/vB)', controller: _fee.rate),
                const SizedBox(height: 16),
                if (_error != null)
                  Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
                PrimaryButton(label: 'Confirm & sign', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
                const SizedBox(height: 6),
                GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
              ]),
      ),
    );
  }
}

/// A tappable field (asset / fee-asset picker) used by the replace sheet.
class _RescuePicker extends StatelessWidget {
  const _RescuePicker({required this.label, this.onTap});
  final String label;
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
          if (onTap != null) const Icon(Icons.expand_more, color: AmbraColors.dim, size: 20),
        ]),
      ),
    );
  }
}

/// Replace a still-unconfirmed payment with brand-new outputs (RBF): same inputs,
/// a fresh recipient, asset, and amount. The replacement's fee must exceed the
/// original's, so it carries an aggressive default rate too.
class _RescueReplaceSheet extends StatefulWidget {
  const _RescueReplaceSheet({required this.tx});
  final core.TxRow tx;
  @override
  State<_RescueReplaceSheet> createState() => _RescueReplaceSheetState();
}

class _RescueReplaceSheetState extends State<_RescueReplaceSheet> {
  final _addr = TextEditingController();
  final _amount = TextEditingController();
  final _fee = _RescueFee(10); // an aggressive rate: 10 reference atoms per vByte
  List<core.AssetBalance> _balances = [];
  String? _assetId; // the asset the replacement sends; the original's until the user picks
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addr.dispose();
    _amount.dispose();
    _fee.rate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      Map<String, BigInt> rates = {};
      try {
        rates = await ApiClient.feeRates();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _balances = s.balances;
        _fee.rates = rates;
        _fee.largest = largestCoinsOf(s);
        // The replacement sends what the original sent (the asset it took the most of), never a
        // preferred asset; the fee follows it by the wallet rule.
        _assetId ??= _originalAsset();
        _fee.choose(_assetId);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  List<String> _heldIds() => _balances
      .where((b) => (BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero)
      .map((b) => b.assetId)
      .toList();
  String _balanceOf(String id) {
    for (final b in _balances) {
      if (b.assetId == id) return b.atoms;
    }
    return '0';
  }

  /// The asset the original transaction moved out of this wallet the most of.
  String? _originalAsset() {
    String? best;
    BigInt most = BigInt.zero;
    for (final d in widget.tx.deltas) {
      final out = -(BigInt.tryParse(d.atoms) ?? BigInt.zero);
      if (out > most) {
        most = out;
        best = d.assetId;
      }
    }
    return best;
  }

  Future<void> _pickAsset() async {
    final held = _heldIds();
    final picked = await showAssetSheet(
      context,
      title: 'Choose asset',
      rows: [
        for (final id in held)
          AssetPickerItem(hex: id, ticker: SeqAssets.labelFor(id).ticker, name: SeqAssets.labelFor(id).subtitle),
      ],
      balanceOf: (id) => formatAtoms(_balanceOf(id), SeqAssets.labelFor(id).precision),
    );
    if (picked == null) return;
    setState(() {
      _fee.remember();
      _assetId = picked;
      _fee.choose(picked);
    });
  }

  Future<void> _confirm() async {
    final assetId = _assetId;
    if (assetId == null) return setState(() => _error = 'Choose the asset to send');
    final label = SeqAssets.labelFor(assetId);
    final addr = _addr.text.trim();
    final atoms = parseAtoms(_amount.text, label.precision);
    if (addr.isEmpty) return setState(() => _error = 'Enter a recipient address');
    if (atoms == null || atoms <= BigInt.zero) return setState(() => _error = 'Enter a valid amount');
    if (atoms >= (BigInt.one << 64)) return setState(() => _error = 'Amount is too large');
    final f = _fee.read();
    if (f.error != null) return setState(() => _error = f.error);
    final feeAsset = f.param;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final pset = await core.buildRbfReplaceTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        txid: widget.tx.txid,
        newRecipients: [core.Recipient(address: addr, assetId: assetId, satoshi: atoms)],
        feeRateSatKvb: f.kvb,
        feeAsset: feeAsset,
      );
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
    final label = SeqAssets.labelFor(_assetId ?? '');
    final held = _heldIds();
    final heldMap = _heldMap(_balances);
    final canFeeAsset = _fee.options(heldMap).length > 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: _loading
            ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
            : SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Replace payment', style: AmbraText.h1),
                  const SizedBox(height: 6),
                  const Text(
                    'Keeps the original inputs but sends new outputs, replacing it before it confirms. '
                    'The new fee must exceed the original\'s.',
                    style: AmbraText.sub,
                  ),
                  const SizedBox(height: 16),
                  const SectionLabel('Asset'),
                  const SizedBox(height: 8),
                  _RescuePicker(
                    label: _assetId == null ? '—' : label.ticker,
                    onTap: held.isEmpty ? null : _pickAsset,
                  ),
                  const SizedBox(height: 14),
                  AmbraField(label: 'Recipient address', controller: _addr, hint: 'tb1… or tsqb1…', mono: true),
                  const SizedBox(height: 14),
                  AmbraField(label: 'Amount (${label.ticker})', controller: _amount, hint: '0.0'),
                  const SizedBox(height: 14),
                  const SectionLabel('Pay fee in'),
                  const SizedBox(height: 8),
                  _RescuePicker(
                    label: _fee.label,
                    onTap: canFeeAsset ? () => _fee.pick(context, heldMap, () => setState(() {})) : null,
                  ),
                  const SizedBox(height: 14),
                  AmbraField(label: 'Fee rate (${_fee.label}/vB)', controller: _fee.rate),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
                  PrimaryButton(label: 'Confirm & sign', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
                  const SizedBox(height: 6),
                  GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
                ]),
              ),
      ),
    );
  }
}

String _pretty(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  final low = s.toLowerCase();
  if (low.contains('not enough additional fees') ||
      low.contains('replacement') ||
      low.contains('bad-txns-spends-conflicting')) {
    return 'The new fee must exceed the original; raise the fee rate and try again.';
  }
  if (low.contains('insufficient')) {
    return 'Not enough funds for the higher fee. Try a smaller fee, or pay it in another accepted asset.';
  }
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
