//! A site paired by a `nostrconnect://` code (the extension's `doc/PAIRING.md`): the key
//! made for one pairing, and the kind-24133 events it seals and opens. The key signs
//! events of that pairing and nothing else; it is not derived from the wallet's phrase.

use anyhow::Result;

use crate::nostr;

fn e(s: String) -> anyhow::Error {
    anyhow::Error::msg(s)
}

/// A pairing's key pair, hex: the secret and its x-only public key.
pub struct PairingKeys {
    pub secret_hex: String,
    pub pubkey_hex: String,
}

/// A fresh key pair for one pairing.
pub fn pairing_new_keys() -> Result<PairingKeys> {
    let (secret_hex, pubkey_hex) = nostr::new_keys().map_err(e)?;
    Ok(PairingKeys { secret_hex, pubkey_hex })
}

/// A message to `peer_hex`: the signed kind-24133 event (JSON) of `secret_hex`, its
/// content `plaintext` NIP-44 v2 encrypted to `peer_hex`, tagged `p` with it.
pub fn pairing_seal(secret_hex: String, peer_hex: String, created_at: u64, plaintext: String) -> Result<String> {
    Ok(nostr::seal(&secret_hex, &peer_hex, created_at, &plaintext).map_err(e)?.to_string())
}

/// What an event (JSON) addressed to `secret_hex` says, once its id, signature, kind and
/// `p` tag are checked and its content decrypted.
pub struct PairingMessage {
    pub from_hex: String,
    pub created_at: u64,
    pub text: String,
}

pub fn pairing_open(secret_hex: String, event_json: String) -> Result<PairingMessage> {
    let ev: serde_json::Value = serde_json::from_str(&event_json).map_err(|x| e(format!("bad event: {x}")))?;
    let (from_hex, created_at, text) = nostr::open(&secret_hex, &ev).map_err(e)?;
    Ok(PairingMessage { from_hex, created_at, text })
}
