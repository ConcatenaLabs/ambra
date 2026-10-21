// bolt11Of finds a Lightning invoice in what was scanned or pasted, so Send can
// route it to the Lightning pay screen instead of refusing it as an address.
//
//   cd app && flutter test test/bolt11_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/widgets/ln_cards.dart';

void main() {
  test('a testnet, signet, regtest or main invoice is found, with or without its URI prefix', () {
    expect(bolt11Of(' lntb10u1pjexample '), 'lntb10u1pjexample');
    expect(bolt11Of('lightning:LNTBS2500n1pexample'), 'LNTBS2500n1pexample');
    expect(bolt11Of('lnbcrt1u1pexample'), 'lnbcrt1u1pexample');
    expect(bolt11Of('lnbc1pexample'), 'lnbc1pexample');
  });
  test('a Sequentia asset invoice is found: testnet, regtest and mainnet prefixes', () {
    expect(bolt11Of('lntsqt11p4d3hszsp57vfg'), 'lntsqt11p4d3hszsp57vfg');
    expect(bolt11Of('lnsqrt1p4d3h'), 'lnsqrt1p4d3h');
    expect(bolt11Of('LNSQT5p4d3h'), 'LNSQT5p4d3h');
  });
  test('an address is not an invoice', () {
    expect(bolt11Of('tb1q78facck0fkfzqn3wldcqfvxl8y3h4sdllqd9xw'), isNull);
    expect(bolt11Of('tsqb1qexample'), isNull);
    expect(bolt11Of('lntbx'), isNull);
    expect(bolt11Of(''), isNull);
  });
}
