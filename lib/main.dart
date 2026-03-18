import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/database/app_database.dart';
import 'data/services/deep_link_service.dart';
import 'data/services/supabase_service.dart';
import 'data/services/model_download_service.dart';
import 'data/services/tts_service.dart';
import 'data/services/stt_service.dart';
import 'data/services/debug_log_service.dart';
import 'firebase_options.dart';

/// Global database instance, provided via Riverpod.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

/// SharedPreferences instance, initialized before runApp.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('Must be overridden in ProviderScope');
});

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Crashlytics: catch all Flutter errors
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

  // Crashlytics: catch async errors not caught by Flutter
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  // Performance monitoring
  FirebasePerformance.instance.setPerformanceCollectionEnabled(true);

  // Analytics
  FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true);

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL',
      defaultValue: 'https://vngpbmqymdaxxnvqptsk.supabase.co');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY',
      defaultValue: 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI');

  try {
    await SupabaseService.instance.init(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  } catch (e) {
    debugPrint('Supabase init failed: $e');
  }

  // Initialize debug logging first so other services can use it
  await DebugLogService.instance.init();

  // Deep link service is initialized lazily in CastCircleApp to avoid
  // blocking app startup if app_links has issues on cold start.

  // Initialize ML services (non-blocking — will use fallbacks if models not ready)
  Future.microtask(() async {
    await TtsService.instance.init();
    await SttService.instance.init();

    // Auto-download Kokoro TTS models if not already present
    final modelService = ModelDownloadService.instance;
    await modelService.refreshDownloadedStatus();
    if (!await modelService.isKokoroReady()) {
      debugPrint('Auto-downloading Kokoro TTS models...');
      for (final model in ModelDownloadService.availableModels) {
        if (model.subdir == 'kokoro_mlx') {
          await modelService.download(model);
        }
      }
    }
  });

  final prefs = await SharedPreferences.getInstance();

  // Determine if user already has a persisted session (Supabase login or
  // previously skipped auth). This lets the app skip the login screen on
  // subsequent launches — users only need to authenticate once per device.
  final hasPersistedSession =
      (SupabaseService.instance.isInitialized &&
          SupabaseService.instance.isSignedIn) ||
      (prefs.getBool('auth_skipped') ?? false);

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (hasPersistedSession)
          authGatePassedProvider.overrideWith((ref) => true),
      ],
      child: const CastCircleApp(),
    ),
  );
}
