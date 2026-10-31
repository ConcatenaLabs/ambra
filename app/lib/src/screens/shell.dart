import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../rust/api.dart' as core;
import '../data/ark_btc_service.dart';
import '../data/asset_picker.dart';
import '../data/btc_lightning.dart' show decodeBtcInvoice;
import '../data/btc_state.dart';
import '../data/channel_move_service.dart';
import '../data/config.dart';
import '../data/default_words.dart';
import '../data/descriptor.dart';
import '../data/dev_mode.dart';
import '../data/fee_asset_rule.dart';
import '../data/format.dart';
import '../data/hidden_assets.dart';
import '../data/lightning_to_ark.dart';
import '../data/pay_code.dart';
import '../data/problem_report.dart' show ReportWords;
import '../data/leaf_service.dart';
import '../data/lightning_service.dart';
import '../data/ln_payment_limit.dart';
import '../data/ln_rail.dart';
import '../data/portfolio.dart';
import '../data/lsp_client.dart';
import '../data/node_config.dart';
import '../data/openamp_service.dart';
import '../data/price_service.dart';
import '../data/registry_service.dart';
import '../data/seqln_keys.dart' as lnkeys;
import '../data/site_link.dart' show SiteLinkWords;
import '../data/site_service.dart';
import '../data/stakes.dart';
import '../data/subasset_buy_service.dart';
import '../data/subasset_sell_service.dart';
import '../data/subswap_service.dart';
import '../data/wallet_cache.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/ln_cards.dart';
import 'contracts_screen.dart';
import 'report_screen.dart';
import 'leaves_screen.dart';
import '../widgets/restricted_asset_detail.dart';
import '../widgets/widgets.dart';
import 'assets_screen.dart';
import 'faucet_screen.dart';
import 'history_screen.dart';
import 'node_screen.dart';
import 'send_screen.dart';
import 'mix_screen.dart';
import 'sites_screen.dart';
import 'stake_screen.dart';
import 'swap_screen.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // The wallet is unlocked once the Shell is shown. Bring the on-device
    // Lightning signer online (the mobile twin of the web wallet's post-unlock
    // initLightning), so the "Instant (Lightning)" swap rail becomes available.
    // Non-fatal + opt-in: no-op unless a hosted LSP is configured for this build
    // (Backend.lnWsUrl / lnHostPubkey), and idempotent if already serving.
    _initLightning();
    // Register this wallet's x-only key with the OpenAMP enclave so restricted
    // assets can be held/received/sent. Fails soft if the enclave isn't deployed.
    _initOpenamp();
    // The wallet's mode is kept for each wallet. A wallet that joined a leaf operator
    // keeps its leaf wallet open and syncing on its schedule while the app runs, in
    // either mode: its coins have dates to keep. User mode only hides the rail.
    DevMode.instance.addListener(_onMode);
    _loadMode();
  }

  Future<void> _loadMode() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m != null) await DevMode.instance.loadFor(m);
    _onMode();
    // The sites this wallet is connected to reach it while the wallet is open.
    unawaited(AmbraSites.instance.start());
  }

  @override
  void dispose() {
    DevMode.instance.removeListener(_onMode);
    unawaited(AmbraSites.instance.stop());
    super.dispose();
  }

  void _onMode() {
    // Opens only a leaf wallet this phone holds for the mnemonic (`start` checks).
    if (!LeafService.instance.open) unawaited(LeafService.instance.start());
    // The Bitcoin ark wallet stays open in both modes, so BTC held there is always counted;
    // only user mode moves BTC into it and pays from it by itself.
    unawaited(ArkBtcService.instance.start());
  }

  Future<void> _initLightning() async {
    // AUTHORITATIVE PRIMING BEFORE UI (fund-loss, Task 1): FIRST — before the LN gate, before any resume
    // I/O, and REGARDLESS of whether Lightning is deployed — PRIME the synchronous submarine in-flight
    // guard from the persisted record (AWAITED). Mirrors the web wallet's SYNCHRONOUS module-eval hydration
    // of hasSubswapInFlight (swap.js): the guard is authoritative before the Swap tab is interactive, so a
    // fresh _start / _dispatchSubmarine can never fail open and clobber a live record. Fails safe (assumes
    // in-flight) on any read error, so priming never leaves the guard open.
    await SubswapStore.primeInFlight();
    if (!LightningService.instance.configured) return; // LN not deployed here (guard already primed)
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    await LightningService.instance.start(m);
    // Finish any Move to Lightning whose deposit already landed: the funds are ON the user's hosted
    // node with no channel, and before this there was no record that one was owed — the sheet polled
    // for four minutes, said "check back shortly" and forgot. Re-drives from the persisted record.
    // Then bring every hosted node of this wallet back online (a node restarted while this phone was
    // away answers nothing until its device is attached, and its channels look gone), and finish a
    // deposit no record remembers: a reinstall loses the records, never the nodes.
    unawaited(() async {
      await ChannelMoveService.resume();
      await ChannelMoveService.recoverFromNodes();
    }());
    // Fund-recovery on cold start: resume any in-flight sub-asset swap so a locked BTC HTLC settles or
    // refunds (BUY) and an unclaimed BTC gets re-claimed (SELL) even if the user never re-opens Swap.
    // Fire-and-forget: each loads its own persisted record and no-ops when there is nothing to resume.
    unawaited(SubassetBuyService.resume());
    unawaited(SubassetSellService.resume());
    // Resume any in-flight P2P SUBMARINE (settle a HELD Bitcoin hold with P, re-claim a paid-but-unclaimed
    // asset on a BUY, or fire the CLTV refund past T_seq on a SELL) — even if the user never re-opens Swap.
    // This heavy settlement drive runs UNAWAITED, AFTER priming (Task 1). A read failure inside it must be
    // OBSERVED, not swallowed, and must never leave the guard OPEN: load() already fails safe (guard closed),
    // and this .catchError reaffirms it for the session so no _start / _dispatch clobbers a live record.
    unawaited(SubswapService.resume().catchError((Object e) {
      SubswapStore.markInFlight(true);
    }));
  }

  Future<void> _initOpenamp() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m != null) await OpenAmpService.instance.ensureRegistered(m);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      BalanceTab(isActive: _tab == 0),
      SendTab(isActive: _tab == 1),
      const ReceiveTab(),
      SwapTab(isActive: _tab == 3),
      HistoryTab(isActive: _tab == 4),
      const MoreTab(),
    ];
    // TODO(device-verify): confirm the Android hardware/gesture back returns to
    // Balance from other tabs and only exits from Balance (needs a device).
    return PopScope(
      // Android back should return to the Balance tab from any other tab, and only
      // exit the app when already on Balance — not drop out of the wallet on the
      // first back press from Send/Swap/History/More.
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) setState(() => _tab = 0);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AmbraBackground(child: SafeArea(bottom: false, child: IndexedStack(index: _tab, children: tabs))),
        bottomNavigationBar: _BottomBar(index: _tab, onTap: (i) => setState(() => _tab = i)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Balance (M3: shows network + your main receive address; live balances = M4)
// ---------------------------------------------------------------------------
class BalanceTab extends StatefulWidget {
  const BalanceTab({super.key, this.isActive = false});
  final bool isActive;
  @override
  State<BalanceTab> createState() => _BalanceTabState();
}

class _BalanceTabState extends State<BalanceTab> {
  core.WalletSync? _sync;
  core.BtcBalance? _btc; // parent-chain (testnet4) balance, first-class like any asset
  String? _btcCachedSats; // last-known BTC sats from disk, shown if a fresh scan fails
  bool _btcStale = false; // true when the shown BTC balance is last-known (scan failed)
  List<core.AssetBalance>? _cachedBalances; // last-known, shown instantly while syncing
  List<core.AssetBalance> _openamp = const []; // restricted-asset balances (enclave)
  // This device's OWN Lightning channels (node_key present), read back from the LSP so each balance
  // row can show its on-chain vs Lightning split. Only OWN channels count as this wallet's funds
  // (fresh-wallet rule): a shared/demo channel the LSP also reports is never folded in.
  List<Map<dynamic, dynamic>> _lnChannels = const [];
  String? _error;
  bool _loading = true;
  DateTime? _lastSync; // time of the last successful Sequentia sync (for the chip)
  bool _syncFailed = false; // the latest refresh errored (chip shows offline + last-sync time)
  // Whether the collapsed "Hidden assets (N)" section is expanded. Session-only
  // on purpose: it always starts collapsed (that's the decluttering).
  bool _hiddenOpen = false;

  @override
  void initState() {
    super.initState();
    PriceService.instance.addListener(_onPrice);
    DevMode.instance.addListener(_onPrice);
    LeafService.instance.addListener(_onPrice);
    LightningToArk.instance.addListener(_onPrice);
    ArkBtcService.instance.addListener(_onPrice);
    StakeHoldings.instance.addListener(_onPrice);
    // Asset labels can arrive after first paint (network registry); rebuild so
    // rows show the real ticker/precision instead of a hex placeholder.
    RegistryService.instance.addListener(_onPrice);
    _loadCached(); // show outdated balances at once, refresh below
    _refresh(); // eager: every tab loads at launch (cheap now that the wallet is cached)
  }

  Future<void> _loadCached() async {
    final b = await WalletCache.loadBalances();
    final btcSats = await WalletCache.loadBtc();
    if (mounted && _sync == null) {
      setState(() {
        if (b != null) _cachedBalances = b;
        if (btcSats != null && _btc == null) _btcCachedSats = btcSats;
      });
    }
  }

  @override
  void didUpdateWidget(BalanceTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-sync whenever this tab becomes visible (assets may have arrived while
    // the user was on another tab).
    if (widget.isActive && !oldWidget.isActive) _refresh();
  }

  void _onPrice() {
    if (!mounted) return;
    setState(() {});
    // A board just spent coins on the chain: read the chain again, so they are not counted there
    // and as arriving at once.
    final boards = LeafService.instance.boardsMade + ArkBtcService.instance.boardsMade;
    if (boards != _boardsSeen) {
      _boardsSeen = boards;
      unawaited(_refresh());
    }
  }

  int _boardsSeen = 0;

  @override
  void dispose() {
    PriceService.instance.removeListener(_onPrice);
    DevMode.instance.removeListener(_onPrice);
    LeafService.instance.removeListener(_onPrice);
    LightningToArk.instance.removeListener(_onPrice);
    ArkBtcService.instance.removeListener(_onPrice);
    StakeHoldings.instance.removeListener(_onPrice);
    RegistryService.instance.removeListener(_onPrice);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _error = null);
    PriceService.instance.refreshPrices();
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      // The per-wallet hidden set drives the visible/hidden row split below. A local
      // prefs read, awaited so the first render already partitions correctly.
      await HiddenAssets.instance.loadFor(m);
      // Scan both chains. Kick off the Bitcoin scan concurrently; a BTC failure
      // must not break the Sequentia balance, so it resolves to null on error.
      final btcF = () async {
        try {
          return await core.btcSync(mnemonic: m, t4Api: Backend.testnet4);
        } catch (_) {
          return null;
        }
      }();
      // Restricted (OpenAMP) balances load in parallel; a failure must not break
      // the on-chain balance, so it resolves to the last-known list on error.
      final ampF = OpenAmpService.instance.refresh(m);
      // This device's OWN Lightning channels, read apart from the on-chain sync (a sync that fails,
      // as on an origin whose explorer does not answer, must not hide what the wallet holds in
      // Lightning). Non-blocking so the balance render never waits on the LSP.
      final lnBalances = _sync?.balances ?? _cachedBalances ?? const <core.AssetBalance>[];
      unawaited(_refreshLn(m, lnBalances));
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      final btc = await btcF;
      final amp = await ampF;
      WalletCache.saveBalances(s.balances); // persist for the next launch
      if (btc != null) WalletCache.saveBtc(btc.balanceSats); // persist last-known BTC
      // Feed both chains' indices into the shared cross-chain receive cycling.
      BtcState.instance.observe(btc: btc, seqNext: s.nextIndex);
      // Read again only when the sync found an asset the read above did not name a node for.
      final named = {for (final b in lnBalances) b.assetId};
      if (s.balances.any((b) => !named.contains(b.assetId))) unawaited(_refreshLn(m, s.balances));
      // What is staked is the holder's Sequence token and counts in its figure; read
      // from the explorer at most every few minutes (the stake screen reads it at once).
      unawaited(StakeHoldings.instance.refresh(m));
      if (mounted) {
        setState(() {
          _sync = s;
          _openamp = amp;
          _lastSync = DateTime.now();
          _syncFailed = false;
          if (btc != null) {
            _btc = btc;
            _btcCachedSats = btc.balanceSats;
            _btcStale = false;
          } else {
            // The testnet4 scan failed. Keep showing the last-known BTC balance
            // (fresh _btc or the disk cache) marked offline, instead of silently
            // dropping the row while the sync chip reads green.
            _btcStale = _btc != null || _btcCachedSats != null;
          }
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _syncFailed = true; // latest refresh failed; chip reflects it (may show stale data)
          // Surface an error only when there's nothing (not even stale data) to show.
          if (_sync == null && _cachedBalances == null) _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  /// Read this device's OWN provisioned Lightning channels from the LSP so each row can show its
  /// on-chain vs Lightning split and the Move-to-Lightning / close affordances. Passes the device's
  /// own node keys (BTC + each held asset), reconstructed from the mnemonic, as `?nodes=` so the
  /// status includes channels this wallet opened even across restarts. OWN-only (node_key present):
  /// a shared/demo channel is never counted as this wallet's funds. Best-effort + fully gated on
  /// [LightningService.configured] — a no-op when Lightning is dormant.
  Future<void> _refreshLn(String mnemonic, List<core.AssetBalance> balances) async {
    if (!LightningService.instance.configured) return;
    try {
      // Every registry-known asset, not just assets with an on-chain balance: an asset held ONLY inside
      // a channel (0 on-chain) still has a node/channel this view must show its Lightning split + close
      // affordance for. Keying off balances alone hid those channels. Set-dedup; union the balance ids.
      final nodes = lnkeys.ownNodeKeysFor(mnemonic, [...SeqAssets.resolvedIds, for (final b in balances) b.assetId]);
      final st = await LightningService.instance.getStatus(nodes: nodes);
      final own = ((st.raw['channels'] as List?) ?? const [])
          .whereType<Map>()
          .where((c) => '${c['node_key'] ?? ''}'.isNotEmpty)
          .toList();
      if (mounted) setState(() => _lnChannels = own);
    } catch (_) {/* LN status best-effort; the balance rows still render on-chain amounts */}
  }

  @override
  Widget build(BuildContext context) {
    // Prefer fresh sync data; fall back to cached balances so a launch shows the
    // last-known values instantly instead of a spinner. tSEQ is not privileged,
    // so a 0 balance is hidden like any other asset's.
    final onchainBalances = _sync?.balances ?? _cachedBalances;
    // Everything the wallet holds of an asset counts in its one figure and in the
    // headline, in both modes: on-chain, leaves (once this wallet joined an operator;
    // the leaf wallet syncs in either mode), Lightning (its own channels, the reserve
    // included) and, for the Sequence token, what is staked. User mode shows one figure
    // per row, its parts one tap away; developer mode splits it beside the row and
    // keeps the Lightning controls.
    final dev = DevMode.instance.on;
    final leafAtoms = LeafService.instance.joined ? LeafService.instance.leafAtoms() : const <String, BigInt>{};
    // What is on its way (user mode shows "<amount> <TICKER> arriving" under the figure): an
    // asset with nothing yet but something arriving still gets its row.
    final arriving = LeafService.instance.joined ? LeafService.instance.arrivingAtoms() : const <String, BigInt>{};
    final redoing = LeafService.instance.joined ? LeafService.instance.redoingAtoms() : const <String, BigInt>{};
    final onchainOf = {
      for (final b in onchainBalances ?? const <core.AssetBalance>[])
        b.assetId: LeafService.instance.onchainLessBoards(b.assetId, BigInt.tryParse(b.atoms) ?? BigInt.zero)
    };
    final chans = _lnChannels.cast<Map>();
    // What is on its way from a channel to the tree stays in the figure until its leaf counts.
    final moving = dev ? const <String, BigInt>{} : LightningToArk.instance.movingAssets;
    BigInt lnOf(String id) =>
        legLiquidity(chans, RailTarget.asset(hex: id, ticker: SeqAssets.labelFor(id).ticker)).balance + (moving[id] ?? BigInt.zero);
    final stakedAtoms = StakeHoldings.instance.stakedAtoms;
    final staked = {if (stakedAtoms > BigInt.zero) SeqAssets.policy: stakedAtoms};
    final lnAssets = <String>{
      for (final c in chans)
        if ('${c['node_key'] ?? ''}'.isNotEmpty && '${c['leg'] ?? ''}' != 'btc' && '${c['asset'] ?? ''}'.isNotEmpty) '${c['asset']}',
    };
    final figures = onchainBalances == null
        ? null
        : assetFigures(
            onchain: onchainOf,
            leaves: leafAtoms,
            lightning: {for (final id in {...onchainOf.keys, ...leafAtoms.keys, ...arriving.keys, ...lnAssets, ...moving.keys}) id: lnOf(id)},
            staked: staked,
          );
    final figureOf = {for (final f in figures ?? const <AssetFigure>[]) f.id: f};
    final balances = figures == null
        ? null
        : [for (final f in figures) core.AssetBalance(assetId: f.id, atoms: f.total.toString())];
    // Restricted (OpenAMP) assets sit among equals — appended to the on-chain
    // rows, counted equally in the total, with no privileged label.
    final held = balances == null
        ? _openamp.toList()
        : [
            ...balances.where((b) =>
                (BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero ||
                (!dev && (arriving.containsKey(b.assetId) || moving.containsKey(b.assetId)))),
            ..._openamp,
          ];
    // Bitcoin is first-class: on-chain (the last-known balance if a fresh testnet4
    // scan failed) plus Lightning. Its row comes first and is listed even at 0.
    final btcSatsStr = _btc?.balanceSats ?? _btcCachedSats;
    final btcOnchain = BigInt.tryParse(btcSatsStr ?? '0') ?? BigInt.zero;
    final btcLn = legLiquidity(chans, RailTarget.btc()).balance;
    // User mode: what the Bitcoin ark holds and has on its way counts in BTC's one figure.
    final btcArk = ArkBtcService.instance.held;
    final btcTotal = btcOnchain + btcLn + btcArk;
    final hasBtc = btcTotal > BigInt.zero;
    // Headline total: computed over EVERY asset and every rail, hidden assets
    // included (see below) — hiding is visual decluttering, not accounting, so the
    // total never changes on hide.
    final total = balances == null
        ? null
        : headlineTotal([
            for (final b in [...balances, ..._openamp]) (key: b.assetId, atoms: BigInt.tryParse(b.atoms) ?? BigInt.zero),
            if (btcSatsStr != null || btcLn > BigInt.zero || btcArk > BigInt.zero) (key: 'BTC', atoms: btcTotal),
          ], (key, atoms) {
            if (key == 'BTC') return PriceService.instance.refValue('BTC', atoms.toString(), 8);
            final label = SeqAssets.labelFor(key);
            return PriceService.instance.refValue(label.ticker, atoms.toString(), label.precision);
          });
    // Split the rows into the visible main list and the collapsed hidden section
    // (AFTER the total above). BTC is never partitioned out — its row below carries
    // no hide control at all. held is positive-balance-only already, so totalOf is
    // the row's figure.
    final byId = {for (final b in held) b.assetId: b};
    final part = partitionHidden(byId.keys, HiddenAssets.instance.hidden,
        totalOf: (h) => BigInt.tryParse(byId[h]!.atoms) ?? BigInt.zero);
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AmbraColors.amber,
      backgroundColor: AmbraColors.panel,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Row(children: [
            const BrandMark(size: 34),
            const SizedBox(width: 12),
            const Text('Ambra', style: AmbraText.title),
            const Spacer(),
            _RefChip(ref: PriceService.instance.ref),
            const SizedBox(width: 10),
            _SyncChip(loading: _loading, tip: _sync?.tipHeight, failed: _syncFailed, lastSync: _lastSync),
          ]),
          const SizedBox(height: 28),
          Text('TOTAL BALANCE', style: AmbraText.label),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(total == null ? '—' : PriceService.instance.fmtRef(total), style: AmbraText.hero),
            const SizedBox(width: 8),
            Text(PriceService.instance.ref,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AmbraColors.amber2)),
          ]),
          if (balances != null && total == null)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Live prices unavailable; see per-asset amounts below.', style: AmbraText.sub),
            ),
          const SizedBox(height: 24),
          if (_error != null && balances == null)
            AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red)))
          else if (balances == null)
            const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
          else ...[
            if (held.isEmpty && !hasBtc) ...[
              const AmbraCard(
                  child: Text(
                      'No funds yet. Get free testnet coins from the faucet (More tab), '
                      'or share your address on Receive.',
                      style: AmbraText.muted)),
              const SizedBox(height: 18),
            ],
            Text('ASSETS', style: AmbraText.label),
            const SizedBox(height: 10),
            AmbraCard(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Column(children: [
                _BtcRow(
                      sats: btcTotal.toString(),
                      onchainSats: btcOnchain,
                      lightningSats: btcLn,
                      arrivingSats: dev ? null : ArkBtcService.instance.arriving,
                      stale: _btcStale,
                      channels: _lnChannels,
                      onChanged: _refresh,
                      dev: dev),
                for (final h in part.visible)
                  _AssetRow(
                    balance: byId[h]!,
                    figure: figureOf[h],
                    dev: dev,
                    leavesJoined: LeafService.instance.joined,
                    frozen: LeafService.instance.joined ? LeafService.instance.frozenAtoms(h) : BigInt.zero,
                    arriving: arriving[h],
                    redoing: redoing[h],
                    moving: moving[h],
                    channels: _lnChannels,
                    onChanged: _refresh,
                    onHide: () async {
                      await HiddenAssets.instance.setHidden(h, true);
                      if (mounted) setState(() {});
                    },
                  ),
                if (part.hidden.isNotEmpty)
                  _HiddenAssetsSection(
                    rows: [for (final h in part.hidden) byId[h]!],
                    open: _hiddenOpen,
                    onToggle: () => setState(() => _hiddenOpen = !_hiddenOpen),
                    onUnhide: (h) async {
                      await HiddenAssets.instance.setHidden(h, false);
                      if (mounted) setState(() {});
                    },
                  ),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

class _AssetRow extends StatefulWidget {
  const _AssetRow(
      {required this.balance,
      this.figure,
      this.dev = false,
      this.leavesJoined = false,
      this.frozen,
      this.arriving,
      this.redoing,
      this.moving,
      this.channels = const [],
      this.onChanged,
      this.onHide});
  // The row's figure: everything the wallet holds of the asset.
  final core.AssetBalance balance;
  // Its parts (null for a restricted asset, which is held in the enclave alone).
  final AssetFigure? figure;
  // Developer mode: the parts beside the row and the Lightning controls. User mode:
  // one figure, its parts one tap away.
  final bool dev;
  final bool leavesJoined;
  // What of the asset its issuer has frozen for this wallet: one plain sentence under
  // the figure, in both modes, never hidden.
  final BigInt? frozen;

  /// User mode: what of the asset is arriving (counted in the figure, not final yet).
  final BigInt? arriving;

  /// User mode: of what is arriving, what a Bitcoin reorganisation took back out of the chain and
  /// is being redone: said apart, never as gone.
  final BigInt? redoing;

  /// User mode: what of the asset is on its way from its channel to the tree.
  final BigInt? moving;
  final List<Map<dynamic, dynamic>> channels;
  final VoidCallback? onChanged;
  // Per-asset Hide control (quiet trailing icon). null = no control — the BTC row
  // ([_BtcRow]) has no such parameter at all: the parent-chain asset is never hideable.
  final VoidCallback? onHide;
  @override
  State<_AssetRow> createState() => _AssetRowState();
}

class _AssetRowState extends State<_AssetRow> {
  bool _open = false;

  // Of what is arriving, what is being redone is said on its own line.
  BigInt get _redoing {
    final a = widget.arriving ?? BigInt.zero, r = widget.redoing ?? BigInt.zero;
    return r > a ? a : r;
  }

  BigInt get _arrivingOnly => (widget.arriving ?? BigInt.zero) - _redoing;

  @override
  Widget build(BuildContext context) {
    final balance = widget.balance;
    final figure = widget.figure;
    final label = SeqAssets.labelFor(balance.assetId);
    final amount = formatAtoms(balance.atoms, label.precision);
    // Restricted (OpenAMP enclave) assets are not on-chain UTXOs, so they can't be moved into a
    // Lightning channel; only issued on-chain assets get the split. The same flag opens the
    // restriction-disclosure detail sheet on tap.
    final restricted = OpenAmpService.instance.isRestricted(balance.assetId);
    final movable = !restricted;
    final parts = figure == null ? const <(String, BigInt)>[] : splitParts(figure, dev: widget.dev);
    final VoidCallback? onTap = restricted
        ? () => showRestrictedAssetDetail(context, balance.assetId)
        : (!widget.dev && parts.isNotEmpty ? () => setState(() => _open = !_open) : null);
    return Column(children: [
      InkWell(
        key: Key('row-${label.ticker}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.ticker,
                    style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 2),
                Text(label.subtitle ?? balance.assetId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: label.subtitle != null ? AmbraText.sub : AmbraText.mono.copyWith(fontSize: 11)),
              ]),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Text(amount,
                  style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w700)),
              if (PriceService.instance.approx(label.ticker, balance.atoms, label.precision) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(PriceService.instance.approx(label.ticker, balance.atoms, label.precision)!,
                      style: AmbraText.sub),
                ),
            ]),
            if (widget.onHide != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: 'Hide this asset. It still counts toward your total and stays findable by search.',
                  child: InkWell(
                    onTap: widget.onHide,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.visibility_off_outlined, size: 16, color: AmbraColors.dim),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
      if ((widget.frozen ?? BigInt.zero) > BigInt.zero)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(frozenSentence(formatAtoms(widget.frozen.toString(), label.precision), label.ticker),
                key: Key('frozen-${label.ticker}'), style: const TextStyle(color: AmbraColors.amber2, fontSize: 12)),
          ),
        ),
      if (!widget.dev && (widget.moving ?? BigInt.zero) > BigInt.zero)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(DefaultWords.moving(formatAtoms(widget.moving.toString(), label.precision), label.ticker),
                key: Key('moving-${label.ticker}'), style: AmbraText.sub),
          ),
        ),
      if (!widget.dev && _arrivingOnly > BigInt.zero)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(DefaultWords.arriving(formatAtoms(_arrivingOnly.toString(), label.precision), label.ticker),
                key: Key('arriving-${label.ticker}'), style: AmbraText.sub),
          ),
        ),
      if (!widget.dev && _redoing > BigInt.zero)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(DefaultWords.redoing(formatAtoms(_redoing.toString(), label.precision), label.ticker),
                key: Key('redoing-${label.ticker}'), style: AmbraText.sub),
          ),
        ),
      if (!widget.dev && _open && parts.isNotEmpty)
        _SplitLine(ticker: label.ticker, precision: label.precision, parts: parts),
      if (widget.dev && figure != null)
        _RailLine(
          ticker: label.ticker,
          precision: label.precision,
          onchain: figure.onchain,
          leaves: widget.leavesJoined || figure.leaves > BigInt.zero ? figure.leaves : null,
          lightning: figure.lightning,
          staked: figure.staked,
        ),
      if (widget.dev && movable)
        _LnMeta(
          channels: widget.channels,
          leg: _Leg(
            chain: 'seq',
            asset: balance.assetId,
            ticker: label.ticker,
            precision: label.precision,
            target: RailTarget.asset(hex: balance.assetId, ticker: label.ticker),
            onchainAtoms: figure?.onchain ?? BigInt.tryParse(balance.atoms) ?? BigInt.zero,
          ),
          onChanged: widget.onChanged,
        ),
    ]);
  }
}

/// User mode: a figure's parts in plain words, under the row once it is tapped. Only
/// the parts held.
class _SplitLine extends StatelessWidget {
  const _SplitLine({required this.ticker, required this.precision, required this.parts});
  final String ticker;
  final int precision;
  final List<(String, BigInt)> parts;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          parts.map((p) => '${p.$1} ${formatAtoms(p.$2.toString(), precision)}').join('  ·  '),
          key: Key('split-$ticker'),
          style: AmbraText.sub,
        ),
      ),
    );
  }
}

/// The collapsed "Hidden assets (N)" section at the bottom of the balance list —
/// the only place a hidden balance is listed, and the way back (per-asset Unhide).
/// These balances were already counted into the headline total: hiding never
/// changes accounting, only what the main list shows.
class _HiddenAssetsSection extends StatelessWidget {
  const _HiddenAssetsSection({required this.rows, required this.open, required this.onToggle, required this.onUnhide});
  final List<core.AssetBalance> rows;
  final bool open;
  final VoidCallback onToggle;
  final Future<void> Function(String hex) onUnhide;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: AmbraColors.dim),
            const SizedBox(width: 6),
            Text('Hidden assets (${rows.length})', style: AmbraText.sub),
            const Spacer(),
          ]),
        ),
      ),
      if (open)
        for (final b in rows) _hiddenRow(b),
    ]);
  }

  Widget _hiddenRow(core.AssetBalance b) {
    final label = SeqAssets.labelFor(b.assetId);
    final approx = PriceService.instance.approx(label.ticker, b.atoms, label.precision);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: 0.75,
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label.ticker,
                  style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 2),
              Text(label.subtitle ?? b.assetId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: label.subtitle != null ? AmbraText.sub : AmbraText.mono.copyWith(fontSize: 11)),
            ]),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            Text(formatAtoms(b.atoms, label.precision),
                style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 14, fontWeight: FontWeight.w700)),
            if (approx != null)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text(approx, style: AmbraText.sub)),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Tooltip(
              message: 'Show this asset in the balance list and the default pickers again.',
              child: InkWell(
                onTap: () => onUnhide(b.assetId),
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.visibility_outlined, size: 16, color: AmbraColors.dim),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The Bitcoin parent-chain balance row — first-class, same layout as [_AssetRow].
class _BtcRow extends StatefulWidget {
  const _BtcRow(
      {required this.sats,
      required this.onchainSats,
      required this.lightningSats,
      this.stale = false,
      this.channels = const [],
      this.onChanged,
      this.dev = false,
      this.arrivingSats});
  // Developer mode: the parts beside the row and the Lightning controls.
  final bool dev;
  // The row's figure: on-chain and Lightning together.
  final String sats;
  final BigInt onchainSats;
  final BigInt lightningSats;

  /// User mode: BTC on its way into the ark, shown under the figure.
  final BigInt? arrivingSats;
  final bool stale; // showing the last-known balance because the latest scan failed
  final List<Map<dynamic, dynamic>> channels;
  final VoidCallback? onChanged;
  @override
  State<_BtcRow> createState() => _BtcRowState();
}

class _BtcRowState extends State<_BtcRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final amount = formatAtoms(widget.sats, 8);
    final approx = PriceService.instance.approx('BTC', widget.sats, 8);
    final parts = [('On-chain', widget.onchainSats), ('Lightning', widget.lightningSats)]
        .where((p) => p.$2 > BigInt.zero)
        .toList();
    return Column(children: [
      InkWell(
        key: const Key('row-BTC'),
        onTap: !widget.dev && parts.isNotEmpty ? () => setState(() => _open = !_open) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('BTC',
                    style: TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 2),
                Text(widget.stale ? 'Bitcoin testnet4 · last known (offline)' : 'Bitcoin testnet4',
                    style: widget.stale ? AmbraText.sub.copyWith(color: AmbraColors.amber2) : AmbraText.sub),
              ]),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Text(amount,
                  style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w700)),
              if (approx != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(approx, style: AmbraText.sub),
                ),
            ]),
          ]),
        ),
      ),
      if (!widget.dev)
        ListenableBuilder(
          listenable: LightningToArk.instance,
          builder: (context, _) {
            // BTC on its way from the wallet's channel to the ark is said as such; anything
            // else on its way is "arriving".
            final moving = LightningToArk.instance.moving;
            final arriving = widget.arrivingSats ?? BigInt.zero;
            if (moving == null && arriving <= BigInt.zero) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    moving != null
                        ? DefaultWords.moving(formatAtoms(moving.toString(), 8), 'BTC')
                        : DefaultWords.arriving(formatAtoms(arriving.toString(), 8), 'BTC'),
                    key: Key(moving != null ? 'moving-BTC' : 'arriving-BTC'),
                    style: AmbraText.sub),
              ),
            );
          },
        ),
      if (widget.dev && _open && parts.isNotEmpty) _SplitLine(ticker: 'BTC', precision: 8, parts: parts),
      if (widget.dev)
        _RailLine(
          ticker: 'BTC',
          precision: 8,
          onchain: widget.onchainSats,
          leaves: null,
          btc: true,
          lightning: widget.lightningSats,
          ark: ArkBtcService.instance.held,
        ),
      if (widget.dev)
        _LnMeta(
          channels: widget.channels,
          leg: _Leg(
            chain: 'btc',
            asset: null,
            ticker: 'BTC',
            precision: 8,
            target: RailTarget.btc(),
            onchainAtoms: widget.onchainSats,
          ),
          onChanged: widget.onChanged,
        ),
    ]);
  }
}

/// Developer mode: a row's figure split by rail, "X on-chain · Y in leaves · Z on
/// Lightning · W staked". BTC has no leaves: a tree on Sequentia holds no BTC.
class _RailLine extends StatelessWidget {
  const _RailLine({
    required this.ticker,
    required this.precision,
    required this.onchain,
    required this.leaves,
    required this.lightning,
    this.staked,
    this.btc = false,
    this.ark,
  });
  final String ticker;

  /// BTC on the Bitcoin ark (shown when above zero).
  final BigInt? ark;
  final int precision;
  final BigInt onchain;
  final BigInt? leaves; // null: no leaf wallet joined, or BTC
  final BigInt lightning;
  final BigInt? staked; // shown when above zero
  final bool btc;

  @override
  Widget build(BuildContext context) {
    String f(BigInt v) => formatAtoms(v.toString(), precision);
    final parts = <String>[
      '${f(onchain)} on-chain',
      if (btc) 'no leaves (a tree on Sequentia holds no BTC)' else if (leaves != null) '${f(leaves!)} in leaves',
      '${f(lightning)} on Lightning',
      if (ark != null && ark! > BigInt.zero) '${f(ark!)} on the Bitcoin ark',
      if (staked != null && staked! > BigInt.zero) '${f(staked!)} staked',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(parts.join(' · '), key: Key('rails-$ticker'), style: AmbraText.sub),
      ),
    );
  }
}

/// A per-row balance leg for the Lightning split + move/close actions.
class _Leg {
  const _Leg({
    required this.chain,
    required this.asset,
    required this.ticker,
    required this.precision,
    required this.target,
    required this.onchainAtoms,
  });
  final String chain; // 'btc' | 'seq'
  final String? asset; // asset id hex for a Sequentia asset; null for BTC
  final String ticker;
  final int precision;
  final RailTarget target;
  final BigInt onchainAtoms;
}

/// The inline Lightning metacard beneath a balance row: the on-chain vs Lightning split plus the
/// Move-to-Lightning / close affordances, driven by the existing [lsp_client] channels + [ln_rail]
/// gating. Renders nothing when Lightning is dormant, and never on a zero row with no channel — so a
/// fresh wallet's 0 BTC row shows no empty Lightning card.
class _LnMeta extends StatelessWidget {
  const _LnMeta({required this.channels, required this.leg, this.onChanged});
  final List<Map<dynamic, dynamic>> channels;
  final _Leg leg;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    if (!LightningService.instance.configured) return const SizedBox.shrink();
    final chans = channels.cast<Map>();
    final liq = legLiquidity(chans, leg.target);
    final hasChannel = liq.count > 0;
    final movable = leg.onchainAtoms > BigInt.zero;
    // No metacard on a zero row without a channel (never an empty "Not in Lightning yet" card).
    if (!hasChannel && !movable) return const SizedBox.shrink();
    final split = hasChannel
        ? '${formatAtoms(liq.balance.toString(), leg.precision)} ${leg.ticker} in Lightning · '
            '${formatAtoms(leg.onchainAtoms.toString(), leg.precision)} on-chain'
        : 'Not in Lightning yet · ${formatAtoms(leg.onchainAtoms.toString(), leg.precision)} ${leg.ticker} on-chain';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AmbraColors.panelDeep,
        border: Border.all(color: AmbraColors.line),
        borderRadius: BorderRadius.circular(AmbraRadii.input),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: const [
          Icon(Icons.bolt, color: AmbraColors.amber2, size: 15),
          SizedBox(width: 4),
          Text('Lightning', style: AmbraText.label),
        ]),
        const SizedBox(height: 6),
        Text(split, style: AmbraText.sub),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _LnActionButton(
              label: hasChannel ? 'Add to Lightning' : 'Move to Lightning',
              enabled: movable,
              onTap: () => _showMoveDialog(context, leg, onChanged),
            ),
          ),
          if (hasChannel) ...[
            const SizedBox(width: 8),
            Expanded(
              child: _LnActionButton(
                label: 'Move to chain',
                enabled: true,
                onTap: () => _showCloseDialog(context, leg, chans, onChanged),
              ),
            ),
          ],
        ]),
      ]),
    );
  }
}

/// A compact ghost-style action button for the Lightning metacard.
class _LnActionButton extends StatelessWidget {
  const _LnActionButton({required this.label, required this.enabled, required this.onTap});
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: OutlinedButton(
        onPressed: enabled ? onTap : null,
        style: OutlinedButton.styleFrom(
          backgroundColor: AmbraColors.buttonSurface,
          side: const BorderSide(color: AmbraColors.line),
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AmbraRadii.control)),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 13)),
      ),
    );
  }
}

void _showMoveDialog(BuildContext context, _Leg leg, VoidCallback? onChanged) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _MoveSheet(leg: leg, onChanged: onChanged),
    ),
  );
}

void _showCloseDialog(BuildContext context, _Leg leg, List<Map> channels, VoidCallback? onChanged) {
  final own = channels
      .where((c) => channelMatches(c, leg.target) && channelActive(c) && '${c['node_key'] ?? ''}'.isNotEmpty)
      .toList();
  if (own.isEmpty) return;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => _CloseSheet(leg: leg, channel: own.first, onChanged: onChanged),
  );
}

/// Build + sign + broadcast the on-chain deposit that funds a Lightning channel — a normal
/// wallet-signed send (the LSP never holds the key). BTC uses the parent-chain path; a Sequentia
/// asset pays the funding fee by the wallet rule ([walletFeeFor]): in the asset moved when the node
/// accepts it, else in the accepted asset whose largest coin covers the most fees, never tSEQ by
/// default.
Future<void> _sendChannelDeposit(String mnemonic, _Leg leg, BigInt atoms, String address) async {
  if (leg.chain == 'btc') {
    final tx = await core.btcPrepare(
        mnemonic: mnemonic, t4Api: Backend.testnet4, address: address, amountSats: atoms, feeRate: 0);
    await core.btcBroadcast(t4Api: Backend.testnet4, txHex: tx.hex);
    return;
  }
  final asset = leg.asset!;
  final feeAsset = await walletFeeParam(mnemonic, moved: asset, movedAtoms: atoms);
  final pset = await core.buildSendTx(
    mnemonic: mnemonic,
    esploraUrl: Backend.esplora,
    recipients: [core.Recipient(address: address, assetId: asset, satoshi: atoms)],
    feeAsset: feeAsset,
  );
  final signed = await core.signPset(mnemonic: mnemonic, pset: pset);
  await core.finalizeAndBroadcast(mnemonic: mnemonic, esploraUrl: Backend.esplora, pset: signed);
}

/// Modal: choose an amount, then run the non-custodial Move-to-Lightning flow (provision the user's
/// OWN node, bring the device signer online, deposit on-chain, open a device-co-signed channel).
class _MoveSheet extends StatefulWidget {
  const _MoveSheet({required this.leg, this.onChanged});
  final _Leg leg;
  final VoidCallback? onChanged;
  @override
  State<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<_MoveSheet> {
  final _amount = TextEditingController();
  bool _busy = false;
  bool _done = false;
  /// Set once the deposit is broadcast AND persisted: from that point the move is finishable
  /// without this sheet, so closing it abandons nothing and the ghost button says so.
  bool _leaveable = false;
  String? _status;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _say(String t) {
    if (mounted) setState(() => _status = t);
  }

  Future<void> _move() async {
    final leg = widget.leg;
    final atoms = parseAtoms(_amount.text, leg.precision);
    if (atoms == null || atoms <= BigInt.zero) {
      setState(() => _error = 'Enter an amount greater than zero.');
      return;
    }
    if (atoms > leg.onchainAtoms) {
      setState(() => _error = 'Amount exceeds your on-chain ${leg.ticker} balance.');
      return;
    }
    if (leg.chain == 'btc' && atoms < BigInt.from(546)) {
      setState(() => _error = 'Minimum channel is 546 sats (the dust limit).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('Your wallet is locked; unlock it and try again.');
      _say(leg.chain == 'btc'
          ? 'Provisioning your Lightning BTC node…'
          : 'Provisioning your ${leg.ticker} Lightning node…');
      final nodeKey = await LightningService.instance.connectNode(m, chain: leg.chain, asset: leg.asset);
      _say('Getting your hosted node deposit address…');
      final addr = await LspClient.channelDeposit(chain: leg.chain, asset: leg.asset, node: nodeKey);
      _say('Signing and sending the on-chain deposit…');
      await _sendChannelDeposit(m, leg, atoms, addr);
      // The deposit is now on the hosted node, so a channel is OWED. Write that down BEFORE asking
      // for it: from here on the move is finishable by ChannelMoveService.resume() even if this
      // sheet is closed or the app is killed, and re-asking never re-deposits (the LSP funds from
      // the balance already on the node and adopts an opening channel rather than opening a second).
      final rec = ChannelMove(
        id: ChannelMoveService.idFor(nodeKey),
        chain: leg.chain,
        asset: leg.asset,
        ticker: leg.ticker,
        amountAtoms: atoms.toString(),
        nodeKey: nodeKey,
        pollPath: null,
        startedMs: DateTime.now().millisecondsSinceEpoch,
      );
      await ChannelMoveStore.put(rec);
      if (mounted) setState(() => _leaveable = true);
      // The poll now lives in the service, on the server's own timescale. It used to run here for
      // 120 * 2s and then report "the channel is still opening; check back shortly" — a four-minute
      // verdict on an hour-long watch, for a deposit that confirms in the next block.
      final job = await ChannelMoveService.drive(rec, onStep: _say);
      if (mounted) {
        setState(() {
          _done = true;
          _status = 'Done. Your ${leg.ticker} Lightning channel is active.';
        });
      }
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed: ${_moveError(e, widget.leg.ticker)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final leg = widget.leg;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Move ${leg.ticker} to Lightning', style: AmbraText.h1),
          const SizedBox(height: 12),
          const Text(
            'Your wallet sends this amount on-chain to your hosted node, then your device co-signs '
            'opening a Lightning channel with it. Non-custodial: only your device can spend these funds.',
            style: AmbraText.sub,
          ),
          const SizedBox(height: 14),
          AmbraField(label: 'Amount (${leg.ticker})', controller: _amount, hint: '0.0', mono: true),
          const SizedBox(height: 6),
          Text('Available on-chain: ${formatAtoms(leg.onchainAtoms.toString(), leg.precision)} ${leg.ticker}',
              style: AmbraText.sub),
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, style: const TextStyle(color: AmbraColors.red)))
          else if (_status != null)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_status!, style: AmbraText.sub)),
          if (_leaveable && !_done)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'Your deposit is on your node. You can leave this screen — the channel keeps opening, '
                'and Ambra picks it up again if you close the app.',
                style: AmbraText.sub,
              ),
            ),
          if (_done)
            PrimaryButton(label: 'Done', onPressed: () => Navigator.pop(context))
          else ...[
            PrimaryButton(label: 'Move to Lightning', icon: Icons.bolt, busy: _busy, onPressed: _busy ? null : _move),
            const SizedBox(height: 6),
            // Cancel stays blocked only while the deposit is still being built and signed — there is
            // genuinely nothing to come back to yet. Once it is broadcast and written down, closing the
            // sheet is safe, so the button stops pretending otherwise.
            GhostButton(
              label: _leaveable ? 'Leave it running' : 'Cancel',
              onPressed: (_busy && !_leaveable) ? null : () => Navigator.pop(context),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Map the open-fee-market outcomes to honest copy (a funding tx no producer will mine is the fee
/// market working as designed, not a bug).
String _moveError(Object e, String ticker) {
  final msg = e.toString().replaceFirst('Exception: ', '');
  if (RegExp(r'fee asset is not accepted|no exchange rate|not accepted .*fee', caseSensitive: false).hasMatch(msg)) {
    return 'No block producer currently accepts $ticker for the on-chain funding fee, so it cannot be '
        'moved into Lightning yet. It becomes movable once a producer accepts it for fees.';
  }
  if (RegExp(r'insufficient funds|missing \d+ units', caseSensitive: false).hasMatch(msg)) {
    return 'Not enough $ticker to cover the amount plus the on-chain network fee. Move a slightly '
        'smaller amount so a little $ticker is left for the fee.';
  }
  return msg;
}

/// Modal: cooperatively close the user's OWN channel for a leg and pay its balance on-chain to a
/// fresh wallet address. The device signs that close only because the app named the address's
/// script to it first; the LSP drives the close but cannot redirect the funds. When the peer does
/// not answer, the close is unilateral and pays the node's own address after the channel's delay.
class _CloseSheet extends StatefulWidget {
  const _CloseSheet({required this.leg, required this.channel, this.onChanged});
  final _Leg leg;
  final Map channel;
  final VoidCallback? onChanged;
  @override
  State<_CloseSheet> createState() => _CloseSheetState();
}

class _CloseSheetState extends State<_CloseSheet> {
  bool _busy = false;
  bool _done = false;
  String? _status;
  String? _error;

  void _say(String t) {
    if (mounted) setState(() => _status = t);
  }

  Future<void> _close() async {
    final leg = widget.leg;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('Your wallet is locked; unlock it and try again.');
      _say('Connecting your device signer…');
      final nodeKey = await LightningService.instance.connectNode(m, chain: leg.chain, asset: leg.asset);
      // A fresh on-chain address of ours = where the reclaimed funds land.
      final dest = (await core.receiveAddressAt(
              mnemonic: m, index: BtcState.instance.unifiedNext, confidential: false))
          .address;
      // The device refuses a close of this side's balance to any script it was not told is ours.
      await LightningService.instance
          .approveCloseDestination(nodeKey, await core.addressScriptPubkey(address: dest));
      _say('Closing the channel (your device is co-signing)…');
      final scid = '${widget.channel['short_channel_id'] ?? widget.channel['scid'] ?? ''}';
      final res = await LspClient.channelClose(
        chain: leg.chain,
        destination: dest,
        asset: leg.asset,
        node: nodeKey,
        scid: scid.isEmpty ? null : scid,
      );
      final txid = res.closingTxid;
      final tx = txid != null && txid.length >= 16 ? 'transaction ${txid.substring(0, 16)}…' : 'the transaction was broadcast';
      if (mounted) {
        setState(() {
          _done = true;
          _status = res.type == 'unilateral'
              ? 'The routing peer did not answer, so the channel closed unilaterally ($tx). Your '
                  '${leg.ticker} goes to your Lightning node\'s own address after the channel\'s delay.'
              : 'Done ($tx). Your ${leg.ticker} arrives in this wallet once it confirms.';
        });
      }
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final leg = widget.leg;
    final spendable = BigInt.tryParse(
            '${widget.channel['spendable_units'] ?? widget.channel['spendable'] ?? 0}'.split('.').first) ??
        BigInt.zero;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Move ${leg.ticker} back on-chain', style: AmbraText.h1),
          const SizedBox(height: 12),
          Text(
            'This closes your ${leg.ticker} Lightning channel and pays its balance straight to this '
            'wallet, on chain. Your device signs the close only because it pays your balance to an '
            'address of this wallet. If the routing peer is offline the close falls back to a slower '
            'unilateral one, which pays your Lightning node\'s own address instead.',
            style: AmbraText.sub,
          ),
          const SizedBox(height: 10),
          Text('In Lightning: ${formatAtoms(spendable.toString(), leg.precision)} ${leg.ticker}', style: AmbraText.sub),
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, style: const TextStyle(color: AmbraColors.red)))
          else if (_status != null)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_status!, style: AmbraText.sub)),
          if (_done)
            PrimaryButton(label: 'Done', onPressed: () => Navigator.pop(context))
          else ...[
            PrimaryButton(label: 'Move to chain', busy: _busy, onPressed: _busy ? null : _close),
            const SizedBox(height: 6),
            GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
          ],
        ]),
      ),
    );
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.loading, this.tip, this.failed = false, this.lastSync});
  final bool loading;
  final int? tip;
  final bool failed; // the latest refresh errored
  final DateTime? lastSync; // time of the last successful sync

  static String _hhmm(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Row(mainAxisSize: MainAxisSize.min, children: const [
        SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: AmbraColors.dim)),
        SizedBox(width: 7),
        Text('syncing', style: AmbraText.sub),
      ]);
    }
    // Green + block height when the latest sync succeeded; amber + "offline" when
    // it failed, with the last-synced time so "offline" isn't undated (the screen
    // is then showing last-known data).
    final synced = tip != null && !failed;
    final String label;
    if (synced) {
      label = 'block $tip';
    } else if (lastSync != null) {
      label = 'offline · synced ${_hhmm(lastSync!)}';
    } else {
      label = 'offline';
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: synced ? AmbraColors.green : AmbraColors.amber,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 7),
      Text(label, style: AmbraText.sub),
    ]);
  }
}

class _RefChip extends StatelessWidget {
  const _RefChip({required this.ref});
  final String ref;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _showRefSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: AmbraColors.line), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(ref, style: const TextStyle(color: AmbraColors.amber2, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 3),
          const Icon(Icons.expand_more, color: AmbraColors.dim, size: 16),
        ]),
      ),
    );
  }
}

void _showRefSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const Padding(padding: EdgeInsets.all(16), child: Text('Show values in', style: AmbraText.title)),
        for (final r in PriceService.instance.refOptions())
          ListTile(
            title: Text(r, style: AmbraText.body),
            trailing: r == PriceService.instance.ref ? const Icon(Icons.check, color: AmbraColors.amber) : null,
            onTap: () {
              PriceService.instance.setRef(r);
              Navigator.pop(context);
            },
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

// ---------------------------------------------------------------------------
// The account key, for a watch-only import elsewhere. Collapsed by default: it is
// not a thing to hand out casually — it derives every address this wallet will
// ever use, on BOTH chains, since they share one m/84'/1'/0' account. It cannot
// spend, and the card says so.
//
// Three forms of the same key, matching the web wallet: the extended key, the
// wpkh() descriptor that describes the addresses this wallet hands out, and the
// legacy pkh() form, which is what a node's verifymessage takes and so what
// someone imports to check a signature made on the Sign screen.
// ---------------------------------------------------------------------------
enum AccountKeyForm { xpub, wpkh, pkh }

class AccountKeyCard extends StatefulWidget {
  const AccountKeyCard({super.key});
  @override
  State<AccountKeyCard> createState() => _AccountKeyCardState();
}

class _AccountKeyCardState extends State<AccountKeyCard> {
  bool _shown = false;
  AccountKeyForm _form = AccountKeyForm.xpub;
  String? _keyorigin;
  String? _error;

  // Why a descriptor view shows TWO lines is the first thing anyone asks, so every
  // descriptor form says it — not only the first one. A descriptor covers one branch of the
  // keychain: /0/* is receive, /1/* is change, and a wallet given only the first would see
  // incoming payments and none of the change.
  static const _pair = 'Two lines, because a descriptor covers one branch: the first derives your '
      'receive addresses, the second your change. Import both — a wallet given only the first would '
      'miss every change output. They come as a pair rather than one combined <0;1> descriptor '
      'because this network\'s node refuses that form.';
  static const _notes = {
    AccountKeyForm.xpub: 'The account key with its origin path, which is what a watch-only import asks for.',
    AccountKeyForm.wpkh: '$_pair These are the tb1 addresses this wallet hands out — the same ones on '
        'Sequentia and on Bitcoin testnet4.',
    AccountKeyForm.pkh: '$_pair This is the legacy form of the same key: nothing is paid to these '
        'addresses, but it is the form a node takes for verifymessage, so it is what someone imports '
        'to check a signature made on the Sign screen.',
  };

  Future<void> _reveal() async {
    setState(() {
      _shown = true;
      _error = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final k = await core.accountXpub(mnemonic: m);
      if (mounted) setState(() => _keyorigin = k);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read the account key: $e');
    }
  }

  String get _value {
    final k = _keyorigin;
    if (k == null || k.isEmpty) return '';
    switch (_form) {
      case AccountKeyForm.xpub:
        return k;
      case AccountKeyForm.wpkh:
        return accountDescriptors(k).join('\n');
      case AccountKeyForm.pkh:
        return accountDescriptors(k, kind: 'pkh').join('\n');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) {
      return SecondaryButton(label: 'Show account key (xpub)', icon: Icons.key, onPressed: _reveal);
    }
    final value = _value;
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionLabel('Account key'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AmbraColors.panelDeep,
            border: Border.all(color: AmbraColors.line),
            borderRadius: BorderRadius.circular(AmbraRadii.input),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<AccountKeyForm>(
              value: _form,
              isExpanded: true,
              dropdownColor: AmbraColors.panel,
              iconEnabledColor: AmbraColors.dim,
              style: const TextStyle(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w600),
              items: const [
                DropdownMenuItem(value: AccountKeyForm.xpub, child: Text('Extended public key')),
                DropdownMenuItem(value: AccountKeyForm.wpkh, child: Text('Descriptor — wpkh')),
                DropdownMenuItem(value: AccountKeyForm.pkh, child: Text('Descriptor — pkh (legacy)')),
              ],
              onChanged: (v) => setState(() => _form = v ?? AccountKeyForm.xpub),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: AmbraColors.red))
        else if (value.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)),
          )
        else ...[
          SelectableText(value, style: AmbraText.mono.copyWith(fontSize: 12)),
          const SizedBox(height: 10),
          Text(_notes[_form]!, style: AmbraText.sub),
          const SizedBox(height: 8),
          const Text(
            'Watch-only either way. It derives every address this wallet will ever use — on Sequentia and on '
            'Bitcoin testnet4, which share this one account key — so anyone holding it can follow your whole '
            'history on both chains. It cannot spend: only the recovery phrase can.',
            style: AmbraText.sub,
          ),
          const SizedBox(height: 14),
          SecondaryButton(
            label: 'Copy',
            icon: Icons.copy,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account key copied')));
            },
          ),
          // Some importers take ONE descriptor and only ever want the receive branch. Copying
          // the whole box then hands them the change line as often as not, so offer the
          // receive line on its own rather than leaving it to a careful selection.
          if (_form != AccountKeyForm.xpub) ...[
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'Copy the receive line',
              icon: Icons.call_received,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value.split('\n').first));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Receive descriptor copied')));
              },
            ),
          ],
          const SizedBox(height: 6),
          GhostButton(label: 'Hide', onPressed: () => setState(() => _shown = false)),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Receive (M3: shared tb1 default + confidential tsqb1 opt-in, copy, cycle)
// ---------------------------------------------------------------------------
class ReceiveTab extends StatefulWidget {
  const ReceiveTab({super.key});
  @override
  State<ReceiveTab> createState() => _ReceiveTabState();
}

class _ReceiveTabState extends State<ReceiveTab> {
  int _index = 0;
  bool _confidential = false;
  String? _address;
  String? _bitcoinAddress; // the tb1 form, shown alongside a confidential address
  String? _error;
  String? _ampAid; // OpenAMP account id (how senders address restricted assets)
  String? _ampAddress; // an enclave deposit address for a restricted asset
  // User mode: the receive code shown first (a payment to it arrives in seconds). It shows at
  // once from what the wallet last drew (kept until it is paid or lapses), whatever the wallet
  // is syncing, and gains a way to be paid in place when one opens; a new one is drawn in the
  // background and replaces it only when it is ready.
  String? _code;
  String? _codeAddr;
  String? _codeArk;
  String? _codeSeq;
  int? _codeUntil; // the receive request's lapse, a median time
  bool _drawing = false;
  bool _fresh = false; // the next draw asks for a new receive request
  int _paidAt = 0;

  // The one receive code shows in user mode once there is one to show, or once the wallet
  // holds coins with the operator or BTC on the ark.
  bool get _codeMode =>
      !DevMode.instance.on && (_code != null || LeafService.instance.open || ArkBtcService.instance.open);

  @override
  void initState() {
    super.initState();
    // Start at the cross-chain unified next-unused index, and follow it forward as
    // either chain's scan advances it (the shared address discourages reuse).
    _index = BtcState.instance.unifiedNext;
    BtcState.instance.addListener(_onUnified);
    LeafService.instance.addListener(_onLeaves);
    ArkBtcService.instance.addListener(_onLeaves);
    // The mode decides what Receive shows (one code, or every rail): it follows a switch at once.
    DevMode.instance.addListener(_onMode);
    _paidAt = LeafService.instance.arrivedCount;
    _load();
    unawaited(_restoreCode().whenComplete(_onLeaves));
  }

  void _onMode() {
    if (!mounted) return;
    setState(() {});
    _load();
  }

  /// The code last drawn, shown at once, unless its receive request lapses within a day.
  Future<void> _restoreCode() async {
    final kept = await WalletCache.loadReceiveCode();
    if (kept == null || !mounted || _code != null) return;
    final until = kept['until'] is int ? kept['until'] as int : null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (until != null && until - now < 86400) return;
    final addr = kept['address']?.toString();
    if (addr == null || addr.isEmpty) return;
    setState(() {
      _codeAddr = addr;
      _codeArk = kept['ark']?.toString();
      _codeSeq = kept['sequentia']?.toString();
      _codeUntil = until;
      _code = _compose();
    });
    debugPrint('[ambra-receive] the last code drawn, shown at once: ${_code?.length} chars');
  }

  /// A new code on request; the one shown stays until the new one is ready.
  void _newCode() {
    _fresh = true;
    _onLeaves();
  }

  /// Draws a code when the wallet shows none, adds a way to be paid that opened since, and
  /// draws a new one once the one shown was paid (its receive request is single use).
  void _onLeaves() {
    final l = LeafService.instance;
    final ark = ArkBtcService.instance;
    if (DevMode.instance.on || _drawing || !mounted) return;
    // A code carrying an invoice is spent once BTC arrived on the ark: a new invoice then.
    final paid = ark.received;
    final invoicePaid = (paid != null && paid.hash == _codeInvoiceHash) ||
        (_codeAmount.isNotEmpty && ark.open && ark.spendable + ark.arriving > _arkSeen);
    if (paid != null && paid.hash == _codeInvoiceHash && _toldPaid != paid.hash) {
      _toldPaid = paid.hash;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(ambraSnack(DefaultWords.received(formatAtoms(paid.sats.toString(), 8), 'BTC')));
      });
    }
    if (l.arrivedCount != _paidAt) {
      _paidAt = l.arrivedCount;
      _fresh = true;
    }
    final want = _code == null ||
        _fresh ||
        (ark.open && _codeArk == null) ||
        (l.open && _codeSeq == null) ||
        invoicePaid ||
        _btcAmount.text.trim() != _codeAmount;
    if (!want) return;
    _drawing = true;
    _drawCode().whenComplete(() => _drawing = false);
  }

  String? _codeInvoice;
  String? _codeInvoiceHash; // the payment hash of the code's lightning= invoice
  String? _toldPaid;

  // The optional BTC amount: with one, the code also names it and carries an invoice from
  // the Bitcoin ark for exactly that amount, which the wallet claims while it is open.
  final _btcAmount = TextEditingController();
  Timer? _amountDebounce;
  String _codeAmount = '';
  BigInt _arkSeen = BigInt.zero;

  void _onAmount(String _) {
    _amountDebounce?.cancel();
    _amountDebounce = Timer(const Duration(milliseconds: 800), _onLeaves);
  }

  /// The amount field's BTC as a BIP321 decimal (trailing zeros dropped) and in sats, or
  /// null when it is empty or not an amount.
  (String, BigInt)? _amountOf(String text) {
    final sats = parseAtoms(text.trim(), 8);
    if (sats == null || sats <= BigInt.zero) return null;
    var dec = formatAtoms(sats.toString(), 8).replaceAll(',', '');
    if (dec.contains('.')) dec = dec.replaceFirst(RegExp(r'\.?0+$'), '');
    return (dec, sats);
  }

  /// The code from its parts as they stand.
  String? _compose() {
    final a = _codeAddr;
    if (a == null) return null;
    try {
      return PayCode(
              address: a,
              amount: _amountOf(_codeAmount)?.$1,
              lightning: _codeInvoice,
              ark: _codeArk,
              sequentia: _codeSeq)
          .build();
    } catch (_) {
      return null;
    }
  }

  void _show() {
    final c = _compose();
    if (c == null || !mounted || c == _code) return;
    setState(() => _code = c);
    // The code is public (it is shown and copied); its size is what a scanner meets.
    debugPrint('[ambra-receive] code ${c.length} chars, QR version ${payCodeQr(c).typeNumber}: $c');
  }

  /// Draws the code part by part, each shown as soon as it is there: the shared address at the
  /// current index, an ark address once the Bitcoin ark is open, a receive request once the
  /// wallet holds coins with the operator (a new one only when the one shown was paid, lapses
  /// or a new code was asked for), and with an amount an invoice of the ark's for it. What the
  /// wallet cannot reach now (a sync running, a service closed) is left as it was.
  Future<void> _drawCode() async {
    final fresh = _fresh;
    _fresh = false;
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      if (_codeAddr == null || fresh) {
        _codeAddr = (await core.receiveAddressAt(mnemonic: m, index: _index, confidential: false)).address;
        if (_code == null) _show();
      }
      final ark = ArkBtcService.instance;
      if (ark.open && _codeArk == null) {
        try {
          _codeArk = await ark.address();
          _show();
        } catch (_) {}
      }
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final lapsing = _codeUntil != null && _codeUntil! - now < 86400;
      if (LeafService.instance.open && (_codeSeq == null || fresh || lapsing)) {
        final seq = await LeafService.instance.receiveCode();
        if (seq != null) {
          _codeSeq = seq;
          final r = libraryRequest(seq);
          _codeUntil = r?['until'] is int ? r!['until'] as int : null;
          _paidAt = LeafService.instance.arrivedCount;
          _show();
        }
      }
      final text = _btcAmount.text.trim();
      if (text != _codeAmount || _codeInvoice == null || fresh) {
        _codeAmount = text;
        _arkSeen = ark.spendable + ark.arriving;
        _codeInvoice = null;
        _codeInvoiceHash = null;
        final amount = _amountOf(text);
        if (amount != null && ark.open) {
          try {
            _codeInvoice = await ark.invoice(amount.$2);
            _codeInvoiceHash = '${decodeBtcInvoice(_codeInvoice!)['payment_hash']}';
          } catch (_) {}
        }
        _show();
      }
      await WalletCache.saveReceiveCode(
          {'address': _codeAddr, 'ark': _codeArk, 'sequentia': _codeSeq, 'until': _codeUntil});
    } catch (_) {
      // The code shown stays; the next change of the wallet's state tries again.
    }
  }

  void _onUnified() {
    final next = BtcState.instance.unifiedNext;
    if (next > _index && mounted) {
      setState(() => _index = next);
      _load();
    }
  }

  @override
  void dispose() {
    BtcState.instance.removeListener(_onUnified);
    LeafService.instance.removeListener(_onLeaves);
    ArkBtcService.instance.removeListener(_onLeaves);
    DevMode.instance.removeListener(_onMode);
    _amountDebounce?.cancel();
    _btcAmount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // The address shown stays until the next one is ready: a scan moving the index on, or the
    // wallet syncing, never blanks it.
    setState(() => _error = null);
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final info = await core.receiveAddressAt(mnemonic: m, index: _index, confidential: _confidential);
      String? bitcoin;
      if (_confidential) {
        bitcoin = (await core.receiveAddressAt(mnemonic: m, index: _index, confidential: false)).address;
      }
      if (mounted) {
        setState(() {
          _address = info.address;
          _bitcoinAddress = bitcoin;
        });
      }
      // Restricted-asset (OpenAMP) receive identifiers, best-effort. Senders use
      // the AID; the enclave deposit address funds the account on-chain.
      await OpenAmpService.instance.ensureRegistered(m);
      final aid = OpenAmpService.instance.aid;
      String? ampAddr;
      final assets = OpenAmpService.instance.assets;
      if (aid != null && assets.isNotEmpty) {
        ampAddr = await OpenAmpService.instance.depositAddress(assets.first.id);
      }
      if (mounted) {
        setState(() {
          _ampAid = aid;
          _ampAddress = ampAddr;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _copy(String text, String msg) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        const Text('Receive', style: AmbraText.h1),
        const SizedBox(height: 20),
        if (_codeMode) ...[
          if (_code != null) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView.withQr(
                    key: const Key('receive-code-qr'),
                    qr: payCodeQr(_code!),
                    size: 288,
                    backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 18),
          ],
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel(DefaultWords.receiveCode),
              const SizedBox(height: 12),
              if (_code == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)),
                )
              else ...[
                const Text(DefaultWords.receiveCodeLine, style: AmbraText.sub),
                const SizedBox(height: 14),
                SecondaryButton(
                  key: const Key('receive-code-copy'),
                  label: DefaultWords.copyCode,
                  icon: Icons.copy,
                  onPressed: () => _copy(_code!, DefaultWords.codeCopied),
                ),
                const SizedBox(height: 10),
                SecondaryButton(
                  key: const Key('receive-code-new'),
                  label: DefaultWords.newCode,
                  icon: Icons.refresh,
                  onPressed: _newCode,
                ),
                if (ArkBtcService.instance.open) ...[
                  const SizedBox(height: 14),
                  AmbraField(
                      key: const Key('receive-btc-amount'),
                      label: DefaultWords.amountInBtc,
                      controller: _btcAmount,
                      hint: '0.0',
                      onChanged: _onAmount),
                ],
              ],
            ]),
          ),

        ] else ...[
        if (_address != null) ...[
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(data: _address!, version: QrVersions.auto, size: 224, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: 18),
        ],
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionLabel(
                _confidential ? 'Confidential address (index $_index)' : 'Address (index $_index)'),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: AmbraColors.red))
            else if (_address == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)),
              )
            else ...[
              SelectableText(_address!, style: AmbraText.mono.copyWith(fontSize: 14)),
              const SizedBox(height: 10),
              Text(
                _confidential
                    ? 'Private: the amount and asset are hidden on-chain. This is NOT a Bitcoin address.'
                    : 'Also receives Bitcoin (testnet4); one address, both chains.',
                style: AmbraText.sub,
              ),
              const SizedBox(height: 14),
              SecondaryButton(
                label: _confidential ? 'Copy confidential address' : 'Copy address',
                icon: Icons.copy,
                onPressed: () =>
                    _copy(_address!, _confidential ? 'Confidential address copied' : 'Address copied'),
              ),
            ],
          ]),
        ),
        if (_confidential && _bitcoinAddress != null) ...[
          const SizedBox(height: 12),
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Bitcoin / non-confidential address'),
              const SizedBox(height: 14),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: QrImageView(
                      data: _bitcoinAddress!, version: QrVersions.auto, size: 168, backgroundColor: Colors.white),
                ),
              ),
              const SizedBox(height: 14),
              SelectableText(_bitcoinAddress!, style: AmbraText.mono.copyWith(fontSize: 14)),
              const SizedBox(height: 10),
              const Text('Use this transparent address to also receive Bitcoin (testnet4).',
                  style: AmbraText.sub),
              const SizedBox(height: 14),
              SecondaryButton(
                label: 'Copy Bitcoin address',
                icon: Icons.copy,
                onPressed: () => _copy(_bitcoinAddress!, 'Bitcoin address copied'),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 14),
        SecondaryButton(
          label: _confidential ? 'New addresses' : 'New address',
          icon: Icons.refresh,
          onPressed: _address == null
              ? null
              : () {
                  _index++;
                  BtcState.instance.bumpTo(_index); // keep the cross-chain cycle in step
                  _load();
                },
        ),
        const SizedBox(height: 18),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeThumbColor: AmbraColors.amber,
          value: _confidential,
          onChanged: (v) {
            _confidential = v;
            _load();
          },
          title: const Text('Show confidential address', style: AmbraText.body),
          subtitle: const Text('A private address that hides the amount and asset.', style: AmbraText.sub),
        ),
        const SizedBox(height: 18),
        const AccountKeyCard(),
        // General Lightning receive — generate a BOLT11 into the user's own hosted node. Mounted
        // only when Lightning is deployed for this build (dormant otherwise, so nothing shows).
        if (LightningService.instance.configured) ...[
          const SizedBox(height: 18),
          const LnReceiveCard(),
        ],
        if (_ampAid != null) ...[
          const SizedBox(height: 18),
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Restricted assets (OpenAMP)'),
              const SizedBox(height: 12),
              const Text('Your account id — share it to receive restricted assets.',
                  style: AmbraText.sub),
              const SizedBox(height: 8),
              SelectableText(_ampAid!, style: AmbraText.mono.copyWith(fontSize: 14)),
              const SizedBox(height: 10),
              SecondaryButton(
                label: 'Copy account id',
                icon: Icons.copy,
                onPressed: () => _copy(_ampAid!, 'Account id copied'),
              ),
              if (_ampAddress != null) ...[
                const SizedBox(height: 16),
                const Text('Enclave deposit address (funds the account on-chain):',
                    style: AmbraText.sub),
                const SizedBox(height: 8),
                SelectableText(_ampAddress!, style: AmbraText.mono.copyWith(fontSize: 14)),
                const SizedBox(height: 10),
                SecondaryButton(
                  label: 'Copy deposit address',
                  icon: Icons.copy,
                  onPressed: () => _copy(_ampAddress!, 'Deposit address copied'),
                ),
              ],
            ]),
          ),
        ],
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// More (M3: network info, reveal phrase, lock, remove wallet)
// ---------------------------------------------------------------------------
class MoreTab extends StatelessWidget {
  const MoreTab({super.key});

  Future<void> _reveal(BuildContext context) async {
    final repo = WalletRepository.instance;
    final ok = await repo.authenticate(reason: 'Reveal recovery phrase');
    if (!ok) return;
    final m = await repo.readMnemonic();
    if (m == null || !context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Recovery phrase', style: AmbraText.h1),
          const SizedBox(height: 16),
          AmbraCard(child: MnemonicWordGrid(words: m.split(' '))),
          const SizedBox(height: 16),
          const WarnCallout('Never share these words. Anyone with them controls your funds.'),
        ]),
      ),
    );
  }

  /// Developer mode: the daily Lightning payment limit the phone's signer applies, in the
  /// reference unit (US dollars on the testnet), held in each asset at its rate.
  Future<void> _editLnLimit(BuildContext context) async {
    final lim = LnPaymentLimit.instance;
    await lim.load();
    if (!context.mounted) return;
    final ctl = TextEditingController(text: '${lim.reference}');
    final v = await showDialog<int>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: const Text('Lightning payment limit', style: AmbraText.title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
            'What your phone lets your Lightning nodes pay in a day, in US dollars, held in each '
            'asset at the node\'s rate.',
            style: AmbraText.muted,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('ln-limit-field'),
            controller: ctl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(suffixText: 'USD a day'),
          ),
        ]),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(dctx)),
          TextButton(
            key: const Key('ln-limit-save'),
            onPressed: () => Navigator.pop(dctx, int.tryParse(ctl.text.trim())),
            child: const Text('Save', style: TextStyle(color: AmbraColors.amber, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (v == null || v < 1) return;
    await lim.set(v);
    await LightningService.instance.reapplyPaymentLimit();
  }

  Future<void> _remove(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: const Text('Remove wallet?', style: AmbraText.title),
        content: const Text(
          'This deletes the recovery phrase from this device. You can only restore '
          'it if you have your 12 words backed up.',
          style: AmbraText.muted,
        ),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: AmbraColors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      // The leaf wallet and the Bitcoin ark wallet of this phrase close, and what was read
      // of them is forgotten, before the phrase goes: the next wallet shows and spends only
      // its own.
      await LeafService.instance.forget();
      ArkBtcService.instance.stop();
      await WalletRepository.instance.removeWallet();
      await WalletCache.clear();
      StakeHoldings.instance.clear();
      await LeafService.forgetCare();
    }
  }

  Future<void> _toggleLock(BuildContext context, bool on) async {
    final repo = WalletRepository.instance;
    if (on) {
      // Only enable if the device can actually enforce it (has a screen lock).
      if (!await repo.canEnforceLock()) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Set up a screen lock (PIN, pattern, or biometrics) on your device first.')));
        }
        return;
      }
      // Confirm the user can authenticate before relying on the lock.
      if (!await repo.authenticate(reason: 'Confirm to enable the app lock')) return;
      await repo.setLockEnabled(true);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App lock enabled.')));
      }
    } else {
      // Disabling the lock must require auth too, or anyone holding the unlocked
      // phone could just turn it off.
      if (!await repo.authenticate(reason: 'Confirm to disable the app lock')) return;
      await repo.setLockEnabled(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        const Text('More', style: AmbraText.h1),
        const SizedBox(height: 20),
        ListenableBuilder(
          listenable: NodeConfig.instance,
          builder: (context, _) => AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Node'),
              const SizedBox(height: 12),
              const _Kv('Network', 'sequentia-testnet'),
              _Kv('Node', NodeConfig.instance.origin),
              _Kv('Source', NodeConfig.instance.isDefault ? 'Default (public testnet)' : 'Custom'),
              const SizedBox(height: 12),
              SecondaryButton(
                label: 'Change node',
                icon: Icons.dns_outlined,
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NodeScreen())),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Sites'),
            const SizedBox(height: 12),
            SecondaryButton(
              key: const Key('open-sites'),
              label: SiteLinkWords.entry,
              icon: Icons.link,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SitesScreen())),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Testnet'),
            const SizedBox(height: 12),
            SecondaryButton(
              label: 'Get testnet coins (faucet)',
              icon: Icons.water_drop_outlined,
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FaucetScreen())),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Help'),
            const SizedBox(height: 12),
            SecondaryButton(
              key: const Key('open-report'),
              label: ReportWords.title,
              icon: Icons.bug_report_outlined,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReportScreen())),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        ListenableBuilder(
          listenable: DevMode.instance,
          builder: (context, _) => AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel(ModeWords.title),
              const SizedBox(height: 4),
              RadioGroup<bool>(
                groupValue: DevMode.instance.on,
                onChanged: (v) {
                  if (v != null) DevMode.instance.set(v);
                },
                child: Column(children: [
                  for (final dev in [false, true])
                    RadioListTile<bool>(
                      key: Key(dev ? 'mode-developer' : 'mode-user'),
                      contentPadding: EdgeInsets.zero,
                      activeColor: AmbraColors.amber,
                      value: dev,
                      title: Text(dev ? ModeWords.developer : ModeWords.user, style: AmbraText.body),
                      subtitle: Text(dev ? ModeWords.developerLine : ModeWords.userLine, style: AmbraText.sub),
                    ),
                ]),
              ),
              const Text(ModeWords.note, style: AmbraText.sub),
              if (DevMode.instance.on) ...[
                const SizedBox(height: 8),
                SecondaryButton(
                  key: const Key('open-leaves'),
                  label: 'Leaves',
                  icon: Icons.account_tree_outlined,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LeavesScreen())),
                ),
                const SizedBox(height: 8),
                SecondaryButton(
                  key: const Key('open-contracts'),
                  label: 'Contracts',
                  icon: Icons.description_outlined,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ContractsScreen())),
                ),
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: LnPaymentLimit.instance,
                  builder: (context, _) => SecondaryButton(
                    key: const Key('open-ln-limit'),
                    label: 'Lightning payment limit: ${LnPaymentLimit.instance.reference} USD a day',
                    icon: Icons.speed,
                    onPressed: () => _editLnLimit(context),
                  ),
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 14),
        ListenableBuilder(
          listenable: WalletRepository.instance,
          builder: (context, _) {
            final repo = WalletRepository.instance;
            return AmbraCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Security'),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AmbraColors.amber,
                  value: repo.lockEnabled,
                  onChanged: (v) => _toggleLock(context, v),
                  title: const Text('App lock', style: AmbraText.body),
                  subtitle: const Text('Require biometrics or your device PIN to open Ambra.', style: AmbraText.sub),
                ),
                if (repo.lockEnabled) ...[
                  const SizedBox(height: 8),
                  SecondaryButton(label: 'Lock now', icon: Icons.lock, onPressed: repo.lock),
                ],
              ]),
            );
          },
        ),
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Wallet'),
            const SizedBox(height: 12),
            SecondaryButton(label: 'Reveal recovery phrase', icon: Icons.visibility, onPressed: () => _reveal(context)),
            const SizedBox(height: 10),
            DangerButton(label: 'Remove wallet', onPressed: () => _remove(context)),
          ]),
        ),
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Assets & staking'),
            const SizedBox(height: 12),
            SecondaryButton(
              label: 'Issue / manage assets',
              icon: Icons.toll,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AssetsScreen())),
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Stake tSEQ',
              icon: Icons.lock_outline,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StakeScreen())),
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Mix (CoinJoin)',
              icon: Icons.shuffle,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MixScreen())),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text('Ambra v$kAppVersion · Bitcoin testnet4 + Sequentia testnet', style: AmbraText.sub),
        ),
      ],
    );
  }
}

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, style: AmbraText.mono, textAlign: TextAlign.right)),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Bottom navigation — nested-pill active state.
// ---------------------------------------------------------------------------
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  static const _items = [
    (Icons.account_balance_wallet_outlined, 'Balance'),
    (Icons.north_east, 'Send'),
    (Icons.qr_code, 'Receive'),
    (Icons.swap_horiz, 'Swap'),
    (Icons.receipt_long_outlined, 'History'),
    (Icons.more_horiz, 'More'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AmbraColors.bg,
        border: Border(top: BorderSide(color: AmbraColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: List.generate(_items.length, (i) {
              final active = i == index;
              return Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(AmbraRadii.control),
                  onTap: () => onTap(i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: active ? AmbraColors.buttonSurface : Colors.transparent,
                      borderRadius: BorderRadius.circular(AmbraRadii.control),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_items[i].$1, size: 22, color: active ? AmbraColors.amber2 : AmbraColors.dim),
                      const SizedBox(height: 4),
                      Text(_items[i].$2,
                          style: TextStyle(
                              fontSize: 11, color: active ? AmbraColors.txt : AmbraColors.dim)),
                    ]),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
