/// The user-mode composer's BTC trades: an asset for BTC, or BTC for an asset, in one hash-lock.
/// The Dart twin of the web wallet's `user-trade-btc.js`: change them together.
///
/// The asset moves inside the operator's tree under a payment hash (the leaf library's
/// `lightning_pay` and `lightning_receive` under a hash, the operator settling it between its own
/// two wallets); the BTC moves over Bitcoin Lightning under the same hash, between the person's
/// Bitcoin Lightning wallet ([BtcLightning]: the Bitcoin ark in user mode, else the wallet's own
/// hosted node) and the maker's node. BTC is never a leaf and never pegged.
///
/// The hash is always the one whoever receives the BTC makes, and whoever gives the asset locks
/// first; the BTC is paid only once the leaf received under the hash is held for good:
///   selling an asset for BTC   the wallet makes a Bitcoin invoice (its own preimage); the maker
///                              asks to receive the asset under that hash; the wallet's leaf pays
///                              it; once the maker's leaf has come it pays the wallet's invoice,
///                              learns the preimage from it, and claims. The wallet then hands the
///                              preimage to the operator too, so its own payment is settled even if
///                              the maker never claims.
///   buying an asset with BTC   the maker makes a Bitcoin invoice; the wallet asks to receive the
///                              asset under its hash; the maker's leaf pays it; once the wallet's
///                              leaf has come and is final, with its home date far enough off, the
///                              wallet pays the maker's invoice, learns the preimage, and claims.
/// Neither side can take what it gets before paying: the leaf received under the hash opens only
/// with the preimage, and the preimage comes out only when the BTC is paid.
///
/// A payment of BTC is bounded by the whole lock of its route (its `delay`, the final delta and
/// every hop's on the way) when the wallet can say what it is; else by the invoice's final delta
/// alone, which only a payment to a direct peer meets.
library;

import 'btc_lightning.dart';

BigInt _big(Object? v) => v is BigInt ? v : (BigInt.tryParse('${v ?? 0}') ?? BigInt.zero);
BigInt _ceilDiv(BigInt a, BigInt b) => (a + b - BigInt.one) ~/ b;

/// A Bitcoin block at half its pace (the clocks meet only in wall time), the blocks a payment's
/// lock may run past its route, and the hour the receiver keeps to claim after the latest moment
/// the preimage can come out.
const int kBitcoinBlockSeconds = 1200;
const int kExtraBlocks = 6;
const int kReactionSeconds = 3600;

/// A Bitcoin invoice the wallet pays must have at least this long to run.
const int kInvoiceLeftSeconds = 600;

/// A step whose outcome is unknown is looked for this long before the trade is called failed.
const int kUncertainMs = 10 * 60 * 1000;

/// The seconds of median time the leaf received under the hash must keep before its home date,
/// for a Bitcoin payment whose whole lock is `blocks`.
int needSeconds(int? blocks) => ((blocks ?? 18) + kExtraBlocks) * kBitcoinBlockSeconds + kReactionSeconds;

/// One BTC candidate's priced terms (what [BtcTrades.firm] answers).
class BtcTerms {
  BtcTerms({
    required this.dir,
    required this.receive,
    required this.give,
    required this.fees,
    required this.offer,
    this.invoice,
    this.quote,
    this.decoded,
    this.receiveQuote,
    this.settle,
    this.routeFee,
    this.routeDelay,
    this.rail,
  });
  final String dir; // 'sell' | 'buy'
  final BigInt receive, give;
  final List<Map<String, dynamic>> fees;
  final Map<String, dynamic> offer;
  final Map<String, dynamic>? invoice, quote, decoded, receiveQuote, settle;
  final BigInt? routeFee;
  final int? routeDelay;

  /// The wallet's BTC rail the terms were priced on (`ark`, `lightning`, or null when the app
  /// names none): the trade is finished on it, whatever the wallet uses for new trades by then.
  final String? rail;
}

class BtcTrades {
  BtcTrades({
    required this.run,
    required this.btc,
    required this.fetchJson,
    required this.put,
    required this.log,
    required this.now,
    required this.settleStep,
    required this.maxFeePpm,
    required this.firmMarginMs,
    this.railNow,
    this.railOf,
  });

  final Future<dynamic> Function(String command, [Map<String, dynamic> args]) run;

  /// Read at each use: the app learns whether its Bitcoin Lightning is there after it starts.
  final BtcLightning? Function() btc;
  final Future<Map<String, dynamic>> Function(String url, {Map<String, dynamic>? post}) fetchJson;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> rec) put;
  final void Function(String) log;
  final int Function() now;
  final Future<bool> Function(Map<String, dynamic> rec) settleStep;
  final int maxFeePpm, firmMarginMs;

  /// The rail [btc] answers for now, and the wallet's Bitcoin Lightning on a named rail (null while
  /// that rail is not there): a trade records the rail it was priced on and is followed on it.
  final String? Function()? railNow;
  final BtcLightning? Function(String rail)? railOf;

  /// The Bitcoin Lightning a trade's record is followed on: its own rail when it names one.
  BtcLightning? _forRec(Map<String, dynamic> rec) {
    final r = rec['btcRail'];
    if (r is String && railOf != null) return railOf!(r);
    return btc();
  }

  BtcLightning? _forTerms(BtcTerms t) => t.rail != null && railOf != null ? railOf!(t.rail!) : btc();

  void release(String? maker, String? swap) {
    if (maker == null || swap == null) return;
    fetchJson('$maker/v1/btc/release', post: {'swap': swap}).catchError((_) => <String, dynamic>{});
  }

  /// Before a smaller offer is asked for, the larger one is let go of and the maker has answered:
  /// it holds what an offer gives until the offer is released.
  Future<void> _releaseNow(String? maker, String? swap) async {
    if (maker == null || swap == null) return;
    try {
      await fetchJson('$maker/v1/btc/release', post: {'swap': swap});
    } catch (_) {}
  }

  void _cancel(BtcLightning? b, String? hash) {
    if (hash == null || b == null) return;
    b.cancelInvoice(hash).catchError((_) {});
  }

  /// Firm terms of one entry for `pay` of the pay asset: the entry's maker, rate and minimum, and
  /// the first size to ask for (`first`, what the entry gives at its price).
  Future<BtcTerms?> firm({
    required String? maker,
    required BigInt rateNum,
    required BigInt rateDen,
    required BigInt minReceive,
    required String payAsset,
    required String receiveAsset,
    required BigInt pay,
    required BigInt have,
    required BigInt first,
  }) async {
    // The rail and its wallet read once: every step of these terms is on the same one.
    final rail = railNow?.call();
    final b = btc();
    if (b == null) return null;
    final limit = pay < have ? pay : have;
    if (receiveAsset == 'BTC') {
      // Selling an asset for BTC: the wallet's invoice first, so the maker's receive is under the
      // wallet's hash.
      var sats = first;
      for (var i = 0; i < 4; i++) {
        Map<String, dynamic> inv, o, q;
        try {
          inv = await b.invoice(sats: sats, description: 'trade');
        } catch (e) {
          log('[user trade] btc invoice: $e');
          return null;
        }
        try {
          o = await fetchJson('$maker/v1/btc/firm', post: {'give_asset': 'BTC', 'want_asset': payAsset, 'give': '$sats', 'invoice': inv['invoice']});
        } catch (e) {
          log('[user trade] maker btc firm: $e');
          _cancel(b, '${inv['payment_hash']}');
          return null;
        }
        void drop() {
          release(maker, '${o['swap']}');
          _cancel(b, '${inv['payment_hash']}');
        }

        try {
          q = Map<String, dynamic>.from((await run('lightning_pay_quote', {'invoice': o['invoice'], 'asset': payAsset, 'max_fee_ppm': maxFeePpm})) as Map);
        } catch (e) {
          log('[user trade] lightning_pay_quote: $e');
          drop();
          return null;
        }
        // The maker's invoice is under the wallet's own hash, for the asset paid, at the price quoted.
        final fair = _ceilDiv(sats * rateNum, rateDen);
        if (q['payment_hash'] != inv['payment_hash'] || q['asset'] != payAsset || _big(q['amount']) != _big(o['want']) || _big(o['want']) > fair) {
          log('[user trade] the maker\'s btc terms are not the quote\'s');
          drop();
          return null;
        }
        final spends = _big(q['spends']);
        if (spends > limit) {
          _cancel(b, '${inv['payment_hash']}');
          await _releaseNow(maker, '${o['swap']}');
          sats = sats - ((spends - limit) * rateDen + rateNum - BigInt.one) ~/ rateNum - BigInt.one;
          if (sats < minReceive) return null;
          continue;
        }
        return BtcTerms(
          dir: 'sell',
          receive: sats,
          give: spends,
          fees: [
            {'asset': payAsset, 'atoms': spends - _big(q['amount'])},
          ],
          offer: o,
          invoice: inv,
          quote: q,
          rail: rail,
        );
      }
      return null;
    }
    // Buying an asset with BTC: the maker's invoice, and what the wallet's leaf would hold.
    var give = first;
    for (var i = 0; i < 4; i++) {
      Map<String, dynamic> o, d, rq, sq;
      try {
        o = await fetchJson('$maker/v1/btc/firm', post: {'give_asset': receiveAsset, 'want_asset': 'BTC', 'give': '$give'});
      } catch (e) {
        log('[user trade] maker btc firm: $e');
        return null;
      }
      try {
        d = await b.decode('${o['invoice']}');
      } catch (e) {
        log('[user trade] btc decode: $e');
        release(maker, '${o['swap']}');
        return null;
      }
      final fair = _ceilDiv(give * rateNum, rateDen);
      if (_big(d['sats']) != _big(o['want']) ||
          _big(d['sats']) > fair ||
          (d['expires_at'] as num) * 1000 - now() < (kInvoiceLeftSeconds + 1800) * 1000) {
        log('[user trade] the maker\'s btc invoice is not the quote\'s: ${d['sats']} sat for $give, the quote\'s $fair at most, '
            'its offer ${o['want']}, ${(d['expires_at'] as num) - now() ~/ 1000} s left');
        release(maker, '${o['swap']}');
        return null;
      }
      // The route's fee and whole lock, which the payment is held to (a payment to the maker's
      // node through another takes the hops' deltas as well as the invoice's).
      ({BigInt fee, int delay})? rt;
      try {
        rt = await b.payRoute('${o['invoice']}');
      } catch (_) {
        rt = null;
      }
      final fee = rt?.fee ?? BigInt.zero;
      final routeDelay = rt != null && rt.delay > 0 ? rt.delay : (d['min_final_cltv'] as num? ?? 18).toInt();
      try {
        rq = Map<String, dynamic>.from((await run('lightning_receive_quote', {'asset': receiveAsset, 'amount': '$give', 'max_fee_ppm': maxFeePpm})) as Map);
        // The leaf is settled in the operator's next round, at the fee a fresh coin pays.
        sq = Map<String, dynamic>.from(
          (await run('settle_quote', {'asset': receiveAsset, 'value': rq['claimed'], 'expiry': now() ~/ 1000 + 400 * 86400})) as Map,
        );
      } catch (e) {
        log('[user trade] receive quote: $e');
        release(maker, '${o['swap']}');
        return null;
      }
      final spends = _big(d['sats']) + fee;
      if (spends > limit) {
        await _releaseNow(maker, '${o['swap']}');
        give = give - ((spends - limit) * rateDen + rateNum - BigInt.one) ~/ rateNum - BigInt.one;
        if (give < minReceive) return null;
        continue;
      }
      return BtcTerms(
        dir: 'buy',
        receive: _big(sq['after']),
        give: spends,
        fees: [
          if (fee > BigInt.zero) {'asset': 'BTC', 'atoms': fee},
          {'asset': receiveAsset, 'atoms': _big(rq['fee']) + _big(rq['claim_margins']) + _big(sq['fee'])},
        ],
        offer: o,
        decoded: d,
        receiveQuote: rq,
        settle: sq,
        routeFee: fee,
        routeDelay: routeDelay,
        rail: rail,
      );
    }
    return null;
  }

  /// Lets go of priced terms that are not taken: the maker's offer and the wallet's own invoice.
  void drop(String? maker, BtcTerms t) {
    release(maker, '${t.offer['swap']}');
    if (t.invoice != null) _cancel(_forTerms(t), '${t.invoice!['payment_hash']}');
  }

  /// Takes the one step of a confirmed BTC trade; the record is written before anything is signed.
  Future<Map<String, dynamic>> confirm(String maker, BtcTerms t, Map<String, dynamic> rec) async {
    final o = t.offer;
    final exp = int.tryParse('${o['expires_at'] ?? ''}');
    if (exp != null && exp * 1000 - now() < firmMarginMs) {
      rec['state'] = 'failed';
      rec['error'] = 'the firm offer lapsed before it was confirmed';
      await put(rec);
      release(maker, '${o['swap']}');
      if (t.invoice != null) _cancel(_forTerms(t), '${t.invoice!['payment_hash']}');
      throw const BtcLapsed();
    }
    rec['maker'] = maker;
    if (t.rail != null) rec['btcRail'] = t.rail;
    rec['swap'] = o['swap'];
    rec['dir'] = t.dir;
    rec['before'] = [for (final c in ((await run('coins')) as List? ?? const [])) '${(c as Map)['leaf_id']}'];
    if (t.dir == 'sell') {
      rec['hash'] = t.invoice!['payment_hash'];
      rec['invoiceX'] = o['invoice'];
      rec['sats'] = '${t.receive}';
      rec['spends'] = t.quote!['spends'];
      rec['amount'] = t.quote!['amount'];
      await put(rec);
      final r = (await run('lightning_pay', {'invoice': o['invoice'], 'asset': t.quote!['asset'], 'max_fee_ppm': maxFeePpm, 'shown': t.quote})) as Map;
      rec['change'] = r['change'];
      rec['state'] = 'sent';
      rec['sentAt'] = now();
      await put(rec);
      fetchJson('$maker/v1/btc/paid', post: {'swap': rec['swap']}).catchError((_) => <String, dynamic>{});
      return rec;
    }
    rec['hash'] = t.decoded!['payment_hash'];
    rec['invoiceBtc'] = o['invoice'];
    rec['sats'] = '${t.decoded!['sats']}';
    rec['minFinalCltv'] = t.decoded!['min_final_cltv'];
    rec['routeFee'] = '${t.routeFee}';
    rec['routeDelay'] = t.routeDelay;
    rec['receiveAsset'] = t.receiveQuote!['asset'];
    rec['claimed'] = t.receiveQuote!['claimed'];
    rec['settleTargets'] = [
      {'asset': t.settle!['asset'], 'value': t.settle!['value'], 'fee': t.settle!['fee']},
    ];
    await put(rec);
    final r =
        (await run('lightning_receive', {'asset': rec['receiveAsset'], 'amount': t.receiveQuote!['amount'], 'hash': rec['hash'], 'max_fee_ppm': maxFeePpm}))
            as Map;
    if (r['fee'] != t.receiveQuote!['fee'] || r['value'] != t.receiveQuote!['value']) throw Exception('the receive changed since it was shown');
    rec['invoiceX'] = r['invoice'];
    // Nothing of the wallet's is locked until it pays the BTC, which waits for its leaf. From here
    // the trade is under way whatever the maker answers now: a lock it refused is asked for again
    // as the trade is followed, and a receive it never pays lapses and the trade comes back.
    rec['state'] = 'waiting';
    rec['waitingSince'] = now();
    await put(rec);
    try {
      await fetchJson('$maker/v1/btc/lock', post: {'swap': rec['swap'], 'invoice': r['invoice']});
    } catch (e) {
      log('[user trade] the maker did not lock yet: $e');
    }
    return rec;
  }

  /// A trade whose step did not answer: the lock under its hash, if the library made one.
  Future<Map<String, dynamic>> found(Map<String, dynamic> rec) async {
    final locks = (await run(rec['dir'] == 'sell' ? 'lightning_payments' : 'lightning_receives')) as Map?;
    final mine = locks == null ? null : locks[rec['hash']];
    if (mine != null) {
      rec['state'] = rec['dir'] == 'sell' ? 'sent' : 'waiting';
      rec['sentAt'] = now();
    } else if (!(rec['uncertain'] == true && now() - ((rec['uncertainAt'] as num?)?.toInt() ?? 0) < kUncertainMs)) {
      rec['state'] = 'failed';
      rec['error'] = 'not made';
    }
    return put(rec);
  }

  Future<Map<String, dynamic>> advance(Map<String, dynamic> rec) async {
    try {
      _logSync(await run('sync'));
    } catch (e) {
      log('[user trade] sync: $e');
    }
    // A trade's rail that is not there yet (the ark still opening) is followed on the next pass.
    final b = _forRec(rec);
    if (b == null) return put(rec);
    return rec['dir'] == 'sell' ? _advanceSell(rec, b) : _advanceBuy(rec, b);
  }

  /// Selling: the BTC comes to the wallet's invoice; its payment of the asset is settled with the
  /// preimage, which the wallet hands the operator too.
  Future<Map<String, dynamic>> _advanceSell(Map<String, dynamic> rec, BtcLightning b) async {
    final hash = '${rec['hash']}';
    final p = (((await run('lightning_payments')) as Map?)?[hash] as Map?) ?? const {};
    rec['payState'] = p['state'];
    Map<String, dynamic> inv;
    try {
      inv = await b.invoiceStatus(hash);
    } catch (_) {
      inv = {'status': 'unknown'};
    }
    if (inv['status'] == 'paid') {
      rec['btcPaid'] = true;
      if (p['state'] != 'paid' && inv['preimage'] != null && rec['posted'] != true) {
        try {
          await run('lightning_post_preimage', {'hash': hash, 'preimage': inv['preimage']});
          rec['posted'] = true;
        } catch (e) {
          log('[user trade] post preimage: $e');
        }
      }
      if (p['state'] == 'paid') {
        rec['state'] = 'settled';
        rec['settledAt'] = now();
      }
      return put(rec);
    }
    if (p['state'] == 'returned') {
      // The maker never paid: the payment failed back and its leaf came back, less its margins.
      rec['state'] = 'returned';
      rec['returnedAt'] = now();
      _cancel(b, hash);
      final before = {...((rec['before'] as List?) ?? const []).map((e) => '$e')};
      final pay = (rec['ticket'] as Map)['payAsset'];
      final back =
          ((await run('coins')) as List? ?? const [])
              .cast<Map>()
              .where((c) => c['state'] == 'live' && !before.contains('${c['leaf_id']}') && c['asset'] == pay)
              .fold<BigInt>(BigInt.zero, (n, c) => n + _big(c['value'])) -
          _big(rec['change']);
      final lost = _big(rec['spends']) - back;
      if (lost > BigInt.zero) {
        rec['feesPaid'] = [
          {'asset': pay, 'atoms': '$lost'},
        ];
      }
      return put(rec);
    }
    return put(rec);
  }

  /// Buying: wait for the leaf, then pay the BTC, then claim and settle the leaf.
  Future<Map<String, dynamic>> _advanceBuy(Map<String, dynamic> rec, BtcLightning b) async {
    final hash = '${rec['hash']}';
    final lock = (rec['routeDelay'] as num?)?.toInt() ?? (rec['minFinalCltv'] as num?)?.toInt() ?? 18;
    final rcv = (((await run('lightning_receives')) as Map?)?[hash] as Map?) ?? const {};
    rec['receiveState'] = rcv['state'];
    if (rec['state'] == 'waiting') {
      if (rcv['state'] == 'failed') {
        rec['state'] = 'returned';
        rec['returnedAt'] = now();
        return put(rec);
      }
      // The maker's lock, asked for again in case it missed it.
      if (rcv['state'] == 'waiting') {
        fetchJson('${rec['maker']}/v1/btc/lock', post: {'swap': rec['swap'], 'invoice': rec['invoiceX']}).catchError((_) => <String, dynamic>{});
      }
      Map r;
      try {
        r = (await run('lightning_receive_ready', {'hash': hash, 'need_seconds': needSeconds(lock)})) as Map;
      } catch (e) {
        log('[user trade] the leaf will not do: $e');
        rec['state'] = 'returned';
        rec['returnedAt'] = now();
        rec['why'] = '$e';
        return put(rec);
      }
      if (r['ready'] != true) {
        if (r['why'] != rec['readyWhy']) log('[user trade] not yet: ${r['why']}');
        rec['readyWhy'] = r['why'];
        return put(rec);
      }
      rec['state'] = 'sent';
      rec['sentAt'] = now();
      rec['paying'] = true;
      await put(rec);
    }
    if (rec['state'] == 'sent' && rec['preimage'] == null) {
      Map<String, dynamic> st;
      try {
        st = await b.payStatus(hash);
      } catch (_) {
        st = {'state': 'none'};
      }
      // The asset is final only after Bitcoin blocks, which can outlast the maker's invoice: one
      // that runs out soon is renewed by the maker under the same hash, for the same amount, on no
      // longer a lock or a higher fee, or the trade comes back with nothing paid. An invoice that
      // ran out is never paid.
      if (st['state'] == 'none' && !await _freshInvoice(rec, b, lock)) {
        release('${rec['maker']}', '${rec['swap']}');
        rec['state'] = 'returned';
        rec['returnedAt'] = now();
        rec['why'] = 'the maker\'s invoice ran out while the trade waited';
        rec['whyKind'] = 'lapsed';
        return put(rec);
      }
      if (st['state'] == 'none') {
        st = await b.pay(invoice: '${rec['invoiceBtc']}', maxFeeSats: _big(rec['routeFee']), maxDelay: lock + kExtraBlocks);
      }
      if (st['state'] == 'failed') {
        // Nothing was paid: the leaf stays unclaimed and goes back to the maker.
        rec['state'] = 'returned';
        rec['returnedAt'] = now();
        rec['why'] = st['reason'] ?? 'the payment failed';
        return put(rec);
      }
      if (st['state'] != 'complete') return put(rec);
      rec['preimage'] = st['preimage'];
      await put(rec);
      await run('lightning_receive_preimage', {'hash': hash, 'preimage': st['preimage']});
      try {
        await run('sync');
      } catch (e) {
        log('[user trade] sync: $e');
      }
    }
    if (rec['preimage'] != null) {
      final r2 = (((await run('lightning_receives')) as Map?)?[hash] as Map?) ?? const {};
      rec['receiveState'] = r2['state'];
      if (r2['state'] != 'received') return put(rec);
      // The coin the claim made is the one settled, named by its id: its value is the quote's only
      // while the operator's fee rates hold, and a coin looked for by a value it no longer has is
      // never found.
      final targets = (rec['settleTargets'] as List?) ?? const [];
      if (r2['leaf'] != null && targets.length == 1 && (targets[0] as Map)['leaf_id'] == null) {
        rec['settleTargets'] = [
          {...(targets[0] as Map), 'leaf_id': r2['leaf']},
        ];
        await put(rec);
      }
      // The claimed coin is settled in the next round, at no more than the ticket's fee.
      if (await settleStep(rec)) {
        rec['state'] = 'settled';
        rec['settledAt'] = now();
      }
    }
    return put(rec);
  }
}

extension on BtcTrades {
  /// What a sync said of the trade's steps that did not go: a participation or Lightning step's
  /// error or refusal, or a witness that did not succeed (then the wallet moves nothing on).
  void _logSync(Object? v) {
    if (v is! Map) return;
    for (final k in ['participations', 'lightning']) {
      final x = v[k];
      if (x is Map && x['error'] != null) log('[user trade] sync $k: ${x['error']}');
      if (x is Map && x['note'] != null) log('[user trade] sync $k: ${x['note']}');
      if (x is List) {
        for (final s in x) {
          if (s is Map && (s['error'] != null || s['refused'] != null)) log('[user trade] sync $k: $s');
        }
      }
    }
  }

  /// The maker's invoice for a purchase, renewed when it runs out within [kInvoiceLeftSeconds]:
  /// the same hash and amount, a final delta, fee and lock no greater than the trade allowed.
  /// True when it can be paid now; false when it cannot (the maker gives no new one, or not one
  /// like it). The web wallet's freshInvoice().
  Future<bool> _freshInvoice(Map<String, dynamic> rec, BtcLightning b, int lock) async {
    double left(Map d) => (d['expires_at'] as num).toDouble() - now() / 1000;
    Map<String, dynamic> cur;
    try {
      cur = await b.decode('${rec['invoiceBtc']}');
    } catch (_) {
      return false;
    }
    if (left(cur) >= kInvoiceLeftSeconds) return true;
    Map<String, dynamic> o;
    try {
      o = await fetchJson('${rec['maker']}/v1/btc/invoice', post: {'swap': rec['swap']});
    } catch (e) {
      log('[user trade] the maker gave no new invoice: $e');
      return false;
    }
    Map<String, dynamic> n;
    try {
      n = await b.decode('${o['invoice']}');
    } catch (_) {
      return false;
    }
    final cltv = (rec['minFinalCltv'] as num?)?.toInt() ?? 18;
    if (n['payment_hash'] != rec['hash'] ||
        _big(n['sats']) != _big(rec['sats']) ||
        left(n) < kInvoiceLeftSeconds ||
        ((n['min_final_cltv'] as num?)?.toInt() ?? 18) > cltv) {
      log('[user trade] the maker\'s new invoice is not the trade\'s');
      return false;
    }
    ({BigInt fee, int delay})? rt;
    try {
      rt = await b.payRoute('${o['invoice']}');
    } catch (_) {
      rt = null;
    }
    if (rt != null && (rt.fee > _big(rec['routeFee']) || rt.delay > lock)) {
      log('[user trade] the new invoice\'s route costs more than the trade allowed');
      return false;
    }
    rec['invoiceBtc'] = o['invoice'];
    await put(rec);
    log('[user trade] the maker renewed its invoice for ${rec['swap']}');
    return true;
  }
}

class BtcLapsed implements Exception {
  const BtcLapsed();
  @override
  String toString() => 'the price is no longer held';
}
