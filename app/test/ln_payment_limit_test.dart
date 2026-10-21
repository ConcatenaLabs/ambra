import 'package:ambra/src/data/ln_payment_limit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the device declining a payment over its limit reads in plain words', () {
    final e = LnPaymentLimit.explain(Exception(
        "Your device declined this payment of 100000000 atoms: it is more than your device's payment "
        'limit for USDX still allows in this period. Nothing was sent and your channel is unchanged.'));
    expect(
        e.toString(),
        'Exception: This payment is over the daily limit your phone sets for Lightning payments '
        '(about 1,000 USD a day). Nothing was sent.');
    expect(e.toString(), isNot(contains('atoms')));
  });

  test('any other failure is passed on as it came', () {
    final e = Exception('No Lightning route to the other side had room for this amount');
    expect(identical(LnPaymentLimit.explain(e), e), isTrue);
  });

  test('the limit is 1,000 a day until developer mode sets another', () async {
    SharedPreferences.setMockInitialValues({});
    final lim = LnPaymentLimit.instance;
    await lim.load();
    expect(lim.reference, LnPaymentLimit.defaultReference);
    expect(LnPaymentLimit.defaultReference, 1000);
    await lim.set(250);
    await lim.load();
    expect(lim.reference, 250);
    expect(lim.refusal(), contains('about 250 USD a day'));
    expect(() => lim.set(0), throwsArgumentError);
  });
}
