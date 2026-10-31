import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'fee_asset_rule.dart' show feeRateFor;
import 'format.dart' show groupThousands;
import 'price_service.dart';
import 'seqln_signer.dart';

/// The daily Lightning payment limit the phone's signer holds this wallet's hosted nodes to.
///
/// The device approves a payment only within what the limit leaves for the day. The limit is
/// one value in the reference unit, the unit the node's fee exchange rates are quoted in (the
/// price feed's US dollar on the testnet), held in each asset at its rate, so it is worth the
/// same in every asset and privileges none. 1,000 a day by default, the device's own default:
/// it covers everyday spending and bounds what a host could have the device approve in a day.
/// Developer mode sets another figure; user mode shows only the refusal when it bites.
///
/// The rates come from the wallet's own feed (`/feerates`, and `/prices` for Bitcoin, which the
/// node's table does not list), never from the hosted node.
class LnPaymentLimit extends ChangeNotifier {
  LnPaymentLimit._();
  static final LnPaymentLimit instance = LnPaymentLimit._();

  /// Reference units a day.
  static const int defaultReference = 1000;
  static const _key = 'ambra.ln.daily_limit_ref';
  static final BigInt _atomsPerUnit = BigInt.from(100000000);

  int _reference = defaultReference;
  bool _loaded = false;
  int get reference => _reference;

  Future<void> load() async {
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _reference = p.getInt(_key) ?? defaultReference;
    } catch (_) {
      _reference = defaultReference;
    }
    notifyListeners();
  }

  /// Sets the limit (whole reference units a day, at least 1).
  Future<void> set(int reference) async {
    if (reference < 1) throw ArgumentError('the limit must be at least 1');
    _reference = reference;
    _loaded = true;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_key, reference);
  }

  /// Gives [signer] the limit and the rates of [assets] (asset ids; [kBtcKey] for Bitcoin).
  /// An asset whose rate cannot be read keeps the device's own limit for an asset it cannot
  /// value. Never throws: a signer without rates still serves.
  Future<void> applyTo(SeqlnSigner signer, Iterable<String> assets) async {
    if (!_loaded) await load();
    signer.setReferencePaymentLimit(BigInt.from(_reference) * _atomsPerUnit);
    Map<String, BigInt> rates = const {};
    try {
      rates = await ApiClient.feeRates();
    } catch (_) {}
    for (final a in assets) {
      final BigInt? rate = a == kBtcKey ? _btcRate() : feeRateFor(rates, a);
      if (rate == null) continue;
      try {
        signer.setAssetRate(a, rate);
      } catch (_) {}
    }
  }

  /// The signer's name for Bitcoin.
  static const kBtcKey = 'btc';

  /// Bitcoin's rate in the node's convention (reference atoms per 10^8 sats): its price in the
  /// reference unit times 10^8.
  BigInt? _btcRate() {
    final p = PriceService.instance.usdPrice('BTC');
    if (p == null || !p.isFinite || p <= 0) return null;
    return BigInt.from((p * 1e8).round());
  }

  /// What the daily limit is worth in [asset] (an asset id; [kBtcKey] for Bitcoin), in its
  /// atoms (sats for Bitcoin), or null when its rate cannot be read now.
  Future<BigInt?> allowanceAtoms(String asset) async {
    if (!_loaded) await load();
    BigInt? rate;
    if (asset == kBtcKey) {
      rate = _btcRate();
    } else {
      try {
        rate = feeRateFor(await ApiClient.feeRates(), asset);
      } catch (_) {}
    }
    if (rate == null || rate <= BigInt.zero) return null;
    return BigInt.from(_reference) * _atomsPerUnit * _atomsPerUnit ~/ rate;
  }

  /// Whether [e] is the device declining a payment over its limit.
  static bool isRefusal(Object e) {
    final s = e.toString();
    return s.contains('Your device declined') || s.contains('invoice was declined') || s.contains('over the daily limit');
  }

  /// The words a declined payment gets.
  String refusal() =>
      'This payment is over the daily limit your phone sets for Lightning payments '
      '(about ${groupThousands('$_reference')} USD a day). Nothing was sent.';

  /// [e] in plain words when it is the device declining a payment over its limit, else as it came.
  static Object explain(Object e) {
    final s = e.toString();
    if (s.contains('Your device declined') || s.contains('invoice was declined')) {
      return Exception(instance.refusal());
    }
    return e;
  }
}
