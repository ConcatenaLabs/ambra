import 'package:ambra/src/data/default_words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default mode\'s sentences say none of the contract\'s forbidden words', () {
    for (final s in DefaultWords.all()) {
      for (final w in DefaultWords.forbidden) {
        // A word, not a part of one ("rail" in "trail" is not the word).
        final hit = RegExp('(^|[^A-Za-z])${RegExp.escape(w)}(s|es)?(\$|[^A-Za-z])', caseSensitive: false).hasMatch(s);
        expect(hit, isFalse, reason: '"$s" says "$w"');
      }
    }
  });
}
