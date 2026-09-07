import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:castcircle/data/services/supabase_service.dart';

void main() {
  const productionId = '11111111-1111-4111-8111-111111111111';
  const memberId = '22222222-2222-4222-8222-222222222222';

  test(
    'join lookup uses only the RPC and preserves the explicit contract',
    () async {
      final requests = <http.Request>[];
      final service = _service((request) async {
        requests.add(request);
        expect(request.url.path, '/rest/v1/rpc/lookup_production_by_join_code');
        expect(jsonDecode(request.body), {'lookup_code': 'ABC123'});
        return _json({
          'id': productionId,
          'title': 'Seeded play',
          'organizer_id': '33333333-3333-4333-8333-333333333333',
          'join_code': 'ABC123',
          'created_at': '2026-08-30T00:00:00Z',
          'locale': 'en-US',
          'voice_preset': 'warm_narrator',
        });
      });

      final result = await service.lookupByJoinCode('abc123');

      expect(result, isNotNull);
      expect(result!.keys.toSet(), {
        'id',
        'title',
        'organizer_id',
        'join_code',
        'created_at',
        'locale',
        'voice_preset',
      });
      expect(requests, hasLength(1));
    },
  );

  test(
    'invalid join code returns no production without a table fallback',
    () async {
      final paths = <String>[];
      final service = _service((request) async {
        paths.add(request.url.path);
        return _json(null);
      });

      expect(await service.lookupByJoinCode('WRONG1'), isNull);
      expect(paths, ['/rest/v1/rpc/lookup_production_by_join_code']);
    },
  );

  test(
    'authentication failure propagates without a direct lookup fallback',
    () async {
      final paths = <String>[];
      final service = _service((request) async {
        paths.add(request.url.path);
        return _json({
          'code': '42501',
          'message': 'permission denied for function',
        }, statusCode: 401);
      });

      await expectLater(service.lookupByJoinCode('ABC123'), throwsA(anything));
      expect(paths, ['/rest/v1/rpc/lookup_production_by_join_code']);
    },
  );

  test(
    'pre-membership roster exposes is_claimed instead of user UUIDs',
    () async {
      final service = _service((request) async {
        expect(request.url.path, '/rest/v1/rpc/fetch_cast_for_join');
        return _json([
          {
            'id': memberId,
            'character_name': 'Viola',
            'role': 'actor',
            'is_claimed': true,
          },
        ]);
      });

      final roster = await service.fetchCastMembers(
        productionId,
        joinCode: 'ABC123',
      );

      expect(roster.single.keys.toSet(), {
        'id',
        'character_name',
        'role',
        'is_claimed',
      });
      expect(roster.single['is_claimed'], isTrue);
    },
  );

  test('member roster preserves full cast synchronization fields', () async {
    final service = _service((request) async {
      expect(jsonDecode(request.body), {'prod_id': productionId, 'code': ''});
      return _json([
        {
          'id': memberId,
          'production_id': productionId,
          'character_name': 'Viola',
          'display_name': 'Actor',
          'role': 'actor',
          'user_id': '99999999-9999-4999-8999-999999999999',
          'contact_info': 'actor@example.test',
          'invited_at': '2026-08-29T00:00:00Z',
          'joined_at': '2026-08-30T00:00:00Z',
          'is_claimed': true,
        },
      ]);
    });

    final roster = await service.fetchCastMembers(productionId);

    expect(roster.single.keys.toSet(), {
      'id',
      'production_id',
      'character_name',
      'display_name',
      'role',
      'user_id',
      'contact_info',
      'invited_at',
      'joined_at',
      'is_claimed',
    });
  });

  test(
    'wrong-code invitation result fails and never attempts direct update',
    () async {
      final paths = <String>[];
      final service = _service((request) async {
        paths.add(request.url.path);
        return _json('invalid_code');
      });

      await expectLater(
        service.claimInvitation(castMemberId: memberId, joinCode: 'WRONG1'),
        throwsA(isA<StateError>()),
      );
      expect(paths, ['/rest/v1/rpc/claim_cast_invitation']);
    },
  );

  test('claimed invitation succeeds only on explicit claimed result', () async {
    final service = _service((request) async => _json('claimed'));

    await service.claimInvitation(castMemberId: memberId, joinCode: 'ABC123');
  });

  test(
    'join RPC failure propagates without direct cast_members insert',
    () async {
      final paths = <String>[];
      final service = _service((request) async {
        paths.add(request.url.path);
        return _json({
          'code': 'P0001',
          'message': 'Invalid join code for this production',
        }, statusCode: 400);
      });

      await expectLater(
        service.selfJoinProduction(
          productionId: productionId,
          characterName: 'Viola',
          displayName: 'Actor',
          joinCode: 'WRONG1',
        ),
        throwsA(anything),
      );
      expect(paths, ['/rest/v1/rpc/join_production']);
    },
  );
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
