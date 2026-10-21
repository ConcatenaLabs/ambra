//! The device signer's payment limit through Ambra's FFI: by default one value in the
//! reference unit, held in each asset at the rate the app gives it.

use ambra_core::api::signer::SeqlnSigner;

const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const USDX: &str = "2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de";

#[test]
fn the_default_limit_is_a_reference_value_at_each_rate() {
    let s = SeqlnSigner::from_mnemonic(MNEMONIC.into()).unwrap();
    // Without a rate the device cannot value USDX: 10,000,000 of its atoms (0.1 USDX).
    assert_eq!(s.payment_limit(USDX.into()).unwrap(), Some(10_000_000));
    // The app gives the node's rate (one reference unit per USDX): 1,000 USDX a day.
    s.set_asset_rate(USDX.into(), Some(100_000_000)).unwrap();
    assert_eq!(s.payment_limit(USDX.into()).unwrap(), Some(1_000 * 100_000_000));
    // Bitcoin at 60,000: the same thousand, 1,666,666 sats.
    s.set_asset_rate("btc".into(), Some(6_000_000_000_000)).unwrap();
    assert_eq!(s.payment_limit("btc".into()).unwrap(), Some(1_666_666));
    // Developer mode's 250 a day.
    s.set_reference_payment_limit(Some(250 * 100_000_000));
    assert_eq!(s.payment_limit(USDX.into()).unwrap(), Some(250 * 100_000_000));
    // A rate forgotten: back to the device's limit for an asset it cannot value.
    s.set_asset_rate(USDX.into(), None).unwrap();
    assert_eq!(s.payment_limit(USDX.into()).unwrap(), Some(10_000_000));
    assert!(s.set_asset_rate("nope".into(), Some(1)).is_err());
    s.set_reference_payment_limit(None);
    assert_eq!(s.payment_limit("btc".into()).unwrap(), None);
}
