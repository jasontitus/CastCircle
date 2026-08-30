// ignore_for_file: avoid_print
//
// Read-only verification of recordings in an explicitly selected disposable
// Supabase environment. The caller must provide a pre-provisioned,
// least-privilege access token; this tool never signs up users or joins cast.
//
// dart run tool/verify_cloud_recordings.dart \
//   --url http://127.0.0.1:54321 \
//   --key <publishable-key> \
//   --access-token <staging-user-jwt> \
//   --production-id <seeded-production-uuid>

import 'dart:convert';
import 'dart:io';

import 'package:supabase/supabase.dart';

const _productionHost = 'vngpbmqymdaxxnvqptsk.supabase.co';

Future<void> main(List<String> args) async {
  final options = _parseOptions(args);
  final target = Uri.parse(options.url);
  if (target.host == _productionHost && !options.allowProduction) {
    stderr.writeln(
      'Refusing the production project. Re-run with '
      '--allow-production only after approving this read-only audit target.',
    );
    exitCode = 64;
    return;
  }

  final client = SupabaseClient(
    options.url,
    options.key,
    headers: {'Authorization': 'Bearer ${options.accessToken}'},
  );

  final rows = await client
      .from('recordings')
      .select('line_id, audio_url, duration_ms')
      .eq('production_id', options.productionId);
  final recordings = rows.cast<Map<String, dynamic>>();
  if (recordings.isEmpty) {
    throw StateError(
      'No recording rows were visible for the seeded production.',
    );
  }

  var verified = 0;
  for (final recording in recordings.take(3)) {
    final audioUrl = recording['audio_url'];
    if (audioUrl is! String) {
      throw StateError('A recording row has no audio_url string.');
    }
    final objectPath = _objectPathFromUrl(audioUrl);
    if (objectPath == null) {
      throw StateError(
        'A recording URL does not identify a recordings object.',
      );
    }

    final bytes = await client.storage.from('recordings').download(objectPath);
    if (bytes.length < 12 || ascii.decode(bytes.sublist(4, 8)) != 'ftyp') {
      throw StateError('Downloaded object is not a valid MP4/M4A container.');
    }
    verified++;
  }

  if (verified == 0) {
    throw StateError('No recording object was verified.');
  }
  print('Verified $verified recording object(s) in the explicit target.');
}

_Options _parseOptions(List<String> args) {
  if (args.contains('--help')) {
    print(_usage);
    exit(0);
  }

  final values = <String, String>{};
  var allowProduction = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--allow-production') {
      allowProduction = true;
      continue;
    }
    if (!const {
      '--url',
      '--key',
      '--access-token',
      '--production-id',
    }.contains(arg)) {
      _usageError('Unknown argument: $arg');
    }
    if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
      _usageError('Missing value for $arg');
    }
    values[arg] = args[++i];
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

  final url = Uri.tryParse(values['--url']!);
  if (url == null || !url.hasScheme || url.host.isEmpty) {
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

Never _usageError(String message) {
  stderr.writeln('$message\n\n$_usage');
  exit(64);
}

String? _objectPathFromUrl(String url) {
  const marker = '/recordings/';
  final index = url.indexOf(marker);
  if (index < 0) return null;
  final encodedPath = url.substring(index + marker.length).split('?').first;
  if (encodedPath.isEmpty) return null;
  return Uri.decodeFull(encodedPath);
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

const _usage = '''Usage: dart run tool/verify_cloud_recordings.dart
  --url <local-or-staging-supabase-url>
  --key <publishable-key>
  --access-token <pre-provisioned-user-jwt>
  --production-id <seeded-production-uuid>
  [--allow-production]

The command is read-only and performs no signup or membership mutation.
Production is refused unless --allow-production is explicit.''';

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
