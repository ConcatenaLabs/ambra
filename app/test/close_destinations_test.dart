// CloseDestinations: the scripts named to a hosted node's device for a close to the wallet, kept
// per node so they can be named again when that node's signer is rebuilt.
//
//   cd app && flutter test test/close_destinations_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ambra/src/data/close_destinations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  const spk = '0014aabbccddeeff00112233445566778899aabbccdd';

  test('a script is kept for its node only, once, in lower case', () async {
    await CloseDestinations.add('NodeA', spk.toUpperCase());
    await CloseDestinations.add('nodea', spk);
    expect(await CloseDestinations.forNode('nodeA'), [spk]);
    expect(await CloseDestinations.forNode('nodeB'), isEmpty);
  });

  test('the newest scripts are kept', () async {
    for (var i = 0; i < CloseDestinations.keep + 3; i++) {
      await CloseDestinations.add('n', '0014${i.toRadixString(16).padLeft(40, '0')}');
    }
    final list = await CloseDestinations.forNode('n');
    expect(list.length, CloseDestinations.keep);
    expect(list.first, '0014${3.toRadixString(16).padLeft(40, '0')}');
  });

  test('a script that is not hex, or no node, is refused', () async {
    await expectLater(CloseDestinations.add('n', 'zz'), throwsArgumentError);
    await expectLater(CloseDestinations.add('n', '0'), throwsArgumentError);
    await expectLater(CloseDestinations.add('', spk), throwsArgumentError);
    expect(await CloseDestinations.forNode('n'), isEmpty);
  });

  test('a damaged store reads as empty', () async {
    SharedPreferences.setMockInitialValues({'ambra.ln.closeTo.v1': '{not json'});
    expect(await CloseDestinations.forNode('n'), isEmpty);
    await CloseDestinations.add('n', spk);
    expect(await CloseDestinations.forNode('n'), [spk]);
  });
}
