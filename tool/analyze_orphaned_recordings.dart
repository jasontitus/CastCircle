// ignore_for_file: avoid_print
//
// Read-only orphan analysis for one explicitly selected local/staging project.
// Use a pre-provisioned least-privilege auditor identity; this command never
// signs up a user or mutates membership.

import 'dart:io';

import 'package:supabase/supabase.dart';

const _productionHost = 'vngpbmqymdaxxnvqptsk.supabase.co';

Future<void> main(List<String> args) async {
  final options = _parseOptions(args);
  final target = Uri.parse(options.url);
  if (target.host == _productionHost && !options.allowProduction) {
    stderr.writeln(
      'Refusing the production project without the explicit '
      '--allow-production acknowledgement.',
    );
    exitCode = 64;
    return;
  }

  final client = SupabaseClient(
    options.url,
    options.key,
    headers: {'Authorization': 'Bearer ${options.accessToken}'},
  );
  final lines =
      (await client
                  .from('script_lines')
                  .select('id, character, order_index')
                  .eq('production_id', options.productionId)
              as List)
          .cast<Map<String, dynamic>>();
  final lineIds = lines.map((line) => line['id'] as String).toSet();
  final recordings =
      (await client
                  .from('recordings')
                  .select(
                    'line_id, user_id, audio_url, duration_ms, recorded_at',
                  )
                  .eq('production_id', options.productionId)
                  .order('recorded_at')
              as List)
          .cast<Map<String, dynamic>>();
  final orphans = recordings
      .where((recording) => !lineIds.contains(recording['line_id']))
      .toList();

  print('script_lines: ${lines.length}');
  print('recordings:   ${recordings.length}');
  print('matched:      ${recordings.length - orphans.length}');
  print('orphaned:     ${orphans.length}');

  for (final recording in orphans) {
    final recordedAt = recording['recorded_at'] as String? ?? '?';
    final userId = recording['user_id'] as String? ?? '?';
    final lineId = recording['line_id'] as String? ?? '?';
    print(
      '  ${_prefix(recordedAt, 16)} user=${_prefix(userId, 8)} '
      'line=${_prefix(lineId, 8)} duration=${recording['duration_ms']}ms',
    );
  }
}

_Options _parseOptions(List<String> args) {
  if (args.contains('--help')) {
    print(_usage);
    exit(0);
  }
  final values = <String, String>{};
  var allowProduction = false;
  for (var index = 0; index < args.length; index++) {
    final argument = args[index];
    if (argument == '--allow-production') {
      allowProduction = true;
      continue;
    }
    if (!const {
      '--url',
      '--key',
      '--access-token',
      '--production-id',
    }.contains(argument)) {
      _usageError('Unknown argument: $argument');
    }
    if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
      _usageError('Missing value for $argument');
    }
    values[argument] = args[++index];
  }
  for (final required in const [
    '--url',
    '--key',
    '--access-token',
    '--production-id',
  ]) {
    if ((values[required] ?? '').isEmpty) {
      _usageError('Missing required argument: $required');
    }
  }
  final target = Uri.tryParse(values['--url']!);
  if (target == null || !target.hasScheme || target.host.isEmpty) {
    _usageError('--url must be an absolute HTTP(S) URL');
  }
  if (!_uuid.hasMatch(values['--production-id']!)) {
    _usageError('--production-id must be a UUID');
  }
  return _Options(
    url: values['--url']!,
    key: values['--key']!,
    accessToken: values['--access-token']!,
    productionId: values['--production-id']!,
    allowProduction: allowProduction,
  );
}

String _prefix(String value, int length) =>
    value.length <= length ? value : value.substring(0, length);

Never _usageError(String message) {
  stderr.writeln('$message\n\n$_usage');
  exit(64);
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

const _usage = '''Usage: dart run tool/analyze_orphaned_recordings.dart
  --url <local-or-staging-supabase-url>
  --key <publishable-key>
  --access-token <pre-provisioned-auditor-jwt>
  --production-id <seeded-production-uuid>
  [--allow-production]

The command is read-only and performs no signup or membership mutation.''';

class _Options {
  const _Options({
    required this.url,
    required this.key,
    required this.accessToken,
    required this.productionId,
    required this.allowProduction,
  });

  final String url;
  final String key;
  final String accessToken;
  final String productionId;
  final bool allowProduction;
}
