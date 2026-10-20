/// The summary the kit's contract engine writes for a spend, in the sections the
/// Contracts screen shows: the same sections, in the same order, as the web wallet's
/// and the browser extension's approval (`approvalSections` in their contracts.js).
/// The engine wrote every value; nothing here computes one.
class SummarySection {
  const SummarySection(this.title, this.rows);
  final String title;
  final List<(String, String)> rows;
}

String _s(Object? v) => v == null ? '' : v.toString();

List<Map<String, dynamic>> _list(Object? v) =>
    (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

List<SummarySection> summarySections(Map<String, dynamic> s) {
  final t = Map<String, dynamic>.from(s['template'] as Map);
  final p = Map<String, dynamic>.from(s['path'] as Map);
  final checks = Map<String, dynamic>.from(s['checks'] as Map);
  final contract = Map<String, dynamic>.from(s['contract'] as Map);
  final out = <SummarySection>[
    SummarySection('Template', [
      ('Template', _s(t['shown'])),
      ('What it is', _s(t['summary'])),
      if (t['registered'] != true) ('It names itself', '${_s(t['names_itself'])} v${_s(t['version'])} (not checked by any registry)'),
      ('Template hash', _s(t['hash'])),
    ]),
    SummarySection('Path', [
      ('Path', '${_s(p['name'])} (${_s(p['kind'])} leaf ${_s(p['leaf'])})'),
      ('Who can take it', _s(p['who'])),
      ('What it does', _s(p['effect'])),
    ]),
    SummarySection('Parameters', [for (final x in _list(s['params'])) ('${_s(x['label'])} [${_s(x['role'])}]', _s(x['shown']))]),
  ];
  final slots = _list(s['slots']);
  if (slots.isNotEmpty) out.add(SummarySection('State', [for (final x in slots) ('${_s(x['label'])} [${_s(x['role'])}]', _s(x['shown']))]));
  final spender = _list(s['spender']);
  if (spender.isNotEmpty) out.add(SummarySection('Values the spender chose', [for (final x in spender) (_s(x['name']), _s(x['value']))]));
  final inputs = _list(s['inputs']);
  if (inputs.isNotEmpty) {
    out.add(SummarySection('What it spends', [
      for (final i in inputs) ...[
        ('Input ${_s(i['index'])}', _s(i['shown'])),
        if (i['request_says'] != null) ('Input ${_s(i['index'])}, as the request calls it', '${_s(i['request_says'])} (the request\'s word, not checked)'),
        if (i['is'] == 'foreign')
          ('Input ${_s(i['index'])}, checked against the chain', i['checked_against_chain'] == true ? 'yes: the chain\'s record of the coin is what the request says' : 'no'),
      ],
    ]));
  }
  out.add(SummarySection('Your balance change', [for (final c in _list(s['wallet_change'])) ('This wallet', _s(c['shown']))]));
  for (final o in _list(s['opens'])) {
    out.add(SummarySection('Output ${_s(o['index'])} opens a contract', [
      ('Opens', _s(o['shown'])),
      ('What it is', _s(o['summary'])),
      ('Template hash', _s(o['template_hash'])),
      for (final x in _list(o['params'])) ('${_s(x['label'])} [${_s(x['role'])}]', _s(x['shown'])),
      for (final x in _list(o['slots'])) ('${_s(x['label'])} [${_s(x['role'])}]', _s(x['shown'])),
    ]));
  }
  out.add(SummarySection('Where the coins go', [
    for (final c in _list(contract['change'])) ('The contract', _s(c['shown'])),
    for (final x in _list(s['payments'])) ('Pays output ${_s(x['index'])}', '${_s(x['shown'])} to script ${_s(x['script_pubkey'])}'),
    for (final f in _list(s['fee'])) ('Network fee', '${_s(f['shown'])} (${_s(s['vsize'])} vB)'),
  ]));
  out.add(SummarySection('Checked before signing', [
    ('1. Known template', _s(checks['1_known_template'])),
    ('2. Output recomputed', _s(checks['2_output_recomputed'])),
    ('3. Program run', _s(checks['3_program_run'])),
    ('4. Shown', 'this screen; it signs digest ${_s(s['digest'])}'),
    ('5. Contract key', _s(checks['5_contract_key'])),
    if (p['selected_by'] != null) ('Path chosen by', _s(p['selected_by'])),
    if (s['locks'] != null) ('Locks', _s(s['locks'])),
    ('Input sequence', _s(s['sequence'])),
    ('Coin', _s(contract['coin'])),
  ]));
  return out;
}
