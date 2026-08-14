// Integration test that drives the app through its core flows and captures
// screenshots at each step. Used to generate App Store screenshots and
// README imagery from a single deterministic run.
//
// Run with:
//   flutter test integration_test/screenshot_test.dart \
//     -d "iPhone 17 Pro Max"
//
// Screenshots are reported back to the host driver. scripts/generate_screenshots.sh
// collects them into fastlane/screenshots/en-US/.

import 'package:drift/native.dart';
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

/// Path to the bundled Shakespeare Hamlet script used for screenshots.
/// This is the same canonical file from sample-scripts/ that parses cleanly
/// (35 characters, 5 acts, 20 scenes, HAMLET as top character).
const _hamletAssetPath = 'assets/test_scripts/hamlet.txt';

late IntegrationTestWidgetsFlutterBinding _binding;

bool _surfaceConverted = false;

/// Capture a screenshot with the given name after the UI has settled.
Future<void> _snap(WidgetTester tester, String name) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
  // The Flutter surface is converted to an image ONCE per run. Calling this
  // before every screenshot trips `assert(!_isSurfaceRendered)` on Android,
  // which failed the whole run on the second frame.
  if (!_surfaceConverted) {
    await _binding.convertFlutterSurfaceToImage();
    _surfaceConverted = true;
  }
  await tester.pumpAndSettle();
  await _binding.takeScreenshot(name);
}

/// Get the current BuildContext from a live widget in the tree so we can
/// invoke GoRouter navigation.
BuildContext _context(WidgetTester tester) {
  return tester.element(find.byType(Navigator).first);
}

void main() {
  _binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CastCircle app flow screenshots', (tester) async {
    // Skip auth and any onboarding. `screenshot_mode` suppresses the
    // "Download AI Voices" modal and banner in ProductionHubScreen.
    // setMockInitialValues doesn't apply to the real plugin on-simulator,
    // so we set values via the real API instead — which means these are the
    // REAL preferences when this runs on a phone. Remember them and put
    // them back at the end, or a screenshot run silently leaves the owner's
    // app signed out of its auth prompt with onboarding suppressed.
    final prefs = await SharedPreferences.getInstance();
    final prevAuthSkipped = prefs.getBool('auth_skipped');
    final prevScreenshotMode = prefs.getBool('screenshot_mode');
    await prefs.setBool('auth_skipped', true);
    await prefs.setBool('screenshot_mode', true);

    // A REAL in-memory database. `AppDatabase()` opens the on-disk
    // lineguide.sqlite in the app's documents directory, so using it here
    // wrote the seeded Hamlet production into whatever device this ran on.
    final db = AppDatabase.forTesting(NativeDatabase.memory());

    // Parse the full Hamlet script so every screen has realistic content.
    final rawHamlet = await rootBundle.loadString(_hamletAssetPath);
    final importer = ScriptImportService();
    final hamlet = importer.importFromText(rawHamlet, title: 'Hamlet');
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

    // 1. Home — empty state
    await _snap(tester, '01_home_empty');

    // Seed production + script through Riverpod. This skips the file-picker
    // flow which isn't drivable from widget tests.
    final container = ProviderScope.containerOf(
        tester.element(find.byType(CastCircleApp)));
    await container.read(productionsProvider.notifier).add(production);
    container.read(currentProductionProvider.notifier).state = production;
    container.read(currentScriptProvider.notifier).state = hamlet;
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 2. Home — with Hamlet production
    await _snap(tester, '02_home_with_production');

    // 3. Script import screen — shows the parsed preview
    _context(tester).push('/import');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _snap(tester, '03_import_preview');

    // 4. Production hub — character + scene selection.
    // Pre-select HAMLET so the character picker is populated.
    container.read(rehearsalCharacterProvider.notifier).state = 'HAMLET';
    _context(tester).go('/production');
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _snap(tester, '04_production_hub');

    // Pick a scene that contains HAMLET's lines (Scene 2) for the actor
    // shot; the readthrough shot uses Scene 1 which has the ghost setup.
    final sceneWithHamlet = hamlet.scenes.firstWhere(
      (s) => s.characters.contains('HAMLET'),
      orElse: () => hamlet.scenes.first,
    );

    // 5. Rehearsal — readthrough mode (Scene 1: ghost watch)
    container.read(rehearsalModeProvider.notifier).state =
        RehearsalMode.readthrough;
    container.read(rehearsalCharacterProvider.notifier).state = null;
    if (hamlet.scenes.isNotEmpty) {
      container.read(selectedSceneProvider.notifier).state =
          hamlet.scenes.first;
    }
    _context(tester).push('/rehearsal');
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _snap(tester, '05_rehearsal_readthrough');

    // 6. Rehearsal — actor mode as HAMLET (Scene 2: court scene)
    _context(tester).pop();
    await tester.pumpAndSettle();
    container.read(rehearsalModeProvider.notifier).state =
        RehearsalMode.cuePractice;
    container.read(rehearsalCharacterProvider.notifier).state = 'HAMLET';
    container.read(selectedSceneProvider.notifier).state = sceneWithHamlet;
    _context(tester).push('/rehearsal');
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _snap(tester, '06_rehearsal_actor');

    // 7. Settings
    _context(tester).pop();
    await tester.pumpAndSettle();
    _context(tester).push('/settings');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _snap(tester, '07_settings');

    // 8. AI Models
    _context(tester).pop();
    await tester.pumpAndSettle();
    _context(tester).push('/ai-models');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _snap(tester, '08_ai_models');

    // 9. Cast manager
    _context(tester).pop();
    await tester.pumpAndSettle();
    _context(tester).push('/cast');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _snap(tester, '09_cast_manager');

    // Put the device's preferences back the way they were found.
    Future<void> restore(String key, bool? previous) async {
      if (previous == null) {
        await prefs.remove(key);
      } else {
        await prefs.setBool(key, previous);
      }
    }

    await restore('auth_skipped', prevAuthSkipped);
    await restore('screenshot_mode', prevScreenshotMode);
    await db.close();
  });
}
