//! An order resting as a leaf in an operator's tree (offer field 26, `resting_leaf`), from
//! seqdex's vectors (`internal/seqob/offer/testdata/resting_leaf_offer_vectors.json`): the canonical
//! bytes are the relay's, the offer verifies where it first rested and where it moved after a
//! part fill (its locator is outside the signed bytes), and fails once a signed term changes.

const V: &str = include_str!("fixtures/resting_leaf_offer_vectors.json");

#[test]
fn a_resting_offer_verifies_as_the_relay_signs_it() {
    let v: serde_json::Value = serde_json::from_str(V).unwrap();
    let canonical = ambra_core::seqob_wire::canonical_offer_bytes(&v["rested"]);
    let hex: String = canonical.iter().map(|b| format!("{:02x}", b)).collect();
    assert_eq!(hex, v["canonical_hex"].as_str().unwrap(), "the canonical bytes are the relay's");
    for k in ["rested", "moved"] {
        assert!(ambra_core::api::seqob_verify_offer(v[k].to_string()).unwrap(), "{} verifies", k);
    }
    for k in ["tampered_rate", "tampered_order"] {
        assert!(!ambra_core::api::seqob_verify_offer(v[k].to_string()).unwrap(), "{} fails", k);
    }
}
