/// Default mode's own sentences, as the default-mode contract gives them (sequentia-web-wallet
/// `docs/DEFAULT_MODE.md`, the same in every Sequentia wallet): change them there first.
class DefaultWords {
  static const receiveCode = 'Receive code';
  static const receiveCodeLine = 'Any asset, any amount. A payment from another Sequentia wallet arrives in seconds. '
      'Each code is paid once; a new one shows when it is.';
  static const copyCode = 'Copy receive code';
  static const codeCopied = 'Receive code copied';
  static const newCode = 'New code';
  static const amountInBtc = 'Amount in BTC (optional)';
  /// The amount's label when it is asked in an asset rather than BTC.
  static const amountOptional = 'Amount (optional)';

  /// The switch under the receive code that makes it the confidential address, and what it means.
  static const confidential = 'Confidential';
  static const confidentialLine = 'Hides the asset and amount of a payment from everyone but you and the payer.';
  static const confidentialOn = 'Everyone can still see that a payment was made. A payment that arrives in seconds is '
      'never confidential, so this one arrives after the next block, in about a minute. '
      'BTC is never confidential: to receive BTC, turn this off.';
  static const addressCopied = 'Copied';
  static const recipient = 'Recipient';
  static const recipientHint = 'a receive code, a payment name, an address or an invoice';
  static String review(String amount, String ticker) => 'Send $amount $ticker?';
  static const reviewLine = 'It arrives in seconds.';
  static String sent(String amount, String ticker, double secs) => 'Sent $amount $ticker (${secs.toStringAsFixed(1)} s).';
  static String stillArriving(String ticker) => 'Part of this $ticker is still arriving: try again in a moment.';
  static const codeTakesAssets = 'A receive code takes Sequentia assets. For BTC, use an address or an invoice.';
  static const addressNotNow = "This amount can't be sent to an address right now. "
      'Send it to a receive code, or pay an invoice.';

  /// When a payment to an address from the instant part arrives: [minutes] is the
  /// operator's round interval in whole minutes, null when it publishes none.
  static String arrivesIn(int? minutes) => minutes == null
      ? 'It arrives shortly.'
      : (minutes <= 5 ? 'It arrives in a few minutes.' : 'It arrives in about $minutes minutes.');
  static String sentThen(String amount, String ticker, String arrives) => 'Sent $amount $ticker. $arrives';
  static String fee(String amount, String ticker) => 'Fee $amount $ticker';
  static String arriving(String amount, String ticker) => '$amount $ticker arriving';
  /// Held, spendable before, and taken back out of the chain with the Bitcoin block it rested on.
  static String redoing(String amount, String ticker) => '$amount $ticker being redone after a Bitcoin reorganisation';
  /// Not refreshed while the wallet was away: taken on the chain under its own key before it could
  /// be swept, and put back by itself once the wallet is open again. Part of the figure meanwhile.
  static String keptSafe(String amount, String ticker) => '$amount $ticker moved out of the Ark to keep it safe while you were away';
  /// Held where it cannot be sent in seconds (a wallet made before), on its way to where it can.
  static String moving(String amount, String ticker) => 'Moving $amount $ticker so it can be sent in seconds.';
  static String received(String amount, String ticker) => 'Received $amount $ticker.';
  /// The faucet has paid and the wallet has not taken the coin in yet (it was busy with an update).
  static String faucetOnItsWay(String amount, String ticker) =>
      'The faucet sent $amount $ticker. It shows in your balance as soon as your wallet has taken it in, usually within a few minutes.';
  /// What the wallet holds that nothing can move before a date (a vesting allocation): part of the
  /// figure, one line under it for each date, never counted as what can be spent ([vestingLots]).
  static String vests(String amount, String ticker, String date) => '$amount $ticker vests on $date';
  static String vestsOn(String date) => 'Vests on $date';
  /// Any action asked for more than can be spent now, the rest of it held until a date.
  static String notVested(String amount, String ticker, String date) =>
      '$amount $ticker of this vests on $date, and can be used from then. Nothing has moved.';
  /// The same, refused by the network, which names only the date.
  static String vestingRefused(String date) => 'Part of this vests on $date, and can be used from then. Nothing has moved.';
  static const notVestedYet = 'Part of this has not vested yet, and can be used once it has. Nothing has moved.';
  static const btcFee = 'The fee is paid in BTC.';
  static String feeIn(String ticker) => 'Fee paid in $ticker.';

  // BTC, held on the Bitcoin ark (the web wallet's words for it).
  static const arrivesAfterBlock = 'It arrives after a Bitcoin block.';
  static const noFees = 'No fees';
  static String btcSentAfterBlock(String amount) => 'Sent $amount BTC. $arrivesAfterBlock';
  static String btcUpTo(String amount) => 'You can send up to $amount BTC this way now.';
  static const couldNotSend = 'This payment could not be made. Nothing was sent.';

  /// When the service holding BTC for instant payments stops renewing it and it would soon need
  /// renewing, the wallet moves it to its own Bitcoin address by itself (the web wallet's words).
  static String exitStarted(String amount, String fee) =>
      'The service holding $amount BTC for instant payments stopped renewing it, so it is moving to your Bitcoin address. Bitcoin network fees: about $fee BTC, paid from your Bitcoin address.';
  static String exitMoving(String amount) => 'Moving $amount BTC to your Bitcoin address, one Bitcoin block at a time.';
  static String exitArrived(String amount, String? fee) =>
      '$amount BTC arrived at your Bitcoin address, moved there because the service holding it for instant payments stopped renewing it.'
      '${fee == null ? '' : ' Bitcoin network fees: about $fee BTC.'}';
  static String exitNeedsFees(String amount, String need) =>
      'The service holding $amount BTC for instant payments stopped renewing it, and it needs renewing within a day. To move it to your Bitcoin address yourself, first receive about $need BTC at your Bitcoin address: it pays the Bitcoin network fees once confirmed.';
  static String exitNotWorth(String amount) =>
      'The service holding $amount BTC for instant payments stopped renewing it. Moving that out alone would cost more than it holds, so it stays there and is renewed once the service answers again.';

  /// An invoice whose payee holds the payment and has not taken it yet (a hold invoice): not
  /// paid until they do, and it comes back if they never do. The web wallet's words.
  static const payWaiting = 'On its way: waiting for the other side to accept it.';
  static const payCameBack = 'Not paid: the payment came back, and the BTC is in your balance again.';
  static const onItsWay = 'On its way';
  static const notPaid = 'Not paid';
  static const cameBack = 'The payment came back';

  /// A receive code paid at its address because this wallet holds nothing that pays it in
  /// seconds: said in the review, with when it arrives.
  static String byAddress(String arrives) => "This can't arrive in seconds from what you hold now, so it goes to the address. $arrives";
  static const arrivesNextBlock = 'It arrives after the next block, in about a minute.';

  /// One payment of the Bitcoin ark's `direct` figure or more goes to the address, never into the
  /// ark (ark_limits.dart): said first in the review, and under Receive's amount.
  static String byAddressLarge(String usd) => 'A payment of $usd USD or more goes to the address.';

  /// A payment the way in seconds cannot carry now (above the most the service takes in one
  /// payment, ln_max_payment.dart): paid at the code's address, said first in the review.
  static const byAddressNoWay = 'This can’t arrive in seconds right now, so it goes to the address.';

  /// No invoice for an amount that goes to the address, nor for more than the service takes in
  /// one payment: the receive code, which carries the address, instead.
  static const giveCode = 'Give the receive code instead: it is paid there.';
  static const invoiceNoWay = 'This can’t arrive in seconds right now. Give the receive code instead: it is paid at the address.';

  /// The service that holds the wallet's coins for instant payments does not answer: the coins
  /// are still the wallet's, and go home to its own address from what the wallet holds and the
  /// chain alone (home_coins.dart). Balance shows the card in either mode.
  static const homeLine = 'The service that holds your coins for instant payments is not answering. '
      'Your coins are still yours: wait for it to come back, or take them home to your own address now.';
  static const homeButton = 'Take my coins home';
  static const homeQuoting = 'Working out what it costs\u2026';
  static const homeTitle = 'Take your coins home?';
  static String homeAsset(String amount, String ticker, String fees) =>
      '$amount $ticker${fees.isEmpty ? '' : ', network fees about $fees'}';
  static String homeWhen(int hours) => hours > 0
      ? 'They reach your own address in about $hours hours, and cannot be sent until then. Open this wallet again after that to finish.'
      : 'They reach your own address shortly, and cannot be sent until then.';
  static const homeConfirm = 'Take them home';
  static const homeWorking = 'Taking your coins home\u2026';
  static String homeNotNow(String amount, String ticker) =>
      '$amount $ticker cannot be taken home right now. Nothing of it was sent: try again later.';
  static const homeNothing = 'None of your coins can be taken home right now. Nothing was sent: try again later.';
  static String homeOnWay(String amount, String ticker, int hours) => hours > 0
      ? '$amount $ticker on its way to your own address: it arrives in about $hours hours, once this wallet is open.'
      : '$amount $ticker on its way to your own address.';

  /// The words no default-mode screen says (the contract's list).
  static const forbidden = [
    'rail', 'round', 'leaf', 'operator', 'tree', 'board', 'covenant', 'expiry', 'atom', 'sat', 'forfeit',
    'checkpoint', 'reassignment', 'exit', 'unroll', 'anchor', 'channel', 'node', 'room', 'relay', 'maker',
    'hash', 'preimage', 'HTLC', 'submarine', 'LSP', 'bridge', 'gateway', 'on-chain', 'Lightning',
    'claim', 'distribution', 'lapse', 'locktime',
  ];

  /// Every sentence above, filled with sample values: what the test reads.
  static List<String> all() => [
        receiveCode, receiveCodeLine, copyCode, codeCopied, newCode, amountInBtc, amountOptional,
        confidential, confidentialLine, confidentialOn, addressCopied,
        recipient, recipientHint, review('5', 'USDX'), reviewLine, sent('5', 'USDX', 1.2), stillArriving('USDX'),
        codeTakesAssets, addressNotNow, arrivesIn(null), arrivesIn(1), arrivesIn(12), sentThen('5', 'USDX', arrivesIn(1)),
        fee('5', 'USDX'), arriving('5', 'USDX'), redoing('5', 'USDX'), keptSafe('5', 'USDX'), received('5', 'USDX'), btcFee, feeIn('USDX'),
        arrivesAfterBlock, noFees, btcSentAfterBlock('0.001'),
        btcUpTo('0.001'), couldNotSend, byAddress(arrivesAfterBlock), arrivesNextBlock, moving('0.001', 'BTC'),
        byAddressLarge('1,500'), byAddressNoWay, giveCode, invoiceNoWay,
        homeLine, homeButton, homeQuoting, homeTitle, homeAsset('50', 'USDX', '0.00000145 USDX'), homeAsset('50', 'USDX', ''),
        homeWhen(37), homeWhen(0), homeConfirm, homeWorking, homeNotNow('5', 'USDX'), homeNothing,
        homeOnWay('5', 'USDX', 37), homeOnWay('5', 'USDX', 0),
        payWaiting, payCameBack, onItsWay, notPaid, cameBack,
        exitStarted('0.0015', '0.00002'), exitMoving('0.0015'), exitArrived('0.0015', '0.00002'), exitArrived('0.0015', null),
        exitNeedsFees('0.0015', '0.00002'), exitNotWorth('0.00002'),
        vests('100', 'ORNG', '3 November 2026'), vestsOn('3 November 2026'), notVested('100', 'ORNG', '3 November 2026'),
        vestingRefused('3 November 2026'), notVestedYet,
      ];
}
