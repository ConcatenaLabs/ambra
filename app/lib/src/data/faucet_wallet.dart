import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The testnet faucet pays each asset once per wallet (sequentia-faucet, "Once per wallet").
/// A wallet names itself to the faucet by its id, sent with every request as `wallet`:
///
///   hex( sha256( "sequentia-faucet-wallet/1" || scriptPubKey of its first receive address ) )
///
/// the first receive address being the wallet's Sequentia address at index 0. One phrase gives
/// one id here, in the web wallet and in Ambra browser (the web wallet's `faucet-wallet.js`,
/// which the browser extension vendors): change them together. The vector in
/// `test/faucet_wallet_test.dart` is the one all three check.
const faucetWalletTag = 'sequentia-faucet-wallet/1';

const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

int _polymod(List<int> values) {
  const g = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final v in values) {
    final b = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if ((b >> i) & 1 == 1) chk ^= g[i];
    }
  }
  return chk;
}

/// A segwit address (tb1…, bech32 for version 0, bech32m above) -> the bytes of its
/// scriptPubKey, or null when it is not one.
Uint8List? scriptPubKeyOf(String address) {
  final s = address.trim();
  if (s != s.toLowerCase() && s != s.toUpperCase()) return null;
  final a = s.toLowerCase();
  final at = a.lastIndexOf('1');
  if (at < 1 || a.length - at < 8) return null;
  final hrp = a.substring(0, at);
  final data = <int>[];
  for (final c in a.substring(at + 1).split('')) {
    final v = _charset.indexOf(c);
    if (v < 0) return null;
    data.add(v);
  }
  final expand = [
    ...hrp.codeUnits.map((c) => c >> 5),
    0,
    ...hrp.codeUnits.map((c) => c & 31),
  ];
  final version = data[0];
  final chk = _polymod([...expand, ...data]);
  if (version > 16 || chk != (version == 0 ? 1 : 0x2bc830a3)) return null;
  var acc = 0, bits = 0;
  final prog = <int>[];
  for (final v in data.sublist(1, data.length - 6)) {
    acc = ((acc << 5) | v) & 0xfff;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      prog.add((acc >> bits) & 0xff);
    }
  }
  if (bits >= 5 || (acc & ((1 << bits) - 1)) != 0) return null;
  if (prog.length < 2 || prog.length > 40 || (version == 0 && prog.length != 20 && prog.length != 32)) return null;
  return Uint8List.fromList([version == 0 ? 0 : 0x50 + version, prog.length, ...prog]);
}

/// The wallet's id from the scriptPubKey of its first receive address.
String faucetWalletId(List<int> scriptPubKey) {
  if (scriptPubKey.isEmpty) throw ArgumentError('no scriptPubKey');
  return sha256.convert([...utf8.encode(faucetWalletTag), ...scriptPubKey]).toString();
}

/// The wallet's id from its first receive address, as text.
String faucetWalletIdOf(String address) {
  final spk = scriptPubKeyOf(address);
  if (spk == null) throw ArgumentError('not a segwit address: $address');
  return faucetWalletId(spk);
}

/// The label the faucet uses for a button's asset ('' is tSEQ).
String faucetLabel(String asset) => asset.isEmpty ? 'tSEQ' : asset;

/// What a button and the card say.
class FaucetWords {
  FaucetWords._();
  static String received(String label) => '$label received';
  static const rule =
      'The faucet pays each asset once per wallet. Once your wallet has an asset from it, trade for more of it in the wallet.';
}
