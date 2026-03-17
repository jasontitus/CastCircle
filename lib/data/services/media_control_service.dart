import 'package:flutter/services.dart';

/// Service for handling AirPods / lock screen / Action Button media controls.
///
/// Maps remote commands to rehearsal actions:
///   - Previous track (double-tap left AirPod) → jump back
///   - Play/Pause (single tap AirPod)          → pause/resume
///   - Next track (double-tap right AirPod)    → skip forward
class MediaControlService {
  MediaControlService._();
  static final instance = MediaControlService._();

  static const _channel = MethodChannel('com.lineguide/media_controls');

  void Function()? onJumpBack;
  void Function()? onSkip;
  void Function()? onPlayPause;

  bool _active = false;

  /// Activate remote command handling. Call when rehearsal starts.
  Future<void> activate({
    void Function()? onJumpBack,
    void Function()? onSkip,
    void Function()? onPlayPause,
  }) async {
    this.onJumpBack = onJumpBack;
    this.onSkip = onSkip;
    this.onPlayPause = onPlayPause;

    _channel.setMethodCallHandler(_handleNativeCall);

    try {
      await _channel.invokeMethod('activate');
      _active = true;
    } on MissingPluginException {
      // Plugin not registered (e.g., on Android or simulator)
    }
  }

  /// Deactivate remote command handling. Call when rehearsal ends.
  Future<void> deactivate() async {
    onJumpBack = null;
    onSkip = null;
    onPlayPause = null;

    if (!_active) return;
    _active = false;

    try {
      await _channel.invokeMethod('deactivate');
    } on MissingPluginException {
      // Plugin not registered
    }
  }

  /// Update the Now Playing info shown on lock screen / AirPods.
  Future<void> updateNowPlaying({
    required String title,
    required String character,
  }) async {
    if (!_active) return;
    try {
      await _channel.invokeMethod('updateNowPlaying', {
        'title': title,
        'character': character,
      });
    } on MissingPluginException {
      // Plugin not registered
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onMediaCommand') {
      final command = call.arguments as String;
      switch (command) {
        case 'jumpBack':
        case 'playPause':
          // All physical button presses → jump back (primary rehearsal action)
          onJumpBack?.call();
        case 'skip':
          onSkip?.call();
      }
    }
  }
}
