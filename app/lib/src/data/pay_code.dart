import 'dart:convert';

import 'package:qr/qr.dart';

/// A wallet's one receive code: a BIP321 payment request carrying every way the wallet takes
/// a payment, so whoever pays picks the way that fits what they send. The same format as the
/// web wallet's and Ambra browser's (`pay-code.js` in sequentia-web-wallet, whose header is the
/// format's full description); change all three together.
///
///     BITCOIN:<ADDRESS>?ark=<ARK ADDRESS>&sequentia=<RECEIVE REQUEST>
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
///
/// Made to be scanned at a glance: the scheme and every bech32 part are upper case, which a QR
/// code holds in its alphanumeric mode ([payCodeQr]), and the receive request travels short
/// (`SQR1…`, [compactRequest]): only what a payer on the same operator and chain cannot know.
/// Such a payer rebuilds the library's request with its own operator and genesis
/// ([expandRequest]). Codes made before the short form are read as they always were.
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

  /// The code's text. A `sequentia` request in the library's spelling goes in short when it can.
  String build() {
    final a = address;
    if (a == null || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(a)) {
      throw const FormatException("a receive code needs the wallet's address");
    }
    final seq = sequentia;
    final short = seq == null ? null : compactRequest(seq);
    final q = <(String, String)>[
      if (amount != null) ('amount', _enc(amount!)),
      if (label != null && label!.isNotEmpty) ('label', _enc(label!)),
      if (message != null && message!.isNotEmpty) ('message', _enc(message!)),
      if (lightning != null && lightning!.isNotEmpty) ('lightning', _enc(_up(lightning!))),
      if (ark != null && ark!.isNotEmpty) ('ark', _enc(_up(ark!))),
      if (seq != null && seq.isNotEmpty) ('sequentia', short != null ? short.toUpperCase() : _enc(seq)),
    ];
    return 'BITCOIN:${_up(a)}${q.isEmpty ? '' : '?${q.map((p) => '${p.$1}=${p.$2}').join('&')}'}';
  }

  /// The code [text] names, or null when it is not a bitcoin: request. Bech32 parts come back
  /// in lower case; `sequentia` as the code carries it ([expandRequest] makes it payable).
  /// Throws a [FormatException] on one the wallet cannot honour: a required parameter it does
  /// not know (BIP321's `req-`), a parameter given twice, or no way to pay at all.
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
        known[key] = (key == 'ark' || key == 'lightning' || key == 'sequentia') ? _down(value) : value;
      } else if (required) {
        throw FormatException('the code asks for something this wallet cannot do ($key)');
      } else {
        other[key] = value;
      }
    }
    final address = (m.group(1) ?? '').isEmpty ? null : _down(_dec(m.group(1)!));
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

// ---- bech32 and bech32m (BIP173, BIP350), without BIP173's 90-character limit ----------------

const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const _bech32 = 1, _bech32m = 0x2bc830a3;

int _polymod(Iterable<int> values) {
  const g = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if ((top >> i) & 1 == 1) chk ^= g[i];
    }
  }
  return chk;
}

List<int> _hrpExpand(String hrp) =>
    [for (final c in hrp.codeUnits) c >> 5, 0, for (final c in hrp.codeUnits) c & 31];

List<int>? _convert(List<int> data, int from, int to, bool pad) {
  var acc = 0, bits = 0;
  final out = <int>[], max = (1 << to) - 1;
  for (final v in data) {
    acc = ((acc << from) | v) & 0xffffff;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.add((acc >> bits) & max);
    }
  }
  if (pad) {
    if (bits > 0) out.add((acc << (to - bits)) & max);
  } else if (bits >= from || ((acc << (to - bits)) & max) != 0) {
    return null;
  }
  return out;
}

/// [s] as a human part, its 5-bit words and its checksum constant, or null when it is not
/// bech32 or bech32m.
(String, List<int>, int)? _bechParts(String s) {
  if (s != s.toLowerCase() && s != s.toUpperCase()) return null;
  final l = s.toLowerCase(), p = l.lastIndexOf('1');
  if (p < 1 || p + 7 > l.length || l.length > 2000) return null;
  final hrp = l.substring(0, p);
  if (hrp.codeUnits.any((c) => c < 33 || c > 126)) return null;
  final data = <int>[];
  for (final c in l.substring(p + 1).split('')) {
    final d = _charset.indexOf(c);
    if (d < 0) return null;
    data.add(d);
  }
  final sum = _polymod([..._hrpExpand(hrp), ...data]);
  return (sum == _bech32 || sum == _bech32m) ? (hrp, data, sum) : null;
}

String bech32mEncode(String hrp, List<int> bytes) {
  final data = _convert(bytes, 8, 5, true)!;
  final mod = _polymod([..._hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0]) ^ _bech32m;
  final chk = [for (var i = 0; i < 6; i++) (mod >> (5 * (5 - i))) & 31];
  return '${hrp}1${[...data, ...chk].map((d) => _charset[d]).join()}';
}

/// [s]'s human part and bytes, or null when it is not bech32m with a good checksum.
(String, List<int>)? bech32mDecode(String s) {
  final p = _bechParts(s);
  if (p == null || p.$3 != _bech32m) return null;
  final bytes = _convert(p.$2.sublist(0, p.$2.length - 6), 5, 8, false);
  return bytes == null ? null : (p.$1, bytes);
}

String _up(String v) => _bechParts(v) != null ? v.toUpperCase() : v;
String _down(String v) => _bechParts(v) != null ? v.toLowerCase() : v;

// ---- the short receive request -------------------------------------------------------------

const requestHrp = 'sqr';
const _fV2 = 1, _fLanding = 2, _fAsset = 4, _fValue = 8, _fChannels = 16;
const _carried = {
  'kind', 'genesis_hash', 'operator', 'owner', 'owner_nonce', 'mailbox', 'exit_delay_units',
  'until', 'landing', 'asset', 'value', 'template', 'channels',
};

bool _isHex(Object? s, int n) => s is String && s.length == 2 * n && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);
List<int> _hexBytes(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
String _bytesHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The library's request text (`<word>:<hex of its JSON>`) as its JSON, or null.
Map<String, dynamic>? libraryRequest(String text) {
  final s = text.trim();
  final i = s.indexOf(':');
  if (i <= 0) return null;
  final prefix = s.substring(0, i), hex = s.substring(i + 1);
  if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(prefix) || hex.isEmpty || hex.length.isOdd) return null;
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
  try {
    final v = jsonDecode(utf8.decode(_hexBytes(hex)));
    if (v is! Map) return null;
    return (v['kind'] == 'request' || v.containsKey('arca_request')) ? Map<String, dynamic>.from(v) : null;
  } catch (_) {
    return null;
  }
}

/// The library's request text in its short form (`sqr1…`, lower case), or null when the
/// request carries anything the short form does not (it is then kept as it is).
String? compactRequest(String text) {
  final r = libraryRequest(text);
  if (r == null || r['kind'] != 'request') return null;
  if (r.keys.any((k) => !_carried.contains(k))) return null;
  for (final k in ['operator', 'genesis_hash', 'owner', 'owner_nonce', 'mailbox']) {
    if (!_isHex(r[k], 32)) return null;
  }
  final delay = r['exit_delay_units'], until = r['until'];
  if (delay is! int || delay < 0 || delay > 0xffff) return null;
  if (until is! int || until < 0 || until > 0xffffffff) return null;
  if (r.containsKey('template') && r['template'] != 'vtxo-2') return null;
  if (r.containsKey('landing') && !_isHex(r['landing'], 20)) return null;
  if (r.containsKey('asset') && !_isHex(r['asset'], 32)) return null;
  BigInt? value;
  if (r.containsKey('value')) {
    final v = r['value'];
    if (v is! String || !RegExp(r'^\d+$').hasMatch(v)) return null;
    value = BigInt.parse(v);
    if (value >= BigInt.one << 64) return null;
  }
  List<MapEntry<String, dynamic>>? channels;
  if (r.containsKey('channels')) {
    final c = r['channels'];
    if (c is! Map || c.isEmpty || c.length > 255) return null;
    channels = [for (final e in c.entries) MapEntry('${e.key}', e.value)];
    if (channels.any((e) => !_isHex(e.key, 32) || !_isHex(e.value, 32))) return null;
  }
  var flags = 0;
  if (r.containsKey('template')) flags |= _fV2;
  if (r.containsKey('landing')) flags |= _fLanding;
  if (r.containsKey('asset')) flags |= _fAsset;
  if (value != null) flags |= _fValue;
  if (channels != null) flags |= _fChannels;
  final b = <int>[
    1, flags,
    ..._hexBytes(r['operator'] as String).sublist(0, 4),
    ..._hexBytes(r['genesis_hash'] as String).sublist(0, 4),
    ..._hexBytes(r['owner'] as String),
    ..._hexBytes(r['owner_nonce'] as String),
    ..._hexBytes(r['mailbox'] as String),
    delay >> 8, delay & 0xff, (until >> 24) & 0xff, (until >> 16) & 0xff, (until >> 8) & 0xff, until & 0xff,
  ];
  if (r.containsKey('landing')) b.addAll(_hexBytes(r['landing'] as String));
  if (r.containsKey('asset')) b.addAll(_hexBytes(r['asset'] as String));
  if (value != null) {
    for (var i = 7; i >= 0; i--) {
      b.add(((value >> (8 * i)) & BigInt.from(0xff)).toInt());
    }
  }
  if (channels != null) {
    b.add(channels.length);
    for (final e in channels) {
      b
        ..addAll(_hexBytes(e.key))
        ..addAll(_hexBytes(e.value as String));
    }
  }
  return bech32mEncode(requestHrp, b);
}

/// The short form's operator and genesis prefixes and the library's request less those two,
/// or null when [text] is not one.
({String operatorPrefix, String genesisPrefix, Map<String, dynamic> request})? readShortRequest(String text) {
  final d = bech32mDecode(text.trim());
  if (d == null || d.$1 != requestHrp) return null;
  final b = d.$2;
  if (b.length < 112 || b[0] != 1) return null;
  final flags = b[1];
  if (flags & ~31 != 0) return null;
  String at(int i, int n) => _bytesHex(b.sublist(i, i + n));
  final r = <String, dynamic>{
    'kind': 'request',
    'owner': at(10, 32),
    'owner_nonce': at(42, 32),
    'mailbox': at(74, 32),
    'exit_delay_units': (b[106] << 8) | b[107],
    'until': (b[108] << 24) + (b[109] << 16) + (b[110] << 8) + b[111],
  };
  var i = 112;
  int? need(int n) {
    if (i + n > b.length) return null;
    final s = i;
    i += n;
    return s;
  }

  if (flags & _fLanding != 0) {
    final s = need(20);
    if (s == null) return null;
    r['landing'] = at(s, 20);
  }
  if (flags & _fAsset != 0) {
    final s = need(32);
    if (s == null) return null;
    r['asset'] = at(s, 32);
  }
  if (flags & _fValue != 0) {
    final s = need(8);
    if (s == null) return null;
    var v = BigInt.zero;
    for (var k = 0; k < 8; k++) {
      v = (v << 8) | BigInt.from(b[s + k]);
    }
    r['value'] = v.toString();
  }
  if (flags & _fV2 != 0) r['template'] = 'vtxo-2';
  if (flags & _fChannels != 0) {
    final c = need(1);
    if (c == null || b[c] == 0) return null;
    final ch = <String, String>{};
    for (var k = 0; k < b[c]; k++) {
      final s = need(64);
      if (s == null) return null;
      ch[at(s, 32)] = at(s + 32, 32);
    }
    r['channels'] = ch;
  }
  if (i != b.length) return null;
  return (operatorPrefix: at(2, 4), genesisPrefix: at(6, 4), request: r);
}

/// A receive request as a code carries it (short, or in the library's spelling) as the
/// library's request text a payer on [operator] and [genesis] pays, or null when it is not
/// for them.
String? expandRequest(String text, {required String operator, required String genesis}) {
  if (!_isHex(operator, 32) || !_isHex(genesis, 32)) return null;
  final s = text.trim();
  final short = readShortRequest(s);
  if (short == null) {
    final r = libraryRequest(s);
    return (r != null && r['operator'] == operator && r['genesis_hash'] == genesis) ? s : null;
  }
  if (operator.substring(0, 8).toLowerCase() != short.operatorPrefix) return null;
  if (genesis.substring(0, 8).toLowerCase() != short.genesisPrefix) return null;
  final rest = Map<String, dynamic>.from(short.request)..remove('kind');
  final json = jsonEncode({'kind': 'request', 'genesis_hash': genesis, 'operator': operator, ...rest});
  return 'arca:${_bytesHex(utf8.encode(json))}';
}

// ---- the picture ---------------------------------------------------------------------------

/// QR alphanumeric mode's characters.
final _alnum = RegExp(r'^[0-9A-Z $%*+\-./:]$');

/// The QR code of a receive code, at error-correction level M and the smallest version that
/// holds it: runs of upper-case characters go in alphanumeric mode (5.5 bits each), the rest
/// (`?ark=`, `&sequentia=`, anything lower case) in byte mode. A run too short to repay a mode
/// change stays in the bytes around it.
QrCode payCodeQr(String text, {int level = QrErrorCorrectLevel.M}) {
  final runs = <(bool, String)>[];
  for (final ch in text.split('')) {
    final a = _alnum.hasMatch(ch);
    if (runs.isNotEmpty && runs.last.$1 == a) {
      runs[runs.length - 1] = (a, runs.last.$2 + ch);
    } else {
      runs.add((a, ch));
    }
  }
  // An alphanumeric run shorter than this costs more in segment headers than it saves.
  const minRun = 12;
  final segs = <(bool, String)>[];
  for (final run in runs) {
    final r = (run.$1 && run.$2.length < minRun && runs.length > 1) ? (false, run.$2) : run;
    if (segs.isNotEmpty && segs.last.$1 == r.$1) {
      segs[segs.length - 1] = (r.$1, segs.last.$2 + r.$2);
    } else {
      segs.add(r);
    }
  }
  for (var v = 1; v <= 40; v++) {
    final q = QrCode(v, level);
    for (final s in segs) {
      s.$1 ? q.addAlphaNumeric(s.$2) : q.addData(s.$2);
    }
    try {
      QrImage(q);
      return q;
    } on InputTooLongException {
      continue;
    }
  }
  throw const FormatException('the code is too long for a QR code');
}
