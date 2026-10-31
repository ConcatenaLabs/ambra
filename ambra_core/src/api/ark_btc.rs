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

/// An invoice of `sats` paid into the ark: `{invoice, payment_hash, expires_at}`.
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

/// The fee of paying `sats` over Lightning out of the ark, and the longest lock
/// the payment may take in blocks: `{fee, gross, max_route_delay}`.
pub fn ark_pay_fee(sats: u64) -> Result<String> {
    text(ark_btc::pay_fee(sats))
}

/// Pays `invoice` out of the ark, refused when its fee would pass `max_fee_sats`
/// or its lock `max_delay` blocks; a payment already made under the invoice's
/// hash is not made again. `{state: complete|pending|failed, preimage?, reason?}`.
pub fn ark_pay(invoice: String, max_fee_sats: Option<u64>, max_delay: Option<u32>, wait: bool) -> Result<String> {
    text(ark_btc::pay(&invoice, max_fee_sats, max_delay, wait))
}

/// A payment's state under `hash` (`drive`: asked of the server first):
/// `{state: none|pending|complete, preimage?}`.
pub fn ark_pay_status(hash: String, drive: bool) -> Result<String> {
    text(ark_btc::pay_status(&hash, drive))
}

/// A receive's state under `hash` (`claim`: a held payment claimed first):
/// `{state: paid|waiting|unknown, preimage?, amount?}`.
pub fn ark_receive_status(hash: String, claim: bool) -> Result<String> {
    text(ark_btc::receive_status(&hash, claim))
}

/// Brings the ark wallet's store up to date with what other wallets of the same
/// phrase did (coins they boarded, received or spent): `{recovered,
/// recovered_sat, spent_elsewhere, failed, complete}`.
pub fn ark_catch_up() -> Result<String> {
    text(ark_btc::catch_up())
}

/// The wallet's movements, newest first, at most `limit`: what History lists of the ark.
pub fn ark_history(limit: u32) -> Result<String> {
    text(ark_btc::history(limit as usize))
}
