import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/model_manager.dart';

void main() {
  group('ModelManager', () {
    test('is a singleton', () {
      expect(identical(ModelManager.instance, ModelManager.instance), true);
    });

    // Note: Methods that call path_provider (isKokoroReady, getKokoroPaths, etc.)
    // cannot be tested in unit tests — they require platform channels.
    // These are tested via integration tests on-device.
  });
}
