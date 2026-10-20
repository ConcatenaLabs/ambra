import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hidden_assets.dart' show HiddenAssets;

/// The mode's words, the same in every Sequentia wallet (Ambra, the web wallet and
/// the browser extension): change them in all three together.
class ModeWords {
  static const title = 'Mode';
  static const user = 'User mode';
  static const userLine = 'One figure per asset, and the wallet chooses how value moves.';
  static const developer = 'Developer mode';
  static const developerLine =
      'Every rail by name, side by side (on-chain, leaves and Lightning), each with its balance and its manual controls, and the developer tools.';
  static const note = 'Kept for this wallet. Sites that ask the wallet for its mode follow it.';
}

/// The wallet's mode: one setting, kept for each wallet, user mode until the user
/// changes it. Developer mode names every rail (on-chain, leaves, Lightning) with its
/// balance and its manual controls; user mode shows one figure per asset. Leaves count
/// in each figure and in the headline in both modes.
///
/// Kept in SharedPreferences under `ambra.mode.<tag>`, the tag being the wallet's
/// fingerprint as [HiddenAssets] keys it, so a different wallet recovered on this phone
/// starts in user mode. The one setting kept before (`ambra.developer_mode`) becomes the
/// first wallet's that loads, once.
class DevMode extends ChangeNotifier {
  DevMode._();
  static final DevMode instance = DevMode._();

  static const _prefix = 'ambra.mode.';
  static const _legacyKey = 'ambra.developer_mode';
  String? _tag;
  bool _on = false;
  bool get on => _on;
  String get mode => _on ? 'developer' : 'user';

  /// Before a wallet is open: user mode.
  Future<void> load() async {
    _on = false;
    notifyListeners();
  }

  /// Loads (or switches to) the mode of [mnemonic]'s wallet.
  Future<void> loadFor(String mnemonic) async {
    final tag = HiddenAssets.fingerprintOf(mnemonic);
    try {
      final p = await SharedPreferences.getInstance();
      var v = p.getString(_prefix + tag);
      if (v == null && (p.getBool(_legacyKey) ?? false)) {
        v = 'developer';
        await p.setString(_prefix + tag, v);
        await p.remove(_legacyKey);
      }
      _on = v == 'developer';
    } catch (_) {
      _on = false;
    }
    _tag = tag;
    notifyListeners();
  }

  /// Sets this wallet's mode. A no-op before [loadFor] (no wallet to keep it for).
  Future<void> set(bool on) async {
    final tag = _tag;
    if (tag == null) return;
    _on = on;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefix + tag, on ? 'developer' : 'user');
    await p.remove(_legacyKey);
  }
}
