import 'dart:io';

// The EXTENDED driver is the one with onScreenshot; the plain
// integration_test_driver.dart has no such parameter and silently
// discards screenshot bytes.
import 'package:integration_test/integration_test_driver_extended.dart';

/// Driver that WRITES screenshots to disk.
///
/// The default [integrationDriver] discards the bytes a test reports, which
/// is why a screenshot run can look successful and leave no files. Used by
/// scripts/generate-play-screenshots.sh.
Future<void> main() => integrationDriver(
      onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
        final dir = Directory('build/screenshots-android');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final file = File('${dir.path}/$name.png');
        file.writeAsBytesSync(bytes);
        // ignore: avoid_print
        print('SCREENSHOT ${file.path} (${bytes.length} bytes)');
        return true;
      },
    );
