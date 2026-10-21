// Mobile twin of the web wallet's feerates-gating.test.mjs. Pins the first-principle fee rule:
// tSEQ (the policy asset) is offered as a fee option ONLY when this node's /feerates feed prices
// it, judged by the same predicate as every issued asset (feeRateFor in
// lib/src/data/fee_asset_rule.dart), with no fabricated fallback rate. A feed keys an asset by
// ticker or hex, and may key the policy asset as "bitcoin" (Elements naming).
//
//   cd app && flutter test test/feerates_gating_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/config.dart';
import 'package:ambra/src/data/fee_asset_rule.dart';

const policy = SeqAssets.policy;
const gold = '3a0f9192219db59f8d7f87d93ac6311095dfe1255d149727b87baaa7d2cc71a1';
const oilx = '4dfe69c334a9cdf4005ddf3889bba1bc397703fa8da669254877f3209caf7c8f';

BigInt? rateFor(Map<String, BigInt> feed, String hex) => feeRateFor(feed, hex);

// The send screen's fee options: the held assets the feed prices, tSEQ among them on equal terms.
List<String> feeOptions(Map<String, BigInt> feed, List<String> held) =>
    held.where((id) => rateFor(feed, id) != null).toList();

void main() {
  test('feed PRICES tSEQ -> tSEQ offered + priced assets offered, unpriced gated out', () {
    final feed = {'bitcoin': BigInt.from(100000000), 'GOLD': BigInt.from(200000000)}; // OILX absent
    final offered = feeOptions(feed, [policy, gold, oilx]);
    expect(offered.contains(policy), isTrue, reason: 'tSEQ offered when the feed prices it (via "bitcoin")');
    expect(offered.contains(gold), isTrue, reason: 'a priced held asset is offered');
    expect(offered.contains(oilx), isFalse, reason: 'an unpriced held asset is gated out — same rule as tSEQ');
    expect(rateFor(feed, policy), BigInt.from(100000000), reason: 'tSEQ rate comes from the feed reference, not fabricated');
  });

  test('feed OMITS tSEQ -> tSEQ NOT offered (de-privileged), other priced assets still offered', () {
    final feed = {'GOLD': BigInt.from(200000000), 'OILX': BigInt.from(3)}; // no "bitcoin" -> SEQ not accepted
    expect(rateFor(feed, policy), isNull, reason: 'no fabricated reference when the feed omits it');
    final offered = feeOptions(feed, [policy, gold, oilx]);
    expect(offered.contains(policy), isFalse, reason: 'tSEQ is NOT offered when the feed omits it (no privilege)');
    expect(offered.contains(gold), isTrue);
    expect(offered.contains(oilx), isTrue);
  });
}
