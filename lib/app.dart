import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'main.dart' show firebaseAvailable, rootScaffoldMessengerKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/app_theme.dart';
import 'data/services/debug_log_service.dart';
import 'data/services/deep_link_service.dart';
import 'data/services/supabase_service.dart';
import 'features/auth/auth_screen.dart';
import 'features/cast_manager/bulk_cast_setup_screen.dart';
import 'features/home/home_screen.dart';
import 'features/production_hub/production_hub_screen.dart';
import 'features/script_import/script_import_screen.dart';
import 'features/script_editor/script_editor_screen.dart';
import 'features/script_editor/character_manager_screen.dart';
import 'features/script_editor/scene_editor_screen.dart';
import 'features/cast_manager/cast_manager_screen.dart';
import 'features/cast_manager/voice_config_screen.dart';
import 'features/join/join_production_screen.dart';
import 'features/recording_studio/recording_character_screen.dart';
import 'features/recording_studio/recording_studio_screen.dart';
import 'features/recording_studio/recordings_browser_screen.dart';
import 'features/rehearsal/rehearsal_history_screen.dart';
import 'features/rehearsal/rehearsal_screen.dart';
import 'features/onboarding/model_setup_screen.dart';
import 'features/settings/ai_models_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/settings/kokoro_debug_screen.dart';
import 'features/settings/parakeet_debug_screen.dart';
import 'features/settings/debug_log_screen.dart';
import 'providers/production_providers.dart';

/// Whether the user has passed the auth gate (signed in or skipped).
/// Initialized from the persisted Supabase session or saved skip preference.
final authGatePassedProvider = StateProvider<bool>((ref) {
  final supabase = SupabaseService.instance;
  // If Supabase is initialized and has a valid session, restore login.
  if (supabase.isInitialized && supabase.isSignedIn) return true;
  return false;
});

/// Human-readable screen names for analytics.
const _screenNames = {
  '/': 'Home',
  '/auth': 'Sign In',
  '/production': 'Production Hub',
  '/import': 'Import Script',
  '/editor': 'Script Editor',
  '/characters': 'Characters',
  '/scenes': 'Scenes',
  '/cast': 'Cast Manager',
  '/cast-setup': 'Cast Setup',
  '/join': 'Join Production',
  '/voice-config': 'Voice Config',
  '/record': 'Record Lines',
  '/recording-studio': 'Recording Studio',
  '/recordings': 'Recordings',
  '/rehearsal': 'Rehearsal',
  '/history': 'History',
  '/settings': 'Settings',
  '/ai-models': 'AI Models',
  '/setup-models': 'AI Setup',
  '/debug-log': 'Debug Log',
};

GoRouter _buildRouter(Ref ref) => GoRouter(
  initialLocation: '/',
  observers: [
    AnalyticsRouteObserver(),
  ],
  redirect: (context, state) {
    final authed = ref.read(authGatePassedProvider);
    final onAuth = state.uri.toString() == '/auth';
    if (!authed && !onAuth) return '/auth';
    if (authed && onAuth) return '/';
    return null;
  },
  routes: [
    GoRoute(
      name: '/auth',
      path: '/auth',
      builder: (context, state) => const AuthScreen(),
    ),
    GoRoute(
      name: '/',
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      name: '/settings',
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      name: '/production',
      path: '/production',
      builder: (context, state) => const ProductionHubScreen(),
    ),
    GoRoute(
      name: '/import',
      path: '/import',
      builder: (context, state) => const ScriptImportScreen(),
    ),
    GoRoute(
      name: '/editor',
      path: '/editor',
      builder: (context, state) => const ScriptEditorScreen(),
    ),
    GoRoute(
      name: '/characters',
      path: '/characters',
      builder: (context, state) => const CharacterManagerScreen(),
    ),
    GoRoute(
      name: '/scenes',
      path: '/scenes',
      builder: (context, state) => const SceneEditorScreen(),
    ),
    GoRoute(
      name: '/cast',
      path: '/cast',
      builder: (context, state) => const CastManagerScreen(),
    ),
    GoRoute(
      name: '/cast-setup',
      path: '/cast-setup',
      builder: (context, state) => const BulkCastSetupScreen(),
    ),
    GoRoute(
      name: '/join',
      path: '/join',
      builder: (context, state) => const JoinProductionScreen(),
    ),
    GoRoute(
      name: '/voice-config',
      path: '/voice-config',
      builder: (context, state) => const VoiceConfigScreen(),
    ),
    GoRoute(
      name: '/record',
      path: '/record',
      builder: (context, state) => const RecordingCharacterScreen(),
    ),
    GoRoute(
      name: '/recording-studio',
      path: '/recording-studio',
      builder: (context, state) => const RecordingStudioScreen(),
    ),
    GoRoute(
      name: '/recordings',
      path: '/recordings',
      builder: (context, state) => const RecordingsBrowserScreen(),
    ),
    GoRoute(
      name: '/rehearsal',
      path: '/rehearsal',
      builder: (context, state) => const RehearsalScreen(),
    ),
    GoRoute(
      name: '/history',
      path: '/history',
      builder: (context, state) => const RehearsalHistoryScreen(),
    ),
    GoRoute(
      name: '/ai-models',
      path: '/ai-models',
      builder: (context, state) => const AiModelsScreen(),
    ),
    GoRoute(
      name: '/setup-models',
      path: '/setup-models',
      builder: (context, state) => const ModelSetupScreen(),
    ),
    GoRoute(
      name: '/kokoro-debug',
      path: '/kokoro-debug',
      builder: (context, state) => const KokoroDebugScreen(),
    ),
    GoRoute(
      name: '/parakeet-debug',
      path: '/parakeet-debug',
      builder: (context, state) => const ParakeetDebugScreen(),
    ),
    GoRoute(
      name: '/debug-log',
      path: '/debug-log',
      builder: (context, state) => const DebugLogScreen(),
    ),
  ],
);

final _routerProvider = Provider<GoRouter>((ref) => _buildRouter(ref));

class CastCircleApp extends ConsumerStatefulWidget {
  const CastCircleApp({super.key});

  @override
  ConsumerState<CastCircleApp> createState() => _CastCircleAppState();
}

class _CastCircleAppState extends ConsumerState<CastCircleApp> {
  StreamSubscription<PendingJoin>? _deepLinkSub;

  @override
  void initState() {
    super.initState();
    _setupDeepLinks();
  }

  Future<void> _setupDeepLinks() async {
    final deepLinks = DeepLinkService.instance;

    try {
      await deepLinks.init();
    } catch (e) {
      // Invite links silently doing nothing is undiagnosable without this.
      DebugLogService.instance
          .logError(LogCategory.error, 'Deep link init failed', e);
    }

    // Handle initial link (cold start)
    if (deepLinks.latestPendingJoin != null) {
      _handlePendingJoin(deepLinks.latestPendingJoin!);
    }

    // Handle links while running
    _deepLinkSub = deepLinks.onPendingJoin.listen(_handlePendingJoin);
  }

  void _handlePendingJoin(PendingJoin pending) {
    ref.read(pendingJoinProvider.notifier).state = pending;
    final router = ref.read(_routerProvider);
    // If already authed, navigate to join. Otherwise auth screen will pick it up.
    if (ref.read(authGatePassedProvider)) {
      router.push('/join');
    }
    // If not authed, the auth screen will see the pending join and
    // show a banner, then navigate after sign-in.
  }

  @override
  void dispose() {
    _deepLinkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Whenever the current production changes — whether opened from home,
    // joined via a code/link, or switched — (re)start recording sync from this
    // app-root ref (stable for the app's lifetime, so the global sync callbacks
    // never capture a disposed widget ref). Loads this production's local
    // recordings and clears the previous production's downloaded cache first.
    ref.listen(currentProductionProvider, (prev, next) {
      if (next == null || next.id == prev?.id) return;
      ref.read(understudyRecordingsProvider.notifier).clear();
      // Load this production's local recordings BEFORE the cloud sync runs, or
      // the sync mistakes not-yet-loaded recordings for missing ones (re-
      // downloading them and skipping their uploads).
      unawaited(() async {
        try {
          await ref
              .read(recordingsProvider.notifier)
              .loadForProduction(next.id);
        } catch (e) {
          DebugLogService.instance.logError(LogCategory.error,
              'Loading local recordings for ${next.id} failed', e);
        }
        launchRecordingSync(ref, next.id);
      }());
    });

    final router = ref.watch(_routerProvider);
    return MaterialApp.router(
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      title: 'CastCircle',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Logs screen views to Firebase Analytics with human-readable names.
///
/// `logScreenView` means "the user is now on this screen" — it sets the screen
/// that subsequent events and engagement time are attributed to. So a pop logs
/// the route being *returned to*, never the one being left: logging the popped
/// route would count every page twice (once on push, once on pop) and leave
/// attribution pointing at a screen the user already abandoned.
///
/// Only [PageRoute]s count. Dialogs and modal sheets push routes too, and
/// without this filter closing one would re-log its host screen on every
/// dismissal. Filtering on the route type rather than relying on dialog routes
/// having a null `settings.name` keeps that true even if a dialog is ever given
/// explicit `routeSettings`.
class AnalyticsRouteObserver extends NavigatorObserver {
  /// [logScreenView] is the sink for resolved screen names; it defaults to
  /// Firebase and is overridden in tests, which is the only way to assert the
  /// push/pop bookkeeping without a live Firebase instance.
  AnalyticsRouteObserver({void Function(String screenName)? logScreenView})
    : _logScreenView = logScreenView ?? _sendToFirebase;

  final void Function(String screenName) _logScreenView;

  static void _sendToFirebase(String screenName) {
    if (!firebaseAvailable) return;
    FirebaseAnalytics.instance.logScreenView(screenName: screenName);
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    if (route is PageRoute) _logScreen(route);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (route is PageRoute && previousRoute is PageRoute) {
      _logScreen(previousRoute);
    }
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    if (newRoute is PageRoute) _logScreen(newRoute);
  }

  void _logScreen(Route route) {
    final path = route.settings.name;
    if (path == null) return;
    _logScreenView(_screenNames[path] ?? path);
  }
}
