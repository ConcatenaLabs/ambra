import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The scripts of this wallet's own addresses that a hosted node's device signer may let a
/// cooperative close pay this side's balance to (`SeqlnSigner.approveCloseDestination`).
///
/// The device keeps none across a start, and a close can finish after the signer was rebuilt
/// (the app restarted while the peer negotiated, or the link dropped), so they are kept here per
/// LSP node key and named again whenever that node's signer is built. The node key is derived
/// from the wallet's own seed, so two wallets never share a list. The twin of the web wallet's
/// `swk.ln.closeTo.v1`.
///
/// Persisted in SharedPreferences: a script is public (it is on chain once the close confirms),
/// never key material.
class CloseDestinations {
  static const _key = 'ambra.ln.closeTo.v1';

  /// The most scripts kept per node: the newest win.
  static const keep = 20;

  static final _hex = RegExp(r'^([0-9a-f]{2})+$');

  static Future<Map<String, List<String>>> _all() async {
    final p = await SharedPreferences.getInstance();
    try {
      final raw = p.getString(_key);
      if (raw == null) return {};
      final j = jsonDecode(raw) as Map;
      return {
        for (final e in j.entries)
          '${e.key}': [for (final s in (e.value as List)) '$s'].where(_hex.hasMatch).toList(),
      };
    } catch (_) {
      return {};
    }
  }

  /// The scripts named for [nodeKey], oldest first.
  static Future<List<String>> forNode(String nodeKey) async =>
      (await _all())[nodeKey.toLowerCase()] ?? const [];

  /// Record [scriptHex] for [nodeKey]. Throws on a script that is not hex.
  static Future<void> add(String nodeKey, String scriptHex) async {
    final k = nodeKey.toLowerCase(), hex = scriptHex.toLowerCase();
    if (k.isEmpty || !_hex.hasMatch(hex)) {
      throw ArgumentError('a node key and a script in hex are required');
    }
    final all = await _all();
    final list = all[k] ?? <String>[];
    if (list.contains(hex)) return;
    final next = [...list, hex];
    all[k] = next.length > keep ? next.sublist(next.length - keep) : next;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(all));
  }
}
