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
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('screenshot_mode') == true) return;
    if (prefs.getBool('model_setup_offered') == true) return;
    final ready = await ModelManager.instance.isAllReady();
    await prefs.setBool('model_setup_offered', true);
    if (ready || !context.mounted) return;
    await context.push('/setup-models');
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
    Platform.isAndroid ? '~600 MB' : '~180 MB',
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
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final voicesReady = await ModelManager.instance.isKokoroReady();
    final matchingReady = _matching == null
        ? true
        : await ModelDownloadService.instance.isLiveAsrReady();
    if (!mounted) return;
    setState(() {
      _voices.ready = voicesReady;
      _matching?.ready = matchingReady;
      _statusChecked = true;
    });
  }

  /// iOS/native downloads report through the service's listener; fold the
  /// per-file states into the voices row.
  void _onServiceState() {
    if (!mounted || Platform.isAndroid) return;
    final svc = ModelDownloadService.instance;
    final files = ModelDownloadService.availableModels
        .where((m) => m.subdir == 'kokoro_mlx')
        .toList();
    var total = 0, done = 0.0;
    String? error;
    for (final m in files) {
      final s = svc.getState(m.id);
      total += m.sizeBytes;
      done += (s.status == ModelStatus.downloaded ? 1.0 : s.progress) *
          m.sizeBytes;
      error ??= s.errorMessage;
    }
    setState(() {
      _voices.progress = total == 0 ? 0 : done / total;
      _voices.error = error;
      if (files.every(
          (m) => svc.getState(m.id).status == ModelStatus.downloaded)) {
        _voices.ready = true;
      }
    });
  }

  Future<void> _downloadAll() async {
    setState(() {
      _downloading = true;
      for (final i in _items) {
        i.error = null;
      }
    });
    AnalyticsService.instance.logModelDownloaded(modelId: 'setup_all');

    // Sequential on purpose: one fat download at a time is kinder to the
    // network and gives an honest per-row progress bar.
    if (!_voices.ready) {
      try {
        if (Platform.isAndroid) {
          await ModelManager.instance.downloadKokoro(
            onProgress: (file, progress) {
              if (mounted) setState(() => _voices.progress = progress);
            },
          );
          await TtsService.instance.tryLoadKokoro();
          if (mounted) setState(() => _voices.ready = true);
        } else {
          // Native background session; progress arrives via _onServiceState.
          for (final m in ModelDownloadService.availableModels
              .where((m) => m.subdir == 'kokoro_mlx')) {
            await ModelDownloadService.instance.download(m);
          }
          // Completion also arrives via the listener; poll until settled so
          // the line-matching row (Android-only today) never runs early.
          while (mounted && !_voices.ready && _voices.error == null) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      } catch (e) {
        _dlog.logError(LogCategory.error, 'Model setup: voices failed', e);
        if (mounted) setState(() => _voices.error = e.toString());
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
            done += (s.status == ModelStatus.downloaded ? 1.0 : s.progress) *
                m.sizeBytes;
          }
          if (mounted) {
            setState(() => matching.progress = total == 0 ? 0 : done / total);
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
              matching.error = ModelDownloadService.availableModels
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
        if (mounted) setState(() => matching.error = e.toString());
      }
    }

    if (!mounted) return;
    setState(() => _downloading = false);
    if (_items.every((i) => i.ready)) {
      ScaffoldMessenger.of(context).showAutoToast(const SnackBar(
        content: Text('All set — rehearsal is ready to go!'),
      ));
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allReady = _statusChecked && _items.every((i) => i.ready);
    final anyMissing = _statusChecked && _items.any((i) => !i.ready);

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
                    child: Text(allReady
                        ? 'Continue'
                        : _downloading
                            ? 'Continue in background'
                            : 'Skip for now'),
                  ),
                ),
                const SizedBox(height: 8),
                Icon(Icons.theater_comedy,
                    size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Set up your rehearsal AI',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'CastCircle runs its AI on your device — nothing you say in '
                  'rehearsal leaves your ${Platform.isAndroid ? 'phone' : 'device'}. '
                  'One download, then it works offline.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                ..._items.map((i) => Card(
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
                            Text(i.ready
                                ? 'Installed'
                                : '${i.subtitle} (${i.sizeLabel})'),
                            if (_downloading && !i.ready && i.error == null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: LinearProgressIndicator(
                                    value:
                                        i.progress == 0 ? null : i.progress),
                              ),
                            if (i.error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(i.error!,
                                    style: const TextStyle(
                                        color: Colors.red, fontSize: 12)),
                              ),
                          ],
                        ),
                      ),
                    )),
                const Spacer(),
                if (anyMissing)
                  FilledButton.icon(
                    onPressed: _downloading ? null : _downloadAll,
                    icon: _downloading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download),
                    label: Text(_downloading
                        ? 'Downloading…'
                        : _items.any((i) => i.error != null)
                            ? 'Retry download'
                            : 'Download all'),
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
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
