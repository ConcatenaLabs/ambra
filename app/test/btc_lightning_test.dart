// The wallet's Bitcoin Lightning for user-mode BTC trades (data/btc_lightning.dart), against a
// stand-in for the service: the hold's preimage stays the wallet's until a payment of the whole
// amount is held, and a payment is called failed only when nothing of it can still be in flight.
// The same cases as the web wallet's btc-lightning.test.mjs.
import 'dart:convert';

import 'package:ambra/src/data/btc_lightning.dart';
import 'package:ambra/src/data/lsp_client.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';

// BOLT 11's example invoice: 250,000 sat, made at 1496314658, one-minute expiry.
const inv0 =
    'lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpuaztrnwngzn3kdzw5hydlzf03qdgm2hdq27cqv3agm2awhz5se903vruatfhq77w3ls4evs3ch9zw97j25emudupq63nyw24cg27h2rspfj9srp';
final sats = BigInt.from(250000);
const cs = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

int polymod(List<int> v) {
  const g = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final x in v) {
    final b = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ x;
    for (var i = 0; i < 5; i++) {
      if ((b >> i) & 1 == 1) chk ^= g[i];
    }
  }
  return chk;
}

// The invoice with `hash` as its `p` field and a valid checksum (what the service's hold-bolt11.mjs
// does before the node signs it).
String withHash(String inv, String hash) {
  final sep = inv.lastIndexOf('1');
  final hrp = inv.substring(0, sep);
  final data = [for (final ch in inv.substring(sep + 1).split('')) cs.indexOf(ch)]..removeRange(inv.length - sep - 1 - 6, inv.length - sep - 1);
  final groups = <int>[];
  var acc = 0, bits = 0;
  for (var i = 0; i < 64; i += 2) {
    acc = (acc << 8) | int.parse(hash.substring(i, i + 2), radix: 16);
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      groups.add((acc >> bits) & 31);
    }
  }
  groups.add((acc << (5 - bits)) & 31);
  var i = 7;
  while (true) {
    final t = data[i], len = (data[i + 1] << 5) | data[i + 2];
    if (t == 1 && len == 52) {
      data.replaceRange(i + 3, i + 55, groups);
      break;
    }
    i += 3 + len;
  }
  final ex = [...hrp.codeUnits.map((x) => x >> 5), 0, ...hrp.codeUnits.map((x) => x & 31)];
  final mod = polymod([...ex, ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
  return '${hrp}1${[...data, for (var k = 0; k < 6; k++) (mod >> (5 * (5 - k))) & 31].map((v) => cs[v]).join()}';
}

class FakeLsp implements BtcLsp {
  FakeLsp({this.otherHash, this.payErr, this.payAnswer, this.payStatusAnswer});
  final String? otherHash;
  final Object? payErr;
  final Map<String, dynamic>? payAnswer, payStatusAnswer;
  final calls = <List<dynamic>>[];
  final hold = <String, dynamic>{'state': 'waiting', 'received_msat': 0, 'htlc_expiry': null, 'btc_tip': 100};
  String? storedAtInvoice;
  late Future<String?> Function() peek;

  @override
  Future<Map<String, dynamic>> invoice(Map<String, dynamic> b) async {
    calls.add(['invoice', b]);
    storedAtInvoice = await peek();
    return {'bolt11': b['bolt11'] == true ? withHash(inv0, otherHash ?? '${b['payment_hash']}') : null, 'payment_hash': b['payment_hash']};
  }

  @override
  Future<Map<String, dynamic>> invoiceStatus(String nodeKey, String hash) async => {...hold};
  @override
  Future<void> settle(String nodeKey, String hash, String preimage) async {
    calls.add(['settle', preimage]);
    hold['state'] = 'settled';
  }

  @override
  Future<Map<String, dynamic>> pay(Map<String, dynamic> b) async {
    calls.add(['pay', b]);
    if (payErr != null) throw payErr!;
    return payAnswer ?? {'paid': true, 'preimage': '11' * 32};
  }

  @override
  Future<Map<String, dynamic>> payStatus(String nodeKey, String hash) async => payStatusAnswer ?? {'state': 'none'};
  @override
  Future<Map<String, dynamic>> payQuote(String nodeKey, String bolt11) async => {'route_found': true, 'fee_msat': 1001, 'delay': 52};
}

final order = <String>[];

({HostedBtcLightning btc, FakeLsp lsp}) setup({String? otherHash, Object? payErr, Map<String, dynamic>? payStatus, BigInt? receivable}) {
  String? store;
  order.clear();
  final lsp = FakeLsp(otherHash: otherHash, payErr: payErr, payStatusAnswer: payStatus);
  lsp.peek = () async => store;
  final btc = HostedBtcLightning(
    lsp: lsp,
    nodeKey: () async {
      order.add('node');
      return 'btc:02aa';
    },
    spendable: () async => BigInt.from(5000000),
    receivable: receivable == null
        ? null
        : () async {
            order.add('receivable');
            return receivable;
          },
    read: () async => store,
    write: (v) async => store = v,
    now: () => 1496314658000,
  );
  return (btc: btc, lsp: lsp);
}

String sha(String hex) => c.sha256.convert([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]).toString();

void main() {
  test('the invoice reader: amount, hash, final delta, when it was made and how long it runs; a broken one refused', () {
    final d = decodeBtcInvoice(inv0);
    expect(d['sats'], sats);
    expect(d['payment_hash'], '0001020304050607080900010203040506070809000102030405060708090102');
    expect(d['expires_at'], 1496314658 + 60);
    expect(d['min_final_cltv'], 18);
    expect(() => decodeBtcInvoice('${inv0.substring(0, inv0.length - 1)}q'), throwsFormatException);
    expect(decodeBtcInvoice(withHash(inv0, 'ab' * 32))['payment_hash'], 'ab' * 32);
  });

  test('a hold under a hash of the wallet\'s, its preimage kept before the node is asked', () async {
    final t = setup();
    final inv = await t.btc.invoice(sats: sats);
    final body = t.lsp.calls.first[1] as Map;
    expect(body['payment_hash'], inv['payment_hash']);
    expect(body['bolt11'], true);
    expect(body.containsKey('preimage'), isFalse, reason: 'the node is never given the preimage to make the invoice');
    final kept = (jsonDecode(t.lsp.storedAtInvoice!) as Map)[inv['payment_hash']] as Map;
    expect(sha('${kept['preimage']}'), inv['payment_hash'], reason: 'kept before the call');
    expect(decodeBtcInvoice('${inv['invoice']}')['payment_hash'], inv['payment_hash']);
  });

  test('the node up first, then its room read, and a hold for more refused before anything is drawn or asked', () async {
    final t = setup(receivable: sats - BigInt.one);
    await expectLater(t.btc.invoice(sats: sats), throwsA(predicate((e) => '$e'.contains('the node cannot receive that much now'))));
    expect(order, ['node', 'receivable'], reason: 'the node is brought up first (a first trade provisions it), then its room read');
    expect(t.lsp.calls, isEmpty, reason: 'no invoice asked of the service');
    expect(await t.lsp.peek(), isNull, reason: 'no preimage drawn and kept');
    final ok = setup(receivable: sats);
    expect((await ok.btc.invoice(sats: sats))['payment_hash'], isNotNull);
  });

  test('refused: a node invoice under another hash', () async {
    final t = setup(otherHash: 'cd' * 32);
    await expectLater(t.btc.invoice(sats: sats), throwsA(predicate((e) => '$e'.contains('not the hold asked for'))));
  });

  test('settled only when the whole amount is held with blocks to spare; never once cancelled', () async {
    var t = setup();
    var inv = await t.btc.invoice(sats: sats);
    final hash = '${inv['payment_hash']}';
    expect((await t.btc.invoiceStatus(hash))['status'], 'unpaid');
    t.lsp.hold.addAll({'state': 'accepted', 'received_msat': 250000000 - 1, 'htlc_expiry': 150});
    expect((await t.btc.invoiceStatus(hash))['status'], 'unpaid', reason: 'one msat short');
    t.lsp.hold.addAll({'received_msat': 250000000, 'htlc_expiry': 102});
    expect((await t.btc.invoiceStatus(hash))['status'], 'unpaid', reason: 'two blocks from its expiry');
    expect(t.lsp.calls.where((c) => c[0] == 'settle'), isEmpty);
    t.lsp.hold['htlc_expiry'] = 150;
    final st = await t.btc.invoiceStatus(hash);
    expect(st['status'], 'paid');
    expect(sha('${st['preimage']}'), hash);
    expect(t.lsp.calls.where((c) => c[0] == 'settle').length, 1);

    t = setup();
    inv = await t.btc.invoice(sats: sats);
    await t.btc.cancelInvoice('${inv['payment_hash']}');
    t.lsp.hold.addAll({'state': 'accepted', 'received_msat': 250000000, 'htlc_expiry': 150});
    expect((await t.btc.invoiceStatus('${inv['payment_hash']}'))['status'], 'expired');
    expect(t.lsp.calls.where((c) => c[0] == 'settle'), isEmpty, reason: 'a cancelled hold is never settled');
  });

  test('a hold the node forgot is registered again', () async {
    final t = setup();
    final inv = await t.btc.invoice(sats: sats);
    t.lsp.hold['state'] = 'unknown';
    expect((await t.btc.invoiceStatus('${inv['payment_hash']}'))['status'], 'unpaid');
    final again = t.lsp.calls.where((c) => c[0] == 'invoice').toList()[1][1] as Map;
    expect(again['payment_hash'], inv['payment_hash']);
    expect(again['bolt11'], isNull);
    expect(again.containsKey('preimage'), isFalse);
  });

  test('a payment: capped at the ticket\'s fee; failed only when nothing can be in flight', () async {
    final inv = withHash(inv0, 'ef' * 32);
    var t = setup();
    final rt = await t.btc.payRoute(inv);
    expect(rt!.fee, BigInt.two);
    expect(rt.delay, 52);
    var st = await t.btc.pay(invoice: inv, maxFeeSats: BigInt.two, maxDelay: 58);
    expect(st['state'], 'complete');
    final b = t.lsp.calls.firstWhere((c) => c[0] == 'pay')[1] as Map;
    expect(b['wantHash'], 'ef' * 32);
    expect(b['maxfee_msat'], 2000);
    expect(b['max_cltv'], 58);
    expect(b['amount_msat'], 250000000);
    t = setup(payErr: LspHttpException(403, 'over the daily limit'));
    expect((await t.btc.pay(invoice: inv))['state'], 'failed');
    final gateway = LspHttpException(502, 'pay: timed out');
    t = setup(payErr: gateway, payStatus: {'state': 'pending'});
    expect((await t.btc.pay(invoice: inv))['state'], 'pending', reason: 'a 502 is not a failure');
    t = setup(payErr: gateway, payStatus: {'state': 'complete', 'preimage': '22' * 32});
    st = await t.btc.pay(invoice: inv);
    expect(st, {'state': 'complete', 'preimage': '22' * 32});
    t = setup(payErr: gateway, payStatus: {'state': 'failed'});
    expect((await t.btc.pay(invoice: inv))['state'], 'failed');
  });
}
