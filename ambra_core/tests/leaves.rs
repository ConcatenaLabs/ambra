//! The leaf service against a whole operator: a payment that arrives while the app
//! is closed, and an in-tree swap between two wallets. Runs against arca's long-running operator harness
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
    let pass = ok(leaves::job(&adir, APP, password.clone()), "the job's pass");
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
    let pass2 = ok(leaves::job(&adir, APP, None), "second pass");
    assert_eq!(pass2["arrived"], json!([]));
    assert_eq!(pass2["opened_for_the_job"], false, "the open wallet is used, not opened twice");
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
