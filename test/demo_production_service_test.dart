import 'package:castcircle/data/database/app_database.dart' show AppDatabase;
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/data/services/demo_production_service.dart';
import 'package:castcircle/data/services/voice_config_service.dart';
import 'package:castcircle/main.dart' show databaseProvider;
import 'package:castcircle/providers/production_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exercises the demo end to end against a real (in-memory) database: the
/// parse, the production row, the British voice preset, and the preselected
/// part. Loading it twice must not leave two demos in the list.
///
/// Every load() goes through [WidgetTester.runAsync]: persisting a script
/// spawns an isolate to encode the JSON backup, and a real isolate never
/// completes inside testWidgets' fake-async zone — the test just hangs until
/// the 10-minute timeout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  /// Pump a throwaway widget purely to obtain a WidgetRef, which is what the
  /// service takes (it writes through the same providers the UI does).
  Future<WidgetRef> refFor(WidgetTester tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    return captured;
  }

  testWidgets('creates a British-voiced demo production with a part chosen', (
    tester,
  ) async {
    final ref = await refFor(tester);

    final production = (await tester.runAsync(
      () => DemoProductionService.instance.load(ref),
    ))!;

    expect(production.id, DemoProductionService.productionId);
    expect(production.title, contains('Demo'));
    expect(production.locale, 'en-GB');
    // Local-only: a demo must not masquerade as a cloud production.
    expect(production.organizerId, 'local');
    expect(production.joinCode, isNull);
    expect(production.status, ProductionStatus.scriptImported);

    final script = ref.read(currentScriptProvider);
    expect(script, isNotNull);
    expect(script!.lines, isNotEmpty);
    expect(script.scenes.length, greaterThanOrEqualTo(2));

    // Landing in the hub with no part selected is the thing this avoids.
    expect(ref.read(rehearsalCharacterProvider), isNotNull);
    expect(ref.read(rehearsalCharacterProvider), 'HAMLET');

    final preset = await VoiceConfigService.instance.getPreset(
      production.id,
      locale: production.locale,
    );
    expect(preset.id, 'shakespearean');
    expect(
      preset.maleVoices.every((v) => v.startsWith('bm_')),
      isTrue,
      reason: 'the demo is meant to sound British',
    );
    expect(preset.femaleVoices.every((v) => v.startsWith('bf_')), isTrue);
  });

  testWidgets('loading twice reopens the same production', (tester) async {
    final ref = await refFor(tester);

    await tester.runAsync(() => DemoProductionService.instance.load(ref));
    await tester.runAsync(() => DemoProductionService.instance.load(ref));

    final demos = ref
        .read(productionsProvider)
        .where((p) => p.id == DemoProductionService.productionId)
        .length;
    expect(demos, 1);
  });

  testWidgets('keeps a part the user chose themselves', (tester) async {
    SharedPreferences.setMockInitialValues({
      'rehearsal_character_${DemoProductionService.productionId}': 'OPHELIA',
    });
    final ref = await refFor(tester);

    await tester.runAsync(() => DemoProductionService.instance.load(ref));

    expect(ref.read(rehearsalCharacterProvider), 'OPHELIA');
  });

  test('isDemo only matches the demo production', () {
    final demo = Production(
      id: DemoProductionService.productionId,
      title: 'Hamlet (Demo)',
      organizerId: 'local',
      createdAt: DateTime(2026),
      status: ProductionStatus.scriptImported,
    );
    final real = Production(
      id: 'some-other-id',
      title: 'Hamlet (Demo)', // same title, still not the demo
      organizerId: 'local',
      createdAt: DateTime(2026),
      status: ProductionStatus.scriptImported,
    );
    expect(DemoProductionService.isDemo(demo), isTrue);
    expect(DemoProductionService.isDemo(real), isFalse);
    expect(DemoProductionService.isDemo(null), isFalse);
  });
}
