// The web wallet's error sentences, in Dart: the same vectors as its node-reject.test.mjs and
// pretty-err.test.mjs, so both wallets say the same thing for the same failure.
import 'package:ambra/src/data/pretty_error.dart';
import 'package:flutter_test/flutter_test.dart';

AssetMeta meta(String h) => h.startsWith('e396') ? (ticker: 'EURX', precision: 8) : (ticker: 'USDX', precision: 8);

void main() {
  // As they reach the wallet: the explorer's broadcast answer, Esplora's, and the node's RPC error.
  const seen = {
    'http://localhost:8080/api/tx returned HTTP 400: bad-txns-inputs-missingorspent': 'already been spent',
    'sendrawtransaction RPC error: {"code":-26,"message":"min relay fee not met, 100 < 141"}': 'fee is too low',
    'sendrawtransaction RPC error: {"code":-26,"message":"mempool min fee not met"}': 'fee is too low',
    'insufficient fee, rejecting replacement 7f3a…; new feerate 0.00001 <= old feerate 0.00001': 'fee is too low',
    'HTTP 400: txn-mempool-conflict': 'waiting for a block',
    'HTTP 400: too-long-mempool-chain, too many unconfirmed ancestors [limit: 25]': 'in a row',
    'HTTP 400: non-final': 'time-locked',
    'HTTP 400: non-BIP68-final': 'time-locked',
    'HTTP 400: dust': 'too small',
    'HTTP 400: bad-txns-asset-frozen, frozen by its supervisor': 'frozen',
    'HTTP 400: bad-txns-supervision-declaration': 'supervision rules',
    'HTTP 400: bad-txns-multiple-fee-assets': 'exactly one asset',
    'HTTP 400: bip125-replacement-disallowed': 'does not allow replacement',
    'HTTP 400: bad-txns-in-belowout, value in (0.1) < value out (0.2)': 'network refused this transaction',
  };

  test('every reject code reaching the wallet has a sentence that quotes no code', () {
    seen.forEach((raw, want) {
      final out = nodeRejectText(raw);
      expect(out, isNotNull, reason: raw);
      expect(out, contains(want), reason: raw);
      expect(RegExp(r'bad-|txn-|non-final|BIP|HTTP|RPC|\{').hasMatch(out!), isFalse, reason: out);
      expect(out.toLowerCase(), contains('nothing was sent'), reason: out);
    });
  });

  test('the most specific code wins', () {
    expect(nodeRejectText('bad-txns-inputs-missingorspent; also min relay fee not met'), contains('already been spent'));
  });

  test('a transaction the network already has is not a refusal; a message without a code is left alone', () {
    for (final raw in ['HTTP 400: txn-already-in-mempool', 'txn-already-known', 'Transaction already in block chain',
      'Your wallet is locked; unlock it and try again.', 'timed out', '', null]) {
      expect(nodeRejectText(raw), isNull, reason: '$raw');
    }
  });

  test('a shortfall is said in the asset, not in atoms and ids', () {
    expect(
        shortfallText('Insufficient funds: missing 702 units for asset e39685e718516156679088d9400d11a1eb82bf7cc27c5b9f5a614b8c91246d13', meta: meta),
        'Not enough EURX: 0.00000702 EURX short, counting the network fee when it is paid in EURX. Lower the amount, or pay the fee in another asset.');
    final t = shortfallText(
        'insufficient transparent 2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de: need 999998663, have 0 (a further 49999999999065 is held in confidential outputs)',
        meta: meta);
    expect(t, contains('you hold 0 USDX that way; the other 499999.99999065 USDX is at blinded outputs. Send it to yourself'));
    expect(shortfallText('something else', meta: meta), isNull);
  });

  // The exact strings the web wallet's sessions produced, verbatim from the wire.
  const real = {
    'pure-LN swap ended: pay hold: taker pay hold: waitsendpay: waitsendpay: rpc error 204: failed: WIRE_TEMPORARY_NODE_FAILURE (reply from remote)':
        'could not accept the payment just now',
    'peer failed the cross-chain lift: btc_leg_invalid: xchain: taker BTC leg invalid (does not match quote): redeemScript mismatch (want 63a820.., got 63a820..)':
        'other side of this trade changed',
    'error: no verified sub-asset offer found to buy 3a0f9192 with on-chain BTC': 'no longer be filled',
    'relay: maker is not connected; this offer cannot be lifted right now': 'gone offline',
    "inbound provisioning failed: getinfo: lightning-cli: Connecting to 'lightning-rpc': Connection refused": 'Lightning node is not reachable',
  };

  test('every real failure has a named message that leaks no machinery and says what to do', () {
    real.forEach((raw, want) {
      final out = prettyErr(raw);
      expect(out, contains(want), reason: raw);
      expect(out, isNot(kSomethingWentWrong));
      expect(RegExp(r'0x|63a820|WIRE_|rpc', caseSensitive: false).hasMatch(out), isFalse, reason: out);
      expect(RegExp(r'try again|reload|Reopen|smaller|different offer|returned automatically', caseSensitive: false).hasMatch(out), isTrue,
          reason: out);
    });
  });

  test('the safety net still catches what is not understood, and a plain sentence passes', () {
    expect(prettyErr('hsmd rejected: psbt vout cltv nonsense'), kSomethingWentWrong);
    expect(prettyErr('{"code":-32601}'), kSomethingWentWrong);
    expect(prettyErr(Exception('covenant leaf 3 refused')), kSomethingWentWrong);
    const plain = 'Your wallet is locked; unlock it and try again.';
    expect(prettyErr(plain), plain);
    expect(prettyErr(Exception(plain)), plain);
    expect(prettyErr(StateError(plain)), plain);
  });

  test('the most specific cause wins when a message carries several', () {
    expect(prettyErr('peer failed: redeemScript mismatch; also no route found; timed out'), contains('other side of this trade changed'));
  });

  test('a timeout never says nothing happened', () {
    final out = prettyErr('deadline exceeded waiting for the round');
    expect(out, contains('may still complete'));
    expect(out.toLowerCase(), isNot(contains('nothing was')));
  });

  test('plainErr names a shortfall and a refusal, and leaves anything else as it was', () {
    expect(plainErr(Exception('HTTP 400: dust')), contains('too small'));
    expect(plainErr('Address is not valid for this network'), 'Address is not valid for this network');
  });
}
