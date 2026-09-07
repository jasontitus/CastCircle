import 'dart:convert';
import 'dart:io';

import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:castcircle/data/services/script_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String combinedHeadingsScript() {
    final text = StringBuffer();
    for (final act in ['I', 'II']) {
      final count = act == 'I' ? 6 : 7;
      for (var scene = 1; scene <= count; scene++) {
        text.writeln('Act $act Scene $scene—Location $scene');
        text.writeln('MEG: We should look for the others.');
        text.writeln('CALVIN: They are waiting outside.');
        text.writeln('CHARLES: Let us go together.');
      }
    }
    return text.toString();
  }

  // The licensed script stays outside source control. Supply per-page
  // Apple PDFKit extraction to exercise the full import pipeline locally.
  const realPagesPath = String.fromEnvironment('WRINKLE_PDFKIT_PAGES');
  test(
    'imports the real Wrinkle PDFKit pages',
    () async {
      final pages = (jsonDecode(File(realPagesPath).readAsStringSync()) as List)
          .cast<String>();
      const channel = MethodChannel('com.lineguide/pdf_text');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {'pages': pages},
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final script = await ScriptImportService().importFromPdf(
        '/unused/wrinkle.pdf',
      );
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      printOnFailure(
        'Wrinkle: ${pages.length} pages, ${script.acts.length} acts, '
        '${script.scenes.length} scenes, ${dialogue.length} dialogue lines, '
        '${script.characters.length} characters',
      );
      expect(script.acts, ['Act I', 'Act II']);
      expect(script.scenes, hasLength(13));
      expect(dialogue.length, greaterThan(500));
      expect(dialogue.first.sourcePage, 6);
      expect(dialogue.last.sourcePage, greaterThanOrEqualTo(53));
    },
    skip: realPagesPath.isEmpty
        ? 'Supply WRINKLE_PDFKIT_PAGES for licensed local PDF'
        : false,
  );

  test(
    'combined act and scene headings retain two acts and thirteen scenes',
    () {
      final script = ScriptParser().parse(combinedHeadingsScript());
      expect(script.acts, ['Act I', 'Act II']);
      expect(script.scenes, hasLength(13));
      expect(script.scenes.where((s) => s.act == 'Act I'), hasLength(6));
      expect(script.scenes.where((s) => s.act == 'Act II'), hasLength(7));
      expect(
        script.lines.where((l) => l.lineType == LineType.dialogue),
        hasLength(39),
      );
    },
  );

  test(
    'full-length combined headings use embedded PDF text without OCR',
    () async {
      const channel = MethodChannel('com.lineguide/pdf_text');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'extractTextPerPage');
        return {
          'pages': [combinedHeadingsScript()],
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final script = await ScriptImportService().importFromPdf(
        '/unused/wrinkle.pdf',
      );
      expect(script.acts, ['Act I', 'Act II']);
      expect(script.scenes, hasLength(13));
      expect(
        script.lines.where((l) => l.lineType == LineType.dialogue),
        hasLength(39),
      );
    },
  );

  test(
    'parses indented Stage Partners colon cues after a scene-list preamble',
    () {
      const text = '''
    Cast of Characters
    MRS. WHICH
    MRS. WHO
    MEG
    CHARLES WALLACE
    CALVIN

    Scenes
    Act I Scene 1—Earth and Thereabouts
    Act I Scene 2—Into the Woods
    COPYRIGHT NOTICE: This front matter is not dialogue.

    Act I Scene 1—Earth and Thereabouts
      (Blackness. Lightning flashes.)
    MRS. WHICH: (Voice over:) It is time.
    MRS. WHO: Time flies by!
    yourstagepartners.com
    MEG: I hate this weather.
    CHARLES WALLACE: Whole house?

    Act I Scene 2—Into the Woods
    CALVIN: I was not hiding.
    https://www.yourstagepartners.com/
    MEG: Then why are you following us?
''';

      final script = ScriptParser().parse(text, title: 'A Wrinkle in Time');
      final names = script.characters
          .map((character) => character.name)
          .toSet();
      final dialogue = script.lines
          .where((line) => line.lineType == LineType.dialogue)
          .toList();

      expect(
        names,
        containsAll(<String>{
          'MRS. WHICH',
          'MRS. WHO',
          'MEG',
          'CHARLES WALLACE',
          'CALVIN',
        }),
      );
      expect(names, isNot(contains('COPYRIGHT NOTICE')));
      expect(dialogue, hasLength(6));
      expect(dialogue.first.character, 'MRS. WHICH');
      expect(script.rawText, isNot(contains('COPYRIGHT NOTICE')));
      expect(
        dialogue.every(
          (line) => !line.text.toLowerCase().contains('yourstagepartners.com'),
        ),
        isTrue,
      );
      expect(
        script.rawText.toLowerCase(),
        isNot(contains('yourstagepartners.com')),
      );
      expect(script.rawText, contains('Act I Scene 1—Earth and Thereabouts'));
    },
  );
}
