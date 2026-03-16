import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/stt_adaptation_service.dart';

void main() {
  group('TrainingSample', () {
    test('toJson and fromJson round-trip', () {
      final sample = TrainingSample(
        audioPath: '/audio/line1.m4a',
        transcript: 'To be or not to be.',
        character: 'HAMLET',
        durationMs: 5000,
        recordedAt: DateTime(2026, 3, 14, 10, 30),
      );

      final json = sample.toJson();
      final restored = TrainingSample.fromJson(json);

      expect(restored.audioPath, sample.audioPath);
      expect(restored.transcript, sample.transcript);
      expect(restored.character, sample.character);
      expect(restored.durationMs, sample.durationMs);
      expect(restored.recordedAt.year, 2026);
    });
  });

  group('SttProfile', () {
    test('totalAudioSeconds sums sample durations', () {
      final profile = SttProfile(
        actorId: 'HAMLET',
        productionId: 'prod-1',
        samples: [
          TrainingSample(
            audioPath: '/a.m4a', transcript: 'Line 1',
            character: 'HAMLET', durationMs: 10000,
            recordedAt: DateTime.now(),
          ),
          TrainingSample(
            audioPath: '/b.m4a', transcript: 'Line 2',
            character: 'HAMLET', durationMs: 5000,
            recordedAt: DateTime.now(),
          ),
        ],
      );

      expect(profile.totalAudioSeconds, 15.0);
    });

    test('readiness scales from 0 to 1 based on 300s target', () {
      final empty = const SttProfile(
        actorId: 'X', productionId: 'p', samples: [],
      );
      expect(empty.readiness, 0.0);

      // 150s = 50% ready
      final half = SttProfile(
        actorId: 'X', productionId: 'p',
        samples: [
          TrainingSample(
            audioPath: '/a.m4a', transcript: 'L',
            character: 'X', durationMs: 150000,
            recordedAt: DateTime.now(),
          ),
        ],
      );
      expect(half.readiness, closeTo(0.5, 0.01));
    });

    test('readiness caps at 1.0', () {
      final profile = SttProfile(
        actorId: 'X', productionId: 'p',
        samples: [
          TrainingSample(
            audioPath: '/a.m4a', transcript: 'L',
            character: 'X', durationMs: 600000, // 10 minutes
            recordedAt: DateTime.now(),
          ),
        ],
      );
      expect(profile.readiness, 1.0);
    });

    test('hasEnoughData requires 60s minimum', () {
      final notEnough = SttProfile(
        actorId: 'X', productionId: 'p',
        samples: [
          TrainingSample(
            audioPath: '/a.m4a', transcript: 'L',
            character: 'X', durationMs: 30000, // 30s
            recordedAt: DateTime.now(),
          ),
        ],
      );
      expect(notEnough.hasEnoughData, isFalse);

      final enough = SttProfile(
        actorId: 'X', productionId: 'p',
        samples: [
          TrainingSample(
            audioPath: '/a.m4a', transcript: 'L',
            character: 'X', durationMs: 65000, // 65s
            recordedAt: DateTime.now(),
          ),
        ],
      );
      expect(enough.hasEnoughData, isTrue);
    });

    test('copyWith preserves unchanged fields', () {
      final profile = SttProfile(
        actorId: 'HAMLET',
        productionId: 'prod-1',
        samples: const [],
        status: SttAdaptationStatus.needsData,
      );

      final updated = profile.copyWith(
        status: SttAdaptationStatus.trained,
        adapterPath: '/adapters/hamlet.bin',
      );

      expect(updated.actorId, 'HAMLET');
      expect(updated.productionId, 'prod-1');
      expect(updated.status, SttAdaptationStatus.trained);
      expect(updated.adapterPath, '/adapters/hamlet.bin');
    });

    test('minAudioSeconds and recommendedAudioSeconds constants', () {
      expect(SttProfile.minAudioSeconds, 60.0);
      expect(SttProfile.recommendedAudioSeconds, 300.0);
    });
  });

  group('SttAdaptationService', () {
    late SttAdaptationService service;

    setUp(() {
      // Use the singleton but clear state by accessing it fresh
      service = SttAdaptationService.instance;
    });

    test('getActorProfile returns default for unknown actor', () {
      final profile = service.getActorProfile('unknown-prod', 'UNKNOWN');
      expect(profile.actorId, 'UNKNOWN');
      expect(profile.samples, isEmpty);
      expect(profile.status, SttAdaptationStatus.needsData);
    });

    test('getProductionProfile returns default for unknown production', () {
      final profile = service.getProductionProfile('unknown-prod');
      expect(profile.actorId, '_production');
      expect(profile.samples, isEmpty);
    });

    test('addSample populates both actor and production profiles', () {
      service.addSample(
        productionId: 'test-prod',
        actorId: 'ELIZABETH',
        audioPath: '/test/audio.m4a',
        transcript: 'What a fine assembly tonight.',
        durationMs: 5000,
      );

      final actorProfile = service.getActorProfile('test-prod', 'ELIZABETH');
      expect(actorProfile.samples.length, greaterThanOrEqualTo(1));

      final prodProfile = service.getProductionProfile('test-prod');
      expect(prodProfile.samples.length, greaterThanOrEqualTo(1));
    });

    test('recommendStrategy returns notReady with no data', () {
      final strategy = service.recommendStrategy('empty-prod');
      expect(strategy, TrainingStrategy.notReady);
    });

    test('getBestAdapter returns null when no adapter trained', () {
      final adapter = service.getBestAdapter('no-prod', 'NOBODY');
      expect(adapter, isNull);
    });
  });

  group('SttAdaptationStatus', () {
    test('has all expected values', () {
      expect(SttAdaptationStatus.values, containsAll([
        SttAdaptationStatus.needsData,
        SttAdaptationStatus.readyToTrain,
        SttAdaptationStatus.training,
        SttAdaptationStatus.trained,
        SttAdaptationStatus.failed,
      ]));
    });
  });

  group('TrainingStrategy', () {
    test('has all expected values', () {
      expect(TrainingStrategy.values, containsAll([
        TrainingStrategy.perActor,
        TrainingStrategy.perProduction,
        TrainingStrategy.notReady,
      ]));
    });
  });
}
