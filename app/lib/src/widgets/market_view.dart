import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/format.dart';
import '../data/market_view.dart';
import '../theme/theme.dart';

/// The chosen pair's market, above "You pay" in default mode's Swap tab (docs/DEFAULT_MODE.md
/// "Market"; the data and words are `data/market_view.dart`). It reads the relay again every five
/// seconds while it is on screen. A buy is green and a sale amber, in the chart and the trades.
class MarketView extends StatefulWidget {
  const MarketView({
    super.key,
    required this.base,
    required this.quote,
    required this.ticker,
    required this.precision,
    required this.relay,
    this.get,
    this.everyMs = 5000,
  });
  final String base, quote;
  final String Function(String hex) ticker;
  final int Function(String hex) precision;
  final String Function() relay;

  /// How the relay is read (tests pass their own); [relayGet] at [relay] when null.
  final MarketGet? get;
  final int everyMs;

  @override
  State<MarketView> createState() => _MarketViewState();
}

class _MarketViewState extends State<MarketView> {
  String _range = kMarketRanges.first.key;
  MarketPicture? _pic;
  String? _pair;
  Timer? _timer;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loop());
  }

  @override
  void didUpdateWidget(MarketView old) {
    super.didUpdateWidget(old);
    if (old.base != widget.base || old.quote != widget.quote) {
      _pic = null;
      _paint();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _loop() {
    _timer?.cancel();
    if (!mounted) return;
    // Only while the tab is the one shown: a hidden tab's view does not read the relay.
    if (TickerMode.valuesOf(context).enabled) _paint();
    _timer = Timer(Duration(milliseconds: widget.everyMs), _loop);
  }

  Future<void> _paint() async {
    final base = widget.base, quote = widget.quote;
    if (base == quote) return;
    final mine = ++_req;
    final m = await readMarket(widget.get ?? relayGet(widget.relay()), base, quote, marketRange(_range));
    if (!mounted || mine != _req) return;
    final bp = widget.precision(base), qp = widget.precision(quote);
    setState(() {
      _pair = '$base/$quote';
      _pic = pictureOf(m,
          base: base,
          quote: quote,
          baseTicker: widget.ticker(base),
          quoteTicker: widget.ticker(quote),
          bp: bp,
          qp: qp,
          nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _pic;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bt = widget.ticker(widget.base), qt = widget.ticker(widget.quote);
    final day = p?.day;
    final head = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$bt / $qt', key: const ValueKey('mvPair'), style: AmbraText.title),
          if (day?.last != null)
            Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 6, children: [
              Text(fmtPrice(day!.last), key: const ValueKey('mvLast'), style: AmbraText.mono.copyWith(fontSize: 18, color: AmbraColors.txt)),
              Text(qt, style: AmbraText.sub),
              if (day.inDay) ...[
                Text('${day.changePct >= 0 ? '+' : ''}${day.changePct.toStringAsFixed(2)}%',
                    key: const ValueKey('mvChange'), style: AmbraText.mono.copyWith(color: day.changePct >= 0 ? AmbraColors.green : AmbraColors.amber)),
                const Text(MarketWords.change24, style: AmbraText.sub),
              ],
            ]),
        ]),
      ),
      for (final r in MarketWords.ranges)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: ChoiceChip(
            key: ValueKey('mvRange-$r'),
            label: Text(r),
            selected: _range == r,
            showCheckmark: false,
            selectedColor: AmbraColors.amber,
            labelStyle: TextStyle(color: _range == r ? AmbraColors.onGold : AmbraColors.txt, fontSize: 12),
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              setState(() => _range = r);
              _paint();
            },
          ),
        ),
    ]);
    final rows = <Widget>[head];
    if (p != null && _pair == '${widget.base}/${widget.quote}') {
      String vol(double atoms) => formatAtoms('${atoms.round()}', p.basePrec);
      if (p.trades.isEmpty) {
        rows.add(const Text(MarketWords.noTrades, key: ValueKey('mvNote'), style: AmbraText.sub));
      } else if (!p.day.inDay) {
        rows.add(Text('${MarketWords.noDay} · ${MarketWords.lastTrade('${fmtPrice(p.day.last)} $qt', agoText(p.day.lastT ?? now, now))}',
            key: const ValueKey('mvNote'), style: AmbraText.sub));
      } else {
        rows.add(Text(
            '${MarketWords.high} ${fmtPrice(p.day.hi)} · ${MarketWords.low} ${fmtPrice(p.day.lo)} · ${MarketWords.volume} ${vol(p.day.vol)} $bt',
            key: const ValueKey('mvDay'),
            style: AmbraText.sub));
      }
      if (p.series.pts.isNotEmpty) {
        rows.add(const SizedBox(height: 8));
        rows.add(SizedBox(
          key: const ValueKey('mvChart'),
          height: 140,
          child: CustomPaint(
            painter: _StepChartPainter(p.series.pts, p.series.start, now, [
              for (final t in p.trades)
                if (t.ts >= p.series.start) (t: t.ts, p: t.p, buy: t.side != 'sell'),
            ]),
            size: Size.infinite,
          ),
        ));
        if (p.series.inRange == 0) rows.add(const Text(MarketWords.noRange, style: AmbraText.sub));
      }
      rows.add(const SizedBox(height: 8));
      if (p.book.bid != null || p.book.ask != null) {
        final b = p.buyersPct;
        rows.add(Row(children: [
          Expanded(
              child: Text.rich(TextSpan(children: [
            const TextSpan(text: '${MarketWords.bid} ', style: AmbraText.sub),
            TextSpan(text: fmtPrice(p.book.bid), style: AmbraText.mono.copyWith(color: AmbraColors.green)),
          ]), key: const ValueKey('mvBid'))),
          Text.rich(TextSpan(children: [
            const TextSpan(text: '${MarketWords.ask} ', style: AmbraText.sub),
            TextSpan(text: fmtPrice(p.book.ask), style: AmbraText.mono.copyWith(color: AmbraColors.amber)),
          ]), key: const ValueKey('mvAsk')),
        ]));
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Row(children: [
                if (b > 0) Expanded(flex: b, child: Container(color: AmbraColors.green)),
                if (b < 100) Expanded(flex: 100 - b, child: Container(color: AmbraColors.amber)),
              ]),
            ),
          ),
        ));
        rows.add(Row(key: const ValueKey('mvDepth'), children: [
          Expanded(child: Text('${MarketWords.buyers} $b%', style: AmbraText.sub)),
          Text('${MarketWords.sellers} ${100 - b}%', style: AmbraText.sub),
        ]));
      } else {
        rows.add(const Text(MarketWords.noBook, key: ValueKey('mvNoBook'), style: AmbraText.sub));
      }
      if (p.trades.isNotEmpty) {
        rows.add(const SizedBox(height: 10));
        rows.add(const Text(MarketWords.trades, key: ValueKey('mvTrades'), style: AmbraText.label));
        rows.add(Row(children: [
          Expanded(child: Text('${MarketWords.price} ($qt)', style: AmbraText.sub)),
          Expanded(child: Text('${MarketWords.amount} ($bt)', style: AmbraText.sub)),
          const Text(MarketWords.time, style: AmbraText.sub),
        ]));
        for (final t in p.trades.reversed.take(12)) {
          rows.add(Row(children: [
            Expanded(child: Text(fmtPrice(t.p), style: AmbraText.mono.copyWith(color: t.side == 'sell' ? AmbraColors.amber : AmbraColors.green))),
            Expanded(child: Text(vol(t.size), style: AmbraText.mono)),
            Text(agoText(t.ts, now), style: AmbraText.sub),
          ]));
        }
      }
    }
    return Container(
      key: const ValueKey('ucMarket'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AmbraColors.panel, borderRadius: BorderRadius.circular(AmbraRadii.card), border: Border.all(color: AmbraColors.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }
}

/// The price over the range as a step line (a price holds until the next trade), its times along
/// the bottom and its prices on the right; each trade a dot, a buy green and a sale amber.
class _StepChartPainter extends CustomPainter {
  _StepChartPainter(this.pts, this.start, this.end, this.trades);
  final List<({int t, double p})> pts;
  final int start, end;
  final List<({int t, double p, bool buy})> trades;

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.isEmpty) return;
    const right = 64.0, bottom = 16.0;
    final w = size.width - right, h = size.height - bottom;
    var lo = pts.first.p, hi = pts.first.p;
    for (final q in [...pts.map((e) => e.p), ...trades.map((e) => e.p)]) {
      lo = math.min(lo, q);
      hi = math.max(hi, q);
    }
    if (hi == lo) {
      hi = hi * 1.01;
      lo = lo * 0.99;
    }
    final span = math.max(1, end - start);
    double x(int t) => (t - start).clamp(0, span) / span * w;
    double y(double p) => h - (p - lo) / (hi - lo) * (h - 8) - 4;
    final grid = Paint()
      ..color = AmbraColors.line
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, h), Offset(w, h), grid);
    final path = Path()..moveTo(x(pts.first.t), y(pts.first.p));
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(x(pts[i].t), y(pts[i - 1].p));
      path.lineTo(x(pts[i].t), y(pts[i].p));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = AmbraColors.amber2
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6);
    for (final t in trades) {
      canvas.drawCircle(Offset(x(t.t), y(t.p)), 2.6, Paint()..color = t.buy ? AmbraColors.green : AmbraColors.amber);
    }
    void label(String s, Offset at, {bool rightAlign = false}) {
      final tp = TextPainter(text: TextSpan(text: s, style: AmbraText.sub.copyWith(fontSize: 10)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, rightAlign ? at.translate(-tp.width, 0) : at);
    }

    label(fmtPrice(hi), Offset(w + 4, 0));
    label(fmtPrice(lo), Offset(w + 4, h - 12));
    String when(int t) {
      final d = DateTime.fromMillisecondsSinceEpoch(t * 1000);
      String two(int n) => n.toString().padLeft(2, '0');
      return span <= 86400 ? '${two(d.hour)}:${two(d.minute)}' : '${d.day}/${d.month}';
    }

    label(when(start), Offset(0, h + 2));
    label(when(end), Offset(w, h + 2), rightAlign: true);
  }

  @override
  bool shouldRepaint(_StepChartPainter old) => old.pts != pts || old.trades != trades || old.end != end;
}
