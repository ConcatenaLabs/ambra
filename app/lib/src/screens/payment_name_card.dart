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
        ] else if (name == null)
          SecondaryButton(
            key: const Key('payment-name-choose'),
            label: NameWords.choose,
            icon: Icons.alternate_email,
            onPressed: () => setState(() {
              _editing = true;
              _status = null;
            }),
          )
        else ...[
          SelectableText(name, key: const Key('payment-name-address'), style: AmbraText.mono.copyWith(fontSize: 15)),
          const SizedBox(height: 12),
          SecondaryButton(
            label: NameWords.copy,
            icon: Icons.copy,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: name));
              ScaffoldMessenger.of(context).showSnackBar(ambraSnack(NameWords.copied));
            },
          ),
          GhostButton(label: _busy ? NameWords.removing : NameWords.remove, onPressed: _remove),
        ],
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(_status!, style: TextStyle(color: _err ? AmbraColors.red : AmbraColors.dim)),
        ],
      ]),
    );
  }
}
