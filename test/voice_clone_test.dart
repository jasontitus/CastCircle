import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/voice_clone_service.dart';

void main() {
  group('VoiceProfile', () {
    test('quality is 0 when no reference audio', () {
      final profile = VoiceProfile(
        characterName: 'DARCY',
        referenceAudioPaths: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(profile.quality, 0.0);
    });

    test('quality scales with number of reference clips', () {
      final profile1 = VoiceProfile(
        characterName: 'DARCY',
        referenceAudioPaths: ['/a.wav'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(profile1.quality, closeTo(0.125, 0.01));

      final profile4 = VoiceProfile(
        characterName: 'DARCY',
        referenceAudioPaths: ['/a.wav', '/b.wav', '/c.wav', '/d.wav'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(profile4.quality, closeTo(0.5, 0.01));
    });

    test('quality caps at 1.0 for 8+ clips', () {
      final paths = List.generate(10, (i) => '/clip_$i.wav');
      final profile = VoiceProfile(
        characterName: 'DARCY',
        referenceAudioPaths: paths,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(profile.quality, 1.0);
    });

    test('quality is at least 0.1 when there are any clips', () {
      final profile = VoiceProfile(
        characterName: 'DARCY',
        referenceAudioPaths: ['/one.wav'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(profile.quality, greaterThanOrEqualTo(0.1));
    });

    test('copyWith preserves unchanged fields', () {
      final now = DateTime.now();
      final profile = VoiceProfile(
        characterName: 'DARCY',
        referenceAudioPaths: ['/a.wav'],
        createdAt: now,
        updatedAt: now,
      );

      final updated = profile.copyWith(
        referenceAudioPaths: ['/a.wav', '/b.wav'],
      );

      expect(updated.characterName, 'DARCY');
      expect(updated.referenceAudioPaths.length, 2);
      expect(updated.createdAt, now);
    });
  });

  group('VoiceCloneStatus', () {
    test('has all expected states', () {
      expect(VoiceCloneStatus.values, containsAll([
        VoiceCloneStatus.idle,
        VoiceCloneStatus.extractingEmbedding,
        VoiceCloneStatus.generating,
        VoiceCloneStatus.complete,
        VoiceCloneStatus.error,
      ]));
    });
  });
}
