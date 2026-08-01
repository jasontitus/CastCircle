import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/theme/app_theme.dart';
import '../../core/responsive.dart';
import '../../data/models/script_models.dart';
import '../../data/models/rehearsal_models.dart';
import '../../data/models/voice_preset.dart';
import '../../data/services/tts_service.dart';
import '../../data/services/stt_service.dart';
import '../../data/services/stt_channel.dart';
import '../../data/services/live_asr_service.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/stt_adaptation_service.dart';
import '../../data/services/stt_vocabulary_service.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/media_control_service.dart';
import '../../data/services/model_download_service.dart';
import '../../data/services/sync_queue.dart';
import '../../data/services/voice_config_service.dart';
import '../../data/services/audio_level_service.dart';
import '../../data/services/playback_session.dart';
import '../../providers/production_providers.dart';
import '../../features/settings/settings_screen.dart';
import 'rehearsal_history_screen.dart';
import '../../core/toast.dart';

/// Rehearsal state machine.
enum RehearsalState {
  ready, // waiting to start or between lines
  playingOther, // playing another character's recording/TTS
  listeningForMe, // STT active, waiting for actor to speak
  paused, // user paused
  sceneComplete, // all lines done
}

/// Provider tracking the rehearsal engine state.
final rehearsalStateProvider =
    StateProvider<RehearsalState>((ref) => RehearsalState.ready);

/// Current line index within the scene.
final currentLineIndexProvider = StateProvider<int>((ref) => 0);

class RehearsalScreen extends ConsumerStatefulWidget {
  const RehearsalScreen({super.key});

  @override
  ConsumerState<RehearsalScreen> createState() => _RehearsalScreenState();
}

class _RehearsalScreenState extends ConsumerState<RehearsalScreen>
    with WidgetsBindingObserver {
  late ScrollController _scrollController;
  final AudioPlayer _player = AudioPlayer();
  final TtsService _tts = TtsService.instance;
  final SttService _stt = SttService.instance;
  final SttAdaptationService _sttAdapt = SttAdaptationService.instance;
  final SttVocabularyService _sttVocab = SttVocabularyService.instance;
  String? _activeAdapter; // per-actor or per-production LoRA adapter path
  final GlobalKey _currentLineKey = GlobalKey();
  StreamSubscription? _playerSub;

  final bool _autoPlay = true; // auto-advance through other characters' lines
  // Live STT state. ValueNotifiers, not setState fields, for the same reason
  // as _micLevel below: the recognizer emits several partial results per
  // second and only the transcript line and the match-feedback bar care.
  final ValueNotifier<String> _recognizedText = ValueNotifier('');
  final ValueNotifier<double> _matchScore = ValueNotifier(0.0);
  final ValueNotifier<bool> _showMatchFeedback = ValueNotifier(false);
  // Smoothed mic input level (0..1) while listening. A ValueNotifier consumed
  // by only the mic indicator: the native tap reports ~12 events/sec, and
  // routing that through setState rebuilt the ENTIRE screen (including ~70
  // offscreen list items force-built by cacheExtent: 10000) twelve times a
  // second for the whole time the actor speaks.
  final ValueNotifier<double> _micLevel = ValueNotifier(0.0);
  String _lastRecognizedRaw = ''; // last uncorrected transcript, for learning
  bool _matchConfirmed = false; // guards double-advance from timer + VAD
  bool _showJumpBackHint = false; // Set in initState based on how many times shown

  // Rehearsal audio capture: record the user's lines for later use
  final Map<String, _CapturedLine> _capturedAudio = {};
  bool _isCapturingAudio = false;
  bool _hasPromptedUpload = false; // only prompt once per session
  // Android: "download the live-matching model" tip, once per rehearsal
  bool _liveAsrNoticeShown = false;
  // Android: whether live word-matching is driving the CURRENT line. A field
  // (not a closure capture) because the recognizer can finish loading and
  // attach mid-line — the silence endpointing must see the upgrade.
  bool _liveMatchingActive = false;

  // Prefetched Kokoro TTS audio: lineId → per-CHUNK synthesis futures.
  // Populated in the background while the actor speaks THEIR line and while
  // the previous line plays, so the next other-character line starts
  // instantly. Futures (inserted before synthesis begins) rather than
  // results, for two measured reasons: playback of a line whose prefetch is
  // in flight awaits the same synthesis instead of duplicating it (the
  // results version lost that race by 100 ms), and speak() starts playing
  // chunk 0 the moment it resolves instead of waiting for the whole line
  // (a 416-char line used to sit silent for 15 s). Pruned on use (.remove)
  // and cleared on dispose / scene change.
  final Map<String, List<Future<String?>>> _ttsPrefetch = {};

  // Debounce rapid taps to prevent stack overflow from reentrancy
  bool _jumpBackInProgress = false;
  bool _processingLine = false;
  Timer? _deferredProcess;

  /// One-time pre-roll at session start: synthesize the first few lines
  /// BEFORE playback begins so the voice pipeline starts with a lead.
  /// (done, total) chunk progress while waiting; null = not preparing.
  bool _didPreRoll = false;
  final ValueNotifier<(int, int)?> _preparingVoices = ValueNotifier(null);

  // Silence timeout — auto-advance when no new STT results for a while
  Timer? _silenceTimer;
  static const _silenceTimeout = Duration(seconds: 5);

  // Match confirmation timer — don't advance while actor is still speaking.
  // When match score exceeds threshold, wait for a brief silence before advancing
  // to ensure the actor has finished reading a long multi-sentence line.
  Timer? _matchConfirmTimer;

  // matchScore is coverage (fraction of the line's words recognized). At/above
  // this, the actor has said essentially the whole line, so we advance after
  // only [_fastConfirmMs] of no-new-results (a snappy "finish line → next line"
  // loop) instead of the long confirm. The timer only fires once the actor
  // actually stops, so a high threshold + short wait can't clip them.
  static const double _fullLineMatchThreshold = 0.9;
  static const int _fastConfirmMs = 200;

  // Session tracking
  late DateTime _sessionStartedAt;
  final List<LineAttempt> _lineAttempts = [];
  int _currentAttemptCount = 0;
  double _currentBestScore = 0.0;

  // Progress autosave — persist the current line position per
  // production+scene+character+mode so a force-quit (or just leaving) doesn't
  // drop the actor back to the top of the scene next time.
  Timer? _progressSaveTimer;
  /// Force-dismisses the resume toast (see _showResumeSnackBar).
  Timer? _toastTimer;
  /// One 'first result' log per line (see onResult).
  bool _loggedFirstResultForLine = false;
  // When listening for the current line began — used to sanity-check a
  // high match score against physically-possible reading speed.
  DateTime _listeningStartedAt = DateTime.now();
  ProviderSubscription<int>? _progressSub;
  // Cached while the screen is mounted so the debounce timer, app-lifecycle
  // callback, and dispose() can persist progress WITHOUT touching `ref` after
  // the widget is unmounted (Riverpod throws "Using ref ... is unsafe" then).
  String? _persistKey;
  int _lastLineIndex = 0;
  int? _pendingResumeLine; // surfaced as a snackbar once the screen is built

  // STT failed to init (permission denied / recognizer unavailable): skip the
  // per-line wait-for-init poll and tell the actor once instead of silently
  // doing nothing on every one of their lines.
  bool _sttInitFailed = false;
  bool _sttUnavailableNoticeShown = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addObserver(this);

    _sessionStartedAt = DateTime.now();

    // Reset to beginning
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(currentLineIndexProvider.notifier).state = 0;
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
      _initAudio();
    });

    // Listen for playback completion to auto-advance (real recordings only)
    _playerSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed &&
          _autoPlay &&
          mounted) {
        final rs = ref.read(rehearsalStateProvider);
        if (rs == RehearsalState.playingOther) {
          _dlog.log(LogCategory.rehearsal, 'Recording player completed');
          _onOtherLineFinished();
        }
      }
    });
  }

  final _dlog = DebugLogService.instance;
  final _mediaControl = MediaControlService.instance;

  Future<void> _initAudio() async {
    _dlog.log(LogCategory.rehearsal, 'Rehearsal starting');
    _dlog.startMemoryMonitoring();

    final character = ref.read(rehearsalCharacterProvider) ?? 'unknown';
    final rehearsalMode = ref.read(rehearsalModeProvider);
    AnalyticsService.instance.logRehearsalStarted(
      character: character,
      mode: rehearsalMode.name,
    );

    // Keep screen on during rehearsal
    WakelockPlus.enable();

    // Show AirPods/Action Button hint for the first 5 sessions
    final prefs = await SharedPreferences.getInstance();
    // Guard after every await: backing out of the screen during init would
    // otherwise use ref/setState after unmount (crash) and re-activate media
    // controls AFTER dispose() deactivated them, leaving lock-screen controls
    // hijacked app-wide. Same bug class as the fixed _persistProgress crash.
    if (!mounted) return;
    final hintCount = prefs.getInt('jumpback_hint_shown') ?? 0;
    if (hintCount < 5) {
      setState(() => _showJumpBackHint = true);
      prefs.setInt('jumpback_hint_shown', hintCount + 1);
    }

    // Activate AirPods / lock screen remote controls
    _mediaControl.activate(
      onJumpBack: _handleRemoteJumpBack,
      onSkip: _handleRemoteSkip,
      onPlayPause: _handleRemotePlayPause,
    );
    await _tts.init();
    if (!mounted) return;
    _maybeWarnSystemVoiceFallback();

    final production = ref.read(currentProductionProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final script = ref.read(currentScriptProvider);

    // Use per-character locale if set, otherwise production default
    var locale = production?.locale ?? 'en-US';
    if (production != null && myCharacter != null) {
      final charLocale = await VoiceConfigService.instance
          .getLocale(production.id, myCharacter);
      if (charLocale != null) locale = charLocale;
    }

    // Set system TTS locale and assign voices
    await _tts.setLocale(locale);
    await _assignVoices(production, script, locale);
    if (!mounted) return;

    _tts.setCompletionHandler(() {
      if (_autoPlay && mounted) {
        _onOtherLineFinished();
      }
    });
    // Pipelining anchor: the moment a line's audio starts playing, queue
    // synthesis for the upcoming lines so it overlaps the playback.
    _tts.onPlaybackStarted = _prefetchUpcomingOtherLines;

    // A phone call / Siri / unplugged headphones kills the audio engine and
    // (on the playback path) never delivers a completion — the state machine
    // used to strand on "Playing" forever. Pause cleanly instead; the actor
    // resumes with the Pause/Resume button.
    _stt.onAudioInterruption = (began, shouldResume) {
      if (!mounted || !began) return;
      _pauseForInterruption('Audio was interrupted');
    };
    _stt.onAudioRouteLost = () {
      if (!mounted) return;
      _pauseForInterruption('Headphones disconnected');
    };

    // Decide the starting line: a saved checkpoint (resume where they left off)
    // takes precedence; otherwise Cue Practice jumps a few lines before the
    // actor's first line, and other modes start from the beginning.
    final mode = ref.read(rehearsalModeProvider);
    final scene = ref.read(selectedSceneProvider);

    int? resumeIdx;
    if (script != null && scene != null) {
      final dialogueLines = _getRehearsalLines(script, scene, myCharacter);
      resumeIdx = await _loadProgressCheckpoint(
          production, scene, myCharacter, dialogueLines.length);
      if (!mounted) return;
    }

    if (resumeIdx != null) {
      ref.read(currentLineIndexProvider.notifier).state = resumeIdx;
      _scrollToCurrentLine();
      _pendingResumeLine = resumeIdx;
    } else if (mode == RehearsalMode.cuePractice &&
        script != null &&
        myCharacter != null &&
        scene != null) {
      final dialogueLines = _getRehearsalLines(script, scene, myCharacter);
      final firstMyIdx =
          dialogueLines.indexWhere((l) => l.isForCharacter(myCharacter));
      if (firstMyIdx > 0) {
        // Start 3 lines before actor's first line (minimum 0)
        final startIdx = (firstMyIdx - 3).clamp(0, dialogueLines.length - 1);
        ref.read(currentLineIndexProvider.notifier).state = startIdx;
        _scrollToCurrentLine();
      }
    }

    // Begin watching the position so subsequent advances are autosaved. Started
    // *after* the resume read above so the initial reset-to-0 can't clobber a
    // saved checkpoint.
    _startProgressAutosave();

    // Auto-start playback immediately — don't wait for STT
    if (_autoPlay) {
      _processCurrentLine();
    }

    // Let the actor know we picked up where they left off (with an escape hatch).
    if (_pendingResumeLine != null) {
      _showResumeSnackBar(_pendingResumeLine!);
      _pendingResumeLine = null;
    }

    // Defer STT init to background — it's only needed when it's the user's
    // turn to speak, not for TTS playback of other characters' lines.
    // Skip entirely in readthrough mode (no character, no STT needed).
    if (mode != RehearsalMode.readthrough) {
      // The recognizer listens to the ACTOR's speech, so it follows the
      // DEVICE locale — never the production's dialect. A British-dialect
      // P&P handed en-GB to SFSpeechRecognizer, which heard an American
      // actor as "I feels your" / "Bennel" and starved endpointing of
      // results. The dialect keeps shaping TTS voices above.
      final device = ui.PlatformDispatcher.instance.locale;
      final sttLocale =
          device.languageCode == 'en' && device.countryCode != null
              ? '${device.languageCode}-${device.countryCode}'
              : 'en-US';
      _initSttDeferred(production, myCharacter, script, sttLocale);
    }
  }

  /// Kokoro (AI voices) silently degrading to robotic system voices was a
  /// real user complaint — say it out loud, once per app session, with the
  /// reason.
  static bool _systemVoiceNoticeShown = false;
  Future<void> _maybeWarnSystemVoiceFallback() async {
    if (_systemVoiceNoticeShown) return;
    if (_tts.activeEngine != TtsEngine.system) return;
    _systemVoiceNoticeShown = true;

    String reason;
    if (!Platform.isIOS) {
      reason = 'AI voices aren\'t supported on this device yet';
    } else if (await ModelDownloadService.instance.isKokoroReady()) {
      reason = 'the AI voice model failed to load';
      _dlog.logError(LogCategory.tts,
          'Kokoro model is downloaded but did not load — using system voices');
    } else {
      reason = 'the AI voice model isn\'t downloaded '
          '(Settings → AI Models)';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAutoToast(SnackBar(
      content: Text('Using system voices — $reason.'),
      duration: const Duration(seconds: 6),
    ));
  }

  Future<void> _initSttDeferred(
    dynamic production,
    String? myCharacter,
    ParsedScript? script,
    String locale,
  ) async {
    final sttOk = await _stt.init(locale: locale);
    if (!mounted) return;
    // Android: warm the on-device recognizer NOW, while the opening lines
    // play — a lazy start on the actor's first line cost 11 s (model load
    // competing with TTS synthesis) with the mic dead the whole time.
    if (Platform.isAndroid) {
      unawaited(LiveAsrService.instance.ensureStarted());
    }
    if (!sttOk && !Platform.isAndroid) {
      // The core feature (line matching) is dead without STT — say so instead
      // of leaving the actor wondering why nothing reacts to their voice.
      _sttInitFailed = true;
      _dlog.logError(LogCategory.stt,
          'Rehearsal: STT init failed — line matching disabled this session');
      ScaffoldMessenger.of(context).showAutoToast(const SnackBar(
        content: Text('Speech recognition unavailable — your lines won\'t be '
            'matched automatically. Check microphone & speech recognition '
            'permissions in Settings, then restart rehearsal.'),
        duration: Duration(seconds: 10),
      ));
    }

    // Build STT vocabulary from script for correction
    if (script != null && production != null) {
      _sttVocab.buildFromScript(production.id, script.lines);
    }

    // Check for per-actor or per-production STT adapter
    if (production != null && myCharacter != null) {
      _activeAdapter = _sttAdapt.getBestAdapter(production.id, myCharacter);
      if (_activeAdapter != null) {
        debugPrint('Rehearsal: Using adapted STT model: $_activeAdapter');
      }
    }
  }

  // ── Progress autosave ─────────────────────────────────
  //
  // The live position lives in [currentLineIndexProvider] (in-memory). Without
  // persistence, a force-quit or even just backgrounding mid-scene drops the
  // actor back to line 0. We checkpoint the index per
  // production+scene+character+mode (mode matters because Cue Practice uses a
  // filtered line list with a different index space) and resume on re-entry.

  String? _progressKey(dynamic production, ScriptScene scene, String? character) {
    final pid = production?.id;
    if (pid == null) return null;
    final mode = ref.read(rehearsalModeProvider).name;
    return 'rehearsal_pos:$pid:${scene.sceneName}:${character ?? '_all'}:$mode';
  }

  /// Reads a saved checkpoint for the current scene. Returns the resume index
  /// only when it's a meaningful mid-scene position; expires stale checkpoints.
  Future<int?> _loadProgressCheckpoint(
      dynamic production, ScriptScene scene, String? character, int lineCount) async {
    final key = _progressKey(production, scene, character);
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;

    final parts = raw.split('|');
    final idx = int.tryParse(parts.first) ?? 0;
    if (parts.length > 1) {
      final millis = int.tryParse(parts[1]);
      if (millis != null) {
        final age = DateTime.now().millisecondsSinceEpoch - millis;
        if (age > const Duration(days: 14).inMilliseconds) {
          await prefs.remove(key);
          return null;
        }
      }
    }
    // Only resume from a real mid-scene position (not the very start or a stale
    // index past the end of a since-edited script).
    if (idx <= 0 || idx >= lineCount) return null;
    return idx;
  }

  void _startProgressAutosave() {
    // Seed the cache while we're definitely mounted.
    _lastLineIndex = ref.read(currentLineIndexProvider);
    _persistKey = _currentProgressKey();
    _progressSub = ref.listenManual<int>(currentLineIndexProvider, (prev, next) {
      // Refresh the cache from inside the (mounted) listener so the debounce
      // timer and dispose() can persist without reading ref after unmount.
      _lastLineIndex = next;
      _persistKey = _currentProgressKey() ?? _persistKey;
      // Debounce: advancing fires rapidly during a readthrough.
      _progressSaveTimer?.cancel();
      _progressSaveTimer =
          Timer(const Duration(milliseconds: 600), () => _persistProgress(next));
    });
  }

  /// Build the checkpoint key from providers. Uses `ref`, so call ONLY while
  /// the widget is mounted (autosave setup + the listener).
  String? _currentProgressKey() {
    final production = ref.read(currentProductionProvider);
    final scene = ref.read(selectedSceneProvider);
    final character = ref.read(rehearsalCharacterProvider);
    if (scene == null) return null;
    return _progressKey(production, scene, character);
  }

  /// Persist the checkpoint using the cached key — never touches `ref`, so it is
  /// safe from the debounce timer, the app-lifecycle callback, and dispose(),
  /// even after the screen has been unmounted.
  Future<void> _persistProgress(int idx) async {
    final key = _persistKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (idx <= 0) {
      await prefs.remove(key);
    } else {
      await prefs.setString(
          key, '$idx|${DateTime.now().millisecondsSinceEpoch}');
    }
  }

  Future<void> _clearProgressCheckpoint() async {
    final production = ref.read(currentProductionProvider);
    final scene = ref.read(selectedSceneProvider);
    final character = ref.read(rehearsalCharacterProvider);
    if (scene == null) return;
    final key = _progressKey(production, scene, character);
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  /// Brief, non-blocking toast. `duration` alone is NOT enough: Flutter keeps a
  /// SnackBar up indefinitely when the platform reports accessible navigation,
  /// and any snackbar queued behind it extends the bar's presence — which is
  /// how this ended up docked over the controls for a whole 2-minute run.
  /// So: float it above the content, and force-dismiss on our own timer.
  void _showResumeSnackBar(int idx) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showAutoToast(SnackBar(
        content: Text('Resumed at line ${idx + 1}'),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        duration: const Duration(seconds: 3),
      ));
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      // Not `mounted`-guarded on the messenger: it outlives this screen, and
      // hiding a snackbar that already went away is a no-op.
      messenger.hideCurrentSnackBar();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding is the most likely moment before a force-quit — checkpoint now.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _persistProgress(_lastLineIndex);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Stop listening + debouncing first so nothing reads `ref` during teardown,
    // then persist the final position from the cached key/index (no `ref`).
    _progressSub?.close();
    _progressSaveTimer?.cancel();
    _deferredProcess?.cancel();
    _preparingVoices.dispose();
    _persistProgress(_lastLineIndex);
    WakelockPlus.disable(); // Allow screen to sleep again
    _dlog.stopMemoryMonitoring();
    _dlog.log(LogCategory.rehearsal, 'Rehearsal ended');
    _silenceTimer?.cancel();
    _matchConfirmTimer?.cancel();
    _toastTimer?.cancel();
    _ttsPrefetch.clear();
    _micLevel.dispose();
    _recognizedText.dispose();
    _matchScore.dispose();
    _showMatchFeedback.dispose();
    _scrollController.dispose();
    _playerSub?.cancel();
    _player.dispose();
    // Clear the completion handler so the singleton TtsService doesn't retain
    // this disposed State (and its ref) until the next rehearsal.
    _tts.setCompletionHandler(() {});
    _tts.onPlaybackStarted = null;
    _stt.onAudioInterruption = null;
    _stt.onAudioRouteLost = null;
    _tts.stop(reason: 'dispose');
    _stt.stop();
    if (Platform.isAndroid) {
      // Detach callbacks but keep the recognizer engine WARM: stopping it
      // here orphaned the in-flight load of the next rehearsal (scene switch
      // = dispose + immediate restart), which then ran its first lines with
      // live matching dead. The isolate holds ~150 MB and reloads in ~8 s —
      // keeping it resident across rehearsals is the better trade.
      SttChannel.instance.onPcm = null;
      LiveAsrService.instance.onPartial = null;
    }
    _mediaControl.deactivate();
    // Note: the production-level recording subscription is owned by the
    // home screen (set up when the production is opened) — do not tear
    // it down here or castmates' new recordings stop arriving.
    super.dispose();
  }

  /// Assign voices to all characters. Batches SharedPreferences reads
  /// to avoid sequential await per character.
  Future<void> _assignVoices(
    dynamic production,
    ParsedScript? script,
    String locale,
  ) async {
    if (script == null) return;
    final voiceConfig = VoiceConfigService.instance;

    if (production != null) {
      // Batch-load overrides and genders in one go
      final genderOverrides = await voiceConfig.getGenders(production.id);
      final overrides = await voiceConfig.getOverrides(production.id);
      final preset = await voiceConfig.getPreset(production.id, locale: locale);

      // Compute adjacency-aware default assignments
      final autoAssignment = VoiceConfigService.assignVoicesFromScript(
        lines: script.lines,
        characters: script.characters,
        femaleVoices: preset.femaleVoices,
        maleVoices: preset.maleVoices,
        genderOverrides: genderOverrides,
      );

      for (var i = 0; i < script.characters.length; i++) {
        final char = script.characters[i];
        final gender = genderOverrides[char.name] ?? char.gender;

        // Manual override takes priority
        String voiceId;
        double speed;
        final override = overrides[char.name];
        if (override != null) {
          voiceId = override.voiceId;
          speed = override.speed;
        } else {
          voiceId = autoAssignment[char.name] ?? 'af_heart';
          speed = preset.defaultSpeed;
        }

        _tts.assignVoice(char.name, i,
            voiceId: voiceId, speed: speed, locale: locale,
            isMale: gender == CharacterGender.male);
      }
    } else {
      // No production — still use adjacency-aware assignment with defaults
      final autoAssignment = VoiceConfigService.assignVoicesFromScript(
        lines: script.lines,
        characters: script.characters,
        femaleVoices: VoicePresets.modernAmerican.femaleVoices,
        maleVoices: VoicePresets.modernAmerican.maleVoices,
      );
      for (var i = 0; i < script.characters.length; i++) {
        final char = script.characters[i];
        _tts.assignVoice(char.name, i, voiceId: autoAssignment[char.name],
            locale: locale, isMale: char.gender == CharacterGender.male);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Drop any prefetched TTS audio when the line set changes (different scene)
    // so we never play stale paths for a line that no longer exists.
    ref.listen<ScriptScene?>(selectedSceneProvider, (prev, next) {
      if (prev != next) _ttsPrefetch.clear();
    });

    final script = ref.watch(currentScriptProvider);
    final scene = ref.watch(selectedSceneProvider);
    final myCharacter = ref.watch(rehearsalCharacterProvider);
    final currentIdx = ref.watch(currentLineIndexProvider);
    final rehearsalState = ref.watch(rehearsalStateProvider);
    final jumpBackLines = ref.watch(jumpBackLinesProvider);

    if (script == null || scene == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Rehearsal')),
        body: const Center(child: Text('No scene selected')),
      );
    }

    final mode = ref.watch(rehearsalModeProvider);
    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);

    final isComplete = currentIdx >= dialogueLines.length;
    final currentLine = isComplete ? null : dialogueLines[currentIdx];
    final isMyLine = mode != RehearsalMode.readthrough &&
        myCharacter != null &&
        (currentLine?.isForCharacter(myCharacter) ?? false);
    final progress = dialogueLines.isEmpty
        ? 0.0
        : currentIdx / dialogueLines.length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context, scene, progress, rehearsalState, mode),
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey[900],
              color: isMyLine
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey[600],
            ),
            // Session-start voice pre-roll progress (see _preRollVoices).
            ValueListenableBuilder<(int, int)?>(
              valueListenable: _preparingVoices,
              builder: (context, prep, _) {
                if (prep == null) return const SizedBox.shrink();
                final (done, total) = prep;
                return Container(
                  width: double.infinity,
                  color: Colors.grey[900],
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: total == 0 ? null : done / total,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Preparing voices… $done of $total',
                        style: TextStyle(color: Colors.grey[300], fontSize: 13),
                      ),
                    ],
                  ),
                );
              },
            ),
            Expanded(
              child: isComplete
                  ? _buildCompletionView(context, scene, dialogueLines.length)
                  : _buildScriptView(
                      context, script, dialogueLines, currentIdx, myCharacter,
                      rehearsalState),
            ),
            // Match feedback for STT. Listens instead of reading the field so
            // a new partial result repaints this bar alone.
            if (isMyLine)
              ValueListenableBuilder<bool>(
                valueListenable: _showMatchFeedback,
                builder: (context, show, _) => show
                    ? _buildMatchFeedback(context)
                    : const SizedBox.shrink(),
              ),
            // AirPods / Action Button hint
            if (_showJumpBackHint && !isComplete)
              _buildJumpBackHint(context),
            _buildControls(
              context, rehearsalState, isMyLine, isComplete,
              currentIdx, dialogueLines.length, jumpBackLines,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, ScriptScene scene, double progress,
      RehearsalState rehearsalState, RehearsalMode mode) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () {
              _tts.stop(reason: 'closeButton');
              _stt.stop();
              _player.stop();
              context.pop();
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  scene.sceneName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                if (scene.location.isNotEmpty)
                  Text(
                    scene.location,
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
              ],
            ),
          ),
          // Text size +/- (useful on iPad)
          IconButton(
            icon: const Icon(Icons.text_decrease, color: Colors.white54, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Smaller text',
            onPressed: () {
              final current = ref.read(rehearsalFontSizeProvider);
              if (current > 12) {
                ref.read(rehearsalFontSizeProvider.notifier).state = current - 2;
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.text_increase, color: Colors.white54, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Larger text',
            onPressed: () {
              final current = ref.read(rehearsalFontSizeProvider);
              if (current < 36) {
                ref.read(rehearsalFontSizeProvider.notifier).state = current + 2;
              }
            },
          ),
          // Fast mode toggle
          GestureDetector(
            onTap: () {
              ref.read(fastModeEnabledProvider.notifier).state =
                  !ref.read(fastModeEnabledProvider);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: ref.watch(fastModeEnabledProvider)
                    ? Colors.amber.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt,
                      color: ref.watch(fastModeEnabledProvider)
                          ? Colors.amber
                          : Colors.white30,
                      size: 14),
                  const SizedBox(width: 2),
                  Text('FAST',
                      style: TextStyle(
                          color: ref.watch(fastModeEnabledProvider)
                              ? Colors.amber
                              : Colors.white30,
                          fontSize: 9,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          // Mode badge
          if (mode == RehearsalMode.readthrough)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('READ',
                  style: TextStyle(color: Colors.teal, fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          if (mode == RehearsalMode.cuePractice)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('CUE',
                  style: TextStyle(color: Colors.blue, fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          // Blind rehearsal badge
          if (ref.watch(hideMyLinesProvider))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('BLIND',
                  style: TextStyle(color: Colors.purple, fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          // Adapted STT badge
          if (_activeAdapter != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('AI',
                  style: TextStyle(color: Colors.green, fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          // State indicator
          _buildStateChip(rehearsalState),
          const SizedBox(width: 8),
          Text(
            '${(progress * 100).toInt()}%',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildStateChip(RehearsalState state) {
    String label;
    Color color;
    IconData icon;

    switch (state) {
      case RehearsalState.playingOther:
        label = 'Playing';
        color = Colors.green;
        icon = Icons.volume_up;
      case RehearsalState.listeningForMe:
        label = 'Listening';
        color = Colors.orange;
        icon = Icons.mic;
      case RehearsalState.paused:
        label = 'Paused';
        color = Colors.grey;
        icon = Icons.pause;
      case RehearsalState.sceneComplete:
        label = 'Done';
        color = Colors.blue;
        icon = Icons.check;
      case RehearsalState.ready:
        label = 'Ready';
        color = Colors.grey;
        icon = Icons.hourglass_empty;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildScriptView(
    BuildContext context,
    ParsedScript script,
    List<ScriptLine> dialogueLines,
    int currentIdx,
    String? myCharacter,
    RehearsalState rehearsalState,
  ) {
    // Hoisted out of itemBuilder: with cacheExtent forcing ~145 rows built,
    // a per-row indexWhere over the cast was O(rows × characters) per frame.
    final script = ref.read(currentScriptProvider);
    final charIndexByName = <String, int>{
      if (script != null)
        for (var i = 0; i < script.characters.length; i++)
          script.characters[i].name: i,
    };

    final list = ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      // Large cache extent so items are built before they're visible.
      // This ensures _currentLineKey is always available for scrolling.
      cacheExtent: 10000,
      itemCount: dialogueLines.length,
      itemBuilder: (context, index) {
        final line = dialogueLines[index];
        final isCurrent = index == currentIdx;
        final isPast = index < currentIdx;
        final isMe = ref.read(rehearsalModeProvider) != RehearsalMode.readthrough &&
            myCharacter != null &&
            line.isForCharacter(myCharacter);
        final baseFontSize = ref.watch(rehearsalFontSizeProvider);
        final fontSize = isCurrent ? baseFontSize : baseFontSize - 3;

        // For multi-character lines, use first individual for color lookup
        final colorLookupName = line.multiCharacters.isNotEmpty
            ? line.multiCharacters.first
            : line.character;
        final charIdx = charIndexByName[colorLookupName] ?? -1;
        final color = charIdx >= 0
            ? AppTheme.colorForCharacter(charIdx)
            : Colors.grey;

        double opacity;
        if (isCurrent) {
          opacity = 1.0;
        } else if (isPast) {
          opacity = 0.25;
        } else {
          opacity = 0.5;
        }

        return Opacity(
          key: isCurrent ? _currentLineKey : null,
          opacity: opacity,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isCurrent
                  ? (isMe
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.15)
                      : Colors.grey[900])
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: isCurrent
                  ? Border.all(
                      color: isMe
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey[700]!,
                      width: isMe ? 2 : 1,
                    )
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isMe ? 'YOU (${line.character})' : line.character,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    if (isCurrent && isMe) ...[
                      const Spacer(),
                      if (rehearsalState == RehearsalState.listeningForMe) ...[
                        _pulsingMic(context),
                      ] else ...[
                        Icon(Icons.mic, size: 16,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 4),
                        Text('YOUR LINE',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                    if (isCurrent && !isMe &&
                        rehearsalState == RehearsalState.playingOther) ...[
                      const Spacer(),
                      Icon(Icons.volume_up, size: 14, color: Colors.green[400]),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (line.stageDirection.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '(${line.stageDirection})',
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Colors.grey[600],
                        fontSize: 13,
                      ),
                    ),
                  ),
                // Hide the actor's upcoming lines in blind mode
                if (ref.watch(hideMyLinesProvider) && isMe && !isPast)
                  Text(
                    'Say your line...',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: fontSize,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                    ),
                  )
                else
                  Text(
                    line.text,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: fontSize,
                      height: 1.4,
                    ),
                  ),
                // Show recognized text under current line if listening.
                // Only the current line subscribes, so a partial result
                // repaints one Text instead of every built list item.
                if (isCurrent && isMe)
                  ValueListenableBuilder<String>(
                    valueListenable: _recognizedText,
                    builder: (context, recognized, _) => recognized.isEmpty
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              recognized,
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 14,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    // Cap the reading column on tablets so script lines stay comfortably
    // readable instead of stretching the full iPad width. Full-width on phones.
    return ContentConstraint(maxWidth: 760, child: list);
  }

  Widget _pulsingMic(BuildContext context) {
    // Mic glow follows the actor's actual voice level (smoothed RMS from
    // the native tap) instead of a fixed animation — speaking visibly
    // "lights up" the indicator. Only this widget listens to the ~12Hz level
    // stream, so the rest of the screen doesn't rebuild with it.
    return ValueListenableBuilder<double>(
      valueListenable: _micLevel,
      builder: (context, level, _) {
        final intensity = (level / 0.15).clamp(0.0, 1.0);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Colors.orange.withValues(alpha: 0.10 + 0.25 * intensity),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mic,
                  size: 16 + 3 * intensity,
                  color: Color.lerp(
                      Colors.orange[300], Colors.orange[600], intensity)),
              const SizedBox(width: 4),
              Text('LISTENING...',
                style: TextStyle(
                  color: Colors.orange[400],
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMatchFeedback(BuildContext context) {
    final threshold = ref.read(matchThresholdProvider) / 100.0;

    // The score changes with every partial result — rebuild just this bar.
    return ValueListenableBuilder<double>(
      valueListenable: _matchScore,
      builder: (context, score, _) {
        final matched = score >= threshold;
        final percentage = (score * 100).toInt();

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: matched
              ? Colors.green.withValues(alpha: 0.2)
              : Colors.orange.withValues(alpha: 0.2),
          child: Row(
            children: [
              Icon(
                matched ? Icons.check_circle : Icons.info_outline,
                color: matched ? Colors.green : Colors.orange,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                matched ? 'Match! $percentage%' : '$percentage% — keep going',
                style: TextStyle(
                  color: matched ? Colors.green : Colors.orange,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCompletionView(
      BuildContext context, ScriptScene scene, int totalLines) {
    final completedLines = _lineAttempts.where((a) => !a.skipped).length;
    final avgScore = _lineAttempts.isEmpty
        ? 0.0
        : _lineAttempts.fold<double>(0, (s, a) => s + a.bestScore) /
            _lineAttempts.length;
    final struggled = _lineAttempts.where((a) => a.bestScore < 0.7).toList();
    final duration = DateTime.now().difference(_sessionStartedAt);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              avgScore >= 0.8
                  ? Icons.emoji_events
                  : Icons.check_circle_outline,
              size: 80,
              color: avgScore >= 0.8 ? Colors.amber : Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            const Text(
              'Scene Complete!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              scene.sceneName,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 16),
            ),
            const SizedBox(height: 16),
            // Stats row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _completionStat('${(avgScore * 100).toInt()}%', 'Score',
                    avgScore >= 0.8 ? Colors.green : Colors.orange),
                _completionStat('$completedLines/$totalLines', 'Lines',
                    Colors.white70),
                _completionStat(
                    '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s',
                    'Time',
                    Colors.white70),
              ],
            ),
            // Struggled lines
            if (struggled.isNotEmpty) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Lines to practice:',
                        style: TextStyle(color: Colors.orange,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    ...struggled.take(5).map((a) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '- ${a.lineText}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.grey[400], fontSize: 12),
                          ),
                        )),
                  ],
                ),
              ),
            ],
            if (_capturedAudio.isNotEmpty && _hasPromptedUpload) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  final character = ref.read(rehearsalCharacterProvider) ?? '';
                  _saveRehearsalCaptures(character);
                },
                icon: const Icon(Icons.upload),
                label: Text('Save ${_capturedAudio.length} Recorded Lines'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  textStyle: const TextStyle(fontSize: 16),
                  backgroundColor: Colors.green,
                ),
              ),
            ],
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _restartScene,
              icon: const Icon(Icons.replay),
              label: const Text('Run Again'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.push('/history'),
              icon: const Icon(Icons.history),
              label: const Text('View History'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                _tts.stop(reason: 'chooseAnotherScene');
                _stt.stop();
                _player.stop();
                context.pop();
              },
              child: const Text('Choose Another Scene'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _completionStat(String value, String label, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                color: color, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
    );
  }

  Widget _buildJumpBackHint(BuildContext context) {
    return Container(
      color: Colors.blueGrey[900],
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.headphones, size: 16, color: Colors.blueGrey[300]),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(color: Colors.blueGrey[300], fontSize: 12),
                children: const [
                  TextSpan(
                    text: 'Tip: ',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(
                    text: 'Tap your AirPods to jump back to your last cue',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => setState(() => _showJumpBackHint = false),
            child: Icon(Icons.close, size: 16, color: Colors.blueGrey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    RehearsalState state,
    bool isMyLine,
    bool isComplete,
    int currentIdx,
    int totalLines,
    int jumpBackLines,
  ) {
    if (isComplete) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _controlButton(
            context,
            icon: Icons.replay,
            label: ref.read(rehearsalModeProvider) == RehearsalMode.cuePractice
                ? 'Back 2'
                : 'Back $jumpBackLines',
            onTap: currentIdx > 0
                ? () => _jumpBack(
                    ref.read(rehearsalModeProvider) == RehearsalMode.cuePractice
                        ? 2
                        : jumpBackLines,
                    totalLines)
                : null,
          ),
          _controlButton(
            context,
            icon: Icons.restart_alt,
            label: 'Restart',
            onTap: _restartScene,
          ),
          // Main action button changes based on state
          _controlButton(
            context,
            icon: _mainActionIcon(state, isMyLine),
            label: _mainActionLabel(state, isMyLine),
            onTap: () => _mainAction(state, isMyLine, totalLines),
            primary: true,
          ),
          _controlButton(
            context,
            icon: state == RehearsalState.paused
                ? Icons.play_arrow
                : Icons.pause,
            label: state == RehearsalState.paused ? 'Resume' : 'Pause',
            onTap: () => _togglePause(totalLines),
          ),
        ],
      ),
    );
  }

  IconData _mainActionIcon(RehearsalState state, bool isMyLine) {
    if (state == RehearsalState.ready && isMyLine) return Icons.mic;
    if (state == RehearsalState.listeningForMe) return Icons.skip_next;
    if (state == RehearsalState.ready) return Icons.play_arrow;
    return Icons.skip_next;
  }

  String _mainActionLabel(RehearsalState state, bool isMyLine) {
    if (state == RehearsalState.ready && isMyLine) return 'Speak';
    if (state == RehearsalState.listeningForMe) return 'Skip';
    if (state == RehearsalState.ready) return 'Play';
    return 'Next';
  }

  void _mainAction(RehearsalState state, bool isMyLine, int totalLines) {
    switch (state) {
      case RehearsalState.ready:
        _processCurrentLine();
      case RehearsalState.playingOther:
        // Mark state as ready BEFORE stopping TTS so the completion handler
        // sees we're no longer in playingOther and won't double-advance.
        ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
        _tts.stop(reason: 'skipOtherLine');
        try { _player.stop(); } catch (_) {}
        _advanceLine(totalLines);
      case RehearsalState.listeningForMe:
        // Accept whatever was said and advance (manual skip)
        // Discard pending transcription to avoid delayed callbacks
        _stt.stop(discard: true);
        _recordCurrentLineAttempt(
            skipped: _matchScore.value <
                (ref.read(matchThresholdProvider) / 100.0));
        _advanceLine(totalLines);
      case RehearsalState.paused:
      case RehearsalState.sceneComplete:
        break;
    }
  }

  Widget _controlButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool primary = false,
  }) {
    final color = onTap == null
        ? Colors.grey[700]
        : primary
            ? Theme.of(context).colorScheme.primary
            : Colors.white70;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: primary ? 56 : 44,
            height: primary ? 56 : 44,
            decoration: BoxDecoration(
              color: primary
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.2)
                  : Colors.grey[850],
              shape: BoxShape.circle,
              border: primary
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2)
                  : null,
            ),
            child: Icon(icon, color: color, size: primary ? 28 : 22),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10)),
        ],
      ),
    );
  }

  // ── Cue-to-Cue Filtering ─────────────────────────────

  // Memo for _getRehearsalLines: it's called from build() (and per line
  // advance), and the underlying script/scene/character/mode change rarely —
  // recomputing the filtered list per rebuild is pure waste.
  List<ScriptLine>? _rehearsalLinesCache;
  Object? _rehearsalLinesKey;

  /// Returns the dialogue lines to rehearse, filtered for cue-to-cue mode
  /// if enabled. In cue-to-cue mode, only the actor's lines plus one cue
  /// line before each are included.
  List<ScriptLine> _getRehearsalLines(
      ParsedScript script, ScriptScene scene, String? myCharacter) {
    final mode = ref.read(rehearsalModeProvider);
    final key = (identityHashCode(script), scene.id, myCharacter, mode);
    if (_rehearsalLinesCache != null && _rehearsalLinesKey == key) {
      return _rehearsalLinesCache!;
    }

    final sceneLines = script.linesInScene(scene);
    final allDialogue =
        sceneLines.where((l) => l.lineType == LineType.dialogue).toList();

    List<ScriptLine> result;
    if (mode != RehearsalMode.cuePractice || myCharacter == null) {
      result = allDialogue;
    } else {
      // Build a filtered list: for each of the actor's lines, include
      // the immediately preceding line (the cue) plus the actor's line.
      final filtered = <ScriptLine>[];
      final included = <String>{};
      for (var i = 0; i < allDialogue.length; i++) {
        if (allDialogue[i].isForCharacter(myCharacter)) {
          // Add cue line (the one before) if not already added
          if (i > 0 && included.add(allDialogue[i - 1].id)) {
            filtered.add(allDialogue[i - 1]);
          }
          if (included.add(allDialogue[i].id)) {
            filtered.add(allDialogue[i]);
          }
        }
      }
      result = filtered;
    }

    _rehearsalLinesCache = result;
    _rehearsalLinesKey = key;
    return result;
  }

  // ── Engine Logic ──────────────────────────────────────

  /// Process the current line: play audio/TTS for others, or start listening for me.
  void _processCurrentLine() {
    if (_processingLine) {
      // A LEGITIMATE advance can land inside the debounce window — an
      // all-stage-direction line's completion arrives while the previous
      // processCurrentLine is still within its 50 ms guard. Dropping the
      // call silently hung the rehearsal (field: stuck dead after
      // "(To audience: ...)" until the actor gave up). Defer instead of
      // dropping; duplicates coalesce into one deferred run.
      _deferredProcess ??= Timer(const Duration(milliseconds: 60), () {
        _deferredProcess = null;
        if (mounted) _processCurrentLine();
      });
      return;
    }
    // Delayed callbacks (inter-line pacing, advance, jump-back) land here after
    // the user may have tapped Pause — honor it instead of resuming playback.
    if (ref.read(rehearsalStateProvider) == RehearsalState.paused) {
      _dlog.log(LogCategory.rehearsal,
          'processCurrentLine: paused — not starting the next line');
      return;
    }
    _processingLine = true;
    Future.delayed(const Duration(milliseconds: 50), () {
      _processingLine = false;
    });

    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final currentIdx = ref.read(currentLineIndexProvider);

    if (script == null || scene == null) {
      _dlog.log(LogCategory.rehearsal,
          'processCurrentLine: script=${script != null} scene=${scene != null}');
      return;
    }

    final sceneLines = script.linesInScene(scene);
    _dlog.log(LogCategory.rehearsal,
        'processCurrentLine: scene="${scene.sceneName}" '
        'start=${scene.startLineIndex} end=${scene.endLineIndex} '
        'totalLines=${script.lines.length} sceneLines=${sceneLines.length}');

    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);

    _dlog.log(LogCategory.rehearsal,
        'processCurrentLine: dialogueLines=${dialogueLines.length} '
        'currentIdx=$currentIdx char=$myCharacter');

    if (currentIdx >= dialogueLines.length) {
      _completeScene(dialogueLines);
      return;
    }

    final line = dialogueLines[currentIdx];
    final mode = ref.read(rehearsalModeProvider);
    // In readthrough mode, no line is "mine" — all lines are played via TTS.
    final isMyLine = mode != RehearsalMode.readthrough &&
        myCharacter != null &&
        line.isForCharacter(myCharacter);

    // Update lock screen / AirPods now-playing info
    final production = ref.read(currentProductionProvider);
    _mediaControl.updateNowPlaying(
      title: production?.title ?? scene.sceneName,
      character: '${line.character}: ${line.text.length > 60 ? '${line.text.substring(0, 57)}...' : line.text}',
    );

    // Always scroll to the current line so the actor can see it
    _scrollToCurrentLine();

    // Reset attempt tracking for new line
    _currentAttemptCount = 0;
    _currentBestScore = 0.0;

    if (isMyLine) {
      _dlog.log(LogCategory.rehearsal, 'MY LINE: ${line.character} → "${line.text.length > 40 ? '${line.text.substring(0, 37)}...' : line.text}"');
      // While the actor reads their line, synthesize the next other-character
      // line's Kokoro audio in the background so playback starts instantly.
      _prefetchLineAudio(
          _nextOtherLine(dialogueLines, currentIdx, myCharacter, mode));
      _startListeningForMyLine(line);
    } else {
      _playOtherLine(line);
    }
  }

  /// Everything that must happen exactly once when the scene finishes,
  /// whichever path got us here (auto-advance, actor's last line, playback
  /// completion): stop keeping the screen awake, record the session in
  /// history, drop the resume checkpoint, and offer to save recordings.
  void _completeScene(List<ScriptLine> dialogueLines) {
    // Clear any lingering toast so it can't sit on top of the summary.
    _toastTimer?.cancel();
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ref.read(rehearsalStateProvider.notifier).state =
        RehearsalState.sceneComplete;
    WakelockPlus.disable(); // Allow screen to sleep at scene end
    if (dialogueLines.isNotEmpty) _saveSession(dialogueLines);
    _progressSaveTimer?.cancel(); // don't let a late debounce re-checkpoint
    _clearProgressCheckpoint(); // finished the scene — nothing to resume
    _offerToSaveRehearsalRecordings();
  }

  /// Return the next dialogue line after [currentIdx] that is NOT the actor's
  /// line (the next line we'll play via TTS), or null if there is none.
  ScriptLine? _nextOtherLine(
    List<ScriptLine> dialogueLines,
    int currentIdx,
    String? myCharacter,
    RehearsalMode mode,
  ) {
    for (var i = currentIdx + 1; i < dialogueLines.length; i++) {
      final l = dialogueLines[i];
      final isMine = mode != RehearsalMode.readthrough &&
          myCharacter != null &&
          l.isForCharacter(myCharacter);
      if (!isMine) return l;
    }
    return null;
  }

  /// Best-effort prefetch: synthesize [line]'s Kokoro audio in the background
  /// so the eventual [_playOtherLine] call can start playback instantly.
  /// No-op unless the line will actually be voiced by Kokoro TTS (no primary
  /// or understudy recording) and hasn't already been prefetched.
  Future<void> _prefetchLineAudio(ScriptLine? line) async {
    if (!mounted || line == null) return;

    // Skip if this is the actor's line — those aren't played via TTS.
    final mode = ref.read(rehearsalModeProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final isMine = mode != RehearsalMode.readthrough &&
        myCharacter != null &&
        line.isForCharacter(myCharacter);
    if (isMine) return;

    // If a real recording exists (primary, or understudy fallback), it's played
    // directly rather than via TTS — so warm the loudness cache instead so
    // volume normalization adds no latency when the line plays.
    final rec = ref.read(recordingsProvider)[line.id] ??
        (ref.read(understudyFallbackProvider)
            ? ref.read(understudyRecordingsProvider)[line.id]
            : null);
    if (rec != null) {
      AudioLevelService.instance.prefetch(rec.localPath);
      return;
    }

    // Already prefetched or in flight — never start a duplicate synthesis.
    if (_ttsPrefetch.containsKey(line.id)) return;

    // Same voice resolution as _playOtherLine.
    final voiceCharacter = line.multiCharacters.isNotEmpty
        ? line.multiCharacters.first
        : line.character;
    // Synthesize at the SAME speed _playOtherLine will use — Kokoro bakes speed
    // into the audio, so a mismatch would play the prefetched line at the wrong
    // speed (e.g. the first time a character speaks at a non-default speed).
    final fastMode = ref.read(fastModeEnabledProvider);
    final speed = fastMode
        ? ref.read(fastModeSpeedProvider)
        : ref.read(playbackSpeedProvider);
    _tts.setCharacterSpeed(voiceCharacter, speed);
    // Per-chunk futures, in the map BEFORE any synthesis completes, so
    // playback consumes in-flight work chunk by chunk. speak() handles a
    // chunk future resolving null (failed/cancelled prefetch) by
    // re-synthesizing that chunk on demand.
    final chunkFutures =
        _tts.prepareKokoro(line.text, character: voiceCharacter);
    if (chunkFutures != null) _ttsPrefetch[line.id] = chunkFutures;
  }

  /// Play another character's line.
  ///
  /// Audio priority chain:
  ///   1. Real recording by primary actor
  ///   2. Real recording by understudy (if understudy fallback enabled)
  ///   3. Voice-cloned audio (if voice cloning enabled)
  ///   4. Kokoro TTS (default fallback — never uses system TTS)
  bool _orphanWarningChecked = false;

  /// Surface — never silently swallow — the case where shared recordings exist
  /// but none of their line IDs are in the current script (e.g. the script was
  /// re-imported or pushed with regenerated IDs, orphaning every recording).
  /// Without this, rehearsal just plays TTS and the actor never learns their
  /// castmates' recordings are present-but-mismatched.
  void _maybeWarnOrphanedRecordings() {
    if (_orphanWarningChecked) return;
    final script = ref.read(currentScriptProvider);
    if (script == null) return;
    final recIds = <String>{
      ...ref.read(recordingsProvider).keys,
      ...ref.read(understudyRecordingsProvider).keys,
    };
    if (recIds.isEmpty) return; // nothing synced yet — re-check on the next line
    _orphanWarningChecked = true;

    final scriptIds = script.lines.map((l) => l.id).toSet();
    final orphaned = recIds.where((id) => !scriptIds.contains(id)).length;
    if (orphaned == 0) return;

    _dlog.logError(
        LogCategory.rehearsal,
        'Orphaned recordings: $orphaned/${recIds.length} shared recordings have '
        'line IDs not in this script — they will NOT play (script version mismatch)');
    if (mounted) {
      ScaffoldMessenger.of(context).showAutoToast(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
              "$orphaned shared recording(s) don't match this script version — "
              "you'll hear computer voices for them. Re-sync the script so the "
              "whole cast shares the same lines."),
        ),
      );
    }
  }

  /// Drop the live transcript and the match bar between lines. No setState:
  /// the notifiers repaint their own two widgets, and every caller has
  /// already moved a provider that rebuilds the rest of the screen.
  void _clearMatchFeedback() {
    _showMatchFeedback.value = false;
    _recognizedText.value = '';
  }

  /// Session-start pre-roll: queue synthesis for the first few TTS lines and
  /// WAIT (with visible progress) until they're ready before playback starts.
  /// Fresh material synthesizes at ~realtime on Android, so starting blind
  /// meant several seconds of unexplained dead air on the first line and no
  /// pipeline lead. Cache hits resolve instantly, so a re-run skips the wait
  /// (the banner only appears if readiness takes >300 ms).
  Future<void> _preRollVoices(ScriptLine firstLine) async {
    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final mode = ref.read(rehearsalModeProvider);
    if (script == null || scene == null) return;
    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);

    // QUEUE the first line plus the next two TTS lines (primes the engine),
    // but only WAIT for the first line plus the opening chunk of the second:
    // that guarantees a gapless first transition without holding the start
    // hostage to three full lines of ~realtime synthesis (field: "1 of 5"
    // took noticeably longer than just starting used to).
    _prefetchLineAudio(firstLine);
    var idx = dialogueLines.indexOf(firstLine);
    ScriptLine? secondLine;
    for (var n = 0; n < 2 && idx >= 0; n++) {
      final next = _nextOtherLine(dialogueLines, idx, myCharacter, mode);
      if (next == null) break;
      _prefetchLineAudio(next);
      secondLine ??= next;
      idx = dialogueLines.indexOf(next);
    }

    final futures = <Future<String?>>[
      ...?_ttsPrefetch[firstLine.id],
      if (secondLine != null &&
          (_ttsPrefetch[secondLine.id]?.isNotEmpty ?? false))
        _ttsPrefetch[secondLine.id]!.first,
    ];
    if (futures.isEmpty) return;

    final total = futures.length;
    var done = 0;
    var finished = false;
    // Only surface the banner if readiness actually takes a moment.
    final showTimer = Timer(const Duration(milliseconds: 300), () {
      if (!finished && mounted) _preparingVoices.value = (done, total);
    });
    for (final f in futures) {
      f.whenComplete(() {
        done++;
        if (!finished && mounted && _preparingVoices.value != null) {
          _preparingVoices.value = (done, total);
        }
      }).ignore();
    }
    try {
      await Future.wait(futures.map((f) => f.catchError((_) => null)))
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      // Timeout or failure — start anyway; speak() re-synthesizes on demand.
    }
    finished = true;
    showTimer.cancel();
    if (mounted) _preparingVoices.value = null;
  }

  Future<void> _playOtherLine(ScriptLine line) async {
    ref.read(rehearsalStateProvider.notifier).state =
        RehearsalState.playingOther;
    _clearMatchFeedback();

    if (!_didPreRoll) {
      _didPreRoll = true;
      await _preRollVoices(line);
      if (!mounted ||
          ref.read(rehearsalStateProvider) != RehearsalState.playingOther) {
        return; // closed or state changed while preparing
      }
    }

    _maybeWarnOrphanedRecordings();

    _dlog.log(LogCategory.rehearsal,
        'Playing: ${line.character} — "${line.text.length > 40 ? '${line.text.substring(0, 37)}...' : line.text}"');

    final fastMode = ref.read(fastModeEnabledProvider);
    final speed = fastMode
        ? ref.read(fastModeSpeedProvider)
        : ref.read(playbackSpeedProvider);

    // 1. Check for a primary actor recording first
    final recordings = ref.read(recordingsProvider);
    final recording = recordings[line.id];

    if (recording != null) {
      try {
        // The actor's own line was just captured under the .record category;
        // force a playback session or the castmate's recording plays silently.
        await PlaybackSession.ensurePlayback();
        await _player.setFilePath(recording.localPath);
        await _player.setSpeed(speed);
        // Normalize loudness so castmates' recordings don't jump in volume.
        await _player
            .setVolume(await AudioLevelService.instance.volumeFor(recording.localPath));
        await _player.play();
        return;
      } catch (e) {
        // Fall through to understudy — but leave a trace: a corrupt file or
        // session error here is why an actor hears TTS instead of their
        // castmate, and it was undiagnosable without a log.
        _dlog.logError(LogCategory.rehearsal,
            'Recording playback failed for ${line.id}, falling back', e);
      }
    }

    // 2. Understudy fallback — use understudy recording if primary is missing
    final understudyFallback = ref.read(understudyFallbackProvider);
    if (understudyFallback) {
      final understudyRecordings = ref.read(understudyRecordingsProvider);
      final understudyRecording = understudyRecordings[line.id];

      if (understudyRecording != null) {
        try {
          await PlaybackSession.ensurePlayback();
          await _player.setFilePath(understudyRecording.localPath);
          await _player.setSpeed(speed);
          await _player.setVolume(await AudioLevelService.instance
              .volumeFor(understudyRecording.localPath));
          await _player.play();
          return;
        } catch (e) {
          // Fall through to TTS (logged for the same reason as above).
          _dlog.logError(LogCategory.rehearsal,
              'Understudy playback failed for ${line.id}, falling back', e);
        }
      }
    }

    // 3. Kokoro TTS fallback (never uses system TTS)
    // For multi-character lines, use the first individual character's voice
    final voiceCharacter = line.multiCharacters.isNotEmpty
        ? line.multiCharacters.first
        : line.character;
    _tts.setCharacterSpeed(voiceCharacter, speed);
    _dlog.log(LogCategory.tts,
        'Fast mode: ${ref.read(fastModeEnabledProvider)}, speed=$speed for $voiceCharacter');
    // Prefetched (possibly still in flight) — hand the chunk futures to
    // speak(), which starts playback on the first resolved chunk and
    // re-synthesizes any chunk whose prefetch failed or was cancelled.
    final prefetched = _ttsPrefetch.remove(line.id);
    if (prefetched != null) {
      _dlog.log(LogCategory.tts, 'Kokoro: playing prefetched audio');
      await _tts.speak(line.text,
          character: voiceCharacter, precomputedChunks: prefetched);
    } else {
      await _tts.speak(line.text, character: voiceCharacter);
    }
    // Safety net only — the real prefetch trigger is onPlaybackStarted
    // (speak() returns after playback COMPLETES, far too late to overlap).
    _prefetchUpcomingOtherLines();
    // Completion handled by TTS completion handler
  }

  /// Queue synthesis for the next TWO other-character lines. Called from
  /// [TtsService.onPlaybackStarted] — the moment a line's audio starts — so
  /// their synthesis genuinely overlaps this line's playback. That anchor is
  /// what makes playthrough flow on Android, where synthesis is ~real-time
  /// (RTF 0.9): hooked "after speak returned" it fired at playback END and
  /// back-to-back TTS lines each sat silent for 6-10 s despite "prefetching".
  /// Two deep because one-deep only breaks even at real-time synthesis; the
  /// future-map dedupe makes repeat calls free.
  void _prefetchUpcomingOtherLines() {
    if (!mounted) return;
    final state = ref.read(rehearsalStateProvider);
    if (state != RehearsalState.playingOther &&
        state != RehearsalState.listeningForMe) {
      return;
    }
    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final mode = ref.read(rehearsalModeProvider);
    if (script == null || scene == null) return;
    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);
    final currentIdx = ref.read(currentLineIndexProvider);
    // Read-through is wall-to-wall TTS and on-device synthesis runs near
    // realtime (RTF ~0.9 on Android), so the pipe needs more lookahead to
    // build a lead during long lines; with user lines interleaved a deep
    // queue would mostly get cancelled, so keep it shallow there.
    final depth = mode == RehearsalMode.readthrough ? 4 : 2;
    var idx = currentIdx;
    for (var n = 0; n < depth; n++) {
      final next = _nextOtherLine(dialogueLines, idx, myCharacter, mode);
      if (next == null) break;
      _prefetchLineAudio(next);
      final nextIdx = dialogueLines.indexOf(next);
      if (nextIdx < 0) break;
      idx = nextIdx;
    }
  }

  /// Called when another character's line finishes playing.
  void _onOtherLineFinished() {
    if (!mounted) return;
    final rehearsalState = ref.read(rehearsalStateProvider);
    // Only advance if we were actually playing another character's line.
    // This prevents double-advance when _tts.stop() is called explicitly
    // (e.g., during skip/advance) from triggering this handler.
    if (rehearsalState != RehearsalState.playingOther) {
      _dlog.log(LogCategory.rehearsal,
          'onOtherLineFinished ignored (state=${rehearsalState.name})');
      return;
    }
    _dlog.log(LogCategory.rehearsal, 'Other line finished, advancing');

    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    if (script == null || scene == null) return;

    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);
    final currentIdx = ref.read(currentLineIndexProvider);

    if (currentIdx + 1 >= dialogueLines.length) {
      ref.read(currentLineIndexProvider.notifier).state = currentIdx + 1;
      _completeScene(dialogueLines);
      _scrollToCurrentLine();
      return;
    }

    // Advance and process next
    ref.read(currentLineIndexProvider.notifier).state = currentIdx + 1;
    _scrollToCurrentLine();

    // Check if next line is the actor's — if so, start listening immediately
    // so there's no awkward pause. Only add pacing delay between other lines.
    final nextLine = dialogueLines[currentIdx + 1];
    final mode = ref.read(rehearsalModeProvider);
    final isNextMine = mode != RehearsalMode.readthrough &&
        myCharacter != null &&
        nextLine.isForCharacter(myCharacter);

    if (isNextMine) {
      // Actor's turn — start listening right away
      if (mounted) _processCurrentLine();
    } else {
      // Another character's line — pacing delay for natural feel
      final fastMode = ref.read(fastModeEnabledProvider);
      final delayMs = fastMode
          ? ref.read(fastModeLineDelayProvider)
          : ref.read(lineDelayProvider);
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (mounted) _processCurrentLine();
      });
    }
  }

  /// Start STT listening for the actor's line.
  Future<void> _startListeningForMyLine(ScriptLine line) async {
    ref.read(rehearsalStateProvider.notifier).state =
        RehearsalState.listeningForMe;
    _clearMatchFeedback();

    // Release TTS audio session so STT can acquire the microphone.
    // Without this, the audioPlayer holds the session in playback mode
    // and STT silently fails to start recording.
    await _tts.releaseAudioSession();

    // Haptic feedback: it's your turn
    HapticFeedback.mediumImpact();

    // Android can't run SpeechRecognizer and the audio recorder on the mic at
    // the same time. Rehearsal always captures the actor's lines (to share with
    // castmates), so on Android we record the line and advance on mic-silence
    // instead of live word-matching.
    if (Platform.isAndroid) {
      await _startRecordOnlyCapture(line);
      return;
    }

    // If STT isn't ready yet (deferred init still running), wait for it —
    // but not when init already FAILED: polling a dead recognizer just
    // freezes every actor line for 5 seconds.
    if (!_stt.isAvailable && !_sttInitFailed) {
      _dlog.log(LogCategory.rehearsal, 'Waiting for STT init...');
      // Poll briefly — STT init typically takes 1-3 seconds
      for (var i = 0; i < 50 && !_stt.isAvailable && mounted; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
    }

    final available = _stt.isAvailable;
    if (!available) {
      // STT truly not available — wait for manual advance, and tell the actor
      // why nothing is listening (once per rehearsal, not per line).
      _dlog.log(LogCategory.rehearsal, 'STT not available, manual advance');
      if (!_sttUnavailableNoticeShown) {
        _sttUnavailableNoticeShown = true;
        ScaffoldMessenger.of(context).showAutoToast(const SnackBar(
          content: Text('Speech recognition isn\'t available — tap the '
              'forward arrow to advance past your lines.'),
          duration: Duration(seconds: 6),
        ));
      }
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
      return;
    }

    final threshold = ref.read(matchThresholdProvider) / 100.0;

    _currentAttemptCount++;
    _matchConfirmed = false;
    _lastRecognizedRaw = '';
    _loggedFirstResultForLine = false;
    _listeningStartedAt = DateTime.now();
    _micLevel.value = 0.0;

    // Build vocabulary hints: the expected line as a phrase + its individual
    // words. Keep hints focused — flooding with script-wide vocabulary
    // (character names, etc.) dilutes the signal and confuses the recognizer.
    final cleanLine = line.text.replaceAll(RegExp("[^\\w\\s']"), '');
    final wordHints = cleanLine.split(RegExp(r'\s+'))
        .where((w) => w.length > 1)
        .toSet()
        .toList();
    // Full expected phrase + its individual words only
    final vocabHints = <String>[cleanLine, ...wordHints];

    // Start silence timer — if no new results for a while, auto-advance
    _resetSilenceTimer(line);

    // Live mic level for the listening indicator (smoothed in SttService).
    // ValueNotifier, not setState: only the mic chip repaints per event.
    // While the actor is audibly speaking, push the hard silence timer back —
    // it is otherwise only reset by NEW recognition results, and a recognizer
    // producing sparse partials (field case: one partial then nothing) let it
    // fire mid-read and cut the actor off at 22-57% scores.
    _stt.onLevel = (level) {
      if (!mounted) return;
      if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) {
        return;
      }
      _micLevel.value = level;
      if (level >= SttService.silenceThreshold) {
        _resetSilenceTimer(line);
      }
    };

    // Energy-based endpointing: once the match threshold is crossed,
    // advance as soon as the actor's audio goes quiet for the tunable
    // pause window instead of waiting the full 1.2s no-new-results debounce.
    // The debounce timer below stays as a fallback (e.g. if level events stop).
    _stt.onSilence = (silence) {
      if (!mounted) return;
      if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) {
        return;
      }
      if (_matchScore.value >= threshold &&
          silence >= _requiredAdvanceSilence(line)) {
        _confirmLineMatch(line);
      }
    };

    await _stt.listen(
      continuous: true,
      onResult: (recognized) => _handleRecognizedForLine(line, recognized),
      onDone: () {
        if (!mounted) return;
        // Listening ended but no match — stay on this line, let user retry or skip
        if (ref.read(rehearsalStateProvider) == RehearsalState.listeningForMe) {
          ref.read(rehearsalStateProvider.notifier).state =
              RehearsalState.ready;
        }
      },
      vocabularyHints: vocabHints,
    );

    // Start audio capture AFTER listen() — the audio engine must be running
    _startCaptureForLine(line);
  }

  /// Shared per-result matching pipeline: vocabulary correction → score →
  /// UI notifiers → threshold/confirm-timer advance. Fed by the platform
  /// recognizer on iOS/macOS ([SttService.listen]) and by the on-device
  /// streaming recognizer on Android ([LiveAsrService.onPartial]) — both
  /// deliver cumulative transcripts of the current utterance.
  void _handleRecognizedForLine(ScriptLine line, String recognized) {
    if (!mounted) return;
    // Ignore stale results if we've moved past this line
    if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) {
      return;
    }
    final threshold = ref.read(matchThresholdProvider) / 100.0;
    final production = ref.read(currentProductionProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);

    // Reset silence timer on each new result
    _resetSilenceTimer(line);
    _lastRecognizedRaw = recognized;

    // Apply vocabulary correction before scoring
    final corrected = production != null
        ? _sttVocab.correct(
            recognized: recognized,
            expectedText: line.text,
            productionId: production.id,
            actorId: myCharacter,
          )
        : recognized;

    final score = SttService.matchScore(line.text, corrected);
    // Without this the debug log shows only "line started / line stopped",
    // so a run where recognition silently produced nothing is
    // indistinguishable from one where it produced the wrong words. Log
    // the first result per line (proves the recognizer is alive) and then
    // only meaningful score changes, to stay readable.
    if (!_loggedFirstResultForLine) {
      _loggedFirstResultForLine = true;
      _dlog.log(LogCategory.stt,
          'first result: heard="${corrected.length > 60 ? '${corrected.substring(0, 57)}...' : corrected}" '
          'score=${(score * 100).toStringAsFixed(0)}% threshold=${(threshold * 100).toStringAsFixed(0)}%');
    }
    // Notifiers, not setState: partial results arrive several times a
    // second and setState here rebuilt the whole screen — including the
    // ~145 offscreen list items cacheExtent: 10000 keeps alive — for what
    // is really a two-widget update.
    _recognizedText.value = corrected;
    _matchScore.value = score;
    _showMatchFeedback.value = corrected.isNotEmpty;

    if (score > _currentBestScore) _currentBestScore = score;

    // Auto-advance once the match exceeds threshold, after the actor stops.
    // A confirmation timer fires only if no new STT results arrive for a
    // window after the score crosses the threshold. When coverage is
    // near-complete the actor has clearly finished the whole line, so use a
    // short window for a fast response; a partial-but-over-threshold score
    // (still mid long line) keeps the longer 1.2s window so we don't cut a
    // multi-sentence line short. (Energy endpointing also advances on
    // mic-silence.)
    if (score >= threshold) {
      _matchConfirmTimer?.cancel();
      final confirmMs =
          score >= _fullLineMatchThreshold ? _fastConfirmMs : 1200;
      _quietStreak = 0; // fresh evidence of speech — restart the quiet count
      _matchConfirmTimer = Timer(Duration(milliseconds: confirmMs), () {
        _confirmIfActorQuiet(line);
      });
    } else {
      // Score dropped below threshold (e.g., new words recognized that
      // don't match) — cancel pending advance
      _matchConfirmTimer?.cancel();
    }
  }

  /// How long the actor must be quiet before an over-threshold score may
  /// advance the line.
  ///
  /// The score alone cannot distinguish "finished (some words misheard)"
  /// from "70-80% of the way through and pausing for effect" — and with a
  /// healthy recognizer, scores routinely cross the threshold MID-line, so
  /// the bare tunable window (default 500 ms) turned every acting pause
  /// into an exit (field: advanced at 70% and 76% "every time"). The
  /// discriminator is whether the transcript shows the actor REACHED THE
  /// LINE'S ENDING:
  ///   - ending heard → the normal snappy window;
  ///   - ending not heard → they are mid-line until proven otherwise:
  ///     require a long deliberate pause (they may have paraphrased the
  ///     ending, so never wait forever).
  Duration _requiredAdvanceSilence(ScriptLine line) {
    final base = ref.read(rehearsalAdvanceSilenceMsProvider);
    final tailHeard =
        SttService.heardLineEnding(line.text, _recognizedText.value);
    return Duration(milliseconds: tailHeard ? base : (base + 2000));
  }

  /// Confirm the match only once the actor has actually stopped talking.
  ///
  /// The confirm timer fires after N ms of no NEW recognition results — but
  /// "no new results" is not "done speaking": when the actor hits words the
  /// recognizer can't transcribe (OCR-garbled text, mumbled names) partials
  /// stop changing while speech continues, and the timer used to cut the
  /// actor off mid-line. Worse, the recognizer can predictively complete the
  /// whole line from its contextual hint — 100% score mid-read (field case:
  /// 1.3 s after the first partial, 3.8 s into a longer line) — and a single
  /// mic sample can land in a comma-breath.
  ///
  /// The tiebreaker is TIME PLAUSIBILITY: a real read of an N-word line
  /// cannot finish faster than a fast reader speaks (~200 ms/word). When the
  /// elapsed time makes the match physically possible, confirm on the first
  /// quiet sample — the snappy path, which is nearly every line. Only a
  /// too-fast "match" (necessarily hint completion) pays for sustained quiet
  /// (~450 ms), so a breath can't end a line the actor can't have finished.
  int _quietStreak = 0;

  void _confirmIfActorQuiet(ScriptLine line) {
    if (!mounted || _matchConfirmed) return;
    if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) {
      return;
    }
    if (_stt.inputLevel >= SttService.silenceThreshold) {
      _quietStreak = 0;
      _matchConfirmTimer?.cancel();
      _matchConfirmTimer = Timer(const Duration(milliseconds: 300), () {
        _confirmIfActorQuiet(line);
      });
      return;
    }

    // Stage directions aren't spoken (matchScore already excludes them), so
    // they mustn't inflate the reading-time floor either — "(crossing to the
    // window, softly)" would otherwise make a short line look under-read.
    final spokenText = TtsService.stripStageDirections(line.text);
    final wordCount =
        spokenText.isEmpty ? 0 : spokenText.split(RegExp(r'\s+')).length;
    final minPlausible = Duration(milliseconds: 200 * wordCount);
    final plausible =
        DateTime.now().difference(_listeningStartedAt) >= minPlausible;
    final tailHeard =
        SttService.heardLineEnding(line.text, _recognizedText.value);

    // Quiet needed before confirming, in ~150 ms samples:
    //   ending heard + plausible timing → first quiet sample (snappy);
    //   ending heard but impossibly fast → hint completion, ~450 ms;
    //   ending NOT heard → actor is likely mid-line, ~1.5 s.
    final needed = tailHeard ? (plausible ? 1 : 3) : 10;

    _quietStreak++;
    if (_quietStreak < needed) {
      _matchConfirmTimer?.cancel();
      _matchConfirmTimer = Timer(const Duration(milliseconds: 150), () {
        _confirmIfActorQuiet(line);
      });
      return;
    }
    _confirmLineMatch(line);
  }

  /// Log how a line actually ended. "advanced with no recognition at all" is
  /// the signature of a dead recognizer (Apple returning error 216 / "No
  /// speech detected"), which reads to the actor as "it just sat there".
  void _logLineOutcome(String how) {
    _dlog.log(
        LogCategory.stt,
        'line ended ($how): '
        '${_loggedFirstResultForLine ? 'score=${(_matchScore.value * 100).toStringAsFixed(0)}%' : 'NO recognition results at all'}');
  }

  /// The actor finished their line and the match held — stop listening,
  /// learn from the attempt, and advance. Called from both the energy
  /// endpointing (mic silence) and the no-new-results confirm timer;
  /// [_matchConfirmed] makes the two triggers race-safe.
  void _confirmLineMatch(ScriptLine line) {
    if (!mounted || _matchConfirmed) return;
    if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) {
      return;
    }
    _matchConfirmed = true;
    _logLineOutcome('matched');

    _matchConfirmTimer?.cancel();
    _silenceTimer?.cancel();
    _stopCaptureForLine(line);
    _stt.stop();
    HapticFeedback.lightImpact();

    // Learn from this successful attempt
    final production = ref.read(currentProductionProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    if (production != null && myCharacter != null &&
        _lastRecognizedRaw.isNotEmpty) {
      _sttVocab.learnFromAttempt(
        productionId: production.id,
        actorId: myCharacter,
        recognized: _lastRecognizedRaw,
        expected: line.text,
      );
    }

    // Record the attempt
    _recordAttempt(line, skipped: false);

    // Advance
    final s = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    if (s == null || scene == null) return;
    final dialogueLines = _getRehearsalLines(s, scene, myCharacter);
    _advanceLine(dialogueLines.length);
  }

  /// Reset the silence timer. When no new STT results arrive for
  /// [_silenceTimeout], auto-advance with whatever score we have.
  void _resetSilenceTimer(ScriptLine line) {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(_silenceTimeout, () {
      if (!mounted) return;
      final state = ref.read(rehearsalStateProvider);
      if (state != RehearsalState.listeningForMe) return;

      // Never time out an actor who is audibly mid-line — if level events
      // stalled but the mic still hears speech, come back shortly instead.
      if (_stt.inputLevel >= SttService.silenceThreshold) {
        _silenceTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) _resetSilenceTimer(line);
        });
        return;
      }

      _logLineOutcome('silence timeout');
      _stopCaptureForLine(line);
      _stt.stop();

      // Record the attempt with whatever score was achieved
      final threshold = ref.read(matchThresholdProvider) / 100.0;
      _recordAttempt(line, skipped: _matchScore.value < threshold);

      // Advance to next line
      final script = ref.read(currentScriptProvider);
      final scene = ref.read(selectedSceneProvider);
      final mc = ref.read(rehearsalCharacterProvider);
      if (script == null || scene == null) return;
      final dialogueLines = _getRehearsalLines(script, scene, mc);
      _advanceLine(dialogueLines.length);
    });
  }

  void _advanceLine(int totalLines) {
    _silenceTimer?.cancel();
    _matchConfirmTimer?.cancel();
    // Stop any in-progress audio capture before advancing
    if (_isCapturingAudio) {
      _stt.stopRecording(); // fire-and-forget, file will be finalized
      _isCapturingAudio = false;
    }
    _tts.stop(reason: 'advanceLine');
    _stt.stop(discard: true);
    try { _player.stop(); } catch (_) {}

    final current = ref.read(currentLineIndexProvider);
    if (current + 1 >= totalLines) {
      ref.read(currentLineIndexProvider.notifier).state = current + 1;
      // The scene's last line being the actor's lands here — it must record
      // the session in history exactly like the other completion paths.
      final script = ref.read(currentScriptProvider);
      final scene = ref.read(selectedSceneProvider);
      final myCharacter = ref.read(rehearsalCharacterProvider);
      _completeScene(script != null && scene != null
          ? _getRehearsalLines(script, scene, myCharacter)
          : const []);
      _scrollToCurrentLine();
      return;
    }

    ref.read(currentLineIndexProvider.notifier).state = current + 1;
    ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
    _scrollToCurrentLine();

    _clearMatchFeedback();

    // Auto-play next line after minimal delay
    if (_autoPlay) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _processCurrentLine();
      });
    }
  }

  void _jumpBack(int jumpCount, int totalLines) {
    if (totalLines <= 0) return;
    _silenceTimer?.cancel();
    _matchConfirmTimer?.cancel();
    _tts.stop(reason: 'jumpBack');
    _stt.stop(discard: true);
    try { _player.stop(); } catch (_) {}

    final current = ref.read(currentLineIndexProvider);
    final newIdx = (current - jumpCount).clamp(0, totalLines - 1);
    ref.read(currentLineIndexProvider.notifier).state = newIdx;
    ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
    _scrollToCurrentLine();

    _clearMatchFeedback();

    // Haptic on jump back
    HapticFeedback.heavyImpact();

    // Auto-play from new position
    if (_autoPlay) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _processCurrentLine();
      });
    }
  }

  void _restartScene() {
    _silenceTimer?.cancel();
    _matchConfirmTimer?.cancel();
    _tts.stop(reason: 'restartScene');
    _stt.stop(discard: true);
    try { _player.stop(); } catch (_) {}

    ref.read(currentLineIndexProvider.notifier).state = 0;
    ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
    _clearProgressCheckpoint(); // starting over — drop any saved position
    // Scene completion released the wakelock — "Run Again" needs it back or
    // the screen sleeps (and iOS suspends the mic) mid-rehearsal.
    WakelockPlus.enable();

    // Reset session tracking
    _sessionStartedAt = DateTime.now();
    _lineAttempts.clear();
    _currentAttemptCount = 0;
    _currentBestScore = 0.0;

    _clearMatchFeedback();

    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );

    if (_autoPlay) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) _processCurrentLine();
      });
    }
  }

  /// Pause the rehearsal because the OS took the audio away (interruption or
  /// route loss). Mirrors _togglePause's pause branch, plus tells the actor
  /// why — a rehearsal that just stops with no explanation reads as a hang.
  void _pauseForInterruption(String reason) {
    final state = ref.read(rehearsalStateProvider);
    if (state != RehearsalState.playingOther &&
        state != RehearsalState.listeningForMe &&
        state != RehearsalState.ready) {
      return; // not mid-rehearsal (complete/paused) — nothing to pause
    }
    _silenceTimer?.cancel();
    _matchConfirmTimer?.cancel();
    if (_isCapturingAudio) {
      _stt.stopRecording(); // finalize whatever was captured
      _isCapturingAudio = false;
    }
    _tts.stop(reason: 'audioInterruption');
    _stt.stop(discard: true);
    try { _player.pause(); } catch (_) {}
    ref.read(rehearsalStateProvider.notifier).state = RehearsalState.paused;
    _dlog.log(LogCategory.rehearsal, 'Rehearsal paused: $reason');
    ScaffoldMessenger.of(context).showAutoToast(SnackBar(
      content: Text('$reason — rehearsal paused. Tap Resume to continue.'),
      duration: const Duration(seconds: 5),
    ));
  }

  void _togglePause(int totalLines) {
    _silenceTimer?.cancel();
    final current = ref.read(rehearsalStateProvider);
    if (current == RehearsalState.paused) {
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
      if (_autoPlay) _processCurrentLine();
    } else {
      _tts.stop(reason: 'pause');
      _stt.stop(discard: true);
      try { _player.pause(); } catch (_) {}
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.paused;
    }
  }

  // ── Remote media control handlers (AirPods / lock screen) ──

  void _handleRemoteJumpBack() {
    if (!mounted || _jumpBackInProgress) return;
    _jumpBackInProgress = true;
    // Release the lock after a short delay so rapid taps are coalesced
    Future.delayed(const Duration(milliseconds: 500), () {
      _jumpBackInProgress = false;
    });
    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final mc = ref.read(rehearsalCharacterProvider);
    if (script == null || scene == null) return;
    final dialogueLines = _getRehearsalLines(script, scene, mc);
    final mode = ref.read(rehearsalModeProvider);

    if (mc != null && mode != RehearsalMode.readthrough && dialogueLines.length > 1) {
      // Find the actor's PREVIOUS cue line (not the one they're
      // currently on, but the one before that), then go 2 lines
      // before it so they hear the full cue leading in.
      final current = ref.read(currentLineIndexProvider);
      final maxIdx = dialogueLines.length - 1;

      // Step 1: Walk back to find the actor's current/most recent line
      var myLine = current.clamp(0, maxIdx);
      while (myLine > 0 && !dialogueLines[myLine].isForCharacter(mc)) {
        myLine--;
      }

      // Step 2: Walk back past it to find the PREVIOUS actor line
      var prevMyLine = (myLine - 1).clamp(0, maxIdx);
      while (prevMyLine > 0 && !dialogueLines[prevMyLine].isForCharacter(mc)) {
        prevMyLine--;
      }
      // If we couldn't find a previous line, use the current one
      if (!dialogueLines[prevMyLine].isForCharacter(mc)) {
        prevMyLine = myLine;
      }

      // Step 3: Go 2 lines before that previous cue
      var target = (prevMyLine - 2).clamp(0, maxIdx);

      // NEVER land on the actor's own line — always land on a cue line
      // so TTS plays and the actor hears the setup
      while (target < maxIdx && dialogueLines[target].isForCharacter(mc)) {
        target = (target - 1).clamp(0, maxIdx);
        if (target == 0) break; // can't go further back
      }

      final jumpCount = (current - target).clamp(1, current);

      _dlog.log(LogCategory.rehearsal,
          'Jump back: current=$current, myLine=$myLine, '
          'prevMyLine=$prevMyLine, target=$target, jump=$jumpCount');

      _jumpBack(jumpCount, dialogueLines.length);
    } else {
      // Listen/readthrough mode — use configured jump count
      final jumpCount = ref.read(jumpBackLinesProvider);
      _jumpBack(jumpCount, dialogueLines.length);
    }
  }

  void _handleRemoteSkip() {
    if (!mounted) return;
    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final mc = ref.read(rehearsalCharacterProvider);
    if (script == null || scene == null) return;
    final dialogueLines = _getRehearsalLines(script, scene, mc);
    _advanceLine(dialogueLines.length);
  }

  void _handleRemotePlayPause() {
    if (!mounted) return;
    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final mc = ref.read(rehearsalCharacterProvider);
    if (script == null || scene == null) return;
    final dialogueLines = _getRehearsalLines(script, scene, mc);
    _togglePause(dialogueLines.length);
  }

  /// Record an attempt for the given line.
  void _recordAttempt(ScriptLine line, {required bool skipped}) {
    _lineAttempts.add(LineAttempt(
      lineId: line.id,
      lineText: line.text.length > 80
          ? '${line.text.substring(0, 77)}...'
          : line.text,
      attemptCount: _currentAttemptCount,
      bestScore: _currentBestScore,
      skipped: skipped,
    ));
  }

  /// Record attempt for the current line (used when manually advancing).
  void _recordCurrentLineAttempt({required bool skipped}) {
    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final currentIdx = ref.read(currentLineIndexProvider);
    if (script == null || scene == null) return;

    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);
    if (currentIdx < dialogueLines.length) {
      final line = dialogueLines[currentIdx];
      if (myCharacter != null && line.isForCharacter(myCharacter)) {
        _recordAttempt(line, skipped: skipped);
      }
    }
  }

  // ── Rehearsal Audio Capture ──────────────────────────

  /// Android path for the actor's line (see [_startListeningForMyLine]).
  ///
  /// The app owns the mic (the platform recognizer won't share it): one native
  /// AudioRecord captures the line to .m4a AND streams PCM up here, where the
  /// on-device recognizer ([LiveAsrService]) produces partial transcripts for
  /// the same live word-matching iOS gets. When the ASR model isn't
  /// downloaded, degrades to the old record-only behavior: advance once the
  /// actor has spoken and gone quiet.
  Future<void> _startRecordOnlyCapture(ScriptLine line) async {
    _currentAttemptCount++;
    _matchConfirmed = false;
    _matchScore.value = 0.0;
    _micLevel.value = 0.0;
    _lastRecognizedRaw = '';
    _loggedFirstResultForLine = false;
    _listeningStartedAt = DateTime.now();

    // Instant when already running (warmed at rehearsal start). When it's
    // still loading — e.g. resuming straight into the actor's line — do NOT
    // hold the mic hostage: start capturing after a short grace and attach
    // matching mid-line when the recognizer arrives (words spoken before then
    // aren't matched, but the recording is complete and the silence timers
    // still advance). Blocking here cost 8.7 s of dead mic in the field.
    final liveAsr = LiveAsrService.instance;
    bool? asrStarted; // null = still loading
    final asrFuture = liveAsr.ensureStarted().then((ok) => asrStarted = ok);
    if (!liveAsr.isRunning) {
      await Future.any([
        asrFuture,
        Future.delayed(const Duration(milliseconds: 250)),
      ]);
    } else {
      asrStarted = true;
    }
    if (!mounted) return;
    final liveMatching = asrStarted == true;
    _liveMatchingActive = liveMatching;

    // Say once per rehearsal why lines don't match live — and how to get it.
    // Only when the engine reported it CAN'T start (model missing) — not
    // while it's merely still loading.
    if (asrStarted == false && !_liveAsrNoticeShown) {
      _liveAsrNoticeShown = true;
      ScaffoldMessenger.of(context).showAutoToast(SnackBar(
        content: const Text('Download "Live Line Matching" and rehearsal '
            'will follow your lines as you speak them.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Download',
          onPressed: () {
            if (mounted) context.push('/ai-models');
          },
        ),
      ));
    }

    // Mic level for the listening indicator. While the actor is audibly
    // speaking, push the hard-cap silence timer back so a long line isn't cut
    // off even when recognition produces nothing.
    _stt.onLevel = (level) {
      if (!mounted) return;
      if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) {
        return;
      }
      _micLevel.value = level;
      if (level >= SttService.silenceThreshold) {
        _resetSilenceTimer(line);
      }
    };

    // Endpoint on silence. With live matching this mirrors iOS: advance only
    // once the match score has crossed the threshold AND the actor has gone
    // quiet. Without it (model not downloaded), speech-then-quiet is all the
    // signal there is.
    final threshold = ref.read(matchThresholdProvider) / 100.0;
    _stt.onSilence = (silence) {
      if (!mounted) return;
      if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) {
        return;
      }
      if (_liveMatchingActive) {
        if (_matchScore.value < threshold) return;
        // Same line-ending tier as iOS: a mid-line pause must not advance.
        if (silence >= _requiredAdvanceSilence(line)) {
          _confirmLineMatch(line);
        }
        return;
      }
      if (silence >=
          Duration(milliseconds: ref.read(rehearsalAdvanceSilenceMsProvider))) {
        _confirmLineMatch(line);
      }
    };

    void attachMatching() {
      liveAsr.onPartial = (text) => _handleRecognizedForLine(line, text);
      SttChannel.instance.onPcm = liveAsr.feedPcm;
      liveAsr.startUtterance();
    }

    if (liveMatching) {
      attachMatching();
    } else if (asrStarted == null) {
      // Still loading — upgrade this line to live matching when it's ready,
      // if the actor is still on it and the mic is still capturing.
      unawaited(asrFuture.then((_) {
        if (asrStarted != true || !mounted || !_isCapturingAudio) return;
        if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) {
          return;
        }
        _dlog.log(LogCategory.stt, 'LiveASR: attached mid-line');
        _liveMatchingActive = true;
        attachMatching();
      }));
    }

    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, 'rehearsal_${line.id}.m4a');
    _dlog.log(LogCategory.rehearsal,
        'Capture(Android): starting for ${line.id.substring(0, 8)}... '
        '(live matching: $liveMatching)');
    final started = await _stt.startLineCapture(path);
    if (started) {
      _isCapturingAudio = true;
      // Hard fallback so a silent/never-ending mic still advances.
      _resetSilenceTimer(line);
    } else {
      // Never silent: tell the user recording didn't happen.
      _dlog.logError(
          LogCategory.error, 'Capture(Android): recording failed to start');
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
                "Couldn't record your line — check microphone permission in Settings."),
          ),
        );
      }
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
    }
  }

  Future<void> _startCaptureForLine(ScriptLine line) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, 'rehearsal_${line.id}.m4a');
      // Capture paths are deterministic per line and survive across sessions.
      // Clear any previous take now so a failed capture can never pass off
      // last session's audio as this one.
      try {
        final stale = File(path);
        if (stale.existsSync()) stale.deleteSync();
      } catch (_) {}
      _dlog.log(LogCategory.rehearsal, 'Capture: starting for ${line.id.substring(0, 8)}...');
      final ok = await _stt.startRecording(path);
      _dlog.log(LogCategory.rehearsal, 'Capture: startRecording returned $ok');
      if (ok) {
        _isCapturingAudio = true;
      } else {
        // Never silent: recording didn't start, so the actor isn't being
        // captured — surface it instead of carrying on as if we are.
        _dlog.logError(
            LogCategory.error, 'Capture: startRecording returned false');
        if (mounted) {
          ScaffoldMessenger.of(context).showAutoToast(
            const SnackBar(
              content: Text("Couldn't record your line — check microphone access."),
            ),
          );
        }
      }
    } catch (e) {
      _dlog.logError(LogCategory.error, 'Capture: start exception', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(content: Text('Recording error: $e')),
        );
      }
    }
  }

  Future<void> _stopCaptureForLine(ScriptLine line) async {
    if (!_isCapturingAudio) {
      _dlog.log(LogCategory.rehearsal, 'Capture: stop skipped (not capturing)');
      return;
    }
    _isCapturingAudio = false;

    // Android live matching: stop feeding the recognizer and flush the
    // utterance. Any final words it emits are dropped by the stale-line guard
    // in _handleRecognizedForLine once the state moves on — harmless.
    if (Platform.isAndroid) {
      SttChannel.instance.onPcm = null;
      LiveAsrService.instance.endUtterance();
    }

    try {
      _dlog.log(LogCategory.rehearsal, 'Capture: stopping...');
      final result = await _stt.stopRecording();
      if (result != null) {
        final path = result['path'] as String?;
        final durationMs = result['durationMs'] as int? ?? 0;
        final fileExists = path != null && File(path).existsSync();
        final fileSize = fileExists ? File(path).lengthSync() : 0;
        _dlog.log(LogCategory.rehearsal,
            'Capture: stopped — ${durationMs}ms, ${fileSize}B, exists=$fileExists');
        if (path != null && durationMs > 500 && fileExists && fileSize > 100) {
          _capturedAudio[line.id] = _CapturedLine(path: path, durationMs: durationMs);
          _dlog.log(LogCategory.rehearsal,
              'Capture: saved ${line.id.substring(0, 8)}... (${durationMs}ms, ${fileSize ~/ 1024}KB)');
        } else {
          _dlog.log(LogCategory.rehearsal,
              'Capture: DISCARDED (too short or empty)');
        }
      } else {
        _dlog.log(LogCategory.rehearsal, 'Capture: stopRecording returned null');
      }
    } catch (e) {
      _dlog.logError(LogCategory.error, 'Capture: stop exception', e);
    }
  }

  /// Show prompt to save captured rehearsal audio as recordings.
  void _offerToSaveRehearsalRecordings() {
    // Delay slightly — the last capture's async stopRecording may still
    // be in flight when scene-complete fires synchronously.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _showSaveRecordingsPrompt();
    });
  }

  void _showSaveRecordingsPrompt() {
    if (_capturedAudio.isEmpty) return;

    final character = ref.read(rehearsalCharacterProvider) ?? '';

    if (!_hasPromptedUpload) {
      _hasPromptedUpload = true;
      // First run: show dialog
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.mic, size: 40),
          title: const Text('Save Your Performance?'),
          content: const Text(
            'We captured your lines during rehearsal. '
            'Save them as your recorded lines so other cast members '
            'can hear your voice during their rehearsals?\n\n'
            'You can review and re-record individual lines later.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _purgeRehearsalCaptures();
              },
              child: const Text('Discard'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _saveRehearsalCaptures(character);
              },
              icon: const Icon(Icons.upload),
              label: const Text('Save Recordings'),
            ),
          ],
        ),
      );
    }
    // After first prompt, the button is shown in the completion UI
  }

  Future<void> _saveRehearsalCaptures(String character) async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    if (character.isEmpty) {
      // Without a character the cloud storage path would be malformed
      // ({prod}//{line}.m4a) and other devices couldn't resolve it.
      _dlog.log(LogCategory.rehearsal,
          'Save captures skipped: no rehearsal character set');
      return;
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory(p.join(docsDir.path, 'recordings'));
    if (!recordingsDir.existsSync()) {
      recordingsDir.createSync(recursive: true);
    }

    int saved = 0;
    for (final entry in _capturedAudio.entries) {
      final lineId = entry.key;
      final captured = entry.value;
      final tempFile = File(captured.path);
      if (!tempFile.existsSync()) continue;

      // Move from temp to permanent recordings directory
      final destPath = p.join(recordingsDir.path, '$lineId.m4a');
      try {
        await tempFile.copy(destPath);
        await tempFile.delete();

        final recording = Recording(
          id: const Uuid().v4(),
          scriptLineId: lineId,
          character: character,
          localPath: destPath,
          durationMs: captured.durationMs,
          recordedAt: DateTime.now(),
        );
        ref.read(recordingsProvider.notifier).add(recording);

        // Enqueue for cloud upload
        SyncQueue.instance.enqueue(
          productionId: production.id,
          characterName: character,
          lineId: lineId,
          localPath: destPath,
          durationMs: captured.durationMs,
          recordedAt: recording.recordedAt,
        );

        saved++;
      } catch (e) {
        _dlog.logError(LogCategory.error, 'Save capture failed for $lineId', e);
      }
    }

    _capturedAudio.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showAutoToast(
        SnackBar(
          content: Text('Saved $saved rehearsal recordings'),
          action: SnackBarAction(
            label: 'Review',
            onPressed: () => context.push('/recordings'),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    _dlog.log(LogCategory.rehearsal, 'Saved $saved rehearsal recordings');
  }

  void _purgeRehearsalCaptures() {
    for (final captured in _capturedAudio.values) {
      try { File(captured.path).deleteSync(); } catch (_) {}
    }
    _capturedAudio.clear();
  }

  /// Save the completed rehearsal session to history.
  void _saveSession(List<ScriptLine> dialogueLines) {
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final production = ref.read(currentProductionProvider);
    final mode = ref.read(rehearsalModeProvider);
    if (scene == null || myCharacter == null) return;

    final myLines = dialogueLines
        .where((l) => myCharacter != null && l.isForCharacter(myCharacter))
        .length;
    final completedLines = _lineAttempts.where((a) => !a.skipped).length;
    final avgScore = _lineAttempts.isEmpty
        ? 0.0
        : _lineAttempts.fold<double>(0, (s, a) => s + a.bestScore) /
            _lineAttempts.length;

    final session = RehearsalSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      productionId: production?.id ?? '',
      sceneId: scene.sceneName,
      sceneName: scene.displayLabel,
      character: myCharacter,
      startedAt: _sessionStartedAt,
      endedAt: DateTime.now(),
      totalLines: myLines,
      completedLines: completedLines,
      averageMatchScore: avgScore,
      lineAttempts: List.from(_lineAttempts),
      rehearsalMode: mode.name,
    );

    ref.read(rehearsalHistoryProvider.notifier).add(session);
  }

  void _scrollToCurrentLine() {
    // Wait for the current frame to complete layout so the widget tree
    // has been rebuilt with the new currentLineIndexProvider value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;

      // With cacheExtent: 10000 the target widget should be built.
      // Use ensureVisible on the GlobalKey for pixel-perfect scroll.
      final ctx = _currentLineKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.3, // position current line ~30% from top
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        // Fallback: estimate scroll position if widget not yet built
        final currentIdx = ref.read(currentLineIndexProvider);
        const estimatedItemHeight = 140.0;
        final targetOffset = currentIdx * estimatedItemHeight;
        final maxScroll = _scrollController.position.maxScrollExtent;
        _scrollController.animateTo(
          targetOffset.clamp(0.0, maxScroll),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }
}

class _CapturedLine {
  final String path;
  final int durationMs;
  const _CapturedLine({required this.path, required this.durationMs});
}
