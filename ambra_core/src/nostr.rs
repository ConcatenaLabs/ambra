//! The two pieces of Nostr a site pairing needs: NIP-44 v2 encryption and NIP-01 events
//! signed with BIP340.
//!
//! A site (SeqDEX) pairs with Ambra by a `nostrconnect://` code and talks to it through a
//! Nostr relay (the extension's `doc/PAIRING.md`): every message is a kind-24133 event, its
//! content NIP-44 v2 encrypted to the other side and signed by its sender. The key of a
//! pairing is made for that pairing alone; it signs events and nothing else, and never
//! touches the wallet's own keys.
//!
//! Built on the secp256k1, ChaCha20, HKDF, HMAC and SHA-256 crates the core already links;
//! tested against the official NIP-44 vectors (`tests/fixtures/nip44.vectors.json`).

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use chacha20::cipher::{KeyIvInit, StreamCipher};
use chacha20::ChaCha20;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use secp256k1::{ecdh, schnorr, Keypair, Message, Parity, PublicKey, Secp256k1, SecretKey, XOnlyPublicKey};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

/// The kind of a Nostr Connect message: ephemeral, so relays forward it and keep nothing.
pub const KIND_CONNECT: u32 = 24133;

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Result<Vec<u8>, String> {
    if s.len() % 2 != 0 || !s.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("not hex".into());
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| e.to_string())).collect()
}

fn unhex32(s: &str, what: &str) -> Result<[u8; 32], String> {
    let v = unhex(s).map_err(|_| format!("{what} must be 32 bytes of hex"))?;
    v.try_into().map_err(|_| format!("{what} must be 32 bytes of hex"))
}

fn secret(s: &str) -> Result<SecretKey, String> {
    SecretKey::from_slice(&unhex32(s, "the secret key")?).map_err(|_| "the secret key is not a valid key".to_string())
}

fn xonly(s: &str) -> Result<XOnlyPublicKey, String> {
    XOnlyPublicKey::from_slice(&unhex32(s, "the public key")?).map_err(|_| "the public key is not on the curve".to_string())
}

/// A fresh key pair: (secret hex, x-only public key hex).
pub fn new_keys() -> Result<(String, String), String> {
    let secp = Secp256k1::signing_only();
    for _ in 0..64 {
        let mut b = [0u8; 32];
        getrandom::getrandom(&mut b).map_err(|e| format!("rng: {e}"))?;
        if let Ok(sk) = SecretKey::from_slice(&b) {
            let (x, _) = sk.x_only_public_key(&secp);
            return Ok((hex(&b), hex(&x.serialize())));
        }
    }
    Err("could not draw a key".into())
}

/// The x-only public key of a secret key, hex.
pub fn public_of(secret_hex: &str) -> Result<String, String> {
    let secp = Secp256k1::signing_only();
    Ok(hex(&secret(secret_hex)?.x_only_public_key(&secp).0.serialize()))
}

// ---------------------------------------------------------------------------
// NIP-44 v2
// ---------------------------------------------------------------------------

/// The conversation key of `secret` and the x-only `peer`: HKDF-extract over the shared
/// point's x coordinate, salt `nip44-v2`. The same both ways round.
pub fn conversation_key(secret_hex: &str, peer_hex: &str) -> Result<[u8; 32], String> {
    let sk = secret(secret_hex)?;
    let pk = PublicKey::from_x_only_public_key(xonly(peer_hex)?, Parity::Even);
    let point = ecdh::shared_secret_point(&pk, &sk);
    let (prk, _) = Hkdf::<Sha256>::extract(Some(b"nip44-v2"), &point[..32]);
    Ok(prk.into())
}

/// (ChaCha20 key, ChaCha20 nonce, HMAC key) of one message: HKDF-expand of the
/// conversation key with the message's nonce, 76 bytes.
fn message_keys(conv: &[u8; 32], nonce: &[u8; 32]) -> Result<([u8; 32], [u8; 12], [u8; 32]), String> {
    let hk = Hkdf::<Sha256>::from_prk(conv).map_err(|_| "bad conversation key".to_string())?;
    let mut okm = [0u8; 76];
    hk.expand(nonce, &mut okm).map_err(|_| "hkdf expand".to_string())?;
    let mut k = [0u8; 32];
    let mut n = [0u8; 12];
    let mut h = [0u8; 32];
    k.copy_from_slice(&okm[..32]);
    n.copy_from_slice(&okm[32..44]);
    h.copy_from_slice(&okm[44..76]);
    Ok((k, n, h))
}

/// The padded length of a plaintext of `len` bytes (1 to 65535).
pub fn padded_len(len: usize) -> usize {
    if len <= 32 {
        return 32;
    }
    let next_power = 1usize << (usize::BITS - (len - 1).leading_zeros());
    let chunk = if next_power <= 256 { 32 } else { next_power / 8 };
    chunk * ((len - 1) / chunk + 1)
}

fn pad(plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let n = plaintext.len();
    if n == 0 || n > 65535 {
        return Err("a message is 1 to 65535 bytes".into());
    }
    let mut out = Vec::with_capacity(2 + padded_len(n));
    out.extend_from_slice(&(n as u16).to_be_bytes());
    out.extend_from_slice(plaintext);
    out.resize(2 + padded_len(n), 0);
    Ok(out)
}

fn unpad(padded: &[u8]) -> Result<Vec<u8>, String> {
    if padded.len() < 2 {
        return Err("invalid padding".into());
    }
    let n = u16::from_be_bytes([padded[0], padded[1]]) as usize;
    if n == 0 || 2 + n > padded.len() || padded.len() != 2 + padded_len(n) {
        return Err("invalid padding".into());
    }
    Ok(padded[2..2 + n].to_vec())
}

/// Encrypts with a given conversation key and nonce (the vectors' form): the base64 payload.
pub fn encrypt_with(conv: &[u8; 32], plaintext: &str, nonce: &[u8; 32]) -> Result<String, String> {
    let (ck, cn, hk) = message_keys(conv, nonce)?;
    let mut buf = pad(plaintext.as_bytes())?;
    ChaCha20::new(&ck.into(), &cn.into()).apply_keystream(&mut buf);
    let mut mac = <HmacSha256 as Mac>::new_from_slice(&hk).map_err(|_| "hmac key".to_string())?;
    mac.update(nonce);
    mac.update(&buf);
    let tag = mac.finalize().into_bytes();
    let mut out = Vec::with_capacity(1 + 32 + buf.len() + 32);
    out.push(2);
    out.extend_from_slice(nonce);
    out.extend_from_slice(&buf);
    out.extend_from_slice(&tag);
    Ok(B64.encode(out))
}

/// Encrypts `plaintext` from `secret` to `peer` with a fresh nonce.
pub fn encrypt(secret_hex: &str, peer_hex: &str, plaintext: &str) -> Result<String, String> {
    let conv = conversation_key(secret_hex, peer_hex)?;
    let mut nonce = [0u8; 32];
    getrandom::getrandom(&mut nonce).map_err(|e| format!("rng: {e}"))?;
    encrypt_with(&conv, plaintext, &nonce)
}

/// Decrypts a payload with a conversation key; refuses an unknown version, a bad length,
/// a bad MAC and bad padding.
pub fn decrypt_with(conv: &[u8; 32], payload: &str) -> Result<String, String> {
    let plen = payload.len();
    if payload.starts_with('#') {
        return Err("unknown encryption version".into());
    }
    if !(132..=87472).contains(&plen) {
        return Err("invalid payload length".into());
    }
    let data = B64.decode(payload).map_err(|_| "invalid base64".to_string())?;
    let dlen = data.len();
    if !(99..=65603).contains(&dlen) {
        return Err("invalid data length".into());
    }
    if data[0] != 2 {
        return Err("unknown encryption version".into());
    }
    let nonce: [u8; 32] = data[1..33].try_into().expect("32 bytes");
    let ct = &data[33..dlen - 32];
    let tag = &data[dlen - 32..];
    let (ck, cn, hk) = message_keys(conv, &nonce)?;
    let mut mac = <HmacSha256 as Mac>::new_from_slice(&hk).map_err(|_| "hmac key".to_string())?;
    mac.update(&nonce);
    mac.update(ct);
    mac.verify_slice(tag).map_err(|_| "invalid MAC".to_string())?;
    let mut buf = ct.to_vec();
    ChaCha20::new(&ck.into(), &cn.into()).apply_keystream(&mut buf);
    String::from_utf8(unpad(&buf)?).map_err(|_| "the message is not UTF-8".to_string())
}

/// Decrypts a payload `peer` sent to `secret`.
pub fn decrypt(secret_hex: &str, peer_hex: &str, payload: &str) -> Result<String, String> {
    decrypt_with(&conversation_key(secret_hex, peer_hex)?, payload)
}

// ---------------------------------------------------------------------------
// NIP-01 events
// ---------------------------------------------------------------------------

/// The id of an event: SHA-256 of `[0, pubkey, created_at, kind, tags, content]`, serialized
/// as NIP-01 says (no white space; JSON's own escapes).
pub fn event_id(pubkey: &str, created_at: u64, kind: u32, tags: &Value, content: &str) -> [u8; 32] {
    let ser = json!([0, pubkey, created_at, kind, tags, content]).to_string();
    Sha256::digest(ser.as_bytes()).into()
}

/// A signed event of `secret`: `{id, pubkey, created_at, kind, tags, content, sig}`.
pub fn sign_event(secret_hex: &str, created_at: u64, kind: u32, tags: &Value, content: &str) -> Result<Value, String> {
    if !tags.as_array().map(|a| a.iter().all(|t| t.as_array().map(|t| t.iter().all(Value::is_string)).unwrap_or(false))).unwrap_or(false) {
        return Err("tags must be a list of lists of strings".into());
    }
    let secp = Secp256k1::signing_only();
    let kp = Keypair::from_secret_key(&secp, &secret(secret_hex)?);
    let pubkey = hex(&kp.x_only_public_key().0.serialize());
    let id = event_id(&pubkey, created_at, kind, tags, content);
    let mut aux = [0u8; 32];
    getrandom::getrandom(&mut aux).map_err(|e| format!("rng: {e}"))?;
    let sig = secp.sign_schnorr_with_aux_rand(&Message::from_digest(id), &kp, &aux);
    Ok(json!({"id": hex(&id), "pubkey": pubkey, "created_at": created_at, "kind": kind, "tags": tags,
        "content": content, "sig": hex(sig.as_ref())}))
}

/// Whether an event's id is its content's and its signature its pubkey's.
pub fn verify_event(ev: &Value) -> bool {
    let (Some(id), Some(pubkey), Some(created_at), Some(kind), Some(tags), Some(content), Some(sig)) = (
        ev["id"].as_str(),
        ev["pubkey"].as_str(),
        ev["created_at"].as_u64(),
        ev["kind"].as_u64(),
        ev.get("tags"),
        ev["content"].as_str(),
        ev["sig"].as_str(),
    ) else {
        return false;
    };
    let Ok(kind) = u32::try_from(kind) else { return false };
    let (Ok(want), Ok(pk), Ok(sig)) = (unhex32(id, "id"), xonly(pubkey), unhex(sig)) else { return false };
    if event_id(pubkey, created_at, kind, tags, content) != want {
        return false;
    }
    let Ok(sig) = schnorr::Signature::from_slice(&sig) else { return false };
    Secp256k1::verification_only().verify_schnorr(&sig, &Message::from_digest(want), &pk).is_ok()
}

/// One message to `peer`: a kind-24133 event of `secret`, its content `plaintext` NIP-44
/// encrypted to `peer`, tagged `p` with `peer`.
pub fn seal(secret_hex: &str, peer_hex: &str, created_at: u64, plaintext: &str) -> Result<Value, String> {
    xonly(peer_hex)?;
    let content = encrypt(secret_hex, peer_hex, plaintext)?;
    sign_event(secret_hex, created_at, KIND_CONNECT, &json!([["p", peer_hex]]), &content)
}

/// What a kind-24133 event addressed to `secret` says: its sender, its time and its
/// decrypted content. Refuses an event whose id or signature is not its own, another kind,
/// or one not tagged `p` with `secret`'s key.
pub fn open(secret_hex: &str, ev: &Value) -> Result<(String, u64, String), String> {
    if !verify_event(ev) {
        return Err("the event's id or signature is not its own".into());
    }
    if ev["kind"].as_u64() != Some(KIND_CONNECT as u64) {
        return Err("not a Nostr Connect event".into());
    }
    let me = public_of(secret_hex)?;
    let to_me = ev["tags"].as_array().into_iter().flatten().any(|t| t[0].as_str() == Some("p") && t[1].as_str() == Some(me.as_str()));
    if !to_me {
        return Err("the event is not addressed to this key".into());
    }
    let from = ev["pubkey"].as_str().unwrap_or_default().to_string();
    let text = decrypt(secret_hex, &from, ev["content"].as_str().unwrap_or_default())?;
    Ok((from, ev["created_at"].as_u64().unwrap_or(0), text))
}

#[cfg(test)]
mod tests {
    use super::*;

    const VECTORS: &str = include_str!("../tests/fixtures/nip44.vectors.json");

    fn v2() -> Value {
        serde_json::from_str::<Value>(VECTORS).unwrap()["v2"].clone()
    }

    fn s<'a>(v: &'a Value, k: &str) -> &'a str {
        v[k].as_str().unwrap()
    }

    #[test]
    fn the_vectors_file_is_the_official_one() {
        // NIP-44 names the file by its SHA-256.
        assert_eq!(hex(&Sha256::digest(VECTORS.as_bytes())), "269ed0f69e4c192512cc779e78c555090cebc7c785b609e338a62afc3ce25040");
    }

    #[test]
    fn conversation_keys() {
        let v = v2();
        let all = v["valid"]["get_conversation_key"].as_array().unwrap();
        for c in all {
            let k = conversation_key(s(c, "sec1"), s(c, "pub2")).unwrap();
            assert_eq!(hex(&k), s(c, "conversation_key"), "{c}");
        }
        assert!(all.len() >= 30);
        for c in v["invalid"]["get_conversation_key"].as_array().unwrap() {
            assert!(conversation_key(s(c, "sec1"), s(c, "pub2")).is_err(), "{c}");
        }
    }

    #[test]
    fn message_keys_match() {
        let v = v2();
        let mk = &v["valid"]["get_message_keys"];
        let conv = unhex32(s(mk, "conversation_key"), "k").unwrap();
        for c in mk["keys"].as_array().unwrap() {
            let (ck, cn, hk) = message_keys(&conv, &unhex32(s(c, "nonce"), "n").unwrap()).unwrap();
            assert_eq!((hex(&ck), hex(&cn), hex(&hk)), (s(c, "chacha_key").into(), s(c, "chacha_nonce").into(), s(c, "hmac_key").into()));
        }
    }

    #[test]
    fn padded_lengths() {
        for c in v2()["valid"]["calc_padded_len"].as_array().unwrap() {
            assert_eq!(padded_len(c[0].as_u64().unwrap() as usize), c[1].as_u64().unwrap() as usize, "{c}");
        }
    }

    #[test]
    fn encrypt_decrypt() {
        for c in v2()["valid"]["encrypt_decrypt"].as_array().unwrap() {
            let conv = conversation_key(s(c, "sec1"), &public_of(s(c, "sec2")).unwrap()).unwrap();
            assert_eq!(hex(&conv), s(c, "conversation_key"));
            // The other side reaches the same key.
            assert_eq!(conversation_key(s(c, "sec2"), &public_of(s(c, "sec1")).unwrap()).unwrap(), conv);
            let nonce = unhex32(s(c, "nonce"), "n").unwrap();
            assert_eq!(encrypt_with(&conv, s(c, "plaintext"), &nonce).unwrap(), s(c, "payload"));
            assert_eq!(decrypt_with(&conv, s(c, "payload")).unwrap(), s(c, "plaintext"));
        }
    }

    #[test]
    fn long_messages() {
        for c in v2()["valid"]["encrypt_decrypt_long_msg"].as_array().unwrap() {
            let conv = unhex32(s(c, "conversation_key"), "k").unwrap();
            let pt = s(c, "pattern").repeat(c["repeat"].as_u64().unwrap() as usize);
            assert_eq!(hex(&Sha256::digest(pt.as_bytes())), s(c, "plaintext_sha256"));
            let payload = encrypt_with(&conv, &pt, &unhex32(s(c, "nonce"), "n").unwrap()).unwrap();
            assert_eq!(hex(&Sha256::digest(payload.as_bytes())), s(c, "payload_sha256"));
            assert_eq!(decrypt_with(&conv, &payload).unwrap(), pt);
        }
    }

    #[test]
    fn invalid_messages_are_refused() {
        let v = v2();
        let conv = [1u8; 32];
        for len in v["invalid"]["encrypt_msg_lengths"].as_array().unwrap() {
            let pt = "a".repeat(len.as_u64().unwrap() as usize);
            assert!(encrypt_with(&conv, &pt, &[0; 32]).is_err(), "length {len}");
        }
        let all = v["invalid"]["decrypt"].as_array().unwrap();
        for c in all {
            let conv = unhex32(s(c, "conversation_key"), "k").unwrap();
            let e = decrypt_with(&conv, s(c, "payload")).unwrap_err();
            eprintln!("{} -> {e}", s(c, "note"));
        }
        assert!(all.len() >= 10);
    }

    #[test]
    fn events_sign_seal_and_open() {
        let (a, apub) = new_keys().unwrap();
        let (b, bpub) = new_keys().unwrap();
        let ev = seal(&a, &bpub, 1_700_000_000, r#"{"id":"1","method":"getCapabilities","params":{}}"#).unwrap();
        assert!(verify_event(&ev));
        assert_eq!(ev["kind"], 24133);
        assert_eq!(ev["tags"], json!([["p", bpub]]));
        let (from, at, text) = open(&b, &ev).unwrap();
        assert_eq!((from.as_str(), at), (apub.as_str(), 1_700_000_000));
        assert!(text.contains("getCapabilities"));
        // Not addressed to a third key; a changed content or time breaks the id.
        let (c, _) = new_keys().unwrap();
        assert!(open(&c, &ev).unwrap_err().contains("not addressed"));
        let mut bad = ev.clone();
        bad["created_at"] = json!(1_700_000_001u64);
        assert!(!verify_event(&bad));
        let mut bad = ev.clone();
        bad["content"] = json!(encrypt(&a, &bpub, "other").unwrap());
        assert!(open(&b, &bad).is_err());
        // An escape-heavy content signs and verifies (NIP-01 serialization).
        let ev = sign_event(&a, 1, 1, &json!([]), "line\nquote\" back\\ tab\t \u{1} é").unwrap();
        assert!(verify_event(&ev));
    }

    #[test]
    fn a_known_event_of_another_implementation_verifies() {
        // Signed by nostr-tools 2.25.1 (finalizeEvent), the site's library.
        let ev: Value = serde_json::from_str(include_str!("../tests/fixtures/nostr_tools_event.json")).unwrap();
        assert!(verify_event(&ev));
        // Its content, encrypted by nostr-tools to the throwaway key 0x22…22, opens here.
        let (from, _, text) = open(&"22".repeat(32), &ev).unwrap();
        assert_eq!(from, public_of(&"11".repeat(32)).unwrap());
        assert_eq!(text, r#"{"id":"x1","method":"getBalances","params":{}}"#);
    }
}
