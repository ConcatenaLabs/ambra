//! Ambra's contract spends against a real `sequentiad`, through the kit's
//! engine under the five-point rule (`ambra_core::contracts`):
//!
//! - a drip from a faucet drip covenant whose faucet key is this wallet's
//!   contract key: the summary the screen shows is asserted (the template, the
//!   path, the five checks, the wallet's balance change), then it is signed with
//!   the digest of that summary, broadcast through the explorer and confirmed;
//! - a Pignus version 2 vault whose borrower is this wallet, repaid in part and
//!   then in full, each funded from the wallet's own coins (its debt-asset coin
//!   and the change), each summary asserted and each spend confirmed; the full
//!   repayment returns the collateral to the wallet.
//!
//! Refused, each before anything is signed: a digest that was not shown; a
//! wallet input said to be in another asset than the wallet's record of it; a
//! foreign coin said to hold what the chain's record does not; a template the
//! wallet does not carry.
//!
//! The test serves the Esplora endpoints the module reads (`/blocks/tip/hash`,
//! `/block/:h`, `/block-height/:n`, `/tx/:t`, `/tx/:t/status`, `POST /tx`) from
//! the node's RPC, and hands the wallet the transactions it makes and receives,
//! as a scan would.
//!
//! ```text
//! SEQUENTIAD_EXEC=/path/to/sequentiad cargo test --test contracts -- --nocapture
//! ```
//!
//! Without it the test fails and says what it needs.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::str::FromStr;
use std::time::Duration;

use ambra_core::contracts::{self, Ask, ContractChain};
use lwk_common::{ElementsParamsBuilder, Network};
use lwk_contracts::approval::AssetLabel;
use lwk_contracts::spend::{default_contract_key_path, Spend};
use lwk_signer::SwSigner;
use lwk_wollet::bitcoin::bip32::ChildNumber;
use lwk_wollet::clients::LastUnused;
use lwk_wollet::elements::encode::deserialize;
use lwk_wollet::elements::hashes::{sha256, Hash as _};
use lwk_wollet::elements::hex::{FromHex, ToHex};
use lwk_wollet::elements::{
    AssetId, BlockExtData, BlockHash, BlockHeader, Transaction, TxMerkleNode,
};
use lwk_wollet::{Chain, DownloadTxResult, Update, Wollet, WolletBuilder, WolletDescriptor};
use serde_json::{json, Value as Json};

const COIN: u64 = 100_000_000;
/// A published test mnemonic: the wallet holds nothing outside these tests.
const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const DRIP: &str = "12986f202fbfb850f7699c5d5188f261f276de6c7038142f0a28bbb672b5af34";
const VAULT: &str = "6b17869c4e2abe782fe3d8a3ece4865b8f0aa483028b1d0a815e6bcb4e8939ac";

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

struct Node {
    child: Child,
    dir: PathBuf,
    port: u16,
}

impl Node {
    fn rpc(&self, method: &str, params: Json) -> Json {
        try_rpc(self.port, method, params).unwrap_or_else(|e| panic!("{method}: {e}"))
    }
    fn mine(&self, n: u32) {
        let a = self.rpc("getnewaddress", json!([]));
        self.rpc("generatetoaddress", json!([n, a]));
    }
    fn advance(&self, secs: u64) {
        let t = self.rpc("getblockheader", json!([self.rpc("getbestblockhash", json!([]))]))["time"]
            .as_u64()
            .unwrap();
        self.rpc("setmocktime", json!([t + secs + 60]));
        self.mine(12);
    }
    fn tx(&self, txid: &str) -> Transaction {
        let raw = self.rpc("getrawtransaction", json!([txid]));
        deserialize(&Vec::<u8>::from_hex(raw.as_str().unwrap()).unwrap()).unwrap()
    }
    fn vout_to(&self, txid: &str, spk: &str) -> (u32, String, u64) {
        let t = self.rpc("getrawtransaction", json!([txid, true]));
        let o = t["vout"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["scriptPubKey"]["hex"] == json!(spk))
            .unwrap_or_else(|| panic!("{txid} pays nothing to {spk}"));
        (
            o["n"].as_u64().unwrap() as u32,
            o["asset"].as_str().unwrap().into(),
            atoms(&o["value"]).unwrap(),
        )
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        let _ = try_rpc(self.port, "stop", json!([]));
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn try_rpc(port: u16, method: &str, params: Json) -> Result<Json, String> {
    let body = json!({"jsonrpc": "1.0", "id": 1, "method": method, "params": params}).to_string();
    let mut s = TcpStream::connect(("127.0.0.1", port)).map_err(|e| e.to_string())?;
    s.set_read_timeout(Some(Duration::from_secs(120))).ok();
    let req = format!(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Basic dTpw\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
    let mut out = String::new();
    s.read_to_string(&mut out).map_err(|e| e.to_string())?;
    let json_part = out.split("\r\n\r\n").nth(1).ok_or("no body")?;
    let v: Json = serde_json::from_str(json_part).map_err(|e| format!("{e}: {json_part}"))?;
    if !v["error"].is_null() {
        return Err(v["error"]["message"].as_str().unwrap_or("error").to_string());
    }
    Ok(v["result"].clone())
}

fn start(exe: &str) -> Node {
    let dir = std::env::temp_dir().join(format!("ambra-contracts-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let port = free_port();
    let child = Command::new(exe)
        .args([
            format!("-datadir={}", dir.display()),
            "-chain=elementsregtest".into(),
            format!("-rpcport={port}"),
            format!("-port={}", free_port()),
            "-listen=0".into(),
            "-server".into(),
            "-rpcuser=u".into(),
            "-rpcpassword=p".into(),
            "-txindex=1".into(),
            "-par=1".into(),
            "-evbparams=simplicity:-1:::".into(),
            "-initialfreecoins=2100000000000000".into(),
            "-anyonecanspendaremine=1".into(),
            "-blindedaddresses=0".into(),
            "-con_default_blinded_addresses=0".into(),
            "-validatepegin=0".into(),
            "-con_parent_chain_signblockscript=51".into(),
            "-con_any_asset_fees=1".into(),
            "-fallbackfee=0.0001".into(),
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    for i in 0.. {
        if try_rpc(port, "getblockcount", json!([])).is_ok() {
            break;
        }
        assert!(i < 300, "the node did not start");
        std::thread::sleep(Duration::from_millis(300));
    }
    Node { child, dir, port }
}

fn atoms(v: &Json) -> Option<u64> {
    v.as_f64().map(|f| (f * COIN as f64).round() as u64)
}

// --- the explorer ---------------------------------------------------------------

fn serve_explorer(port: u16) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let _ = answer(port, stream);
        }
    });
    url
}

fn answer(port: u16, mut stream: TcpStream) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let path = parts.next().unwrap_or("").to_string();
    let mut length = 0usize;
    loop {
        let mut h = String::new();
        reader.read_line(&mut h)?;
        if h == "\r\n" || h.is_empty() {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            if k.eq_ignore_ascii_case("content-length") {
                length = v.trim().parse().unwrap_or(0);
            }
        }
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body)?;
    let (status, text) = route(port, &method, &path, &String::from_utf8_lossy(&body));
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
        text.len()
    );
    stream.write_all(reply.as_bytes())
}

fn route(port: u16, method: &str, path: &str, body: &str) -> (&'static str, String) {
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let rpc = |m: &str, p: Json| try_rpc(port, m, p);
    match (method, parts.as_slice()) {
        ("GET", ["blocks", "tip", "hash"]) => ("200 OK", rpc("getbestblockhash", json!([])).unwrap().as_str().unwrap().into()),
        ("GET", ["block-height", h]) => ("200 OK", rpc("getblockhash", json!([h.parse::<u64>().unwrap()])).unwrap().as_str().unwrap().into()),
        ("GET", ["block", hash]) => {
            let h = rpc("getblockheader", json!([hash])).unwrap();
            ("200 OK", json!({"id": h["hash"], "height": h["height"], "mediantime": h["mediantime"]}).to_string())
        }
        ("GET", ["tx", txid, "status"]) => {
            let t = rpc("getrawtransaction", json!([txid, true])).unwrap();
            match t["blockhash"].as_str() {
                Some(b) => {
                    let h = rpc("getblockheader", json!([b])).unwrap();
                    ("200 OK", json!({"confirmed": true, "block_height": h["height"]}).to_string())
                }
                None => ("200 OK", json!({"confirmed": false}).to_string()),
            }
        }
        ("GET", ["tx", txid]) => {
            let t = rpc("getrawtransaction", json!([txid, true])).unwrap();
            let vout: Vec<Json> = t["vout"]
                .as_array()
                .unwrap()
                .iter()
                .map(|o| {
                    let mut e = json!({"scriptpubkey": o["scriptPubKey"]["hex"]});
                    if let Some(v) = atoms(&o["value"]) {
                        e["value"] = json!(v);
                    }
                    if o["asset"].is_string() {
                        e["asset"] = o["asset"].clone();
                    }
                    e
                })
                .collect();
            ("200 OK", json!({"txid": t["txid"], "vout": vout}).to_string())
        }
        ("POST", ["tx"]) => match rpc("sendrawtransaction", json!([body.trim()])) {
            Ok(id) => ("200 OK", id.as_str().unwrap().to_string()),
            Err(e) => ("400 Bad Request", e),
        },
        _ => ("404 Not Found", format!("not served here: {path}")),
    }
}

// --- the wallet -----------------------------------------------------------------

/// Teach the wallet its first scripts, which a scan would; the test then hands
/// it each transaction it makes or receives.
fn register_scripts(wollet: &mut Wollet) {
    let mut scripts = vec![];
    for i in 0..20u32 {
        let n = ChildNumber::from_normal_idx(i).unwrap();
        let external = wollet.address(Some(i)).unwrap().address().script_pubkey();
        let internal = wollet.change(Some(i)).unwrap().address().script_pubkey();
        scripts.push((Chain::External, n, external, None));
        scripts.push((Chain::Internal, n, internal, None));
    }
    let update = Update {
        version: 4,
        wollet_status: wollet.status(),
        new_txs: DownloadTxResult::default(),
        txid_height_new: vec![],
        txid_height_delete: vec![],
        timestamps: vec![],
        scripts_with_blinding_pubkey: scripts,
        tip: BlockHeader {
            version: 0,
            prev_blockhash: BlockHash::all_zeros(),
            merkle_root: TxMerkleNode::all_zeros(),
            time: 0,
            height: 0,
            ext: BlockExtData::default(),
            bitcoin_anchor: Some((0, BlockHash::all_zeros())),
        },
        unspent: vec![],
        last_unused: LastUnused::default(),
    };
    wollet.apply_update(update).unwrap();
}

fn hexw(n: u64, bytes: usize) -> String {
    format!("{n:0width$x}", width = 2 * bytes)
}

fn rev(display: &str) -> String {
    let mut b = Vec::<u8>::from_hex(display).unwrap();
    b.reverse();
    b.to_hex()
}

fn sha(spk: &str) -> String {
    sha256::Hash::hash(&Vec::<u8>::from_hex(spk).unwrap()).to_byte_array().to_hex()
}

/// Writes a summary where `AMBRA_CONTRACTS_SUMMARIES` names a directory: the
/// app's screen tests render these (`app/test/fixtures/contracts/`).
fn dump(name: &str, summary: &Json) {
    if let Ok(dir) = std::env::var("AMBRA_CONTRACTS_SUMMARIES") {
        std::fs::write(
            PathBuf::from(dir).join(format!("{name}.json")),
            serde_json::to_string_pretty(summary).unwrap() + "\n",
        )
        .unwrap();
    }
}

fn shows(summary: &Json, label: &str, wants: &[&str]) {
    let text = summary.to_string().to_lowercase();
    for w in wants {
        assert!(text.contains(&w.to_lowercase()), "{label}: the summary shows {w:?}\n{summary:#}");
    }
}

#[test]
fn a_drip_and_a_vault_repaid_under_the_five_point_rule() {
    let exe = std::env::var("SEQUENTIAD_EXEC").expect("set SEQUENTIAD_EXEC to a sequentiad binary");
    let node = start(&exe);
    let esplora = serve_explorer(node.port);
    let mut log = vec![];
    node.rpc("createwallet", json!(["lender"]));
    node.mine(101);
    node.rpc("rescanblockchain", json!([]));
    let policy = node.rpc("getsidechaininfo", json!([]))["pegged_asset"].as_str().unwrap().to_string();
    let genesis_hex = node.rpc("getblockhash", json!([0])).as_str().unwrap().to_string();
    let network = Network::CustomElements(
        ElementsParamsBuilder::new()
            .with_policy_asset(AssetId::from_str(&policy).unwrap())
            .with_genesis_hash(BlockHash::from_str(&genesis_hex).unwrap())
            .build()
            .unwrap(),
    );
    let chain = ContractChain::for_network(network);
    let desc = ambra_core::descriptor_from_mnemonic(MNEMONIC).unwrap();
    let mut wollet = WolletBuilder::new(network, WolletDescriptor::from_str(&desc).unwrap())
        .build()
        .unwrap();
    register_scripts(&mut wollet);
    let signer = SwSigner::new(MNEMONIC, false).unwrap();
    let me = wollet.address(Some(0)).unwrap().address().to_unconfidential();
    let me_spk = me.script_pubkey().to_hex();
    let mut labels = BTreeMap::from([(policy.clone(), AssetLabel { ticker: "tSEQ".into(), precision: 8 })]);

    // ---- a drip, whose faucet key is this wallet's contract key ----
    let key = Spend::key_at(&signer, &default_contract_key_path(false)).unwrap().to_string();
    let mut params = json!({"ASSET": rev(&policy), "FAUCET_KEY": key,
        "TREASURY_KEY": "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        "INTERVAL": "0001", "FEE_CAP": hexw(100_000, 8), "RECOVERY_DELAY": hexw((1 << 22) | 2, 4)});
    for (n, v) in [("TIER1_FLOOR", 1_000_000), ("TIER1_MAX", 500), ("TIER2_FLOOR", 100_000), ("TIER2_MAX", 200),
        ("TIER3_FLOOR", 10_000), ("TIER3_MAX", 20), ("TIER4_MAX", 2)] {
        params[n] = json!(hexw(v * COIN, 8));
    }
    let drip_instance = json!({"instance": 2, "template_hash": DRIP, "params": params, "slots": {}, "genesis": genesis_hex});
    let drip_contract = lwk_contracts::Contract::new(
        std::sync::Arc::new(lwk_contracts::known(DRIP).unwrap().template().unwrap()),
        lwk_contracts::Instance::parse(&drip_instance.to_string()).unwrap(),
    )
    .unwrap();
    let cov = drip_contract.address("ert").unwrap();
    let fund = node.rpc("sendtoaddress", json!({"address": cov, "amount": 2_000_000, "fee_asset_label": "bitcoin"}));
    node.mine(1);
    let fund = fund.as_str().unwrap();
    let (vout, asset, amount) = node.vout_to(fund, &drip_contract.derived.script_pubkey);
    let coin = json!({"txid": fund, "vout": vout, "script_pubkey": drip_contract.derived.script_pubkey, "asset": asset, "amount": amount});
    node.advance(600);
    let ask: Ask = serde_json::from_value(json!({"templateHash": DRIP, "instance": drip_instance,
        "drip": {"coin": coin, "amount": "50000000000", "ratePerKvb": 1000}})).unwrap();
    let p = contracts::prepare(&chain, &wollet, &signer, &esplora, &ask, &labels).unwrap();
    shows(&p.summary, "drip", &["an unregistered template, root", "sequentia/faucet-drip", "\"name\":\"drip\"",
        "is on this wallet's list", "the engine derived", "the contract's program (input 0) ran against the final transaction",
        "faucet_key is this wallet's contract key at m/8383h/1h/0h/0/0", "500.00000000 tsEQ", "this wallet's contract key"]);
    assert_eq!(p.summary["wallet_change"][0]["change"], json!((500 * COIN).to_string()));
    dump("drip", &p.summary);
    log.push(json!({"step": "drip: the summary", "checks": p.summary["checks"], "wallet_change": p.summary["wallet_change"], "vsize": p.summary["vsize"], "digest": p.summary["digest"]}));
    let e = contracts::sign_and_broadcast(&p.approval, &"00".repeat(32), &signer, &esplora).unwrap_err();
    assert!(e.contains("is not what was shown"), "{e}");
    log.push(json!({"step": "refused: a digest not shown", "error": e}));
    let txid = contracts::sign_and_broadcast(&p.approval, p.approval.digest(), &signer, &esplora).unwrap();
    node.mine(1);
    let t = node.rpc("getrawtransaction", json!([txid, true]));
    assert!(t["confirmations"].as_u64().unwrap() >= 1);
    wollet.apply_transaction(node.tx(&txid)).unwrap();
    log.push(json!({"step": "drip confirmed", "txid": txid, "vsize": t["vsize"]}));

    // A template the wallet does not carry.
    let bad: Ask = serde_json::from_value(json!({"templateHash": "ab".repeat(32), "instance": drip_instance, "drip": {"coin": coin, "amount": 1}})).unwrap();
    let e = contracts::prepare(&chain, &wollet, &signer, &esplora, &bad, &labels).err().unwrap();
    assert!(e.contains("is not one this wallet carries"), "{e}");
    log.push(json!({"step": "refused: a template the wallet does not carry", "error": e}));

    // ---- a Pignus vault this wallet borrows under ----
    let issue = || {
        let a = node.rpc("issueasset", json!({"assetamount": 1000, "tokenamount": 0, "blind": false, "fee_asset": "bitcoin"}))["asset"]
            .as_str().unwrap().to_string();
        node.mine(1);
        a
    };
    let (x, y) = (issue(), issue());
    let mut rates = node.rpc("getfeeexchangerates", json!([]));
    rates[&x] = json!(COIN);
    rates[&y] = json!(COIN);
    node.rpc("setfeeexchangerates", json!([rates]));
    labels.insert(x.clone(), AssetLabel { ticker: "XCOL".into(), precision: 8 });
    labels.insert(y.clone(), AssetLabel { ticker: "YDEBT".into(), precision: 8 });
    let lender_spk = node.rpc("getaddressinfo", json!([node.rpc("getnewaddress", json!(["", "bech32"]))]))["scriptPubKey"]
        .as_str().unwrap().to_string();
    let now = node.rpc("getblockchaininfo", json!([]))["mediantime"].as_u64().unwrap();
    let debt = 1_050_000_000u64;
    let last = now - 1;
    let vparams = json!({"COLL": rev(&x), "DEBT_ASSET": rev(&y), "ORACLE": "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        "BEACON_ASSET": rev(&policy), "PRECISION": "08", "LIQ_BP": hexw(12_000, 4), "TARGET_BP": hexw(15_000, 4), "BONUS_BP": hexw(10_500, 4),
        "MATURITY": hexw(now + 4 * 3600, 4), "RECOVER_AFTER": hexw(now + 8 * 3600, 4), "LENDER": sha(&lender_spk), "BORROWER": sha(&me_spk)});
    let vault = |d: u64| json!({"instance": 2, "template_hash": VAULT, "params": vparams, "slots": {"DEBT_OUT": hexw(d, 8), "LAST_TIME": hexw(last, 4)}, "genesis": genesis_hex});
    let vault_spk = |d: u64| {
        lwk_contracts::Contract::new(
            std::sync::Arc::new(lwk_contracts::known(VAULT).unwrap().template().unwrap()),
            lwk_contracts::Instance::parse(&vault(d).to_string()).unwrap(),
        )
        .unwrap()
        .derived
        .script_pubkey
    };
    let vaddr = lwk_wollet::elements::Address::from_script(
        &lwk_contracts::spend::script_from_hex(&vault_spk(debt)).unwrap(), None, &lwk_wollet::elements::AddressParams::ELEMENTS,
    )
    .unwrap();
    let vfund = node.rpc("sendtoaddress", json!({"address": vaddr.to_string(), "amount": 10, "assetlabel": x, "fee_asset_label": "bitcoin"}));
    let yfund = node.rpc("sendtoaddress", json!({"address": me.to_string(), "amount": 12, "assetlabel": y, "fee_asset_label": "bitcoin"}));
    node.mine(1);
    wollet.apply_transaction(node.tx(yfund.as_str().unwrap())).unwrap();
    let vfund = vfund.as_str().unwrap().to_string();
    let (vv, _, va) = node.vout_to(&vfund, &vault_spk(debt));
    let vcoin = json!({"txid": vfund, "vout": vv, "script_pubkey": vault_spk(debt), "asset": x, "amount": va});
    let paid = 2 * COIN;
    let repay = |coin: &Json, inputs: Json| json!({"templateHash": VAULT, "instance": vault(debt), "fund": true, "request": {
        "path": "repay", "coin": coin, "inputs": inputs,
        "outputs": [{"to": "contract", "script": vault_spk(debt - paid), "asset": x, "amount": va},
                    {"to": "pay", "script": lender_spk, "asset": y, "amount": paid},
                    {"to": "fee", "asset": y, "amount": 2000}],
        "spender": {"PATH": "Left(Left(()))"}, "next_slots": {"DEBT_OUT": hexw(debt - paid, 8), "LAST_TIME": hexw(last, 4)}}});

    // Refused: a wallet input said to be in another asset, and a foreign coin the chain does not back.
    let ycoin = lwk_contracts::wallet::wallet_coins(&wollet).unwrap().into_iter().find(|c| c.asset == y).unwrap();
    // (Not funded: the wallet would find no coin of the asset the lie hides.)
    let mut lie = repay(&vcoin, json!([{"is": "contract"}, {"is": "wallet", "txid": ycoin.txid, "vout": ycoin.vout, "asset": x, "amount": ycoin.amount}]));
    lie["fund"] = json!(false);
    let lie: Ask = serde_json::from_value(lie).unwrap();
    let e = contracts::prepare(&chain, &wollet, &signer, &esplora, &lie, &labels).err().unwrap();
    assert!(e.contains("so it is not spent as shown"), "{e}");
    log.push(json!({"step": "refused: a wallet input said to be in another asset", "error": e}));
    let foreign: Ask = serde_json::from_value(repay(&vcoin, json!([{"is": "contract"},
        {"is": "foreign", "txid": fund, "vout": vout, "script_pubkey": drip_contract.derived.script_pubkey, "asset": policy, "amount": 7, "witness": ["51", "00"]}]))).unwrap();
    let e = contracts::prepare(&chain, &wollet, &signer, &esplora, &foreign, &labels).err().unwrap();
    assert!(e.contains("the chain's record is"), "{e}");
    log.push(json!({"step": "refused: a foreign coin the chain does not back", "error": e}));

    // The repayment in part, funded from the wallet.
    let ask: Ask = serde_json::from_value(repay(&vcoin, json!([{"is": "contract"}]))).unwrap();
    let p = contracts::prepare(&chain, &wollet, &signer, &esplora, &ask, &labels).unwrap();
    shows(&p.summary, "repay", &["pignus/vault", "\"name\":\"repay\"", "this wallet's coin", "signed with its funding key m/84h/1h/0h/0/0",
        "path repay takes no signature, so no contract key signs", "the contract's program (input 0) ran against the final transaction",
        "sha-256 of this wallet's script", "-2.00002000 YDEBT", "2.00000000 YDEBT", "PATH = Left(Left(… (checked against the kit's table"]);
    dump("repay", &p.summary);
    log.push(json!({"step": "repay (part): the summary", "inputs": p.summary["inputs"], "wallet_change": p.summary["wallet_change"], "checks": p.summary["checks"], "vsize": p.summary["vsize"]}));
    let txid = contracts::sign_and_broadcast(&p.approval, p.approval.digest(), &signer, &esplora).unwrap();
    node.mine(1);
    let t = node.rpc("getrawtransaction", json!([txid, true]));
    assert!(t["confirmations"].as_u64().unwrap() >= 1);
    assert_eq!(t["vout"][0]["scriptPubKey"]["hex"], json!(vault_spk(debt - paid)));
    wollet.apply_transaction(node.tx(&txid)).unwrap();
    log.push(json!({"step": "repay (part) confirmed", "txid": txid, "vsize": t["vsize"]}));

    // The rest, in full: the collateral comes back to this wallet.
    let rest = debt - paid;
    let vcoin2 = json!({"txid": txid, "vout": 0, "script_pubkey": vault_spk(rest), "asset": x, "amount": va});
    let mut inst2 = vault(rest);
    inst2["slots"]["DEBT_OUT"] = json!(hexw(rest, 8));
    let ask: Ask = serde_json::from_value(json!({"templateHash": VAULT, "instance": inst2, "fund": true, "request": {
        "path": "repay", "coin": vcoin2, "inputs": [{"is": "contract"}],
        "outputs": [{"to": "wallet", "script": me_spk, "asset": x, "amount": va},
                    {"to": "pay", "script": lender_spk, "asset": y, "amount": rest},
                    {"to": "fee", "asset": y, "amount": 2000}],
        "spender": {"PATH": "Left(Left(()))"}}})).unwrap();
    let p = contracts::prepare(&chain, &wollet, &signer, &esplora, &ask, &labels).unwrap();
    shows(&p.summary, "repay (full)", &["10.00000000 XCOL", "-8.50002000 YDEBT"]);
    let txid = contracts::sign_and_broadcast(&p.approval, p.approval.digest(), &signer, &esplora).unwrap();
    node.mine(1);
    let t = node.rpc("getrawtransaction", json!([txid, true]));
    assert!(t["confirmations"].as_u64().unwrap() >= 1);
    assert_eq!(t["vout"][0]["scriptPubKey"]["hex"], json!(me_spk));
    log.push(json!({"step": "repay (full) confirmed, the collateral back to this wallet", "txid": txid, "vsize": t["vsize"],
        "wallet_change": p.summary["wallet_change"]}));

    if let Ok(out) = std::env::var("AMBRA_CONTRACTS_LOG") {
        std::fs::write(out, serde_json::to_string_pretty(&log).unwrap()).unwrap();
    }
    for l in &log {
        println!("{l}");
    }
}

/// The templates this wallet carries are the kit's, among them the Pignus
/// vault and offer of several oracles, so a 2-of-3 take or liquidation is not
/// refused at the first point of the rule.
#[test]
fn the_wallet_carries_the_pignus_threshold_templates() {
    let known = contracts::known_templates();
    for (name, hash) in [
        ("pignus/vault-threshold", "b7fee3aa3dd5f1078204e91384f14bd7c78d7d8a051fc7ace00e9b3bde0e6f75"),
        ("pignus/offer-threshold", "c8d981f09b6bd60b52e152a093ed54070e76fe82b305ca02a43c568e81e1e811"),
    ] {
        assert!(known.iter().any(|k| k == hash), "{name} {hash} is not on the list: {known:?}");
    }
}
