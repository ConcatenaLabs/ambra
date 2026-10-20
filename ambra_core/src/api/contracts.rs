//! Contract spends under the five-point rule (`crate::contracts`), for the
//! developer-mode Contracts screen.
//!
//! `contract_prepare` hands the screen the engine's summary, with its digest, and
//! keeps the prepared spend under that digest; `contract_sign` signs only the
//! spend prepared under the digest the screen showed, and only once.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, OnceLock};

use anyhow::Result;
use lwk_contracts::approval::{Approval, AssetLabel};
use lwk_signer::SwSigner;

use super::{err, with_synced_wollet};
use crate::contracts::{self, Ask, ContractChain};

fn pending() -> &'static Mutex<HashMap<String, Approval>> {
    static P: OnceLock<Mutex<HashMap<String, Approval>>> = OnceLock::new();
    P.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The template hashes this wallet signs for (the kit's), as JSON.
#[flutter_rust_bridge::frb(sync)]
pub fn contract_known_templates() -> String {
    serde_json::to_string(&contracts::known_templates()).unwrap_or_default()
}

/// Checks a spend asked as `askJson` (`{templateHash, instance, request | drip,
/// fund?}`) with the kit's engine against this wallet, synced from `esplora_url`;
/// `labels_json` maps asset ids to `{ticker, precision}`. Returns the summary to
/// show, as JSON, its `digest` the one `contract_sign` takes back; or the engine's
/// refusal.
pub fn contract_prepare(
    mnemonic: String,
    esplora_url: String,
    ask_json: String,
    labels_json: String,
) -> Result<String> {
    let ask: Ask = serde_json::from_str(&ask_json).map_err(|e| err(format!("the request: {e}")))?;
    let labels: BTreeMap<String, AssetLabel> = if labels_json.trim().is_empty() {
        BTreeMap::new()
    } else {
        serde_json::from_str(&labels_json).map_err(|e| err(format!("asset labels: {e}")))?
    };
    let signer = SwSigner::new(&mnemonic, false).map_err(|e| err(format!("{e:?}")))?;
    let prepared = with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        contracts::prepare(&ContractChain::testnet(), wollet, &signer, &esplora_url, &ask, &labels)
            .map_err(err)
    })?;
    let digest = prepared.approval.digest().to_string();
    pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(digest, prepared.approval);
    Ok(prepared.summary.to_string())
}

/// Signs the spend prepared under `shown_digest`, the digest of the summary the
/// screen showed, and broadcasts it. A digest no summary was prepared under signs
/// nothing. Returns the txid.
pub fn contract_sign(mnemonic: String, esplora_url: String, shown_digest: String) -> Result<String> {
    let approval = pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&shown_digest)
        .ok_or_else(|| {
            err(format!(
                "no spend was shown with digest {shown_digest}; nothing was signed"
            ))
        })?;
    let signer = SwSigner::new(&mnemonic, false).map_err(|e| err(format!("{e:?}")))?;
    let txid = contracts::sign_and_broadcast(&approval, &shown_digest, &signer, &esplora_url).map_err(err)?;
    super::clear_scan_marks();
    Ok(txid)
}

/// Forgets a spend the screen showed and the user declined.
#[flutter_rust_bridge::frb(sync)]
pub fn contract_discard(digest: String) {
    pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&digest);
}
