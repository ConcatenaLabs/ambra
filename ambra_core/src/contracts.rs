//! Contract spends under the five-point rule, through the kit's contract engine
//! (SWK's `lwk_contracts`).
//!
//! A spend is asked for as `{templateHash, instance, request | drip, fund?}`, the
//! shape a site hands the browser extension's `signContractSpend`. The engine does
//! every check: the template is on the wallet's list (the kit's templates), it
//! recomputes the output and every contract an output opens, it runs every program
//! against the final transaction, and it signs only with a contract key the path
//! names, or none on a path that takes no signature, the wallet's funding keys
//! signing only its own coins. This module only gathers what the engine needs: the
//! wallet's own record of its coins (from its own sync), its scripts, and the
//! chain's record of the contract coin and of every foreign coin, which it reads
//! from its own explorer. With `fund`, it adds the wallet's own explicit coins for
//! what the request's inputs do not cover, and the change.
//!
//! [`prepare`] returns the engine's approval with the summary the screen shows; it
//! is signed only through [`sign_and_broadcast`] with the digest of the summary
//! that was shown.

use std::collections::BTreeMap;
use std::str::FromStr;
use std::sync::Arc;

use lwk_contracts::approval::{Approval, AssetLabel, WalletView};
use lwk_contracts::spend::{
    default_contract_key_path, Chain, ChainFacts, CoinRequest, InputRequest, OutputRequest,
    Prevout, Spend, SpendRequest, WalletCoin,
};
use lwk_contracts::{drip, known, Contract, Instance};
use lwk_signer::SwSigner;
use lwk_wollet::elements::encode::serialize_hex;
use lwk_wollet::elements::{BlockHash, Script};
use lwk_wollet::{Network, Wollet};
use serde::Deserialize;
use serde_json::Value;

/// The chain a spend is for: the engine's view of it and the wallet's network.
#[derive(Clone)]
pub struct ContractChain {
    pub chain: Chain,
    pub network: Network,
}

impl ContractChain {
    /// The chain of a wallet network.
    pub fn for_network(network: Network) -> Self {
        let genesis: BlockHash = network.genesis_hash();
        ContractChain {
            chain: Chain {
                genesis,
                mainnet: network.is_mainnet(),
            },
            network,
        }
    }

    /// The Sequentia testnet, which the app runs on.
    pub fn testnet() -> Self {
        Self::for_network(crate::sequentia_testnet())
    }
}

/// A drip of the faucet drip covenant, planned by the wallet at its real size.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DripAsk {
    pub coin: CoinRequest,
    /// Atoms of the dripped asset, as a number or a decimal string.
    pub amount: Value,
    /// The address paid; this wallet's receive address by default.
    #[serde(default)]
    pub to: Option<String>,
    /// Atoms of the dripped asset per 1,000 vB; 1,000 by default. The app always names it: the
    /// reference rate at the node's rate for the asset (`app/lib/src/data/drip_rate.dart`).
    #[serde(default)]
    pub rate_per_kvb: Option<u64>,
}

/// What is asked: the shape of the extension's `signContractSpend`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Ask {
    pub template_hash: String,
    pub instance: Value,
    #[serde(default)]
    pub request: Option<SpendRequest>,
    #[serde(default)]
    pub drip: Option<DripAsk>,
    #[serde(default)]
    pub fund: bool,
}

/// A spend the engine checked, with the summary to show.
pub struct Prepared {
    pub approval: Approval,
    pub summary: Value,
    pub request: SpendRequest,
}

/// The templates the wallet signs for: the kit's.
pub fn known_templates() -> Vec<String> {
    lwk_contracts::KNOWN
        .iter()
        .map(|k| k.hash.to_string())
        .collect()
}

fn get(url: &str) -> Result<String, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let mut req = client.get(url);
    if let Some(h) = crate::auth_header() {
        req = req.header("Authorization", h);
    }
    let r = req.send().map_err(|e| format!("{url}: {e}"))?;
    let status = r.status();
    let text = r.text().map_err(|e| format!("{url}: {e}"))?;
    if !status.is_success() {
        return Err(format!("{url}: {status}: {text}"));
    }
    Ok(text.trim().to_string())
}

fn get_json(url: &str) -> Result<Value, String> {
    serde_json::from_str(&get(url)?).map_err(|e| format!("{url}: {e}"))
}

/// The chain's record of an output, from the wallet's own explorer: its script,
/// asset and amount, explicit.
pub fn prevout_of(esplora: &str, txid: &str, vout: u32) -> Result<Prevout, String> {
    let t = get_json(&format!("{esplora}/tx/{txid}"))?;
    let o = &t["vout"][vout as usize];
    match (o["scriptpubkey"].as_str(), o["asset"].as_str(), o["value"].as_u64()) {
        (Some(s), Some(a), Some(v)) => Ok(Prevout {
            script_pubkey: s.to_string(),
            asset: a.to_string(),
            amount: v,
        }),
        _ => Err(format!(
            "{txid}:{vout} is not an explicit output on the chain"
        )),
    }
}

/// What the engine needs to check the spend's locks, and the chain's record of
/// every coin in `records` (`txid`, `vout`).
pub fn chain_facts(
    esplora: &str,
    coin_txid: &str,
    records: &[(String, u32)],
) -> Result<ChainFacts, String> {
    let tip_hash = get(&format!("{esplora}/blocks/tip/hash"))?;
    let tip = get_json(&format!("{esplora}/block/{tip_hash}"))?;
    let status = get_json(&format!("{esplora}/tx/{coin_txid}/status"))?;
    let mut facts = ChainFacts {
        tip_height: tip["height"].as_u64().ok_or("the tip has no height")?,
        tip_median_time: tip["mediantime"].as_u64().ok_or("the tip has no median time")?,
        coin_height: None,
        coin_start_median_time: None,
        prevouts: BTreeMap::new(),
    };
    if status["confirmed"].as_bool() == Some(true) {
        let h = status["block_height"].as_u64().ok_or("no block height")?;
        facts.coin_height = Some(h);
        let before = get(&format!("{esplora}/block-height/{}", h.saturating_sub(1)))?;
        facts.coin_start_median_time =
            get_json(&format!("{esplora}/block/{before}"))?["mediantime"].as_u64();
    }
    for (t, v) in records {
        facts
            .prevouts
            .insert(format!("{t}:{v}"), prevout_of(esplora, t, *v)?);
    }
    Ok(facts)
}

/// The wallet's scripts: every address it has handed out or will next, both chains.
pub fn wallet_scripts(wollet: &Wollet, coins: &[WalletCoin]) -> Result<Vec<Script>, String> {
    let next = wollet
        .address(None)
        .map_err(|e| format!("{e:?}"))?
        .index();
    let mut out = Vec::new();
    for i in 0..=next + 1 {
        if let Ok(a) = wollet.address(Some(i)) {
            out.push(a.address().to_unconfidential().script_pubkey());
        }
        if let Ok(a) = wollet.change(Some(i)) {
            out.push(a.address().to_unconfidential().script_pubkey());
        }
    }
    for c in coins {
        if let Ok(s) = lwk_contracts::spend::script_from_hex(&c.script_pubkey) {
            if !out.contains(&s) {
                out.push(s);
            }
        }
    }
    Ok(out)
}

/// `request` with this wallet's own explicit coins added where the outputs pay
/// more of an asset than the inputs hold, largest first, and the change of each
/// to `change_address`. A coin the request already names is not picked twice.
pub fn fund_from_wallet(
    request: &SpendRequest,
    coins: &[WalletCoin],
    change_address: &str,
) -> Result<SpendRequest, String> {
    let mut r = request.clone();
    let mut inputs = r.inputs.clone().unwrap_or_else(|| vec![InputRequest::Contract]);
    let mut used: Vec<(String, u32)> = inputs
        .iter()
        .filter_map(|i| match i {
            InputRequest::Wallet { txid, vout, .. } | InputRequest::Foreign { txid, vout, .. } => {
                Some((txid.clone(), *vout))
            }
            // Another coin of the contract's template: never one of the wallet's to pick.
            InputRequest::Sibling { coin, .. } => Some((coin.txid.clone(), coin.vout)),
            InputRequest::Contract => None,
        })
        .collect();
    let mut have: BTreeMap<String, u128> = BTreeMap::new();
    *have.entry(r.coin.asset.clone()).or_default() += u128::from(r.coin.amount);
    for i in &inputs {
        match i {
            InputRequest::Wallet { asset, amount, .. } | InputRequest::Foreign { asset, amount, .. } => {
                *have.entry(asset.clone()).or_default() += u128::from(*amount)
            }
            InputRequest::Sibling { coin, .. } => {
                *have.entry(coin.asset.clone()).or_default() += u128::from(coin.amount)
            }
            InputRequest::Contract => {}
        }
    }
    let mut need: BTreeMap<String, u128> = BTreeMap::new();
    for o in &r.outputs {
        *need.entry(o.asset.clone()).or_default() += u128::from(o.amount);
    }
    for (asset, n) in need {
        let h = have.get(&asset).copied().unwrap_or(0);
        if n <= h {
            continue;
        }
        let short = n - h;
        let mut pick: Vec<&WalletCoin> = coins
            .iter()
            .filter(|c| {
                c.asset == asset
                    && !c.confidential
                    && !used.contains(&(c.txid.clone(), c.vout))
            })
            .collect();
        pick.sort_by(|a, b| b.amount.cmp(&a.amount));
        let mut got = 0u128;
        for c in pick {
            if got >= short {
                break;
            }
            inputs.push(InputRequest::Wallet {
                txid: c.txid.clone(),
                vout: c.vout,
                asset: asset.clone(),
                amount: c.amount,
            });
            used.push((c.txid.clone(), c.vout));
            got += u128::from(c.amount);
        }
        if got < short {
            return Err(format!(
                "this wallet holds too little of {asset} in explicit coins: the spend needs {short} more atoms and finds {got}"
            ));
        }
        if got > short {
            r.outputs.push(OutputRequest {
                to: "wallet".into(),
                address: Some(change_address.to_string()),
                script: None,
                asset: asset.clone(),
                amount: u64::try_from(got - short).map_err(|e| e.to_string())?,
                open: None,
                input: None,
            });
        }
    }
    r.inputs = Some(inputs);
    Ok(r)
}

fn amount_of(v: &Value) -> Result<u64, String> {
    match v {
        Value::Number(n) => n.as_u64().ok_or_else(|| format!("{n} is not an amount in atoms")),
        Value::String(s) => s
            .parse()
            .map_err(|_| format!("{s:?} is not an amount in atoms")),
        _ => Err("the amount is a number of atoms".into()),
    }
}

/// The engine's approval of what is asked, or its refusal in its own words.
/// `labels` are the wallet's asset labels, by display hex.
pub fn prepare(
    chain: &ContractChain,
    wollet: &Wollet,
    signer: &SwSigner,
    esplora: &str,
    ask: &Ask,
    labels: &BTreeMap<String, AssetLabel>,
) -> Result<Prepared, String> {
    let k = known(&ask.template_hash).ok_or_else(|| {
        format!(
            "template {} is not one this wallet carries, so it signs nothing for it",
            ask.template_hash
        )
    })?;
    let template = Arc::new(k.template().map_err(|e| e.to_string())?);
    let instance = Instance::parse(&ask.instance.to_string()).map_err(|e| e.to_string())?;
    let contract = Arc::new(Contract::new(template, instance).map_err(|e| e.to_string())?);
    let coins = lwk_contracts::wallet::wallet_coins(wollet).map_err(|e| e.to_string())?;
    let scripts = wallet_scripts(wollet, &coins)?;
    let receive = crate::receive_address(
        wollet,
        wollet.address(None).map_err(|e| format!("{e:?}"))?.index(),
    )?;
    let view = |req: &SpendRequest| {
        let mut assets = BTreeMap::new();
        let mut add = |a: &String| {
            if let Some(l) = labels.get(a) {
                assets.insert(a.clone(), l.clone());
            }
        };
        add(&req.coin.asset);
        for o in &req.outputs {
            add(&o.asset);
        }
        for i in req.inputs.iter().flatten() {
            match i {
                InputRequest::Wallet { asset, .. } | InputRequest::Foreign { asset, .. } => add(asset),
                InputRequest::Sibling { coin, .. } => add(&coin.asset),
                InputRequest::Contract => {}
            }
        }
        WalletView {
            known: known_templates(),
            registry: None,
            assets,
            key_path: Some(default_contract_key_path(chain.chain.mainnet)),
        }
    };
    let run = |req: &SpendRequest| -> Result<Prepared, String> {
        let mut records = vec![(req.coin.txid.clone(), req.coin.vout)];
        for i in req.inputs.iter().flatten() {
            match i {
                InputRequest::Foreign { txid, vout, .. } => records.push((txid.clone(), *vout)),
                // The engine checks a sibling coin against the chain's record too.
                InputRequest::Sibling { coin, .. } => records.push((coin.txid.clone(), coin.vout)),
                _ => {}
            }
        }
        let facts = chain_facts(esplora, &req.coin.txid, &records)?;
        let spend = Spend::build_with_coins(
            contract.clone(),
            chain.chain,
            req,
            &scripts,
            &coins,
            Some(facts),
        )
        .map_err(|e| e.to_string())?;
        let approval = Approval::prepare(spend, view(req), signer).map_err(|e| e.to_string())?;
        let summary = approval.summary();
        Ok(Prepared {
            approval,
            summary,
            request: req.clone(),
        })
    };
    if let Some(d) = &ask.drip {
        let rate = d.rate_per_kvb.unwrap_or(1000);
        let fee_for = |vsize: u64| (vsize * rate).div_ceil(1000);
        let to = d.to.clone().unwrap_or_else(|| receive.clone());
        let amount = amount_of(&d.amount)?;
        let mut fee = fee_for(600);
        for _ in 0..3 {
            let req = drip::plan(&contract, &d.coin, &to, amount, fee).map_err(|e| e.to_string())?;
            let p = run(&req)?;
            let need = fee_for(p.summary["vsize"].as_u64().unwrap_or(0));
            if need == fee {
                return Ok(p);
            }
            fee = need;
        }
        return Err("the drip's size did not settle".into());
    }
    let req = ask
        .request
        .as_ref()
        .ok_or("a request (or a drip) is required")?;
    let req = if ask.fund {
        fund_from_wallet(req, &coins, &receive)?
    } else {
        req.clone()
    };
    run(&req)
}

/// Signs the prepared spend only for `shown_digest`, the digest of the summary
/// the screen showed, and broadcasts it through the wallet's explorer. Returns
/// the txid.
pub fn sign_and_broadcast(
    prepared: &Approval,
    shown_digest: &str,
    signer: &SwSigner,
    esplora: &str,
) -> Result<String, String> {
    let tx = prepared
        .sign(shown_digest, signer)
        .map_err(|e| e.to_string())?;
    broadcast(esplora, &serialize_hex(&tx))
}

/// Posts a transaction to the explorer; its txid, or the node's refusal.
pub fn broadcast(esplora: &str, hex: &str) -> Result<String, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let mut req = client.post(format!("{esplora}/tx")).body(hex.to_string());
    if let Some(h) = crate::auth_header() {
        req = req.header("Authorization", h);
    }
    let r = req.send().map_err(|e| e.to_string())?;
    let ok = r.status().is_success();
    let text = r.text().unwrap_or_default().trim().to_string();
    if !ok {
        return Err(format!("the node refused the transaction: {text}"));
    }
    lwk_wollet::elements::Txid::from_str(&text)
        .map(|t| t.to_string())
        .map_err(|_| format!("the explorer answered {text:?}, not a txid"))
}
