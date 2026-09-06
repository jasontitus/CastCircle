import 'dart:async';
import 'dart:io';

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
import 'data/services/supabase_service.dart';
import 'data/services/model_download_service.dart';
import 'data/services/tts_service.dart';
import 'data/services/stt_service.dart';
import 'data/services/stt_adaptation_service.dart';
import 'data/services/debug_log_service.dart';
import 'data/services/frame_stats_service.dart';
import 'data/services/sync_queue.dart';
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

/// Whether Firebase was successfully initialized.
bool firebaseAvailable = false;

/// Root ScaffoldMessenger so background services (sync queue, cloud sync)
/// can surface failures as SnackBars without a widget context.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // SharedPreferences backs providers read during the first build, so it is
  // the only startup dependency kept ahead of the widget tree.
  final prefs = await SharedPreferences.getInstance();
  final hasSkippedAuth = prefs.getBool('auth_skipped') ?? false;

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (hasSkippedAuth) authGatePassedProvider.overrideWith((ref) => true),
      ],
      child: const CastCircleApp(),
    ),
  );

  // Everything below is best-effort background startup. Slow cloud, telemetry,
  // logging, or ML setup must never hold the first frame.
  FrameStatsService.instance.install();
  SttAdaptationService.instance.initializeLifecycle();
  SyncQueue.instance.start();
  unawaited(_initializeDebugLogging());
  unawaited(_initializeFirebase());
  unawaited(_initializeSupabase());
  unawaited(_initializeMlServices());
}

Future<void> _initializeDebugLogging() => _runBackgroundStep(
  'Debug logging initialization',
  DebugLogService.instance.init,
);

Future<void> _initializeSupabase() async {
  const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://vngpbmqymdaxxnvqptsk.supabase.co',
  );
  const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI',
  );
  await SupabaseService.instance.init(
    url: supabaseUrl,
    publishableKey: supabaseAnonKey,
  );
}

Future<void> _initializeFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseAvailable = true;
    DebugLogService.instance.log(
      LogCategory.firebase,
      'Firebase initialized OK',
    );
  } catch (e, stack) {
    DebugLogService.instance.logError(
      LogCategory.firebase,
      'Firebase initialization unavailable on ${Platform.operatingSystem}',
      e,
      stack,
    );
    debugPrint(
      'Firebase initialization failed on ${Platform.operatingSystem}: $e',
    );
    return;
  }

  _installFirebaseErrorHandlers();

  await _runBackgroundStep('Crashlytics diagnostics', () async {
    final crashlytics = FirebaseCrashlytics.instance;
    final didCrash = await crashlytics.didCrashOnPreviousExecution();
    DebugLogService.instance.log(
      LogCategory.firebase,
      'Crashed on previous execution: $didCrash',
    );
    DebugLogService.instance.log(
      LogCategory.firebase,
      'Crashlytics collection enabled: '
      '${crashlytics.isCrashlyticsCollectionEnabled}',
    );
  });
  await _runBackgroundStep(
    'Crashlytics collection setup',
    () => FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true),
  );
  await _runBackgroundStep(
    'Firebase Performance collection setup',
    () => FirebasePerformance.instance.setPerformanceCollectionEnabled(true),
  );
  await _runBackgroundStep(
    'Firebase Analytics collection setup',
    () => FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true),
  );
  AnalyticsRouteObserver.flushPendingScreenView();
}

void _installFirebaseErrorHandlers() {
  final previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    DebugLogService.instance.log(
      LogCategory.firebase,
      'FlutterError caught: ${details.exceptionAsString()}',
    );
    if (previousFlutterErrorHandler != null) {
      previousFlutterErrorHandler(details);
    } else {
      FlutterError.presentError(details);
    }
    unawaited(
      FirebaseCrashlytics.instance.recordFlutterFatalError(details).catchError((
        Object error,
      ) {
        DebugLogService.instance.logError(
          LogCategory.firebase,
          'Crashlytics failed to record FlutterError',
          error,
        );
      }),
    );
  };

  final previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    DebugLogService.instance.logError(
      LogCategory.firebase,
      'Unhandled asynchronous error',
      error,
      stack,
    );
    FlutterError.presentError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'PlatformDispatcher',
      ),
    );
    unawaited(
      FirebaseCrashlytics.instance
          .recordError(error, stack, fatal: false)
          .catchError((Object recordingError) {
            DebugLogService.instance.logError(
              LogCategory.firebase,
              'Crashlytics failed to record asynchronous error',
              recordingError,
            );
          }),
    );
    return previousPlatformErrorHandler?.call(error, stack) ?? true;
  };
}

Future<void> _initializeMlServices() async {
  await _runBackgroundStep('TTS initialization', TtsService.instance.init);
  await _runBackgroundStep('STT initialization', SttService.instance.init);

  if (!Platform.isIOS) return;

  try {
    final prefs = await SharedPreferences.getInstance();
    final consented = prefs.getBool('models_auto_download_ok') ?? false;
    final modelService = ModelDownloadService.instance;
    await modelService.refreshDownloadedStatus();
    if (!consented || await modelService.isKokoroReady()) return;

    debugPrint('Auto-downloading Kokoro TTS models...');
    for (final model in ModelDownloadService.availableModels) {
      if (model.subdir != 'kokoro_mlx') continue;
      await _runBackgroundStep(
        'Kokoro model download (${model.id})',
        () => modelService.download(model),
      );
    }
  } catch (e, stack) {
    DebugLogService.instance.logError(
      LogCategory.ai,
      'Kokoro model startup check failed',
      e,
      stack,
    );
  }
}

Future<void> _runBackgroundStep(
  String label,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e, stack) {
    DebugLogService.instance.logError(LogCategory.error, label, e, stack);
  }
}
