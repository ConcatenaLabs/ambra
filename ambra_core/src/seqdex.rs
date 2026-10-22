//! SeqDEX same-chain atomic swap — the taker (proposer) half.
//!
//! `lwk_wollet::Wollet::seqdex_swap_request` builds the taker's unsigned/unblinded
//! PSETv2 + revealed input blinders; the daemon's `/v1/trade/propose` returns a
//! SwapAccept PSET (maker already signed) which the taker signs and returns to
//! `/v1/trade/complete`. Two pieces have no Rust API and live here:
//!   - the SwapRequest JSON serializer (the lwk structs derive no serde), a port
//!     of `lwk_wasm::seqdex_swap::SwapRequest::to_json`, and
//!   - the bip32/global-xpub strip the Go daemon requires before CompleteTrade.
//!
//! The FFI entry points (seqdex_build_swap_request / seqdex_sign_accept) live in
//! `api::mod` next to `with_synced_wollet` + `finalize_and_broadcast`.

use std::str::FromStr;

use lwk_wollet::elements::pset::PartiallySignedTransaction;
use lwk_wollet::SeqdexSwapRequest;

use crate::AmbraResult;

/// Serialize a [`SeqdexSwapRequest`] to the daemon's `seqdex.v1.SwapRequest` JSON.
///
/// Field shape is a faithful port of the wasm `to_json`: `amount_p`/`amount_r`
/// are JSON **strings** (JS_STRING uint64 over grpc-gateway) while each input's
/// `amount` is a JSON **number**; the blinders are display-order hex emitted
/// verbatim (already byte-reversed by lwk — never re-encode them).
pub fn swap_request_json(req: &SeqdexSwapRequest) -> AmbraResult<String> {
    #[derive(serde::Serialize)]
    struct UnblindedInputJson<'a> {
        index: u32,
        asset: &'a str,
        amount: u64,
        asset_blinder: &'a str,
        amount_blinder: &'a str,
    }
    #[derive(serde::Serialize)]
    struct SwapRequestJson<'a> {
        id: &'a str,
        amount_p: String,
        asset_p: &'a str,
        amount_r: String,
        asset_r: &'a str,
        transaction: &'a str,
        unblinded_inputs: Vec<UnblindedInputJson<'a>>,
    }
    let json = SwapRequestJson {
        id: &req.id,
        amount_p: req.amount_p.to_string(),
        asset_p: &req.asset_p,
        amount_r: req.amount_r.to_string(),
        asset_r: &req.asset_r,
        transaction: &req.transaction,
        unblinded_inputs: req
            .unblinded_inputs
            .iter()
            .map(|u| UnblindedInputJson {
                index: u.index,
                asset: &u.asset,
                amount: u.amount,
                asset_blinder: &u.asset_blinder,
                amount_blinder: &u.amount_blinder,
            })
            .collect(),
    };
    serde_json::to_string(&json).map_err(|e| format!("{e:?}"))
}

/// Read back a SwapRequest JSON written by [`swap_request_json`], so the taker can
/// check the maker's answer against the request it built (the transaction is what
/// the check compares; the other fields come back as written).
pub fn swap_request_from_json(json: &str) -> AmbraResult<SeqdexSwapRequest> {
    #[derive(serde::Deserialize)]
    struct In {
        index: u32,
        asset: String,
        amount: u64,
        asset_blinder: String,
        amount_blinder: String,
    }
    #[derive(serde::Deserialize)]
    struct Req {
        id: String,
        amount_p: String,
        asset_p: String,
        amount_r: String,
        asset_r: String,
        transaction: String,
        unblinded_inputs: Vec<In>,
    }
    let r: Req = serde_json::from_str(json).map_err(|e| format!("swap request JSON: {e}"))?;
    let num = |s: &str| s.parse::<u64>().map_err(|e| format!("swap request amount {s:?}: {e}"));
    Ok(SeqdexSwapRequest {
        id: r.id,
        amount_p: num(&r.amount_p)?,
        asset_p: r.asset_p,
        amount_r: num(&r.amount_r)?,
        asset_r: r.asset_r,
        transaction: r.transaction,
        unblinded_inputs: r
            .unblinded_inputs
            .into_iter()
            .map(|u| lwk_wollet::SeqdexUnblindedInput {
                index: u.index,
                asset: u.asset,
                amount: u.amount,
                asset_blinder: u.asset_blinder,
                amount_blinder: u.amount_blinder,
            })
            .collect(),
    })
}

/// Remove the elements-rs bip32 derivation + global-xpub fields a freshly-signed
/// PSET carries, which the daemon's go-elements parser rejects
/// ("invalid swap request transaction"). The partial signatures (and everything
/// else) are kept, so the daemon — or our self-broadcast fallback — can finalize.
///
/// This operates on the typed PSET (clearing the exact maps the JS byte-walk
/// targets: global `PSBT_GLOBAL_XPUB`, input/output `*_BIP32_DERIVATION`) rather
/// than hand-walking bytes, so it can't miscount a key/value length.
pub fn strip_bip32(signed_pset_b64: &str) -> AmbraResult<String> {
    let mut pset = PartiallySignedTransaction::from_str(signed_pset_b64).map_err(|e| format!("{e:?}"))?;
    pset.global.xpub.clear();
    for input in pset.inputs_mut() {
        input.bip32_derivation.clear();
    }
    for output in pset.outputs_mut() {
        output.bip32_derivation.clear();
    }
    Ok(pset.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use lwk_wollet::{SeqdexSwapRequest, SeqdexUnblindedInput};

    #[test]
    fn swap_request_json_shape() {
        // amount_p / amount_r are STRINGS; per-input amount is a NUMBER; blinders verbatim.
        let req = SeqdexSwapRequest {
            id: "deadbeefdeadbeef".into(),
            amount_p: 1000,
            asset_p: "aa".into(),
            amount_r: 2500,
            asset_r: "bb".into(),
            transaction: "cHNldP8B".into(),
            unblinded_inputs: vec![SeqdexUnblindedInput {
                index: 0,
                asset: "aa".into(),
                amount: 4242,
                asset_blinder: "01".into(),
                amount_blinder: "02".into(),
            }],
        };
        let s = swap_request_json(&req).unwrap();
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["amount_p"], serde_json::json!("1000")); // string
        assert_eq!(v["amount_r"], serde_json::json!("2500")); // string
        assert_eq!(v["unblinded_inputs"][0]["amount"], serde_json::json!(4242)); // number
        assert_eq!(v["unblinded_inputs"][0]["index"], serde_json::json!(0)); // number
        assert_eq!(v["unblinded_inputs"][0]["asset_blinder"], serde_json::json!("01"));
        assert_eq!(v["id"], serde_json::json!("deadbeefdeadbeef"));
        // And it reads back as written.
        let back = swap_request_from_json(&s).unwrap();
        assert_eq!(back.amount_p, 1000);
        assert_eq!(back.amount_r, 2500);
        assert_eq!(back.transaction, "cHNldP8B");
        assert_eq!(back.unblinded_inputs, req.unblinded_inputs);
    }
}
