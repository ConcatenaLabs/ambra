// The one receive code, written and read: the web wallet's vectors (pay-code.test.mjs).
import 'package:ambra/src/data/pay_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tb1 = 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx';
  const ark = 'tark1pnglpcr3zqqptxh5f9uabcdefgh';
  const seq = 'sequentia:7b226b696e64223a2272657175657374227d';

  test('written and read back, every part in its place', () {
    final code = PayCode(address: tb1, ark: ark, sequentia: seq).build();
    expect(code, 'bitcoin:$tb1?ark=$ark&sequentia=$seq');
    final r = PayCode.read(code)!;
    expect(r.address, tb1);
    expect(r.ark, ark);
    expect(r.sequentia, seq);
    expect(r.other, isEmpty);
  });

  test('a plain address is a plain bitcoin: request', () {
    expect(PayCode(address: tb1).build(), 'bitcoin:$tb1');
    expect(PayCode.read('bitcoin:$tb1')!.address, tb1);
    expect(PayCode.read('BITCOIN:${tb1.toUpperCase()}')!.address, tb1.toUpperCase());
  });

  test('values that need it are escaped and read back whole', () {
    final code = PayCode(address: tb1, label: 'Ana & Bo', message: 'rent 50%', sequentia: 'x:y z').build();
    expect(code, contains('label=Ana%20%26%20Bo'));
    expect(code, contains('message=rent%2050%25'));
    final r = PayCode.read(code)!;
    expect(r.label, 'Ana & Bo');
    expect(r.message, 'rent 50%');
    expect(r.sequentia, 'x:y z');
  });

  test('other parameters are kept; an unknown required one is refused', () {
    final r = PayCode.read('bitcoin:$tb1?pj=https://x.test/pj&amount=0.001')!;
    expect(r.amount, '0.001');
    expect(r.other, {'pj': 'https://x.test/pj'});
    expect(() => PayCode.read('bitcoin:$tb1?req-pj=https://x.test/pj'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('cannot do (pj)'))));
    expect(PayCode.read('bitcoin:$tb1?req-ark=$ark')!.ark, ark);
  });

  test('what is not a request, or names nothing to pay, is not read', () {
    expect(PayCode.read(tb1), isNull);
    expect(PayCode.read(seq), isNull);
    expect(PayCode.read(''), isNull);
    expect(() => PayCode.read('bitcoin:?label=x'), throwsFormatException);
    expect(() => PayCode.read('bitcoin:$tb1?ark=a&ark=b'), throwsFormatException);
    expect(() => PayCode(ark: ark).build(), throwsFormatException);
  });

  test('an address-less request with an ark address is read', () {
    final r = PayCode.read('bitcoin:?ark=$ark')!;
    expect(r.address, isNull);
    expect(r.ark, ark);
  });
}
