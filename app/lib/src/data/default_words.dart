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
  static const recipient = 'Recipient';
  static const recipientHint = 'a receive code, an address or an invoice';
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
  static const btcFee = 'The fee is paid in BTC.';
  static String feeIn(String ticker) => 'Fee paid in $ticker.';

  // BTC, held on the Bitcoin ark (the web wallet's words for it).
  static const arrivesAfterBlock = 'It arrives after a Bitcoin block.';
  static const noFees = 'No fees';
  static String btcSentAfterBlock(String amount) => 'Sent $amount BTC. $arrivesAfterBlock';
  static String btcUpTo(String amount) => 'You can send up to $amount BTC this way now.';
  static const couldNotSend = 'This payment could not be made. Nothing was sent.';

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

  /// The words no default-mode screen says (the contract's list).
  static const forbidden = [
    'rail', 'round', 'leaf', 'operator', 'tree', 'board', 'covenant', 'expiry', 'atom', 'sat', 'forfeit',
    'checkpoint', 'reassignment', 'exit', 'unroll', 'anchor', 'channel', 'node', 'room', 'relay', 'maker',
    'hash', 'preimage', 'HTLC', 'submarine', 'LSP', 'bridge', 'gateway', 'on-chain', 'Lightning',
  ];

  /// Every sentence above, filled with sample values: what the test reads.
  static List<String> all() => [
        receiveCode, receiveCodeLine, copyCode, codeCopied, newCode, amountInBtc,
        recipient, recipientHint, review('5', 'USDX'), reviewLine, sent('5', 'USDX', 1.2), stillArriving('USDX'),
        codeTakesAssets, addressNotNow, arrivesIn(null), arrivesIn(1), arrivesIn(12), sentThen('5', 'USDX', arrivesIn(1)),
        fee('5', 'USDX'), arriving('5', 'USDX'), redoing('5', 'USDX'), keptSafe('5', 'USDX'), received('5', 'USDX'), btcFee, feeIn('USDX'),
        arrivesAfterBlock, noFees, btcSentAfterBlock('0.001'),
        btcUpTo('0.001'), couldNotSend, byAddress(arrivesAfterBlock), arrivesNextBlock, moving('0.001', 'BTC'),
        payWaiting, payCameBack, onItsWay, notPaid, cameBack,
      ];
}
