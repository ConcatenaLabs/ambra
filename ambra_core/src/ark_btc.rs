//! BTC on the Bitcoin ark: Second's Bark client (`bark::Wallet`, from the
//! arca repository's `arca-wallet` crate) against an ark server on Bitcoin
//! (testnet4 here), from the same recovery phrase as the rest of the wallet.
//! BTC stays native bitcoin: the ark holds it in Bitcoin transactions the
//! holder can always take on the chain.
//!
//! One wallet is open at a time, driven on a runtime of its own. Every call
//! answers JSON as text, and fails with `{"error": {"kind": "ark", "message"}}`.
//!
//! Boarding spends the kit's own BTC: the kit builds and signs an ordinary
//! payment from the shared address to the board's funding address
//! ([`bark::Wallet::board_funding_address`]), and Bark takes it as a finished
//! PSBT ([`bark::Wallet::board_psbt`]), so a board is one transaction and the
//! wallet keeps no second on-chain wallet.

use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Mutex, OnceLock};

use bark::ark::bitcoin::{self, consensus, Address, Amount, Network};
use bark::actions::lightning::pay::LightningSendState;
use bark::actions::lightning::receive::LightningReceiveState;
use bark::ark::lightning::{Invoice, PaymentHash};
use bark::ark::Address as ArkAddress;
use bark::bip39;
use bark::{Config, OpenWalletArgs, Wallet, WalletSeed};
use serde_json::{json, Value};

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("a runtime")
    })
}

static WALLET: Mutex<Option<std::sync::Arc<Wallet>>> = Mutex::new(None);

/// A refusal as the app reads it.
pub fn refusal(msg: impl std::fmt::Display) -> Value {
    json!({"error": {"kind": "ark", "message": format!("{:#}", msg)}})
}

fn err(e: anyhow::Error) -> Value {
    refusal(e)
}

fn wallet() -> Result<std::sync::Arc<Wallet>, Value> {
    WALLET.lock().expect("lock").clone().ok_or_else(|| refusal("the Bitcoin wallet is not open"))
}

/// The directory of the ark wallet of `mnemonic` under the app's `dir`: one per
/// recovery phrase, named by its fingerprint, so two phrases never share a store.
pub fn datadir(dir: &Path, network: Network, mnemonic: &bip39::Mnemonic) -> PathBuf {
    let fp = WalletSeed::new_from_mnemonic(network, mnemonic).fingerprint();
    dir.join(format!("ark-{}", fp))
}

fn network(name: &str) -> Result<Network, Value> {
    match name {
        "testnet4" => Ok(Network::Testnet4),
        "signet" => Ok(Network::Signet),
        "regtest" => Ok(Network::Regtest),
        "bitcoin" | "mainnet" => Ok(Network::Bitcoin),
        o => Err(refusal(format!("unknown Bitcoin network {:?}", o))),
    }
}

/// Opens (creating when there is none, and then recovering what the server
/// holds for this phrase) the ark wallet of `mnemonic` against the server at
/// `server` with the chain read from the esplora at `esplora`. A wallet open
/// already for the same phrase is kept. The answer is `{"fingerprint",
/// "server_pubkey", "network"}`.
pub fn open(dir: &Path, mnemonic: &str, net: &str, server: &str, esplora: &str) -> Result<Value, Value> {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default().with_max_level(log::LevelFilter::Info).with_tag("bark"),
    );
    let network = network(net)?;
    let m = bip39::Mnemonic::from_str(mnemonic.trim()).map_err(|e| refusal(format!("the recovery phrase: {}", e)))?;
    let seed = WalletSeed::new_from_mnemonic(network, &m);
    if let Some(w) = WALLET.lock().expect("lock").clone() {
        if w.fingerprint() == seed.fingerprint() {
            return Ok(json!({"fingerprint": w.fingerprint().to_string(), "network": net, "kept": true}));
        }
    }
    let dd = datadir(dir, network, &m);
    let mut config = Config::network_default(network);
    config.server_address = server.to_string();
    config.esplora_address = Some(esplora.to_string());
    config.bitcoind_address = None;
    let w = runtime()
        .block_on(Wallet::open(
            network,
            seed,
            config,
            OpenWalletArgs {
                datadir: Some(dd),
                create_if_not_exists: true,
                run_daemon: false,
                ..Default::default()
            },
        ))
        .map_err(err)?;
    let props = runtime().block_on(w.properties()).map_err(err)?;
    let out = json!({
        "fingerprint": props.fingerprint.to_string(),
        "network": net,
        "server_pubkey": props.server_pubkey.map(|k| k.to_string()),
    });
    *WALLET.lock().expect("lock") = Some(std::sync::Arc::new(w));
    Ok(out)
}

/// Closes the open wallet.
pub fn close() {
    WALLET.lock().expect("lock").take();
}

fn sats(a: Amount) -> String {
    a.to_sat().to_string()
}

/// What the wallet holds, in sats: `spendable` (in the ark now), and what is on
/// its way (`pending_board`, `pending_in_round`, `claimable_lightning_receive`)
/// or leaving (`pending_lightning_send`, `pending_exit`); and how many boards are
/// still in progress (`boards_in_progress`, those not yet broadcast included).
pub fn balance() -> Result<Value, Value> {
    let w = wallet()?;
    let b = runtime().block_on(w.balance()).map_err(err)?;
    let boards = runtime().block_on(w.pending_boards()).map(|v| v.len()).unwrap_or(0);
    Ok(json!({
        "boards_in_progress": boards,
        "spendable": sats(b.spendable),
        "pending_board": sats(b.pending_board),
        "pending_in_round": sats(b.pending_in_round),
        "claimable_lightning_receive": sats(b.claimable_lightning_receive),
        "pending_lightning_send": sats(b.pending_lightning_send),
        "pending_exit": b.pending_exit.map(sats),
    }))
}

/// One pass of what the wallet does by itself: the server's news (payments
/// received, boards confirmed, rounds), every pending Lightning receive driven
/// on, and the maintenance that refreshes coins close to their expiry.
pub fn sync() -> Result<Value, Value> {
    let w = wallet()?;
    runtime().block_on(async {
        w.sync().await;
        let claimed = w.try_claim_all_lightning_receives(false).await.map(|v| v.len()).unwrap_or(0);
        let maintained = w.maintenance().await.map(|_| true).unwrap_or(false);
        Ok(json!({"lightning_receives": claimed, "maintained": maintained}))
    })
}

/// Brings the store up to date with what other wallets of the same phrase did
/// since it was made: coins they boarded or received, read from the server's
/// recovery mailbox and imported when the store lacks them, and coins they
/// spent, marked spent. [`open`] recovers only when it creates the store, so a
/// second device, or a store kept across a remove and an import, learns of them
/// only here. The native twin of bark-wasm's `catch_up`: `{"recovered",
/// "recovered_sat", "spent_elsewhere", "failed", "complete"}`.
pub fn catch_up() -> Result<Value, Value> {
    let w = wallet()?;
    let r = runtime().block_on(w.catch_up_from_server()).map_err(err)?;
    Ok(json!({
        "recovered": r.recovery.recovered().ids().map(|i| i.to_string()).collect::<Vec<_>>(),
        "recovered_sat": sats(r.recovery.recovered().total_amount()),
        "spent_elsewhere": r.spent_elsewhere.iter().map(|i| i.to_string()).collect::<Vec<_>>(),
        "failed": r.recovery.failed().ids().map(|i| i.to_string()).collect::<Vec<_>>(),
        "complete": r.recovery.is_complete(),
    }))
}

/// A new ark address of the wallet's: what another wallet of the same ark pays
/// in seconds.
pub fn address() -> Result<Value, Value> {
    let w = wallet()?;
    let a = runtime().block_on(w.new_address()).map_err(err)?;
    Ok(json!({"address": a.to_string()}))
}

/// What `destination` is, as the wallet would pay it: `ark` (an address of an
/// ark), `lightning` (a BOLT11 invoice) or `onchain` (a Bitcoin address), or
/// `none`.
pub fn kind_of(destination: &str) -> &'static str {
    let d = destination.trim();
    if ArkAddress::from_str(d).is_ok() {
        "ark"
    } else if bark::lightning_invoice::Bolt11Invoice::from_str(d).is_ok() {
        "lightning"
    } else if Address::from_str(d).is_ok() {
        "onchain"
    } else {
        "none"
    }
}

/// Pays `sats` to `destination` out of the ark: an ark address in the ark
/// (seconds), an invoice over Lightning (its own amount unless it names
/// none), a Bitcoin address on the chain (after a Bitcoin block). The answer
/// is `{"kind", "txid"?}`.
pub fn send(destination: &str, sats_amount: Option<u64>) -> Result<Value, Value> {
    let w = wallet()?;
    let d = destination.trim();
    let amount = sats_amount.map(Amount::from_sat);
    match kind_of(d) {
        "ark" => {
            let a = ArkAddress::from_str(d).map_err(|e| refusal(format!("the address: {}", e)))?;
            let amount = amount.ok_or_else(|| refusal("the amount is missing"))?;
            runtime().block_on(w.send_arkoor_payment(&a, amount)).map_err(err)?;
            Ok(json!({"kind": "ark"}))
        },
        "lightning" => {
            let inv = bark::lightning_invoice::Bolt11Invoice::from_str(d).map_err(|e| refusal(format!("the invoice: {}", e)))?;
            runtime().block_on(w.pay_lightning_invoice(inv, amount, true)).map_err(err)?;
            Ok(json!({"kind": "lightning"}))
        },
        "onchain" => {
            let a = Address::from_str(d)
                .map_err(|e| refusal(format!("the address: {}", e)))?
                .require_network(runtime().block_on(w.network()).map_err(err)?)
                .map_err(|e| refusal(format!("the address: {}", e)))?;
            let amount = amount.ok_or_else(|| refusal("the amount is missing"))?;
            let txid = runtime().block_on(w.send_onchain(a, amount)).map_err(err)?;
            Ok(json!({"kind": "onchain", "txid": txid.to_string()}))
        },
        _ => Err(refusal("not an ark address, an invoice or a Bitcoin address")),
    }
}

/// An invoice of `sats` paid into the ark: claimed by [`sync`] while the app
/// runs, or at once by [`receive_status`] with `claim`. The answer is
/// `{"invoice", "payment_hash", "expires_at"}`.
pub fn invoice(sats_amount: u64, description: Option<String>) -> Result<Value, Value> {
    let w = wallet()?;
    let inv = runtime()
        .block_on(w.bolt11_invoice(Amount::from_sat(sats_amount), description, None))
        .map_err(err)?;
    let expires_at = inv.duration_since_epoch().as_secs() + inv.expiry_time().as_secs();
    Ok(json!({
        "invoice": inv.to_string(),
        "payment_hash": PaymentHash::from(&inv).to_string(),
        "expires_at": expires_at,
    }))
}

// The calls below are the ones the trade composer makes of a Bitcoin Lightning
// wallet, answered by the ark. They are the native twins of the commands of
// the same names in arca's `bark-wasm/src/command.rs`, which the web wallet's
// ark runs: change them together.

/// The longest lock, in blocks, a Lightning payment out of the ark can take:
/// the server pays with at most its HTLC-send delta less its own margin.
fn max_route_delay(info: &bark::ark::ArkInfo) -> u32 {
    (info.htlc_send_expiry_delta as u32).saturating_sub(info.htlc_expiry_delta as u32)
}

fn send_state(st: LightningSendState) -> Value {
    match st {
        LightningSendState::Paid(p) => json!({"state": "complete", "preimage": p.preimage.to_string()}),
        LightningSendState::InProgress(s) => json!({"state": "pending", "fee": sats(s.fee), "amount": sats(s.payment_amount)}),
        LightningSendState::Unknown => json!({"state": "none"}),
    }
}

fn receive_state(st: LightningReceiveState) -> Value {
    match st {
        LightningReceiveState::Settled(r) => json!({"state": "paid", "preimage": r.preimage.to_string(), "amount": sats(r.amount)}),
        LightningReceiveState::InProgress(r) => json!({"state": "waiting", "invoice": r.invoice.to_string()}),
    }
}

fn payment_hash(hash: &str) -> Result<PaymentHash, Value> {
    PaymentHash::from_str(hash.trim()).map_err(|_| refusal("not a payment hash"))
}

/// What paying `sats` over Lightning out of the ark costs now, and the longest
/// lock the server's payment may take: `{"fee", "gross", "max_route_delay"}`.
pub fn pay_fee(sats_amount: u64) -> Result<Value, Value> {
    let w = wallet()?;
    runtime().block_on(async {
        let info = w.require_ark_info().await.map_err(err)?;
        let e = w.estimate_lightning_send_fee(Amount::from_sat(sats_amount)).await.map_err(err)?;
        Ok(json!({"fee": sats(e.fee), "gross": sats(e.gross_amount), "max_route_delay": max_route_delay(&info)}))
    })
}

/// Pays the invoice out of the ark, refused before anything moves when its fee
/// would be more than `max_fee_sats` or the route's lock could run past
/// `max_delay` blocks. A payment already made under the invoice's hash is
/// never made again: its state is the answer. The answer is
/// `{"state": "complete", "preimage"} | {"state": "pending"} | {"state":
/// "failed", "reason"}`.
pub fn pay(invoice: &str, max_fee_sats: Option<u64>, max_delay: Option<u32>, wait: bool) -> Result<Value, Value> {
    let w = wallet()?;
    let inv = bark::lightning_invoice::Bolt11Invoice::from_str(invoice.trim())
        .map_err(|e| refusal(format!("the invoice does not decode: {}", e)))?;
    let hash = PaymentHash::from(&inv);
    runtime().block_on(async {
        match w.lightning_send_state(hash).await.map_err(err)? {
            LightningSendState::Unknown => {},
            st => return Ok(send_state(st)),
        }
        let msat = inv.amount_milli_satoshis().ok_or_else(|| refusal("the invoice names no amount"))?;
        let amount = Amount::from_sat(msat.div_ceil(1000));
        let info = w.require_ark_info().await.map_err(err)?;
        if let Some(max) = max_delay {
            if max_route_delay(&info) > max {
                return Err(refusal(format!(
                    "refused: a payment from the ark may lock for {} blocks, more than the {} allowed",
                    max_route_delay(&info),
                    max
                )));
            }
        }
        let fee = w.estimate_lightning_send_fee(amount).await.map_err(err)?.fee;
        if let Some(max) = max_fee_sats {
            if fee > Amount::from_sat(max) {
                return Err(refusal(format!(
                    "refused: the payment's fee of {} sat is more than the {} allowed",
                    fee.to_sat(),
                    max
                )));
            }
        }
        match w.pay_lightning_invoice(Invoice::Bolt11(inv), None, wait).await {
            Ok(_) => Ok(send_state(w.lightning_send_state(hash).await.map_err(err)?)),
            Err(e) => match w.lightning_send_state(hash).await.map_err(err)? {
                LightningSendState::Unknown => Ok(json!({"state": "failed", "reason": format!("{:#}", e)})),
                st => Ok(send_state(st)),
            },
        }
    })
}

/// A payment's state under `hash`; with `drive`, the wallet first asks the
/// server how it stands. `{"state": "none" | "pending" | "complete",
/// "preimage"?}`.
pub fn pay_status(hash: &str, drive: bool) -> Result<Value, Value> {
    let w = wallet()?;
    let h = payment_hash(hash)?;
    runtime().block_on(async {
        let st = if drive {
            w.check_lightning_payment(h, false).await.map_err(err)?
        } else {
            w.lightning_send_state(h).await.map_err(err)?
        };
        Ok(send_state(st))
    })
}

/// A receive's state under `hash`; with `claim`, the wallet first claims a
/// payment the server holds for it. `{"state": "paid", "preimage", "amount"} |
/// {"state": "waiting"} | {"state": "unknown", "reason"}` (unknown: never made
/// here, or given up).
pub fn receive_status(hash: &str, claim: bool) -> Result<Value, Value> {
    let w = wallet()?;
    let h = payment_hash(hash)?;
    runtime().block_on(async {
        let st = if claim { w.try_claim_lightning_receive(h, false).await } else { w.lightning_receive_state(h).await };
        Ok(st.map(receive_state).unwrap_or_else(|e| json!({"state": "unknown", "reason": format!("{:#}", e)})))
    })
}

/// The funding address of a new board and the key and height it is made for:
/// the kit pays it from the shared address, then [`board_with`] boards it.
pub fn board_address() -> Result<Value, Value> {
    let w = wallet()?;
    runtime().block_on(async {
        let (kp, idx) = w.derive_store_next_keypair().await.map_err(err)?;
        let (addr, expiry) = w.board_funding_address(&kp).await.map_err(err)?;
        Ok(json!({"address": addr.to_string(), "key_index": idx, "expiry_height": expiry}))
    })
}

/// Boards the signed transaction `tx_hex` (the kit's payment to the funding
/// address [`board_address`] gave for `key_index` and `expiry_height`): Bark
/// broadcasts it and registers the board with the server.
pub fn board_with(tx_hex: &str, key_index: u32, expiry_height: u32) -> Result<Value, Value> {
    let w = wallet()?;
    let bytes = hex_decode(tx_hex)?;
    let tx: bitcoin::Transaction = consensus::deserialize(&bytes).map_err(|e| refusal(format!("the transaction: {}", e)))?;
    let mut unsigned = tx.clone();
    for i in unsigned.input.iter_mut() {
        i.witness = bitcoin::Witness::new();
        i.script_sig = bitcoin::ScriptBuf::new();
    }
    let mut psbt = bitcoin::Psbt::from_unsigned_tx(unsigned).map_err(|e| refusal(format!("the transaction: {}", e)))?;
    for (p, i) in psbt.inputs.iter_mut().zip(tx.input.iter()) {
        p.final_script_witness = Some(i.witness.clone());
    }
    runtime().block_on(async {
        // Bark checks every input's amount: each spent output, read from the chain.
        for (p, i) in psbt.inputs.iter_mut().zip(tx.input.iter()) {
            let prev = w.chain().get_tx(&i.previous_output.txid).await.map_err(err)?
                .ok_or_else(|| refusal(format!("the coin {} is not on the chain", i.previous_output)))?;
            let out = prev.output.get(i.previous_output.vout as usize).cloned()
                .ok_or_else(|| refusal(format!("the coin {} is not in its transaction", i.previous_output)))?;
            p.witness_utxo = Some(out);
        }
        let kp = w.peek_keypair(key_index).await.map_err(err)?;
        let b = w.board_psbt(psbt, kp, expiry_height as _).await.map_err(err)?;
        // The transaction is signed and final: put it on the network now rather than
        // leave it to Bark's own push, which waits silently when the chain source
        // answers anything but a clean acceptance. A transaction already there is no harm.
        let pushed = match w.chain().broadcast_tx(&tx).await {
            Ok(()) => Value::Null,
            Err(e) => json!(format!("{:#}", e)),
        };
        w.sync().await;
        Ok(json!({"amount": sats(b.amount), "funding_txid": b.funding_tx.compute_txid().to_string(), "broadcast_error": pushed}))
    })
}

fn hex_decode(s: &str) -> Result<Vec<u8>, Value> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return Err(refusal("the transaction: odd hex"));
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| refusal(format!("the transaction: {}", e))))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds() {
        assert_eq!(kind_of("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"), "onchain");
        assert_eq!(kind_of("hello"), "none");
        assert_eq!(kind_of(""), "none");
    }

    /// Against a live ark: `ARK_SMOKE_SERVER`, `ARK_SMOKE_ESPLORA`, and a fresh
    /// phrase. Opens (creates) the wallet, reads its balance, draws an ark
    /// address, an invoice and a board address. Skipped without the variables.
    #[test]
    fn live_smoke() {
        let (Ok(server), Ok(esplora)) = (std::env::var("ARK_SMOKE_SERVER"), std::env::var("ARK_SMOKE_ESPLORA")) else {
            return;
        };
        let dir = std::env::var("ARK_SMOKE_DIR").expect("ARK_SMOKE_DIR");
        let phrase = std::env::var("ARK_SMOKE_PHRASE")
            .unwrap_or_else(|_| bip39::Mnemonic::generate(12).expect("12 words").to_string());
        let t = std::time::Instant::now();
        let o = open(Path::new(&dir), &phrase, "testnet4", &server, &esplora).expect("open");
        println!("open {:?} in {:?}", o, t.elapsed());
        println!("balance {}", balance().expect("balance"));
        let a = address().expect("address");
        println!("address {}", a);
        assert_eq!(kind_of(a["address"].as_str().unwrap()), "ark");
        let t = std::time::Instant::now();
        println!("sync {} in {:?}", sync().expect("sync"), t.elapsed());
        let t = std::time::Instant::now();
        println!("catch up {} in {:?}", catch_up().expect("catch up"), t.elapsed());
        println!("balance {}", balance().expect("balance"));
        match invoice(20_000, Some("smoke".into())) {
            Ok(i) => {
                println!("invoice {}", i);
                assert_eq!(kind_of(i["invoice"].as_str().unwrap()), "lightning");
                let h = i["payment_hash"].as_str().unwrap();
                println!("receive status {}", receive_status(h, true).expect("receive status"));
                // The wallet's own invoice, paid from an empty ark: refused before anything moves.
                println!("pay own invoice {:?}", pay(i["invoice"].as_str().unwrap(), Some(0), Some(66), false));
                println!("pay status {}", pay_status(h, false).expect("pay status"));
            },
            Err(e) => println!("invoice refused {}", e),
        }
        println!("pay fee {}", pay_fee(20_000).expect("pay fee"));
        println!("board address {}", board_address().expect("board address"));
        close();
    }

    #[test]
    fn hex() {
        assert_eq!(hex_decode("00ff10").unwrap(), vec![0, 255, 16]);
        assert!(hex_decode("abc").is_err());
    }
}
