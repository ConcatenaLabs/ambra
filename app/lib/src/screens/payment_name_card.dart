import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/dev_mode.dart';
import '../data/lnaddr.dart';
import '../data/payment_name_service.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// "Your payment name", under the receive code: a name of the wallet's own at the node's domain,
/// which another wallet pays in an amount it chooses, a Lightning wallet included. The web
/// wallet's name box, in the contract's words (sequentia-web-wallet `docs/DEFAULT_MODE.md`).
class PaymentNameCard extends StatefulWidget {
  const PaymentNameCard({super.key});
  @override
  State<PaymentNameCard> createState() => _PaymentNameCardState();
}

class _PaymentNameCardState extends State<PaymentNameCard> {
  final _input = TextEditingController();
  bool _editing = false, _busy = false;
  String? _status;
  bool _err = false;

  @override
  void initState() {
    super.initState();
    PaymentNameService.instance.addListener(_changed);
    DevMode.instance.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PaymentNameService.instance.removeListener(_changed);
    DevMode.instance.removeListener(_changed);
    _input.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final want = _input.text.trim().toLowerCase();
    final p = nameProblem(want);
    if (p != null) {
      return setState(() {
        _status = p;
        _err = true;
      });
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await PaymentNameService.instance.register(want);
      _editing = false;
    } catch (e) {
      _status = '$e';
      _err = true;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Get a name / Use a word name instead: the wallet's word name, in one tap.
  Future<void> _words() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await PaymentNameService.instance.claimWordName();
      _editing = false;
    } catch (e) {
      _status = '$e';
      _err = true;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _quiet(Key key, String label, VoidCallback? onPressed) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: key,
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 4), foregroundColor: AmbraColors.dim),
          onPressed: onPressed,
          child: Text(label, style: const TextStyle(decoration: TextDecoration.underline, color: AmbraColors.dim)),
        ),
      );

  Future<void> _remove() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await PaymentNameService.instance.release();
    } catch (e) {
      _status = '$e';
      _err = true;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = PaymentNameService.instance;
    final dev = DevMode.instance.on;
    final name = svc.address;
    return AmbraCard(
      key: const Key('payment-name'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionLabel(dev ? NameWords.devLabel : NameWords.label),
        const SizedBox(height: 12),
        Text(name != null ? (dev ? NameWords.devTip : NameWords.tip) : NameWords.none, style: AmbraText.sub),
        const SizedBox(height: 12),
        if (_editing) ...[
          AmbraField(
            key: const Key('payment-name-input'),
            label: NameWords.choose,
            controller: _input,
            hint: NameWords.hint,
            mono: true,
            suffix: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text('@${svc.domain}', style: AmbraText.sub),
            ),
          ),
          const SizedBox(height: 12),
          PrimaryButton(label: _busy ? NameWords.saving : NameWords.save, busy: _busy, onPressed: _save),
          GhostButton(label: NameWords.cancel, onPressed: () => setState(() {
                    _editing = false;
                    _status = null;
                  })),
        ] else if (name == null) ...[
          // Get a name: the wallet's word name in one tap; Choose your own, a quiet link.
          PrimaryButton(
            key: const Key('payment-name-get'),
            label: _busy ? NameWords.getting : NameWords.getName,
            busy: _busy,
            onPressed: _words,
          ),
          const SizedBox(height: 4),
          _quiet(const Key('payment-name-choose'), NameWords.choose, _busy
              ? null
              : () => setState(() {
                    _editing = true;
                    _status = null;
                  })),
        ] else ...[
          // Shown with a capital for each word of a word name; copied in lower case, as the QR holds it.
          SelectableText(svc.display ?? name, key: const Key('payment-name-address'), style: AmbraText.mono.copyWith(fontSize: 15)),
          const SizedBox(height: 12),
          SecondaryButton(
            label: NameWords.copy,
            icon: Icons.copy,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: nameQrText(name)));
              ScaffoldMessenger.of(context).showSnackBar(ambraSnack(NameWords.copied));
            },
          ),
          GhostButton(label: _busy ? NameWords.removing : NameWords.remove, onPressed: _remove),
          if (!svc.isWordName) _quiet(const Key('payment-name-words'), _busy ? NameWords.getting : NameWords.useWords, _busy ? null : _words),
        ],
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(_status!, style: TextStyle(color: _err ? AmbraColors.red : AmbraColors.dim)),
        ],
      ]),
    );
  }
}
