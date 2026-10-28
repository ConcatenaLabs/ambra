/// Default mode's own sentences, as the default-mode contract gives them (sequentia-web-wallet
/// `docs/DEFAULT_MODE.md`, the same in every Sequentia wallet): change them there first.
class DefaultWords {
  static const receiveCode = 'Receive code';
  static const receiveCodeLine = 'Any asset, any amount. A payment from another Sequentia wallet arrives in seconds. '
      'Each code is paid once; a new one shows when it is.';
  static const copyCode = 'Copy receive code';
  static const codeCopied = 'Receive code copied';
  static const newCode = 'New code';
  static const showAddress = 'Show address';
  static const showCode = 'Show receive code';
  static const addressLine = 'For BTC, and for senders that ask for an address.';
  static const recipient = 'Recipient';
  static const recipientHint = 'a receive code, an address or an invoice';
  static String review(String amount, String ticker) => 'Send $amount $ticker?';
  static const reviewLine = 'It arrives in seconds.';
  static String sent(String amount, String ticker, double secs) => 'Sent $amount $ticker (${secs.toStringAsFixed(1)} s).';
  static String stillArriving(String ticker) => 'Part of this $ticker is still arriving: try again in a moment.';
  static const codeTakesAssets = 'A receive code takes Sequentia assets. For BTC, use an address or an invoice.';
  static const instantOnly = "This amount is kept for instant payments and can't be sent to an address yet. "
      'Send it to a receive code, or pay an invoice.';
  static String arriving(String amount, String ticker) => '$amount $ticker arriving';
  static String received(String amount, String ticker) => 'Received $amount $ticker.';
  static const btcFee = 'The fee is paid in BTC.';
  static String feeIn(String ticker) => 'Fee paid in $ticker.';

  /// The words no default-mode screen says (the contract's list).
  static const forbidden = [
    'rail', 'round', 'leaf', 'operator', 'tree', 'board', 'covenant', 'expiry', 'atom', 'sat', 'forfeit',
    'checkpoint', 'reassignment', 'exit', 'unroll', 'anchor', 'channel', 'node', 'room', 'relay', 'maker',
    'hash', 'preimage', 'HTLC', 'submarine', 'LSP', 'bridge', 'gateway', 'on-chain', 'Lightning',
  ];

  /// Every sentence above, filled with sample values: what the test reads.
  static List<String> all() => [
        receiveCode, receiveCodeLine, copyCode, codeCopied, newCode, showAddress, showCode, addressLine,
        recipient, recipientHint, review('5', 'USDX'), reviewLine, sent('5', 'USDX', 1.2), stillArriving('USDX'),
        codeTakesAssets, instantOnly, arriving('5', 'USDX'), received('5', 'USDX'), btcFee, feeIn('USDX'),
      ];
}
