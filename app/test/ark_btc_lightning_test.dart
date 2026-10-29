// The Bitcoin ark as the composer's Bitcoin Lightning (data/ark_btc_lightning.dart), against a
// stand-in for the ark wallet's calls: the fee and the lock come from the wallet, a refusal before
// anything moved is a failure, anything else is looked up, and a paid receive gives its preimage.
// The same cases as the web wallet's btc-ark.js lightning().
import 'dart:convert';

import 'package:ambra/src/data/ark_btc_lightning.dart';
import 'package:flutter_test/flutter_test.dart';

// BOLT 11's example invoice: 250,000 sat, hash 0001…0102.
const inv0 =
    'lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpuaztrnwngzn3kdzw5hydlzf03qdgm2hdq27cqv3agm2awhz5se903vruatfhq77w3ls4evs3ch9zw97j25emudupq63nyw24cg27h2rspfj9srp';
const hash0 = '0001020304050607080900010203040506070809000102030405060708090102';

class FakeArk implements ArkCalls {
  BigInt have = BigInt.from(80000);
  String? invoiceHash;
  Map<String, dynamic> receive = {'state': 'waiting'};
  Object? payThrows;
  Map<String, dynamic> payAnswer = {'state': 'complete', 'preimage': 'ef' * 32};
  Map<String, dynamic> status = {'state': 'none'};
  final calls = <String>[];
  BigInt? maxFee;
  int? maxDelay;

  @override
  Future<BigInt> spendable() async => have;
  @override
  Future<String> invoice(BigInt sats, String description) async =>
      jsonEncode({'invoice': inv0, 'payment_hash': invoiceHash ?? hash0, 'expires_at': 1496314718});
  @override
  Future<String> receiveStatus(String hash, {required bool claim}) async {
    calls.add('receive:$claim');
    return jsonEncode(receive);
  }

  @override
  Future<String> pay(String invoice, {BigInt? maxFeeSats, int? maxDelay}) async {
    calls.add('pay');
    maxFee = maxFeeSats;
    this.maxDelay = maxDelay;
    if (payThrows != null) throw payThrows!;
    return jsonEncode(payAnswer);
  }

  @override
  Future<String> payStatus(String hash, {required bool drive}) async {
    calls.add('status:$drive');
    return jsonEncode(status);
  }

  @override
  Future<String> payFee(BigInt sats) async => jsonEncode({'fee': '${sats ~/ BigInt.from(1000)}', 'gross': '$sats', 'max_route_delay': 60});
}

void main() {
  test('what the ark can pay, and the route a payment takes: the ark\'s fee and its server\'s longest lock', () async {
    final f = FakeArk();
    final b = ArkBtcLightning(f);
    expect(await b.balance(), BigInt.from(80000));
    final r = await b.payRoute(inv0);
    expect(r!.fee, BigInt.from(250));
    expect(r.delay, 60);
  });

  test('an invoice of the ark for the amount asked; one of another amount or hash is refused', () async {
    final f = FakeArk();
    final b = ArkBtcLightning(f);
    final i = await b.invoice(sats: BigInt.from(250000));
    expect(i['payment_hash'], hash0);
    expect(i['expires_at'], 1496314718);
    await expectLater(b.invoice(sats: BigInt.from(1000)), throwsException);
    f.invoiceHash = 'ab' * 32;
    await expectLater(b.invoice(sats: BigInt.from(250000)), throwsException);
  });

  test('a receive is claimed when looked at, and paid gives its preimage', () async {
    final f = FakeArk();
    var moved = 0;
    final b = ArkBtcLightning(f, onMoved: () => moved++);
    expect((await b.invoiceStatus(hash0))['status'], 'unpaid');
    expect(f.calls, ['receive:true']);
    f.receive = {'state': 'paid', 'preimage': 'ef' * 32, 'amount': '250000'};
    expect(await b.invoiceStatus(hash0), {'status': 'paid', 'preimage': 'ef' * 32});
    expect(moved, 1);
    f.receive = {'state': 'unknown', 'reason': 'no such receive'};
    expect((await b.invoiceStatus(hash0))['status'], 'unknown');
  });

  test('a payment: capped at the ticket\'s fee and lock; a refusal is a failure, anything else is looked up', () async {
    final f = FakeArk();
    final b = ArkBtcLightning(f);
    expect(await b.pay(invoice: inv0, maxFeeSats: BigInt.from(87), maxDelay: 66), {'state': 'complete', 'preimage': 'ef' * 32});
    expect(f.maxFee, BigInt.from(87));
    expect(f.maxDelay, 66);
    // No cap given is a cap of nothing, never an open one.
    await b.pay(invoice: inv0);
    expect(f.maxFee, BigInt.zero);
    expect(f.maxDelay, isNull);

    f.payThrows = Exception('{"error":{"kind":"ark","message":"refused: a payment from the ark may lock for 218 blocks, more than the 66 allowed"}}');
    final r = await b.pay(invoice: inv0, maxFeeSats: BigInt.one, maxDelay: 66);
    expect(r['state'], 'failed');
    expect('${r['reason']}', contains('218 blocks'));

    // An error that is not a refusal may have left the payment under way.
    f.calls.clear();
    f.payThrows = Exception('the server did not answer');
    f.status = {'state': 'pending'};
    expect((await b.pay(invoice: inv0, maxFeeSats: BigInt.one))['state'], 'pending');
    expect(f.calls, ['pay', 'status:true']);
    f.status = {'state': 'none'};
    expect((await b.pay(invoice: inv0, maxFeeSats: BigInt.one))['state'], 'none');

    f.payThrows = null;
    f.payAnswer = {'state': 'failed', 'reason': 'no route'};
    expect(await b.pay(invoice: inv0), {'state': 'failed', 'reason': 'no route'});
    f.payAnswer = {'state': 'pending', 'fee': '3', 'amount': '250000'};
    expect(await b.pay(invoice: inv0), {'state': 'pending'});
  });

  test('a payment\'s state is driven by the server, and an unreadable one stays pending', () async {
    final f = FakeArk()..status = {'state': 'complete', 'preimage': 'ef' * 32};
    final b = ArkBtcLightning(f);
    expect(await b.payStatus(hash0), {'state': 'complete', 'preimage': 'ef' * 32});
    expect(f.calls, ['status:true']);
  });
}
