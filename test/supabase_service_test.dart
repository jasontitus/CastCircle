import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:castcircle/data/services/supabase_service.dart';

void main() {
  const productionId = '11111111-1111-4111-8111-111111111111';
  const lineId = '22222222-2222-4222-8222-222222222222';
  const sceneId = '33333333-3333-4333-8333-333333333333';
  const revisionId = '44444444-4444-4444-8444-444444444444';
  const invitationId = '66666666-6666-4666-8666-666666666666';

  test(
    'script save sends lines and scenes in one RPC and verifies commit',
    () async {
      late Map<String, dynamic> requestBody;
      var requestCount = 0;
      final service = _service((request) async {
        requestCount++;
        expect(request.url.path, '/rest/v1/rpc/replace_script');
        requestBody = Map<String, dynamic>.from(
          jsonDecode(request.body) as Map,
        );
        return _json({
          'revision': revisionId,
          'line_count': 1,
          'scene_count': 1,
        });
      });
      final lines = [
        {
          'id': lineId,
          'production_id': productionId,
          'order_index': 0,
          'line_number': 1,
          'line_text': 'If music be the food of love, play on.',
        },
      ];
      final scenes = [
        {
          'id': sceneId,
          'production_id': productionId,
          'sort_order': 0,
          'start_line_index': 0,
          'end_line_index': 0,
        },
      ];

      final revision = await service.saveScript(
        productionId: productionId,
        lines: lines,
        scenes: scenes,
      );

      expect(revision, revisionId);
      expect(requestCount, 1);
      expect(requestBody['p_production_id'], productionId);
      expect(requestBody['p_lines'], lines);
      expect(requestBody['p_scenes'], scenes);
    },
  );

  test('script save rejects mismatched committed counts', () async {
    final service = _service(
      (request) async =>
          _json({'revision': revisionId, 'line_count': 0, 'scene_count': 1}),
    );

    await expectLater(
      service.saveScript(
        productionId: productionId,
        lines: [
          {'id': lineId, 'production_id': productionId, 'order_index': 0},
        ],
        scenes: const [],
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'production creation is one RPC with stable retry identifiers',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final service = _service((request) async {
        expect(request.url.path, '/rest/v1/rpc/create_production');
        bodies.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
        return _json({
          'id': productionId,
          'title': 'Twelfth Night',
          'organizer_id': '55555555-5555-4555-8555-555555555555',
          'status': 'draft',
          'join_code': 'ABC123',
          'created_at': '2026-08-30T00:00:00Z',
          'locale': 'en-US',
        });
      });

      final first = await service.createProduction(
        title: 'Twelfth Night',
        id: productionId,
        joinCode: 'ABC123',
      );
      final retry = await service.createProduction(
        title: 'Twelfth Night',
        id: productionId,
        joinCode: 'ABC123',
      );

      expect(first, retry);
      expect(bodies, hasLength(2));
      expect(bodies[0], bodies[1]);
    },
  );

  test(
    'invitation creation retries one RPC with the same durable id',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final service = _service((request) async {
        expect(request.url.path, '/rest/v1/rpc/create_cast_invitation');
        bodies.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
        return _json({
          'id': invitationId,
          'production_id': productionId,
          'user_id': null,
          'character_name': 'Viola',
          'display_name': 'Actor',
          'contact_info': null,
          'role': 'actor',
        });
      });

      final first = await service.createCastInvitation(
        id: invitationId,
        productionId: productionId,
        characterName: 'Viola',
        displayName: 'Actor',
        role: 'actor',
      );
      final retry = await service.createCastInvitation(
        id: invitationId,
        productionId: productionId,
        characterName: 'Viola',
        displayName: 'Actor',
        role: 'actor',
      );

      expect(first, retry);
      expect(bodies, hasLength(2));
      expect(bodies[0], bodies[1]);
      expect(bodies.first['p_id'], invitationId);
    },
  );

  test(
    'explicit recording delete drains and acknowledges durable cleanup',
    () async {
      const userId = '77777777-7777-4777-8777-777777777777';
      const cleanupId = '88888888-8888-4888-8888-888888888888';
      final objectName = '$productionId/Viola/$lineId/take.m4a';
      final audioUrl =
          'http://127.0.0.1:54321/storage/v1/object/public/recordings/'
          '$objectName';
      final requests = <http.Request>[];
      final service = _service((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/rest/v1/rpc/delete_recording_metadata':
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['p_audio_url'], audioUrl);
            expect(body['p_object_name'], objectName);
            return _json({'deleted': true});
          case '/rest/v1/rpc/claim_recording_cleanup':
            return _json([
              {'id': cleanupId, 'object_name': objectName},
            ]);
          case '/storage/v1/object/recordings':
            expect(jsonDecode(request.body), {
              'prefixes': [objectName],
            });
            return _json([]);
          case '/rest/v1/rpc/complete_recording_cleanup':
            expect(jsonDecode(request.body), {'p_cleanup_id': cleanupId});
            return _json(true);
          default:
            fail('Unexpected request: ${request.url}');
        }
      });

      final deleted = await service.deleteRecording(
        productionId: productionId,
        lineId: lineId,
        userId: userId,
        audioUrl: audioUrl,
      );

      expect(deleted, isTrue);
      expect(requests.map((request) => request.url.path), [
        '/rest/v1/rpc/delete_recording_metadata',
        '/rest/v1/rpc/claim_recording_cleanup',
        '/storage/v1/object/recordings',
        '/rest/v1/rpc/complete_recording_cleanup',
      ]);
    },
  );

  test('storage failure remains queued and succeeds on retry', () async {
    const userId = '77777777-7777-4777-8777-777777777777';
    const cleanupId = '88888888-8888-4888-8888-888888888888';
    final objectName = '$productionId/Viola/$lineId/take.m4a';
    final audioUrl =
        'http://127.0.0.1:54321/storage/v1/object/public/recordings/'
        '$objectName';
    var storageAttempts = 0;
    var acknowledgements = 0;
    final service = _service((request) async {
      switch (request.url.path) {
        case '/rest/v1/rpc/delete_recording_metadata':
          return _json({'deleted': true});
        case '/rest/v1/rpc/claim_recording_cleanup':
          return _json([
            {'id': cleanupId, 'object_name': objectName},
          ]);
        case '/storage/v1/object/recordings':
          storageAttempts++;
          if (storageAttempts == 1) {
            return _json({'message': 'temporary failure'}, statusCode: 503);
          }
          return _json([]);
        case '/rest/v1/rpc/complete_recording_cleanup':
          acknowledgements++;
          return _json(true);
        default:
          fail('Unexpected request: ${request.url}');
      }
    });

    await expectLater(
      service.deleteRecording(
        productionId: productionId,
        lineId: lineId,
        userId: userId,
        audioUrl: audioUrl,
      ),
      throwsA(anything),
    );
    expect(acknowledgements, 0);

    expect(
      await service.deleteRecording(
        productionId: productionId,
        lineId: lineId,
        userId: userId,
        audioUrl: audioUrl,
      ),
      isTrue,
    );
    expect(storageAttempts, 2);
    expect(acknowledgements, 1);
  });

  test(
    'superseded-object cleanup remains retryable after metadata commit',
    () async {
      const userId = '77777777-7777-4777-8777-777777777777';
      const cleanupId = '88888888-8888-4888-8888-888888888888';
      final oldObjectName = '$productionId/Lady Macbeth/$lineId/old.m4a';
      final oldUrl =
          'http://127.0.0.1:54321/storage/v1/object/public/recordings/'
          '$productionId/Lady%20Macbeth/$lineId/old.m4a';
      final newUrl =
          'http://127.0.0.1:54321/storage/v1/object/public/recordings/'
          '$productionId/Lady%20Macbeth/%E7%8E%8B/$lineId/new.m4a';
      var storageAttempts = 0;
      var metadataCalls = 0;
      var acknowledgements = 0;
      final service = _service((request) async {
        switch (request.url.path) {
          case '/rest/v1/recordings':
            return _json({'audio_url': metadataCalls == 0 ? oldUrl : newUrl});
          case '/rest/v1/rpc/save_recording_metadata':
            metadataCalls++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(
              body['p_object_name'],
              '$productionId/Lady Macbeth/王/$lineId/new.m4a',
            );
            if (metadataCalls == 1) {
              expect(body['p_previous_audio_url'], oldUrl);
              expect(body['p_previous_object_name'], oldObjectName);
            }
            return _json({'saved': true});
          case '/rest/v1/rpc/claim_recording_cleanup':
            return _json([
              {'id': cleanupId, 'object_name': oldObjectName},
            ]);
          case '/storage/v1/object/recordings':
            storageAttempts++;
            if (storageAttempts == 1) {
              return _json({'message': 'temporary failure'}, statusCode: 503);
            }
            return _json([]);
          case '/rest/v1/rpc/complete_recording_cleanup':
            acknowledgements++;
            return _json(true);
          default:
            fail('Unexpected request: ${request.url}');
        }
      });

      Future<void> save() => service.saveRecordingMetadata(
        productionId: productionId,
        lineId: lineId,
        userId: userId,
        audioUrl: newUrl,
        durationMs: 1000,
      );

      await save();
      expect(acknowledgements, 0);
      await save();

      expect(metadataCalls, 2);
      expect(storageAttempts, 2);
      expect(acknowledgements, 1);
    },
  );

  test('abandoned upload is durable before deferred storage cleanup', () async {
    const userId = '77777777-7777-4777-8777-777777777777';
    const cleanupId = '88888888-8888-4888-8888-888888888888';
    final objectName = '$productionId/Viola/$lineId/orphan.m4a';
    final audioUrl =
        'http://127.0.0.1:54321/storage/v1/object/public/recordings/'
        '$objectName';
    final requests = <http.Request>[];
    final service = _service((request) async {
      requests.add(request);
      switch (request.url.path) {
        case '/rest/v1/rpc/queue_recording_cleanup':
          expect(jsonDecode(request.body), {
            'p_production_id': productionId,
            'p_line_id': lineId,
            'p_user_id': userId,
            'p_object_name': objectName,
          });
          return _json(true);
        case '/rest/v1/rpc/claim_recording_cleanup':
          return _json([
            {'id': cleanupId, 'object_name': objectName},
          ]);
        case '/storage/v1/object/recordings':
          return _json({'message': 'temporary failure'}, statusCode: 503);
        default:
          fail('Unexpected request: ${request.url}');
      }
    });

    await service.discardRecordingUpload(
      productionId: productionId,
      lineId: lineId,
      userId: userId,
      audioUrl: audioUrl,
    );

    expect(requests.map((request) => request.url.path), [
      '/rest/v1/rpc/queue_recording_cleanup',
      '/rest/v1/rpc/claim_recording_cleanup',
      '/storage/v1/object/recordings',
    ]);
  });

  test('voice preset update requires an acknowledged production row', () async {
    final service = _service((request) async {
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/productions');
      return _json([]);
    });

    await expectLater(
      service.saveVoicePreset(productionId: productionId, presetId: 'narrator'),
      throwsA(isA<StateError>()),
    );
  });

  test('locale update requires an acknowledged production row', () async {
    final service = _service((request) async {
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/productions');
      return _json([]);
    });

    await expectLater(
      service.saveLocale(productionId: productionId, locale: 'en-GB'),
      throwsA(isA<StateError>()),
    );
  });
}

SupabaseService _service(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = SupabaseClient(
    'http://127.0.0.1:54321',
    'local-test-key',
    httpClient: MockClient((request) async {
      final response = await handler(request);
      return http.Response.bytes(
        response.bodyBytes,
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    }),
  );
  return SupabaseService.forTesting(client);
}

http.Response _json(Object? body, {int statusCode = 200}) => http.Response(
  jsonEncode(body),
  statusCode,
  headers: {'content-type': 'application/json'},
);
