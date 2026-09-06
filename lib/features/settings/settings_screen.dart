import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app.dart';
import '../../core/constants.dart';
import '../../core/responsive.dart';
import '../../core/toast.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/tts_service.dart';
import '../../main.dart';
import '../../providers/production_providers.dart';
import '../auth/auth_screen.dart';

const _rehearsalSettingsKey = 'rehearsal_settings_v1';

class RehearsalSettingController<T> extends StateNotifier<T> {
  RehearsalSettingController(
    this._preferences,
    this._settingKey,
    T initialState, {
    Object? Function(T value)? encode,
  }) : _encode = encode ?? ((value) => value),
       super(initialState);

  final SharedPreferences _preferences;
  final String _settingKey;
  final Object? Function(T value) _encode;

  @override
  set state(T value) {
    if (value == super.state) return;
    super.state = value;

    final settings = _readRehearsalSettings(_preferences);
    settings[_settingKey] = _encode(value);
    unawaited(
      _preferences
          .setString(
            _rehearsalSettingsKey,
            jsonEncode({'version': 1, 'settings': settings}),
          )
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              DebugLogService.instance.logError(
                LogCategory.general,
                'Could not save rehearsal setting $_settingKey',
                error,
                stack,
              );
            },
          ),
    );
  }
}

Map<String, dynamic> _readRehearsalSettings(SharedPreferences preferences) {
  final raw = preferences.getString(_rehearsalSettingsKey);
  if (raw == null) return {};
  try {
    final record = jsonDecode(raw);
    if (record is! Map<String, dynamic> || record['version'] != 1) return {};
    final settings = record['settings'];
    return settings is Map<String, dynamic>
        ? Map<String, dynamic>.from(settings)
        : {};
  } catch (error, stack) {
    DebugLogService.instance.logError(
      LogCategory.general,
      'Could not read rehearsal settings',
      error,
      stack,
    );
    return {};
  }
}

T _settingValue<T>(Object? value, T fallback) {
  if (fallback is int && value is num) return value.toInt() as T;
  if (fallback is double && value is num) return value.toDouble() as T;
  return value is T ? value : fallback;
}

StateNotifierProvider<RehearsalSettingController<T>, T>
_persistedRehearsalSetting<T>(
  String key,
  T fallback, {
  T Function(Object? value)? decode,
  Object? Function(T value)? encode,
}) {
  return StateNotifierProvider<RehearsalSettingController<T>, T>((ref) {
    final preferences = ref.watch(sharedPreferencesProvider);
    final saved = _readRehearsalSettings(preferences)[key];
    return RehearsalSettingController<T>(
      preferences,
      key,
      decode?.call(saved) ?? _settingValue(saved, fallback),
      encode: encode,
    );
  });
}

final jumpBackLinesProvider = _persistedRehearsalSetting(
  'jumpBackLines',
  AppConstants.defaultJumpBackLines,
);
final playbackSpeedProvider = _persistedRehearsalSetting(
  'playbackSpeed',
  AppConstants.defaultPlaybackSpeed,
);
final matchThresholdProvider = _persistedRehearsalSetting(
  'matchThreshold',
  AppConstants.defaultMatchThreshold,
);

/// Silence (ms) the actor must hold after a confirmed match before the
/// rehearsal auto-advances to the next line.
final rehearsalAdvanceSilenceMsProvider = _persistedRehearsalSetting(
  'advanceSilenceMs',
  500,
);

enum JumpBackTrigger { shake, doubleTap, swipeLeft, keyword }

final jumpBackTriggerProvider = _persistedRehearsalSetting(
  'jumpBackTrigger',
  JumpBackTrigger.doubleTap,
  decode: (value) =>
      JumpBackTrigger.values
          .where((trigger) => trigger.name == value)
          .firstOrNull ??
      JumpBackTrigger.doubleTap,
  encode: (value) => value.name,
);

/// Speed multiplier used when fast mode is active.
final fastModeSpeedProvider = _persistedRehearsalSetting(
  'fastModeSpeed',
  AppConstants.defaultFastModeSpeed,
);

/// Delay between lines in normal mode (milliseconds).
final lineDelayProvider = _persistedRehearsalSetting(
  'lineDelay',
  AppConstants.defaultLineDelay,
);

/// Delay between lines in fast mode (milliseconds).
final fastModeLineDelayProvider = _persistedRehearsalSetting(
  'fastModeLineDelay',
  AppConstants.defaultFastModeLineDelay,
);

/// When true, fast mode is active — TTS plays faster with shorter gaps.
final fastModeEnabledProvider = _persistedRehearsalSetting(
  'fastModeEnabled',
  false,
);

/// When true, fall back to understudy recordings when the primary actor
/// hasn't recorded a line.
final understudyFallbackProvider = _persistedRehearsalSetting(
  'understudyFallback',
  true,
);

/// Rehearsal script font size (adjustable via +/- in rehearsal top bar).
final rehearsalFontSizeProvider = _persistedRehearsalSetting('fontSize', 18.0);

// Memoized: the version can't change while the app runs, and a fresh
// PackageInfo future per rebuild made the FutureBuilder flicker through its
// loading state on every settings rebuild.
Future<String>? _versionFuture;

Future<String> _getVersionString() => _versionFuture ??= () async {
  try {
    final info = await PackageInfo.fromPlatform();
    return 'Version ${info.version} (${info.buildNumber})';
  } catch (_) {
    return 'Version unavailable';
  }
}();

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jumpBackLines = ref.watch(jumpBackLinesProvider);
    final playbackSpeed = ref.watch(playbackSpeedProvider);
    final matchThreshold = ref.watch(matchThresholdProvider);
    final jumpBackTrigger = ref.watch(jumpBackTriggerProvider);
    final understudyFallback = ref.watch(understudyFallbackProvider);
    final fastModeSpeed = ref.watch(fastModeSpeedProvider);
    final lineDelay = ref.watch(lineDelayProvider);
    final fastModeLineDelay = ref.watch(fastModeLineDelayProvider);
    final advanceSilenceMs = ref.watch(rehearsalAdvanceSilenceMsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              GoRouter.of(context).go('/');
            }
          },
        ),
        title: const Text('Settings'),
      ),
      body: ContentConstraint(
        maxWidth: 640,
        child: ListView(
          children: [
            _sectionHeader(context, 'Rehearsal'),
            ListTile(
              title: const Text('Jump-back lines'),
              subtitle: Text('Go back $jumpBackLines lines when triggered'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: jumpBackLines > 1
                        ? () => ref.read(jumpBackLinesProvider.notifier).state--
                        : null,
                  ),
                  Text(
                    '$jumpBackLines',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: jumpBackLines < 20
                        ? () => ref.read(jumpBackLinesProvider.notifier).state++
                        : null,
                  ),
                ],
              ),
            ),
            ListTile(
              title: const Text('Jump-back trigger'),
              subtitle: Text(jumpBackTrigger.name),
              trailing: DropdownButton<JumpBackTrigger>(
                value: jumpBackTrigger,
                onChanged: (v) {
                  if (v != null) {
                    ref.read(jumpBackTriggerProvider.notifier).state = v;
                  }
                },
                items: JumpBackTrigger.values.map((t) {
                  return DropdownMenuItem(value: t, child: Text(t.name));
                }).toList(),
              ),
            ),
            ListTile(
              title: const Text('Playback speed'),
              subtitle: Slider(
                value: playbackSpeed,
                min: 0.5,
                max: 2.0,
                divisions: 6,
                label: '${playbackSpeed}x',
                onChanged: (v) =>
                    ref.read(playbackSpeedProvider.notifier).state = v,
              ),
              trailing: Text('${playbackSpeed}x'),
            ),
            ListTile(
              title: const Text('Line delay'),
              subtitle: Slider(
                value: lineDelay.toDouble(),
                min: 0,
                max: 2000,
                divisions: 20,
                label: '${lineDelay}ms',
                onChanged: (v) =>
                    ref.read(lineDelayProvider.notifier).state = v.round(),
              ),
              trailing: Text('${lineDelay}ms'),
            ),
            _sectionHeader(context, 'Fast Mode'),
            ListTile(
              title: const Text('Fast mode speed'),
              subtitle: Slider(
                value: fastModeSpeed,
                min: 1.0,
                max: 3.0,
                divisions: 8,
                label: '${fastModeSpeed}x',
                onChanged: (v) =>
                    ref.read(fastModeSpeedProvider.notifier).state = v,
              ),
              trailing: Text('${fastModeSpeed}x'),
            ),
            ListTile(
              title: const Text('Fast mode line delay'),
              subtitle: Slider(
                value: fastModeLineDelay.toDouble(),
                min: 0,
                max: 500,
                divisions: 10,
                label: '${fastModeLineDelay}ms',
                onChanged: (v) =>
                    ref.read(fastModeLineDelayProvider.notifier).state = v
                        .round(),
              ),
              trailing: Text('${fastModeLineDelay}ms'),
            ),
            _sectionHeader(context, 'Speech Recognition'),
            ListTile(
              title: const Text('Match threshold'),
              subtitle: Slider(
                value: matchThreshold.toDouble(),
                min: 30,
                max: 100,
                divisions: 14,
                label: '$matchThreshold%',
                onChanged: (v) =>
                    ref.read(matchThresholdProvider.notifier).state = v.round(),
              ),
              trailing: Text('$matchThreshold%'),
            ),
            ListTile(
              title: const Text('Pause before next line'),
              subtitle: Slider(
                value: advanceSilenceMs.toDouble(),
                min: 200,
                max: 1000,
                divisions: 16,
                label: '${advanceSilenceMs}ms',
                onChanged: (v) =>
                    ref.read(rehearsalAdvanceSilenceMsProvider.notifier).state =
                        v.round(),
              ),
              trailing: Text('${advanceSilenceMs}ms'),
            ),
            _sectionHeader(context, 'AI & Voice'),
            SwitchListTile(
              title: const Text('Understudy fallback'),
              subtitle: const Text(
                'Use understudy recordings when primary actor hasn\'t recorded',
              ),
              value: understudyFallback,
              onChanged: (v) =>
                  ref.read(understudyFallbackProvider.notifier).state = v,
              secondary: const Icon(Icons.people_outline),
            ),
            if (Platform.isAndroid || Platform.isIOS)
              ValueListenableBuilder<bool>(
                valueListenable: TtsService.instance.kokoroLoadedListenable,
                builder: (context, loaded, _) => ListTile(
                  title: const Text('Kokoro TTS (on-device)'),
                  subtitle: Text(
                    loaded
                        ? 'Loaded — using on-device inference'
                        : 'Not loaded — using system TTS',
                  ),
                  leading: Icon(
                    loaded ? Icons.record_voice_over : Icons.voice_over_off,
                    color: loaded ? Colors.green : Colors.orange,
                  ),
                ),
              )
            else
              const ListTile(
                title: Text('System text-to-speech'),
                subtitle: Text('Using voices provided by the operating system'),
                leading: Icon(Icons.record_voice_over, color: Colors.green),
              ),
            _sectionHeader(context, 'AI Models'),
            ListTile(
              leading: const Icon(Icons.smart_toy),
              title: const Text('AI Models'),
              subtitle: Text(
                Platform.isAndroid || Platform.isIOS
                    ? 'Download on-device AI models'
                    : 'System voices — no model download required',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/ai-models'),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report),
              title: const Text('Kokoro Debug'),
              subtitle: const Text('Test TTS engine and view diagnostics'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/kokoro-debug'),
            ),
            ListTile(
              leading: const Icon(Icons.terminal),
              title: const Text('Debug Log'),
              subtitle: const Text(
                'View system logs, memory usage, and errors',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/debug-log'),
            ),
            _sectionHeader(context, 'Web Editor'),
            ListTile(
              leading: const Icon(Icons.language),
              title: const Text('Edit on the Web'),
              subtitle: const Text('Open the script editor in your browser'),
              trailing: const Icon(Icons.share),
              onTap: () {
                final email = SupabaseService.instance.currentUser?.email ?? '';
                final text =
                    'Edit your CastCircle script on the web:\n'
                    'https://castcircle-app.web.app'
                    '${email.isNotEmpty ? '\n\nSign in with: $email' : ''}';
                Share.share(text, subject: 'CastCircle Web Editor');
              },
            ),
            _sectionHeader(context, 'Account'),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign Out'),
              subtitle: const Text('Sign out and return to the login screen'),
              onTap: () => _signOut(context, ref),
            ),
            _sectionHeader(context, 'About'),
            FutureBuilder<String>(
              future: _getVersionString(),
              builder: (context, snap) => ListTile(
                title: const Text('CastCircle'),
                subtitle: Text(snap.data ?? 'Version unavailable'),
                leading: const Icon(Icons.theater_comedy),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    // Capture provider state before the first async gap. The settings route can
    // be popped while remote sign-out is in flight, disposing its WidgetRef.
    final preferences = ref.read(sharedPreferencesProvider);
    final authState = ref.read(authStateProvider.notifier);
    final authGate = ref.read(authGatePassedProvider.notifier);

    // Start account teardown while the WidgetRef is definitely alive. The
    // coordinator captures all providers synchronously before its first await;
    // awaiting its completion below therefore cannot touch a disposed ref.
    final accountTeardown = teardownAccountState(ref);

    // Clear persisted skip-auth flag. Awaited: fire-and-forget raced the
    // navigation, and an app kill before the flush meant next launch still
    // read auth_skipped=true and skipped straight past sign-in.
    await preferences.remove('auth_skipped');

    // Sign out of Supabase if there's an active session.
    if (SupabaseService.instance.isInitialized &&
        SupabaseService.instance.isSignedIn) {
      try {
        await SupabaseService.instance.signOut();
      } catch (e) {
        // An AuthException here used to be an unhandled async error: the local
        // state was never cleared, the session token stayed on the device, and
        // the user was told nothing. Clear locally and say the session may
        // still be live on this device.
        DebugLogService.instance.logError(
          LogCategory.error,
          'Sign-out failed',
          e,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showAutoToast(
            SnackBar(
              content: Text(
                'Signed out on this device, but the server '
                "couldn't be reached ($e). Sign in again to be sure the "
                'session is closed.',
              ),
              duration: const Duration(seconds: 8),
            ),
          );
        }
      }
    }

    try {
      await accountTeardown;
    } catch (error, stack) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'Account teardown did not fully complete',
        error,
        stack,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
              'Signed out, but some local cached files could not be cleared.',
            ),
          ),
        );
      }
    }

    // Reset in-memory auth state without reading a disposed WidgetRef.
    authState.state = false;
    authGate.state = false;

    if (context.mounted) {
      context.go('/auth');
    }
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
