import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'features/home/home_screen.dart';
import 'features/script_import/script_import_screen.dart';
import 'features/script_editor/script_editor_screen.dart';
import 'features/script_editor/character_manager_screen.dart';
import 'features/script_editor/scene_editor_screen.dart';
import 'features/cast_manager/cast_manager_screen.dart';
import 'features/recording_studio/recording_character_screen.dart';
import 'features/recording_studio/recording_studio_screen.dart';
import 'features/rehearsal/scene_selector_screen.dart';
import 'features/rehearsal/rehearsal_history_screen.dart';
import 'features/rehearsal/rehearsal_screen.dart';
import 'features/settings/settings_screen.dart';

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
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
      path: '/record',
      builder: (context, state) => const RecordingCharacterScreen(),
    ),
    GoRoute(
      path: '/recording-studio',
      builder: (context, state) => const RecordingStudioScreen(),
    ),
    GoRoute(
      path: '/practice',
      builder: (context, state) => const SceneSelectorScreen(),
    ),
    GoRoute(
      path: '/rehearsal',
      builder: (context, state) => const RehearsalScreen(),
    ),
    GoRoute(
      path: '/history',
      builder: (context, state) => const RehearsalHistoryScreen(),
    ),
  ],
);

class LineGuideApp extends StatelessWidget {
  const LineGuideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'LineGuide',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppShell extends StatelessWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex(context),
        onDestinationSelected: (index) => _onNav(context, index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.theater_comedy_outlined),
            selectedIcon: Icon(Icons.theater_comedy),
            label: 'Productions',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  int _selectedIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    if (location.startsWith('/settings')) return 1;
    return 0;
  }

  void _onNav(BuildContext context, int index) {
    switch (index) {
      case 0:
        context.go('/');
        break;
      case 1:
        context.go('/settings');
        break;
    }
  }
}
