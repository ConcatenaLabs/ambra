// Report a problem (data/problem_report.dart): what happened, an optional Emissio account
// code, and the address only when ticked. The exact report is shown under "What will be
// sent" as it changes, and sent to Emissio's intake.

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/dev_mode.dart';
import '../data/problem_report.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, this.phrase, this.address, this.client, this.url});

  /// The wallet's phrase for the check before sending (it is never sent). Defaults to the
  /// open wallet's.
  final Future<String?> Function()? phrase;

  /// The wallet's address, shown and sent only when ticked. Defaults to the open wallet's.
  final Future<String?> Function()? address;
  final http.Client? client;
  final Uri? url;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _text = TextEditingController();
  final _code = TextEditingController();
  bool _withAddress = false;
  String? _address;
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;

  Future<String?> _phrase() => (widget.phrase ?? () => WalletRepository.instance.readMnemonic())();

  Future<String?> _readAddress() async {
    if (widget.address != null) return widget.address!();
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return null;
    return core.receiveAddress(mnemonic: m);
  }

  Map<String, Object> _report() => buildReport(
        version: kAppVersion,
        mode: DevMode.instance.on ? 'developer' : 'default',
        description: _text.text,
        accountCode: _code.text,
        errors: ErrorLog.instance.list(),
        context: {
          'platform': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
          'network': 'testnet',
        },
        addresses: _withAddress && _address != null ? [_address!] : const [],
      );

  void _edited(String _) {
    setState(() {
      if (_statusIsError) _status = null;
    });
  }

  Future<void> _tick(bool? v) async {
    final on = v ?? false;
    if (on && _address == null) {
      try {
        _address = await _readAddress();
      } catch (e) {
        ErrorLog.instance.note(e);
      }
    }
    if (mounted) setState(() => _withAddress = on && _address != null);
  }

  Future<void> _send() async {
    final r = _report();
    final no = refusal(r, await _phrase());
    if (no != null) {
      setState(() {
        _status = no;
        _statusIsError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = ReportWords.sending;
      _statusIsError = false;
    });
    final res = await sendReport(r, client: widget.client, url: widget.url);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = res.words;
      _statusIsError = !res.ok;
      if (res.ok) {
        _text.clear();
        _withAddress = false;
      }
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final payload = const JsonEncoder.withIndent('  ').convert(_report());
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(ReportWords.title, style: AmbraText.title),
        iconTheme: const IconThemeData(color: AmbraColors.dim),
      ),
      body: AmbraBackground(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text(ReportWords.intro, style: AmbraText.muted),
          const SizedBox(height: 18),
          AmbraField(
            key: const Key('report-text'),
            label: ReportWords.descriptionLabel,
            hint: ReportWords.descriptionHint,
            controller: _text,
            maxLines: 5,
            onChanged: _edited,
          ),
          const SizedBox(height: 14),
          AmbraField(key: const Key('report-code'), label: ReportWords.codeLabel, controller: _code, mono: true, onChanged: _edited),
          const SizedBox(height: 6),
          const Text(ReportWords.codeHint, style: AmbraText.sub),
          const SizedBox(height: 14),
          const Text(ReportWords.includes, style: AmbraText.sub),
          CheckboxListTile(
            key: const Key('report-address'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: AmbraColors.amber,
            value: _withAddress,
            onChanged: _busy ? null : _tick,
            title: const Text(ReportWords.addressesBox, style: AmbraText.body),
          ),
          if (_withAddress) ...[
            const Text(ReportWords.addressesWill, style: AmbraText.sub),
            const SizedBox(height: 4),
            SelectableText(_address ?? '', key: const Key('report-address-value'), style: AmbraText.mono),
            const SizedBox(height: 10),
          ],
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const Key('report-preview'),
              tilePadding: EdgeInsets.zero,
              iconColor: AmbraColors.dim,
              collapsedIconColor: AmbraColors.dim,
              title: const Text(ReportWords.preview, style: AmbraText.sub),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(payload, key: const Key('report-payload'), style: AmbraText.mono.copyWith(fontSize: 11)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          PrimaryButton(key: const Key('report-send'), label: ReportWords.send, busy: _busy, onPressed: _send),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!,
                key: const Key('report-status'),
                style: AmbraText.body.copyWith(color: _statusIsError ? AmbraColors.red : AmbraColors.green)),
          ],
        ]),
      ),
    );
  }
}
