import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'word_name_list.dart';

/// Word names: a payment name of two words from a word list, written together, derived from the
/// name's key ([nameKey] in name_key.dart), so a wallet restored from its phrase gets the same name
/// back. The web wallet's `word-name.js`, the same list and rule: change both together (and the
/// browser extension's copy).
///
///   amberfalcon@sequentiatestnet.com, shown as AmberFalcon@sequentiatestnet.com
///
/// The name itself is the joined words in lower case: LUD-16 allows only a-z 0-9 - _ . in a name,
/// and some payers' wallets refuse capitals. Capitals are for display only ([displayName]); every
/// lookup ignores case.
///
/// A key's candidates come in a fixed order ([wordNameCandidates]): two words first, then three,
/// each from SHA-256 over a tag, the key and the candidate's number. The wallet registers the first
/// the service does not hold already, so a third word is added only when the two-word name is
/// taken.
///
/// The words ([wordNameList]): the EFF short wordlist 1 (Electronic Frontier Foundation, CC BY 3.0
/// US, https://www.eff.org/dice), less every word of the BIP39 English list (a recovery phrase's
/// words never appear in a public name) and the one word that is not letters alone (yo-yo): 831
/// words. See NOTICE.

/// How many candidates a key has: one of two words, then three-word ones.
const wordNameCandidateCount = 8;

/// The SHA-256 of the list joined by newlines, as the web wallet's test pins it.
const wordNameListSha256 = 'fb2954dccc87b4db6399683028b284a1a04fb326f505a267b39ca74827b7f5c7';

const _tag = 'sequentia-name-words/1';

/// The words of candidate [k] of the key [pubHex] (32-byte hex): two for k = 0, three after.
List<String> _wordsAt(String pubHex, int k) {
  final h = sha256.convert(utf8.encode('$_tag\n${pubHex.toLowerCase()}\n$k')).bytes;
  final want = k == 0 ? 2 : 3;
  final out = <String>[];
  for (var i = 0; i + 4 <= h.length && out.length < want; i += 4) {
    final n = (h[i] << 24) | (h[i + 1] << 16) | (h[i + 2] << 8) | h[i + 3];
    final w = wordNameList[n % wordNameList.length];
    if (!out.contains(w)) out.add(w);
  }
  return out;
}

/// The key's candidates, in the order a wallet tries them.
List<({String name, List<String> words})> wordNameCandidates(String pubHex, [int count = wordNameCandidateCount]) => [
      for (var k = 0; k < count; k++)
        (() {
          final w = _wordsAt(pubHex, k);
          return (name: w.join(), words: w);
        })(),
    ];

/// The words of [name] when it is one of the key's candidates, else null.
List<String>? wordsOf(String name, String pubHex) {
  final n = name.toLowerCase();
  for (final c in wordNameCandidates(pubHex)) {
    if (c.name == n) return c.words;
  }
  return null;
}

/// How a name is shown: each word with a capital (AmberFalcon) when it is one of the key's word
/// names, else as it is.
String displayName(String name, String? pubHex) {
  final w = pubHex == null ? null : wordsOf(name, pubHex);
  return w == null ? name : w.map((x) => x[0].toUpperCase() + x.substring(1)).join();
}
