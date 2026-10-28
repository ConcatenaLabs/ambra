//! BTC on the Bitcoin ark for the app, through [`crate::ark_btc`]. Every
//! function answers JSON as text, and fails with `{"error": {"kind": "ark",
//! "message"}}` as text.

use std::path::Path;

use anyhow::Result;
use serde_json::Value;

use crate::ark_btc;

fn fail(v: Value) -> anyhow::Error {
    anyhow::Error::msg(v.to_string())
}

fn text(r: std::result::Result<Value, Value>) -> Result<String> {
    r.map(|v| v.to_string()).map_err(fail)
}

/// Opens, or creates and recovers, the ark wallet of `mnemonic` in the app's
/// data directory `dir`, against the ark server at `server` on Bitcoin
/// `network` (`testnet4`, `signet`, `regtest`, `bitcoin`), reading the chain
/// from the esplora at `esplora`.
pub fn ark_open(dir: String, mnemonic: String, network: String, server: String, esplora: String) -> Result<String> {
    text(ark_btc::open(Path::new(&dir), &mnemonic, &network, &server, &esplora))
}

/// Closes the open ark wallet.
#[flutter_rust_bridge::frb(sync)]
pub fn ark_close() {
    ark_btc::close()
}

/// What the ark wallet holds and has on its way, in sats.
pub fn ark_balance() -> Result<String> {
    text(ark_btc::balance())
}

/// One pass of what the wallet does by itself: news from the server, Lightning
/// receives claimed, coins refreshed before they expire.
pub fn ark_sync() -> Result<String> {
    text(ark_btc::sync())
}

/// A new ark address of the wallet's.
pub fn ark_address() -> Result<String> {
    text(ark_btc::address())
}

/// What a destination is: `ark`, `lightning`, `onchain` or `none`.
#[flutter_rust_bridge::frb(sync)]
pub fn ark_kind_of(destination: String) -> String {
    ark_btc::kind_of(&destination).to_string()
}

/// Pays `sats` (none: the invoice's own amount) to `destination` out of the ark.
pub fn ark_send(destination: String, sats: Option<u64>) -> Result<String> {
    text(ark_btc::send(&destination, sats))
}

/// An invoice of `sats` paid into the ark.
pub fn ark_invoice(sats: u64, description: Option<String>) -> Result<String> {
    text(ark_btc::invoice(sats, description))
}

/// The funding address of a new board, its key index and expiry height.
pub fn ark_board_address() -> Result<String> {
    text(ark_btc::board_address())
}

/// Boards the kit's signed payment `tx_hex` to the funding address
/// [`ark_board_address`] gave.
pub fn ark_board_with(tx_hex: String, key_index: u32, expiry_height: u32) -> Result<String> {
    text(ark_btc::board_with(&tx_hex, key_index, expiry_height))
}
