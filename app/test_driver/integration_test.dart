// The host side of `flutter drive` for the on-device drives: each screenshot a drive takes is
// written to $AMBRA_SHOTS (default /tmp/ambra-shots) as <name>.png.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(onScreenshot: (name, bytes, [args]) async {
      final dir = Platform.environment['AMBRA_SHOTS'] ?? '/tmp/ambra-shots';
      Directory(dir).createSync(recursive: true);
      File('$dir/$name.png').writeAsBytesSync(bytes);
      return true;
    });
