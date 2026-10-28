import 'dart:convert';

/// A wallet's one receive code: a BIP321 payment request carrying every way the wallet
/// takes a payment, so whoever pays picks the way that fits what they send. The same
/// format as the web wallet's (`pay-code.js` in sequentia-web-wallet):
///
///     bitcoin:<address>?ark=<Ark address>&sequentia=<receive request>
///
/// - `address`: the wallet's address, the same tb1 address on both chains; what any Bitcoin
///   wallet pays, and the way of last resort for every asset.
/// - `ark`: an address of the wallet's on a Bitcoin ark (Bark's own BIP321 parameter): BTC paid
///   there arrives in seconds.
/// - `sequentia`: a Sequentia receive request (single use): an asset paid there arrives in
///   seconds.
///
/// Neither extra parameter is required (no `req-` prefix), so a wallet that knows neither sees
/// a plain bitcoin: request for the address. Other BIP321 parameters are read and kept.
class PayCode {
  PayCode(
      {this.address, this.ark, this.sequentia, this.amount, this.label, this.message, this.lightning, this.other = const {}});
  final String? address;
  final String? ark;
  final String? sequentia;
  final String? amount;
  final String? label;
  final String? message;
  final String? lightning;
  final Map<String, String> other;

  // Left as they are in a value; everything else is percent-encoded (RFC 3986 unreserved and
  // the sub-delimiters a query value may hold without ambiguity).
  static final _plain = RegExp(r"[A-Za-z0-9\-._~!$'()*,;:@/]");

  static String _enc(String v) {
    final out = StringBuffer();
    for (final ch in v.runes.map(String.fromCharCode)) {
      if (_plain.hasMatch(ch)) {
        out.write(ch);
        continue;
      }
      for (final b in utf8.encode(ch)) {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String _dec(String v) {
    try {
      return Uri.decodeComponent(v.replaceAll('+', '%20'));
    } catch (_) {
      throw const FormatException('the code has a broken escape');
    }
  }

  /// The code's text.
  String build() {
    final a = address;
    if (a == null || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(a)) {
      throw const FormatException("a receive code needs the wallet's address");
    }
    final q = <(String, String)>[
      if (amount != null) ('amount', amount!),
      if (label != null && label!.isNotEmpty) ('label', label!),
      if (message != null && message!.isNotEmpty) ('message', message!),
      if (lightning != null && lightning!.isNotEmpty) ('lightning', lightning!),
      if (ark != null && ark!.isNotEmpty) ('ark', ark!),
      if (sequentia != null && sequentia!.isNotEmpty) ('sequentia', sequentia!),
    ];
    return 'bitcoin:$a${q.isEmpty ? '' : '?${q.map((p) => '${p.$1}=${_enc(p.$2)}').join('&')}'}';
  }

  /// The code [text] names, or null when it is not a bitcoin: request. Throws a
  /// [FormatException] on one the wallet cannot honour: a required parameter it does not
  /// know (BIP321's `req-`), a parameter given twice, or no way to pay at all.
  static PayCode? read(String text) {
    final m = RegExp(r'^bitcoin:([^?]*)(?:\?(.*))?$', caseSensitive: false).firstMatch(text.trim());
    if (m == null) return null;
    final known = <String, String?>{
      'ark': null,
      'sequentia': null,
      'amount': null,
      'label': null,
      'message': null,
      'lightning': null,
    };
    final other = <String, String>{};
    for (final part in (m.group(2) ?? '').split('&')) {
      if (part.isEmpty) continue;
      final i = part.indexOf('=');
      var key = (i < 0 ? part : part.substring(0, i)).toLowerCase();
      final value = i < 0 ? '' : _dec(part.substring(i + 1));
      final required = key.startsWith('req-');
      if (required) key = key.substring(4);
      if (known.containsKey(key)) {
        if (known[key] != null) throw FormatException('the code names $key twice');
        known[key] = value;
      } else if (required) {
        throw FormatException('the code asks for something this wallet cannot do ($key)');
      } else {
        other[key] = value;
      }
    }
    final address = (m.group(1) ?? '').isEmpty ? null : _dec(m.group(1)!);
    final c = PayCode(
      address: address,
      ark: known['ark'],
      sequentia: known['sequentia'],
      amount: known['amount'],
      label: known['label'],
      message: known['message'],
      lightning: known['lightning'],
      other: other,
    );
    if (c.address == null && c.ark == null && c.sequentia == null && c.lightning == null) {
      throw const FormatException('the code names no way to pay');
    }
    return c;
  }
}
