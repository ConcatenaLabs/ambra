// The payment name's key and signatures: BIP340 itself, and the web wallet's lnaddr.js byte for
// byte (the expected values are its output for the same phrase, digest and auxiliary bytes).
import 'package:ambra/src/data/lnaddr.dart';
import 'package:ambra/src/data/name_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BIP340 test vector 0', () {
    final priv = unhex('${'00' * 31}03');
    expect(hexOf(schnorrPublicKey(priv)), 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9');
    final sig = schnorrSign(priv, List.filled(32, 0), aux: List.filled(32, 0));
    expect(hexOf(sig),
        'e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0');
    expect(schnorrVerify(schnorrPublicKey(priv), List.filled(32, 0), sig), isTrue);
  });

  const phrase = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

  test('the same name key and signature as the web wallet', () {
    final k = nameKey(phrase);
    expect(hexOf(k.priv), 'f67dbb5175689544adedba9fed797031ea42b37c559532ac393992f899f9c778');
    expect(k.pub, '31b688e134f8cfbfc917f900e9461b620747bff60ae82a193ca7f9b0a1b8c9a6');
    final d = signedDigest('register', 'sequentiatestnet.com', 'alice', [k.pub, 1700000000]);
    expect(hexOf(d), 'be592afabf9f6dc4b276b80e4c0ab678ef7c812d96028404c4439d684506140d');
    final sig = schnorrSign(k.priv, d, aux: List.filled(32, 7));
    expect(hexOf(sig),
        '067f113c5f4235ef2ffadd708e9d682c1a28c9608df45b7a5d1481988bc3c82af6f5c4875fa1fce1f3072d70a2b95b2d6300280033bba4f7bc914e00f817988f');
  });

  test('a signature with fresh randomness verifies, and not for another message or key', () {
    final k = nameKey(phrase);
    final d = signedDigest('wait', 'sequentiatestnet.com', 'alice', [1700000000, 1000, 50000]);
    final sig = unhex(signWith(k.priv, d));
    final pub = unhex(k.pub);
    expect(schnorrVerify(pub, d, sig), isTrue);
    final other = signedDigest('wait', 'sequentiatestnet.com', 'alice', [1700000000, 1000, 50001]);
    expect(schnorrVerify(pub, other, sig), isFalse);
    expect(schnorrVerify(schnorrPublicKey(unhex('${'00' * 31}03')), d, sig), isFalse);
  });
}
