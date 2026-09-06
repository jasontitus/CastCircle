/// Role a cast member plays in a production.
enum CastRole {
  organizer,
  primary,
  understudy;

  /// Map from Supabase role strings (which use 'actor' instead of 'primary').
  /// Unknown strings (a newer app version's role, a malformed row) degrade to
  /// understudy so invalid cloud data cannot grant primary assignment precedence.
  static CastRole fromString(String s) {
    if (s == 'actor') return CastRole.primary;
    return CastRole.values.asNameMap()[s] ?? CastRole.understudy;
  }

  /// Convert to Supabase-compatible string.
  String toSupabaseString() {
    if (this == CastRole.primary) return 'actor';
    return name;
  }
}

/// A member of a production's cast, with invitation/join tracking.
class CastMemberModel {
  final String id;
  final String productionId;
  final String? userId; // null until they join
  final String characterName;
  final String displayName; // entered by organizer
  final String? contactInfo; // email or phone
  final CastRole role;
  final DateTime? invitedAt;
  final DateTime? joinedAt;

  const CastMemberModel({
    required this.id,
    required this.productionId,
    this.userId,
    required this.characterName,
    required this.displayName,
    this.contactInfo,
    required this.role,
    this.invitedAt,
    this.joinedAt,
  });

  bool get hasJoined => userId != null;

  CastMemberModel copyWith({
    String? id,
    String? productionId,
    String? userId,
    String? characterName,
    String? displayName,
    String? contactInfo,
    CastRole? role,
    DateTime? invitedAt,
    DateTime? joinedAt,
  }) {
    return CastMemberModel(
      id: id ?? this.id,
      productionId: productionId ?? this.productionId,
      userId: userId ?? this.userId,
      characterName: characterName ?? this.characterName,
      displayName: displayName ?? this.displayName,
      contactInfo: contactInfo ?? this.contactInfo,
      role: role ?? this.role,
      invitedAt: invitedAt ?? this.invitedAt,
      joinedAt: joinedAt ?? this.joinedAt,
    );
  }
}
