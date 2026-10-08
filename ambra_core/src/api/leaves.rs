//! Leaves for the app: the operator's wallet library, through
//! [`crate::leaves`]. Every function answers the library's JSON as text, and
//! fails with the library's refusal as text (`{"error": {"kind",
//! "message"}}`), which the app shows in the library's words.

use std::path::Path;

use anyhow::Result;
use serde_json::Value;

use crate::leaves;

fn fail(v: Value) -> anyhow::Error {
    anyhow::Error::msg(v.to_string())
}

fn parse(what: &str, s: &str) -> Result<Value> {
    if s.trim().is_empty() {
        return Ok(Value::Object(Default::default()));
    }
    serde_json::from_str(s).map_err(|e| {
        fail(leaves::refusal(bark::arca::Error::Parse(format!("{}: {}", what, e))))
    })
}

fn password(p: String) -> Option<String> {
    if p.is_empty() { None } else { Some(p) }
}

/// Whether the app's data directory `dir` holds the leaf wallet of `mnemonic`.
pub fn leaves_exists(dir: String, mnemonic: String) -> Result<bool> {
    leaves::exists(Path::new(&dir), &mnemonic).map_err(fail)
}

/// Joins an operator: creates the leaf wallet of `mnemonic` against the
/// operator and node `config_json` names (`{"server", "node_url",
/// "node_user"?, "node_password"?}`), pins the node's chain and the
/// operator's key, keeps it open, and restores whatever the operator and the
/// chain hold of this mnemonic's leaves. The answer is `{"info", "restore"}`.
pub fn leaves_join(dir: String, mnemonic: String, config_json: String) -> Result<String> {
    let c = parse("the configuration", &config_json)?;
    let d = Path::new(&dir);
    if leaves::exists(d, &mnemonic).map_err(fail)? {
        leaves::stop();
        return Err(fail(leaves::refusal(bark::arca::Error::Refused(
            "this phone already holds a leaf wallet for this mnemonic: it opens on its own".into(),
        ))));
    }
    leaves::start(d, &mnemonic, Some(&c), None).map_err(fail)?;
    let info = leaves::run("info", &Value::Null).map_err(fail)?;
    let restore = leaves::run("restore", &Value::Null).map_err(fail)?;
    Ok(serde_json::json!({"info": info["result"], "restore": restore["result"]}).to_string())
}

/// Opens the leaf wallet of `mnemonic` and keeps it open; one already open
/// with this mnemonic is kept. `node_password` empty when the node needs none.
pub fn leaves_open(dir: String, mnemonic: String, node_password: String) -> Result<()> {
    leaves::start(Path::new(&dir), &mnemonic, None, password(node_password)).map(|_| ()).map_err(fail)
}

/// Runs one of the library's commands on the open wallet, `args_json` a JSON
/// object of its arguments. The answer is `{"result", "start"}`.
pub fn leaves_run(command: String, args_json: String) -> Result<String> {
    let a = parse("the arguments", &args_json)?;
    leaves::run(&command, &a).map(|v| v.to_string()).map_err(fail)
}

/// Closes the open wallet.
#[flutter_rust_bridge::frb(sync)]
pub fn leaves_close() {
    leaves::stop();
}

/// Whether a leaf wallet is open in this process.
#[flutter_rust_bridge::frb(sync)]
pub fn leaves_is_open() -> bool {
    leaves::is_open()
}

/// The scheduled job's pass: `sync`, then what arrived and when to wake
/// (`{"arrived", "schedule", "wake_in", "sync", "opened_for_the_job"}`, or
/// `{"joined": false}` when the phone holds no leaf wallet for `mnemonic`).
pub fn leaves_job(dir: String, mnemonic: String, node_password: String) -> Result<String> {
    leaves::job(Path::new(&dir), &mnemonic, password(node_password)).map(|v| v.to_string()).map_err(fail)
}

/// When the scheduled job must wake, in seconds, from the library's `schedule`
/// and `coins` answers: the schedule's `next_sync_at`, never more than a day
/// ahead while a coin is off the chain or a receive request waits; `None` when
/// nothing waits.
#[flutter_rust_bridge::frb(sync)]
pub fn leaves_wake_in(schedule_json: String, coins_json: String) -> Option<u64> {
    let s: Value = serde_json::from_str(&schedule_json).unwrap_or(Value::Null);
    let c: Value = serde_json::from_str(&coins_json).unwrap_or(Value::Null);
    leaves::wake_in(&s, &c)
}
