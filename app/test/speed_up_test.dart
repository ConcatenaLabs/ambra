import 'package:flutter_test/flutter_test.dart';
import 'package:ambra/src/data/default_words.dart';
import 'package:ambra/src/data/speed_up_service.dart';

void main() {
  test('a transaction is due once it has waited two blocks, and again as long after each raise', () {
    final book = <String, dynamic>{};
    expect(SpeedUpService.dueNow(book, ['a'], 100), isEmpty);
    expect(SpeedUpService.dueNow(book, ['a'], 101), isEmpty);
    expect(SpeedUpService.dueNow(book, ['a'], 102), ['a']);
    (book['a'] as Map)['raises'] = 1;
    (book['a'] as Map)['raisedAt'] = 102;
    expect(SpeedUpService.dueNow(book, ['a'], 103), isEmpty);
    expect(SpeedUpService.dueNow(book, ['a'], 104), ['a']);
    (book['a'] as Map)['raises'] = SpeedUpService.maxRaises;
    expect(SpeedUpService.dueNow(book, ['a'], 200), isEmpty);
    expect(SpeedUpService.dueNow(book, [], 201), isEmpty);
    expect(book, isEmpty, reason: 'a mined transaction leaves the book');
  });

  test('the words say none of default mode\'s forbidden words', () {
    for (final w in DefaultWords.forbidden) {
      expect(RegExp('\\b$w\\b', caseSensitive: false).hasMatch(SpeedUpService.spedUp), isFalse, reason: w);
    }
  });
}
