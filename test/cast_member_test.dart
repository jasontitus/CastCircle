import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/cast_member_model.dart';
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/data/services/supabase_service.dart';

void main() {
  group('CastMemberModel', () {
    test('hasJoined is false when userId is null', () {
      const member = CastMemberModel(
        id: 'cm-1',
        productionId: 'prod-1',
        characterName: 'ELIZABETH',
        displayName: 'Jane Doe',
        role: CastRole.primary,
      );
      expect(member.hasJoined, false);
      expect(member.userId, null);
    });

    test('hasJoined is true when userId is set', () {
      const member = CastMemberModel(
        id: 'cm-1',
        productionId: 'prod-1',
        userId: 'user-123',
        characterName: 'ELIZABETH',
        displayName: 'Jane Doe',
        role: CastRole.primary,
      );
      expect(member.hasJoined, true);
    });

    test('copyWith preserves unchanged fields', () {
      final member = CastMemberModel(
        id: 'cm-1',
        productionId: 'prod-1',
        characterName: 'DARCY',
        displayName: 'John Smith',
        role: CastRole.primary,
        invitedAt: DateTime(2026, 3, 15),
      );

      final updated = member.copyWith(userId: 'user-456');
      expect(updated.id, 'cm-1');
      expect(updated.productionId, 'prod-1');
      expect(updated.characterName, 'DARCY');
      expect(updated.displayName, 'John Smith');
      expect(updated.role, CastRole.primary);
      expect(updated.userId, 'user-456');
    });

    test('copyWith can change role', () {
      const member = CastMemberModel(
        id: 'cm-1',
        productionId: 'prod-1',
        characterName: 'BINGLEY',
        displayName: 'Bob',
        role: CastRole.primary,
      );

      final updated = member.copyWith(role: CastRole.understudy);
      expect(updated.role, CastRole.understudy);
      expect(updated.characterName, 'BINGLEY');
    });
  });

  group('CastRole', () {
    test('fromString maps Supabase "actor" to primary', () {
      expect(CastRole.fromString('actor'), CastRole.primary);
    });

    test('fromString maps "organizer" correctly', () {
      expect(CastRole.fromString('organizer'), CastRole.organizer);
    });

    test('fromString maps "understudy" correctly', () {
      expect(CastRole.fromString('understudy'), CastRole.understudy);
    });

    test('toSupabaseString maps primary to "actor"', () {
      expect(CastRole.primary.toSupabaseString(), 'actor');
    });

    test('toSupabaseString maps organizer to "organizer"', () {
      expect(CastRole.organizer.toSupabaseString(), 'organizer');
    });

    test('toSupabaseString maps understudy to "understudy"', () {
      expect(CastRole.understudy.toSupabaseString(), 'understudy');
    });

    test('fromString and toSupabaseString roundtrip', () {
      for (final role in CastRole.values) {
        final supaStr = role.toSupabaseString();
        expect(CastRole.fromString(supaStr), role);
      }
    });
  });

  group('Production joinCode', () {
    test('Production can be created with joinCode', () {
      final production = Production(
        id: 'prod-1',
        title: 'Pride and Prejudice',
        organizerId: 'org-1',
        createdAt: DateTime(2026, 3, 15),
        status: ProductionStatus.draft,
        joinCode: 'H4MK7P',
      );
      expect(production.joinCode, 'H4MK7P');
    });

    test('Production joinCode is null by default', () {
      final production = Production(
        id: 'prod-1',
        title: 'Test',
        organizerId: 'org-1',
        createdAt: DateTime.now(),
        status: ProductionStatus.draft,
      );
      expect(production.joinCode, null);
    });

    test('Production copyWith can set joinCode', () {
      final production = Production(
        id: 'prod-1',
        title: 'Test',
        organizerId: 'org-1',
        createdAt: DateTime.now(),
        status: ProductionStatus.draft,
      );
      final updated = production.copyWith(joinCode: 'ABC123');
      expect(updated.joinCode, 'ABC123');
      expect(updated.title, 'Test');
    });
  });

  group('Join code generation', () {
    test('generateJoinCode returns 6-character string', () {
      final code = SupabaseService.generateJoinCode();
      expect(code.length, 6);
    });

    test('generateJoinCode uses only valid characters (no I/O/0/1)', () {
      const validChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
      // Generate many codes to test character set
      for (var i = 0; i < 100; i++) {
        final code = SupabaseService.generateJoinCode();
        for (final char in code.split('')) {
          expect(validChars.contains(char), true,
              reason: 'Invalid character "$char" in code "$code"');
        }
      }
    });

    test('generateJoinCode produces unique codes', () {
      final codes = <String>{};
      for (var i = 0; i < 100; i++) {
        codes.add(SupabaseService.generateJoinCode());
      }
      // With 6 chars from 32-char alphabet, collision in 100 is vanishingly rare
      expect(codes.length, greaterThan(95));
    });

    test('generateJoinCode never contains ambiguous characters', () {
      for (var i = 0; i < 200; i++) {
        final code = SupabaseService.generateJoinCode();
        expect(code.contains('I'), false, reason: 'Contains I');
        expect(code.contains('O'), false, reason: 'Contains O');
        expect(code.contains('0'), false, reason: 'Contains 0');
        expect(code.contains('1'), false, reason: 'Contains 1');
      }
    });
  });

  group('Cast assignment flow', () {
    test('organizer creates invitation (no userId)', () {
      const invitation = CastMemberModel(
        id: 'cm-1',
        productionId: 'prod-1',
        characterName: 'ELIZABETH',
        displayName: 'Sarah',
        contactInfo: 'sarah@example.com',
        role: CastRole.primary,
      );

      expect(invitation.hasJoined, false);
      expect(invitation.userId, null);
      expect(invitation.contactInfo, 'sarah@example.com');
    });

    test('actor claims invitation by setting userId', () {
      final invitation = CastMemberModel(
        id: 'cm-1',
        productionId: 'prod-1',
        characterName: 'ELIZABETH',
        displayName: 'Sarah',
        role: CastRole.primary,
        invitedAt: DateTime(2026, 3, 15),
      );

      final claimed = invitation.copyWith(
        userId: 'user-789',
        joinedAt: DateTime(2026, 3, 16),
      );

      expect(claimed.hasJoined, true);
      expect(claimed.userId, 'user-789');
      expect(claimed.characterName, 'ELIZABETH');
      expect(claimed.displayName, 'Sarah');
      expect(claimed.invitedAt, DateTime(2026, 3, 15));
      expect(claimed.joinedAt, DateTime(2026, 3, 16));
    });

    test('self-join creates member with userId and joinedAt', () {
      final selfJoined = CastMemberModel(
        id: 'cm-2',
        productionId: 'prod-1',
        userId: 'user-999',
        characterName: 'DARCY',
        displayName: 'Mike',
        role: CastRole.primary,
        joinedAt: DateTime(2026, 3, 16),
      );

      expect(selfJoined.hasJoined, true);
      expect(selfJoined.userId, 'user-999');
    });

    test('understudy assignment tracks separately', () {
      const primary = CastMemberModel(
        id: 'cm-1',
        productionId: 'prod-1',
        userId: 'user-1',
        characterName: 'ELIZABETH',
        displayName: 'Sarah',
        role: CastRole.primary,
      );

      const understudy = CastMemberModel(
        id: 'cm-2',
        productionId: 'prod-1',
        userId: 'user-2',
        characterName: 'ELIZABETH',
        displayName: 'Emily',
        role: CastRole.understudy,
      );

      expect(primary.characterName, understudy.characterName);
      expect(primary.role, CastRole.primary);
      expect(understudy.role, CastRole.understudy);
      expect(primary.userId, isNot(understudy.userId));
    });
  });
}
