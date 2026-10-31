import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/dev_mode.dart';
import '../data/leaf_service.dart';
import '../data/on_chain_need.dart';
import '../data/reward_convert.dart';
import '../data/stake_words.dart';
import '../rust/api/rewards.dart' as rewards_api;
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/fee_asset_rule.dart';
import '../data/format.dart';
import '../data/stakes.dart';
import '../data/tx_flow.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Sequentia staking constants (mirror the chain): 40,000 tSEQ minimum; the
/// stake's lock is TIME-based: SEQUENCE_LOCKTIME_TYPE_FLAG (1<<22) OR
/// ceil(posunbonding * posslotinterval / 512) = ceil(43200*30/512) = 2532
/// (≈15 days), the core's `TIME_CSV`. The web wallet and the extension bond with
/// the height lock (43,200 blocks) instead; the stake list below finds and unbonds
/// a stake of this wallet's key under either.
final BigInt _minStakeAtoms = BigInt.from(40000) * BigInt.from(100000000);
const int _unbondCsv = (1 << 22) | 2532;

/// What is moved out of the Ark beyond the stake itself, for its network fee when that is paid in
/// tSEQ (0.1 tSEQ: far above any fee the network takes for one stake).
final BigInt _stakeFeeMargin = BigInt.from(10000000);

class StakeScreen extends StatefulWidget {
  const StakeScreen({super.key});
  @override
  State<StakeScreen> createState() => _StakeScreenState();
}

class _StakeScreenState extends State<StakeScreen> {
  final _amount = TextEditingController();
  String? _stakerKey;
  BigInt _tseq = BigInt.zero;
  bool _busy = false;

  // Staking rewards, and what the standing instruction would do with them.
  List<Map<String, dynamic>> _rewardTotals = <Map<String, dynamic>>[];
  List<RewardPassRow> _rewardRows = <RewardPassRow>[];
  int? _maturity; // blocks before a block reward is spendable, from the kit

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// What staking has paid, and a DRY RUN of what would be converted.
  ///
  /// Dry, always, on a render path: a cross-chain conversion waits on Bitcoin
  /// confirmations and can run for the better part of an hour, and a screen that
  /// awaited one would simply hang. The real pass runs in the background.
  Future<void> _loadRewards(String mnemonic) async {
    try {
      await RewardConvert.instance.loadFor(mnemonic);
      final txsJson = await rewards_api.walletTxFacts(
          mnemonic: mnemonic, esploraUrl: Backend.esplora);
      final keysJson = await rewards_api.stakingKeyFacts(
          mnemonic: mnemonic, delegated: false);
      final tip = await rewards_api.tipHeight(
          mnemonic: mnemonic, esploraUrl: Backend.esplora);
      // The maturity comes from the kit, never a literal here: Sequentia's is
      // 1,000 blocks, not Bitcoin's 100, because the protection is a wall-clock
      // one and this chain runs at 60 seconds. A wallet that guessed 100 would
      // call a reward spendable 900 blocks early and then build a transaction
      // the chain rejects.
      final maturity = await rewards_api.sequentiaCoinbaseMaturity();
      if (mounted) setState(() => _maturity = maturity);
      final rewardsJson = await rewards_api.attributeStakingRewards(
        txsJson: txsJson,
        stakingKeysJson: keysJson,
        tipHeight: tip,
        coinbaseMaturity: maturity,
      );
      final rewards = (jsonDecode(rewardsJson) as List).cast<Map<String, dynamic>>();
      final report = await RewardConvert.instance.runPass(
        rewards: rewards,
        quoteFor: (asset, atoms, target) async => null,
        execute: (asset, atoms, target) async => null,
        dryRun: true,
      );
      if (!mounted) return;
      setState(() {
        _rewardTotals = rewardTotals(rewards);
        _rewardRows = report.considered;
      });
    } catch (_) {
      // A wallet that cannot answer yet is not an error worth a banner: the
      // card simply shows nothing until it can.
    }
  }

  Future<void> _load() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    unawaited(_loadRewards(m));
    try {
      final key = await core.stakerPublicKey(mnemonic: m);
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      BigInt tseq = BigInt.zero;
      for (final b in s.balances) {
        if (b.assetId == SeqAssets.policy) tseq = BigInt.tryParse(b.atoms) ?? BigInt.zero;
      }
      if (mounted) {
        setState(() {
          _stakerKey = key;
          _tseq = tseq;
        });
      }
    } catch (_) {}
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  /// The tSEQ the wallet holds on the chain now.
  Future<BigInt> _onChainTseq() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return BigInt.zero;
    final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
    var tseq = BigInt.zero;
    for (final b in s.balances) {
      if (b.assetId == SeqAssets.policy) tseq = BigInt.tryParse(b.atoms) ?? BigInt.zero;
    }
    if (mounted) setState(() => _tseq = tseq);
    return tseq;
  }

  /// What the wallet holds of tSEQ wherever it is held: on the chain and in the Ark.
  BigInt get _tseqHeld => _tseq + LeafService.instance.spendableAtoms(SeqAssets.policy);

  String? _status;

  Future<void> _stake() async {
    final plain = !DevMode.instance.on;
    final atoms = parseAtoms(_amount.text, 8);
    if (atoms == null || atoms < _minStakeAtoms) return _snack(plain ? StakeWords.tooLittle('40,000') : 'Minimum stake is 40,000 tSEQ');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large');
    final key = _stakerKey;
    if (key == null) return _snack('Staker key not ready; try again');
    // What the stake moves, and a margin for its fee when the fee is paid in tSEQ.
    final need = atoms + _stakeFeeMargin;
    if (plain) {
      setState(() => _busy = true);
      try {
        await ensureOnChain(
          asset: SeqAssets.policy,
          ticker: 'tSEQ',
          precision: 8,
          need: need,
          onChain: _onChainTseq,
          purpose: StakeWords.purposeStake,
          say: (t) {
            if (mounted) setState(() => _status = t);
          },
        );
      } on OnChainRefusal catch (e) {
        if (mounted) setState(() => _status = e.message);
        return;
      } catch (e) {
        if (mounted) setState(() => _status = friendlyError(e));
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
      setState(() => _status = null);
    } else if (_tseq <= atoms) {
      return _snack('Not enough tSEQ. You need the staked amount plus a network fee.');
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(plain ? StakeWords.reviewTitle(formatAtoms(atoms.toString(), 8)) : 'Confirm stake', style: AmbraText.title),
        content: Text(
          plain
              ? StakeWords.reviewBody
              : 'Stake ${formatAtoms(atoms.toString(), 8)} tSEQ to staker key '
                  '${key.substring(0, 16)}…\n\n'
                  'Staked tSEQ counts in your balance but cannot be spent: it is locked for about 15 days. '
                  'After that you can unbond it here, and it returns to your wallet about two weeks later.',
          style: AmbraText.muted,
        ),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stake', style: TextStyle(color: AmbraColors.amber2, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // The stake moves tSEQ, so its fee follows the wallet rule from there: in tSEQ when the node
      // accepts it and more is held than is staked, else in the accepted asset whose largest coin
      // covers the most fees.
      final txid = await authorizeBuildBroadcast((m) async => core.buildStakeTx(
            mnemonic: m,
            esploraUrl: Backend.esplora,
            stakerPubkey: key,
            csv: _unbondCsv,
            satoshi: atoms,
            feeAsset: await walletFeeParam(m, moved: SeqAssets.policy, movedAtoms: atoms),
          ));
      if (mounted) {
        _amount.clear();
        _snack(DevMode.instance.on ? 'Staked · ${txid.substring(0, 16)}…' : StakeWords.staked(formatAtoms(atoms.toString(), 8)));
        _load();
      }
    } catch (e) {
      if (mounted) _snack('Stake failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(String title, String body, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: AmbraText.title),
          const SizedBox(height: 6),
          Text(body, style: AmbraText.muted),
        ]),
      );

  /// Default mode: what staking is for, how much, where, what it costs and how to get it back, then
  /// the stake (step 1), the pool it makes blocks through (step 2), the stakes held, and rewards.
  Widget _plainBody() {
    return Column(children: [
      Expanded(
        child: ListView(key: const ValueKey('stakePlain'), padding: const EdgeInsets.all(20), children: [
          _section(StakeWords.whatTitle, StakeWords.what, key: const ValueKey('stakeWhat')),
          _section(StakeWords.howMuchTitle, StakeWords.howMuch('40,000', formatAtoms('$_tseqHeld', 8)), key: const ValueKey('stakeHowMuch')),
          _section(StakeWords.whereTitle, StakeWords.where),
          _section(StakeWords.costTitle, StakeWords.cost),
          _section(StakeWords.backTitle, StakeWords.back),
          const SizedBox(height: 8),
          const Text(StakeWords.step1, style: AmbraText.title),
          const SizedBox(height: 8),
          AmbraField(label: StakeWords.amount, controller: _amount, hint: '40000'),
          if (_status != null) ...[
            const SizedBox(height: 10),
            Text(_status!, key: const ValueKey('stakeStatus'), style: AmbraText.muted),
          ],
          const SizedBox(height: 12),
          PrimaryButton(
              key: const ValueKey('stakeReview'),
              label: StakeWords.review,
              busy: _busy,
              icon: Icons.lock_outline,
              onPressed: _busy ? null : _stake),
          const SizedBox(height: 26),
          const _PoolSection(plain: true),
          const SizedBox(height: 26),
          const StakesSection(plain: true),
          const SizedBox(height: 26),
          RewardsCard(
            totals: _rewardTotals,
            rows: _rewardRows,
            maturity: _maturity,
            onChanged: () async {
              final m = await WalletRepository.instance.readMnemonic();
              if (m != null) await _loadRewards(m);
            },
          ),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(StakeWords.title, style: AmbraText.title),
        iconTheme: const IconThemeData(color: AmbraColors.dim),
      ),
      body: AmbraBackground(
        child: !DevMode.instance.on
            ? _plainBody()
            : Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(20), children: [
              const Text(
                'Bond Sequence (tSEQ) to participate in block production. Stake weight = the amount '
                '(no benefit to a longer lock). It uses the network minimum unbonding period.',
                style: AmbraText.muted,
              ),
              const SizedBox(height: 18),
              RewardsCard(
                totals: _rewardTotals,
                rows: _rewardRows,
                maturity: _maturity,
                onChanged: () async {
                  final m = await WalletRepository.instance.readMnemonic();
                  if (m != null) await _loadRewards(m);
                },
              ),
              const SizedBox(height: 18),
              AmbraField(label: 'Amount (tSEQ)', controller: _amount, hint: '40000'),
              const SizedBox(height: 18),
              AmbraCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(children: [
                  _Kv('Spendable tSEQ', formatAtoms(_tseq.toString(), 8)),
                  _Kv('Minimum stake', '40,000 tSEQ'),
                  _Kv('Locked for', 'about 15 days'),
                  _Kv('Unbonding', 'about 2 weeks more'),
                  _Kv('Your staker key', _stakerKey == null ? '…' : '${_stakerKey!.substring(0, 16)}…'),
                ]),
              ),
              const SizedBox(height: 14),
              const WarnCallout(
                'Staked tSEQ counts in your balance but cannot be spent while it is staked: it is '
                'locked for about 15 days, and once you unbond it, it returns to your wallet '
                'about two weeks (2,016 Bitcoin blocks) later. Only stake what you can lock for a month.',
              ),
              const SizedBox(height: 26),
              const StakesSection(),
              const SizedBox(height: 26),
              const _PoolSection(),
            ]),
          ),
          BottomActionBar(children: [
            PrimaryButton(label: 'Review & stake', busy: _busy, icon: Icons.lock_outline, onPressed: _busy ? null : _stake),
          ]),
        ]),
      ),
    );
  }
}

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          SizedBox(width: 130, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.mono)),
        ]),
      );
}


/// Every stake of this wallet's key, whichever wallet made it: under the time lock
/// this app bonds with or the height lock of the web wallet and the extension. Each
/// is unbonded here once its lock has passed, and the unbonded coins are returned to
/// the wallet once the unbonding period has passed (2,016 Bitcoin blocks, counted
/// from the Bitcoin block the unbond's own block anchors to).
class StakesSection extends StatefulWidget {
  const StakesSection({super.key, this.autoLoad = true, this.plain = false});

  /// Default mode's words ([StakeWords]).
  final bool plain;

  /// Read the stakes from the chain when shown (off in widget tests, which set
  /// [StakeHoldings] themselves).
  final bool autoLoad;
  @override
  State<StakesSection> createState() => _StakesSectionState();
}

class _StakesSectionState extends State<StakesSection> {
  StakeHoldings get _h => StakeHoldings.instance;
  bool _loading = true;
  String? _busy; // txid of the stake being acted on
  int? _tip;

  @override
  void initState() {
    super.initState();
    _h.addListener(_changed);
    if (widget.autoLoad) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _h.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final m = await WalletRepository.instance.readMnemonic();
    if (m != null) {
      try {
        final r = await http
            .get(Uri.parse('${Backend.esplora}/blocks/tip/height'), headers: Backend.authHeaders)
            .timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) _tip = int.tryParse(r.body.trim());
      } catch (_) {}
      await _h.refresh(m, force: true, readDelegation: false);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(title, style: AmbraText.title),
        content: Text(body, style: AmbraText.muted),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action, style: const TextStyle(color: AmbraColors.amber2, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _step(core.StakeEntry s, {required bool unbond}) async {
    final amount = '${formatAtoms(s.value.toString(), 8)} tSEQ';
    final plain = widget.plain;
    final n = formatAtoms(s.value.toString(), 8);
    final ok = plain
        ? (unbond
            ? await _confirm(StakeWords.takeBackTitle(n), StakeWords.takeBackBody, StakeWords.takeBack)
            : await _confirm(StakeWords.returnTitle(n), StakeWords.returnBody, StakeWords.returnToWallet))
        : unbond
        ? await _confirm(
            'Unbond $amount?',
            'It stops counting as stake once this confirms, and returns to your wallet about two '
                'weeks later (2,016 Bitcoin blocks), when you can move it back here. The network '
                'fee, at most 1% of the stake, is taken from it.',
            'Unbond')
        : await _confirm(
            'Return $amount to your wallet?',
            'The unbonding period is over: this moves it back into your wallet, where it can be '
                'spent. The network fee is taken from it.',
            'Return');
    if (!ok || !mounted) return;
    if (!await WalletRepository.instance.requirePaymentAuth()) return _snack('Authentication failed or cancelled.');
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    setState(() => _busy = s.txid);
    try {
      final raw = unbond
          ? await core.buildUnbond(
              mnemonic: m, esploraUrl: Backend.esplora, anchorUrl: Backend.anchorBase, txid: s.txid, vout: s.vout)
          : await core.buildUnbondClaim(
              mnemonic: m, esploraUrl: Backend.esplora, anchorUrl: Backend.anchorBase, txid: s.txid, vout: s.vout);
      final txid = await core.broadcastStakeStep(esploraUrl: Backend.esplora, txHex: raw);
      _snack(plain ? (unbond ? StakeWords.takeBack : StakeWords.returnToWallet) : '${unbond ? 'Unbonding' : 'Returning to your wallet'} · ${txid.substring(0, 16)}…');
      await _load();
    } catch (e) {
      _snack('Failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _h.stakes;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(widget.plain ? StakeWords.yours : 'Your stakes', style: AmbraText.title)),
        IconButton(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, color: AmbraColors.dim, size: 20),
          tooltip: 'Reload',
        ),
      ]),
      const SizedBox(height: 8),
      if (_loading && list.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text(StakeWords.looking, style: AmbraText.muted))
      else if (list.isEmpty)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
              _h.error != null && _h.readAt == null
                  ? 'Could not read your stakes: ${friendlyError(_h.error!)}'
                  : StakeWords.none,
              style: AmbraText.muted),
        )
      else
        for (final s in list)
          Padding(
            key: Key('stake-${s.txid}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: AmbraCard(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                      child: Text('${formatAtoms(s.value.toString(), 8)} tSEQ',
                          style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontWeight: FontWeight.w700))),
                  if (!widget.plain) Text('${s.txid.substring(0, 8)}…', style: AmbraText.sub),
                ]),
                const SizedBox(height: 6),
                Text(widget.plain ? plainStakeStatus(s, tip: _tip) : stakeStatusText(s, tip: _tip), style: AmbraText.sub),
                if (s.state == 'unbondable' || s.state == 'claimable') ...[
                  const SizedBox(height: 10),
                  PrimaryButton(
                    label: s.state == 'unbondable' ? (widget.plain ? StakeWords.takeBack : 'Unbond') : 'Return to wallet',
                    busy: _busy == s.txid,
                    icon: s.state == 'unbondable' ? Icons.lock_open : Icons.south_west,
                    onPressed: _busy != null ? null : () => _step(s, unbond: s.state == 'unbondable'),
                  ),
                ],
              ]),
            ),
          ),
    ]);
  }
}

/// A pool as the public board reports it.
class _Pool {
  _Pool(this.signer, this.weight, this.delegators, this.payout, this.reliability,
      this.eligible, this.pendingBlocks, this.pendingMode, this.declared);
  final String signer;
  /// Whether this signer declared itself a pool by committing a payout policy.
  /// The feed carries every staker so the screen can describe whichever one this
  /// wallet is lent to; only declared ones are offered to join.
  final bool declared;
  final BigInt weight;
  final int delegators;
  final String payout;
  final double? reliability;
  final bool eligible;
  final int? pendingBlocks;
  final String? pendingMode;

  static _Pool? parse(dynamic j) {
    if (j is! Map) return null;
    final signer = j['signer'];
    if (signer is! String) return null;
    final pending = (j['policy_pending'] is List && (j['policy_pending'] as List).isNotEmpty)
        ? (j['policy_pending'] as List).first
        : null;
    return _Pool(
      signer,
      BigInt.tryParse('${j['weight']}') ?? BigInt.zero,
      (j['delegators'] as num?)?.toInt() ?? 0,
      (j['payout'] as String?) ?? '',
      (j['reliability'] as num?)?.toDouble(),
      j['eligible'] != false,
      pending is Map ? (pending['blocks_away'] as num?)?.toInt() : null,
      pending is Map ? pending['mode'] as String? : null,
      j['declared'] != false,
    );
  }
}

/// Joining, moving between and leaving staking pools.
///
/// Delegating lends this wallet's stake WEIGHT to a pool's signer. The staked
/// coins are never touched and the pool can never spend them: its key appears
/// nowhere in the staking output's spending condition. Leaving is unilateral,
/// which is why it is always one tap away here and never behind a confirmation
/// that could fail.
///
/// Starting a pool is deliberately absent. Announcing a payout policy binds
/// every block a key ever produces and needs that key online on the machine
/// producing them, which a phone cannot promise, so it lives only in the node
/// wallet.
class _PoolSection extends StatefulWidget {
  const _PoolSection({this.plain = false});

  /// Default mode: plain words, each pool by whether it is producing and what it pays, no keys.
  final bool plain;
  @override
  State<_PoolSection> createState() => _PoolSectionState();
}

/// Signers this device has delegated to. A HINT for finding a record again, not
/// a source of truth: a pool with no weight and no announced policy never
/// appears on the board, so nothing else would remember its key.
const _hintKey = StakeHoldings.hintKey;

/// What a first membership needs of tSEQ on the chain: its small payment to the staking key and the
/// network fee (0.1 tSEQ, far above both).
final BigInt _joinNeed = BigInt.from(10000000);

Future<List<String>> _loadHints() async {
  try {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_hintKey) ?? const [];
  } catch (_) { return const []; }
}

Future<void> _rememberSigner(String signer) async {
  try {
    final p = await SharedPreferences.getInstance();
    final seen = p.getStringList(_hintKey) ?? <String>[];
    if (seen.contains(signer)) return;
    await p.setStringList(_hintKey, [signer, ...seen].take(20).toList());
  } catch (_) { /* a hint that cannot be stored simply is not used */ }
}

class _PoolSectionState extends State<_PoolSection> {
  List<_Pool> _pools = const [];
  BigInt _networkWeight = BigInt.zero;
  int _stakers = 0;
  int _blockSeconds = 60;
  core.DelegationRecord? _deleg;
  String? _selected;
  bool _busy = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // The board and the wallet's own delegation are independent: a board that is
    // briefly away must never hide the Leave button, because leaving is the one
    // thing that has to work at all times.
    try {
      final r = await http.get(Uri.parse(Backend.pools)).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final list = (j['pools'] as List?) ?? const [];
        final parsed = <_Pool>[];
        for (final e in list) {
          final p = _Pool.parse(e);
          if (p != null) parsed.add(p);
        }
        if (mounted) {
          setState(() {
            _pools = parsed;
            _networkWeight = BigInt.tryParse('${j['network_weight']}') ?? BigInt.zero;
            _blockSeconds = (j['block_seconds'] as num?)?.toInt() ?? 60;
            _stakers = (j['stakers'] as num?)?.toInt() ?? 0;
          });
        }
      }
    } catch (_) {
      // keep whatever was showing; the card says when it has no list
    }
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m != null) {
        final d = await core.findDelegation(
            mnemonic: m, esploraUrl: Backend.esplora, probeSigners: await _probeSigners());
        // The record is the holder's Sequence token: it counts in the balance.
        StakeHoldings.instance.setDelegation(d);
        if (mounted) setState(() => _deleg = d);
      }
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Everything worth probing for a record of ours, in the ORDER it should be
  /// tried: the signers this device has used, then the rest of the board.
  ///
  /// The order is part of the contract. find_delegation stops as soon as a probe
  /// finds something, so putting the one or two keys this device actually used
  /// first turns the ordinary case into a single request instead of one per
  /// pool. A Dart Set preserves insertion order, which is what keeps that true.
  Future<List<String>> _probeSigners() async {
    final out = <String>{...await _loadHints()};
    for (final p in _pools) {
      out.add(p.signer);
    }
    return out.toList();
  }

  _Pool? get _currentPool {
    final d = _deleg;
    if (d == null) return null;
    for (final p in _pools) {
      if (p.signer == d.signer) return p;
    }
    return null;
  }

  String? _status;

  Future<void> _delegate() async {
    final plain = widget.plain;
    final target = _selected;
    if (target == null) return _snack(plain ? StakeWords.chooseFirst : 'Choose a pool first');
    final d = _deleg;
    if (d != null && d.signer == target) return _snack('You are already in that pool');
    if (plain && StakeHoldings.instance.stakes.isEmpty) return _snack(StakeWords.noStakeYet);

    final moving = d != null;
    // A first membership is a small payment of the wallet's own tSEQ on the chain: moved out of the
    // Ark first when none is there.
    if (plain && !moving) {
      setState(() => _busy = true);
      try {
        await ensureOnChain(
          asset: SeqAssets.policy,
          ticker: 'tSEQ',
          precision: 8,
          need: _joinNeed,
          onChain: () async {
            final m = await WalletRepository.instance.readMnemonic();
            if (m == null) return BigInt.zero;
            final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
            for (final b in s.balances) {
              if (b.assetId == SeqAssets.policy) return BigInt.tryParse(b.atoms) ?? BigInt.zero;
            }
            return BigInt.zero;
          },
          purpose: StakeWords.purposeJoin,
          say: (t) {
            if (mounted) setState(() => _status = t);
          },
        );
        if (mounted) setState(() => _status = null);
      } on OnChainRefusal catch (e) {
        if (mounted) setState(() => _status = e.message);
        return;
      } catch (e) {
        if (mounted) setState(() => _status = friendlyError(e));
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
    }
    final name = StakeWords.poolName(target);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(plain ? (moving ? StakeWords.moveTitle(name) : StakeWords.joinTitle(name)) : (moving ? 'Move to this pool?' : 'Delegate to this pool?'),
            style: AmbraText.title),
        content: Text(
          plain
              ? StakeWords.joinBody
              : 'Your stake’s block-signing rights go to ${target.substring(0, 16)}…\n\n'
                  'Your coins do NOT move, and this pool can never spend them: only this wallet can. '
                  'You can take the rights back at any time, immediately, without the pool’s cooperation.\n\n'
                  'What you are trusting it for is the reward. Check what it has committed to paying.',
          style: AmbraText.muted,
        ),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(plain ? (moving ? StakeWords.move : StakeWords.join) : (moving ? 'Move' : 'Delegate'),
                style: const TextStyle(color: AmbraColors.amber2, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    await _rememberSigner(target);
    try {
      if (moving) {
        // Moving spends the old record and creates the new one in ONE
        // transaction: consensus permits at most one live record per staking
        // key, so two loose transactions could be mined in the order that
        // invalidates a block.
        final m = await WalletRepository.instance.readMnemonic();
        if (m == null) throw Exception('wallet unavailable');
        final raw = await core.buildDelegationSpend(
            mnemonic: m, esploraUrl: Backend.esplora, rotateTo: target,
            probeSigners: await _probeSigners());
        final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: raw);
        _snack(plain ? StakeWords.moved(name) : 'Moving pool · ${txid.substring(0, 16)}…');
      } else {
        final txid = await _join(target);
        _snack(plain ? StakeWords.joined(name) : 'Delegated · ${txid.substring(0, 16)}…');
      }
      await _load();
    } catch (e) {
      _snack('Failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A first delegation. The network accepts a record only from a transaction
  /// spending a coin of the staking key, so a join is the wallet's payment to
  /// that key, signed like any payment, and the record created from the coin;
  /// the core broadcasts both. A coin already at the staking key (a join whose
  /// record never went out) is used instead of a new payment.
  Future<String> _join(String target) async {
    final ok = await WalletRepository.instance.requirePaymentAuth();
    if (!ok) throw Exception('Authentication failed or cancelled.');
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('wallet unavailable');
    final resumed = await core.delegateWithKeyCoin(
        mnemonic: m, esploraUrl: Backend.esplora, signerPubkey: target);
    if (resumed != null) return resumed;
    // The payment moves tSEQ to the staking key; its fee follows the wallet rule.
    final pset = await core.buildDelegateTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        signerPubkey: target,
        feeAsset: await walletFeeParam(m, moved: SeqAssets.policy));
    final signed = await core.signPset(mnemonic: m, pset: pset);
    return core.broadcastDelegation(
        mnemonic: m, esploraUrl: Backend.esplora, pset: signed, signerPubkey: target);
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(widget.plain ? StakeWords.leaveTitle : 'Leave this pool?', style: AmbraText.title),
        content: Text(
          widget.plain
              ? StakeWords.leaveBody
              : 'Your stake’s weight counts for you again from the next confirmation, and the pool loses it.\n\n'
                  'This does NOT unstake: your coins were never moved by delegating and are not moved now.',
          style: AmbraText.muted,
        ),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave',
                style: TextStyle(color: AmbraColors.amber2, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final raw = await core.buildDelegationSpend(
          mnemonic: m, esploraUrl: Backend.esplora, rotateTo: null,
          probeSigners: await _probeSigners());
      final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: raw);
      _snack(widget.plain ? StakeWords.left : 'Left the pool · ${txid.substring(0, 16)}…');
      await _load();
    } catch (e) {
      _snack('Failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What a delegator most needs to see, and would otherwise have to go looking
  /// for: a pool that has promised nothing, and a promise about to change.
  List<String> get _warnings {
    final d = _deleg;
    if (d == null) return const [];
    final out = <String>[];
    if (!d.confirmed) {
      out.add('This change has not confirmed yet. Until it does, your weight still counts for you.');
    }
    final p = _currentPool;
    if (p == null) {
      out.add('This pool is not on the board right now, so what it has committed to cannot be shown. '
          'Leaving always works.');
      return out;
    }
    if (!p.declared) {
      out.add('This signer has not declared itself a pool: it has committed to no payout policy and never '
          'asked for delegations. It keeps everything its blocks earn, and nothing on-chain obliges it to '
          'pay you.');
    } else if (p.payout.contains('no policy committed')) {
      out.add('This pool has committed to no payout policy, so by default it keeps everything its '
          'blocks earn. Nothing on-chain obliges it to pay you.');
    } else if (p.payout.startsWith('pays a committed address')) {
      out.add('This pool pays a committed address. The chain stops it redirecting the reward '
          'silently, but does not check that address shares anything with you.');
    } else if (p.payout.startsWith('pays every delegator')) {
      out.add('This pool shares rewards proportionally: they pool up on-chain and anyone can '
          'trigger the payout. Leaving gives up your share that has not been paid out yet, so '
          'have your rewards paid out before you leave.');
    }
    final away = p.pendingBlocks;
    if (away != null) {
      final when = DateTime.now().add(Duration(seconds: away * _blockSeconds));
      out.add('This pool has announced a NEW payout policy (${p.pendingMode ?? 'changed'}) binding in '
          '$away blocks, around ${when.toLocal()}. If you do not accept it, leave before then: '
          'leaving is immediate and needs nobody’s permission.');
    }
    if ((p.reliability ?? 1) < 0.5) {
      out.add('This pool has produced far fewer blocks than its weight is owed. While that lasts, '
          'your delegated weight is earning you nothing.');
    }
    return out;
  }

  String _share(BigInt w) {
    if (_networkWeight == BigInt.zero) return '';
    final pct = w * BigInt.from(1000) ~/ _networkWeight;
    return ' · ${(pct.toInt() / 10).toStringAsFixed(1)}% of the network';
  }

  /// Default mode's pool list: each pool by whether it is producing, its share of all stake and its
  /// members, and what it pays, in words; none chosen until the person chooses.
  Widget _plainBuild() {
    final d = _deleg;
    final open = _pools.where((p) => p.declared).toList();
    final cur = _currentPool;
    return Column(key: const ValueKey('poolsPlain'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text(StakeWords.step2, style: AmbraText.title)),
        IconButton(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, color: AmbraColors.dim, size: 20),
          tooltip: 'Reload',
        ),
      ]),
      if (d != null) ...[
        AmbraCard(
          padding: const EdgeInsets.all(14),
          child: Text(
              d.confirmed ? '${StakeWords.inPool} ${StakeWords.poolName(d.signer)}.' : StakeWords.joining,
              key: const ValueKey('poolCurrent'),
              style: AmbraText.body),
        ),
        if (cur?.pendingBlocks != null) ...[
          const SizedBox(height: 8),
          WarnCallout(StakeWords.changing(cur!.pendingBlocks!)),
        ],
        const SizedBox(height: 10),
      ],
      if (_status != null) ...[
        Text(_status!, key: const ValueKey('poolStatus'), style: AmbraText.muted),
        const SizedBox(height: 10),
      ],
      if (_loading && _pools.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('…', style: AmbraText.muted))
      else if (open.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text(StakeWords.noPools, style: AmbraText.muted))
      else
        for (final p in open)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              key: ValueKey('pool-${p.signer.substring(0, 8)}'),
              onTap: () => setState(() => _selected = p.signer),
              child: AmbraCard(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(StakeWords.poolName(p.signer), style: AmbraText.body)),
                    if (_selected == p.signer || (d != null && d.signer == p.signer))
                      const Icon(Icons.check_circle, color: AmbraColors.amber2, size: 18),
                  ]),
                  const SizedBox(height: 6),
                  Text(poolVerdict(reliability: p.reliability, eligible: p.eligible, weight: p.weight),
                      style: const TextStyle(color: AmbraColors.amber2, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text([?poolShare(p.weight, _networkWeight), StakeWords.members(p.delegators)].join(' · '), style: AmbraText.sub),
                  const SizedBox(height: 4),
                  Text(poolPayout(p.payout), style: AmbraText.sub),
                ]),
              ),
            ),
          ),
      const SizedBox(height: 12),
      PrimaryButton(
        key: const ValueKey('poolJoin'),
        label: d == null ? StakeWords.join : StakeWords.move,
        busy: _busy,
        icon: Icons.groups_outlined,
        onPressed: _busy || _selected == null || (d != null && d.signer == _selected) ? null : _delegate,
      ),
      if (d != null) ...[
        const SizedBox(height: 10),
        GhostButton(label: StakeWords.leave, onPressed: _busy ? null : _leave),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.plain) return _plainBuild();
    final d = _deleg;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Staking pool', style: AmbraText.title),
      const SizedBox(height: 8),
      const Text(
        'A pool produces blocks on your behalf, so a stake too small to win blocks often, or a '
        'wallet you would rather keep closed, still earns. Your coins never move and the pool can '
        'never spend them: it is lent only the right to sign with your weight. You can take that '
        'back at any moment, without asking anyone.',
        style: AmbraText.muted,
      ),
      const SizedBox(height: 14),
      AmbraCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(children: [
          _Kv('Status',
              d == null ? 'Not delegating' : (d.confirmed ? 'Delegated' : 'Waiting to confirm')),
          if (d != null) _Kv('Pool', '${d.signer.substring(0, 16)}…'),
          if (d != null) _Kv('In the record', '${formatAtoms(d.value.toString(), 8)} tSEQ'),
        ]),
      ),
      for (final w in _warnings) ...[
        const SizedBox(height: 10),
        WarnCallout(w),
      ],
      if (_error != null) ...[
        const SizedBox(height: 10),
        WarnCallout('Could not read your delegation: $_error'),
      ],
      const SizedBox(height: 16),
      Row(children: [
        const Expanded(child: Text('Choose a pool', style: AmbraText.title)),
        IconButton(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, color: AmbraColors.dim, size: 20),
          tooltip: 'Reload',
        ),
      ]),
      const Text(
        '"Pays out" is what each pool has committed to on-chain. A pool that has committed to '
        'nothing keeps every fee its blocks earn.',
        style: AmbraText.muted,
      ),
      const SizedBox(height: 10),
      if (_loading && _pools.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('Loading pools…', style: AmbraText.muted))
      else if (!_pools.any((p) => p.declared))
        Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
                'No pool has declared itself yet. $_stakers signer(s) are producing blocks for themselves; '
                'a staker becomes a pool by committing a payout policy on-chain, and appears here when it does.',
                style: AmbraText.muted))
      else
        for (final p in _pools.where((p) => p.declared))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () => setState(() => _selected = p.signer),
              child: AmbraCard(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${p.signer.substring(0, 16)}…', style: AmbraText.mono)),
                    if (_selected == p.signer || (d != null && d.signer == p.signer))
                      const Icon(Icons.check_circle, color: AmbraColors.amber2, size: 18),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    '${formatAtoms(p.weight.toString(), 8)} tSEQ${_share(p.weight)} · '
                    '${p.delegators} delegator(s)'
                    '${p.reliability == null ? '' : ' · produces ${p.reliability!.toStringAsFixed(2)} of its share'}',
                    style: AmbraText.sub,
                  ),
                  const SizedBox(height: 4),
                  Text(p.payout, style: AmbraText.sub),
                  if (p.pendingBlocks != null) ...[
                    const SizedBox(height: 4),
                    Text('⚠ has announced a payout change binding in ${p.pendingBlocks} blocks',
                        style: const TextStyle(color: AmbraColors.amber2, fontSize: 12)),
                  ],
                  if (!p.eligible) ...[
                    const SizedBox(height: 4),
                    const Text('below the network minimum stake, so it cannot produce yet',
                        style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ],
                ]),
              ),
            ),
          ),
      const SizedBox(height: 12),
      PrimaryButton(
        label: d == null ? 'Delegate to the selected pool' : 'Move to the selected pool',
        busy: _busy,
        icon: Icons.groups_outlined,
        onPressed: _busy || _selected == null ? null : _delegate,
      ),
      if (d != null) ...[
        const SizedBox(height: 10),
        GhostButton(label: 'Leave this pool', onPressed: _busy ? null : _leave),
      ],
    ]);
  }
}


/// STAKING REWARDS — what staking has paid, and the standing instruction to
/// convert it.
///
/// A staker earns the transaction fees of the blocks it produces, in whichever
/// assets the payers chose, so rewards arrive as a tail of small balances in
/// assets nobody chose to hold. This card shows that tail, and offers to sell it
/// for ONE asset the staker picks. Bitcoin is the default and the first entry,
/// but not the only choice: outside staking no asset is privileged.
///
/// Which coins are rewards, and which batches convert, are decided by the kit
/// (see [RewardConvert]) — never here, and never differently from the desktop
/// wallet watching the same keys.
class RewardsCard extends StatefulWidget {
  const RewardsCard({super.key, required this.totals, required this.rows, this.maturity, this.onChanged});

  /// Blocks before a block reward can be spent, from the kit (null until read).
  final int? maturity;

  /// Per-asset totals, from `rewardTotals`.
  final List<Map<String, dynamic>> totals;

  /// What a dry run says would happen, from `RewardConvert.runPass`.
  final List<RewardPassRow> rows;

  final VoidCallback? onChanged;

  @override
  State<RewardsCard> createState() => _RewardsCardState();
}

class _RewardsCardState extends State<RewardsCard> {
  RewardConvert get _rc => RewardConvert.instance;

  @override
  Widget build(BuildContext context) {
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Staking rewards', style: AmbraText.title),
        const SizedBox(height: 8),
        Text(
          'What staking has paid you, in whatever assets the fees were paid in. Sequentia has no '
          'block subsidy: a block earns its own transaction fees and nothing else. '
          '${widget.maturity == null ? 'Block rewards can be spent once they mature' : 'Block rewards are spendable ${formatAtoms('${widget.maturity}', 0)} blocks after they are earned'}'
          '; a pool payout is spendable at once.',
          style: AmbraText.muted,
        ),
        const SizedBox(height: 12),
        if (widget.totals.isEmpty)
          const Text(
            'No staking rewards yet. A block pays its own fees, so rewards appear once a block '
            'you (or your pool) produced carried some.',
            style: AmbraText.muted,
          )
        else
          ...widget.totals.map((t) {
            final mature = (t['mature'] as BigInt).toString();
            final immature = (t['immature'] as BigInt).toString();
            final maturing = (t['immature'] as BigInt) > BigInt.zero ? ' · $immature maturing' : '';
            return _Kv(t['asset'] as String, '$mature spendable$maturing');
          }),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Convert my staking rewards automatically', style: AmbraText.body),
          value: _rc.enabled,
          onChanged: (v) async {
            setState(() => _rc.enabled = v);
            await _rc.save();
            widget.onChanged?.call();
          },
        ),
        const Text(
          'Once this is on, the wallet sells without asking again. It never converts more than '
          'staking has paid you, never touches your stake, and never converts what it cannot get '
          'a fair price for — but the selling itself is unattended, which is the point of it.',
          style: AmbraText.muted,
        ),
        if (_rc.enabled) ...[
          const SizedBox(height: 12),
          _Kv('Convert into', _rc.target == RewardConvert.btc ? 'BTC (Bitcoin)' : _rc.target),
          _Kv('Only once worth at least', _rc.minReceive.toString()),
          _Kv('Refuse a price worse than', '${(_rc.maxSlippageBp / 100).toStringAsFixed(2)}%'),
          const SizedBox(height: 12),
          if (widget.rows.isEmpty)
            const Text(
              'Nothing to convert right now. Rewards are gathered per asset until a batch is '
              'worth converting.',
              style: AmbraText.muted,
            )
          else
            // Why it would NOT convert matters as much as why it would:
            // "nothing happened" and "nothing should have happened" look
            // identical otherwise, and the second is far the more common.
            ...widget.rows.map((r) => _Kv(
                  '${r.value} ${r.asset}',
                  r.converts ? 'converting' : r.reason,
                )),
        ],
      ]),
    );
  }
}
