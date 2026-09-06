// ignore_for_file: avoid_print
//
// Find storage objects in the recordings bucket that no recordings.audio_url
// references. This is dry-run-only unless --delete is supplied.
//
//   SUPABASE_SERVICE_ROLE_KEY=... \
//     dart run tool/backfill_orphaned_recording_objects.dart [--delete]
//
// The service-role key is required because both sides of the comparison must be
// complete. Never pass the key on argv.

import 'dart:convert';
import 'dart:io';

const _defaultUrl = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
const _metadataPageSize = 500;
const _storagePageSize = 100;
const _deleteBatchSize = 100;
const _sampleSize = 10;

class RecordingReference {
  const RecordingReference({required this.id, required this.recordedAt});

  final String id;
  final String recordedAt;
}

class StorageObject {
  const StorageObject({required this.path, required this.updatedAt});

  final String path;
  final String updatedAt;
}

Future<void> main(List<String> args) async {
  if (args.length > 1 || (args.isNotEmpty && args.single != '--delete')) {
    stderr.writeln(
      'usage: dart run '
      'tool/backfill_orphaned_recording_objects.dart [--delete]',
    );
    exitCode = 2;
    return;
  }

  final deleteRequested = args.isNotEmpty;
  final serviceRoleKey = Platform.environment['SUPABASE_SERVICE_ROLE_KEY'];
  if (serviceRoleKey == null || serviceRoleKey.trim().isEmpty) {
    stderr.writeln('SUPABASE_SERVICE_ROLE_KEY must be set');
    exitCode = 2;
    return;
  }
  final url = Platform.environment['SUPABASE_URL']?.trim().isNotEmpty == true
      ? Platform.environment['SUPABASE_URL']!.trim()
      : _defaultUrl;
  final api = _SupabaseAdminApi(url, serviceRoleKey.trim());

  try {
    final references = await api.fetchRecordingReferences();
    final objects = await api.fetchStorageObjects();
    final keepPaths = references.keys.toSet();
    final objectPaths = objects.keys.toSet();
    final deletePaths = objectPaths.difference(keepPaths).toList()..sort();
    final missingPaths = keepPaths.difference(objectPaths).toList()..sort();

    _printPlan(references, objects, deletePaths, missingPaths);
    _assertNoLiveReferenceIsDeleted(keepPaths, deletePaths);

    if (!deleteRequested) {
      print(
        '\nDRY RUN: no objects deleted. Re-run with --delete after reviewing '
        'the KEEP and DELETE samples above.',
      );
      return;
    }
    if (deletePaths.isEmpty) {
      print('\nNothing to delete.');
      return;
    }

    // Re-read the live metadata immediately before deletion. A recording may
    // have been created since the dry-run plan was assembled.
    final latestReferences = await api.fetchRecordingReferences();
    _assertNoLiveReferenceIsDeleted(latestReferences.keys.toSet(), deletePaths);
    final newlyReferenced = deletePaths
        .where(latestReferences.containsKey)
        .toList();
    if (newlyReferenced.isNotEmpty) {
      throw StateError(
        'ABORT: ${newlyReferenced.length} DELETE candidate(s) became live '
        'recording references: ${newlyReferenced.take(_sampleSize).join(', ')}',
      );
    }

    print(
      '\nDeleting ${deletePaths.length} independently enumerated orphan '
      'object(s)...',
    );
    for (
      var offset = 0;
      offset < deletePaths.length;
      offset += _deleteBatchSize
    ) {
      final proposedEnd = offset + _deleteBatchSize;
      final end = proposedEnd < deletePaths.length
          ? proposedEnd
          : deletePaths.length;
      await api.deleteStorageObjects(deletePaths.sublist(offset, end));
      print('  requested deletion of ${end - offset} object(s)');
    }

    final remainingObjects = await api.fetchStorageObjects();
    final notDeleted = deletePaths.where(remainingObjects.containsKey).toList();
    if (notDeleted.isNotEmpty) {
      throw StateError(
        'deletion verification failed: ${notDeleted.length} target(s) remain: '
        '${notDeleted.take(_sampleSize).join(', ')}',
      );
    }
    print('Verified: all ${deletePaths.length} DELETE targets are absent.');
  } catch (error) {
    stderr.writeln('recording-object backfill failed: $error');
    exitCode = 1;
  } finally {
    api.close();
  }
}

void _printPlan(
  Map<String, List<RecordingReference>> references,
  Map<String, StorageObject> objects,
  List<String> deletePaths,
  List<String> missingPaths,
) {
  final referenceCount = references.values.fold<int>(
    0,
    (sum, rows) => sum + rows.length,
  );
  print(
    'KEEP (live metadata): ${references.length} object path(s) from '
    '$referenceCount recording row(s)',
  );
  final sortedKeepPaths = references.keys.toList()..sort();
  for (final path in sortedKeepPaths.take(_sampleSize)) {
    final reference = references[path]!.first;
    print(
      '  KEEP $path <- recording=${reference.id} '
      'recorded_at=${reference.recordedAt}',
    );
  }

  print('\nOBJECTS (independent storage listing): ${objects.length}');
  final sortedObjects = objects.values.toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  for (final object in sortedObjects.take(_sampleSize)) {
    print('  OBJECT ${object.path} updated_at=${object.updatedAt}');
  }

  print('\nDELETE (OBJECTS - KEEP): ${deletePaths.length}');
  for (final path in deletePaths.take(_sampleSize)) {
    print('  DELETE $path updated_at=${objects[path]?.updatedAt ?? '?'}');
  }

  print('\nMISSING (KEEP - OBJECTS): ${missingPaths.length}');
  for (final path in missingPaths.take(_sampleSize)) {
    final reference = references[path]!.first;
    print(
      '  MISSING $path <- recording=${reference.id} '
      'recorded_at=${reference.recordedAt}',
    );
  }
}

void _assertNoLiveReferenceIsDeleted(
  Set<String> keepPaths,
  Iterable<String> deletePaths,
) {
  final overlap = deletePaths.where(keepPaths.contains).toList();
  if (overlap.isNotEmpty) {
    throw StateError(
      'ABORT: DELETE intersects KEEP: '
      '${overlap.take(_sampleSize).join(', ')}',
    );
  }
}

class _SupabaseAdminApi {
  _SupabaseAdminApi(String baseUrl, this._serviceRoleKey)
    : _baseUri = Uri.parse(baseUrl),
      _client = HttpClient();

  final Uri _baseUri;
  final String _serviceRoleKey;
  final HttpClient _client;

  Future<Map<String, List<RecordingReference>>>
  fetchRecordingReferences() async {
    final references = <String, List<RecordingReference>>{};
    for (var offset = 0; ; offset += _metadataPageSize) {
      final uri = _baseUri
          .resolve('/rest/v1/recordings')
          .replace(
            queryParameters: {
              'select': 'id,audio_url,recorded_at',
              'order': 'id.asc',
              'limit': '$_metadataPageSize',
              'offset': '$offset',
            },
          );
      final decoded = await _request('GET', uri);
      if (decoded is! List) {
        throw StateError('recordings query returned a non-list response');
      }
      for (final value in decoded) {
        if (value is! Map) {
          throw StateError('recordings query returned a malformed row');
        }
        final id = value['id'] as String?;
        final audioUrl = value['audio_url'] as String?;
        if (id == null || audioUrl == null || audioUrl.isEmpty) continue;
        final objectPath = _objectPathFromRecordingUrl(audioUrl);
        references
            .putIfAbsent(objectPath, () => [])
            .add(
              RecordingReference(
                id: id,
                recordedAt: value['recorded_at'] as String? ?? '?',
              ),
            );
      }
      if (decoded.length < _metadataPageSize) return references;
    }
  }

  Future<Map<String, StorageObject>> fetchStorageObjects() async {
    final objects = <String, StorageObject>{};
    final pendingPrefixes = <String>[''];
    final visitedPrefixes = <String>{};
    while (pendingPrefixes.isNotEmpty) {
      final prefix = pendingPrefixes.removeLast();
      if (!visitedPrefixes.add(prefix)) continue;
      for (var offset = 0; ; offset += _storagePageSize) {
        final uri = _baseUri.resolve('/storage/v1/object/list/recordings');
        final decoded = await _request(
          'POST',
          uri,
          body: {
            'prefix': prefix,
            'limit': _storagePageSize,
            'offset': offset,
            'sortBy': {'column': 'name', 'order': 'asc'},
          },
        );
        if (decoded is! List) {
          throw StateError('storage listing returned a non-list response');
        }
        for (final value in decoded) {
          if (value is! Map || value['name'] is! String) {
            throw StateError('storage listing returned a malformed object');
          }
          final name = value['name'] as String;
          final path = prefix.isEmpty ? name : '$prefix/$name';
          if (value['id'] == null) {
            pendingPrefixes.add(path);
          } else {
            objects[path] = StorageObject(
              path: path,
              updatedAt: value['updated_at'] as String? ?? '?',
            );
          }
        }
        if (decoded.length < _storagePageSize) break;
      }
    }
    return objects;
  }

  Future<void> deleteStorageObjects(List<String> paths) async {
    if (paths.isEmpty) return;
    final uri = _baseUri.resolve('/storage/v1/object/recordings');
    await _request('DELETE', uri, body: {'prefixes': paths});
  }

  Future<dynamic> _request(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    final request = await _client.openUrl(method, uri);
    request.headers
      ..set('apikey', _serviceRoleKey)
      ..set('Authorization', 'Bearer $_serviceRoleKey')
      ..set('Accept', 'application/json');
    if (body != null) {
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        '$method ${uri.path} returned HTTP ${response.statusCode}: '
        '$responseBody',
        uri: uri,
      );
    }
    if (responseBody.isEmpty) return null;
    return jsonDecode(responseBody);
  }

  void close() => _client.close(force: true);
}

String _objectPathFromRecordingUrl(String url) {
  const marker = '/recordings/';
  final markerIndex = url.indexOf(marker);
  if (markerIndex < 0) {
    throw FormatException('audio_url does not identify the recordings bucket');
  }
  var path = url.substring(markerIndex + marker.length);
  final suffixIndex = path.indexOf(RegExp(r'[?#]'));
  if (suffixIndex >= 0) path = path.substring(0, suffixIndex);
  path = Uri.decodeFull(path);
  final segments = path.split('/');
  if (path.isEmpty ||
      path.startsWith('/') ||
      segments.any((segment) => segment == '.' || segment == '..')) {
    throw FormatException('audio_url has an invalid object path');
  }
  return path;
}
