// Drives the app into rehearsal cue-practice mode on Hamlet Act I Scene 2,
// then idles long enough for an external screen recorder to capture the
// progression of lines (other characters playing, arriving at HAMLET's cue).
//
// Run via scripts/generate_rehearsal_webp.sh — that script wraps this test
// with `xcrun simctl io recordVideo` to turn the session into an animated
// webp suitable for README embedding.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:castcircle/app.dart';
import 'package:castcircle/data/database/app_database.dart' show AppDatabase;
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/data/services/script_import_service.dart';
import 'package:castcircle/main.dart';
import 'package:castcircle/providers/production_providers.dart';

/// The full Hamlet script, loaded at test runtime from the bundled asset.
const _hamletAssetPath = 'assets/test_scripts/hamlet.txt';

BuildContext _context(WidgetTester tester) =>
    tester.element(find.byType(Navigator).first);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Rehearsal progress demo', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auth_skipped', true);
    await prefs.setBool('screenshot_mode', true);

    final db = AppDatabase();
    final rawHamlet = await rootBundle.loadString(_hamletAssetPath);
    final importer = ScriptImportService();
    final hamlet = await importer.importFromText(rawHamlet, title: 'Hamlet');
    final production = Production(
      id: const Uuid().v4(),
      title: 'Hamlet',
      organizerId: 'local',
      createdAt: DateTime.now(),
      status: ProductionStatus.scriptImported,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          authGatePassedProvider.overrideWith((ref) => true),
        ],
        child: const CastCircleApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Seed production + script.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CastCircleApp)),
    );
    await container.read(productionsProvider.notifier).add(production);
    container.read(currentProductionProvider.notifier).state = production;
    container.read(currentScriptProvider.notifier).state = hamlet;
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Configure rehearsal: HAMLET as actor, cue practice mode, Scene 2.
    container.read(rehearsalCharacterProvider.notifier).state = 'HAMLET';
    container.read(rehearsalModeProvider.notifier).state =
        RehearsalMode.cuePractice;
    if (hamlet.scenes.isNotEmpty) {
      container.read(selectedSceneProvider.notifier).state = hamlet.scenes
          .firstWhere(
            (s) => s.characters.contains('HAMLET'),
            orElse: () => hamlet.scenes.first,
          );
    }

    // Navigate to production hub (so the recording starts on a "real" screen)
    // then push rehearsal after a brief hold.
    _context(tester).go('/production');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Wait for the external recorder to ramp up.
    await Future<void>.delayed(const Duration(seconds: 2));

    _context(tester).push('/rehearsal');
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Hold for 36s of real wall-clock time while the rehearsal plays through.
    // Pump periodically so frames render and TTS callbacks fire.
    final end = DateTime.now().add(const Duration(seconds: 36));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await db.close();
  });
}
