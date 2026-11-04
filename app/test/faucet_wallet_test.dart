// The wallet's id for the testnet faucet (faucet_wallet.dart): the same phrase gives the same id
// here, in the web wallet and in Ambra browser. The vector is the web wallet's
// (faucet-wallet.test.mjs): the abandon phrase's first receive address.
//
//   cd app && flutter test test/faucet_wallet_test.dart
//
// With the host cdylib (`cargo build` in ../ambra_core, or AMBRA_CORE_LIB) the id is also taken
// from the address the wallet's own core derives at index 0.

import 'dart:io' show File, Platform;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/faucet_wallet.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/rust/frb_generated.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _addr0 = 'tb1q6rz28mcfaxtmd6v789l9rrlrusdprr9pqcpvkl';
const _spk0 = '0014d0c4a3ef09e997b6e99e397e518fe3e41a118ca1';
const _id0 = '0dc441add97a52d9e9f9254c6d6a7aaf530c1cca887a08d9b188cb3a6b196803';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
final _hostLib = Platform.environment['AMBRA_CORE_LIB'] ?? '../ambra_core/target/debug/libambra_core.so';

void main() {
  test('the id is sha256 of the tag and the first address\'s scriptPubKey', () {
    expect(_hex(scriptPubKeyOf(_addr0)!), _spk0);
    expect(faucetWalletIdOf(_addr0), _id0);
    expect(faucetWalletIdOf(_addr0.toUpperCase()), _id0);
    // BIP-350's own vectors, version 0 and 1.
    expect(_hex(scriptPubKeyOf('tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7')!),
        '00201863143c14c5166804bd19203356da136c985678cd4d27a1b8c6329604903262');
    expect(_hex(scriptPubKeyOf('tb1pqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesf3hn0c')!),
        '5120000000c4a5cad46221b2a187905e5266362b99d5e91c6ce24d165dab93e86433');
    for (final bad in ['', 'tb1q6rz28mcfaxtmd6v789l9rrlrusdprr9pqcpvkm', 'tb1Q6rz28mcfaxtmd6v789l9rrlrusdprr9pqcpvkl', 'nope']) {
      expect(scriptPubKeyOf(bad), isNull, reason: bad);
    }
    expect(() => faucetWalletIdOf('nope'), throwsArgumentError);
    expect(faucetLabel(''), 'tSEQ');
    expect(FaucetWords.received('USDX'), 'USDX received');
  });

  group('with the wallet\'s own core', () {
    final have = File(_hostLib).existsSync();
    setUpAll(() async {
      if (have) await RustLib.init(externalLibrary: ExternalLibrary.open(_hostLib));
    });
    test('the first receive address gives the same id', () async {
      final info = await core.receiveAddressAt(mnemonic: _mnemonic, index: 0, confidential: false);
      expect(info.address, _addr0);
      expect(faucetWalletIdOf(info.address), _id0);
    }, skip: have ? false : 'needs the host cdylib at $_hostLib');
  });
}
