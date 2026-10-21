import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/config.dart';
import '../data/contract_summary.dart';
import '../data/drip_rate.dart';
import '../data/wallet_repository.dart';
import '../rust/api/contracts.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Prepares a spend: the ask (`{templateHash, instance, request | drip, fund?}`) in,
/// the engine's summary out, as JSON.
typedef ContractPrepare = Future<String> Function(String askJson);

/// Signs the spend prepared under the digest shown; returns the txid.
typedef ContractSign = Future<String> Function(String shownDigest);

/// Developer mode: a spend of a contract the kit carries (a faucet drip covenant,
/// a Pignus version 2 vault or offer, ...), signed under the five-point rule. The
/// request is pasted in the shape a site hands the browser extension's
/// `signContractSpend`. The kit's contract engine checks it against this wallet,
/// funding it from this wallet's own coins when asked, runs every program against the
/// final transaction, and writes the summary shown here; Sign signs only the digest of
/// that summary. Every refusal is shown in the engine's words.
class ContractsScreen extends StatefulWidget {
  const ContractsScreen({super.key, this.prepare, this.sign, this.initialAsk = ''});

  final ContractPrepare? prepare;
  final ContractSign? sign;
  final String initialAsk;

  @override
  State<ContractsScreen> createState() => _ContractsScreenState();
}

class _ContractsScreenState extends State<ContractsScreen> {
  late final TextEditingController _ask = TextEditingController(text: widget.initialAsk);
  Map<String, dynamic>? _summary;
  String? _error;
  String? _txid;
  bool _busy = false;

  static String _labels() {
    final m = <String, dynamic>{};
    for (final id in SeqAssets.resolvedIds) {
      final l = SeqAssets.labelFor(id);
      m[id] = {'ticker': l.ticker, 'precision': l.precision};
    }
    return jsonEncode(m);
  }

  Future<String> _prepare(String ask) async {
    if (widget.prepare != null) return widget.prepare!(ask);
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw 'no wallet is open';
    // A drip's fee is paid in the dripped asset: value its default rate at the node's rate.
    final priced = ask.contains('"drip"') ? dripAskAtNodeRate(ask, await ApiClient.feeRates()) : ask;
    return core.contractPrepare(mnemonic: m, esploraUrl: Backend.esplora, askJson: priced, labelsJson: _labels());
  }

  Future<String> _sign(String digest) async {
    if (widget.sign != null) return widget.sign!(digest);
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw 'no wallet is open';
    return core.contractSign(mnemonic: m, esploraUrl: Backend.esplora, shownDigest: digest);
  }

  Future<void> _review() async {
    setState(() { _busy = true; _error = null; _summary = null; _txid = null; });
    try {
      final s = jsonDecode(await _prepare(_ask.text.trim())) as Map<String, dynamic>;
      setState(() => _summary = s);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final shown = _summary;
    if (shown == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final txid = await _sign(shown['digest'] as String);
      setState(() { _txid = txid; _summary = null; });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cancel() {
    final d = _summary?['digest'] as String?;
    if (d != null && widget.prepare == null) core.contractDiscard(digest: d);
    setState(() => _summary = null);
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return Scaffold(
      backgroundColor: AmbraColors.bg,
      appBar: AppBar(
        backgroundColor: AmbraColors.bg,
        foregroundColor: AmbraColors.txt,
        title: const Text('Contracts', style: AmbraText.title),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('contracts-list'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            AmbraCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('The spend'),
                const Text(
                  'Paste the request: {"templateHash", "instance", "request" or "drip", "fund"}. '
                  'The wallet signs only for a template it carries, and only what it shows here.',
                  style: AmbraText.sub,
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('contract-ask'),
                  controller: _ask,
                  minLines: 4,
                  maxLines: 12,
                  style: AmbraText.mono,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                PrimaryButton(key: const Key('contract-review'), label: 'Review', busy: _busy && s == null, onPressed: _busy ? null : _review),
              ]),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, key: const Key('contract-error'), style: AmbraText.body.copyWith(color: AmbraColors.red)),
            ],
            if (_txid != null) ...[
              const SizedBox(height: 12),
              SelectableText('Broadcast $_txid', key: const Key('contract-done'), style: AmbraText.mono),
            ],
            if (s != null) ...[
              const SizedBox(height: 14),
              AmbraCard(
                key: const Key('contract-approval'),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Sign this contract spend?', style: AmbraText.title),
                  for (final sec in summarySections(s)) ...[
                    const SizedBox(height: 12),
                    SectionLabel(sec.title),
                    for (final (k, v) in sec.rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(k, style: AmbraText.sub),
                          SelectableText(v, style: AmbraText.body),
                        ]),
                      ),
                  ],
                  const SizedBox(height: 14),
                  PrimaryButton(key: const Key('contract-sign'), label: 'Sign and broadcast', busy: _busy, onPressed: _busy ? null : _approve),
                  const SizedBox(height: 8),
                  SecondaryButton(key: const Key('contract-cancel'), label: 'Cancel', onPressed: _busy ? null : _cancel),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
