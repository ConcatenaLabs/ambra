//! Ambra's staking pools against a real `sequentiad`: a join, a move and a
//! leave built by `ambra_core::staking`, each confirmed in a block.
//!
//! Each test starts a proof-of-stake `sequentiad` on a fresh `elementsregtest`
//! chain, funds a wallet with Ambra's own descriptor from the genesis output,
//! and puts the node back on its default relay policy, under which everything
//! Ambra builds must relay. Ambra talks to an explorer, not to a node, so the
//! test serves the handful of Esplora endpoints the staking code reads
//! (`/blocks/tip/height`, `/scripthash/:h/utxo`, `/scripthash/:h/txs[/chain/:t]`,
//! `/tx/:t/outspend/:n`, `POST /tx`), answered from the node's own RPC. Every
//! transaction Ambra broadcasts goes through that `POST /tx`, and the tip it
//! signs for is the one `/blocks/tip/height` reports.
//!
//! `records_from_block_one`, on a chain with the second generation of stake
//! records and the record hardening from block 1 (every new chain):
//!
//! - the join the app made before (a record paid from wallet coins alone) is
//!   refused by the mempool and by a block (`bad-delegation-unauthorized`),
//!   which accepts Ambra's join: the wallet's payment to the staking key and
//!   the record created from that coin;
//! - the join, found again through the staking key's history alone;
//! - a move, signed for the next block; the same move signed the legacy way is
//!   refused by the mempool and a block;
//! - a leave; then a join finished from a coin already at the staking key (the
//!   recovery path when a join's record never went out), and a second leave;
//! - a record spend with no readable tip is refused before anything is built.
//!
//! `records_across_the_fork_height`, on a chain switching at height 14, the way
//! the testnet switches at 163,000: the join and a move below it (the move
//! signed the legacy way; the second-generation one refused by a block), and a
//! leave in the first block at it (signed the second-generation way; the legacy
//! one refused by a block).
//!
//! Needs `SEQUENTIAD_EXEC` pointing at a `sequentiad`:
//!
//! ```text
//! SEQUENTIAD_EXEC=/path/to/sequentiad cargo test --test stake_records -- --nocapture
//! ```
//!
//! Without it the tests fail and say what they need: a test that cannot run
//! must not pass.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::str::FromStr;
use std::time::{Duration, Instant};

use ambra_core::api::DelegationRecord;
use ambra_core::staking::{self, StakeChain, DELEGATION_AUTHORIZATION_ATOMS};
use lwk_common::{ElementsParamsBuilder, Network, Signer as _};
use lwk_signer::SwSigner;
use lwk_wollet::bitcoin::bip32::ChildNumber;
use lwk_wollet::clients::LastUnused;
use lwk_wollet::elements::confidential::{Asset, Nonce, Value};
use lwk_wollet::elements::encode::{deserialize, serialize};
use lwk_wollet::elements::hashes::{sha256, sha256d, Hash as _};
use lwk_wollet::elements::hex::{FromHex, ToHex};
use lwk_wollet::elements::secp256k1_zkp::{PublicKey, Secp256k1, SecretKey};
use lwk_wollet::elements::{
    AssetId, BlockExtData, BlockHash, BlockHeader, LockTime, OutPoint, Script, Sequence,
    Transaction, TxIn, TxInWitness, TxMerkleNode, TxOut, TxOutWitness, Txid,
};
use lwk_wollet::{
    build_delegation_spend_tx, sequentia_stake_script, Chain, DelegationSpendPlan,
    DownloadTxResult, StakeRecordSigning, TxBuilder, Update, Wollet, WolletBuilder,
    WolletDescriptor,
};
use serde_json::{json, Value as Json};

const COIN: u64 = 100_000_000;
/// The PSET fee rate Ambra applies by default, atoms per 1000 vbytes.
const FEE_RATE: f32 = 2_000.0;
/// The chain's unbonding period (blocks), hence the bond's relative lock.
const UNBONDING: u32 = 5;
/// A published test mnemonic: the wallet holds nothing outside these tests.
const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

/// The script error of a record spend signed the legacy way where the second
/// generation is in force.
const WRONG_HASH: &str = "(Signature must be zero for failed CHECK(MULTI)SIG operation)";
/// The script error of a record spend signed the second-generation way below
/// the fork height, in a block.
const FALSE_RESULT: &str =
    "(Script evaluated without error but finished with a false/empty top stack element)";

// --- the node ------------------------------------------------------------------

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn try_rpc(port: u16, method: &str, params: Json) -> Result<Json, String> {
    let body = json!({"jsonrpc": "1.0", "id": 1, "method": method, "params": params}).to_string();
    let mut s = TcpStream::connect(("127.0.0.1", port)).map_err(|e| e.to_string())?;
    // "u:p", the test node's own credentials.
    let req = format!(
        "POST / HTTP/1.0\r\nHost: 127.0.0.1\r\nAuthorization: Basic dTpw\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        body.len(),
        body
    );
    s.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
    let mut resp = String::new();
    s.read_to_string(&mut resp).map_err(|e| e.to_string())?;
    let body = resp.split("\r\n\r\n").nth(1).ok_or("no body")?;
    let v: Json = serde_json::from_str(body).map_err(|e| format!("{e}: {resp}"))?;
    if !v["error"].is_null() {
        return Err(v["error"].to_string());
    }
    Ok(v["result"].clone())
}

/// One `sequentiad` on a fresh proof-of-stake `elementsregtest` chain, stopped
/// and its data deleted on drop.
struct Node {
    exe: PathBuf,
    child: Child,
    port: u16,
    dir: PathBuf,
    chain_args: Vec<String>,
}

fn spawn(exe: &Path, dir: &Path, port: u16, args: &[String]) -> Child {
    Command::new(exe)
        .args([
            "-chain=elementsregtest".to_string(),
            format!("-datadir={}", dir.display()),
            format!("-rpcport={port}"),
            format!("-port={}", free_port()),
            "-listen=0".into(),
            "-connect=0".into(),
            "-server".into(),
            "-printtoconsole=0".into(),
            "-rpcuser=u".into(),
            "-rpcpassword=p".into(),
            "-disablewallet".into(),
            "-txindex=1".into(),
            // Scripts checked one by one, so a refusal names its script error.
            "-par=1".into(),
            "-persistmempool=0".into(),
        ])
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

impl Node {
    fn start(name: &str, chain_args: Vec<String>) -> Node {
        let exe = std::env::var("SEQUENTIAD_EXEC")
            .expect("stake_records needs SEQUENTIAD_EXEC set to a sequentiad binary");
        let exe = PathBuf::from(exe);
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let port = free_port();
        let mut args = chain_args.clone();
        // Non-standard transactions accepted only until the genesis output is spent.
        args.push("-acceptnonstdtxn=1".into());
        let child = spawn(&exe, &dir, port, &args);
        let node = Node {
            exe,
            child,
            port,
            dir,
            chain_args,
        };
        node.wait_ready();
        node
    }

    fn restart_with_default_policy(&mut self) {
        self.stop();
        self.port = free_port();
        self.child = spawn(&self.exe, &self.dir, self.port, &self.chain_args);
        self.wait_ready();
    }

    fn wait_ready(&self) {
        let t0 = Instant::now();
        while try_rpc(self.port, "getblockcount", json!([])).is_err() {
            assert!(
                t0.elapsed() < Duration::from_secs(60),
                "sequentiad did not answer"
            );
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    fn stop(&mut self) {
        let _ = try_rpc(self.port, "stop", json!([]));
        let t0 = Instant::now();
        while t0.elapsed() < Duration::from_secs(60) {
            if let Ok(Some(_)) = self.child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }

    fn rpc(&self, method: &str, params: Json) -> Json {
        try_rpc(self.port, method, params).unwrap_or_else(|e| panic!("{method}: {e}"))
    }

    fn tip(&self) -> u32 {
        self.rpc("getblockcount", json!([])).as_u64().unwrap() as u32
    }

    /// Produce one block as the chain's staker, from the mempool. Returns the
    /// ids of the transactions it carries.
    fn produce(&self, staker_wif: &str) -> Vec<Txid> {
        let r = self.rpc("generateposblock", json!([staker_wif]));
        let hash = r["hash"].as_str().unwrap().to_string();
        self.rpc("getblock", json!([hash, 1]))["tx"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| Txid::from_str(t.as_str().unwrap()).unwrap())
            .collect()
    }

    fn send(&self, tx_hex: &str) -> Txid {
        Txid::from_str(
            self.rpc("sendrawtransaction", json!([tx_hex]))
                .as_str()
                .unwrap(),
        )
        .unwrap()
    }

    /// The reason the mempool refuses `tx_hex`; panics if it would accept it.
    fn refusal(&self, tx_hex: &str) -> String {
        let r = &self.rpc("testmempoolaccept", json!([[tx_hex]]))[0];
        assert_eq!(
            r["allowed"],
            json!(false),
            "the node accepts what it should refuse: {r}"
        );
        r["reject-reason"].as_str().unwrap().to_string()
    }

    /// The live delegation of `controller`, per the node.
    fn delegation_of(&self, controller: &[u8]) -> Option<String> {
        self.rpc("getdelegationinfo", json!([]))
            .get(controller.to_hex())
            .and_then(|v| v.as_str())
            .map(str::to_string)
    }

    fn vsize(&self, tx_hex: &str) -> u64 {
        self.rpc("decoderawtransaction", json!([tx_hex]))["vsize"]
            .as_u64()
            .unwrap()
    }

    /// What a block makes of each variant: the block this node produces next,
    /// taken back (`invalidateblock`), with the variant's transactions added
    /// and its merkle root and witness commitment recomputed, judged by
    /// `testproposedblock`. That runs every check a block must pass except the
    /// leader's signature over its hash, the one thing adding a transaction
    /// breaks. Every variant is judged at the same height; the node then
    /// returns to its block, so the chain advances by one.
    fn block_verdicts(
        &self,
        staker_wif: &str,
        variants: &[Vec<Transaction>],
    ) -> Vec<Result<(), String>> {
        let r = self.rpc("generateposblock", json!([staker_wif]));
        let hash = r["hash"].as_str().unwrap().to_string();
        let block =
            Vec::<u8>::from_hex(self.rpc("getblock", json!([hash, 0])).as_str().unwrap()).unwrap();
        // The header as the node serialises it: this chain has no Bitcoin
        // anchor, so it is spliced as bytes rather than decoded.
        let header = Vec::<u8>::from_hex(
            self.rpc("getblockheader", json!([hash, false]))
                .as_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(&block[..header.len()], header.as_slice());
        let txs: Vec<Transaction> = deserialize(&block[header.len()..]).unwrap();
        assert_eq!(txs.len(), 1, "the block carries only its coinbase");
        assert_eq!(
            &header[36..68],
            merkle_root(&txs).to_byte_array().as_slice()
        );
        self.rpc("invalidateblock", json!([hash]));
        let verdicts = variants
            .iter()
            .map(|extra| {
                let mut all = txs.clone();
                all.extend(extra.iter().cloned());
                commit_witnesses(&mut all);
                let mut proposal = header.clone();
                proposal[36..68].copy_from_slice(&merkle_root(&all).to_byte_array());
                proposal.extend(serialize(&all));
                try_rpc(self.port, "testproposedblock", json!([proposal.to_hex()])).map(|_| ())
            })
            .collect();
        self.rpc("reconsiderblock", json!([hash]));
        assert_eq!(self.rpc("getbestblockhash", json!([])), json!(hash));
        verdicts
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        self.stop();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// `bad` is refused by the node's relay policy and by a block, for the reasons
/// given, and `good` is valid in that same block.
fn refused_everywhere(
    node: &Node,
    producer: &str,
    bad: &Transaction,
    good: &[Transaction],
    what: &str,
    policy: &str,
    block: &str,
) {
    let by_policy = node.refusal(&hex_of(bad));
    let verdicts = node.block_verdicts(producer, &[vec![bad.clone()], good.to_vec()]);
    let by_block = verdicts[0]
        .clone()
        .expect_err("a block carrying it must be invalid");
    println!("NEGATIVE {what}: mempool \"{by_policy}\"; block {by_block}");
    assert!(
        by_policy.contains(policy),
        "{what}: mempool said {by_policy}"
    );
    assert!(by_block.contains(block), "{what}: block said {by_block}");
    verdicts[1]
        .clone()
        .unwrap_or_else(|e| panic!("{what}: the same block carrying the right transaction: {e}"));
}

/// Rewrite the coinbase's witness commitment for the block's transactions, as
/// the node computes it in Elements mode.
fn commit_witnesses(txs: &mut [Transaction]) {
    fn hash<T: lwk_wollet::elements::encode::Encodable>(v: &T) -> [u8; 32] {
        sha256d::Hash::hash(&serialize(v)).to_byte_array()
    }
    fn root(leaves: &[[u8; 32]]) -> [u8; 32] {
        if leaves.is_empty() {
            return [0; 32];
        }
        lwk_wollet::elements::fast_merkle_root(leaves).to_byte_array()
    }
    let witness_only = |tx: &Transaction| {
        let ins: Vec<[u8; 32]> = tx
            .input
            .iter()
            .map(|i| {
                let w = if i.is_coinbase() {
                    TxInWitness::default()
                } else {
                    i.witness.clone()
                };
                root(&[
                    hash(&w.amount_rangeproof),
                    hash(&w.inflation_keys_rangeproof),
                    hash(&w.script_witness),
                    hash(&w.pegin_witness),
                ])
            })
            .collect();
        let outs: Vec<[u8; 32]> = tx
            .output
            .iter()
            .map(|o| {
                root(&[
                    hash(&o.witness.surjection_proof),
                    hash(&o.witness.rangeproof),
                ])
            })
            .collect();
        root(&[root(&ins), root(&outs)])
    };
    let leaves: Vec<[u8; 32]> = txs.iter().map(witness_only).collect();
    let mut committed = root(&leaves).to_vec();
    committed.extend_from_slice(&txs[0].input[0].witness.script_witness[0]);
    let commitment = sha256d::Hash::hash(&committed).to_byte_array();
    let index = txs[0]
        .output
        .iter()
        .rposition(|o| {
            let b = o.script_pubkey.as_bytes();
            b.len() >= 38 && b[..6] == [0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed]
        })
        .expect("the coinbase commits to the witnesses");
    let mut script = txs[0].output[index].script_pubkey.to_bytes();
    script[6..38].copy_from_slice(&commitment);
    txs[0].output[index].script_pubkey = Script::from(script);
}

fn merkle_root(txs: &[Transaction]) -> TxMerkleNode {
    let mut level: Vec<[u8; 32]> = txs.iter().map(|t| t.txid().to_byte_array()).collect();
    while level.len() > 1 {
        if level.len() % 2 == 1 {
            level.push(*level.last().unwrap());
        }
        level = level
            .chunks(2)
            .map(|pair| {
                let mut both = pair[0].to_vec();
                both.extend_from_slice(&pair[1]);
                sha256d::Hash::hash(&both).to_byte_array()
            })
            .collect();
    }
    TxMerkleNode::from_byte_array(level[0])
}

// --- the explorer ---------------------------------------------------------------

/// The Esplora endpoints Ambra's staking code reads, answered from the node.
/// Returns the base URL.
fn serve_explorer(rpc_port: u16) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let _ = answer(rpc_port, stream);
        }
    });
    url
}

fn answer(rpc_port: u16, mut stream: TcpStream) -> std::io::Result<()> {
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
    let (status, text) = route(rpc_port, &method, &path, &String::from_utf8_lossy(&body));
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
        text.len()
    );
    stream.write_all(reply.as_bytes())
}

/// Every transaction the node knows, confirmed (with its height) or in the
/// mempool, oldest first.
fn chain_txs(port: u16) -> Vec<(Json, Option<u32>)> {
    let tip = try_rpc(port, "getblockcount", json!([]))
        .unwrap()
        .as_u64()
        .unwrap();
    let mut out = vec![];
    for h in 0..=tip {
        let hash = try_rpc(port, "getblockhash", json!([h])).unwrap();
        let block = try_rpc(port, "getblock", json!([hash, 2])).unwrap();
        for tx in block["tx"].as_array().unwrap() {
            out.push((tx.clone(), Some(h as u32)));
        }
    }
    for txid in try_rpc(port, "getrawmempool", json!([]))
        .unwrap()
        .as_array()
        .unwrap()
    {
        if let Ok(tx) = try_rpc(port, "getrawtransaction", json!([txid, true])) {
            out.push((tx, None));
        }
    }
    out
}

fn atoms(v: &Json) -> Option<u64> {
    v.as_f64().map(|f| (f * COIN as f64).round() as u64)
}

fn script_hash_of(spk_hex: &str) -> String {
    sha256::Hash::hash(&Vec::<u8>::from_hex(spk_hex).unwrap())
        .to_byte_array()
        .to_hex()
}

fn status(height: Option<u32>) -> Json {
    match height {
        Some(h) => json!({"confirmed": true, "block_height": h}),
        None => json!({"confirmed": false}),
    }
}

/// A node transaction in Esplora's shape: the fields Ambra reads.
fn esplora_tx(tx: &Json, height: Option<u32>) -> Json {
    let vout: Vec<Json> = tx["vout"]
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
    json!({"txid": tx["txid"], "vout": vout, "status": status(height)})
}

fn route(port: u16, method: &str, path: &str, body: &str) -> (&'static str, String) {
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    match (method, parts.as_slice()) {
        ("GET", ["blocks", "tip", "height"]) => (
            "200 OK",
            try_rpc(port, "getblockcount", json!([]))
                .unwrap()
                .to_string(),
        ),
        ("POST", ["tx"]) => match try_rpc(port, "sendrawtransaction", json!([body.trim()])) {
            Ok(id) => ("200 OK", id.as_str().unwrap().to_string()),
            Err(e) => ("400 Bad Request", e),
        },
        ("GET", ["tx", txid, "outspend", vout]) => {
            let vout: u32 = vout.parse().unwrap();
            let spent = chain_txs(port).iter().any(|(tx, _)| {
                tx["vin"].as_array().unwrap().iter().any(|i| {
                    i["txid"].as_str() == Some(txid) && i["vout"].as_u64() == Some(vout as u64)
                })
            });
            ("200 OK", json!({"spent": spent}).to_string())
        }
        ("GET", ["scripthash", hash, rest @ ..]) => {
            let txs = chain_txs(port);
            // (txid, vout) -> (script hash, value, asset, height)
            type Output = (String, Json, Json, Option<u32>);
            let mut outputs: BTreeMap<(String, u64), Output> = BTreeMap::new();
            let mut spent: BTreeSet<(String, u64)> = BTreeSet::new();
            for (tx, h) in &txs {
                let txid = tx["txid"].as_str().unwrap().to_string();
                for o in tx["vout"].as_array().unwrap() {
                    let spk = o["scriptPubKey"]["hex"].as_str().unwrap_or("");
                    outputs.insert(
                        (txid.clone(), o["n"].as_u64().unwrap()),
                        (
                            script_hash_of(spk),
                            json!(atoms(&o["value"])),
                            o["asset"].clone(),
                            *h,
                        ),
                    );
                }
                for i in tx["vin"].as_array().unwrap() {
                    if let (Some(t), Some(n)) = (i["txid"].as_str(), i["vout"].as_u64()) {
                        spent.insert((t.to_string(), n));
                    }
                }
            }
            match rest {
                ["utxo"] => {
                    let list: Vec<Json> = outputs
                        .iter()
                        .filter(|(k, (sh, ..))| sh == hash && !spent.contains(*k))
                        .map(|((t, n), (_, v, a, h))| {
                            json!({"txid": t, "vout": n, "value": v, "asset": a, "status": status(*h)})
                        })
                        .collect();
                    ("200 OK", Json::Array(list).to_string())
                }
                ["txs"] | ["txs", "chain", _] => {
                    let touches = |tx: &Json| {
                        let txid = tx["txid"].as_str().unwrap();
                        tx["vout"].as_array().unwrap().iter().any(|o| {
                            outputs
                                .get(&(txid.to_string(), o["n"].as_u64().unwrap()))
                                .map(|x| &x.0)
                                == Some(&hash.to_string())
                        }) || tx["vin"].as_array().unwrap().iter().any(|i| {
                            match (i["txid"].as_str(), i["vout"].as_u64()) {
                                (Some(t), Some(n)) => {
                                    outputs.get(&(t.to_string(), n)).map(|x| &x.0)
                                        == Some(&hash.to_string())
                                }
                                _ => false,
                            }
                        })
                    };
                    let mut mempool: Vec<Json> = vec![];
                    let mut confirmed: Vec<Json> = vec![];
                    for (tx, h) in txs.iter().rev() {
                        if touches(tx) {
                            match h {
                                None => mempool.push(esplora_tx(tx, None)),
                                Some(_) => confirmed.push(esplora_tx(tx, *h)),
                            }
                        }
                    }
                    let page: Vec<Json> = match rest {
                        ["txs", "chain", last] => confirmed
                            .iter()
                            .skip_while(|t| t["txid"].as_str() != Some(last))
                            .skip(1)
                            .take(25)
                            .cloned()
                            .collect(),
                        _ => mempool
                            .into_iter()
                            .chain(confirmed.into_iter().take(25))
                            .collect(),
                    };
                    ("200 OK", Json::Array(page).to_string())
                }
                _ => ("404 Not Found", String::new()),
            }
        }
        _ => ("404 Not Found", String::new()),
    }
}

// --- the wallet -----------------------------------------------------------------

fn random_key() -> (SecretKey, Vec<u8>) {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).unwrap();
    let sk = SecretKey::from_slice(&bytes).unwrap();
    let pk = PublicKey::from_secret_key(&Secp256k1::new(), &sk);
    (sk, pk.serialize().to_vec())
}

fn wif(sk: &SecretKey) -> String {
    let inner = lwk_wollet::bitcoin::secp256k1::SecretKey::from_slice(&sk.secret_bytes()).unwrap();
    lwk_wollet::bitcoin::PrivateKey::new(inner, lwk_wollet::bitcoin::NetworkKind::Test).to_wif()
}

fn hex_of(tx: &Transaction) -> String {
    serialize(tx).to_hex()
}

fn decode(raw: &str) -> Transaction {
    deserialize(&Vec::<u8>::from_hex(raw).unwrap()).unwrap()
}

fn explicit(asset: AssetId, value: u64, spk: Script) -> TxOut {
    TxOut {
        asset: Asset::Explicit(asset),
        value: Value::Explicit(value),
        nonce: Nonce::Null,
        script_pubkey: spk,
        witness: TxOutWitness::default(),
    }
}

fn chain_args(producer_pub: &[u8], extra: &[String]) -> Vec<String> {
    let mut args: Vec<String> = [
        "-con_pos=1",
        "-posvrf=1",
        "-posslotinterval=1",
        "-signblockscript=51",
        "-initialfreecoins=2100000000000000",
        "-anyonecanspendaremine=0",
        "-con_blocksubsidy=0",
        "-con_connect_genesis_outputs=1",
        "-validatepegin=0",
        "-con_default_blinded_addresses=0",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    args.push(format!("-posunbonding={UNBONDING}"));
    args.push(format!("-staker={}:{}", producer_pub.to_hex(), COIN));
    args.extend(extra.iter().cloned());
    args
}

/// Ambra's wallet on the node's chain: its descriptor, its signer, its staking
/// key, and the explorer it talks to.
struct Ambra {
    chain: StakeChain,
    signer: SwSigner,
    wollet: Wollet,
    staker_secret: SecretKey,
    staker: Vec<u8>,
    esplora: String,
}

impl Ambra {
    fn new(node: &Node, records_v2_height: u32, esplora: String) -> Ambra {
        let asset = AssetId::from_str(
            node.rpc("getsidechaininfo", json!([]))["pegged_asset"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        let genesis =
            BlockHash::from_str(node.rpc("getblockhash", json!([0])).as_str().unwrap()).unwrap();
        let network = Network::CustomElements(
            ElementsParamsBuilder::new()
                .with_policy_asset(asset)
                .with_genesis_hash(genesis)
                .build()
                .unwrap(),
        );
        let desc = ambra_core::descriptor_from_mnemonic(MNEMONIC).unwrap();
        let mut wollet = WolletBuilder::new(network, WolletDescriptor::from_str(&desc).unwrap())
            .build()
            .unwrap();
        register_scripts(&mut wollet);
        let staker_secret = staking::staker_secret(MNEMONIC).unwrap();
        let staker = staking::public_bytes(&staker_secret);
        assert_eq!(
            staker.to_hex(),
            ambra_core::api::staker_public_key(MNEMONIC.to_string()).unwrap(),
            "the key the app shows is the key it signs with"
        );
        Ambra {
            chain: StakeChain {
                network,
                records_v2_height,
            },
            signer: SwSigner::new(MNEMONIC, false).unwrap(),
            wollet,
            staker_secret,
            staker,
            esplora,
        }
    }

    fn asset(&self) -> AssetId {
        self.chain.asset()
    }

    fn address_spk(&self, index: u32) -> Script {
        self.wollet
            .address(Some(index))
            .unwrap()
            .address()
            .to_unconfidential()
            .script_pubkey()
    }

    /// Build, sign and finalize a wallet transaction on the PSET path, as the
    /// app's review-and-sign flow does.
    fn pset_tx(&mut self, builder: TxBuilder) -> Transaction {
        let mut pset = builder
            .fee_rate(Some(FEE_RATE))
            .finish(&self.wollet)
            .unwrap();
        self.signer.sign(&mut pset).unwrap();
        self.wollet.finalize(&mut pset).unwrap()
    }

    fn applied(&mut self, tx: &Transaction) {
        self.wollet.apply_transaction(tx.clone()).unwrap();
    }

    fn find(&self, probes: &[&[u8]]) -> Option<DelegationRecord> {
        let history = staking::records_in_wallet_history(&self.wollet, &self.staker).unwrap();
        staking::find_delegation_from(
            &self.esplora,
            &self.staker,
            history,
            probes.iter().map(|p| p.to_hex()).collect(),
        )
        .unwrap()
    }

    /// The same record spend Ambra builds, signed with `signing` regardless of
    /// the height: the wrong-generation twin a negative case needs.
    fn spend_signed(
        &self,
        rec: &DelegationRecord,
        rotate_to: Option<Vec<u8>>,
        reclaim_spk: Script,
        signing: StakeRecordSigning,
        locktime: u32,
    ) -> Transaction {
        let (raw, _) = build_delegation_spend_tx(&DelegationSpendPlan {
            record_txid: Txid::from_str(&rec.txid).unwrap(),
            record_vout: rec.vout,
            record_value: rec.value,
            asset: self.asset(),
            current_signer: Vec::<u8>::from_hex(&rec.signer).unwrap(),
            controller_secret: self.staker_secret,
            rotate_to,
            reclaim_spk,
            fee_atoms: staking::DELEGATION_SPEND_FEE_ATOMS,
            dust_floor: staking::DUST_FLOOR,
            locktime,
            signing,
        })
        .unwrap();
        decode(&raw)
    }
}

/// Teach the wallet its first scripts, which a scan of a blockchain backend
/// would; the test then hands it each transaction it makes or receives.
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

/// Fund the wallet from the genesis output, then put the node on its default
/// relay policy and point the explorer at it.
fn fund(node: &mut Node, ambra: &mut Ambra, producer_wif: &str) {
    node.produce(producer_wif);
    let genesis = node.rpc("getblock", json!([node.rpc("getblockhash", json!([0])), 2]));
    let (txid, vout, value) = genesis["tx"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|tx| {
            tx["vout"].as_array().unwrap().iter().map(move |o| {
                (
                    tx["txid"].as_str().unwrap().to_string(),
                    o["n"].as_u64().unwrap() as u32,
                    o["scriptPubKey"]["hex"].as_str().unwrap().to_string(),
                    atoms(&o["value"]).unwrap_or(0),
                )
            })
        })
        .find(|(_, _, spk, v)| spk == "51" && *v > 0)
        .map(|(t, n, _, v)| (Txid::from_str(&t).unwrap(), n, v))
        .expect("an OP_TRUE genesis output");
    let asset = ambra.asset();
    let fee = 100_000;
    let tx = Transaction {
        version: 2,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: OutPoint::new(txid, vout),
            is_pegin: false,
            script_sig: Script::new(),
            sequence: Sequence::from_consensus(0xffff_fffe),
            asset_issuance: Default::default(),
            witness: TxInWitness::default(),
        }],
        output: vec![
            explicit(asset, 200 * COIN, ambra.address_spk(0)),
            explicit(asset, 200 * COIN, ambra.address_spk(1)),
            explicit(asset, value - 400 * COIN - fee, Script::from(vec![0x51])),
            TxOut::new_fee(fee, asset),
        ],
    };
    let id = node.send(&hex_of(&tx));
    assert!(node.produce(producer_wif).contains(&id));
    ambra.applied(&tx);
    node.restart_with_default_policy();
    ambra.esplora = serve_explorer(node.port);
}

/// Bond 50 coins to Ambra's staking key, through the wallet's PSET path.
fn bond(node: &Node, ambra: &mut Ambra, producer: &str) {
    let staker = ambra.staker.clone();
    let tx = ambra.pset_tx(TxBuilder::new(ambra.chain.network).add_stake_output(
        &staker,
        UNBONDING,
        50 * COIN,
    ));
    let id = node.send(&hex_of(&tx));
    assert!(node.produce(producer).contains(&id));
    ambra.applied(&tx);
    assert!(tx
        .output
        .iter()
        .any(|o| o.script_pubkey == sequentia_stake_script(&staker, UNBONDING)));
    println!("bond {id} in block {}", node.tip());
}

/// Ambra's join: the wallet pays the staking key, and the record is created
/// from that coin, both through the explorer. Returns (payment, record txid).
fn join(node: &Node, ambra: &mut Ambra, producer: &str, pool: &[u8]) -> (Transaction, Txid) {
    let staker = ambra.staker.clone();
    let pay = ambra.pset_tx(staking::add_delegation_authorization(
        TxBuilder::new(ambra.chain.network),
        &staker,
    ));
    let record = staking::join_with_signed(
        &ambra.chain,
        &ambra.esplora,
        &pay,
        &ambra.staker_secret,
        pool,
        ambra.address_spk(6),
    )
    .unwrap();
    let record = Txid::from_str(&record).unwrap();
    let block = node.produce(producer);
    assert!(
        block.contains(&pay.txid()) && block.contains(&record),
        "mined together"
    );
    ambra.applied(&pay);
    assert_eq!(node.delegation_of(&staker), Some(pool.to_hex()));
    let raw = node
        .rpc("getrawtransaction", json!([record.to_string()]))
        .as_str()
        .unwrap()
        .to_string();
    println!(
        "join: payment {} and record {record} in block {} (record tx {} vB, fee {} atoms)",
        pay.txid(),
        node.tip(),
        node.vsize(&raw),
        staking::DELEGATION_CREATE_FEE_ATOMS
    );
    (pay, record)
}

/// Ambra's move or leave, built for the explorer's tip and broadcast through
/// it. Returns the txid and the signing it chose.
fn spend(
    node: &Node,
    ambra: &Ambra,
    producer: &str,
    rotate_to: Option<Vec<u8>>,
    what: &str,
) -> (Txid, StakeRecordSigning) {
    let rec = ambra
        .find(&[&current_signer(node, ambra)])
        .expect("delegating");
    let signing = ambra.chain.signing_after(node.tip()).unwrap();
    let (raw, id) = staking::spend_delegation(
        &ambra.chain,
        &ambra.esplora,
        &rec,
        &ambra.staker_secret,
        rotate_to,
        ambra.address_spk(7),
    )
    .unwrap();
    assert_eq!(
        staking::broadcast(&ambra.esplora, &raw).unwrap(),
        id.to_string()
    );
    assert!(node.produce(producer).contains(&id));
    println!(
        "{what} {id} in block {} signed {signing:?} ({} vB, fee {} atoms)",
        node.tip(),
        node.vsize(&raw),
        staking::DELEGATION_SPEND_FEE_ATOMS
    );
    (id, signing)
}

fn current_signer(node: &Node, ambra: &Ambra) -> Vec<u8> {
    node.delegation_of(&ambra.staker)
        .map(|s| Vec::<u8>::from_hex(&s).unwrap())
        .unwrap_or_default()
}

#[test]
fn records_from_block_one() {
    let (producer_sk, producer_pub) = random_key();
    let producer = wif(&producer_sk);
    let mut node = Node::start(
        "ambra_stake_records_block_one",
        chain_args(&producer_pub, &[]),
    );
    let mut ambra = Ambra::new(&node, 1, String::new());
    fund(&mut node, &mut ambra, &producer);
    bond(&node, &mut ambra, &producer);
    let staker = ambra.staker.clone();
    let (_, pool_p) = random_key();
    let (_, pool_q) = random_key();

    // The join the app built before: a record paid from wallet coins alone.
    let old_join = ambra.pset_tx(TxBuilder::new(ambra.chain.network).add_delegation_output(
        &staker,
        &pool_p,
        staking::DELEGATION_RECORD_ATOMS,
    ));
    let pay = ambra.pset_tx(staking::add_delegation_authorization(
        TxBuilder::new(ambra.chain.network),
        &staker,
    ));
    let coin = staking::authorization_coin(&ambra.chain, &pay, &staker).unwrap();
    let (create_raw, _) = staking::build_delegation_create(
        &ambra.chain,
        &coin,
        &ambra.staker_secret,
        &pool_p,
        ambra.address_spk(6),
        node.tip(),
    )
    .unwrap();
    refused_everywhere(
        &node,
        &producer,
        &old_join,
        &[pay.clone(), decode(&create_raw)],
        "record paid from wallet coins alone (the app's old join)",
        "bad-delegation-unauthorized",
        "bad-delegation-unauthorized",
    );
    // Neither was broadcast, and the wallet never applied them.

    // --- Join ----------------------------------------------------------------
    let (pay, record) = join(&node, &mut ambra, &producer, &pool_p);
    // Found with no hint at all: the record spends the coin at the staking
    // key, so its history holds it; the wallet's own history does not.
    assert!(staking::records_in_wallet_history(&ambra.wollet, &staker)
        .unwrap()
        .is_empty());
    let found = ambra
        .find(&[])
        .expect("the join is found through the staking key's history");
    assert_eq!(
        (found.txid.as_str(), found.signer.as_str(), found.confirmed),
        (record.to_string().as_str(), pool_p.to_hex().as_str(), true)
    );
    assert_eq!(found.value, staking::DELEGATION_RECORD_ATOMS);
    println!(
        "found the join with no probe: {}:{} for {}",
        found.txid, found.vout, found.signer
    );
    let _ = pay;

    // --- Move ----------------------------------------------------------------
    let rec = ambra.find(&[]).unwrap();
    let tip = node.tip();
    let signing = ambra.chain.signing_after(tip).unwrap();
    assert_eq!(signing, StakeRecordSigning::SegwitV0);
    let legacy = ambra.spend_signed(
        &rec,
        Some(pool_q.clone()),
        Script::new(),
        StakeRecordSigning::Legacy,
        tip,
    );
    let (good_raw, _) = staking::spend_delegation(
        &ambra.chain,
        &ambra.esplora,
        &rec,
        &ambra.staker_secret,
        Some(pool_q.clone()),
        Script::new(),
    )
    .unwrap();
    refused_everywhere(
        &node,
        &producer,
        &legacy,
        &[decode(&good_raw)],
        "move signed the legacy way (v2 in force)",
        &format!("script-verify-flag-failed {WRONG_HASH}"),
        &format!("script-verify-flag-failed {WRONG_HASH}"),
    );
    let (moved, _) = spend(&node, &ambra, &producer, Some(pool_q.clone()), "move");
    assert_eq!(node.delegation_of(&staker), Some(pool_q.to_hex()));
    // The move is found by probing its signer; without the hint the spent join
    // is all the histories hold, and it is spent.
    let found = ambra.find(&[&pool_q]).unwrap();
    assert_eq!(found.txid, moved.to_string());
    assert!(ambra.find(&[]).is_none());

    // --- Leave ---------------------------------------------------------------
    let (left, _) = spend(&node, &ambra, &producer, None, "leave");
    assert_eq!(node.delegation_of(&staker), None);
    assert!(ambra.find(&[&pool_p, &pool_q]).is_none());
    let _ = left;

    // --- A join finished from a coin already at the staking key ---------------
    assert_eq!(
        staking::join_with_key_coin(
            &ambra.chain,
            &ambra.esplora,
            &ambra.staker_secret,
            &pool_p,
            ambra.address_spk(8)
        )
        .unwrap(),
        None,
        "no coin at the staking key: the join starts with a payment"
    );
    let pay = ambra.pset_tx(staking::add_delegation_authorization(
        TxBuilder::new(ambra.chain.network),
        &staker,
    ));
    staking::broadcast(&ambra.esplora, &hex_of(&pay)).unwrap();
    assert!(node.produce(&producer).contains(&pay.txid()));
    ambra.applied(&pay);
    let coins = staking::key_coins(&ambra.chain, &ambra.esplora, &staker).unwrap();
    assert_eq!(coins.len(), 1);
    assert_eq!(coins[0].value, DELEGATION_AUTHORIZATION_ATOMS);
    let resumed = staking::join_with_key_coin(
        &ambra.chain,
        &ambra.esplora,
        &ambra.staker_secret,
        &pool_p,
        ambra.address_spk(8),
    )
    .unwrap()
    .expect("the coin at the staking key finishes the join");
    let resumed = Txid::from_str(&resumed).unwrap();
    assert!(node.produce(&producer).contains(&resumed));
    assert_eq!(node.delegation_of(&staker), Some(pool_p.to_hex()));
    println!(
        "payment {} alone in block {}, join finished from its coin {resumed} in block {}",
        pay.txid(),
        node.tip() - 1,
        node.tip()
    );
    assert_eq!(ambra.find(&[]).unwrap().txid, resumed.to_string());
    let _ = spend(&node, &ambra, &producer, None, "leave");
    assert_eq!(node.delegation_of(&staker), None);

    // A coin of any other value at the staking key (a split pool pays its
    // delegators there) is not taken for a join.
    let other = ambra.pset_tx(
        TxBuilder::new(ambra.chain.network)
            .add_record_authorization(&staker, 3 * DELEGATION_AUTHORIZATION_ATOMS),
    );
    staking::broadcast(&ambra.esplora, &hex_of(&other)).unwrap();
    assert!(node.produce(&producer).contains(&other.txid()));
    ambra.applied(&other);
    assert_eq!(
        staking::key_coins(&ambra.chain, &ambra.esplora, &staker)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        staking::join_with_key_coin(
            &ambra.chain,
            &ambra.esplora,
            &ambra.staker_secret,
            &pool_p,
            ambra.address_spk(8)
        )
        .unwrap(),
        None,
        "only the coin a join paid finishes a join"
    );
    println!(
        "coin of {} atoms at the staking key ({}) left alone",
        3 * DELEGATION_AUTHORIZATION_ATOMS,
        other.txid()
    );

    // --- No tip, no signature ------------------------------------------------
    let unreachable = format!("http://127.0.0.1:{}", free_port());
    let e = staking::spend_delegation(
        &ambra.chain,
        &unreachable,
        &found,
        &ambra.staker_secret,
        None,
        ambra.address_spk(9),
    )
    .unwrap_err()
    .to_string();
    println!("NEGATIVE spend with no readable tip: {e}");
    assert!(e.contains("could not read the chain's height"), "{e}");
}

#[test]
fn records_across_the_fork_height() {
    const FORK: u32 = 14;
    let (producer_sk, producer_pub) = random_key();
    let producer = wif(&producer_sk);
    let extra = [
        format!("-posrecordsv2height={FORK}"),
        format!("-poshardeningheight={FORK}"),
    ];
    let mut node = Node::start(
        "ambra_stake_records_fork",
        chain_args(&producer_pub, &extra),
    );
    let mut ambra = Ambra::new(&node, FORK, String::new());
    fund(&mut node, &mut ambra, &producer);
    bond(&node, &mut ambra, &producer);
    let staker = ambra.staker.clone();
    let (_, pool_p) = random_key();
    let (_, pool_q) = random_key();

    // The join works below the fork height as well as from it.
    join(&node, &mut ambra, &producer, &pool_p);
    assert!(
        node.tip() + 2 < FORK,
        "the move below is judged and mined below the fork"
    );

    // A move below it: legacy; the second-generation twin refused by a block.
    let rec = ambra.find(&[]).unwrap();
    let tip = node.tip();
    assert_eq!(
        ambra.chain.signing_after(tip).unwrap(),
        StakeRecordSigning::Legacy
    );
    let v2 = ambra.spend_signed(
        &rec,
        Some(pool_q.clone()),
        Script::new(),
        StakeRecordSigning::SegwitV0,
        tip,
    );
    let (good_raw, _) = staking::spend_delegation(
        &ambra.chain,
        &ambra.esplora,
        &rec,
        &ambra.staker_secret,
        Some(pool_q.clone()),
        Script::new(),
    )
    .unwrap();
    refused_everywhere(
        &node,
        &producer,
        &v2,
        &[decode(&good_raw)],
        "move signed the second-generation way below the fork",
        &format!("script-verify-flag-failed {WRONG_HASH}"),
        &format!("script-verify-flag-failed {FALSE_RESULT}"),
    );
    let (_, signing) = spend(
        &node,
        &ambra,
        &producer,
        Some(pool_q.clone()),
        "move below the fork",
    );
    assert_eq!(signing, StakeRecordSigning::Legacy);
    assert!(node.tip() < FORK);
    assert_eq!(node.delegation_of(&staker), Some(pool_q.to_hex()));

    // Up to the block before the fork height.
    while node.tip() + 2 < FORK {
        node.produce(&producer);
    }
    // At tip FORK-2 the next block is FORK-1, still legacy; judged there, the
    // chain then stands at FORK-1 and the leave is built for FORK.
    let rec = ambra.find(&[&pool_q]).unwrap();
    let tip = node.tip();
    assert_eq!(tip + 1, FORK - 1);
    let legacy_at_fork = ambra.spend_signed(
        &rec,
        None,
        ambra.address_spk(7),
        StakeRecordSigning::Legacy,
        tip,
    );
    node.produce(&producer);
    assert_eq!(node.tip() + 1, FORK);
    assert_eq!(
        ambra.chain.signing_after(node.tip()).unwrap(),
        StakeRecordSigning::SegwitV0
    );
    let (good_raw, _) = staking::spend_delegation(
        &ambra.chain,
        &ambra.esplora,
        &rec,
        &ambra.staker_secret,
        None,
        ambra.address_spk(7),
    )
    .unwrap();
    refused_everywhere(
        &node,
        &producer,
        &legacy_at_fork,
        &[decode(&good_raw)],
        "leave signed the legacy way in the first block at the fork",
        &format!("script-verify-flag-failed {WRONG_HASH}"),
        &format!("script-verify-flag-failed {WRONG_HASH}"),
    );
    let (_, signing) = spend(&node, &ambra, &producer, None, "leave from the fork");
    assert_eq!(signing, StakeRecordSigning::SegwitV0);
    assert!(node.tip() >= FORK);
    assert_eq!(node.delegation_of(&staker), None);
}
