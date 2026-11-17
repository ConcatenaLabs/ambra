// receive_watch.dart: what Receive says about a payment coming in (the web wallet's
// receive-watch.test.mjs).
import 'package:ambra/src/data/receive_watch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final usdx = 'aa' * 32, orng = 'bb' * 32;
  ReceiveFigure f(int settled, [int arriving = 0]) => (settled: BigInt.from(settled), arriving: BigInt.from(arriving));
  ReceiveState arriving(String a) => ReceiveState.arriving(a);
  ReceiveState received(String a, int atoms) => ReceiveState.received(a, BigInt.from(atoms));

  test('a payment arriving, then counted: "arriving", then received for its amount', () {
    final w = ReceiveWatch();
    expect(w.start({'BTC': f(0), usdx: f(1000)}), isNull);
    expect(w.update({'BTC': f(0), usdx: f(1000, 2500)}), arriving(usdx));
    expect(w.update({'BTC': f(0), usdx: f(3500)}), received(usdx, 2500));
    // Nothing new: the last word stays.
    expect(w.update({'BTC': f(0), usdx: f(3500)}), received(usdx, 2500));
  });

  test('a payment counted at once, in an asset the wallet did not hold: received', () {
    final w = ReceiveWatch()..start({'BTC': f(0)});
    expect(w.update({'BTC': f(0), orng: f(7)}), received(orng, 7));
    // A second payment is reported for its own amount.
    expect(w.update({'BTC': f(50000), orng: f(7)}), received('BTC', 50000));
  });

  test("a move of the wallet's own, and a trade, say nothing", () {
    final w = ReceiveWatch()..start({usdx: f(1000), 'BTC': f(100)});
    // Taken from the chain for instant payments: counted as arriving while it settles, the total unchanged.
    expect(w.update({usdx: f(0, 1000), 'BTC': f(100)}), isNull);
    expect(w.update({usdx: f(1000), 'BTC': f(100)}), isNull);
    // A trade: one asset down, another up.
    expect(w.update({usdx: f(400), 'BTC': f(160)}), isNull);
    expect(w.update({usdx: f(400), 'BTC': f(160)}), isNull);
  });

  test('a payment out, then a payment in: the payment in is seen whole', () {
    final w = ReceiveWatch()..start({usdx: f(1000)});
    expect(w.update({usdx: f(600)}), isNull);
    expect(w.update({usdx: f(900)}), received(usdx, 300));
  });

  test('not watching (Receive closed): nothing is said; opening again starts afresh', () {
    final w = ReceiveWatch();
    expect(w.update({usdx: f(5)}), isNull);
    w.start({usdx: f(5)});
    w.update({usdx: f(9)});
    w.stop();
    expect(w.watching, isFalse);
    expect(w.start({usdx: f(9)}), isNull);
    expect(w.state, isNull);
  });

  test("coins of the wallet's own coming home say nothing: only value it did not hold is received", () {
    // The change of a payment sent before Receive opened, on its way, then counted.
    var w = ReceiveWatch()..start({usdx: f(0, 890)});
    expect(w.update({usdx: f(890)}), isNull);
    // A move of its own with a fee in the asset: down, on its way, then counted.
    w = ReceiveWatch()..start({usdx: f(1000)});
    expect(w.update({usdx: f(0, 990)}), isNull);
    expect(w.update({usdx: f(990)}), isNull);
    // A payment that lands while coins of its own come home: only the payment.
    expect(w.update({usdx: f(990, 300)}), arriving(usdx));
    expect(w.update({usdx: f(1290)}), received(usdx, 300));
    w = ReceiveWatch()..start({usdx: f(0, 500)});
    expect(w.update({usdx: f(700)}), received(usdx, 200));
  });
}
