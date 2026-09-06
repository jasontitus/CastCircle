import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'main.dart'
    show firebaseAvailable, rootScaffoldMessengerKey, sharedPreferencesProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
import 'features/onboarding/welcome_screen.dart';
import 'features/settings/ai_models_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/settings/kokoro_debug_screen.dart';
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

/// Whether Supabase is initialized and ready for authenticated cloud work.
///
/// This is reactive because initialization may complete after the app shell
/// and persisted auth gate have already been built.
final supabaseReadyProvider = StateProvider<bool>(
  (ref) => SupabaseService.instance.isInitialized,
);

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
  '/kokoro-debug': 'Kokoro Debug',
};

GoRouter _buildRouter(Ref ref) => GoRouter(
  initialLocation: '/',
  observers: [AnalyticsRouteObserver()],
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
      name: '/welcome',
      path: '/welcome',
      builder: (context, state) => const WelcomeScreen(),
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
  StreamSubscription<AuthState>? _authSub;
  String? _routedUserId;
  String? _restoringUserId;
  String? _restoredUserId;
  int _productionEpoch = 0;

  @override
  void initState() {
    super.initState();
    _setupDeepLinks();
    unawaited(_watchSupabaseAuth());
  }

  Future<void> _watchSupabaseAuth() async {
    final supabase = SupabaseService.instance;
    final initialized = await supabase.initializationResult;
    if (!mounted) return;

    ref.read(supabaseReadyProvider.notifier).state = initialized;
    if (!initialized) {
      await _applyAccountIdentity(null);
      return;
    }

    // Subscribe before sampling currentUser so an auth event cannot slip
    // between the restored-session check and listener installation.
    _authSub = supabase.authStateChanges.listen((state) {
      unawaited(_applyAccountIdentity(state.session?.user.id));
    });
    await _applyAccountIdentity(supabase.currentUser?.id);
  }

  Future<void> _applyAccountIdentity(String? userId) async {
    try {
      await setAccountIdentity(ref, userId);
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'Switching local account data failed',
        e,
        stack,
      );
      return;
    }

    if (!mounted || SupabaseService.instance.currentUser?.id != userId) return;
    ref.read(authStateProvider.notifier).state = userId != null;
    if (userId == null) {
      _routedUserId = null;
      _restoredUserId = null;
      return;
    }
    await _handleSignedIn(userId);
  }

  Future<void> _handleSignedIn(String userId) async {
    if (!mounted) return;

    // Auth streams emit again for token refreshes. Only the first transition
    // for this user may consume/navigation-route a pending invite.
    if (_routedUserId != userId) {
      _routedUserId = userId;
      _passAuthGate();
    }

    if (_restoredUserId == userId || _restoringUserId == userId) return;
    _restoringUserId = userId;
    try {
      // A real session supersedes guest mode. Leaving this preference set
      // makes a later failed initialization silently reopen the guest gate.
      await ref.read(sharedPreferencesProvider).remove('auth_skipped');
      if (!mounted || SupabaseService.instance.currentUser?.id != userId) {
        return;
      }
      await restoreCloudProductions(ref);
      if (mounted && SupabaseService.instance.currentUser?.id == userId) {
        _restoredUserId = userId;
      }
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Restoring cloud productions after sign-in failed',
        e,
        stack,
      );
    } finally {
      if (_restoringUserId == userId) _restoringUserId = null;
    }
  }

  void _passAuthGate() {
    if (!mounted) return;

    final wasPassed = ref.read(authGatePassedProvider);
    if (!wasPassed) {
      ref.read(authGatePassedProvider.notifier).state = true;
    }

    final router = ref.read(_routerProvider);
    if (ref.read(pendingJoinProvider) != null) {
      // Restored sessions and email-confirmation auth events do not pass
      // through AuthScreen's submit handler, but must honor the same pending
      // deep link instead of falling back to Home.
      router.go('/join');
    } else if (!wasPassed) {
      // GoRouter's redirect reads Riverpod state, so explicitly refresh it
      // when late Supabase initialization restores a persisted session.
      router.refresh();
    }
  }

  Future<void> _setupDeepLinks() async {
    final deepLinks = DeepLinkService.instance;

    try {
      await deepLinks.init();
    } catch (e) {
      // Invite links silently doing nothing is undiagnosable without this.
      DebugLogService.instance.logError(
        LogCategory.error,
        'Deep link init failed',
        e,
      );
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
    _authSub?.cancel();
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
      if (next?.id == prev?.id) return;

      final epoch = ++_productionEpoch;
      // Invalidate callbacks and work from the previous production
      // immediately; waiting for the new production's Drift load would leave
      // the old run active throughout a slow database read.
      final runToken = activateRecordingProduction(next?.id);
      if (next == null) return;

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
          DebugLogService.instance.logError(
            LogCategory.error,
            'Loading local recordings for ${next.id} failed',
            e,
          );
          return;
        }

        // A rapid switch may finish an older database read after the newer
        // selection. Only the latest transition may install global callbacks
        // or launch reconciliation for its production.
        if (!mounted ||
            epoch != _productionEpoch ||
            ref.read(currentProductionProvider)?.id != next.id) {
          return;
        }
        launchRecordingSync(ref, next.id, runToken);
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

  static String? _pendingScreenName;

  static void _sendToFirebase(String screenName) {
    if (!firebaseAvailable) {
      // Keep the latest route: if auth restoration redirects before Firebase
      // is ready, analytics should replay the screen the user actually sees.
      _pendingScreenName = screenName;
      return;
    }
    // A route observed after Firebase became available supersedes anything
    // buffered during startup; flushing the old route later would regress the
    // analytics screen attribution.
    _pendingScreenName = null;
    _recordScreenView(screenName);
  }

  /// Replay the latest route observed during asynchronous Firebase startup.
  static void flushPendingScreenView() {
    if (!firebaseAvailable) return;
    final screenName = _pendingScreenName;
    if (screenName == null) return;
    _pendingScreenName = null;
    _recordScreenView(screenName);
  }

  static void _recordScreenView(String screenName) {
    unawaited(
      FirebaseAnalytics.instance
          .logScreenView(screenName: screenName)
          .catchError((Object error) {
            _pendingScreenName = screenName;
            DebugLogService.instance.logError(
              LogCategory.firebase,
              'Firebase screen-view logging failed',
              error,
            );
          }),
    );
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
