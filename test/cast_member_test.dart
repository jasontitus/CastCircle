import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/data/services/supabase_service.dart';

void main() {
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
          expect(
            validChars.contains(char),
            true,
            reason: 'Invalid character "$char" in code "$code"',
          );
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
}
