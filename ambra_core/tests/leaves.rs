//! The leaf service against a whole operator: a payment that arrives while the app
//! is closed, an in-tree swap between two wallets, what `care` does by itself, and a
//! payment out of planned coins made through a release. Runs against arca's long-running operator harness
//! (`bark-cli/tests/arca_operator_for_browsers.rs` in ConcatenaLabs/arca), named by
//! its control address:
//!
//! ```sh
//! AMBRA_LEAVES_HARNESS=http://127.0.0.1:18640 cargo test --test leaves -- --nocapture
//! ```
//!
//! Without `AMBRA_LEAVES_HARNESS` the test says so and passes without running.
//!
//! The app's wallet (A) joins the operator, hands out a receive request and is
//! closed. A second wallet (B, the payer) boards on-chain coins and pays the
//! request. The scheduled job's pass then opens A from its store, syncs, and
//! reports the coin as arrived with the time to wake next; A, opened again as the
//! app opens it, shows the leaf in its balance. Paying the same request twice is
//! refused in the library's words.

use std::path::PathBuf;

use ambra_core::leaves::{self, LeafWallet};
use serde_json::{json, Value};

/// The well-known BIP39 test vectors; nothing here holds value.
const APP: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const PAYER: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";

fn control(base: &str, path: &str, body: Value) -> Value {
    let c = reqwest::blocking::Client::new();
    let r = if path == "/state" {
        c.get(format!("{}{}", base, path)).send()
    } else {
        c.post(format!("{}{}", base, path)).json(&body).send()
    }
    .unwrap_or_else(|e| panic!("harness {}: {}", path, e));
    let v: Value = r.json().expect("harness answers JSON");
    v
}

fn dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("ambra-leaves-it-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn ok(r: Result<Value, Value>, what: &str) -> Value {
    r.unwrap_or_else(|e| panic!("{}: {}", what, e))
}

#[test]
fn a_payment_arrives_while_the_app_is_closed() {
    let Ok(h) = std::env::var("AMBRA_LEAVES_HARNESS") else {
        eprintln!("AMBRA_LEAVES_HARNESS is not set: the operator harness is not running, nothing to test against");
        return;
    };
    let state = control(&h, "/state", json!({}));
    let x = state["x"].as_str().unwrap().to_string();
    let config = json!({
        "server": state["server"], "node_url": state["node_url"],
        "node_user": state["node_user"], "node_password": state["node_password"],
        // The harness's leaves have exit delays from one 512-second unit.
        "exit_delay_units": 3, "min_exit_delay_units": 1, "max_exit_delay_units": 400,
    });
    let password = state["node_password"].as_str().map(String::from);

    // B, the payer: board 1,000,000 X.
    let bdir = dir("payer");
    let mut b = LeafWallet::create(&bdir, PAYER, &config).expect("the payer's wallet");
    let addr = ok(b.run("address", &json!({})), "address")["result"].clone();
    control(&h, "/fund", json!({"script": addr["script_pubkey"], "asset": x, "amount": 3_000_000}));
    control(&h, "/produce", json!({}));
    let board = ok(b.run("board", &json!({"asset": x, "amount": "1000000"})), "board");
    eprintln!("board: {}", board["result"]);
    control(&h, "/produce", json!({}));
    control(&h, "/bury", json!({}));
    ok(b.run("sync", &json!({})), "payer sync");
    let coins = ok(b.run("coins", &json!({})), "coins")["result"].clone();
    eprintln!("payer coins: {}", coins);
    assert!(coins.as_array().unwrap().iter().any(|c| c["state"] == "live"), "the payer holds a live leaf");

    // A, the app: join, hand out a request, close.
    let adir = dir("app");
    let joined = ok(leaves::start(&adir, APP, Some(&config), None), "join");
    assert_eq!(joined["created"], true);
    // Joining restores whatever the operator holds for this mnemonic (an earlier
    // run against the same harness included): the payment is counted on top.
    let restored = ok(leaves::run("restore", &json!({})), "restore")["result"].clone();
    eprintln!("restore: served {} restored {}", restored["served"], restored["restored"]);
    let held = |b: &Value| b["arca"][&x]["operator-confirmed"].as_str().map_or(0, |v| v.parse::<u64>().unwrap());
    let before_balance = held(&ok(leaves::run("balance", &json!({})), "balance")["result"]);
    let req = ok(leaves::run("receive", &json!({"asset": x, "amount": "300000"})), "receive")["result"].clone();
    let request = req["request"].as_str().unwrap().to_string();
    eprintln!("request: {}…", &request[..40.min(request.len())]);
    assert!(request.starts_with("request:"), "the request carries no command line's prefix");
    let before = ok(leaves::run("schedule", &json!({})), "schedule")["result"].clone();
    eprintln!("schedule with the request open: next_sync_at {} now {} why {}", before["next_sync_at"], before["now"], before["why"]);
    leaves::stop();
    assert!(!leaves::is_open(), "the app is closed");

    // B pays the request while A is closed.
    let sent = ok(b.run("send", &json!({"request": request})), "send");
    eprintln!("send: {}", sent["result"]);

    // Paying it again is refused in the library's words.
    let again = b.run("send", &json!({"request": request})).expect_err("a second payment of one request");
    eprintln!("second payment refused: {}", again);
    assert_eq!(again["error"]["code"], "key_reused");

    // The scheduled job's pass.
    let pass = ok(leaves::job(&adir, APP, password.clone(), None), "the job's pass");
    eprintln!("job: arrived {} wake_in {} opened_for_the_job {}", pass["arrived"], pass["wake_in"], pass["opened_for_the_job"]);
    let arrived = pass["arrived"].as_array().unwrap();
    assert_eq!(arrived.len(), 1, "one coin arrived");
    assert_eq!(arrived[0]["value"].to_string().trim_matches('"'), "300000");
    assert_eq!(arrived[0]["asset"], json!(x));
    assert_eq!(pass["opened_for_the_job"], true);
    let wake = pass["wake_in"].as_u64().expect("a coin is held off the chain: the job wakes again");
    assert!(wake <= leaves::DAILY, "never more than a day while a coin is off the chain");

    // The app opens again: the balance shows the leaf.
    ok(leaves::start(&adir, APP, None, password), "open");
    let bal = ok(leaves::run("balance", &json!({})), "balance")["result"].clone();
    eprintln!("balance on next open: {}", bal["arca"]);
    assert_eq!(held(&bal), before_balance + 300_000, "the leaf received while closed is in the balance");
    // A second pass finds nothing new.
    // A second pass finds nothing new; with care's arguments it runs care too, as
    // the app asks when care is due.
    let pass2 = ok(leaves::job(&adir, APP, None, Some(&json!({"scan": 20}))), "second pass");
    assert_eq!(pass2["arrived"], json!([]));
    assert_eq!(pass2["opened_for_the_job"], false, "the open wallet is used, not opened twice");
    let care = &pass2["care"];
    eprintln!("care in the job's pass: {}", care);
    for k in ["claims", "cancelled", "planned", "refreshing", "not_yet_planned", "plan_within", "max_fee_ppm"] {
        assert!(care.get(k).is_some(), "care answers {k}: {care}");
    }
    let pass3 = ok(leaves::job(&adir, APP, None, None), "a pass with care not due");
    assert_eq!(pass3["care"], Value::Null, "care runs only when the app asks");
    leaves::stop();
    drop(b);
    let _ = std::fs::remove_dir_all(&adir);
    let _ = std::fs::remove_dir_all(&bdir);
}

/// Two wallets swap two assets in the tree through the core, as the swap screen's leaf
/// panel runs it: the maker's offer holds its coin, the taker's read shows what it gives,
/// gets and pays, the acceptance carries those terms, and the maker completes it.
#[test]
fn two_wallets_swap_in_the_tree_through_the_core() {
    let Ok(h) = std::env::var("AMBRA_LEAVES_HARNESS") else {
        eprintln!("AMBRA_LEAVES_HARNESS is not set: the operator harness is not running, nothing to test against");
        return;
    };
    let state = control(&h, "/state", json!({}));
    let (x, y) = (state["x"].as_str().unwrap().to_string(), state["y"].as_str().unwrap().to_string());
    let config = json!({
        "server": state["server"], "node_url": state["node_url"],
        "node_user": state["node_user"], "node_password": state["node_password"],
        "exit_delay_units": 3, "min_exit_delay_units": 1, "max_exit_delay_units": 400,
    });
    let live = |w: &mut LeafWallet, asset: &str| -> u64 {
        let b = ok(w.run("balance", &json!({})), "balance")["result"].clone();
        b["arca"][asset].as_object().map(|m| m.values().filter_map(|v| v.as_str()?.parse::<u64>().ok()).sum()).unwrap_or(0)
    };
    let board = |w: &mut LeafWallet, funds: &[(&str, u64)], asset: &str, fee: &str| {
        let addr = ok(w.run("address", &json!({})), "address")["result"].clone();
        for (a, v) in funds {
            control(&h, "/fund", json!({"script": addr["script_pubkey"], "asset": a, "amount": v}));
        }
        control(&h, "/produce", json!({}));
        ok(w.run("board", &json!({"asset": asset, "amount": "2000000", "fee_asset": fee})), "board");
    };
    let mut a = LeafWallet::create(&dir("swap-maker"), "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong", &config).expect("the maker's wallet");
    let mut b = LeafWallet::create(&dir("swap-taker"), "letter advice cage absurd amount doctor acoustic avoid letter advice cage above", &config)
        .expect("the taker's wallet");
    board(&mut a, &[(&x, 3_000_000)], &x, &x);
    board(&mut b, &[(&y, 3_000_000), (&x, 500_000)], &y, &x);
    control(&h, "/produce", json!({}));
    control(&h, "/bury", json!({}));
    for _ in 0..60 {
        ok(a.run("sync", &json!({})), "maker sync");
        ok(b.run("sync", &json!({})), "taker sync");
        if live(&mut a, &x) >= 2_000_000 && live(&mut b, &y) >= 2_000_000 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    let (ax, bx, by) = (live(&mut a, &x), live(&mut b, &x), live(&mut b, &y));

    let offer = ok(a.run("swap_offer", &json!({"give_asset": x, "give": "300000", "want_asset": y, "want": "400000"})), "offer")["result"].clone();
    let text = offer["offer"].as_str().unwrap().to_string();
    let read = ok(b.run("swap_read", &json!({"offer": text})), "read")["result"].clone();
    eprintln!("read: gets {} gives {} pays {}", read["gets"], read["gives"], read["pays"]);
    assert_eq!(read["gets"], json!({"asset": x, "value": "300000"}));
    let mut wrong = read.clone();
    wrong["gives"]["value"] = json!("399999");
    let e = b.run("swap_accept", &json!({"offer": text, "shown": wrong})).expect_err("terms other than those shown");
    eprintln!("refused: {}", leaves::refusal_message(&e));
    assert!(leaves::refusal_message(&e).contains("the swap's terms changed since they were shown"));
    let acc = ok(b.run("swap_accept", &json!({"offer": text, "shown": read})), "accept")["result"].clone();
    ok(a.run("swap_complete", &json!({"accept": acc["accept"]})), "complete");
    ok(b.run("mailbox", &json!({})), "taker mailbox");
    let paid: u64 = read["pays"]["margins"].as_str().unwrap().parse().unwrap();
    assert_eq!(live(&mut b, &x) - bx, 300_000, "the taker got what it was offered");
    assert_eq!(by - live(&mut b, &y), 400_000 + paid, "the taker gave what it wanted and the margins it was shown");
    assert_eq!(live(&mut a, &y), 400_000, "the maker got what it wanted");
    let mp = offer["pays"]["margin"].as_str().unwrap().parse::<u64>().unwrap() + offer["pays"]["margins"].as_str().unwrap().parse::<u64>().unwrap();
    assert_eq!(ax - live(&mut a, &x), 300_000 + mp, "the maker gave what it offered and the margins it was shown");
}

/// `care`, what the app runs by itself at a sync: a claim of a distribution named by
/// a key of the main wallet's address at index 25 is not found within the leaf
/// wallet's own counter plus 20, and is taken up with no prompt once the scan reaches
/// 20 past the main wallet's next index; the coin it gives is planned once its step
/// window comes within ten days, and the plan can be cancelled (developer mode's
/// Cancel).
#[test]
fn care_takes_up_a_claim_and_plans_its_coin() {
    let Ok(h) = std::env::var("AMBRA_LEAVES_HARNESS") else {
        eprintln!("AMBRA_LEAVES_HARNESS is not set: the operator harness is not running, nothing to test against");
        return;
    };
    const DISTRIBUTOR: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";
    const HOLDER: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
    let state = control(&h, "/state", json!({}));
    let x = state["x"].as_str().unwrap().to_string();
    let config = json!({
        "server": state["server"], "node_url": state["node_url"],
        "node_user": state["node_user"], "node_password": state["node_password"],
        "exit_delay_units": 3, "min_exit_delay_units": 1, "max_exit_delay_units": 400,
    });

    // The holder's key: its main wallet's receive address at index 25 (m/84'/1'/0'/0/25),
    // past the 20 the leaf wallet looks at by itself.
    use lwk_common::Signer as _;
    let signer = lwk_signer::SwSigner::new(HOLDER, false).unwrap();
    let path: lwk_wollet::bitcoin::bip32::DerivationPath = "m/84'/1'/0'/0/25".parse().unwrap();
    let key = signer.derive_xpub(&path).unwrap().public_key.to_string();

    // The distributor boards 2,000,000 X and names the key for 500,000.
    let ddir = dir("distributor");
    let mut d = LeafWallet::create(&ddir, DISTRIBUTOR, &config).expect("the distributor's wallet");
    let addr = ok(d.run("address", &json!({})), "address")["result"].clone();
    control(&h, "/fund", json!({"script": addr["script_pubkey"], "asset": x, "amount": 3_000_000}));
    control(&h, "/produce", json!({}));
    ok(d.run("board", &json!({"asset": x, "amount": "2000000"})), "board");
    control(&h, "/produce", json!({}));
    control(&h, "/bury", json!({}));
    ok(d.run("sync", &json!({})), "distributor sync");
    let claims = json!([{"key": key, "amount": 500000}]);
    let quote = ok(d.run("distribute_quote", &json!({"asset": x, "claims": claims})), "quote")["result"].clone();
    eprintln!("distribution quote: {}", quote);
    let fee = quote["fee"].as_str().map(|s| s.parse::<u64>().unwrap()).or_else(|| quote["fee"].as_u64()).unwrap();
    let dist = ok(d.run("distribute", &json!({"asset": x, "claims": claims, "shown": fee})), "distribute")["result"].clone();
    eprintln!("distribution: {}", dist);
    let round = control(&h, "/round", json!({}));
    eprintln!("round: {}", round);
    ok(d.run("sync", &json!({})), "distributor sync after the round");
    eprintln!("distributions: {}", ok(d.run("distributions", &json!({})), "distributions")["result"]);

    // The holder joins with a new leaf wallet.
    let hdir = dir("holder");
    ok(leaves::start(&hdir, HOLDER, Some(&config), None), "the holder joins");
    let alone = ok(leaves::run("care", &json!({})), "care without a scan")["result"].clone();
    eprintln!("care, the leaf wallet's own counter: {}", alone);
    assert_eq!(alone["claims"], json!([]), "index 25 is past the leaf wallet's own 20");
    // The app scans 20 past the main wallet's next index; say it handed out 26.
    let care = ok(leaves::run("care", &json!({"scan": 26 + 20})), "care")["result"].clone();
    eprintln!("care, scan 46: {}", care);
    let id = dist["distribution"].as_str().unwrap().to_string();
    let taken: Vec<&Value> = care["claims"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["claim"].as_str().is_some_and(|n| n.starts_with(&id)))
        .collect();
    assert_eq!(taken.len(), 1, "{care}");
    assert!(taken[0]["taken_up"].is_object() && taken[0].get("error").is_none(), "{care}");
    let coin = taken[0]["taken_up"]["kept"][0]["leaf_id"].as_str().unwrap().to_string();
    let bal = ok(leaves::run("balance", &json!({})), "balance")["result"].clone();
    eprintln!("holder's balance: {}", bal["arca"]);

    // The coin a claim gives is out of round, which no plan can start from: once its
    // step window is within ten days, care asks its refresh in a round; the round's
    // new leaf is planned by a later care, once within ten days in its turn.
    let until = |what: &str, key: &str| -> Value {
        for step in 0..30 {
            let c = ok(leaves::run("care", &json!({"scan": 46})), "care")["result"].clone();
            if !c[key].as_array().unwrap().is_empty() {
                eprintln!("care, {what}, after {} days on: {}", 2 * step, c);
                return c;
            }
            control(&h, "/advance", json!({"seconds": 2 * 86_400}));
            control(&h, "/produce", json!({}));
        }
        panic!("care never {what}");
    };
    let refreshing = until("refreshing the claimed coin", "refreshing");
    let r = &refreshing["refreshing"][0];
    assert_eq!(r["coin"], json!(coin));
    assert!(r["error"].is_null(), "{refreshing}");
    let live = |v: &Value| -> Vec<String> {
        v.as_array().unwrap().iter().filter(|c| c["state"] == "live").map(|c| c["leaf_id"].as_str().unwrap().to_string()).collect()
    };
    let before = live(&ok(leaves::run("coins", &json!({})), "coins")["result"]);
    let round = control(&h, "/round", json!({}));
    eprintln!("refresh round: {}", round);
    ok(leaves::run("sync", &json!({})), "the holder's sync takes the refresh up");
    let after = live(&ok(leaves::run("coins", &json!({})), "coins")["result"]);
    let fresh = after.iter().find(|c| !before.contains(c)).expect("the refreshed leaf").clone();
    assert!(!after.contains(&coin), "the coin out of round is spent into the round");
    assert_ne!(fresh, coin, "a leaf of the round in place of the coin out of round");
    let planned = until("planning the refreshed leaf", "planned");
    let p = &planned["planned"][0];
    assert!(p.get("error").is_none(), "the coin is planned: {planned}");
    let plans = ok(leaves::run("plans", &json!({})), "plans")["result"].clone();
    eprintln!("plans: {}", plans);
    let plan = plans["plans"].as_array().unwrap().iter().find(|p| p["coin"] == json!(fresh)).expect("a plan names the refreshed leaf");
    assert_eq!(plan["state"], "open");
    let again = ok(leaves::run("care", &json!({"scan": 46})), "care again")["result"].clone();
    assert_eq!(again["planned"], json!([]), "a planned coin is not planned twice: {again}");
    let cancelled = ok(leaves::run("plan_cancel", &json!({"plan": plan["plan_id"]})), "plan_cancel")["result"].clone();
    eprintln!("cancel: {}", cancelled);
    leaves::stop();
    drop(d);
    let _ = std::fs::remove_dir_all(&ddir);
    let _ = std::fs::remove_dir_all(&hdir);
}

/// A fresh recovery phrase, so a run against a harness that served earlier runs starts
/// from no leaves.
fn fresh_phrase() -> String {
    lwk_signer::SwSigner::random(false).expect("a random phrase").1.to_string()
}

/// The harness's operator and node as a leaf wallet's configuration.
fn harness_config(state: &Value) -> Value {
    json!({
        "server": state["server"], "node_url": state["node_url"],
        "node_user": state["node_user"], "node_password": state["node_password"],
        "exit_delay_units": 3, "min_exit_delay_units": 1, "max_exit_delay_units": 400,
    })
}

/// A new wallet that boards `amount` of `asset` (funding its on-chain address with that
/// and 500,000 X for the fee), its board final.
fn boarded(h: &str, name: &str, config: &Value, x: &str, asset: &str, amount: u64) -> (LeafWallet, PathBuf) {
    let d = dir(name);
    let mut w = LeafWallet::create(&d, &fresh_phrase(), config).expect("a wallet");
    let addr = ok(w.run("address", &json!({})), "address")["result"].clone();
    control(h, "/fund", json!({"script": addr["script_pubkey"], "asset": asset, "amount": amount + 1_000_000}));
    if asset != x {
        control(h, "/fund", json!({"script": addr["script_pubkey"], "asset": x, "amount": 500_000}));
    }
    control(h, "/produce", json!({}));
    let b = ok(w.run("board", &json!({"asset": asset, "amount": amount.to_string(), "fee_asset": x})), "board");
    eprintln!("{name} board: {}", b["result"]);
    control(h, "/produce", json!({}));
    control(h, "/bury", json!({}));
    ok(w.run("sync", &json!({})), "sync after the board");
    (w, d)
}

/// The wallet's coins in a state.
fn coins_in(w: &mut LeafWallet, state: &str) -> Vec<Value> {
    ok(w.run("coins", &json!({})), "coins")["result"].as_array().unwrap().iter().filter(|c| c["state"] == state).cloned().collect()
}

/// A payment out of planned coins (the app's `payThroughRelease`, its steps run here
/// one by one): `care` with `plan_within` at PLAN_EVERY_ROUND_LEAF plans a leaf of a
/// round at its first run; a payment the unplanned coins cannot cover is refused with
/// kind `planned`, naming the asset and the coins whose release covers it;
/// `plan_release` gives them up in the next round; once that round is final and the
/// released coins are gone, the same payment goes through.
#[test]
fn a_payment_out_of_planned_coins_goes_through_a_release() {
    let Ok(h) = std::env::var("AMBRA_LEAVES_HARNESS") else {
        eprintln!("AMBRA_LEAVES_HARNESS is not set: the operator harness is not running, nothing to test against");
        return;
    };
    let state = control(&h, "/state", json!({}));
    let x = state["x"].as_str().unwrap().to_string();
    let config = harness_config(&state);
    let (mut a, adir) = boarded(&h, "planned-payer", &config, &x, &x, 1_000_000);

    // The board is a coin of no round: refreshed into a round, it becomes a leaf of one.
    let q = ok(a.run("quote", &json!({})), "quote")["result"].clone();
    ok(a.run("participate", &json!({"shown": q["coins"]})), "participate");
    eprintln!("round: {}", control(&h, "/round", json!({})));
    ok(a.run("sync", &json!({})), "sync after the round");
    let live = coins_in(&mut a, "live");
    assert_eq!(live.len(), 1, "one leaf of the round: {live:?}");
    let leaf = live[0]["leaf_id"].as_str().unwrap().to_string();

    // care, as the app runs it: the leaf of the round is planned at once.
    let care = ok(a.run("care", &json!({"plan_within": 4294967295u64})), "care")["result"].clone();
    eprintln!("care: planned {} plan_within {}", care["planned"], care["plan_within"]);
    assert!(care["planned"].as_array().unwrap().iter().any(|p| p.get("error").is_none()), "the round's leaf is planned at once: {care}");

    // B asks 500,000 X; A's only coin is planned.
    let bdir = dir("planned-payee");
    let mut b = LeafWallet::create(&bdir, &fresh_phrase(), &config).expect("the payee");
    let req = ok(b.run("receive", &json!({"asset": x, "amount": "500000"})), "receive")["result"]["request"].as_str().unwrap().to_string();
    let e = a.run("send", &json!({"request": req})).expect_err("a payment out of a planned coin");
    eprintln!("refused: {e}");
    assert_eq!(e["error"]["kind"], "planned");
    assert_eq!(e["error"]["asset"], json!(x));
    assert_eq!(e["error"]["release"], json!([leaf]));

    // The release, its round, and the same payment again.
    let r = ok(a.run("plan_release", &json!({"leaves": [leaf]})), "plan_release")["result"].clone();
    eprintln!("plan_release: {r}");
    eprintln!("round: {}", control(&h, "/round", json!({})));
    let mut done = false;
    for _ in 0..30 {
        ok(a.run("sync", &json!({})), "sync");
        let all = ok(a.run("coins", &json!({})), "coins")["result"].clone();
        let held = all.as_array().unwrap().iter().find(|c| c["leaf_id"] == json!(leaf)).map(|c| c["state"].as_str().unwrap().to_string());
        if !matches!(held.as_deref(), Some("live" | "pending" | "given" | "offered" | "sending" | "forfeited")) {
            eprintln!("released coin now {:?}", held);
            done = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    assert!(done, "the released coin left the wallet's hands once its round was final");
    let sent = ok(a.run("send", &json!({"request": req})), "the same payment again")["result"].clone();
    eprintln!("sent: {sent}");
    ok(b.run("mailbox", &json!({})), "the payee's mailbox");
    let got = ok(b.run("balance", &json!({})), "balance")["result"]["arca"][&x].clone();
    eprintln!("payee holds: {got}");
    let total: u64 = got.as_object().unwrap().values().filter_map(|v| v.as_str()?.parse::<u64>().ok()).sum();
    assert_eq!(total, 500_000);
    let plans = ok(a.run("plans", &json!({})), "plans")["result"].clone();
    eprintln!("plans: {plans}");
    drop(a);
    drop(b);
    let _ = std::fs::remove_dir_all(&adir);
    let _ = std::fs::remove_dir_all(&bdir);
}
