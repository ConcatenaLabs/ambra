import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as core;
import 'ark_btc_service.dart';
import 'ark_limits.dart';
import 'btc_state.dart';
import 'config.dart';
import 'dev_mode.dart';
import 'leaf_service.dart';
import 'lnaddr.dart';
import 'name_key.dart';
import 'price_service.dart';
import 'wallet_repository.dart';

/// The open wallet's payment name ([LnAddress]), on the default node only: the name lives at that
/// node's domain and its invoices come from the Bitcoin ark, which only the default node has.
/// While the app runs and the wallet holds a name, it answers the service's requests: an invoice
/// of the Bitcoin ark for the amount a payer chose, or a new receive code.
class PaymentNameService extends ChangeNotifier {
  PaymentNameService._();
  static final PaymentNameService instance = PaymentNameService._();

  /// What a payer may send, in sats: from this up to the ark's largest coin, under what goes to
  /// the address straight away, never above [maxSat] (the web wallet's LNADDR_MIN_SAT/MAX_SAT).
  static final minSat = BigInt.from(1000), maxSat = BigInt.from(1000000);

  LnAddress? _a;
  ({List<int> priv, String pub})? _key;
  String? _tag;

  /// The receive index the code shows now: a payer of the name is given a code at it.
  int Function() receiveIndex = () => BtcState.instance.unifiedNext;

  bool get available => _a != null;
  String? get name => _a?.name;
  String? get address => _a?.address;
  String? get lnurl => _a?.lnurl;
  String get domain => Backend.lnaddrDomain ?? '';

  /// Opens the name of the wallet now open: its key, the name kept for it, the name its key holds
  /// at the service, and the link that answers payers.
  Future<void> start() async {
    final domain = Backend.lnaddrDomain;
    if (domain == null) return;
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    final tag = DevMode.instance.tag ?? 'default';
    if (_a != null && _tag == tag) return;
    stop();
    _tag = tag;
    try {
      _key = await compute(_keyOf, m);
    } catch (e) {
      debugPrint('[lnaddr] no name key: $e');
      return;
    }
    final prefKey = 'ambra.lnaddr.name.$tag';
    _a = LnAddress(
      base: Backend.lsp,
      domain: domain,
      key: () => _key,
      invoice: (msat) => ArkBtcService.instance.invoice(msat ~/ BigInt.from(1000)),
      code: _code,
      limits: _limits,
      load: () async => (await SharedPreferences.getInstance()).getString(prefKey),
      save: (n) async {
        final p = await SharedPreferences.getInstance();
        n == null ? await p.remove(prefKey) : await p.setString(prefKey, n);
      },
      log: (s) => debugPrint(s),
      onChange: notifyListeners,
    );
    await _a!.recover();
    _a!.start();
    notifyListeners();
  }

  void stop() {
    _a?.stop();
    _a = null;
    _key = null;
    _tag = null;
    notifyListeners();
  }

  Future<String> register(String name) async {
    final a = _a;
    if (a == null) throw const LnAddressError('The name could not be saved. Check your connection and try again.');
    return a.register(name);
  }

  Future<void> release() async => _a?.release();

  static ({List<int> priv, String pub}) _keyOf(String phrase) {
    final k = nameKey(phrase);
    return (priv: k.priv, pub: k.pub);
  }

  /// A new receive code for a payer: the address at the code's index, an address of the Bitcoin
  /// ark and a new receive request, as far as each can be had now.
  Future<String> _code() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw StateError('no wallet is open');
    final address = (await core.receiveAddressAt(mnemonic: m, index: receiveIndex(), confidential: false)).address;
    String? ark, seq;
    try {
      if (ArkBtcService.instance.open) ark = await ArkBtcService.instance.address();
    } catch (_) {}
    try {
      seq = await LeafService.instance.receiveCode();
    } catch (_) {}
    return nameCode(address: address, ark: ark, sequentia: seq);
  }

  ({BigInt min, BigInt max})? _limits() {
    final ark = ArkBtcService.instance;
    if (!ark.open) return null;
    var max = maxSat;
    final largest = ark.maxBoard;
    if (largest != null && largest < max) max = largest;
    final l = arkLimitsNow().btc;
    final d = usdAtoms(directUsd(l), PriceService.instance.usdPrice('BTC'), 8);
    if (d != null && d - BigInt.one < max) max = d - BigInt.one;
    return max >= minSat ? (min: minSat, max: max) : null;
  }
}
