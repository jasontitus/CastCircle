import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/features/recording_studio/recording_studio_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ScriptLine jointLine(List<String> actors) => ScriptLine(
    id: actors.join('-'),
    act: 'I',
    scene: '1',
    lineNumber: 1,
    orderIndex: 0,
    character: actors.join(' AND '),
    multiCharacters: actors,
    text: 'Together.',
    lineType: LineType.dialogue,
  );

  test('joint context line is labeled as selected actor context', () {
    final line = jointLine(['MACBETH', 'LENNOX']);

    expect(isSelectedActorContextLine(line, 'MACBETH'), isTrue);
    expect(isSelectedActorContextLine(line, 'LENNOX'), isTrue);
    expect(isSelectedActorContextLine(line, 'DUNCAN'), isFalse);
    expect(isSelectedActorContextLine(line, null), isFalse);
  });

  test('STT adaptation failure does not fail a completed take', () async {
    var attempted = false;

    await expectLater(
      persistSttSampleBestEffort(() async {
        attempted = true;
        throw StateError('injected adaptation failure');
      }),
      completes,
    );

    expect(attempted, isTrue);
  });
}
