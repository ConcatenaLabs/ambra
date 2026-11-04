import 'dart:async';

import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/config.dart';
import '../data/default_words.dart';
import '../data/dev_mode.dart';
import '../data/faucet_wallet.dart';
import '../data/leaf_service.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

class FaucetScreen extends StatefulWidget {
  const FaucetScreen({super.key});
  @override
  State<FaucetScreen> createState() => _FaucetScreenState();
}

class _FaucetScreenState extends State<FaucetScreen> {
  String? _address;
  /// The wallet's id for the faucet, which pays each asset once per wallet (faucet_wallet.dart).
  String? _wallet;
  /// The faucet labels of the assets this wallet has received from the faucet.
  Set<String> _claimed = {};
  bool _busy = false;
  bool _error = false;
  bool _asLeaf = false; // developer mode, joined wallet: be paid as a leaf instead of on-chain
  String? _status;

  /// A leaf can be asked for only by a wallet that joined an operator, in developer mode.
  bool get _leafOffered => DevMode.instance.on && LeafService.instance.joined;

  /// User mode with the leaf wallet open: the faucet pays a receive code.
  bool get _userTree => !DevMode.instance.on && LeafService.instance.open;

  /// The asset id of a faucet ticker ('' = tSEQ).
  static String _hexOf(String ticker) {
    if (ticker.isEmpty) return SeqAssets.policy;
    for (final id in SeqAssets.resolvedIds) {
      if (SeqAssets.labelFor(id).ticker == ticker) return id;
    }
    return ticker;
  }

  @override
  void initState() {
    super.initState();
    _loadAddress();
  }

  Future<void> _loadAddress() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    final info = await core.receiveAddressAt(mnemonic: m, index: 0, confidential: false);
    if (!mounted) return;
    setState(() {
      _address = info.address;
      _wallet = faucetWalletIdOf(info.address);
    });
    await _loadClaimed();
  }

  Future<void> _loadClaimed() async {
    final w = _wallet;
    if (w == null) return;
    final got = await ApiClient.faucetClaimed(w);
    if (got != null && mounted) setState(() => _claimed = got);
  }

  void _paid(String asset) {
    if (mounted) setState(() => _claimed = {..._claimed, asset});
  }

  Future<void> _request(String asset) async {
    final addr = _address;
    if (addr == null || _busy) return;
    setState(() {
      _busy = true;
      _error = false;
      _status = 'Requesting from the faucet…';
    });
    try {
      if (asset == 'BTC') {
        // BTC is paid on chain to the wallet's address, the same address on both chains.
        final r = await ApiClient.faucet(addr, asset: asset, wallet: _wallet);
        _paid(r.asset);
        if (mounted) setState(() => _status = 'The faucet sent ${r.amount} BTC. It arrives after a Bitcoin block.');
        return;
      }
      if (_userTree) {
        // User mode: the faucet pays a receive code, so the coins arrive in seconds; if it
        // refuses, the same tap is paid to the address as before.
        try {
          final code = await LeafService.instance.receiveCode();
          if (code == null) throw Exception('no receive code');
          final r = await ApiClient.faucetLeaf(code, asset: asset, wallet: _wallet);
          _paid(r.asset);
          if (mounted) setState(() => _status = DefaultWords.received(r.amount, r.asset));
          // The wallet takes the coin in by itself; nothing waits on it here.
          unawaited(LeafService.instance.openingSync(by: 'faucet'));
          return;
        } catch (e) {
          // The wallet has the asset: the address is the same wallet, so it is not asked again.
          if (e is FaucetRefused && e.alreadyPaid) rethrow;
          final r = await ApiClient.faucet(addr, asset: asset, wallet: _wallet);
          _paid(r.asset);
          if (mounted) {
            setState(() => _status = 'Sent ${r.amount} ${r.asset}. It will appear on Balance once it confirms (about a minute).');
          }
          return;
        }
      }
      if (_asLeaf && _leafOffered) {
        // A receive request from the leaf wallet, paid by the faucet off the chain.
        final made = await LeafService.instance.pay('receive', {'asset': _hexOf(asset)});
        final request = (made is Map ? made['request'] : null)?.toString();
        if (request == null || request.isEmpty) throw Exception('the leaf wallet made no request');
        final r = await ApiClient.faucetLeaf(request, asset: asset, wallet: _wallet);
        _paid(r.asset);
        await LeafService.instance.refresh();
        if (mounted) setState(() => _status = 'Paid ${r.amount} ${r.asset} as a leaf. It shows under Leaves.');
      } else {
        final r = await ApiClient.faucet(addr, asset: asset, wallet: _wallet);
        _paid(r.asset);
        if (mounted) {
          setState(() => _status = 'Sent ${r.amount} ${r.asset}. It will appear on Balance once it confirms (about a minute).');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          // The faucet's own refusal is a sentence a person can act on.
          _status = e is FaucetRefused ? e.message : 'Faucet error: $e';
          if (e is FaucetRefused && e.alreadyPaid) _claimed = {..._claimed, faucetLabel(asset)};
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_loadClaimed());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Testnet faucet', style: AmbraText.title),
        iconTheme: const IconThemeData(color: AmbraColors.dim),
      ),
      body: AmbraBackground(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Get free testnet coins sent to your wallet address.', style: AmbraText.muted),
          const SizedBox(height: 6),
          const Text(FaucetWords.rule, key: Key('faucet-rule'), style: AmbraText.sub),
          const SizedBox(height: 18),
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Funding address'),
              const SizedBox(height: 10),
              _address == null
                  ? const Center(
                      child: Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(color: AmbraColors.amber)))
                  : SelectableText(_address!, style: AmbraText.mono),
            ]),
          ),
          const SizedBox(height: 20),
          const SectionLabel('Request'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final a in ['BTC', ...SeqAssets.faucetAssets])
                _FaucetButton(
                  key: Key('faucet-${faucetLabel(a)}'),
                  label: _claimed.contains(faucetLabel(a)) ? FaucetWords.received(faucetLabel(a)) : faucetLabel(a),
                  onTap: (_busy || _address == null || _claimed.contains(faucetLabel(a))) ? null : () => _request(a),
                ),
            ],
          ),
          if (_leafOffered) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('faucet-as-leaf'),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: AmbraColors.amber,
              value: _asLeaf,
              onChanged: _busy ? null : (v) => setState(() => _asLeaf = v),
              title: const Text('Receive as a leaf', style: AmbraText.body),
              subtitle: const Text('Paid off the chain through the operator you joined, to a request this wallet makes.',
                  style: AmbraText.sub),
            ),
          ],
          const SizedBox(height: 20),
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: const [
              SectionLabel('Bitcoin (testnet4)'),
              SizedBox(height: 10),
              Text(
                'Your address receives Bitcoin on testnet4 too (one address, both chains). '
                'BTC above pays it there, and it arrives after a Bitcoin block.',
                style: AmbraText.sub,
              ),
            ]),
          ),
          const SizedBox(height: 20),
          if (_status != null)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_busy) ...[
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AmbraColors.amber)),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(_status!,
                    style: TextStyle(color: _error ? AmbraColors.red : AmbraColors.green, fontSize: 13, height: 1.4)),
              ),
            ]),
        ]),
      ),
    );
  }
}

class _FaucetButton extends StatelessWidget {
  const _FaucetButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Every asset's button looks the same: none of them is the faucet's main one.
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(AmbraRadii.control),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: AmbraColors.buttonSurface,
            border: Border.all(color: AmbraColors.line),
            borderRadius: BorderRadius.circular(AmbraRadii.control),
          ),
          child: Text(label, style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}
