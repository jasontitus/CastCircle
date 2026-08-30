import 'package:castcircle/data/services/debug_log_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'support log redacts credentials, private metadata, and raw URI queries',
    () {
      const joinCode = 'Q7W9ER';
      const actor = 'Distinctive Actor';
      const title = 'Private Production';
      const dialogue = 'Licensed dialogue words';
      const email = 'actor@example.com';
      const path = '/Users/person/Documents/private-script.pdf';
      const uri =
          'castcircle://join?code=Q7W9ER&char=SecretRole&name=Distinctive%20Actor';

      final safe = DebugLogService.redactForSupportLog(
        'join_code=$joinCode actor_name="$actor" production_title="$title" '
        'script_text="$dialogue" contact_info=$email path=$path uri=$uri',
      );

      for (final secret in [
        joinCode,
        actor,
        title,
        dialogue,
        email,
        path,
        'SecretRole',
        'Distinctive%20Actor',
      ]) {
        expect(safe, isNot(contains(secret)));
      }
      expect(safe, contains('join_code=[REDACTED]'));
      expect(safe, contains('uri=[REDACTED]'));
    },
  );

  test('historical free-form content formats are scrubbed on load', () {
    const dialogue = 'Distinctive licensed dialogue';
    final entry = LogEntry.fromLine(
      '2026-08-30T12:00:00.000Z [REH] MY LINE: ROLE → \"$dialogue\"',
    );
    final storage = DebugLogService.redactForSupportLog(
      'Storage upload → recordings/production/private-file.m4a (12KB)',
    );

    expect(entry, isNotNull);
    expect(entry!.message, '[CONTENT REDACTED]');
    expect(entry.message, isNot(contains(dialogue)));
    expect(storage, 'Storage object [PATH REDACTED]');
  });
  test(
    'free-form titles, character names, and paths with spaces are scrubbed',
    () {
      const title = 'Private Production Title';
      const character = 'Secret Character Name';
      const oldName = 'Old Character Name';
      const newName = 'New Character Name';
      const dialogue = 'Licensed target dialogue';
      const path = '/Users/person/My Scripts/Private Production/script.pdf';
      final messages = [
        'Join: success — opening production "$title"',
        'Delete refused for "$title" — cloud unavailable',
        'Cloud delete failed for "$title"',
        'Join: joining production production-id as "$character" user=user-id',
        'Voice config rename "$oldName" → "$newName" failed',
        'Import failed at $path after parsing',
        'RecordingSync: uploaded line-id ($character)',
        'RecordingSync: downloaded line-id ($character)',
        'RecordingSync: realtime — new recording for line-id ($character)',
        'Restored 1 production(s) from the cloud ($title)',
        'Highlight p2: matched among 14 OCR lines for "$dialogue"',
        'RPC success: $title',
        'RPC cast success: $title',
        'Renamed cast member member-id → "$character"',
        'Join: self-joined "$character" as organizer',
        'Storage download ← recordings/production-id/$character/take.m4a',
        '_submitProduction: background cloud create failed — invites for '
            '"$title" will not work until this heals',
        'SyncQueue: queued upload line=line-id char="$character" duration=12ms',
      ];

      for (final message in messages) {
        final safe = DebugLogService.redactForSupportLog(message);
        for (final secret in [
          title,
          character,
          oldName,
          newName,
          path,
          dialogue,
        ]) {
          expect(safe, isNot(contains(secret)));
        }
      }
    },
  );

  test('support log keeps useful opaque status and counts', () {
    final safe = DebugLogService.redactForSupportLog(
      'cast sync failed productionId=7c9d rows=12 type=timeout',
    );

    expect(safe, 'cast sync failed productionId=7c9d rows=12 type=timeout');
  });
}
