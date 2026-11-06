// The one receive code, written and read: the web wallet's vectors (pay-code.test.mjs), and
// its output for the same requests (pay_code_vectors.json, written by pay-code.js), so a code
// either wallet draws is the code the other draws and reads.
import 'dart:convert';
import 'dart:io';

import 'package:ambra/src/data/pay_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';

void main() {
  final vectors = jsonDecode(File('test/pay_code_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final info = vectors['info'] as Map<String, dynamic>;

  test('the same code as the web wallet, read back and paid on the same operator only', () {
    for (final c in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
      expect(compactRequest(c['library'] as String), c['short']);
      final code = PayCode(address: vectors['address'] as String, ark: vectors['ark'] as String,
              sequentia: c['library'] as String, amount: '0.001')
          .build();
      expect(code, c['code']);
      final r = PayCode.read(code)!;
      expect(r.address, vectors['address']);
      expect(r.ark, vectors['ark']);
      expect(r.sequentia, c['short']);
      final back = expandRequest(r.sequentia!, operator: info['operator'] as String, genesis: info['genesis_hash'] as String);
      expect(back, c['expanded']);
      expect(libraryRequest(back!), c['request']);
      expect(expandRequest(r.sequentia!, operator: 'ef' * 32, genesis: info['genesis_hash'] as String), isNull);
      expect(expandRequest(r.sequentia!, operator: info['operator'] as String, genesis: '00' * 32), isNull);
      // The library's own spelling is still read and paid.
      expect(expandRequest(c['library'] as String, operator: info['operator'] as String, genesis: info['genesis_hash'] as String),
          c['library']);
    }
  });

  test('a code made before the short form is still read', () {
    final lib = (vectors['cases'] as List).first['library'] as String;
    final r = PayCode.read('bitcoin:${vectors['address']}?ark=${vectors['ark']}&sequentia=$lib')!;
    expect(r.sequentia, lib);
    expect(r.ark, vectors['ark']);
  });

  test('the picture: alphanumeric where it can, level M, a low version', () {
    final c = (vectors['cases'] as List).first as Map<String, dynamic>;
    final code = PayCode(address: vectors['address'] as String, ark: vectors['ark'] as String, sequentia: c['library'] as String)
        .build();
    final old = 'bitcoin:${vectors['address']}?ark=${vectors['ark']}&sequentia=${c['library']}';
    final q = payCodeQr(code);
    expect(q.errorCorrectLevel, QrErrorCorrectLevel.M);
    expect(q.typeNumber, lessThanOrEqualTo(13));
    // The same text all in bytes, as before, takes a far larger version.
    final before = QrCode.fromData(data: old, errorCorrectLevel: QrErrorCorrectLevel.L);
    expect(before.typeNumber, greaterThanOrEqualTo(22));
    // ignore: avoid_print
    print('receive code: ${old.length} chars v${before.typeNumber} (L, bytes) -> ${code.length} chars v${q.typeNumber} (M)');
    expect(payCodeQr('BITCOIN:${(vectors['address'] as String).toUpperCase()}').typeNumber, lessThanOrEqualTo(3));
  });

  const tb1 = 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx';
  const ark = 'tark1pnglpcr3zqqptxh5f9uabcdefgh';
  const seq = 'sequentia:7b226b696e64223a2272657175657374227d';

  test('written and read back, every part in its place', () {
    final code = PayCode(address: tb1, ark: ark, sequentia: seq).build();
    expect(code, 'BITCOIN:${tb1.toUpperCase()}?ark=$ark&sequentia=$seq');
    final r = PayCode.read(code)!;
    expect(r.address, tb1);
    expect(r.ark, ark);
    expect(r.sequentia, seq);
    expect(r.other, isEmpty);
  });

  test('a plain address is a plain bitcoin: request', () {
    expect(PayCode(address: tb1).build(), 'BITCOIN:${tb1.toUpperCase()}');
    expect(PayCode.read('bitcoin:$tb1')!.address, tb1);
    expect(PayCode.read('BITCOIN:${tb1.toUpperCase()}')!.address, tb1);
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

  group('a payment name in the code', () {
    const url = 'https://sequentiatestnet.com/.well-known/lnurlp/alice';
    // An independent bech32 library's output for the same URL (and LUD-01's own example).
    const lnurl = 'LNURL1DP68GURN8GHJ7UM9W96K2MN5D9SHGETNW3HX2APWVDHK6TEWWAJKCMPDDDHX7AMW9AKXUATJD3CZ7CTVD93K2Y93MNY';

    test('LUD-01: the URL as bech32 with the human part lnurl, read back', () {
      expect(lnurlEncode(url).toUpperCase(), lnurl);
      expect(lnurlDecode(lnurl), url);
      expect(lnurlDecode(lnurl.toLowerCase()), url);
      expect(
          lnurlDecode('LNURL1DP68GURN8GHJ7UM9WFMXJCM99E3K7MF0V9CXJ0M385EKVCENXC6R2C35XVUKXEFCV5MKVV34X5EKZD3EV56NYD3HXQURZEPEXEJXXEPNXSCRVWFNV9NXZCN9XQ6XYEFHVGCXXCMYXYMNSERXFQ5FNS'),
          'https://service.com/api?q=3fc3645b439ce8e7f2553a69e5267081d96dcd340693afabe04be7b0ccd178df');
      // Not an LNURL: an invoice, a bech32m string, a broken checksum.
      expect(lnurlDecode('lntb1500n1pjqqqqq'), isNull);
      expect(lnurlDecode(lnurl.substring(0, lnurl.length - 1) + (lnurl.endsWith('Y') ? 'Q' : 'Y')), isNull);
    });

    test('without an amount the code carries it as lightning=, read as lnurl and never as an invoice', () {
      final c = (vectors['cases'] as List).first as Map<String, dynamic>;
      final code = PayCode(address: tb1, ark: vectors['ark'] as String, sequentia: c['library'] as String, lnurl: url).build();
      expect(code, contains('lightning=$lnurl'));
      final r = PayCode.read(code)!;
      expect(r.lnurl, url);
      expect(r.lightning, isNull);
      expect(r.address, tb1);
      expect(r.ark, vectors['ark']);
      expect(r.sequentia, c['short']);
      // An invoice wins over the name: a code with an amount carries the invoice.
      final withInv = PayCode(address: tb1, lightning: 'lntb1500n1pjabc', lnurl: url).build();
      expect(PayCode.read(withInv)!.lightning, 'lntb1500n1pjabc');
      expect(PayCode.read(withInv)!.lnurl, isNull);
      // A code with only the name and an address is still a code.
      expect(PayCode.read('BITCOIN:?lightning=$lnurl')!.lnurl, url);
    });

    test('the picture stays within the size a phone scans at a glance', () {
      final c = (vectors['cases'] as List).first as Map<String, dynamic>;
      final plain = PayCode(address: vectors['address'] as String, ark: vectors['ark'] as String, sequentia: c['library'] as String).build();
      final named = PayCode(
              address: vectors['address'] as String,
              ark: vectors['ark'] as String,
              sequentia: c['library'] as String,
              lnurl: 'https://sequentiatestnet.com/.well-known/lnurlp/${'n' * 32}')
          .build();
      // The same code with an amount carries an invoice instead, which is longer than the name's
      // LNURL: a Bitcoin testnet invoice with a description and a route hint runs to some 330
      // characters (this one is a real one's length, its body a placeholder).
      final invoice = 'lntb15u1p${'q' * 321}';
      final withAmount = PayCode(
              address: vectors['address'] as String,
              ark: vectors['ark'] as String,
              sequentia: c['library'] as String,
              amount: '0.000015',
              lightning: invoice)
          .build();
      final q = payCodeQr(named), qa = payCodeQr(withAmount);
      // ignore: avoid_print
      print('receive code ${plain.length} chars v${payCodeQr(plain).typeNumber}; with the longest name ${named.length} chars '
          'v${q.typeNumber}; with an amount ${withAmount.length} chars v${qa.typeNumber}');
      expect(q.errorCorrectLevel, QrErrorCorrectLevel.M);
      // Never denser than the code with an amount, which the wallet already shows.
      expect(q.typeNumber, lessThanOrEqualTo(qa.typeNumber));
      expect(q.typeNumber, lessThanOrEqualTo(16));
    });
  });
}
