import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The wallet's mode. Developer mode shows every rail by name (on-chain, leaves,
/// Lightning) with each one's balance and its manual controls; user mode keeps the
/// production view. Off by default.
class DevMode extends ChangeNotifier {
  DevMode._();
  static final DevMode instance = DevMode._();

  static const _key = 'ambra.developer_mode';
  bool _on = false;
  bool get on => _on;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _on = p.getBool(_key) ?? false;
    } catch (_) {
      _on = false;
    }
    notifyListeners();
  }

  Future<void> set(bool on) async {
    _on = on;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key, on);
  }
}
