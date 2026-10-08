//! The leaf service against a whole operator: a payment that arrives while the app
//! is closed. Runs against arca's long-running operator harness
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
