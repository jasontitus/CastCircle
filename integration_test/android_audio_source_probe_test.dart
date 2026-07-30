import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Drives the on-device EXTRA_AUDIO_SOURCE feasibility probe.
///   flutter test integration_test/android_audio_source_probe_test.dart -d <id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('EXTRA_AUDIO_SOURCE feasibility', (t) async {
    const ch = MethodChannel('com.lineguide/audio_source_probe');
    final res = await ch.invokeMapMethod<String, dynamic>('probe');
    // ignore: avoid_print
    print('=== ANDROID AUDIO SOURCE PROBE ===');
    res?.forEach((k, v) {
      // ignore: avoid_print
      print('  $k: $v');
    });
    expect(res, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
