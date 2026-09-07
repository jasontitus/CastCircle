import 'package:castcircle/features/script_editor/script_editor_screen.dart';
import 'package:castcircle/providers/production_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual script sync messages are truthful for every cloud outcome', () {
    expect(
      scriptPersistOutcomeMessage(ScriptPersistStatus.cloudSynced),
      'Script synced to cloud',
    );
    expect(
      scriptPersistOutcomeMessage(ScriptPersistStatus.cloudFailed),
      'Script saved locally, but cloud sync failed',
    );
    expect(
      scriptPersistOutcomeMessage(ScriptPersistStatus.cloudSkipped),
      'Script saved locally; cloud sync was skipped',
    );
    expect(
      scriptPersistOutcomeMessage(ScriptPersistStatus.nothingToSave),
      'No script available to sync',
    );
    expect(
      scriptPersistOutcomeMessage(ScriptPersistStatus.cloudFailed),
      isNot('Script synced to cloud'),
    );
  });
}
