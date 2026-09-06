import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:castcircle/data/services/script_import_service.dart';

/// Repo root for fixture/model staging paths. Relative default works when
/// tests run from the checkout root; override with
/// --dart-define=CASTCIRCLE_REPO=/path for other harnesses.
const _ccRepo = String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');

/// Dump the FULL parsed result of the real on-device import pipeline for the
/// P&P scan, so parser attribution can be analyzed and iterated offline.
///
/// Run:
///   flutter drive --profile --driver=test_driver/integration_test.dart \
///     --target=integration_test/ocr_dump_macos_test.dart -d macos
///
/// Writes pp_dump.json (parsed lines) and pp_raw.txt (raw OCR text) into the
/// app container temp dir and prints their paths.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'dump P&P import for parser analysis',
    (t) async {
      const src = '$_ccRepo/sample-scripts/Pride-Prejudice-SCRIPT.pdf';
      final tmp = await getTemporaryDirectory();
      await tmp.create(recursive: true);
      final pdf = p.join(tmp.path, 'pp_full.pdf');
      await File(pdf).writeAsBytes(await File(src).readAsBytes());

      final parsed = await ScriptImportService().importFromPdf(pdf);

      final dump = {
        'title': parsed.title,
        'characters': [
          for (final c in parsed.characters)
            {'name': c.name, 'lineCount': c.lineCount},
        ],
        'lines': [
          for (final l in parsed.lines)
            {
              'type': l.lineType.name,
              'character': l.character,
              'multi': l.multiCharacters,
              'text': l.text,
              'page': l.sourcePage,
              'conf': l.ocrConfidence,
            },
        ],
      };
      final dumpPath = p.join(tmp.path, 'pp_dump.json');
      await File(dumpPath).writeAsString(jsonEncode(dump));
      final rawPath = p.join(tmp.path, 'pp_raw.txt');
      await File(rawPath).writeAsString(parsed.rawText);

      // ignore: avoid_print
      print('PP_DUMP_JSON=$dumpPath');
      // ignore: avoid_print
      print('PP_RAW_TXT=$rawPath');
      expect(parsed.lines, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
