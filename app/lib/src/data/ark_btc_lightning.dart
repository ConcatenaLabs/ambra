/// The Bitcoin ark as the composer's Bitcoin Lightning ([BtcLightning]): in default mode a trade's
/// BTC leg is paid from the ark and received into it, as every other BTC payment is. The Dart twin
/// of the web wallet's `btc-ark.js` `lightning()`: change them together.
///
///   buying an asset with BTC   the desk's invoice is paid out of the ark, its fee capped at the
///                              one the ticket showed and its lock at the route's (the server pays
///                              with at most its HTLC-send delta less its own margin)
///   selling an asset for BTC   the wallet's invoice is the ark's: the server holds the desk's
///                              payment and the wallet claims it, learning nothing new (the ark
///                              wallet drew the preimage), so no channel room is needed
///
/// Every amount, fee and refusal is the ark wallet's or its server's; this only reads the answers.
library;

import 'dart:convert';

import '../rust/api/ark_btc.dart' as ark;
import 'ark_btc_service.dart';
import 'btc_lightning.dart';

BigInt _big(Object? v) => v is BigInt ? v : (BigInt.tryParse('${v ?? 0}') ?? BigInt.zero);

/// The ark wallet's calls, as JSON text (the core's `ark_*` functions): a seam for tests.
abstract class ArkCalls {
  Future<BigInt> spendable();
  Future<String> invoice(BigInt sats, String description);
  Future<String> receiveStatus(String hash, {required bool claim});
  Future<String> pay(String invoice, {BigInt? maxFeeSats, int? maxDelay});
  Future<String> payStatus(String hash, {required bool drive});
  Future<String> payFee(BigInt sats);
}

/// [ArkCalls] over the Rust core's open ark wallet.
class CoreArkCalls implements ArkCalls {
  const CoreArkCalls();
  @override
  Future<BigInt> spendable() async {
    await ArkBtcService.instance.refresh();
    return ArkBtcService.instance.spendable;
  }

  @override
  Future<String> invoice(BigInt sats, String description) => ark.arkInvoice(sats: sats, description: description);
  @override
  Future<String> receiveStatus(String hash, {required bool claim}) => ark.arkReceiveStatus(hash: hash, claim: claim);
  @override
  Future<String> pay(String invoice, {BigInt? maxFeeSats, int? maxDelay}) =>
      ark.arkPay(invoice: invoice, maxFeeSats: maxFeeSats, maxDelay: maxDelay, wait: true);
  @override
  Future<String> payStatus(String hash, {required bool drive}) => ark.arkPayStatus(hash: hash, drive: drive);
  @override
  Future<String> payFee(BigInt sats) => ark.arkPayFee(sats: sats);
}

class ArkBtcLightning implements BtcLightning {
  ArkBtcLightning(this.calls, {this.onMoved});
  final ArkCalls calls;

  /// Called after BTC moved in or out, so the figure is read again.
  final void Function()? onMoved;

  Map<String, dynamic> _j(String s) => Map<String, dynamic>.from(jsonDecode(s) as Map);

  @override
  Future<BigInt> balance() => calls.spendable();

  @override
  Future<Map<String, dynamic>> invoice({required BigInt sats, String description = 'trade'}) async {
    final r = _j(await calls.invoice(sats, description));
    final d = decodeBtcInvoice('${r['invoice']}');
    // The invoice is the one asked for: its amount, and the hash the wallet answered with.
    if (d['sats'] != sats || d['payment_hash'] != r['payment_hash']) throw Exception('the ark\'s invoice is not the one asked for');
    return {'invoice': r['invoice'], 'payment_hash': r['payment_hash'], 'expires_at': r['expires_at'] ?? d['expires_at']};
  }

  @override
  Future<Map<String, dynamic>> decode(String invoice) async => decodeBtcInvoice(invoice);

  @override
  Future<Map<String, dynamic>> invoiceStatus(String hash) async {
    final r = _j(await calls.receiveStatus(hash, claim: true));
    if (r['state'] == 'paid') {
      onMoved?.call();
      return {'status': 'paid', 'preimage': r['preimage']};
    }
    if (r['state'] == 'unknown') return {'status': 'unknown'};
    return {'status': 'unpaid'};
  }

  /// An ark invoice that is never paid lapses by itself; nothing is held to let go of.
  @override
  Future<void> cancelInvoice(String hash) async {}

  @override
  Future<Map<String, dynamic>> pay({required String invoice, BigInt? maxFeeSats, int? maxDelay}) async {
    Map<String, dynamic> r;
    try {
      r = _j(await calls.pay(invoice, maxFeeSats: maxFeeSats ?? BigInt.zero, maxDelay: maxDelay != null && maxDelay > 0 ? maxDelay : null));
    } catch (e) {
      // A refusal before anything moved (the fee, the lock) is the wallet's: nothing was paid.
      if (RegExp(r'refused:').hasMatch('$e')) return {'state': 'failed', 'reason': '$e'};
      // Anything else may have left a payment under way: the wallet's own record decides.
      return payStatus('${decodeBtcInvoice(invoice)['payment_hash']}');
    }
    onMoved?.call();
    if (r['state'] == 'complete') return {'state': 'complete', 'preimage': r['preimage']};
    if (r['state'] == 'failed') return {'state': 'failed', 'reason': r['reason'] ?? 'the payment failed'};
    return {'state': 'pending'};
  }

  @override
  Future<Map<String, dynamic>> payStatus(String hash) async {
    Map<String, dynamic> r;
    try {
      r = _j(await calls.payStatus(hash, drive: true));
    } catch (_) {
      return {'state': 'pending'};
    }
    if (r['state'] == 'complete') return {'state': 'complete', 'preimage': r['preimage']};
    if (r['state'] == 'none') return {'state': 'none'};
    return {'state': 'pending'};
  }

  /// The ark's fee for the invoice's amount and the longest lock its server's payment may take.
  @override
  Future<({BigInt fee, int delay})?> payRoute(String invoice) async {
    final d = decodeBtcInvoice(invoice);
    final f = _j(await calls.payFee(d['sats'] as BigInt));
    return (fee: _big(f['fee']), delay: (f['max_route_delay'] as num).toInt());
  }
}
