import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/responsive.dart';
import '../../core/toast.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/model_download_service.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/tts_service.dart';

/// One-time, skippable new-user step: download every on-device AI model the
/// platform uses, in one tap.
///
/// Shown once after first sign-in (HomeScreen pushes it when models are
/// missing and the `model_setup_offered` pref is unset). Skipping is always
/// available — the production hub's banner and the Settings → AI Models
/// screen remain the fallback paths.
class ModelSetupScreen extends StatefulWidget {
  const ModelSetupScreen({super.key});

  /// Push this screen once per install if any model is missing.
  /// Call from a screen a new user is guaranteed to reach (home).
  static Future<void> maybeOffer(BuildContext context) async {
    // Desktop rehearses with system voices; don't gate anything there.
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('screenshot_mode') == true) return;
      if (prefs.getBool('model_setup_offered') == true) return;
      final ready = await ModelManager.instance.isAllReady();
      if (ready || !context.mounted) return;

      // Starting the push successfully means the offer was presented. Mark it
      // immediately, while the setup route is open, rather than waiting for
      // that route to be popped or consuming it before navigation.
      final route = context.push('/setup-models');
      final saved = await prefs.setBool('model_setup_offered', true);
      if (!saved) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'Could not persist model setup offer',
          StateError('SharedPreferences rejected model_setup_offered write'),
        );
      }
      await route;
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'Could not offer model setup',
        e,
      );
    }
  }

  @override
  State<ModelSetupScreen> createState() => _ModelSetupScreenState();
}

class _Item {
  _Item(this.title, this.subtitle, this.sizeLabel);
  final String title;
  final String subtitle;
  final String sizeLabel;
  bool ready = false;
  double progress = 0;
  String? error;
}

class _ModelSetupScreenState extends State<ModelSetupScreen> {
  late final _Item _voices = _Item(
    'AI voices',
    'Your castmates’ lines read in natural voices',
    '~180 MB',
  );
  final _Item? _matching = Platform.isAndroid
      ? _Item(
          'Live line matching',
          'Rehearsal follows your lines as you speak them',
          '~68 MB',
        )
      : null;

  bool _downloading = false;
  bool _statusChecked = false;
  bool _voiceFilesDownloaded = false;
  String? _statusError;
  Timer? _progressUpdateTimer;
  VoidCallback? _pendingProgressUpdate;
  static const _progressUpdateInterval = Duration(milliseconds: 200);
  static const _voiceLoadError =
      'AI voices could not be loaded. Please try again.';
  final _dlog = DebugLogService.instance;

  List<_Item> get _items => [_voices, if (_matching != null) _matching];

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    // iOS voices download via the native service — mirror its progress.
    ModelDownloadService.instance.addListener(_onServiceState);
  }

  @override
  void dispose() {
    ModelDownloadService.instance.removeListener(_onServiceState);
    _progressUpdateTimer?.cancel();
    _pendingProgressUpdate = null;
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    setState(() {
      _statusChecked = false;
      _statusError = null;
    });
    try {
      final voiceFilesReady = Platform.isAndroid
          ? await ModelManager.instance.isKokoroReady()
          : await ModelDownloadService.instance.isKokoroReady();
      final voicesReady = voiceFilesReady && await _tryLoadDownloadedVoices();
      final matchingReady = _matching == null
          ? true
          : await ModelDownloadService.instance.isLiveAsrReady();
      if (!mounted) return;
      setState(() {
        _voiceFilesDownloaded = voiceFilesReady;
        _voices.ready = voicesReady;
        _voices.error = voiceFilesReady && !voicesReady
            ? _voiceLoadError
            : null;
        _matching?.ready = matchingReady;
        _statusChecked = true;
      });
    } catch (e) {
      _dlog.logError(
        LogCategory.error,
        'Model setup: readiness check failed',
        e,
      );
      if (!mounted) return;
      setState(() {
        _statusChecked = true;
        _statusError = "Couldn't check installed models. Please try again.";
      });
    }
  }

  /// iOS/native downloads report through the service's listener; fold the
  /// per-file states into the voices row.
  void _onServiceState() {
    if (!mounted || Platform.isAndroid) return;
    _scheduleProgressUpdate(() {
      final svc = ModelDownloadService.instance;
      final files = ModelDownloadService.availableModels
          .where((m) => m.subdir == 'kokoro_mlx')
          .toList();
      var total = 0, done = 0.0;
      String? error;
      for (final m in files) {
        final s = svc.getState(m.id);
        total += m.sizeBytes;
        done +=
            (s.status == ModelStatus.downloaded ? 1.0 : s.progress) *
            m.sizeBytes;
        error ??= s.errorMessage;
      }
      _voices.progress = total == 0 ? 0 : done / total;
      _voiceFilesDownloaded = files.every(
        (m) => svc.getState(m.id).status == ModelStatus.downloaded,
      );
      if (error != null || !_voiceFilesDownloaded) {
        _voices.error = error;
      }
    });
  }

  Future<bool> _tryLoadDownloadedVoices() async {
    final loaded = await TtsService.instance.tryLoadKokoro();
    if (!loaded) {
      _dlog.logError(
        LogCategory.tts,
        'Model setup: downloaded voices failed to load',
        StateError('tryLoadKokoro returned false'),
      );
    }
    return loaded;
  }

  /// Coalesce native and Dart download notifications so a long transfer does
  /// not rebuild the entire setup screen for every progress packet.
  void _scheduleProgressUpdate(VoidCallback update) {
    _pendingProgressUpdate = update;
    _progressUpdateTimer ??= Timer(_progressUpdateInterval, () {
      _progressUpdateTimer = null;
      final pending = _pendingProgressUpdate;
      _pendingProgressUpdate = null;
      if (mounted && pending != null) setState(pending);
    });
  }

  Future<void> _downloadAll() async {
    // Record consent before starting transfers: the launch-time
    // auto-downloader only runs for users who chose to download (never for
    // "Skip for now" users on cellular).
    setState(() {
      _downloading = true;
      for (final i in _items) {
        i.error = null;
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setBool('models_auto_download_ok', true);
      if (!saved) {
        throw StateError(
          'SharedPreferences rejected models_auto_download_ok write',
        );
      }
    } catch (e) {
      _dlog.logError(
        LogCategory.error,
        'Could not persist model auto-download consent',
        e,
      );
    }

    // Sequential on purpose: one fat download at a time is kinder to the
    // network and gives an honest per-row progress bar.
    if (!_voices.ready) {
      try {
        if (Platform.isAndroid) {
          await ModelManager.instance.downloadKokoro(
            onProgress: (file, progress) {
              if (mounted) {
                _scheduleProgressUpdate(() => _voices.progress = progress);
              }
            },
          );
          final loaded = await _tryLoadDownloadedVoices();
          if (mounted) {
            setState(() {
              _voices.progress = 1;
              _voices.ready = loaded;
              _voices.error = loaded ? null : _voiceLoadError;
            });
          }
        } else {
          final svc = ModelDownloadService.instance;
          final filesReady = await svc.isKokoroReady();
          if (filesReady) {
            // A retry after an engine-load failure must not restart valid
            // native transfers; retry only the load itself.
            _voiceFilesDownloaded = true;
            final loaded = await _tryLoadDownloadedVoices();
            if (mounted) {
              setState(() {
                _voices.progress = 1;
                _voices.ready = loaded;
                _voices.error = loaded ? null : _voiceLoadError;
              });
            }
          } else {
            // Do not let completion state from the previous attempt make this
            // retry load Kokoro while replacement files are still in flight.
            _voiceFilesDownloaded = false;
            // Refresh states for valid files, then start only the missing or
            // invalid native files. Completion arrives via _onServiceState
            // after every file has passed verification.
            await svc.refreshDownloadedStatus();
            await svc.downloadKokoro();
            // Time out only when progress has stalled; a healthy slow
            // transfer may run longer than fifteen minutes.
            var lastProgress = _voices.progress;
            var stallDeadline = DateTime.now().add(const Duration(minutes: 15));
            while (mounted && !_voiceFilesDownloaded && _voices.error == null) {
              await Future.delayed(const Duration(milliseconds: 500));
              if (_voices.progress != lastProgress) {
                lastProgress = _voices.progress;
                stallDeadline = DateTime.now().add(const Duration(minutes: 15));
              } else if (DateTime.now().isAfter(stallDeadline)) {
                setState(() {
                  _voices.error =
                      'Download stalled — check your connection and retry.';
                });
                break;
              }
            }
            if (mounted && _voiceFilesDownloaded && _voices.error == null) {
              final loaded = await _tryLoadDownloadedVoices();
              if (mounted) {
                setState(() {
                  _voices.ready = loaded;
                  _voices.error = loaded ? null : _voiceLoadError;
                });
              }
            }
          }
        }
      } catch (e) {
        _dlog.logError(LogCategory.error, 'Model setup: voices failed', e);
        if (mounted) {
          setState(
            () => _voices.error =
                'AI voices could not be installed. Please try again.',
          );
        }
      }
    }

    final matching = _matching;
    if (matching != null && !matching.ready) {
      try {
        // Per-file progress via the service listener isn't wired for the
        // Android Dart fallback rows; show indeterminate via progress < 1.
        final svc = ModelDownloadService.instance;
        void track() {
          final files = ModelDownloadService.availableModels
              .where((m) => m.subdir == 'live_asr')
              .toList();
          var total = 0, done = 0.0;
          for (final m in files) {
            final s = svc.getState(m.id);
            total += m.sizeBytes;
            done +=
                (s.status == ModelStatus.downloaded ? 1.0 : s.progress) *
                m.sizeBytes;
          }
          if (mounted) {
            _scheduleProgressUpdate(
              () => matching.progress = total == 0 ? 0 : done / total,
            );
          }
        }

        svc.addListener(track);
        try {
          await svc.downloadLiveAsr();
        } finally {
          svc.removeListener(track);
        }
        final ok = await svc.isLiveAsrReady();
        if (mounted) {
          setState(() {
            matching.ready = ok;
            if (!ok) {
              matching.error =
                  ModelDownloadService.availableModels
                      .where((m) => m.subdir == 'live_asr')
                      .map((m) => svc.getState(m.id).errorMessage)
                      .whereType<String>()
                      .firstOrNull ??
                  'Download did not complete — try again';
            }
          });
        }
      } catch (e) {
        _dlog.logError(LogCategory.error, 'Model setup: matching failed', e);
        if (mounted) {
          setState(
            () => matching.error =
                'Live line matching could not be installed. Please try again.',
          );
        }
      }
    }

    if (!mounted) return;
    setState(() => _downloading = false);
    if (_items.every((i) => i.ready)) {
      AnalyticsService.instance.logModelDownloaded(modelId: 'setup_all');
      ScaffoldMessenger.of(context).showAutoToast(
        const SnackBar(content: Text('All set — rehearsal is ready to go!')),
      );
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allReady =
        _statusChecked && _statusError == null && _items.every((i) => i.ready);
    final anyMissing =
        _statusChecked && _statusError == null && _items.any((i) => !i.ready);

    return Scaffold(
      body: SafeArea(
        child: ContentConstraint(
          maxWidth: 560,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: TextButton(
                    // Skippable, never trapped — in-flight downloads keep
                    // running (native session on iOS, in-process futures on
                    // Android) and everything is available later from the
                    // production screen or Settings.
                    onPressed: () => context.pop(),
                    child: Text(
                      allReady
                          ? 'Continue'
                          : _downloading
                          ? 'Continue in background'
                          : 'Skip for now',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Icon(
                  Icons.theater_comedy,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Set up your rehearsal AI',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'CastCircle runs its AI on your device — nothing you say in '
                  'rehearsal leaves your ${Platform.isAndroid ? 'phone' : 'device'}. '
                  'One download, then it works offline.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                ..._items.map(
                  (i) => Card(
                    child: ListTile(
                      leading: Icon(
                        i.ready
                            ? Icons.check_circle
                            : i == _voices
                            ? Icons.record_voice_over
                            : Icons.graphic_eq,
                        color: i.ready
                            ? Colors.green
                            : theme.colorScheme.primary,
                      ),
                      title: Text(i.title),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i.ready
                                ? 'Installed'
                                : '${i.subtitle} (${i.sizeLabel})',
                          ),
                          if (_downloading && !i.ready && i.error == null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: LinearProgressIndicator(
                                value: i.progress == 0 ? null : i.progress,
                              ),
                            ),
                          if (i.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                i.error!,
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_statusError != null)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _statusError!,
                              style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const Spacer(),
                if (_statusError != null)
                  FilledButton.icon(
                    onPressed: _refreshStatus,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry status check'),
                  ),
                if (anyMissing)
                  FilledButton.icon(
                    onPressed: _downloading ? null : _downloadAll,
                    icon: _downloading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: Text(
                      _downloading
                          ? 'Downloading…'
                          : _items.any((i) => i.error != null)
                          ? 'Retry download'
                          : 'Download all',
                    ),
                  ),
                if (allReady)
                  FilledButton.icon(
                    onPressed: () => context.pop(),
                    icon: const Icon(Icons.check),
                    label: const Text('Continue'),
                  ),
                const SizedBox(height: 8),
                if (!allReady)
                  Text(
                    'You can always do this later in Settings → AI Models.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
