import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/cast_member_model.dart';

void main() {
  group('CastRole', () {
    test('fromString maps actor → primary', () {
      expect(CastRole.fromString('actor'), CastRole.primary);
    });

    test('fromString maps organizer', () {
      expect(CastRole.fromString('organizer'), CastRole.organizer);
    });

    test('fromString maps understudy', () {
      expect(CastRole.fromString('understudy'), CastRole.understudy);
    });

    test('toSupabaseString maps primary → actor', () {
      expect(CastRole.primary.toSupabaseString(), 'actor');
    });

    test('toSupabaseString maps organizer → organizer', () {
      expect(CastRole.organizer.toSupabaseString(), 'organizer');
    });

    test('toSupabaseString maps understudy → understudy', () {
      expect(CastRole.understudy.toSupabaseString(), 'understudy');
    });

    test('roundtrip: fromString(toSupabaseString()) preserves role', () {
      for (final role in CastRole.values) {
        expect(CastRole.fromString(role.toSupabaseString()), role);
      }
    });
  });

  group('CastMemberModel', () {
    test('hasJoined is false when userId is null', () {
      const member = CastMemberModel(
        id: '1',
        productionId: 'prod-1',
        characterName: 'DARCY',
        displayName: 'John Smith',
        role: CastRole.primary,
      );
      expect(member.hasJoined, false);
    });

    test('hasJoined is true when userId is set', () {
      const member = CastMemberModel(
        id: '1',
        productionId: 'prod-1',
        userId: 'user-123',
        characterName: 'DARCY',
        displayName: 'John Smith',
        role: CastRole.primary,
      );
      expect(member.hasJoined, true);
    });

    test('copyWith updates specific fields', () {
      const original = CastMemberModel(
        id: '1',
        productionId: 'prod-1',
        characterName: 'DARCY',
        displayName: 'John Smith',
        role: CastRole.primary,
      );

      final updated = original.copyWith(
        userId: 'user-456',
        displayName: 'Jane Doe',
        role: CastRole.understudy,
      );

      expect(updated.id, '1'); // unchanged
      expect(updated.productionId, 'prod-1'); // unchanged
      expect(updated.characterName, 'DARCY'); // unchanged
      expect(updated.userId, 'user-456');
      expect(updated.displayName, 'Jane Doe');
      expect(updated.role, CastRole.understudy);
    });

    test('copyWith preserves unmodified fields', () {
      final now = DateTime.now();
      final member = CastMemberModel(
        id: '1',
        productionId: 'prod-1',
        userId: 'user-1',
        characterName: 'ELIZABETH',
        displayName: 'Jane',
        contactInfo: 'jane@example.com',
        role: CastRole.primary,
        invitedAt: now,
        joinedAt: now,
      );

      final copy = member.copyWith(displayName: 'Jane Updated');

      expect(copy.id, member.id);
      expect(copy.productionId, member.productionId);
      expect(copy.userId, member.userId);
      expect(copy.characterName, member.characterName);
      expect(copy.contactInfo, member.contactInfo);
      expect(copy.role, member.role);
      expect(copy.invitedAt, member.invitedAt);
      expect(copy.joinedAt, member.joinedAt);
      expect(copy.displayName, 'Jane Updated');
    });
  });
}
