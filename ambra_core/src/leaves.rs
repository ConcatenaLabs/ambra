//! Leaves: coins held as leaves of an operator's covenant trees on Sequentia,
//! through the operator's wallet library (`bark::arca`, linked natively).
//!
//! The library does everything a leaf wallet does (every script, record,
//! check, fee, schedule and refusal is its own). This module adds what the
//! phone gives it, as the browser build adds what a browser gives it:
//!
//! - **HTTP**: every request to the node and to the operator goes through
//!   `reqwest`'s blocking client, registered once with
//!   `sequentia_ext::platform::set_platform`, so the core keeps one TLS stack
//!   (rustls, no OpenSSL);
//! - **the store**: the library's SQLite store, one file per mnemonic under
//!   the app's data directory (`<dir>/leaves/arca-<mailbox key digest>.sqlite`),
//!   named as the browser names its OPFS file. The store keeps no mnemonic: the
//!   app hands it over on every open, and an open with another mnemonic is
//!   refused. A lock file beside it admits one opener at a time, so the
//!   foreground service and the scheduled job never write it together;
//! - **the schedule**: [`LeafWallet::background_sync`] is what the scheduled job
//!   runs while the app is closed: a `sync`, the coins it accepted from the
//!   mailbox (each one raises a notification), and the time the job must wake
//!   again ([`wake_at`]).
//!
//! Every answer is the library's JSON, and every refusal is the JSON the
//! library's command line prints, `{"error": {"kind", "message"}}`, so the app
//! shows it in the library's own words.

use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use bark::arca::command;
use bark::arca::store::Store;
use bark::arca::{Error, Wallet};
use sequentia_ext::platform::{self, Platform, Request, Response};
use serde_json::{json, Value};

/// The longest the job may sleep while a coin is off the chain or a request is
/// open: the library asks for a sync at least once a day then.
pub const DAILY: u64 = 86_400;

// ---------------------------------------------------------------------------
// The platform
// ---------------------------------------------------------------------------

struct Http {
    client: reqwest::blocking::Client,
}

impl Platform for Http {
    fn http(&self, r: &Request) -> Result<Response, String> {
        let mut b = match r.method {
            "POST" => self.client.post(r.url),
            "GET" => self.client.get(r.url),
            other => return Err(format!("{} {}: the method is not one this wallet sends", other, r.url)),
        };
        for (k, v) in &r.headers {
            b = b.header(*k, v);
        }
        if let Some(body) = r.body {
            b = b.body(body.to_string());
        }
        let resp = b
            .timeout(Duration::from_secs(r.timeout_secs.max(1)))
            .send()
            .map_err(|e| format!("{} {}: {}", r.method, r.url, e))?;
        let status = i32::from(resp.status().as_u16());
        let body = resp.text().map_err(|e| format!("{} {}: {}", r.method, r.url, e))?;
        Ok(Response { status, body })
    }

    fn sleep(&self, d: Duration) {
        std::thread::sleep(d)
    }
}

/// Registers the phone's HTTP and pause, once.
fn install_platform() -> Result<(), Value> {
    static DONE: OnceLock<Result<(), String>> = OnceLock::new();
    DONE.get_or_init(|| {
        let client = reqwest::blocking::Client::builder()
            .build()
            .map_err(|e| format!("the wallet's HTTP client: {}", e))?;
        // A second registration (another wallet in this process) keeps the
        // first, which is this same transport.
        let _ = platform::set_platform(Box::new(Http { client }));
        Ok(())
    })
    .clone()
    .map_err(|m| refusal(Error::Io(m)))
}

// ---------------------------------------------------------------------------
// Refusals
// ---------------------------------------------------------------------------

/// A refusal as the library's command line prints it.
pub fn refusal(e: Error) -> Value {
    command::refusal(&e)
}

/// The words of a refusal: its `message`.
pub fn refusal_message(v: &Value) -> String {
    v["error"]["message"].as_str().map(String::from).unwrap_or_else(|| v.to_string())
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

/// The store of the wallet of `mnemonic` under the app's data directory `dir`.
pub fn store_path(dir: &Path, mnemonic: &str) -> Result<PathBuf, Value> {
    Ok(dir.join("leaves").join(command::store_name(mnemonic).map_err(refusal)?))
}

/// Whether the app's data directory holds the wallet of `mnemonic`.
pub fn exists(dir: &Path, mnemonic: &str) -> Result<bool, Value> {
    let p = store_path(dir, mnemonic)?;
    if !p.exists() {
        return Ok(false);
    }
    let lock = lock(&p)?;
    let store = open_store(&p)?;
    let held = store.meta("genesis").map_err(refusal)?.is_some();
    drop(store);
    drop(lock);
    Ok(held)
}

/// Takes the store's lock, or refuses while someone else holds it.
fn lock(store: &Path) -> Result<File, Value> {
    let dir = store.parent().expect("a store has a directory");
    std::fs::create_dir_all(dir).map_err(|e| refusal(Error::Io(format!("{}: {}", dir.display(), e))))?;
    let path = store.with_extension("lock");
    let f = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(|e| refusal(Error::Io(format!("{}: {}", path.display(), e))))?;
    match try_lock(&f) {
        Ok(true) => Ok(f),
        Ok(false) => Err(refusal(Error::Refused(
            "the leaf wallet's store is open elsewhere (another process holds it): try again once it is closed".into(),
        ))),
        Err(e) => Err(refusal(Error::Io(format!("{}: {}", path.display(), e)))),
    }
}

/// An exclusive lock on `f` without waiting: `false` while another open file
/// holds it. flock(2) on Unix, Android included, where the standard library's
/// `File::try_lock` answers "not supported"; it is let go when `f` closes.
#[cfg(unix)]
fn try_lock(f: &File) -> std::io::Result<bool> {
    use std::os::fd::AsRawFd;
    // SAFETY: flock on a descriptor `f` owns, open for the whole call.
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(true);
    }
    let e = std::io::Error::last_os_error();
    if e.raw_os_error() == Some(libc::EWOULDBLOCK) { Ok(false) } else { Err(e) }
}

#[cfg(not(unix))]
fn try_lock(f: &File) -> std::io::Result<bool> {
    match f.try_lock() {
        Ok(()) => Ok(true),
        Err(std::fs::TryLockError::WouldBlock) => Ok(false),
        Err(std::fs::TryLockError::Error(e)) => Err(e),
    }
}

fn open_store(p: &Path) -> Result<Store, Value> {
    let conn = rusqlite::Connection::open(p).map_err(|e| refusal(Error::Store(e.to_string())))?;
    Store::open_connection(conn).map_err(refusal)
}

// ---------------------------------------------------------------------------
// The wallet
// ---------------------------------------------------------------------------

/// One leaf wallet, open with its store's lock held.
pub struct LeafWallet {
    w: Wallet,
    store: PathBuf,
    _lock: File,
}

impl LeafWallet {
    /// Creates the wallet of `mnemonic` in the app's data directory against
    /// the operator and node `config` names (`{"server", "node_url",
    /// "node_user"?, "node_password"?, "exit_delay_units"?, …}`), pinning the
    /// node's chain and the operator's key. A store that already holds a
    /// wallet is refused.
    pub fn create(dir: &Path, mnemonic: &str, config: &Value) -> Result<LeafWallet, Value> {
        install_platform()?;
        let cfg = command::config(config).map_err(refusal)?;
        let p = store_path(dir, mnemonic)?;
        let lock = lock(&p)?;
        let w = Wallet::create_in(open_store(&p)?, mnemonic, cfg).map_err(refusal)?;
        Ok(LeafWallet { w, store: p, _lock: lock })
    }

    /// Opens the wallet of `mnemonic` the app's data directory holds; the
    /// node's password is handed over on each open and never stored.
    pub fn open(dir: &Path, mnemonic: &str, node_password: Option<String>) -> Result<LeafWallet, Value> {
        install_platform()?;
        let p = store_path(dir, mnemonic)?;
        if !p.exists() {
            return Err(refusal(Error::Refused("this phone holds no leaf wallet for this mnemonic: join an operator first".into())));
        }
        let lock = lock(&p)?;
        let w = Wallet::open_in(open_store(&p)?, mnemonic, node_password).map_err(refusal)?;
        Ok(LeafWallet { w, store: p, _lock: lock })
    }

    /// The store's file.
    pub fn store(&self) -> &Path {
        &self.store
    }

    /// Runs one of the library's commands ([`command::COMMANDS`]), `args` a
    /// JSON object. The answer is `{"result", "start"}`.
    pub fn run(&mut self, cmd: &str, args: &Value) -> Result<Value, Value> {
        command::run(&mut self.w, cmd, args).map_err(refusal)
    }

    /// What the scheduled job does: a `sync`, then what arrived and when to
    /// wake. The answer is `{"arrived": [{leaf_id, asset, value, kind}…],
    /// "schedule", "wake_in", "sync"}`, `wake_in` in seconds or `null`.
    pub fn background_sync(&mut self) -> Result<Value, Value> {
        let sync = self.run("sync", &json!({}))?;
        let arrived = arrivals(&sync["result"]["mailbox"]);
        let schedule = self.run("schedule", &json!({}))?["result"].take();
        let coins = self.run("coins", &json!({}))?["result"].take();
        let wake = wake_in(&schedule, &coins);
        Ok(json!({"arrived": arrived, "schedule": schedule, "wake_in": wake, "sync": sync["result"]}))
    }
}

/// The coins a mailbox read accepted, each `{leaf_id, asset, value, kind}`.
pub fn arrivals(mailbox: &Value) -> Vec<Value> {
    mailbox["accepted"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|c| json!({"leaf_id": c["leaf_id"], "asset": c["asset"], "value": c["value"], "kind": c["kind"]}))
                .collect()
        })
        .unwrap_or_default()
}

/// Whether a coin in `state` is still the wallet's, off the chain: the coins
/// the library's schedule follows home.
fn off_chain(state: &str) -> bool {
    matches!(state, "live" | "pending" | "given" | "forfeited" | "offered" | "sending" | "paying" | "receiving" | "exiting")
}

/// When the job must wake, in seconds from the schedule's `now` (both median
/// times): the schedule's `next_sync_at`, and never more than a day ahead
/// while a coin is off the chain or a receive request waits; `null` when
/// nothing waits. Due now is `0`.
pub fn wake_in(schedule: &Value, coins: &Value) -> Option<u64> {
    let now = schedule["now"].as_u64().unwrap_or(0);
    let next = schedule["next_sync_at"].as_u64().map(|n| n.saturating_sub(now));
    let holding = coins
        .as_array()
        .is_some_and(|a| a.iter().any(|c| c["state"].as_str().is_some_and(off_chain)))
        || schedule["receive_requests"]
            .as_array()
            .is_some_and(|a| a.iter().any(|r| r["state"] == "waiting"));
    match (next, holding) {
        (Some(n), true) => Some(n.min(DAILY)),
        (Some(n), false) => Some(n),
        (None, true) => Some(DAILY),
        (None, false) => None,
    }
}

// ---------------------------------------------------------------------------
// The one wallet the app holds open
// ---------------------------------------------------------------------------

struct Held {
    wallet: LeafWallet,
    /// A digest of the mnemonic it was opened with, to tell whether a caller
    /// asks for this same wallet.
    who: [u8; 32],
}

static HELD: Mutex<Option<Held>> = Mutex::new(None);

fn who(dir: &Path, mnemonic: &str) -> [u8; 32] {
    use bark::arca::elements::hashes::{sha256, Hash};
    let s = format!("leaf-wallet/{}/{}", dir.display(), mnemonic.trim());
    sha256::Hash::hash(s.as_bytes()).to_byte_array()
}

fn held() -> std::sync::MutexGuard<'static, Option<Held>> {
    HELD.lock().unwrap_or_else(|e| e.into_inner())
}

/// Opens the wallet of `mnemonic` and keeps it open for [`run`]; a wallet
/// already open with the same mnemonic is kept as it is. With `config`, a
/// wallet the directory does not hold is created first, and its answer then
/// says `created`.
pub fn start(dir: &Path, mnemonic: &str, config: Option<&Value>, node_password: Option<String>) -> Result<Value, Value> {
    let id = who(dir, mnemonic);
    let mut g = held();
    if g.as_ref().is_some_and(|h| h.who == id) {
        return Ok(json!({"created": false}));
    }
    *g = None;
    let created = match config {
        Some(c) if !exists(dir, mnemonic)? => {
            let mut c = c.clone();
            if c["node_password"].is_null() {
                if let Some(p) = &node_password {
                    c["node_password"] = json!(p);
                }
            }
            Some(LeafWallet::create(dir, mnemonic, &c)?)
        }
        _ => None,
    };
    let is_new = created.is_some();
    let wallet = match created {
        Some(w) => w,
        None => LeafWallet::open(dir, mnemonic, node_password)?,
    };
    *g = Some(Held { wallet, who: id });
    Ok(json!({"created": is_new}))
}

/// Runs a command on the wallet [`start`] opened.
pub fn run(cmd: &str, args: &Value) -> Result<Value, Value> {
    match held().as_mut() {
        Some(h) => h.wallet.run(cmd, args),
        None => Err(refusal(Error::Refused("the leaf wallet is not open".into()))),
    }
}

/// Closes the wallet [`start`] opened and lets go of its store.
pub fn stop() {
    *held() = None;
}

/// Whether a wallet is open.
pub fn is_open() -> bool {
    held().is_some()
}

/// The scheduled job's pass: on the wallet the app holds open when it is this
/// one, or else on the wallet opened for the pass and closed after it.
pub fn job(dir: &Path, mnemonic: &str, node_password: Option<String>) -> Result<Value, Value> {
    let id = who(dir, mnemonic);
    {
        let mut g = held();
        if let Some(h) = g.as_mut().filter(|h| h.who == id) {
            let mut v = h.wallet.background_sync()?;
            v["opened_for_the_job"] = json!(false);
            return Ok(v);
        }
    }
    if !store_path(dir, mnemonic)?.exists() {
        return Ok(json!({"arrived": [], "wake_in": null, "joined": false}));
    }
    let mut w = LeafWallet::open(dir, mnemonic, node_password)?;
    let mut v = w.background_sync()?;
    v["opened_for_the_job"] = json!(true);
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ZERO: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ambra-leaves-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn the_store_is_named_after_the_mailbox_key_under_the_app_dir() {
        let d = tmp("name");
        let p = store_path(&d, ZERO).unwrap();
        assert_eq!(p.parent().unwrap(), d.join("leaves"));
        assert_eq!(p.file_name().unwrap().to_str().unwrap(), command::store_name(ZERO).unwrap());
        assert!(!exists(&d, ZERO).unwrap());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn one_opener_at_a_time() {
        let d = tmp("lock");
        let p = store_path(&d, ZERO).unwrap();
        let first = lock(&p).unwrap();
        let second = lock(&p).unwrap_err();
        assert_eq!(second["error"]["kind"], "refused");
        assert_eq!(
            refusal_message(&second),
            "refused: the leaf wallet's store is open elsewhere (another process holds it): try again once it is closed"
        );
        drop(first);
        assert!(lock(&p).is_ok());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn opening_a_wallet_never_joined_is_refused_in_words() {
        let d = tmp("open");
        let e = LeafWallet::open(&d, ZERO, None).err().unwrap();
        assert_eq!(refusal_message(&e), "refused: this phone holds no leaf wallet for this mnemonic: join an operator first");
        assert_eq!(job(&d, ZERO, None).unwrap()["joined"], false);
        let e = run("balance", &json!({})).unwrap_err();
        assert_eq!(refusal_message(&e), "refused: the leaf wallet is not open");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_store_without_a_wallet_is_refused_by_the_library() {
        let d = tmp("empty");
        let p = store_path(&d, ZERO).unwrap();
        let l = lock(&p).unwrap();
        drop(open_store(&p).unwrap());
        drop(l);
        assert!(!exists(&d, ZERO).unwrap());
        let e = LeafWallet::open(&d, ZERO, None).err().unwrap();
        assert_eq!(refusal_message(&e), "refused: this store holds no wallet; create one first");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn the_job_wakes_on_the_schedule_and_daily_while_something_waits() {
        let live = json!([{"state": "live"}]);
        let spent = json!([{"state": "spent"}, {"state": "exited"}]);
        // A coin weeks from its refresh window: the daily rule.
        assert_eq!(wake_in(&json!({"now": 1000, "next_sync_at": 1000 + 20 * DAILY}), &live), Some(DAILY));
        // Due in an hour.
        assert_eq!(wake_in(&json!({"now": 1000, "next_sync_at": 4600}), &live), Some(3600));
        // Due now, or overdue.
        assert_eq!(wake_in(&json!({"now": 1000, "next_sync_at": 900}), &live), Some(0));
        // A request waits, no coin: the schedule says a day.
        let s = json!({"now": 1000, "next_sync_at": 1000 + DAILY, "receive_requests": [{"state": "waiting"}]});
        assert_eq!(wake_in(&s, &json!([])), Some(DAILY));
        // A lapsed request alone holds nothing.
        assert_eq!(wake_in(&json!({"now": 1000, "next_sync_at": null, "receive_requests": [{"state": "lapsed"}]}), &spent), None);
        // Nothing held: no wake.
        assert_eq!(wake_in(&json!({"now": 1000, "next_sync_at": null}), &spent), None);
        // A coin off the chain the schedule does not date: still daily.
        assert_eq!(wake_in(&json!({"now": 1000, "next_sync_at": null}), &json!([{"state": "exiting"}])), Some(DAILY));
    }

    #[test]
    fn arrivals_are_the_mailbox_accepted_coins() {
        let mb = json!({"accepted": [{"leaf_id": "l1", "asset": "a", "value": 300000, "kind": "transfer", "extra": 1}], "refused": []});
        assert_eq!(arrivals(&mb), vec![json!({"leaf_id": "l1", "asset": "a", "value": 300000, "kind": "transfer"})]);
        assert!(arrivals(&json!({"note": "the witness … did not succeed"})).is_empty());
    }
}
