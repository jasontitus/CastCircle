import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/production_providers.dart';
import '../models/production_models.dart';
import '../models/script_models.dart';
import '../models/voice_preset.dart';
import 'debug_log_service.dart';
import 'script_import_service.dart';
import 'voice_config_service.dart';

/// The bundled demo production: two scenes of Hamlet, cast in British voices.
///
/// It exists so a new user can see the rehearsal loop before they own a
/// script — importing a PDF is the single biggest thing standing between
/// installing the app and understanding it.
///
/// Deliberately LOCAL-ONLY: no organizer id, no join code, nothing written to
/// Supabase. A demo that created cloud rows would put a fake production in
/// every tester's account and hand out an invite code to a play nobody is
/// staging.
class DemoProductionService {
  DemoProductionService._();
  static final instance = DemoProductionService._();

  /// Fixed id, so the demo is recognisable anywhere (badges, "already
  /// loaded?" checks) without a schema change, and loading it twice reopens
  /// the same production instead of piling up duplicates.
  static const productionId = 'demo-hamlet-castcircle';

  static const _assetPath = 'assets/demo/hamlet_demo.txt';

  /// Title carries the label, so it reads as a demo in the production list,
  /// in the rehearsal header, and anywhere else a title is shown.
  static const title = 'Hamlet (Demo)';

  /// British RP voices at a measured pace — see [VoicePresets.shakespearean].
  static const _presetId = 'shakespearean';

  /// The part the demo opens on. Landing in the hub with nothing selected
  /// means the first thing a new user meets is a dropdown, not a rehearsal.
  static const _defaultCharacter = 'HAMLET';

  /// BCP-47 locale. This drives the TTS voice pool, not speech recognition:
  /// STT follows the device's own locale, because forcing a dialect the
  /// speaker doesn't have wrecks matching.
  static const _locale = 'en-GB';

  static bool isDemo(Production? production) =>
      production != null && production.id == productionId;

  /// Create the demo production (or reopen it if it's already there) and make
  /// it the current production with its script loaded.
  ///
  /// Returns the production, or throws if the bundled script can't be parsed —
  /// a demo that quietly opens empty is worse than an error the user can
  /// report.
  Future<Production> load(WidgetRef ref) async {
    final existing = ref
        .read(productionsProvider)
        .where((p) => p.id == productionId)
        .firstOrNull;

    final production =
        existing ??
        Production(
          id: productionId,
          title: title,
          organizerId: 'local',
          createdAt: DateTime.now(),
          status: ProductionStatus.scriptImported,
          locale: _locale,
        );

    final script = await _parseBundledScript();

    if (existing == null) {
      await ref.read(productionsProvider.notifier).add(production);
    }
    ref.read(currentProductionProvider.notifier).state = production;
    ref.read(currentScriptProvider.notifier).state = script;

    // Local only — persistScript() would also try the cloud.
    await persistScriptLocally(ref, production.id, script);
    await VoiceConfigService.instance.setPreset(production.id, _presetId);
    await _preselectCharacter(ref, script);

    DebugLogService.instance.log(
      LogCategory.general,
      'Demo production ${existing == null ? 'created' : 'reopened'}: '
      '${script.lines.length} lines, ${script.characters.length} characters',
    );
    return production;
  }

  /// Put the user in a part, unless they've already chosen one here — a
  /// returning demo user may well have picked something else.
  Future<void> _preselectCharacter(WidgetRef ref, ParsedScript script) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'rehearsal_character_$productionId';
    var character = prefs.getString(key);
    if (character == null || character.isEmpty) {
      final match = script.characters
          .where((c) => c.name.toUpperCase() == _defaultCharacter)
          .firstOrNull;
      // Fall back to whoever speaks most, so a re-cut demo script still
      // opens on somebody rather than silently on no one.
      character =
          match?.name ??
          (script.characters.toList()
                ..sort((a, b) => b.lineCount.compareTo(a.lineCount)))
              .first
              .name;
      await prefs.setString(key, character);
    }
    ref.read(rehearsalCharacterProvider.notifier).state = character;
  }

  Future<ParsedScript> _parseBundledScript() async {
    final raw = await rootBundle.loadString(_assetPath);
    final script = await ScriptImportService().importFromText(
      raw,
      title: title,
    );
    if (script.lines.isEmpty || script.characters.isEmpty) {
      throw StateError(
        'The bundled demo script parsed to ${script.lines.length} lines and '
        '${script.characters.length} characters — the asset or the parser is '
        'broken.',
      );
    }
    return script;
  }
}
