//! A covenant offer exactly as the public relay serves it (grpc-gateway JSON, its
//! covenant's byte fields in base64), saved from the testnet book: the maker's
//! signature verifies, and fails once a signed field is changed.

const OFFER: &str = include_str!("fixtures/relay_covenant_offer.json");

#[test]
fn a_relay_served_covenant_offer_verifies() {
    assert!(OFFER.contains("\"maker_prog\": \"") && OFFER.contains("="), "the fixture keeps base64 bytes");
    assert!(ambra_core::api::seqob_verify_offer(OFFER.to_string()).unwrap(), "relay offer verifies");
    let mut o: serde_json::Value = serde_json::from_str(OFFER).unwrap();
    o["covenant"]["rate_num"] = serde_json::Value::String("1".into());
    assert!(!ambra_core::api::seqob_verify_offer(o.to_string()).unwrap(), "a changed rate fails");
}
