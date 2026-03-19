import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/constants.dart';
import '../../data/services/model_download_service.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/tts_service.dart';
import '../../main.dart';
import '../auth/auth_screen.dart';

// Settings providers
final jumpBackLinesProvider = StateProvider<int>(
    (ref) => AppConstants.defaultJumpBackLines);
final playbackSpeedProvider = StateProvider<double>(
    (ref) => AppConstants.defaultPlaybackSpeed);
final matchThresholdProvider = StateProvider<int>(
    (ref) => AppConstants.defaultMatchThreshold);

enum JumpBackTrigger { shake, doubleTap, swipeLeft, keyword }

final jumpBackTriggerProvider = StateProvider<JumpBackTrigger>(
    (ref) => JumpBackTrigger.doubleTap);

/// Speed multiplier used when fast mode is active.
final fastModeSpeedProvider = StateProvider<double>(
    (ref) => AppConstants.defaultFastModeSpeed);

/// Delay between lines in normal mode (milliseconds).
final lineDelayProvider = StateProvider<int>(
    (ref) => AppConstants.defaultLineDelay);

/// Delay between lines in fast mode (milliseconds).
final fastModeLineDelayProvider = StateProvider<int>(
    (ref) => AppConstants.defaultFastModeLineDelay);

/// When true, fast mode is active — TTS plays faster with shorter gaps.
final fastModeEnabledProvider = StateProvider<bool>((ref) => false);

/// When true, voice cloning is disabled — the app will use real recordings
/// or system TTS only. Actors can opt out of having their voice cloned.
final voiceCloningEnabledProvider = StateProvider<bool>((ref) => true);

/// When true, fall back to understudy recordings when the primary actor
/// hasn't recorded a line.
final understudyFallbackProvider = StateProvider<bool>((ref) => true);

Future<String> _getVersionString() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return 'Version ${info.version} (${info.buildNumber})';
  } catch (_) {
    return 'Version ${AppConstants.appVersion}';
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jumpBackLines = ref.watch(jumpBackLinesProvider);
    final playbackSpeed = ref.watch(playbackSpeedProvider);
    final matchThreshold = ref.watch(matchThresholdProvider);
    final jumpBackTrigger = ref.watch(jumpBackTriggerProvider);
    final voiceCloningEnabled = ref.watch(voiceCloningEnabledProvider);
    final understudyFallback = ref.watch(understudyFallbackProvider);
    final fastModeSpeed = ref.watch(fastModeSpeedProvider);
    final lineDelay = ref.watch(lineDelayProvider);
    final fastModeLineDelay = ref.watch(fastModeLineDelayProvider);

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
      body: ListView(
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
                Text('$jumpBackLines',
                    style: Theme.of(context).textTheme.titleMedium),
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
                return DropdownMenuItem(
                  value: t,
                  child: Text(t.name),
                );
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
                  ref.read(fastModeLineDelayProvider.notifier).state =
                      v.round(),
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
                  ref.read(matchThresholdProvider.notifier).state =
                      v.round(),
            ),
            trailing: Text('$matchThreshold%'),
          ),
          _sectionHeader(context, 'AI & Voice'),
          SwitchListTile(
            title: const Text('Voice cloning'),
            subtitle: Text(voiceCloningEnabled
                ? 'AI voice cloning is enabled for other characters'
                : 'Opted out — only real recordings or system TTS will be used'),
            value: voiceCloningEnabled,
            onChanged: (v) =>
                ref.read(voiceCloningEnabledProvider.notifier).state = v,
            secondary: Icon(
              voiceCloningEnabled
                  ? Icons.record_voice_over
                  : Icons.voice_over_off,
            ),
          ),
          SwitchListTile(
            title: const Text('Understudy fallback'),
            subtitle: const Text(
                'Use understudy recordings when primary actor hasn\'t recorded'),
            value: understudyFallback,
            onChanged: (v) =>
                ref.read(understudyFallbackProvider.notifier).state = v,
            secondary: const Icon(Icons.people_outline),
          ),
          ListTile(
            title: const Text('Kokoro TTS (on-device)'),
            subtitle: Text(
              TtsService.instance.isKokoroLoaded
                  ? 'Loaded — using on-device MLX inference'
                  : 'Not loaded — using system TTS',
            ),
            leading: Icon(
              TtsService.instance.isKokoroLoaded
                  ? Icons.record_voice_over
                  : Icons.voice_over_off,
              color: TtsService.instance.isKokoroLoaded
                  ? Colors.green
                  : Colors.orange,
            ),
          ),
          _sectionHeader(context, 'AI Models'),
          ListTile(
            leading: const Icon(Icons.smart_toy),
            title: const Text('AI Models'),
            subtitle: const Text('Download on-device AI models'),
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
            leading: const Icon(Icons.mic),
            title: const Text('STT Debug'),
            subtitle: const Text('Test speech recognition with vocabulary hints'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/parakeet-debug'),
          ),
          ListTile(
            leading: const Icon(Icons.terminal),
            title: const Text('Debug Log'),
            subtitle: const Text('View system logs, memory usage, and errors'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/debug-log'),
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
              subtitle: Text(snap.data ?? 'Version ${AppConstants.appVersion}'),
              leading: const Icon(Icons.theater_comedy),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    // Clear persisted skip-auth flag.
    ref.read(sharedPreferencesProvider).remove('auth_skipped');

    // Sign out of Supabase if there's an active session.
    if (SupabaseService.instance.isInitialized &&
        SupabaseService.instance.isSignedIn) {
      await SupabaseService.instance.signOut();
    }

    // Reset in-memory auth state.
    ref.read(authStateProvider.notifier).state = false;
    ref.read(authGatePassedProvider.notifier).state = false;

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
