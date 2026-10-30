// History's row for a trade of the Swap tab (screens/history_screen.dart, docs/DEFAULT_MODE.md
// "History"): one row per trade, "Swapped <pay> for <get>", its time and, until settled, its
// status, the amounts as -/+ and the fee.
import 'package:ambra/src/data/user_trade.dart';
import 'package:ambra/src/screens/history_screen.dart';
import 'package:flutter_test/flutter_test.dart';

String fmt(String a, BigInt n) => '$n $a';

Map<String, dynamic> rec(String state, {Map<String, dynamic> extra = const {}}) => {
      'id': 't-$state',
      'state': state,
      'at': 1000,
      'sentAt': 2000,
      'ticket': {
        'payAsset': 'USDX',
        'receiveAsset': 'BTC',
        'amountIn': '2000',
        'amountOut': '15',
        'fees': [
          {'asset': 'USDX', 'atoms': '7'},
          {'asset': 'BTC', 'atoms': '0'},
        ],
      },
      ...extra,
    };

void main() {
  test('a settled trade: one row, no status, -pay +get and the fee', () {
    final l = TradeHistoryLine(rec('settled'), fmt: fmt, nowMs: 3000);
    expect(l.title, 'Swapped 2000 USDX for 15 BTC');
    expect(l.status, isNull);
    expect(l.minus, '-2000 USDX');
    expect(l.plus, '+15 BTC');
    expect(l.fee, 'fee 7 USDX');
  });
  test('an open trade says where it stands; a returned one moved nothing', () {
    expect(TradeHistoryLine(rec('sent'), fmt: fmt, nowMs: 3000).status, UserWords.sent);
    final r = TradeHistoryLine(rec('returned'), fmt: fmt, nowMs: 3000);
    expect(r.status, UserWords.returned);
    expect(r.minus, isNull);
    expect(r.fee, isNull);
  });
  test('History lists made trades newest first; none still being confirmed, none that failed', () {
    final rows = tradeHistoryRows([
      rec('settled', extra: {'id': 'old', 'sentAt': 10}),
      rec('sent', extra: {'id': 'new', 'sentAt': 99}),
      rec('confirming'),
      rec('failed'),
      {'id': 'noticket', 'state': 'sent'},
    ]);
    expect(rows.map((r) => r['id']), ['new', 'old']);
  });
}
