// Report a problem: a tester describes what happened and Ambra sends it to Emissio's intake
// (POST /emissio/api/problem-reports, the contract in Emissio's README, "Problem-report
// intake"), with the app's version, its mode and its recent errors. The web wallet's
// problem-report.js and Ambra browser carry the same rules and words: change them together
// (the web wallet's docs/DEFAULT_MODE.md, "Report a problem").
//
// What leaves the phone is exactly the map [buildReport] returns, and the screen shows it
// before it is sent. It never holds the recovery phrase or a key: errors are scrubbed of
// anything shaped like an address, a key, an invoice or a long hex string before they are
// kept, and a description that carries words of the wallet's own phrase is refused. The
// address goes only when the person ticks the box that shows it.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// The words of Report a problem, the same in every Concatena wallet.
class ReportWords {
  static const title = 'Report a problem';
  static const intro = 'Tell us what went wrong. Reports help fix the testnet before more people use it.';
  static const descriptionLabel = 'What happened?';
  static const descriptionHint = 'What you did, what you expected, and what happened instead.';
  static const codeLabel = 'Emissio account code (optional)';
  static const codeHint = 'Paste it to be credited if the report is accepted.';
  static const includes =
      'The report includes this wallet\'s version, its mode and its recent errors. It never includes your recovery phrase or your keys.';
  static const addressesBox = 'Also send my address';
  static const addressesWill = 'This address will be sent:';
  static const preview = 'What will be sent';
  static const send = 'Send report';
  static const sending = 'Sending…';
  static String sent(int? id) => id == null ? 'Report sent. Thank you.' : 'Report sent. Its number is #$id. Thank you.';
  static const credited = 'If it is accepted, it is credited to your Emissio account.';
  static const codeUnknown = 'That account code was not found, so the report was sent without it.';
  static const needDescription = 'Describe what happened.';
  static const phrase = 'This looks like your recovery phrase. Never share it with anyone: remove it, then send again.';
  static const already = 'This report was already sent.';
  static const tooMany = 'Too many reports from here. Try again later.';
  static const tooLarge = 'This report is too long. Shorten it, then send again.';
  static const failed = 'The report could not be sent. Check your connection and try again.';

  static List<String> all() => [
        title, intro, descriptionLabel, descriptionHint, codeLabel, codeHint, includes, addressesBox,
        addressesWill, preview, send, sending, sent(7), sent(null), credited, codeUnknown, needDescription,
        phrase, already, tooMany, tooLarge, failed,
      ];
}

/// Where reports go: Emissio on the public testnet site, whatever node the wallet uses.
final Uri reportUrl = Uri.parse('${Backend.defaultOrigin}/emissio/api/problem-reports');

class ReportLimits {
  static const description = 4000, errors = 20, errorMessage = 500, context = 300, version = 40;
  static const addresses = 20, address = 120;
}

final _scrubs = <(RegExp, String)>[
  // Long hex: private keys, txids, blinding keys.
  (RegExp(r'\b[0-9a-fA-F]{32,}\b'), '[hex]'),
  // bech32 / blech32 strings: addresses, invoices, encoded keys (a prefix, "1", the data).
  (RegExp(r'\b[a-z0-9]{1,40}1[02-9ac-hj-np-z]{20,}\b', caseSensitive: false), '[address]'),
  // base58 strings: legacy addresses, WIF keys, extended keys.
  (RegExp(r'\b[1-9A-HJ-NP-Za-km-z]{25,}\b'), '[key]'),
];

/// [text] with anything shaped like a secret or an identifier of the person's coins replaced.
String scrub(String text) {
  var t = text;
  for (final (re, by) in _scrubs) {
    t = t.replaceAll(re, by);
  }
  return t;
}

/// True when [text] carries three or more consecutive words of [phrase], in order.
bool carriesPhrase(String? text, String? phrase) {
  final words = (phrase ?? '').trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length < 3) return false;
  final said = (text ?? '').toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toList();
  for (var i = 0; i + 3 <= words.length; i++) {
    for (var j = 0; j + 3 <= said.length; j++) {
      if (said[j] == words[i] && said[j + 1] == words[i + 1] && said[j + 2] == words[i + 2]) return true;
    }
  }
  return false;
}

/// One error the app met: when, and its scrubbed message.
class ReportError {
  ReportError(this.at, this.message);
  final DateTime at;
  String message;
  Map<String, String> toJson() => {'at': at.toUtc().toIso8601String(), 'message': message};
}

/// The app's recent errors: the last twenty, scrubbed, a repeat of the newest folded in.
/// main.dart feeds it Flutter's and the platform's uncaught errors; a screen may [note] one
/// it shows.
class ErrorLog {
  ErrorLog([this.limit = ReportLimits.errors]);
  static final ErrorLog instance = ErrorLog();
  final int limit;
  final List<ReportError> _items = [];

  void note(Object? error, {DateTime? at}) {
    var m = scrub('$error').trim();
    if (m.length > ReportLimits.errorMessage) m = m.substring(0, ReportLimits.errorMessage);
    if (m.isEmpty) return;
    final when = at ?? DateTime.now();
    if (_items.isNotEmpty && _items.last.message == m) {
      _items[_items.length - 1] = ReportError(when, m);
      return;
    }
    _items.add(ReportError(when, m));
    if (_items.length > limit) _items.removeAt(0);
  }

  List<ReportError> list() => List.unmodifiable(_items);
}

String _cut(String? s, int n) {
  final t = (s ?? '').trim();
  return t.length > n ? t.substring(0, n) : t;
}

/// The payload of one report, exactly as it is sent.
Map<String, Object> buildReport({
  required String version,
  required String mode,
  required String description,
  String? accountCode,
  List<ReportError> errors = const [],
  Map<String, String?> context = const {},
  List<String> addresses = const [],
}) {
  final report = <String, Object>{
    'v': 1,
    'wallet': 'ambra-mobile',
    'version': _cut(version, ReportLimits.version),
    'mode': mode == 'developer' ? 'developer' : 'default',
    'description': _cut(description, ReportLimits.description),
  };
  final code = _cut(accountCode, 64);
  if (code.isNotEmpty) report['account_code'] = code;
  final recent = errors.length > ReportLimits.errors ? errors.sublist(errors.length - ReportLimits.errors) : errors;
  report['errors'] = [
    for (final e in recent) {'at': e.at.toUtc().toIso8601String(), 'message': _cut(scrub(e.message), ReportLimits.errorMessage)},
  ];
  final ctx = <String, String>{
    for (final MapEntry(:key, :value) in context.entries)
      if (value != null && value.isNotEmpty) key: _cut(value, ReportLimits.context),
  };
  if (ctx.isNotEmpty) report['context'] = ctx;
  final addrs = [for (final a in addresses.where((a) => a.isNotEmpty).take(ReportLimits.addresses)) _cut(a, ReportLimits.address)];
  if (addrs.isNotEmpty) report['attached'] = {'addresses': addrs};
  return report;
}

/// Checks before sending: one sentence, or null when the report may go.
String? refusal(Map<String, Object> report, String? phrase) {
  final description = report['description'] as String? ?? '';
  if (description.isEmpty) return ReportWords.needDescription;
  if (carriesPhrase(description, phrase) || carriesPhrase(report['account_code'] as String?, phrase)) {
    return ReportWords.phrase;
  }
  return null;
}

/// What the intake answered, in this wallet's words.
class ReportResult {
  const ReportResult.sent(this.id, this.account) : message = null;
  const ReportResult.refused(this.message)
      : id = null,
        account = null;
  final int? id;
  final String? account;
  final String? message;
  bool get ok => message == null;

  /// The sentence shown once a report is sent.
  String get words {
    if (!ok) return message!;
    final s = [ReportWords.sent(id)];
    if (account == 'linked') s.add(ReportWords.credited);
    if (account == 'unknown') s.add(ReportWords.codeUnknown);
    return s.join(' ');
  }
}

/// Sends one report. The answer is in this wallet's words, whatever the service said.
Future<ReportResult> sendReport(Map<String, Object> report, {http.Client? client, Uri? url}) async {
  final c = client ?? http.Client();
  try {
    final r = await c
        .post(url ?? reportUrl, headers: {'Content-Type': 'application/json'}, body: jsonEncode(report))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 201) {
      int? id;
      String account = 'none';
      try {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        id = (body['id'] as num?)?.toInt();
        account = body['account'] as String? ?? 'none';
      } catch (_) {}
      return ReportResult.sent(id, account);
    }
    return ReportResult.refused(switch (r.statusCode) {
      409 => ReportWords.already,
      429 => ReportWords.tooMany,
      413 => ReportWords.tooLarge,
      _ => ReportWords.failed,
    });
  } catch (_) {
    return const ReportResult.refused(ReportWords.failed);
  } finally {
    if (client == null) c.close();
  }
}
