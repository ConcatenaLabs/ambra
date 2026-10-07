//! Staking pools on any Sequentia chain: joining, finding, moving and leaving a
//! delegation record.
//!
//! [`crate::api`] wraps these for the app on the testnet. They take the chain
//! ([`StakeChain`]) and the explorer URL as arguments, so the same code can be
//! driven against a private chain by `tests/stake_records.rs`.
//!
//! Delegating lends this wallet's stake WEIGHT to a pool's signer. The staked
//! coins are never touched, and the pool can never spend them: its key appears
//! nowhere in the staking output's spending condition. What is lent lives in one
//! small bare output, the delegation record, which only this wallet's staking key
//! (m/2/0, the same key the stake is bonded to) can spend.
//!
//! # Joining
//!
//! The network accepts a record only from a transaction that spends a coin of
//! its controller, the staking key. The wallet's coins belong to its descriptor
//! keys, not to that key, so a join is two transactions, mined together:
//!
//! 1. an ordinary wallet payment of the record's value and its fee to the staking
//!    key's `P2WPKH` ([`add_delegation_authorization`]), reviewed and signed like
//!    any other payment;
//! 2. the record, funded by that coin and nothing else ([`join_with_signed`]),
//!    signed with the staking key. It spends the coin unconfirmed.
//!
//! If the payment went out and the record did not, the coin it left at the
//! staking key finishes the join instead of a new payment
//! ([`join_with_key_coin`]).
//!
//! # Moving and leaving
//!
//! Both spend the record, signed the way the block after the explorer's tip
//! requires ([`StakeChain::signing_after`]): the legacy signature hash below the
//! chain's `pos_records_v2_height`, the segwit-v0 one committing to the amount
//! from it. A spend signed for one side is invalid on the other, so a tip the
//! wallet cannot read is a refusal, never a guess.

use anyhow::{anyhow, Result};
use lwk_wollet::elements::confidential::Value;
use lwk_wollet::elements::hex::FromHex;
use lwk_wollet::elements::secp256k1_zkp::{PublicKey, Secp256k1, SecretKey};
use lwk_wollet::elements::{AssetId, Script, Transaction, Txid};
use lwk_wollet::sequentia_delegation::{delegation_txid_from_hex, p2wpkh_script_pubkey};
use lwk_wollet::sequentia_stake_records::find_key_coins;
use lwk_wollet::{
    build_delegation_create_tx, build_delegation_spend_tx, parse_delegation_script,
    pos_records_v2_height, sequentia_delegation_script, DelegationCreatePlan, DelegationSpendPlan,
    Network, StakeRecordSigning, TxBuilder, Wollet,
};

use crate::api::DelegationRecord;

/// The record's own value: enough to clear the dust floor and pay the fee for a
/// handful of moves between pools, since each move takes its fee out of the
/// record. All of it comes back when the delegation is reclaimed.
pub const DELEGATION_RECORD_ATOMS: u64 = 100_000; // 0.001 tSEQ

/// The fee for the transaction creating a record, in atoms, paid out of the
/// staking key's coin. Its shape is fixed (one `P2WPKH` input, the record, the
/// fee output), so this is its size at the wallet's default rate.
pub const DELEGATION_CREATE_FEE_ATOMS: u64 = 500;

/// The fee for a record spend, in atoms. The transaction's shape is fixed (one
/// bare input, one output, one fee output), so this is that size at the
/// wallet's default rate rather than a guess.
pub const DELEGATION_SPEND_FEE_ATOMS: u64 = 500;

/// Elements' default relay dust floor: refuse here rather than let the broadcast
/// fail with something the user cannot act on.
pub const DUST_FLOOR: u64 = 1_000;

/// What the wallet pays the staking key's `P2WPKH` to join: the record and the
/// fee of the transaction creating it.
pub const DELEGATION_AUTHORIZATION_ATOMS: u64 =
    DELEGATION_RECORD_ATOMS + DELEGATION_CREATE_FEE_ATOMS;

/// The chain a staking operation is for.
#[derive(Debug, Clone)]
pub struct StakeChain {
    /// The network: its Sequence token and its genesis.
    pub network: Network,
    /// The first block whose record spends carry the second-generation
    /// signature (`pos_records_v2_height`).
    pub records_v2_height: u32,
}

impl StakeChain {
    /// The Sequentia testnet, switching at the height the kit carries for it.
    pub fn testnet() -> Self {
        let network = crate::sequentia_testnet();
        let records_v2_height = pos_records_v2_height(&network);
        StakeChain {
            network,
            records_v2_height,
        }
    }

    /// The Sequence token's asset id.
    pub fn asset(&self) -> AssetId {
        *self.network.policy_asset()
    }

    /// The signature a record spend needs to enter the block after `tip`.
    ///
    /// A tip of 0 is what [`tip_height`] answers when it could not read the
    /// chain, and a record spend signed for the wrong side of the fork height is
    /// invalid, so 0 is refused rather than signed for.
    pub fn signing_after(&self, tip: u32) -> Result<StakeRecordSigning> {
        if tip == 0 {
            return Err(anyhow!(
                "could not read the chain's height, which decides how this is signed; try again"
            ));
        }
        Ok(StakeRecordSigning::for_next_block(
            tip,
            self.records_v2_height,
        ))
    }
}

/// The staking key's secret: m/2/0. It alone can spend a delegation record and
/// the coin that authorises one.
pub fn staker_secret(mnemonic: &str) -> Result<SecretKey> {
    use lwk_wollet::bitcoin::bip32::{ChildNumber, DerivationPath};
    let signer = lwk_signer::SwSigner::new(mnemonic, false).map_err(|e| anyhow!("{e:?}"))?;
    let path = DerivationPath::from(vec![
        ChildNumber::Normal { index: 2 },
        ChildNumber::Normal { index: 0 },
    ]);
    let xprv = signer.derive_xprv(&path).map_err(|e| anyhow!("{e:?}"))?;
    SecretKey::from_slice(&xprv.private_key.secret_bytes()).map_err(|e| anyhow!("{e:?}"))
}

/// The 33-byte compressed public key of `secret`.
pub fn public_bytes(secret: &SecretKey) -> Vec<u8> {
    PublicKey::from_secret_key(&Secp256k1::signing_only(), secret)
        .serialize()
        .to_vec()
}

/// Refuse a pool signer that is the staking key itself: the network refuses
/// such a record, and it would mean nothing anyway.
pub fn check_signer(controller: &[u8], signer: &[u8]) -> Result<()> {
    if controller == signer {
        return Err(anyhow!(
            "that is this wallet's own staking key; delegating to yourself is what already happens with no pool at all"
        ));
    }
    Ok(())
}

/// The first step of a join: the wallet pays the staking key's `P2WPKH` the
/// record's value and the fee of the transaction that will create it.
pub fn add_delegation_authorization(builder: TxBuilder, controller: &[u8]) -> TxBuilder {
    builder.add_record_authorization(controller, DELEGATION_AUTHORIZATION_ATOMS)
}

/// A coin of the staking key: an explicit Sequence token output at its `P2WPKH`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyCoin {
    pub txid: Txid,
    pub vout: u32,
    pub value: u64,
}

/// Build and sign the transaction creating a record for `signer` from `coin`.
/// Returns `(raw_hex, txid)`.
///
/// Whatever the coin holds beyond the record and the fee goes to `change_spk`;
/// an amount too small to relay on its own goes into the record instead, from
/// which leaving returns it.
pub fn build_delegation_create(
    chain: &StakeChain,
    coin: &KeyCoin,
    controller_secret: &SecretKey,
    signer: &[u8],
    change_spk: Script,
    tip: u32,
) -> Result<(String, Txid)> {
    let controller = public_bytes(controller_secret);
    check_signer(&controller, signer)?;
    let mut record_value = DELEGATION_RECORD_ATOMS;
    let rest = coin
        .value
        .checked_sub(DELEGATION_RECORD_ATOMS + DELEGATION_CREATE_FEE_ATOMS)
        .ok_or_else(|| {
            anyhow!(
                "the staking key's coin holds {} atoms, less than the {} a record and its fee need",
                coin.value,
                DELEGATION_AUTHORIZATION_ATOMS
            )
        })?;
    if rest > 0 && rest < DUST_FLOOR {
        record_value += rest;
    }
    build_delegation_create_tx(&DelegationCreatePlan {
        coin_txid: coin.txid,
        coin_vout: coin.vout,
        coin_value: coin.value,
        asset: chain.asset(),
        controller_secret: *controller_secret,
        signer: signer.to_vec(),
        record_value,
        change_spk,
        fee_atoms: DELEGATION_CREATE_FEE_ATOMS,
        dust_floor: DUST_FLOOR,
        locktime: tip,
    })
    .map_err(|e| anyhow!("{e:?}"))
}

/// The coin `authorization` paid the staking key for a record: exactly
/// [`DELEGATION_AUTHORIZATION_ATOMS`] of the Sequence token at its `P2WPKH`.
pub fn authorization_coin(
    chain: &StakeChain,
    authorization: &Transaction,
    controller: &[u8],
) -> Result<KeyCoin> {
    let coins = find_key_coins(authorization, controller, chain.asset());
    coins
        .into_iter()
        .find(|(_, v)| *v == DELEGATION_AUTHORIZATION_ATOMS)
        .map(|(vout, value)| KeyCoin {
            txid: authorization.txid(),
            vout,
            value,
        })
        .ok_or_else(|| anyhow!("this payment does not pay the staking key for a record"))
}

/// Finish a join: build the record from the coin the signed `authorization`
/// pays the staking key, then broadcast the payment and the record, in that
/// order. Returns the record transaction's id.
///
/// The record is built before anything is broadcast, so a join that cannot be
/// finished sends nothing. If the payment goes out and the record does not, the
/// coin waits at the staking key and [`join_with_key_coin`] finishes the join.
pub fn join_with_signed(
    chain: &StakeChain,
    esplora_url: &str,
    authorization: &Transaction,
    controller_secret: &SecretKey,
    signer: &[u8],
    change_spk: Script,
) -> Result<String> {
    let coin = authorization_coin(chain, authorization, &public_bytes(controller_secret))?;
    let (create_hex, create_id) = build_delegation_create(
        chain,
        &coin,
        controller_secret,
        signer,
        change_spk,
        tip_height(esplora_url),
    )?;
    let auth_hex = lwk_wollet::elements::encode::serialize_hex(authorization);
    broadcast(esplora_url, &auth_hex)?;
    let sent = broadcast(esplora_url, &create_hex)?;
    if sent != create_id.to_string() {
        return Err(anyhow!(
            "the explorer accepted {sent}, not the record {create_id}"
        ));
    }
    Ok(sent)
}

/// Finish a join whose record never went out: create the record from the coin
/// that join paid the staking key, exactly [`DELEGATION_AUTHORIZATION_ATOMS`]
/// at its `P2WPKH`. Returns the record transaction's id, or `None` when there
/// is no such coin and the join starts with a payment.
///
/// Other coins at that key (a split pool pays its delegators there) are left
/// alone: they are not what the user asked to spend, and a payout can still be
/// waiting out its maturity.
pub fn join_with_key_coin(
    chain: &StakeChain,
    esplora_url: &str,
    controller_secret: &SecretKey,
    signer: &[u8],
    change_spk: Script,
) -> Result<Option<String>> {
    let controller = public_bytes(controller_secret);
    check_signer(&controller, signer)?;
    let mut coins = key_coins(chain, esplora_url, &controller)?;
    coins.retain(|c| c.value == DELEGATION_AUTHORIZATION_ATOMS);
    let coin = match coins.first() {
        Some(c) => c.clone(),
        None => return Ok(None),
    };
    let (hex, _) = build_delegation_create(
        chain,
        &coin,
        controller_secret,
        signer,
        change_spk,
        tip_height(esplora_url),
    )?;
    Ok(Some(broadcast(esplora_url, &hex)?))
}

/// The unspent coins of the staking key at its `P2WPKH`, per the explorer.
pub fn key_coins(chain: &StakeChain, esplora_url: &str, controller: &[u8]) -> Result<Vec<KeyCoin>> {
    let script = p2wpkh_script_pubkey(controller);
    let list = get_json(
        esplora_url,
        &format!("scripthash/{}/utxo", scripthash(&script)),
    )?;
    let asset = chain.asset().to_string();
    let mut out = Vec::new();
    for u in list.as_array().cloned().unwrap_or_default() {
        // A blinded coin has no readable value or asset; the record could not
        // be built from it anyway.
        if u.get("asset").and_then(|a| a.as_str()) != Some(asset.as_str()) {
            continue;
        }
        let (Some(txid), Some(vout), Some(value)) = (
            u.get("txid").and_then(|v| v.as_str()),
            u.get("vout").and_then(|v| v.as_u64()),
            u.get("value").and_then(|v| v.as_u64()),
        ) else {
            continue;
        };
        out.push(KeyCoin {
            txid: delegation_txid_from_hex(txid).map_err(|e| anyhow!("{e:?}"))?,
            vout: vout as u32,
            value,
        });
    }
    Ok(out)
}

/// The records of `controller` among the wallet's own transactions: those it
/// funded from its own coins, which is how a record was created before the
/// network required a coin of the controller.
pub fn records_in_wallet_history(
    wollet: &Wollet,
    controller: &[u8],
) -> Result<Vec<(Option<u32>, DelegationRecord)>> {
    let mut found = Vec::new();
    for wtx in wollet.transactions().map_err(|e| anyhow!("{e:?}"))? {
        for (vout, out) in wtx.tx.output.iter().enumerate() {
            let Some((c, signer)) = parse_delegation_script(&out.script_pubkey) else {
                continue;
            };
            if c != controller {
                continue;
            }
            let Value::Explicit(value) = out.value else {
                continue; // a blinded record carries no readable value
            };
            found.push((
                wtx.height,
                DelegationRecord {
                    txid: wtx.txid.to_string(),
                    vout: vout as u32,
                    value,
                    signer: tohex(&signer),
                    confirmed: wtx.height.is_some(),
                },
            ));
        }
    }
    Ok(found)
}

/// The records of `controller` created from a coin of the staking key, found
/// through the history of its `P2WPKH`, newest first.
///
/// At most one record per controller is live, and a record created while
/// another is live is invalid, so only the newest such record can still be
/// unspent. The history is read a page at a time until a page holds one.
fn records_in_key_history(
    esplora_url: &str,
    controller: &[u8],
) -> Result<Vec<(Option<u32>, DelegationRecord)>> {
    const PAGE: usize = 25; // confirmed transactions per page, Esplora's own
    const MAX_PAGES: usize = 40;
    let hash = scripthash(&p2wpkh_script_pubkey(controller));
    let mut path = format!("scripthash/{hash}/txs");
    let mut found = Vec::new();
    for _ in 0..MAX_PAGES {
        let page = get_json(esplora_url, &path)?;
        let txs = page.as_array().cloned().unwrap_or_default();
        let mut last_confirmed = None;
        let mut confirmed = 0usize;
        for tx in &txs {
            let Some(txid) = tx.get("txid").and_then(|v| v.as_str()) else {
                continue;
            };
            let height = if tx.pointer("/status/confirmed").and_then(|v| v.as_bool()) == Some(true)
            {
                confirmed += 1;
                last_confirmed = Some(txid.to_string());
                tx.pointer("/status/block_height")
                    .and_then(|v| v.as_u64())
                    .map(|h| h as u32)
            } else {
                None
            };
            for (vout, out) in tx
                .get("vout")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
                .iter()
                .enumerate()
            {
                let Some(spk) = out.get("scriptpubkey").and_then(|v| v.as_str()) else {
                    continue;
                };
                let Ok(bytes) = Vec::<u8>::from_hex(spk) else {
                    continue;
                };
                let Some((c, signer)) = parse_delegation_script(&Script::from(bytes)) else {
                    continue;
                };
                let Some(value) = out.get("value").and_then(|v| v.as_u64()) else {
                    continue; // a blinded record carries no readable value
                };
                if c != controller {
                    continue;
                }
                found.push((
                    height,
                    DelegationRecord {
                        txid: txid.to_string(),
                        vout: vout as u32,
                        value,
                        signer: tohex(&signer),
                        confirmed: height.is_some(),
                    },
                ));
            }
        }
        if !found.is_empty() || confirmed < PAGE {
            break;
        }
        match last_confirmed {
            Some(last) => path = format!("scripthash/{hash}/txs/chain/{last}"),
            None => break,
        }
    }
    Ok(found)
}

/// This wallet's live delegation, or `None`.
///
/// Three ways of looking, because none alone is enough:
///
///  * `history`, the records in the wallet's own transactions
///    ([`records_in_wallet_history`]): those it funded from its own coins.
///  * the history of the staking key's `P2WPKH`: the record a join creates
///    spends the coin paid there, so nothing in that transaction is the
///    wallet's and no wallet scan downloads it.
///  * asking the explorer for unspent outputs at the record script, for each
///    signer worth trying, finds it whatever created it, including a MOVE,
///    which spends only the old record and pays only the new one, and survives
///    a restore onto a device that has never seen any of this.
///
/// `probe_signers` is what to try in the last pass: the pool board's signers,
/// plus any this device has used before. They are a HINT, never a source of
/// truth: a pool with no weight and no announced policy is not on the board at
/// all.
pub fn find_delegation_from(
    esplora_url: &str,
    controller: &[u8],
    history: Vec<(Option<u32>, DelegationRecord)>,
    probe_signers: Vec<String>,
) -> Result<Option<DelegationRecord>> {
    // (txid, vout) -> (height, record, already known unspent)
    let mut by_outpoint: std::collections::BTreeMap<
        (String, u32),
        (Option<u32>, DelegationRecord, bool),
    > = Default::default();
    for (h, rec) in history
        .into_iter()
        .chain(records_in_key_history(esplora_url, controller)?)
    {
        by_outpoint.insert((rec.txid.clone(), rec.vout), (h, rec, false));
    }

    //    `probe_signers` is tried in ORDER and the sweep stops as soon as
    //    anything is found, so the caller can put the handful of signers this
    //    device has actually used first. The ordinary case then costs one
    //    request instead of one per pool on every refresh, while a seed restored
    //    onto a device that remembers nothing still sweeps the whole board.
    let mut probed = 0usize;
    for signer_hex in probe_signers {
        // Stop on what an EARLIER PROBE found, never on the history passes:
        // they find the record this wallet created, which a later move has
        // spent, and skipping the probe would report "not delegating" for a
        // delegation that is very much alive.
        if probed > 0 {
            break;
        }
        let signer = match lwk_wollet::sequentia_delegation::delegation_pubkey_from_hex(
            &signer_hex,
            "signer",
        ) {
            Ok(s) => s,
            Err(_) => continue,
        };
        let script = sequentia_delegation_script(controller, &signer);
        let utxos = match scripthash_utxos(esplora_url, &scripthash(&script)) {
            Ok(u) => u,
            Err(_) => continue, // transient: the other signers still get their turn
        };
        for (txid, vout, value, height) in utxos {
            let rec = DelegationRecord {
                txid: txid.clone(),
                vout,
                value,
                signer: signer_hex.clone(),
                confirmed: height.is_some(),
            };
            by_outpoint.insert((txid, vout), (height, rec, true));
            probed += 1;
        }
    }

    if by_outpoint.is_empty() {
        return Ok(None);
    }
    let mut candidates: Vec<(Option<u32>, DelegationRecord, bool)> =
        by_outpoint.into_values().collect();
    // Unconfirmed first (it is the most recent thing that happened), then by
    // height descending: a move spends the old record and creates a new one, so
    // the most recent unspent record is the one in force.
    candidates.sort_by_key(|(h, _, _)| std::cmp::Reverse(h.unwrap_or(u32::MAX)));
    for (_, rec, known_unspent) in candidates {
        if known_unspent || !outpoint_is_spent(esplora_url, &rec.txid, rec.vout)? {
            return Ok(Some(rec));
        }
    }
    Ok(None)
}

/// Spend the delegation record `rec`: move to `rotate_to`, or leave (`None`),
/// paying the record's coins to `reclaim_spk`. Signed for the block after the
/// explorer's tip. Returns `(raw_hex, txid)`.
pub fn spend_delegation(
    chain: &StakeChain,
    esplora_url: &str,
    rec: &DelegationRecord,
    controller_secret: &SecretKey,
    rotate_to: Option<Vec<u8>>,
    reclaim_spk: Script,
) -> Result<(String, Txid)> {
    if !rec.confirmed {
        return Err(anyhow!(
            "the last delegation change has not confirmed yet; wait for it"
        ));
    }
    let current_signer =
        lwk_wollet::sequentia_delegation::delegation_pubkey_from_hex(&rec.signer, "current signer")
            .map_err(|e| anyhow!("{e:?}"))?;
    let tip = tip_height(esplora_url);
    let signing = chain.signing_after(tip)?;
    let plan = DelegationSpendPlan {
        record_txid: delegation_txid_from_hex(&rec.txid).map_err(|e| anyhow!("{e:?}"))?,
        record_vout: rec.vout,
        record_value: rec.value,
        asset: chain.asset(),
        current_signer,
        controller_secret: *controller_secret,
        rotate_to,
        reclaim_spk,
        fee_atoms: DELEGATION_SPEND_FEE_ATOMS,
        dust_floor: DUST_FLOOR,
        locktime: tip,
        signing,
    };
    build_delegation_spend_tx(&plan).map_err(|e| anyhow!("{e:?}"))
}

/// Broadcast a raw transaction through the explorer. Returns its txid.
pub fn broadcast(esplora_url: &str, tx_hex: &str) -> Result<String> {
    lwk_wollet::btc::xchain::blocking::seq_broadcast(esplora_url, tx_hex)
        .map_err(|e| anyhow!("{e:?}"))
}

/// The Electrum-style scripthash this explorer indexes by: the FORWARD sha256 of
/// the scriptPubKey.
///
/// Verified against the deployed esplora rather than assumed. The reversed form
/// is the more common convention and returns an empty list here, which would
/// look exactly like "you are not delegating" -- the worst possible wrong answer
/// for a feature whose whole promise is that you can always leave.
pub fn scripthash(script: &Script) -> String {
    use lwk_wollet::elements::hashes::{sha256, Hash};
    tohex(sha256::Hash::hash(script.as_bytes()).as_byte_array())
}

fn client(timeout_secs: u64) -> Result<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(timeout_secs))
        .build()
        .map_err(|e| anyhow!("{e:?}"))
}

fn get(esplora_url: &str, path: &str, timeout_secs: u64) -> Result<reqwest::blocking::Response> {
    let url = format!("{}/{}", esplora_url.trim_end_matches('/'), path);
    let mut req = client(timeout_secs)?.get(&url);
    if let Some(auth) = crate::auth_header() {
        req = req.header("Authorization", auth);
    }
    req.send().map_err(|e| anyhow!("{e:?}"))
}

fn get_json(esplora_url: &str, path: &str) -> Result<serde_json::Value> {
    let resp = get(esplora_url, path, 30)?;
    if !resp.status().is_success() {
        return Err(anyhow!("esplora /{path} returned {}", resp.status()));
    }
    resp.json().map_err(|e| anyhow!("{e:?}"))
}

/// An unspent output as the explorer lists it: (txid, vout, value, height).
type Utxo = (String, u32, u64, Option<u32>);

/// Unspent outputs at a scripthash.
fn scripthash_utxos(esplora_url: &str, scripthash: &str) -> Result<Vec<Utxo>> {
    let resp = get(esplora_url, &format!("scripthash/{scripthash}/utxo"), 30)?;
    if !resp.status().is_success() {
        return Ok(Vec::new()); // an unavailable probe is not a failed lookup
    }
    let list: serde_json::Value = resp.json().map_err(|e| anyhow!("{e:?}"))?;
    let mut out = Vec::new();
    for u in list.as_array().cloned().unwrap_or_default() {
        let txid = match u.get("txid").and_then(|v| v.as_str()) {
            Some(t) => t.to_string(),
            None => continue,
        };
        let vout = match u.get("vout").and_then(|v| v.as_u64()) {
            Some(v) => v as u32,
            None => continue,
        };
        let value = u.get("value").and_then(|v| v.as_u64()).unwrap_or(0);
        let confirmed = u
            .pointer("/status/confirmed")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let height = if confirmed {
            u.pointer("/status/block_height")
                .and_then(|v| v.as_u64())
                .map(|h| h as u32)
        } else {
            None
        };
        out.push((txid, vout, value, height));
    }
    Ok(out)
}

/// Whether an outpoint has been spent, per the explorer.
fn outpoint_is_spent(esplora_url: &str, txid: &str, vout: u32) -> Result<bool> {
    let v = get_json(esplora_url, &format!("tx/{txid}/outspend/{vout}"))?;
    Ok(v.get("spent").and_then(|s| s.as_bool()).unwrap_or(false))
}

/// The explorer's chain tip, or 0 when it cannot be read. 0 is a valid
/// nLockTime, but it says nothing about which side of the record fork height
/// the next block is on, so [`StakeChain::signing_after`] refuses it.
pub fn tip_height(esplora_url: &str) -> u32 {
    match get(esplora_url, "blocks/tip/height", 15)
        .ok()
        .and_then(|r| r.text().ok())
    {
        Some(t) => t.trim().parse().unwrap_or(0),
        None => 0,
    }
}

fn tohex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use lwk_wollet::elements::hashes::Hash as _;

    #[test]
    fn testnet_signing_is_the_kits_for_network() {
        let chain = StakeChain::testnet();
        assert_eq!(chain.records_v2_height, 163_000);
        for tip in [1, 162_998, 162_999, 163_000, 200_000] {
            assert_eq!(
                chain.signing_after(tip).unwrap(),
                StakeRecordSigning::for_network(&crate::sequentia_testnet(), tip),
                "tip {tip}"
            );
        }
        assert_eq!(
            chain.signing_after(162_998).unwrap(),
            StakeRecordSigning::Legacy
        );
        assert_eq!(
            chain.signing_after(162_999).unwrap(),
            StakeRecordSigning::SegwitV0
        );
    }

    #[test]
    fn an_unread_tip_is_refused() {
        let e = StakeChain::testnet()
            .signing_after(0)
            .unwrap_err()
            .to_string();
        assert!(e.contains("could not read the chain's height"), "{e}");
    }

    #[test]
    fn a_record_for_the_staking_key_itself_is_refused() {
        let sk = SecretKey::from_slice(&[7u8; 32]).unwrap();
        let me = public_bytes(&sk);
        let coin = KeyCoin {
            txid: Txid::all_zeros(),
            vout: 0,
            value: DELEGATION_AUTHORIZATION_ATOMS,
        };
        let e = build_delegation_create(&StakeChain::testnet(), &coin, &sk, &me, Script::new(), 5)
            .unwrap_err()
            .to_string();
        assert!(e.contains("own staking key"), "{e}");
    }

    #[test]
    fn a_coin_too_small_for_a_record_is_refused() {
        let sk = SecretKey::from_slice(&[7u8; 32]).unwrap();
        let pool = public_bytes(&SecretKey::from_slice(&[8u8; 32]).unwrap());
        let coin = KeyCoin {
            txid: Txid::all_zeros(),
            vout: 0,
            value: DELEGATION_AUTHORIZATION_ATOMS - 1,
        };
        let e =
            build_delegation_create(&StakeChain::testnet(), &coin, &sk, &pool, Script::new(), 5)
                .unwrap_err()
                .to_string();
        assert!(e.contains("less than the 100500"), "{e}");
    }
}
