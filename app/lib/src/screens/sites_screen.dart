/// Connect to a site: scan its code or paste its link, approve the pairing, see the sites
/// connected and forget one. A connected site's trades are approved in [showSiteApproval]'s sheet.
/// Every word is a [SiteLinkWords] entry (none of default mode's forbidden words).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/site_link.dart';
import '../data/site_service.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'scan_screen.dart';

class SitesScreen extends StatefulWidget {
  const SitesScreen({super.key});
  @override
  State<SitesScreen> createState() => _SitesScreenState();
}

class _SitesScreenState extends State<SitesScreen> {
  final _paste = TextEditingController();

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (code != null && mounted) await openPairing(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final link = AmbraSites.instance.link;
    return Scaffold(
      appBar: AppBar(title: const Text(SiteLinkWords.entry)),
      body: ListenableBuilder(
        listenable: link,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            const Text(SiteLinkWords.entryLine, style: AmbraText.muted),
            const SizedBox(height: 16),
            SecondaryButton(key: const Key('site-scan'), label: SiteLinkWords.scan, icon: Icons.qr_code_scanner, onPressed: _scan),
            const SizedBox(height: 12),
            TextField(
              key: const Key('site-paste'),
              controller: _paste,
              decoration: const InputDecoration(labelText: SiteLinkWords.paste, hintText: SiteLinkWords.pasteHint),
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            SecondaryButton(
              key: const Key('site-paste-go'),
              label: SiteLinkWords.pasteGo,
              onPressed: () async {
                final t = _paste.text.trim();
                if (t.isEmpty) return;
                if (await openPairing(context, t)) _paste.clear();
              },
            ),
            const SizedBox(height: 24),
            const SectionLabel(SiteLinkWords.paired),
            const SizedBox(height: 8),
            if (link.sites.isEmpty) const Text(SiteLinkWords.none, style: AmbraText.sub),
            for (final s in link.sites)
              AmbraCard(
                key: Key('site-${s.clientPubkey.substring(0, 8)}'),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.name, style: AmbraText.title),
                          Text('${SiteLinkWords.saysItIs}: ${s.url ?? SiteLinkWords.noAddress}', style: AmbraText.sub),
                        ],
                      ),
                    ),
                    GhostButton(label: SiteLinkWords.forget, onPressed: () => link.forget(s)),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            const Text(SiteLinkWords.openOnly, style: AmbraText.sub),
          ],
        ),
      ),
    );
  }
}

/// Reads a pairing code and asks its owner to approve the pairing. True once paired.
Future<bool> openPairing(BuildContext context, String text) async {
  final PairingUri u;
  try {
    u = parsePairingUri(text);
  } on FormatException catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(ambraSnack(e.message));
    return false;
  }
  final ok = await showSiteApproval(
    context,
    SiteApproval(SiteLinkWords.pairTitle(u.name), SiteLinkWords.pairText, [
      (SiteLinkWords.site, u.name),
      (SiteLinkWords.saysItIs, u.url ?? SiteLinkWords.noAddress),
      ('', SiteLinkWords.check),
    ]),
  );
  if (!ok) return false;
  await AmbraSites.instance.link.pair(u);
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(ambraSnack(SiteLinkWords.connectedTo(u.name)));
  return true;
}

/// The approval sheet: what is asked, the rows, Approve or Decline. Closing it declines, and so
/// does leaving it [kSiteWindow]: the sheet closes by itself then.
Future<bool> showSiteApproval(BuildContext context, SiteApproval a) async {
  BuildContext? sheet;
  final lapse = Timer(kSiteWindow, () {
    final c = sheet;
    if (c != null && c.mounted) Navigator.of(c).pop(false);
  });
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (ctx) {
      sheet = ctx;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            key: const Key('site-approval'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(a.title, style: AmbraText.h1),
              const SizedBox(height: 8),
              Text(a.text, style: AmbraText.muted),
              const SizedBox(height: 16),
              for (final (k, v) in a.rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: k.isEmpty
                      ? Text(v, style: AmbraText.sub)
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 120, child: Text(k, style: AmbraText.sub)),
                            Expanded(child: Text(v, style: AmbraText.body)),
                          ],
                        ),
                ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: GhostButton(key: const Key('site-decline'), label: SiteLinkWords.decline, onPressed: () => Navigator.pop(ctx, false)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PrimaryButton(key: const Key('site-approve'), label: SiteLinkWords.approve, onPressed: () => Navigator.pop(ctx, true)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  sheet = null;
  lapse.cancel();
  return r == true;
}
