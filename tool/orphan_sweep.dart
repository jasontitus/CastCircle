// ignore_for_file: avoid_print
//
// Read-only orphan sweep over productions visible to an explicitly provided
// local/staging auditor identity. This command never creates users or cast rows.

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
  final productions =
      (await client
                  .from('productions')
                  .select('id, created_at')
                  .order('created_at')
              as List)
          .cast<Map<String, dynamic>>();
  print('${productions.length} visible production(s)');

  final failures = <String>[];
  for (final production in productions) {
    final productionId = production['id'] as String;
    try {
      final lines =
          (await client
                      .from('script_lines')
                      .select('id')
                      .eq('production_id', productionId)
                  as List)
              .cast<Map<String, dynamic>>();
      final lineIds = lines.map((line) => line['id'] as String).toSet();
      final recordings =
          (await client
                      .from('recordings')
                      .select('line_id')
                      .eq('production_id', productionId)
                  as List)
              .cast<Map<String, dynamic>>();
      final orphanCount = recordings
          .where((recording) => !lineIds.contains(recording['line_id']))
          .length;
      print(
        '$productionId lines=${lineIds.length} '
        'recordings=${recordings.length} '
        'matched=${recordings.length - orphanCount} orphaned=$orphanCount',
      );
    } catch (error) {
      failures.add('$productionId: $error');
    }
  }

  if (failures.isNotEmpty) {
    throw StateError(
      'Failed to audit ${failures.length} production(s):\n'
      '${failures.join('\n')}',
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
    if (!const {'--url', '--key', '--access-token'}.contains(argument)) {
      _usageError('Unknown argument: $argument');
    }
    if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
      _usageError('Missing value for $argument');
    }
    values[argument] = args[++index];
  }
  for (final required in const ['--url', '--key', '--access-token']) {
    if ((values[required] ?? '').isEmpty) {
      _usageError('Missing required argument: $required');
    }
  }
  final target = Uri.tryParse(values['--url']!);
  if (target == null || !target.hasScheme || target.host.isEmpty) {
    _usageError('--url must be an absolute HTTP(S) URL');
  }
  return _Options(
    url: values['--url']!,
    key: values['--key']!,
    accessToken: values['--access-token']!,
    allowProduction: allowProduction,
  );
}

Never _usageError(String message) {
  stderr.writeln('$message\n\n$_usage');
  exit(64);
}

const _usage = '''Usage: dart run tool/orphan_sweep.dart
  --url <local-or-staging-supabase-url>
  --key <publishable-key>
  --access-token <pre-provisioned-auditor-jwt>
  [--allow-production]

Only productions already visible to the supplied identity are read. The
command performs no signup or membership mutation.''';

class _Options {
  const _Options({
    required this.url,
    required this.key,
    required this.accessToken,
    required this.allowProduction,
  });

  final String url;
  final String key;
  final String accessToken;
  final bool allowProduction;
}
