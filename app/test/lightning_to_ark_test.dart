// What of a channel a wallet made before the ark moves there: all of it less the route's fee;
// for an asset, only to an operator that receives it over Lightning, once at a time, and shown
// as moving until its leaf is the wallet's.
import 'package:ambra/src/data/lightning_to_ark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all of it less 1% and 10 sats; nothing below the least worth moving', () {
    expect(LightningToArk.amountToMove(BigInt.from(100000)), BigInt.from(98990));
    expect(LightningToArk.amountToMove(BigInt.from(5000)), isNull);
    expect(LightningToArk.amountToMove(BigInt.from(5200)), BigInt.from(5138));
    expect(LightningToArk.amountToMove(BigInt.zero), isNull);
  });

  test('an asset moves only what reaches the operator\'s smallest leaf', () {
    expect(LightningToArk.amountToMove(BigInt.from(198000000000), min: BigInt.from(1000000)), BigInt.from(196019999990));
    expect(LightningToArk.amountToMove(BigInt.from(1000000), min: BigInt.from(1000000)), isNull);
    expect(LightningToArk.amountToMove(BigInt.from(100), min: BigInt.from(12)), BigInt.from(89));
  });

  test('only assets whose operator node is up and receives, and never a supervised one', () {
    final info = {
      'server_info': {
        'assets': [
          {'asset': 'a', 'lightning': {'state': 'up', 'receives': true}},
          {'asset': 'b', 'lightning': {'state': 'down', 'receives': true}},
          {'asset': 'c', 'lightning': {'state': 'up', 'receives': false}},
          {'asset': 'd', 'lightning': null},
          {'asset': 'e', 'supervised': {}, 'lightning': {'state': 'up', 'receives': true}},
        ],
      },
    };
    expect(lightningLegs(info), ['a']);
    expect(lightningLegs(null), isEmpty);
    expect(lightningLegs({'assets': []}), isEmpty);
  });

  test('a receive under way holds the next move of its asset', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
    expect(receivesUnderWay({}, 'a', now), isFalse);
    expect(receivesUnderWay({'h': {'asset': 'a', 'state': 'waiting', 'expires_at': 2000}}, 'a', now), isTrue);
    expect(receivesUnderWay({'h': {'asset': 'a', 'state': 'waiting', 'expires_at': 500}}, 'a', now), isFalse);
    expect(receivesUnderWay({'h': {'asset': 'a', 'state': 'issuing', 'expires_at': 500}}, 'a', now), isTrue);
    expect(receivesUnderWay({'h': {'asset': 'a', 'state': 'claiming'}}, 'a', now), isTrue);
    expect(receivesUnderWay({'h': {'asset': 'a', 'state': 'received'}}, 'a', now), isFalse);
    expect(receivesUnderWay({'h': {'asset': 'a', 'state': 'failed'}}, 'a', now), isFalse);
    expect(receivesUnderWay({'h': {'asset': 'b', 'state': 'issuing'}}, 'a', now), isFalse);
  });

  test('moving: a paid receive until its leaf is a coin of the wallet\'s', () {
    final receives = {
      'h1': {'asset': 'a', 'state': 'waiting', 'amount': '1000', 'value': '990'},
      'h2': {'asset': 'a', 'state': 'issuing', 'amount': '500', 'value': '495'},
      'h3': {'asset': 'b', 'state': 'received', 'amount': '700', 'value': '690'},
      'h4': {'asset': 'b', 'state': 'waiting', 'amount': '800', 'value': '790'},
    };
    // h4 was never paid from the channel by the wallet (a trade's receive): not moving.
    expect(movingOf(receives, const [], {'h1', 'h2', 'h3'}), {'a': BigInt.from(1500)});
    // h2's leaf came: counted as a leaf from then, not twice.
    expect(movingOf(receives, [{'state': 'receiving', 'asset': 'a', 'value': '495'}], {'h1', 'h2'}), {'a': BigInt.from(1000)});
    expect(movingOf(receives, const [], {}), isEmpty);
    // A waiting invoice that lapsed moved nothing.
    final lapsed = {'h1': {'asset': 'a', 'state': 'waiting', 'amount': '1000', 'value': '990', 'expires_at': 500}};
    expect(movingOf(lapsed, const [], {'h1'}, now: DateTime.fromMillisecondsSinceEpoch(1000 * 1000)), isEmpty);
  });

  test('only a locked-in channel pays; one waiting for its funding does not', () {
    expect(channelLockedIn({'state': 'CHANNELD_NORMAL'}), isTrue);
    expect(channelLockedIn({'state': 'CHANNELD_AWAITING_LOCKIN'}), isFalse);
    expect(channelLockedIn({'state': 'CHANNELD_SHUTTING_DOWN'}), isFalse);
    expect(channelLockedIn({}), isFalse);
  });

  test('a receive whose payment was refused holds nothing back', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
    final r = {'h': {'asset': 'a', 'state': 'waiting', 'expires_at': 2000}};
    expect(receivesUnderWay(r, 'a', now, givenUp: {'h'}), isFalse);
    expect(receivesUnderWay(r, 'a', now, givenUp: {'x'}), isTrue);
  });

  test('a move is held to nine tenths of what the daily limit allows', () {
    final usdxLimit = BigInt.from(100000000000); // 1,000 USDX at 1:1
    expect(LightningToArk.withinAllowance(BigInt.from(196019963251), usdxLimit, min: BigInt.from(1000000)), BigInt.from(90000000000));
    expect(LightningToArk.withinAllowance(BigInt.from(37610), BigInt.from(1290000)), BigInt.from(37610));
    expect(LightningToArk.withinAllowance(BigInt.from(37610), null), BigInt.from(37610));
    expect(LightningToArk.withinAllowance(BigInt.from(37610), BigInt.from(4000)), isNull); // 3,600 < 5,000 sat
    expect(LightningToArk.withinAllowance(null, usdxLimit), isNull);
  });
}
