//! Ambra's issuance and reissuance against a real `sequentiad`, built by
//! `ambra_core::issuance` and signed as the app signs:
//!
//! - the issuance the app built before (the kit's default receivers, this
//!   wallet's confidential addresses) blinds the asset and token outputs;
//! - an issuance of an asset and its reissuance token: both outputs, and the
//!   issued amount, are explicit;
//! - a reissuance spending that explicit token, its input marked with the
//!   node's sentinel nonce (`0…01`), and its output explicit; then a second
//!   reissuance from the token it returned;
//! - the same reissuance with the nonce the kit used to set for an explicit
//!   token (zero, the token's blinding factor) is refused by the mempool and
//!   by a block: consensus reads it as a new issuance.
//!
//! ```text
//! SEQUENTIAD_EXEC=/path/to/sequentiad cargo test --test issuance -- --nocapture
//! ```
//!
//! Without it the test fails and says what it needs.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::str::FromStr;
use std::time::Duration;

use lwk_common::{ElementsParamsBuilder, Network, Signer as _};
use lwk_signer::SwSigner;
use lwk_wollet::bitcoin::bip32::ChildNumber;
use lwk_wollet::clients::LastUnused;
use lwk_wollet::elements::encode::{deserialize, serialize};
use lwk_wollet::elements::hashes::Hash as _;
use lwk_wollet::elements::hex::{FromHex, ToHex};
use lwk_wollet::elements::pset::PartiallySignedTransaction;
use lwk_wollet::elements::secp256k1_zkp::ZERO_TWEAK;
use lwk_wollet::elements::{AssetId, BlockExtData, BlockHash, BlockHeader, Transaction, TxMerkleNode};
use lwk_wollet::{Chain, DownloadTxResult, TxBuilder, Update, Wollet, WolletBuilder, WolletDescriptor};
use serde_json::{json, Value as Json};

const COIN: u64 = 100_000_000;
/// A published test mnemonic: the wallet holds nothing outside these tests.
const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const FEE_RATE: f32 = 1000.0;

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
    fn mine(&self, n: u32) -> Vec<String> {
        let a = self.rpc("getnewaddress", json!([]));
        let hashes = self.rpc("generatetoaddress", json!([n, a]));
        let mut txids = vec![];
        for h in hashes.as_array().unwrap() {
            for t in self.rpc("getblock", json!([h]))["tx"].as_array().unwrap() {
                txids.push(t.as_str().unwrap().to_string());
            }
        }
        txids
    }
    fn verbose(&self, txid: &str) -> Json {
        self.rpc("getrawtransaction", json!([txid, true]))
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
    let dir = std::env::temp_dir().join(format!("ambra-issuance-{}", std::process::id()));
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
            // One script-check thread: a block's refusal then names its reason.
            "-par=1".into(),
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

fn pset_of(builder: TxBuilder, wollet: &Wollet) -> PartiallySignedTransaction {
    builder.fee_rate(Some(FEE_RATE)).finish(wollet).unwrap()
}

fn signed(signer: &SwSigner, wollet: &Wollet, mut pset: PartiallySignedTransaction) -> Transaction {
    signer.sign(&mut pset).unwrap();
    wollet.finalize(&mut pset).unwrap()
}

/// Every output of `tx` that pays this wallet carries an explicit value and
/// asset; returns how many there are.
fn explicit_outputs_to_wallet(node: &Node, wollet: &Wollet, tx: &Transaction) -> usize {
    let mine: Vec<String> = (0..20u32)
        .flat_map(|i| {
            [
                wollet.address(Some(i)).unwrap().address().script_pubkey().to_hex(),
                wollet.change(Some(i)).unwrap().address().script_pubkey().to_hex(),
            ]
        })
        .collect();
    let v = node.verbose(&tx.txid().to_string());
    let mut n = 0;
    for o in v["vout"].as_array().unwrap() {
        let spk = o["scriptPubKey"]["hex"].as_str().unwrap_or("");
        if !mine.iter().any(|m| m == spk) {
            continue;
        }
        assert!(o["value"].is_number(), "output {} has an explicit value: {o}", o["n"]);
        assert!(o["asset"].is_string(), "output {} has an explicit asset: {o}", o["n"]);
        assert!(o.get("valuecommitment").is_none() && o.get("assetcommitment").is_none(), "{o}");
        n += 1;
    }
    n
}

/// The issuance input of a verbose transaction.
fn issuance_of(v: &Json) -> Json {
    v["vin"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i.get("issuance").is_some())
        .expect("an input with an issuance")["issuance"]
        .clone()
}

#[test]
fn an_issuance_and_its_reissuances_are_explicit() {
    let exe = std::env::var("SEQUENTIAD_EXEC").expect("set SEQUENTIAD_EXEC to a sequentiad binary");
    let node = start(&exe);
    node.rpc("createwallet", json!(["funder"]));
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
    let desc = ambra_core::descriptor_from_mnemonic(MNEMONIC).unwrap();
    let mut wollet = WolletBuilder::new(network, WolletDescriptor::from_str(&desc).unwrap())
        .build()
        .unwrap();
    register_scripts(&mut wollet);
    let signer = SwSigner::new(MNEMONIC, false).unwrap();

    // Fund the wallet with the chain's own asset, which pays the fees here.
    let me = wollet.address(Some(0)).unwrap().address().to_unconfidential();
    let fund = node.rpc(
        "sendtoaddress",
        json!({"address": me.to_string(), "amount": 10, "fee_asset_label": policy}),
    );
    assert!(node.mine(1).contains(&fund.as_str().unwrap().to_string()));
    let raw = node.rpc("getrawtransaction", json!([fund])).as_str().unwrap().to_string();
    let fund_tx: Transaction = deserialize(&Vec::<u8>::from_hex(&raw).unwrap()).unwrap();
    wollet.apply_transaction(fund_tx).unwrap();

    // ---- the issuance the app built before: the kit's default receivers,
    // this wallet's confidential addresses, so every issued output is blinded.
    // Decoded and judged by the mempool, not broadcast.
    let before = TxBuilder::new(network).issue_asset(1_000 * COIN, None, COIN, None, None).unwrap();
    let before = signed(&signer, &wollet, pset_of(before, &wollet));
    let before_hex = serialize(&before).to_hex();
    let d = node.rpc("decoderawtransaction", json!([before_hex]));
    let blinded = d["vout"].as_array().unwrap().iter().filter(|o| o.get("valuecommitment").is_some()).count();
    let iss = issuance_of(&d);
    assert!(blinded >= 2, "the old issuance blinds the asset and the token: {d}");
    let ok = node.rpc("testmempoolaccept", json!([[before_hex]]));
    println!(
        "before: the old issuance of asset {} (token {}) has {blinded} blinded outputs, mempool allowed: {}",
        iss["asset"], iss["token"], ok[0]["allowed"]
    );

    // ---- the issuance ----
    let b = ambra_core::issuance::issue_builder(network, &wollet, 1_000 * COIN, COIN).unwrap();
    let issue = signed(&signer, &wollet, pset_of(b, &wollet));
    let id = node.rpc("sendrawtransaction", json!([serialize(&issue).to_hex()]));
    assert!(node.mine(1).contains(&id.as_str().unwrap().to_string()));
    let v = node.verbose(&issue.txid().to_string());
    let iss = issuance_of(&v);
    let asset = iss["asset"].as_str().unwrap().to_string();
    let token = iss["token"].as_str().unwrap().to_string();
    assert!(iss["assetamount"].is_number(), "the issued amount is explicit: {iss}");
    assert!(iss["tokenamount"].is_number(), "the token amount is explicit: {iss}");
    let n = explicit_outputs_to_wallet(&node, &wollet, &issue);
    let paid: Vec<&str> = v["vout"].as_array().unwrap().iter().filter_map(|o| o["asset"].as_str()).collect();
    assert!(paid.contains(&asset.as_str()) && paid.contains(&token.as_str()), "{v}");
    println!(
        "issuance {} in block {}: asset {asset}, token {token}, {n} explicit outputs to the wallet, {} vB",
        issue.txid(),
        node.rpc("getblockcount", json!([])),
        v["vsize"]
    );
    wollet.apply_transaction(issue).unwrap();

    // ---- a reissuance, and the same one with the old nonce ----
    let asset_id = AssetId::from_str(&asset).unwrap();
    let b = ambra_core::issuance::reissue_builder(network, &wollet, asset_id, 500 * COIN).unwrap();
    let pset = pset_of(b, &wollet);
    let idx = pset
        .inputs()
        .iter()
        .position(|i| i.issuance_blinding_nonce.is_some())
        .expect("the token input carries the reissuance");
    let mut old = pset.clone();
    old.inputs_mut()[idx].issuance_blinding_nonce = Some(ZERO_TWEAK);
    let reissue = signed(&signer, &wollet, pset);
    let twin = signed(&signer, &wollet, old);

    let twin_hex = serialize(&twin).to_hex();
    let mempool = try_rpc(node.port, "sendrawtransaction", json!([twin_hex])).unwrap_err();
    println!("the zero-nonce reissuance, mempool: {mempool}");
    let addr = node.rpc("getnewaddress", json!([]));
    let block = try_rpc(node.port, "generateblock", json!([addr, [twin_hex]])).unwrap_err();
    println!("the zero-nonce reissuance, forced into a block: {block}");
    // Read as a new issuance, its input issues a different asset from a fresh
    // entropy, and the 500 coins it pays in the asset come from nowhere.
    assert!(
        mempool.contains("bad-txns-in-ne-out") || mempool.contains("value-in-ne-out"),
        "{mempool}"
    );
    assert!(block.contains("bad-txns-in-ne-out") || block.contains("value-in-ne-out"), "{block}");

    let id = node.rpc("sendrawtransaction", json!([serialize(&reissue).to_hex()]));
    assert!(node.mine(1).contains(&id.as_str().unwrap().to_string()));
    let v = node.verbose(&reissue.txid().to_string());
    let iss = issuance_of(&v);
    assert_eq!(
        iss["assetBlindingNonce"].as_str().unwrap(),
        format!("{}01", "0".repeat(62)),
        "the node's sentinel, as the node shows it: {iss}"
    );
    assert_eq!(iss["isreissuance"], json!(true), "{iss}");
    assert_eq!(iss["asset"].as_str().unwrap(), asset);
    assert!(iss["assetamount"].is_number(), "{iss}");
    let n = explicit_outputs_to_wallet(&node, &wollet, &reissue);
    println!(
        "reissuance {} in block {}: 500 of {asset}, nonce {}, {n} explicit outputs to the wallet, {} vB",
        reissue.txid(),
        node.rpc("getblockcount", json!([])),
        iss["assetBlindingNonce"],
        v["vsize"]
    );
    wollet.apply_transaction(reissue).unwrap();

    // ---- a second reissuance, from the token the first one returned ----
    let b = ambra_core::issuance::reissue_builder(network, &wollet, asset_id, 250 * COIN).unwrap();
    let again = signed(&signer, &wollet, pset_of(b, &wollet));
    let id = node.rpc("sendrawtransaction", json!([serialize(&again).to_hex()]));
    assert!(node.mine(1).contains(&id.as_str().unwrap().to_string()));
    let n = explicit_outputs_to_wallet(&node, &wollet, &again);
    println!("second reissuance {}: {n} explicit outputs to the wallet", again.txid());
    wollet.apply_transaction(again).unwrap();
    let held = wollet.balance().unwrap();
    assert_eq!(held.get(&asset_id).copied(), Some(1_750 * COIN));
    println!("the wallet holds {} atoms of {asset}", held[&asset_id]);
}
