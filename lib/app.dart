import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/app_theme.dart';
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
import 'features/recording_studio/voice_profile_screen.dart';
import 'features/rehearsal/rehearsal_history_screen.dart';
import 'features/rehearsal/rehearsal_screen.dart';
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

GoRouter _buildRouter(Ref ref) => GoRouter(
  initialLocation: '/',
  redirect: (context, state) {
    final authed = ref.read(authGatePassedProvider);
    final onAuth = state.uri.toString() == '/auth';
    if (!authed && !onAuth) return '/auth';
    if (authed && onAuth) return '/';
    return null;
  },
  routes: [
    GoRoute(
      path: '/auth',
      builder: (context, state) => const AuthScreen(),
    ),
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/production',
      builder: (context, state) => const ProductionHubScreen(),
    ),
    GoRoute(
      path: '/import',
      builder: (context, state) => const ScriptImportScreen(),
    ),
    GoRoute(
      path: '/editor',
      builder: (context, state) => const ScriptEditorScreen(),
    ),
    GoRoute(
      path: '/characters',
      builder: (context, state) => const CharacterManagerScreen(),
    ),
    GoRoute(
      path: '/scenes',
      builder: (context, state) => const SceneEditorScreen(),
    ),
    GoRoute(
      path: '/cast',
      builder: (context, state) => const CastManagerScreen(),
    ),
    GoRoute(
      path: '/cast-setup',
      builder: (context, state) => const BulkCastSetupScreen(),
    ),
    GoRoute(
      path: '/join',
      builder: (context, state) => const JoinProductionScreen(),
    ),
    GoRoute(
      path: '/voice-config',
      builder: (context, state) => const VoiceConfigScreen(),
    ),
    GoRoute(
      path: '/record',
      builder: (context, state) => const RecordingCharacterScreen(),
    ),
    GoRoute(
      path: '/recording-studio',
      builder: (context, state) => const RecordingStudioScreen(),
    ),
    GoRoute(
      path: '/recordings',
      builder: (context, state) => const RecordingsBrowserScreen(),
    ),
    GoRoute(
      path: '/voice-profile',
      builder: (context, state) => const VoiceProfileScreen(),
    ),
    GoRoute(
      path: '/rehearsal',
      builder: (context, state) => const RehearsalScreen(),
    ),
    GoRoute(
      path: '/history',
      builder: (context, state) => const RehearsalHistoryScreen(),
    ),
    GoRoute(
      path: '/ai-models',
      builder: (context, state) => const AiModelsScreen(),
    ),
    GoRoute(
      path: '/kokoro-debug',
      builder: (context, state) => const KokoroDebugScreen(),
    ),
    GoRoute(
      path: '/parakeet-debug',
      builder: (context, state) => const ParakeetDebugScreen(),
    ),
    GoRoute(
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
      debugPrint('Deep link init failed: $e');
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
    final router = ref.watch(_routerProvider);
    return MaterialApp.router(
      title: 'CastCircle',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
