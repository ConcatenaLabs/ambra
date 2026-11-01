// arca#501: BTC leaves the Bitcoin ark alone only by the wallet's one rule (bark-wasm's
// `exit_auto`), and default mode says what happened and what it cost, in its own words: the
// web wallet's exitNoteOf, here for Ambra.
import 'package:ambra/src/data/ark_btc_service.dart';
import 'package:ambra/src/data/default_words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('what default mode says about BTC leaving alone', () {
    final note = ArkBtcService.exitNoteOf;
    expect(note({'action': 'none', 'ark': 'answering'}), isNull);
    expect(note({'action': 'none', 'ark': 'unreachable', 'not_worth': []}), isNull);
    expect(ArkBtcService.formatSats(BigInt.from(209340)), '0.0020934');
    expect(ArkBtcService.formatSats(BigInt.from(100000000)), '1');
    expect(note({'action': 'started', 'ark': 'unreachable', 'started': {'amount': '209340', 'cost': '8695'}})!.$2,
        DefaultWords.exitStarted('0.0020934', '0.00008695'));
    expect(
        note({'action': 'none', 'ark': 'unreachable', 'progress': {'pending': 1, 'exits': [{'state': 'waiting_out_its_delay'}]}},
                pendingSats: BigInt.from(98250))!
            .$2,
        DefaultWords.exitMoving('0.0009825'));
    // A claim already sent is not "moving".
    expect(note({'action': 'none', 'ark': 'unreachable', 'progress': {'pending': 1, 'exits': [{'state': 'claiming'}]}},
            pendingSats: BigInt.from(98250)),
        isNull);
    final arrived = note({'action': 'none', 'ark': 'unreachable', 'progress': {'claimed': {'amount': '98250'}}}, lastCost: '8695')!;
    expect(arrived.$1, 'arrived');
    expect(arrived.$2, DefaultWords.exitArrived('0.0009825', '0.00008695'));
    expect(note({'action': 'cannot_start', 'ark': 'refused', 'amount': '99670', 'needed': '1382', 'available': '0'})!.$2,
        DefaultWords.exitNeedsFees('0.0009967', '0.00001382'));
    expect(note({'action': 'none', 'ark': 'unreachable', 'not_worth': [{'amount': '2000'}]})!.$2, DefaultWords.exitNotWorth('0.00002'));
    // While the ark answers, a coin too small to leave alone says nothing.
    expect(note({'action': 'none', 'ark': 'answering', 'not_worth': [{'amount': '2000'}]}), isNull);
  });
}
