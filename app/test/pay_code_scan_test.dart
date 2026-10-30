// The receive code read back by the scanner's own decoder (ZXing) from a picture of it: the
// smallest picture, in pixels across, from which each code still reads, before and after.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ambra/src/data/pay_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:zxing2/qrcode.dart';

/// [q] drawn [px] pixels across (a 4-module quiet zone), sampled the way a camera's sensor
/// would at that resolution, with a little blur and sensor noise; then read.
String? readAt(QrCode q, int px, {int seed = 1}) {
  final img = QrImage(q);
  final n = q.moduleCount + 8;
  final rnd = math.Random(seed);
  final lum = List<double>.filled(px * px, 0);
  for (var y = 0; y < px; y++) {
    for (var x = 0; x < px; x++) {
      // Average 3x3 sub-samples over the pixel: the pixel's footprint on the code.
      var dark = 0.0;
      for (var sy = 0; sy < 3; sy++) {
        for (var sx = 0; sx < 3; sx++) {
          final mx = ((x + (sx + 0.5) / 3) * n / px).floor() - 4, my = ((y + (sy + 0.5) / 3) * n / px).floor() - 4;
          if (mx >= 0 && my >= 0 && mx < q.moduleCount && my < q.moduleCount && img.isDark(my, mx)) dark += 1 / 9;
        }
      }
      lum[y * px + x] = 230 - 200 * dark + (rnd.nextDouble() - 0.5) * 30;
    }
  }
  final pixels = Int32List(px * px);
  for (var i = 0; i < px * px; i++) {
    final l = lum[i].round().clamp(0, 255);
    pixels[i] = 0xff000000 | (l << 16) | (l << 8) | l;
  }
  try {
    return QRCodeReader()
        .decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(px, px, pixels))), hints: DecodeHints()..put(DecodeHintType.tryHarder))
        .text;
  } on ReaderException {
    return null;
  }
}

int smallestReadable(QrCode q, String text) {
  for (var px = 60; px <= 600; px += 10) {
    if (readAt(q, px) == text && readAt(q, px, seed: 2) == text) return px;
  }
  return -1;
}

void main() {
  final v = jsonDecode(File('test/pay_code_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final c = (v['cases'] as List).first as Map<String, dynamic>;
  final code = PayCode(address: v['address'] as String, ark: v['ark'] as String, sequentia: c['library'] as String).build();
  final old = 'bitcoin:${v['address']}?ark=${v['ark']}&sequentia=${c['library']}';

  test('the scanner reads the new code from a far smaller picture than the old one', () {
    final q = payCodeQr(code);
    final before = QrCode.fromData(data: old, errorCorrectLevel: QrErrorCorrectLevel.L);
    final sw = Stopwatch()..start();
    expect(readAt(q, 400), code);
    final ms = sw.elapsedMilliseconds;
    final nNew = smallestReadable(q, code), nOld = smallestReadable(before, old);
    // ignore: avoid_print
    print('smallest readable picture: before v${before.typeNumber} ${nOld}px, after v${q.typeNumber} ${nNew}px; '
        'one decode at 400px ${ms}ms');
    expect(nNew, greaterThan(0));
    expect(nOld < 0 || nNew * 1.4 < nOld, isTrue);
    // A scanned code is read back whole, every part in place.
    final r = PayCode.read(readAt(q, 400)!)!;
    expect(r.sequentia, c['short']);
  });
}
