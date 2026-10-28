# Ambra

Ambra is a non-custodial **dual-chain mobile wallet for Bitcoin (testnet4) and Sequentia**:
a Flutter UI over a shared Rust core (`ambra_core`) built on
[SWK](https://github.com/ConcatenaLabs/SWK), the Sequentia Wallet Kit.
One 12-word recovery phrase controls both chains, and the same `tb1...` address
receives Bitcoin and Sequentia assets alike: Sequentia is transparent by default and its
default addresses use Bitcoin's own bech32 format, so BTC is a first-class asset in the
wallet, not an add-on.

Everything here is **testnet software** (Bitcoin testnet4 + the public Sequentia testnet).
There is no mainnet. Coins and assets have no value.

Sequentia itself is a Bitcoin sidechain for asset tokenization and disintermediated exchanges.
Protocol documentation lives in the node repo:
[Sequentia `doc/sequentia/`](https://github.com/ConcatenaLabs/Sequentia/tree/HEAD/doc/sequentia).

## Get the app

- Download the Android APK from https://sequentiatestnet.com/download/. That page always
  names the current release; this file deliberately does not, because a version pinned in
  prose goes stale the next time the publisher runs. Allow "install unknown apps", then
  open the `.apk`.
- Ambra also ships as a Chromium browser extension, the same dual-chain wallet built from
  [sequentia-extension](https://github.com/ConcatenaLabs/sequentia-extension),
  offered on the same download page.
- iOS is not released. The `app/ios/` scaffold exists but iOS bring-up has not happened
  (it needs a macOS + Xcode machine).
- Free testnet funds: the in-app faucet (More tab) dispenses tSEQ and the demo assets;
  for BTC use any public Bitcoin testnet4 faucet with the wallet's receive address. In
  user mode the faucet pays the wallet's receive code, so the coins arrive in seconds
  (the address if the faucet refuses the code); in developer mode, a wallet that joined
  an operator can ask to be paid as a leaf instead.

## What the wallet does

Each item below is implemented in this repo; the file pointers name the screen or
module that implements it.

**Wallet and custody**
- Create a wallet (12-word BIP39 phrase, word grid + verification quiz) or import an
  existing phrase (`app/lib/src/screens/onboarding.dart`). The phrase is stored only in
  platform secure storage (Android Keystore-backed encrypted preferences / iOS Keychain)
  and is read out transiently for signing, never cached
  (`app/lib/src/data/wallet_repository.dart`).
- Opt-in app lock (biometrics or device PIN) that engages on cold start and whenever the
  app is backgrounded; revealing the recovery phrase always requires authentication.
- Reveal recovery phrase and remove wallet (deletes the phrase from the device), both
  from the More tab.
- Keylogger-immune phrase import: the import path uses an on-screen keyboard with BIP39
  autocomplete, so no system IME ever sees the words; free-text paste remains as a
  fallback (`app/lib/src/screens/recover_screen.dart`).
- OpenAMP tagged signing: sign a wallet-link/login challenge or a document hash for an
  OpenAMP-integrated site, opened from an `oamp-sign` deep link
  (`app/lib/src/screens/sign_screen.dart`).
- Classic message signing on the same screen: sign with the key behind one of the
  wallet's own addresses, in the format `verifymessage` accepts, so anyone with a node
  can check that an address is yours. Neither signature can move funds. Verification is
  offered against the legacy form of the address, the only form that RPC takes.
- CoinJoin: mix a Sequentia asset in a seqcj round, from the More tab. The amounts are
  confidential, so the chain sees a transaction and not what moved in it, and the change is
  blinded like the mixed coins; what the blind signatures buy is that the coordinator cannot
  link the coins going in to the mixed coins coming out. The screen says the rest plainly —
  the coordinator sees your amounts, the phone connects from one address, and the anonymity
  set is the round (`app/lib/src/screens/mix_screen.dart`).

**Balance (dual-chain, no privileged asset)**
- The headline is one **total balance across all held assets and everything held of
  each, valued in a user-chosen reference currency** (USD default; picker in the top bar,
  fed by the public price server), in both modes, hidden assets included. Below it, every
  held asset is one equal row: BTC (Bitcoin testnet4) first, listed at 0 too, then tSEQ,
  issued assets and OpenAMP restricted assets side by side
  (`app/lib/src/screens/shell.dart`).
- An asset's figure counts everything the wallet holds of it: on-chain coins, leaves
  (the leaf library's `held` less its own on-chain coins, which sit at the phrase's keys
  and are counted on-chain, so a leaf taken home by its exit counts once, as the coin on
  the chain), Lightning (the wallet's own channels in a `CHANNELD_*` state, its share with the
  channel reserve, `balance_units`, or `spendable_units` from an LSP that does not report
  it) and, for the Sequence token, what is staked (each bonded stake under either lock,
  each unbonding output not yet returned, and the delegation record; a stake returned to
  the wallet is on-chain again and counted there once). User mode shows one figure per
  row; a tap on the row shows what is staked, if any, and what is arriving shows under
  it. Developer mode shows the parts beside each row, with the Lightning controls (`app/lib/src/data/portfolio.dart`, `app/lib/src/data/stakes.dart`).
  What a payment can use is the spendable part, not the figure.
- Both chains sync against Esplora-style REST APIs; last-known balances are cached on
  disk and shown instantly on launch, with an explicit offline/stale indicator when a
  scan fails.

**Receive**
- One shared `tb1...` address for both chains, with QR code and cross-chain index
  cycling ("New address" advances both chains together, discouraging reuse).
- Opt-in confidential Sequentia address (blech32, `tsqb1...`) that hides amount and
  asset on-chain; the screen then also shows the matching transparent `tb1` form, which
  is the one that can receive Bitcoin.
- OpenAMP account id + enclave deposit address for receiving restricted assets, shown
  when the OpenAMP service is reachable.
- The account key, on request, for a watch-only import elsewhere: the extended public
  key (`[fingerprint/84h/1h/0h]tpub...`) or a checksummed descriptor pair, receive and
  change, in the `wpkh(...)` form that matches this wallet's addresses or the legacy
  `pkh(...)` form. One key covers both chains, which share the `m/84'/1'/0'` account.

**Send**
- Sequentia send of any held asset, with the signature Sequentia feature: an **any-asset
  fee picker**. The fee asset follows the wallet rule wherever Ambra builds a Sequentia
  transaction (`app/lib/src/data/fee_asset_rule.dart`): the asset being moved when the node
  accepts it, else the accepted asset whose largest coin covers the most fees. The Sequence
  token is never a default or a fallback; a wallet holding nothing the node accepts is told
  so. Any accepted asset can be picked instead, at the node's published exchange rates, the
  Sequence token's included. Optional fee-rate override,
  always denominated in **the chosen fee asset's own units per vByte** (never sat/vB;
  sats are Bitcoin-only) (`app/lib/src/screens/send_screen.dart`).
- One asset picker, shared with the swap composer (`app/lib/src/widgets/asset_sheet.dart`):
  BTC first and picked by default, listed even at 0; then every asset the wallet holds on
  any rail (on-chain, Lightning, leaves); a search over every registry asset, or a pasted
  asset id, reaches the rest. The list scrolls, whatever its length and the screen's.
- Bitcoin (testnet4) send: BTC pays its own fee in sat/vB (correct there, it is the
  Bitcoin chain).
- A Lightning invoice, scanned or pasted into the recipient field, opens the Lightning pay
  screen, for BTC and for Sequentia assets (`lntsqt…` on the testnet).
- The phone's signer approves Lightning payments up to a daily limit of 1,000 US dollars,
  held in each asset at the node's rate (Bitcoin at the price feed's), so it is worth the
  same in every asset (`app/lib/src/data/ln_payment_limit.dart`). A payment over it is
  refused in plain words and nothing is sent; developer mode sets another figure under
  More > Lightning payment limit.
- QR scanning of recipient addresses using the first-party CameraX preview plus a
  **pure-Dart ZXing decoder (`zxing2`)**, so the app needs no Google ML Kit and no Play
  Services (`app/lib/src/screens/scan_screen.dart`).
- OpenAMP restricted assets are sent by account id through the enclave's
  transfer-approval flow (`app/lib/src/data/openamp_service.dart`).

**History and stuck-transaction rescue**
- Transaction history with kind badges, per-asset deltas, and explorer deep links.
- Rescue actions on unconfirmed transactions (`app/lib/src/screens/rescue_screen.dart`):
  - **RBF bump**: re-send the same payment at a higher fee,
  - **RBF replace**: same inputs, brand-new recipient/asset/amount,
  - **CPFP**: pay a child fee, in any asset, to pull the parent in
    (with a suggested child fee rate from the core).

**Swap (SeqDEX)**
- **In user mode** (the default) the Swap tab is three inputs and one button: **You pay**
  (an asset and an amount), **You get**, and **Review** (`app/lib/src/screens/user_composer.dart`,
  its engine `app/lib/src/data/user_trade.dart`, the web wallet's `user-trade.js` in Dart). BTC
  heads both pickers, and each picker shows what the wallet holds of an asset as its one
  figure on the balance (`heldFigure`, `app/lib/src/data/ln_rail.dart`: BTC in the wallet's
  own Bitcoin Lightning node included), while a trade is bounded by what can be spent now.
  The wallet's Lightning channels are read apart from the on-chain sync, so a sync that fails
  hides none of them. Review shows what you pay, what you get and one line of fees, each in
  the asset it is paid in, before anything is signed; **Trade** confirms it, and the trade then
  reads **Sent**, **Settled** once final, or **Returned: nothing traded.**, with nothing to do
  either way. It trades only what settles in one step from the wallet's coins in a leaf
  operator's tree: an in-tree swap with a live leaf maker, a transparent covenant order
  taken in the operator's round, or an order resting in the operator's tree filled in one
  transfer the operator co-signs, choosing the one that gives the most, then the one with the
  fewest parties left to act. It offers only the pairs the web wallet's reliability drill has
  passed on the chain (the web wallet's `user-mode/pairs.json`, read from the node's origin),
  and says "Not offered right now" in plain words for one nobody fills in one step; no screen
  of it names a rail, a round, a leaf, the operator, a covenant, an expiry or an atom. BTC
  trades against an asset the same way, in one hash-lock: the asset moves in the operator's
  tree and the BTC over the wallet's own hosted Bitcoin Lightning node, under the hash of
  whoever receives the BTC (`app/lib/src/data/user_trade_btc.dart`), with the leaf maker that
  quotes BTC at the node's origin (`/leafmaker-btc`, beside the in-tree maker at `/leafmaker`). When the wallet sells
  for BTC its invoice is a hold under a hash it makes itself, its preimage kept on the phone
  and handed to the node only to settle a payment held there for the whole amount; when it
  buys with BTC it pays the maker's invoice only once the asset it receives is held for good,
  its routing fee and lock capped at the route the ticket showed
  (`app/lib/src/data/btc_lightning.dart`). The screens below are developer mode's.
- **Same-chain atomic swap**: pay one Sequentia asset, receive another, settled in a
  single atomic transaction against the SeqDEX daemon's order book
  (`app/lib/src/screens/swap_screen.dart`). The review sheet states finality honestly:
  settles in ~1 block, anchor-bound to Bitcoin (reverts only if Bitcoin reverts).
- **Cross-chain buy**: buy a Sequentia asset by locking BTC in a testnet4 HTLC
  (`app/lib/src/screens/xchain_swap_screen.dart`). The preimage reveal is hard-gated on
  verifying the Sequentia leg's Bitcoin anchor; in-flight swaps persist across restarts
  and a BTC refund path opens after the timeout.
- **Instant (Lightning)**: a pure-Lightning BTC<->asset rail through the public hosted
  SeqLN LSP, non-custodial via an on-device signer
  (`app/lib/src/screens/lightning_swap_screen.dart`). It is on by default: the released
  APK points at `wss://sequentiatestnet.com/lsp-ws-asset` and `/lsp-ws-btc` with pinned
  host keys (`Backend` in `app/lib/src/data/config.dart`). Pointing the wallet at a
  custom node clears these, because a custom node has no hosted LSP, and the rail goes
  dark until you return to the default.
- **Peer-to-peer submarine swap**: a rail crossing on the BTC leg settled directly with
  an interactive maker, no LSP in the value path. A buy pays Bitcoin over Lightning and
  receives the asset in one on-chain HTLC bound to the same secret; a sell funds the
  asset HTLC (`app/lib/src/screens/submarine_swap_screen.dart`).
- **Sub-asset rails**: buy or sell a Sequentia asset over Lightning against Bitcoin on
  the testnet4 chain, served by the LSP (`app/lib/src/screens/subasset_buy_screen.dart`,
  `subasset_sell_screen.dart`).
- **Cross-market lift and walk**: buy an asset with Bitcoin against one resting cross
  offer at a live maker quote fetched over the relay courier
  (`app/lib/src/screens/cross_lift_screen.dart`), or sweep several resting offers best
  price first, one leg at a time through the same path
  (`app/lib/src/screens/cross_walk_screen.dart`). The BTC is refundable after the
  timeout and the secret reveals only on an anchor-safe asset leg.
- **My orders**: the maker's own resting covenant orders (funded on-chain, posted to the
  relay) with a reclaim path (`app/lib/src/screens/my_orders_screen.dart`).

**The mode, and leaves**
- More > Mode is one setting, kept for each wallet, in the words every Sequentia wallet
  uses. **User mode** (the default): one figure per asset, and the wallet chooses how
  value moves. **Developer mode**: every rail by name, side by side (on-chain, leaves and
  Lightning), each with its balance and its manual controls, and the developer tools:
  each balance row splits into on-chain, leaves, Lightning and staked, with the Move to
  Lightning and Move to chain controls under it, and More > Leaves,
  More > Contracts and More > Lightning payment limit appear.
  BTC has no leaves: a tree on Sequentia holds no BTC (`app/lib/src/data/dev_mode.dart`).
- A wallet that joined a leaf operator keeps its leaf wallet syncing in either mode, since
  its coins have dates to keep; user mode shows nothing of leaves but their value, in each
  asset's figure and in the headline.
- **User mode runs on the default node's operator by itself** (`LeafService.autoJoin`,
  `autoBoard`, `receiveCode` in `app/lib/src/data/leaf_service.dart`), in the same words
  and ways as the web wallet:
  - A new or restored wallet that holds no leaf wallet joins the operator at
    `<origin>/arca`, only when the server shows the operator key pinned in
    `app/lib/src/data/config.dart` (`Backend.arcaOperatorKey`; a custom node pins none and
    joins nothing by itself). The join restores this phrase's leaves. While the operator
    cannot be reached the wallet works on the chain as before and tries again every two
    minutes.
  - Its words are the default-mode contract's (sequentia-web-wallet `docs/DEFAULT_MODE.md`), held in
    `app/lib/src/data/default_words.dart` and tested against the contract's forbidden words.
    Default mode shows no rail: a row's details show only Staked, what is arriving, and a
    freeze; the split by rail and the fee-rate fields are developer mode's.
  - Receive shows a **receive code** first: any asset, any amount, paid once, a new one
    drawn when it is or on "New code"; a payment to it arrives in seconds (the wallet reads
    for it every four seconds while a code handed out in the last hour waits). "Show
    address" gives the shared address, "For BTC, and for senders that ask for an address."
  - Send pays a receive code of a wallet on the same operator from the wallet's leaves;
    anything else (an address, an invoice, an account id) takes the path it always took.
    An address send that only the leaves could cover is refused in plain words: "This
    amount is kept for instant payments and can't be sent to an address yet. Send it to a
    receive code, or pay an invoice."
  - Coins that arrive on the chain, of every asset the operator serves, are boarded by
    the wallet itself (amount = what the chain holds less the board's fee, paid in the
    same asset, on the fee quoted), never while something a person asked for runs or in
    the minute after it, since the leaf wallet spends the same addresses' coins. What is
    not final yet shows as "<amount> <ticker> arriving" under the asset's figure.
- **User mode keeps BTC on the Bitcoin ark** (`app/lib/src/data/ark_btc_service.dart`,
  `ambra_core/src/ark_btc.rs`): Second's Bark client, from arca's `arca-wallet` crate,
  opened from the same recovery phrase against the ark server the default node serves
  (`Backend.bitcoinArk`, gRPC on the node's own address; testnet4 here; a custom node
  has none). BTC stays native bitcoin, which the holder can always take on the chain.
  - Confirmed BTC at the shared address moves in by itself: the kit pays it, less the
    fee, to a new board's funding address in one transaction, and the ark wallet boards
    that transaction (`board_funding_address`, `board_psbt`). Below 20,000 sat it stays on
    the chain. Never while something a person asked for runs, or in the minute after.
  - Send pays out of the ark, chosen without asking: an ark address in seconds, a BTC
    invoice (`lntb…`) over Lightning, a Bitcoin address on the chain after a Bitcoin
    block. What the ark cannot cover, or a payment it refuses, goes the way it always
    went.
  - BTC's one figure counts the ark; what is on its way in shows as "<amount> BTC
    arriving". Developer mode keeps BTC on the chain and in Lightning, by hand.
- Leaves are coins held as leaves of an operator's covenant tree on Sequentia: paid and
  received off the chain with the operator's co-signature, and always takeable on-chain
  by the holder. The wallet is the operator's own wallet library (`bark::arca` from
  [arca](https://github.com/ConcatenaLabs/arca)) linked into the Rust core
  (`ambra_core/src/leaves.rs`): every script, record, check, fee, schedule and refusal
  is the library's, and the app shows each refusal in the library's words.
- More > Leaves (`app/lib/src/screens/leaves_screen.dart`): join an operator (pins its
  key and the node's chain, and restores this phrase's leaves), the leaf balance per
  asset and state, receive (a request shown as text and QR, copied or shared), send to
  a request, settle now (the refresh fee shown before anything is signed), every coin
  with its dates, the exit drill, board from on-chain, and what the wallet refused.
- The Swap screen's leaf rail (developer mode, an operator joined, two Sequentia assets;
  `app/lib/src/data/leaf_rail.dart`, `app/lib/src/screens/leaf_rail_panel.dart`): "Pay
  from" and "Receive to" offer **Leaf** beside On-chain and Lightning, and a leg on Leaf
  is settled by the leaf panel in place of the screen's own review. Market, Leaf to Leaf:
  a take from leaves of the best on-chain order the operator's round can take (a
  transparent covenant order on the relay), its fill, price, fee and the operator's
  forfeit window shown first; beside it, accepting another wallet's in-tree swap offer,
  read first (what is got, given and paid, and the date by which the coins got must be
  taken on the chain) and accepted only on those terms. Limit, Leaf to Leaf: an in-tree
  swap offered to another wallet of the same operator (the offer holds the coins and signs
  nothing), completed with its acceptance in one reassignment the operator co-signs. BTC is
  never a leaf: a pair with BTC has no Leaf choice. An order placed on the chain from
  leaves is made in the web wallet or the browser wallet. User mode shows no Leaf choice.
- More > Contracts (developer mode, `app/lib/src/screens/contracts_screen.dart`): a spend
  of a contract the kit carries (`sequentia/faucet-drip`, `pignus/vault`, `pignus/offer`,
  `pignus/vault-threshold`, `pignus/offer-threshold`, `sequentia/capped-sale`,
  `sequentia/subscription-escrow`, `sequentia/one-key`, `sequentia/one-key-exit`), pasted in the shape a site hands the
  browser extension's `signContractSpend` (`{templateHash, instance, request | drip,
  fund?}`). The kit's contract engine (SWK `lwk_contracts`, in `ambra_core/src/contracts.rs`)
  checks it against this wallet: with `fund` the wallet adds its own explicit coins and the
  change; every wallet input is checked against the wallet's own record of its coins, the
  contract coin and every foreign coin against the chain's record, read from the wallet's
  own explorer; every program runs against the final transaction. The screen shows the
  engine's summary (the template, the path, the parameters by role, every input by what it
  is, the wallet's balance change in every asset, where the coins go, and the five checks)
  and signs only the digest of what it showed, with a contract key the path names or, on a
  path that takes no signature, none; the wallet's funding keys sign only its own coins.
- The leaf wallet's store is one SQLite file per recovery phrase in the app's support
  directory, opened by one process at a time. It keeps no phrase.
- While the app runs, the leaf wallet syncs on the library's schedule, with a foreground
  service keeping the process alive (`LeafSyncService.kt`). While it is closed, a
  scheduled job (`LeafSyncWorker.kt`, WorkManager) runs the Dart entry point
  `leafSyncJob` in an engine with no UI: it syncs, raises a notification for each
  payment received, and wakes again at the schedule's `next_sync_at`, at most a day
  ahead while a coin is off the chain or a receive request is open. The job keeps
  running whatever the mode, so coins already held keep their refresh. When the leaf
  wallet opens and whenever the app comes back to the foreground it syncs once,
  whatever the schedule says (the schedule wakes a planned coin only at its plan's
  `sync_by`).
- What the wallet does by itself, with no prompt, in either mode: at the first sync after
  the app starts and then at most every ten minutes (the app and the scheduled job keep
  one clock), it runs the library's `care`. `care` takes up every claim of a distribution
  named for an address the wallet handed out (it scans 20 past the wallet's next receive
  index, since the leaf wallet counts its keys apart from the main wallet); a claim taken
  up then counts in the asset's figure like any coin. It cancels each offline-refresh plan
  whose coin moved, and signs a plan for every leaf of a round at the first `care` after
  the leaf is made (`plan_within` set to plan every round leaf), two expiries ahead, so a
  wallet closed across an expiry keeps the coin, whenever it closes. Each step's fee is at
  most 0.2% of the coin and is taken from the coin in its own asset, never another; a coin
  the operator will not plan in its asset stays unplanned, and the sync refreshes it while
  the app is open. A coin of no round (a board, or a coin received or taken up out of
  round) is free to pay with, and is refreshed into a round once that refresh could run
  within ten days (it costs a fee, so it waits), then planned at a later sync.
- A planned coin carries refund halves the wallet signed, so no wallet pays it out of
  round. A payment, a trade or an order that the unplanned coins cannot cover is made
  through the next round, by itself: the library refuses it naming the planned coins whose
  release covers it (kind `planned`), the app gives those up in the next round for leaves
  of its own that no plan names (`plan_release`), syncs every 15 seconds until that round
  is final and the new leaves are held, and asks again (at most three releases, and three
  hours of waiting, after which it says that nothing was paid and the payment can be asked
  again). The person waits one round and sees nothing else. Every leaf command a screen
  starts goes through this one path (`LeafService.pay`, `payThroughRelease` in
  `app/lib/src/data/leaf_service.dart`), the user-mode Swap tab's included. A release
  costs the refresh fee the asset's schedule asks then (none in the coin's free window).
  Developer mode's Leaves screen shows the last `care` in a "Kept by itself" card (claims
  taken up, plans cancelled and made, coins refreshed into a round) with the
  distributions, the claims and the plans; each open plan has Cancel and Release
  (`plan_release` of the plan's current leaf, which ends the plan once that round is
  final), each planned leaf is marked under "Coins and their dates", and a "Paying through
  the next round" card stands while a payment waits for its round. User mode
  shows none of it.
- Supervised assets: an asset whose issuer can freeze holdings by a rule of the chain is
  held, received and paid like any other, and counted in its one figure. The library
  holds a coin of such an asset only as a landing-1 leaf, whose way out of the tree pays
  one key of the wallet's own, its landing key (the first on-chain key of the phrase,
  `landing_address` in the leaf wallet's `info`). A board, a refresh, a payment received
  and the change of a payment sent all land there; the app computes none of it. When the
  issuer freezes that key, or pauses the asset, the frozen part shows under the asset's
  figure on the balance, in either mode, as one sentence ("… is frozen by its issuer: it
  can't be sent until the issuer lifts the freeze"); it is never hidden. A payment of it
  is refused, in user mode in plain words ("This asset is frozen by its issuer for this
  wallet: nothing was sent."). Developer mode's Leaves screen shows each leaf's landing
  and whether it is frozen, with the library's note, and the landed coins on the chain
  that are frozen; such a leaf leaves the tree only into the landing key (the exit drill,
  or sync before its exit date), where the coin stays frozen on the chain until the issuer
  lifts the freeze, and is then spent like any coin. The operator serves no take, no
  resting order and no Lightning payment in a supervised asset, so user mode's Swap tab
  offers such an asset only through an in-tree swap with a live maker (`servedPairs`, in
  `app/lib/src/data/leaf_service.dart`).
- A payment the operator declines: the operator's signer refuses what it asks, and would
  refuse it again however often it were asked (the server's code `declined`), so the
  payment is refused for good. The library puts the coins back at once and sends nothing
  again; user mode reads "This payment was declined; nothing was sent.", and developer
  mode shows the operator's own words, which name the code. An operator that cannot be
  reached is no refusal: the payment stands, and the next sync sends it again.
- The operator's bond: the operator posts an equivocation bond, which two different
  messages its key signs under one coin's salt burn whole. At `care`'s pace, in either
  mode, while the app runs, the leaf wallet reads the bond (`bond`; once it has seen it
  bonded, it requires it from then on) and runs `watch_bond`, which checks the wallet's
  own evidence against the chain and the mempool and sends the slash itself should the
  operator key have signed twice. The library's gate does the rest: a receive or a swap is
  refused while the bond is missing or in notice, or when what the wallet would hold out
  of round is worth more than it. Nothing is said while the bond stands; a refusal reads,
  in user mode, "Not accepted: the security deposit that backs these instant payments is
  missing or being withdrawn, so this wallet takes no payment that rests on it. Nothing
  was signed." Developer mode's Leaves screen shows the bond (its state, asset and value,
  coin, when it can be withdrawn, whether this wallet requires it, whether it covers what
  the wallet holds out of round) and the last watch, with Watch now.
- Issuer-operated assets: the operator may serve an asset issuer-operated, where the
  issuer mints each round's float through the asset's mint limiter and every batch's sweep
  can only burn. The library checks each new leaf against that profile by itself.
  Developer mode's Leaves screen shows each leaf's batch profile under "Coins and their
  dates" (issuer-operated, or open) and, for each asset the operator serves
  issuer-operated, Supply: the operator's report of what it minted, burned and holds under
  burn-only sweeps, each mint and burn read again from the wallet's own node. It checks
  the transactions the report lists; it does not prove the list complete. User mode shows
  none of it.

**Assets, staking, faucet, node**
- Issue a new asset, reissue (mint more of) an asset you hold the reissuance token for,
  and burn (`app/lib/src/screens/assets_screen.dart`). The issued amount, the asset and its
  reissuance token go to the wallet's own addresses as explicit outputs, as a send does
  (`ambra_core/src/issuance.rs`).
- Stake the Sequence token (tSEQ) for block production: 40,000 tSEQ minimum, bonded to
  the staking key m/2/0 under a time-based lock of about 15 days
  (`app/lib/src/screens/stake_screen.dart`). Staking is the one thing the Sequence token
  is for; it is not privileged anywhere else in the wallet.
- Every stake of the wallet's staking key is listed under "Your stakes", whichever
  Sequentia wallet made it: the app's own time lock and the height lock of 43,200 blocks
  the web wallet and the extension bond with are both looked up on the explorer, along
  with unbonding outputs not yet returned. Unbonding takes two steps. Once a stake's lock
  has passed, **Unbond** moves it into an unbonding output of the same key (the fee, at
  most 1% of the stake, comes out of it); once the unbonding period has passed (2,016
  Bitcoin blocks after the Bitcoin block the unbond's block anchors to), **Return to
  wallet** pays it to a fresh address of the wallet. Where each stake stands is read
  from the chain every time, so a reorg moves it back (`ambra_core/src/staking.rs`).
- Faucet screen requesting tSEQ, USDX, EURX, GOLD, SILVR, or OILX from the public
  testnet faucet.
- Custom node: point the wallet at your own Sequentia node/backend (with optional HTTP
  auth) instead of the public testnet default (`app/lib/src/screens/node_screen.dart`).

## Consensus rules the UX must respect

Bitcoin **anchoring is supreme**: every Sequentia block references a Bitcoin block
header, and Sequentia reorganizes whenever Bitcoin reorganizes away an anchor, in real
time, overriding checkpoints and immediate finality. A transaction's real safety depth
is the **Bitcoin** confirmation depth of its block's anchor, not its Sequentia block
depth. Ambra never presents Sequentia finality as stronger than a Bitcoin reorg: swap
review sheets say "anchor-bound to Bitcoin (reverts only if Bitcoin reverts)", the
cross-chain swap gates its preimage reveal on an anchor check, and only the pure
Lightning rail (where nothing settles on-chain) is ever labeled final.

## Backend endpoints

The wallet defaults to the public Sequentia testnet node and derives every endpoint from
one origin (`app/lib/src/data/config.dart`), so switching to a custom node is one
change:

| Endpoint | Purpose |
|---|---|
| `<origin>/api` | Sequentia Esplora REST (sync, broadcast) |
| `<origin>/testnet4/api` | Bitcoin testnet4 Esplora REST |
| `<origin>/dex` | SeqDEX daemon (REST via grpc-gateway) |
| `<origin>/feerates` | Per-asset fee exchange rates |
| `<origin>/prices` | Reference-currency price server |
| `<origin>/registry/index.minimal.json` | Asset registry labels |
| `<origin>/faucet` | Testnet faucet |
| `<origin>/openamp` | OpenAMP restricted-asset API |
| `<origin>/lsp` | Hosted SeqLN LSP HTTP API |

The default origin is `https://sequentiatestnet.com`. The Lightning rail's websocket
endpoints and pinned host keys are separate constants in the same file and are enabled
only while the default origin is in use.

## Architecture

```
Flutter UI (app/)  --flutter_rust_bridge-->  ambra_core (Rust)  -->  SWK (lwk_wollet,
   Dart                                          |                    `sequentia` feature)
                                                 +-->  seqln-signer (Lightning device signer)
```

- **`app/`** is the Flutter application: screens, theme, and thin Dart service classes
  for the HTTP sidecars (faucet, prices, registry, SeqDEX, OpenAMP, LSP). See
  [`app/README.md`](app/README.md).
- **`ambra_core/`** is the shared Rust crate exposed to Dart via flutter_rust_bridge
  (pinned to 2.12.0). It consumes SWK's `lwk_wollet` with the `sequentia` cargo feature
  ON, which is where the whole Sequentia send-flow lives: any-asset fees, RBF/CPFP,
  transparent-by-default addresses, staking, the Bitcoin testnet4 wallet
  (`lwk_wollet::btc`), and the cross-chain HTLC glue (`lwk_wollet::btc::xchain`).
  SWK's own UniFFI bindings (`lwk_bindings`) build with that feature OFF and cannot
  reach these code paths, which is why Ambra has a dedicated core crate.
  It links the operator's wallet library (`arca-wallet` from
  [arca](https://github.com/ConcatenaLabs/arca), the `arca-core` feature) for leaves,
  with the core's own HTTP client as its transport.
  It also embeds `seqln-signer` (from the
  [seqln](https://github.com/ConcatenaLabs/seqln) repo): the phone-side
  Lightning signing kernel + Noise_XK transport that keeps the LSP rail non-custodial.
- **`docs/SPEC.md`** is the product/design spec (custody contract, navigation, design
  tokens, core API surface).

Key implementation detail: the core API is intentionally stateless per call. Dart passes
the mnemonic into each operation; the core derives what it needs, signs, and returns.
Scanned wallet state persists to the app's data dir (set once at startup) so cold starts
resume instead of re-scanning.

## Building from source

Verified toolchain: Linux host, Rust (stable), Flutter with Dart SDK >= 3.12,
Android SDK with **NDK 29.0.14206865** (pinned in `app/android/app/build.gradle.kts`),
`cargo-ndk`, `protoc` (`apt install protobuf-compiler`; the arca library compiles a
gRPC protocol), and flutter_rust_bridge_codegen 2.12.0 (only needed if you change the
core API).

`ambra_core` consumes SWK and seqln **by relative path**: both checkouts must sit as
siblings of the `ambra` repo (see `[patch.crates-io]` in `ambra_core/Cargo.toml`). The
arca library comes from GitHub at the revision `ambra_core/Cargo.toml` pins, with its
kit crates pointed at the same SWK checkout.

```sh
# 1. Sibling checkouts
git clone https://github.com/ConcatenaLabs/ambra.git
git clone -b sequentia https://github.com/ConcatenaLabs/SWK.git
git clone -b sequentia-stable https://github.com/ConcatenaLabs/seqln.git

# 2. Rust core (host build; also produces the cdylib the Flutter host tests load)
cd ambra/ambra_core
cargo build

# 3. Cross-compile the core for Android
rustup target add aarch64-linux-android
cargo install cargo-ndk
cargo ndk -t arm64-v8a -o ../app/android/app/src/main/jniLibs build --release
# (for the x86_64 emulator: rustup target add x86_64-linux-android; -t x86_64)

# 4. Build the app
cd ../app
flutter pub get
flutter build apk --release        # or: flutter run (device attached)
```

`app/android/app/src/main/jniLibs/` is gitignored; the `.so` is rebuilt on demand by
step 3. Release builds are signed with the Ambra release key when
`app/android/key.properties` (gitignored) is present; without it Gradle silently falls
back to the debug key, producing an APK that will not install over the published one
(`app/android/app/build.gradle.kts`).

If you change the `ambra_core::api` surface, regenerate the bridge from `app/`
(config in `app/flutter_rust_bridge.yaml`):

```sh
flutter_rust_bridge_codegen generate
```

## Tests

Rust core (from `ambra_core/`):

```sh
# Offline tests: architecture smoke test, Lightning signer conformance
# (a 99-frame corpus byte-compared against libhsmd's replies, less the device's two
# deliberate departures: covenant capabilities, watchtower-friendly penalties) and its payment limit
cargo test --test smoke --test signer_conformance --test payment_limit --test seqob_relay_offer

# Network tests (hit the live public testnet; run explicitly)
cargo test --test sync -- --nocapture

# Staking against a local sequentiad on a private elementsregtest chain: pools
# (join, move and leave confirmed in blocks, wrong signatures refused by a block) and
# stakes under both locks found, unbonded and returned (early steps refused by a block)
SEQUENTIAD_EXEC=/path/to/sequentiad cargo test --test stake_records -- --nocapture

# Contract spends against a local sequentiad: a faucet drip and a Pignus vault
# repaid with the wallet's own coins, each summary checked and each spend confirmed,
# and the refusals (a digest not shown, a wallet coin said to be in another asset,
# a foreign coin the chain does not back, a template the wallet does not carry)
SEQUENTIAD_EXEC=/path/to/sequentiad cargo test --test contracts -- --nocapture

# Leaves against a whole operator: a payment received while the app is closed,
# found by the scheduled job's pass, and two wallets swapping two assets in the
# tree through the core (offer, read, acceptance on the terms read, completion). Needs arca's long-running operator harness
# (bark-cli/tests/arca_operator_for_browsers.rs in the arca repo) at its control
# address; without the variable the test says so and passes without running.
AMBRA_LEAVES_HARNESS=http://127.0.0.1:18640 cargo test --test leaves -- --nocapture
```

A bare `cargo test` runs the network tests too, and fails `stake_records` and
`contracts` unless `SEQUENTIAD_EXEC` is set, so prefer the explicit forms.

Flutter (from `app/`):

```sh
flutter test test/lsp_client_test.dart        # pure-Dart, mocked HTTP, runs anywhere
flutter test                                  # all tests; see the caveat below
```

Caveat: `test/widget_test.dart` and `test/seqln_device_key_test.dart` drive the real
Rust core through flutter_rust_bridge on the host. They resolve the cdylib from
`$AMBRA_CORE_LIB`, defaulting to `../ambra_core/target/debug/libambra_core.so`
(relative to `app/`), so run `cargo build` in `ambra_core/` first or set the variable.

## Sequentia ecosystem

| Repo | One-liner |
|---|---|
| [Sequentia](https://github.com/ConcatenaLabs/Sequentia) | The Sequentia node (`sequentiad`, a fork of Elements 23.3.3): consensus, anchoring, proof of stake, open fee market, plus the canonical protocol documentation in `doc/sequentia/`. |
| [SWK](https://github.com/ConcatenaLabs/SWK) | Sequentia Wallet Kit: a fork of Blockstream LWK, providing the Rust wallet library, CLI, and WASM bindings for building Sequentia (and Bitcoin testnet4) wallets. |
| [sequentia-web-wallet](https://github.com/ConcatenaLabs/sequentia-web-wallet) | Proof-of-concept browser wallet built on SWK, live at https://sequentiatestnet.com/wallet. |
| [seqdex](https://github.com/ConcatenaLabs/seqdex) | SeqDEX: non-custodial atomic-swap DEX with an on-chain covenant order book (SeqOB) served over a relay, same-chain swaps, and cross-chain BTC↔asset swaps made safe by Bitcoin anchoring. |
| [seqln](https://github.com/ConcatenaLabs/seqln) | SeqLN: a Core Lightning fork that runs on Sequentia and Bitcoin from the same binary, with asset channels, any-asset payments, and pure-Lightning swaps. |
| [openamp](https://github.com/ConcatenaLabs/openamp) | OpenAMP: open-source restricted-asset issuance/transfer-approval service (an AMP2 equivalent) with opt-in confidentiality; zero consensus changes. |
| [fulmen](https://github.com/ConcatenaLabs/fulmen) | Fulmen: desktop (Electron) wallet for SeqLN with a bundled Lightning node. |
| [sequentia-extension](https://github.com/ConcatenaLabs/sequentia-extension) | Ambra for Chromium: the same dual-chain wallet as a browser extension, plus the `window.sequentia` API websites use to reach it. |

## Contributing

Development happens on `main`; open PRs against it. The Sequentia-specific logic worth
knowing before you start: `ambra_core/src/api/mod.rs` (the whole FFI surface),
`app/lib/src/data/config.dart` (endpoints + asset labels), and
`app/lib/src/screens/shell.dart` (the tab shell and balance model). Never commit
secrets: no real seeds, keys, or credentials belong in this public repo (test fixtures
use only the well-known all-zero BIP39 vector).

## License

MIT, in [LICENSE](LICENSE) and declared in `ambra_core/Cargo.toml`.
