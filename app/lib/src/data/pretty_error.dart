// What an error means, in a sentence the person can act on: the web wallet's prettyErr,
// nodeRejectText and shortfallText (index.html, node-reject.js), in the same words and the same
// order, so both wallets say the same thing for the same failure.
//
// [prettyErr] is for trades, swaps and anything else whose raw error can carry settlement
// machinery: a failure it knows is named, and anything else that does not read as a plain sentence
// becomes "Something went wrong - please try again.". [plainErr] is for Send, issuance and staking,
// as in the web wallet: a shortfall or a node's refusal in words, anything else as it was.

import 'config.dart';

/// The words for an asset in a shortfall: its ticker and precision.
typedef AssetMeta = ({String ticker, int precision});

AssetMeta _appMeta(String hex) {
  final l = SeqAssets.labelFor(hex);
  return (ticker: l.ticker, precision: l.precision);
}

RegExp _re(String p) => RegExp(p, caseSensitive: false);

// A node's refusal of a transaction, most specific first: several codes can share a message, and
// the first match wins (node-reject.js RULES).
final List<(RegExp, String)> _rejectRules = [
  (_re(r'bad-txns-inputs-missingorspent|bad-txns-spends-conflicting-tx|missing-inputs'),
      'A coin this transaction spends has already been spent, most likely by another payment from this wallet that it had not seen yet. Nothing was sent: refresh and try again.'),
  (_re(r'txn-mempool-conflict'),
      'A coin this transaction spends is already spent by a transaction still waiting for a block. Nothing was sent: wait for that one to confirm, or speed it up, then try again.'),
  (_re(r'bip125-replacement-disallowed'),
      'The transaction this one would replace does not allow replacement. Nothing was sent: wait for it to confirm, or speed it up with a child payment instead.'),
  (_re(r'too-long-mempool-chain'),
      'Too many of this wallet’s transactions are waiting in a row for a block. Nothing was sent: wait for the next block, then try again.'),
  (_re(r'non-BIP68-final|non-final'),
      'This transaction is time-locked to a later block or time, so the network does not accept it yet. Nothing was sent: try again later.'),
  (_re(r'bad-txns-asset-frozen'), 'This asset is frozen by its supervisor, so it cannot move right now. Nothing was sent.'),
  (_re(r'supervision-not-active|bad-txns-supervision'),
      'The asset’s supervision rules refuse this transfer. Nothing was sent: check the asset’s terms with its issuer.'),
  (_re(r'bad-txns-no-fee|bad-txns-multiple-fee-assets'),
      'A transaction must pay its fee in exactly one asset. Nothing was sent: choose a single fee asset and try again.'),
  (_re(r'mempool full'), 'The network is too busy to take this transaction at its fee. Nothing was sent: raise the fee rate and try again.'),
  (_re(r'min relay fee not met|mempool min fee not met|insufficient fee'),
      'The fee is too low for the network to accept, or the node does not accept that fee asset. Nothing was sent: raise the fee rate, or pay the fee in another asset, and try again.'),
  (_re(r'\bdust\b'), 'An amount in this transaction is too small for the network to relay. Nothing was sent: send a larger amount.'),
  (_re(r'tx-size-small'), 'This transaction is too small for the network to relay. Nothing was sent: send a larger amount.'),
  (_re(r'bad-txns-premature-spend-of-coinbase'),
      'It spends a block reward that is not mature yet. Nothing was sent: try again once it has more confirmations.'),
];

// Any other reject code: still a refusal the person should see as one, never as the raw code.
final _otherCode = _re(
    r'\b(bad-[a-z0-9-]+|txn-[a-z0-9-]+|non-mandatory-script-verify-flag|mandatory-script-verify-flag-failed|scriptpubkey|multi-op-return)\b');
final _notARefusal = _re(r'txn-already-in-mempool|txn-already-known|txn-same-nonwitness-data-in-mempool|already in (block|the mempool)');

/// The sentence for a node's refusal of a transaction found in [message], or null when it carries
/// no reject code (or one that means the transaction is already in the mempool or a block).
String? nodeRejectText(Object? message) {
  final m = '${message ?? ''}';
  if (m.isEmpty || _notARefusal.hasMatch(m)) return null;
  for (final (re, text) in _rejectRules) {
    if (re.hasMatch(m)) return text;
  }
  if (_otherCode.hasMatch(m)) {
    return 'The network refused this transaction, so nothing was sent. Refresh and try again; if it is refused again, the wallet’s log has the reason.';
  }
  return null;
}

String _atoms(String n, int precision) {
  final s = BigInt.parse(n).toString().padLeft(precision + 1, '0');
  final whole = s.substring(0, s.length - precision);
  final frac = precision > 0 ? s.substring(s.length - precision).replaceFirst(RegExp(r'0+$'), '') : '';
  return frac.isEmpty ? whole : '$whole.$frac';
}

/// A shortfall the wallet kit reports in atoms and asset ids, said in the asset's own units, or null.
String? shortfallText(Object? message, {AssetMeta Function(String hex)? meta}) {
  final m = '${message ?? ''}';
  final of = meta ?? _appMeta;
  var x = _re(r'Insufficient funds: missing (\d+) units for asset ([0-9a-f]{64})').firstMatch(m);
  if (x != null) {
    final a = of(x.group(2)!.toLowerCase());
    return 'Not enough ${a.ticker}: ${_atoms(x.group(1)!, a.precision)} ${a.ticker} short, counting the network fee when it is paid in ${a.ticker}. Lower the amount, or pay the fee in another asset.';
  }
  x = _re(r'insufficient transparent ([0-9a-f]{64}): need (\d+), have (\d+)(?: \(a further (\d+))?').firstMatch(m);
  if (x != null) {
    final a = of(x.group(1)!.toLowerCase());
    final further = x.group(4);
    return 'An order on the book can only take ${a.ticker} you hold in the clear, and you hold ${_atoms(x.group(3)!, a.precision)} ${a.ticker} that way'
        '${further != null ? '; the other ${_atoms(further, a.precision)} ${a.ticker} is at blinded outputs. Send it to yourself at your usual address (Send, to your tb1 address from Receive), then place the order again.' : '.'}';
  }
  return null;
}

/// The message of an error, without the wrapper Dart and the bridge put round it.
String errText(Object? e) => '${e ?? ''}'
    .replaceFirst(RegExp(r'^(Exception|Bad state|Invalid argument\(s\)|FormatException): '), '')
    .replaceFirst(RegExp(r'^AnyhowException\((.*)\)$', dotAll: true), r'$1')
    .trim();

/// Words that name settlement machinery: a message that holds one is never shown as it is.
final _machinery = _re(
    r'\b(makers?|counterpart(?:y|ies)|takers?|LSPs?|bridg(?:e|es|ed|ing)|submarines?|sub-?assets?|HTLCs?|CLTVs?|min-?final-?cltv|anchor(?:s|ed|ing)?|preimages?|hold-?invoices?|covenants?|peg(?:s|ged|ging)?|rail-?crossing|atomic(?:ally)?)\b|T_?seq');

/// Whether [m] reads like a sentence: raw node codes, JSON, stack frames, hex blobs and single
/// tokens do not.
bool looksPlain(String m) {
  final s = m.trim();
  if (s.isEmpty || s.length > 300) return false;
  if (_re(r'[{}\[\]]|::|\bat \w+[.(]|\n|0x[0-9a-f]{6,}|[0-9a-f]{32,}').hasMatch(s)) return false;
  if (_re(r'^[a-z0-9]+(?:-[a-z0-9]+){2,}$').hasMatch(s)) return false;
  if (!RegExp(r'\s').hasMatch(s)) return false;
  return true;
}

const kSomethingWentWrong = 'Something went wrong - please try again.';

/// The sentence for an error shown where the wallet used to print the raw message (Send, issuance,
/// staking): a shortfall or a node's refusal in words, anything else as it was.
String plainErr(Object? e, {AssetMeta Function(String hex)? meta}) {
  final m = errText(e);
  return shortfallText(m, meta: meta) ?? nodeRejectText(m) ?? m;
}

/// The sentence for an error of a trade, a swap or anything whose raw error can carry machinery:
/// the web wallet's prettyErr.
String prettyErr(Object? e, {AssetMeta Function(String hex)? meta}) {
  final m = errText(e);
  final short = shortfallText(m, meta: meta);
  if (short != null) return short;
  final refused = nodeRejectText(m);
  if (refused != null) return refused;
  bool has(String p) => _re(p).hasMatch(m);
  if (has(r'conflicting|already known|txn-already|already in (block|the mempool)|already.?confirmed')) {
    return 'This transaction conflicts with one already in the mempool or a block; it may have already confirmed. Refresh to check; a confirmed transaction needs no bump.';
  }
  if (has(r'insufficient fee|min relay|fee too low|rejecting replacement')) {
    return 'The fee is too low for the network to accept; raise the fee rate and try again.';
  }
  if (has(r'transparent receive spends only explicit coins')) {
    return 'The coins that would pay for this swap are held at a blinded address, and a swap that pays you at your usual address spends coins held in the clear. Send them to your usual address first, or turn on receiving at a blinded address of this wallet - nothing was sent.';
  }
  if (has(r"different swap from the one you reviewed|refusing the maker's swap")) {
    return 'The other side answered with a different swap from the one you reviewed (paying you less, paying elsewhere or changing how you are paid), so this wallet signed nothing and nothing moved. Take another offer.';
  }
  if (has(r'redeem ?script mismatch|does not match quote')) {
    return 'The other side of this trade changed before it completed, so it was refused rather than paid to the wrong party. Nothing was sent; anything already locked is returned automatically.';
  }
  if (has(r'WIRE_INCORRECT_OR_UNKNOWN_PAYMENT_DETAILS|unknown payment|payment_hash.*unknown')) {
    return 'The other side did not recognise this payment, so nothing was sent. Their offer has probably expired - reload the book and try again.';
  }
  if (has(r'WIRE_TEMPORARY_NODE_FAILURE|temporary_node_failure|temporary channel failure|WIRE_TEMPORARY_CHANNEL_FAILURE')) {
    return 'The other side’s Lightning node could not accept the payment just now, so nothing was sent. This usually clears on its own - try again, or take a different offer.';
  }
  if (has(r'no route|route not found|failed to find a route|WIRE_UNKNOWN_NEXT_PEER')) {
    return 'No Lightning route to the other side had room for this amount, so nothing was sent. Try a smaller amount or a different offer.';
  }
  if (has(r'no verified .*offer found|offer (is )?(gone|expired|no longer)|unliftable|maker is not connected|cannot be lifted')) {
    return 'The other side of that offer has gone offline, so it can no longer be filled - reload the market and take a current one.';
  }
  if (has(r'insufficient (funds|balance|capacity)|not enough (funds|liquidity)')) {
    return 'There is not enough balance or Lightning capacity to complete this at the size requested. Try a smaller amount.';
  }
  if (has(r'Command failed:|--rpc-file|lightningd')) {
    return 'Your hosted Lightning node did not complete that request, so nothing was created. It may still be starting up — try again shortly, or with a smaller amount.';
  }
  if (has(r'lightning-rpc|connection refused|ECONNREFUSED')) {
    return 'Your Lightning node is not reachable right now, so nothing was sent. Reopen the wallet to reconnect it, then try again.';
  }
  final declined = RegExp(
          r'maker refused: (the maker cannot fund this lift right now|the request does not match the offer|the maker could not co-sign this lift)')
      .firstMatch(m);
  if (declined != null) return 'The other side declined: ${declined.group(1)}. This wallet signed nothing, so nothing was traded.';
  if (m.contains('maker did not answer: ')) return 'The other side did not answer in time. This wallet signed nothing, so nothing was traded.';
  if (has(r'timed? ?out|timeout|deadline exceeded')) {
    // Never "nothing was committed" on a timeout: the wallet stopped waiting, not the trade happening.
    return 'This is taking longer than expected, so the wallet stopped waiting. It may still complete in the background - check your balance and your trades before trying again.';
  }
  if (_machinery.hasMatch(m) || !looksPlain(m)) return kSomethingWentWrong;
  return m;
}
