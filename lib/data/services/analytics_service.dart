import 'package:firebase_analytics/firebase_analytics.dart';

import '../../main.dart';

/// Lightweight wrapper for Firebase Analytics custom events.
class AnalyticsService {
  AnalyticsService._();
  static final instance = AnalyticsService._();

  FirebaseAnalytics? get _analytics =>
      firebaseAvailable ? FirebaseAnalytics.instance : null;

  void logScriptImported({
    required String format,
    required int lineCount,
    required int characterCount,
  }) {
    _analytics?.logEvent(
      name: 'script_imported',
      parameters: {
        'format': format,
        'line_count': lineCount,
        'character_count': characterCount,
      },
    );
  }

  void logRehearsalStarted({
    required String character,
    required String mode,
    int? sceneCount,
  }) {
    _analytics?.logEvent(
      name: 'rehearsal_started',
      parameters: {
        'character': character,
        'mode': mode,
        if (sceneCount != null) 'scene_count': sceneCount,
      },
    );
  }

  void logProductionCreated() {
    _analytics?.logEvent(name: 'production_created');
  }

  void logProductionJoined() {
    _analytics?.logEvent(name: 'production_joined');
  }

  /// The bundled demo was opened — the clearest signal of whether the
  /// walkthrough's call to action actually lands.
  void logDemoOpened() {
    _analytics?.logEvent(name: 'demo_production_opened');
  }

  void logModelDownloaded({required String modelId}) {
    _analytics?.logEvent(
      name: 'model_downloaded',
      parameters: {'model_id': modelId},
    );
  }

  void logScriptEdited({required String action, int? lineCount}) {
    _analytics?.logEvent(
      name: 'script_edited',
      parameters: {
        'action': action,
        if (lineCount != null) 'line_count': lineCount,
      },
    );
  }

  void logCastUpdated({required int memberCount}) {
    _analytics?.logEvent(
      name: 'cast_updated',
      parameters: {'member_count': memberCount},
    );
  }

  void logVoiceConfigured({required String character, required String voice}) {
    _analytics?.logEvent(
      name: 'voice_configured',
      parameters: {'character': character, 'voice': voice},
    );
  }

  void logRecordingCreated({required String character}) {
    _analytics?.logEvent(
      name: 'recording_created',
      parameters: {'character': character},
    );
  }

  void logCloudSynced({required String direction}) {
    _analytics?.logEvent(
      name: 'cloud_synced',
      parameters: {'direction': direction},
    );
  }
}
