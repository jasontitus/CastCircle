import 'dart:convert';
import 'dart:io';

import 'package:supabase/supabase.dart';

class ToolCredentials {
  const ToolCredentials(this.accessToken, this.userId);

  final String accessToken;
  final String userId;
}

class AuditMembershipLease {
  AuditMembershipLease(this.id, this.membershipId, this.expiresAt)
    : lastRenewedAt = DateTime.now().toUtc();

  final String id;
  final String membershipId;
  DateTime expiresAt;
  DateTime lastRenewedAt;

  bool get renewalDue =>
      DateTime.now().toUtc().difference(lastRenewedAt) >=
      const Duration(minutes: 30);
}

String requireToolEnvironment(String name) {
  final value = Platform.environment[name]?.trim();
  if (value == null || value.isEmpty) {
    throw StateError('$name must be set');
  }
  return value;
}

Future<ToolCredentials> authenticateToolUser(
  String url,
  String key,
  String email,
  String password,
) async {
  final body = jsonEncode({'email': email, 'password': password});
  final response = await _post(
    '$url/auth/v1/token?grant_type=password',
    key,
    body,
  );
  final accessToken = response?['access_token'] as String?;
  final userId = (response?['user'] as Map?)?['id'] as String?;
  if (accessToken == null || userId == null) {
    final detail =
        response?['msg'] ??
        response?['error_description'] ??
        response?['error'] ??
        response;
    throw StateError('authentication failed for $email: $detail');
  }
  return ToolCredentials(accessToken, userId);
}

Future<AuditMembershipLease> beginAuditMembership(
  SupabaseClient client,
  String productionId,
  String joinCode, {
  required String displayName,
}) async {
  final response = await client.rpc(
    'begin_audit_membership',
    params: {
      'prod_id': productionId,
      'code': joinCode,
      'char_name': '',
      'display_name': displayName,
    },
  );
  if (response is! Map ||
      response['lease_id'] is! String ||
      response['membership_id'] is! String ||
      response['expires_at'] is! String) {
    throw StateError('begin_audit_membership returned an invalid lease');
  }
  return AuditMembershipLease(
    response['lease_id'] as String,
    response['membership_id'] as String,
    DateTime.parse(response['expires_at'] as String),
  );
}

Future<void> renewAuditMembership(
  SupabaseClient client,
  AuditMembershipLease lease,
) async {
  final result = await client.rpc(
    'renew_audit_membership',
    params: {'lease_id': lease.id},
  );
  if (result is! String) {
    throw StateError('renew_audit_membership returned an invalid expiry');
  }
  lease
    ..expiresAt = DateTime.parse(result)
    ..lastRenewedAt = DateTime.now().toUtc();
}

Future<void> endAuditMembership(
  SupabaseClient client,
  AuditMembershipLease lease,
) async {
  final result = await client.rpc(
    'end_audit_membership',
    params: {'lease_id': lease.id},
  );
  if (result != 'released' && result != 'already_absent') {
    throw StateError(
      'end_audit_membership returned unexpected status: $result',
    );
  }
}

Future<Map<String, dynamic>?> _post(String url, String key, String body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers
      ..set('apikey', key)
      ..set('Content-Type', 'application/json');
    request.add(utf8.encode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (text.isEmpty) return null;
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } finally {
    client.close();
  }
}
