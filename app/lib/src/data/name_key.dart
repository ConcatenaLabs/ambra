import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The key a wallet holds its payment name with, and the BIP340 signatures it makes with it: the
/// web wallet's `nameKey` and `signWith` (lnaddr.js), byte for byte. The key is the BIP32 child
/// at [nameKeyPath] of the phrase's BIP39 seed; it holds no coins and signs nothing but the
/// payment-name service's messages, each of which names the service's domain.
///
/// secp256k1 is computed here over [BigInt] in affine coordinates: slow next to a native library,
/// and fast enough for a signature every few seconds. Nothing secret leaves this file but the
/// signature.

/// The name key's path, beside the Lightning keys' branches (m/1017'/0' to 3').
const nameKeyPath = "m/1017'/16'/0'";

final _p = BigInt.parse('fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f', radix: 16);
final _n = BigInt.parse('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141', radix: 16);
final _g = _Pt(BigInt.parse('79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798', radix: 16),
    BigInt.parse('483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8', radix: 16));

class _Pt {
  const _Pt(this.x, this.y);
  final BigInt x, y;
}

_Pt? _add(_Pt? a, _Pt? b) {
  if (a == null) return b;
  if (b == null) return a;
  BigInt l;
  if (a.x == b.x) {
    if ((a.y + b.y) % _p == BigInt.zero) return null;
    l = (BigInt.from(3) * a.x * a.x) * (BigInt.two * a.y).modInverse(_p) % _p;
  } else {
    l = (b.y - a.y) * (b.x - a.x).modInverse(_p) % _p;
  }
  final x = (l * l - a.x - b.x) % _p;
  return _Pt(x, (l * (a.x - x) - a.y) % _p);
}

_Pt? _mul(BigInt k, [_Pt? pt]) {
  _Pt? r;
  _Pt? q = pt ?? _g;
  for (var i = 0; i < k.bitLength; i++) {
    if ((k >> i) & BigInt.one == BigInt.one) r = _add(r, q);
    q = _add(q, q);
  }
  return r;
}

Uint8List _b32(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

BigInt _int(List<int> b) => b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));

List<int> _tagged(String tag, List<int> msg) {
  final t = sha256.convert(utf8.encode(tag)).bytes;
  return sha256.convert([...t, ...t, ...msg]).bytes;
}

/// The x-only public key of [priv] (32 bytes).
Uint8List schnorrPublicKey(List<int> priv) {
  final d = _int(priv);
  if (d == BigInt.zero || d >= _n) throw ArgumentError('not a private key');
  return _b32(_mul(d)!.x);
}

/// The BIP340 signature of the 32-byte [msg] by [priv], with [aux] (32 bytes) as its auxiliary
/// randomness; fresh random bytes when none is given.
Uint8List schnorrSign(List<int> priv, List<int> msg, {List<int>? aux}) {
  final d0 = _int(priv);
  if (d0 == BigInt.zero || d0 >= _n) throw ArgumentError('not a private key');
  final a = aux ?? List<int>.generate(32, (_) => math.Random.secure().nextInt(256));
  final pt = _mul(d0)!;
  final d = pt.y.isEven ? d0 : _n - d0;
  final px = _b32(pt.x);
  final h = _tagged('BIP0340/aux', a);
  final db = _b32(d);
  final t = [for (var i = 0; i < 32; i++) db[i] ^ h[i]];
  final k0 = _int(_tagged('BIP0340/nonce', [...t, ...px, ...msg])) % _n;
  if (k0 == BigInt.zero) throw StateError('nonce is zero');
  final r = _mul(k0)!;
  final k = r.y.isEven ? k0 : _n - k0;
  final rx = _b32(r.x);
  final e = _int(_tagged('BIP0340/challenge', [...rx, ...px, ...msg])) % _n;
  return Uint8List.fromList([...rx, ..._b32((k + e * d) % _n)]);
}

/// Whether [sig] is [pub]'s BIP340 signature of [msg].
bool schnorrVerify(List<int> pub, List<int> msg, List<int> sig) {
  try {
    if (pub.length != 32 || sig.length != 64) return false;
    final x = _int(pub);
    if (x >= _p) return false;
    final c = (x.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;
    var y = c.modPow((_p + BigInt.one) >> 2, _p);
    if (y.modPow(BigInt.two, _p) != c) return false;
    if (!y.isEven) y = _p - y;
    final r = _int(sig.sublist(0, 32)), s = _int(sig.sublist(32));
    if (r >= _p || s >= _n) return false;
    final e = _int(_tagged('BIP0340/challenge', [...sig.sublist(0, 32), ...pub, ...msg])) % _n;
    final rr = _add(_mul(s), _mul(_n - e, _Pt(x, y)));
    return rr != null && rr.y.isEven && rr.x == r;
  } catch (_) {
    return false;
  }
}

/// The BIP39 seed of [phrase] (no passphrase): PBKDF2-HMAC-SHA512, 2048 rounds.
Uint8List bip39Seed(String phrase) {
  final words = phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
  final hmac = Hmac(sha512, utf8.encode(words));
  final salt = utf8.encode('mnemonic');
  var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < 2048; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < 64; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

/// The private key at the all-hardened [path] (`m/a'/b'/…`) of [seed] (BIP32).
Uint8List bip32Hardened(List<int> seed, String path) {
  var m = Hmac(sha512, utf8.encode('Bitcoin seed')).convert(seed).bytes;
  var k = _int(m.sublist(0, 32)), c = m.sublist(32);
  final parts = path.split('/');
  if (parts.first != 'm') throw ArgumentError('a path starts at m');
  for (final s in parts.skip(1)) {
    if (!s.endsWith("'")) throw ArgumentError('only hardened steps are taken here');
    final i = int.parse(s.substring(0, s.length - 1)) + 0x80000000;
    m = Hmac(sha512, c).convert([0, ..._b32(k), (i >> 24) & 0xff, (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff]).bytes;
    k = (_int(m.sublist(0, 32)) + k) % _n;
    c = m.sublist(32);
  }
  return _b32(k);
}

/// The name key of a phrase: its private key and its x-only public key in hex.
({Uint8List priv, String pub}) nameKey(String phrase) {
  final words = phrase.trim();
  if (words.isEmpty) throw ArgumentError('no phrase');
  final priv = bip32Hardened(bip39Seed(words), nameKeyPath);
  return (priv: priv, pub: hexOf(schnorrPublicKey(priv)));
}

String hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List unhex(String h) {
  if (h.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(h)) throw const FormatException('not hex');
  return Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
}
