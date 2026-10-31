/// What the Stake screen says in default mode, and how it reads the pool board in plain words.
///
/// The web wallet's docs/DEFAULT_MODE.md "Stake, pools and Mix" (change them together). Every
/// string here is checked against [kUserModeForbiddenWords] (stake_words_test.dart).
library;

/// Every string the Stake screen shows in default mode.
class StakeWords {
  static const title = 'Stake';

  // What staking is for.
  static const whatTitle = 'What staking is for';
  static const what =
      'Staking puts your Sequence tokens (tSEQ) to work making the network\'s blocks. Whoever makes a '
      'block earns the fees paid in it, in whatever assets they were paid. Your staked tSEQ also sets '
      'your tier on Levo. Only tSEQ can be staked, and it stays yours the whole time.';

  // How much.
  static const howMuchTitle = 'How much';
  static String howMuch(String min, String have) => 'At least $min tSEQ. You hold $have tSEQ.';

  // Where it goes.
  static const whereTitle = 'Where your stake makes blocks';
  static const where =
      'A phone cannot make blocks itself, so your stake makes them through a pool you choose. The pool '
      'never holds your tSEQ and can never spend it; you can leave it, or move to another, at any time.';

  // What it costs.
  static const costTitle = 'What it costs';
  static const cost =
      'A small network fee to stake, and another to take it back. The pool keeps part of what your '
      'stake earns (its commission, shown with each pool). While staked, your tSEQ cannot be spent.';

  // How to get it back.
  static const backTitle = 'How to get it back';
  static const back =
      'A stake stays locked for about 15 days. Then press Take back: about two weeks later it is '
      'ready, and Return to wallet puts it back in your balance.';

  // Step one: the stake.
  static const step1 = '1. Stake';
  static const amount = 'Amount (tSEQ)';
  static const review = 'Review stake';
  static String reviewTitle(String amount) => 'Stake $amount tSEQ?';
  static const reviewBody =
      'It stays in your balance but cannot be spent while it is staked: it is locked for about 15 '
      'days, and comes back about two weeks after you take it back.';
  static const stake = 'Stake';
  static String staked(String amount) => 'Staked $amount tSEQ. Now choose a pool for it below.';
  static String tooLittle(String min) => 'The least you can stake is $min tSEQ.';
  static String notEnough(String short) => 'Not enough tSEQ: $short tSEQ short.';

  // What a stake, a pool's membership and a mix need is moved out of the Ark first.
  static String movingOut(String what, String purpose) =>
      'Moving $what out of the Ark so it can be $purpose. It is ready in a few minutes. Keep this screen open.';
  static String cannotMoveNow(String what) =>
      '$what cannot be moved out of the Ark right now: the network has too little of it free. Nothing has moved: try again later.';
  static const notMoved = 'This could not be moved out of the Ark just now. Nothing was spent: try again in a moment.';
  static const notArrived = 'What was moved out of the Ark has not arrived yet. It stays yours: try again in a few minutes.';
  static const purposeStake = 'staked';
  static const purposeJoin = 'used to join the pool';

  // Step two: the pool.
  static const step2 = '2. Choose a pool';
  static const noPools =
      'No pool is open to join right now. Your stake is safe and stays yours; come back to choose one later.';
  static const join = 'Join this pool';
  static const move = 'Move to this pool';
  static const leave = 'Leave this pool';
  static const chooseFirst = 'Choose a pool first.';
  static String joinTitle(String pool) => 'Join $pool?';
  static String moveTitle(String pool) => 'Move to $pool?';
  static const joinBody =
      'Your stake makes blocks through this pool. Your tSEQ does not move, and the pool can never spend '
      'it. You can leave at any time, at once, without asking anyone. What you trust the pool with is '
      'paying you what it promised.';
  static const leaveTitle = 'Leave this pool?';
  static const leaveBody =
      'Your stake stops making blocks through this pool. This does not take your stake back: your tSEQ '
      'stays staked, and you can join another pool.';
  static const inPool = 'Your stake makes blocks through this pool.';
  static const joining = 'Joining: waiting for the network to confirm it.';
  static String joined(String pool) => 'Joined $pool.';
  static String moved(String pool) => 'Moved to $pool.';
  static const left = 'Left the pool.';
  static const noStakeYet = 'Stake first: a pool makes blocks with your stake.';

  // A pool as the list shows it.
  static String poolName(String key) => 'Pool ${key.substring(0, 8)}';
  static const producing = 'Producing its share';
  static const missingSome = 'Missing some blocks';
  static const mostlyOffline = 'Mostly offline';
  static const notProducing = 'Not producing yet';
  static const tooSmall = 'Too small to make blocks yet';
  static String share(String pct) => '$pct of all stake';
  static String members(int n) => n == 1 ? '1 member' : '$n members';
  static String payKeepsAll() => 'Has promised to pay nothing: it keeps what its blocks earn.';
  static String paySplit(String commission) => 'Pays each member its share of every block, less $commission.';
  static String payLottery(String commission) =>
      'Pays one member per block, drawn by stake: your share over time, in occasional lumps, less $commission.';
  static const payFixed = 'Pays a fixed address it chose; nothing obliges it to share with you.';
  static String changing(int blocks) => 'Has announced a change to what it pays, in $blocks blocks. Leave before then if you do not accept it.';

  // Your stakes.
  static const yours = 'Your stakes';
  static const none = 'No stakes yet. A stake made with this recovery phrase in any Sequentia wallet shows here.';
  static const looking = 'Looking for your stakes…';
  static const takeBack = 'Take back';
  static const returnToWallet = 'Return to wallet';
  static String takeBackTitle(String amount) => 'Take back $amount tSEQ?';
  static const takeBackBody =
      'It stops making blocks once this confirms, and is ready to return to your wallet about two weeks '
      'later. The network fee is taken from it.';
  static String returnTitle(String amount) => 'Return $amount tSEQ to your wallet?';
  static const returnBody = 'This puts it back in your balance, where it can be spent. The network fee is taken from it.';

  static List<String> all() => [
        title,
        whatTitle,
        what,
        howMuchTitle,
        howMuch('40,000', '1'),
        whereTitle,
        where,
        costTitle,
        cost,
        backTitle,
        back,
        step1,
        amount,
        review,
        reviewTitle('1'),
        reviewBody,
        stake,
        staked('1'),
        tooLittle('40,000'),
        notEnough('1'),
        movingOut('1 tSEQ', purposeStake),
        movingOut('1 tSEQ', purposeJoin),
        cannotMoveNow('1 tSEQ'),
        notMoved,
        notArrived,
        step2,
        noPools,
        join,
        move,
        leave,
        chooseFirst,
        joinTitle('Pool 0000aaaa'),
        moveTitle('Pool 0000aaaa'),
        joinBody,
        leaveTitle,
        leaveBody,
        inPool,
        joining,
        joined('Pool 0000aaaa'),
        moved('Pool 0000aaaa'),
        left,
        noStakeYet,
        poolName('0000aaaa'),
        producing,
        missingSome,
        mostlyOffline,
        notProducing,
        tooSmall,
        share('1.0%'),
        members(1),
        members(2),
        payKeepsAll(),
        paySplit('a 5% commission'),
        payLottery('a 5% commission'),
        payFixed,
        changing(10),
        yours,
        none,
        looking,
        takeBack,
        returnToWallet,
        takeBackTitle('1'),
        takeBackBody,
        returnTitle('1'),
        returnBody,
      ];
}

/// Whether a pool is producing, in words, from the board's `reliability` (blocks made against
/// what its stake is owed, over the board's window): the pool board's own verdicts.
String poolVerdict({double? reliability, required bool eligible, required BigInt weight}) {
  if (!eligible) return StakeWords.tooSmall;
  final r = reliability;
  if (r == null || r <= 0) return StakeWords.notProducing;
  if (r >= 0.9) return StakeWords.producing;
  if (r >= 0.6) return StakeWords.missingSome;
  return StakeWords.mostlyOffline;
}

/// What a pool pays, in plain words, from the board's description of its payout policy.
String poolPayout(String board) {
  final m = RegExp(r'commission ([0-9.]+)%').firstMatch(board);
  final pct = m == null ? null : double.tryParse(m.group(1)!);
  final commission = pct == null ? 'its commission' : 'a ${_pct(pct)} commission';
  if (board.contains('no policy committed')) return StakeWords.payKeepsAll();
  if (board.contains('(split)') || board.startsWith('pays every delegator')) return StakeWords.paySplit(commission);
  if (board.contains('lottery')) return StakeWords.payLottery(commission);
  if (board.startsWith('pays a committed address')) return StakeWords.payFixed;
  return StakeWords.payKeepsAll();
}

String _pct(double v) => v == v.roundToDouble() ? '${v.toInt()}%' : '${v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}%';

/// A pool's share of all stake, in words ("2.3% of all stake"), or null when the total is unknown.
String? poolShare(BigInt weight, BigInt network) {
  if (network <= BigInt.zero) return null;
  final permille = (weight * BigInt.from(1000) ~/ network).toInt();
  final s = permille < 1 && weight > BigInt.zero ? 'under 0.1%' : '${(permille / 10).toStringAsFixed(1)}%';
  return StakeWords.share(s);
}
