import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Computes per-recording playback volume so cast recordings don't jump wildly
/// in loudness (a top competitor complaint). Loudness is measured from the
/// audio file itself via a native analyzer, so it works for recordings made on
/// this device *and* ones received from castmates over the cloud.
///
/// Limitation: just_audio on iOS can only **attenuate** (volume ≤ 1.0), so this
/// normalizes downward — recordings hotter than the target are pulled toward it;
/// recordings already quieter than the target play at full volume. That evens
/// out the jarring "this one BLASTS" case. (Lifting quiet recordings would need
/// native re-encoding with gain, a possible future pass.)
class AudioLevelService {
  AudioLevelService._({Future<dynamic> Function(String path)? analyze})
    : _analyze = analyze ?? _analyzeWithChannel;

  static final AudioLevelService instance = AudioLevelService._();

  @visibleForTesting
  factory AudioLevelService.forTesting(
    Future<dynamic> Function(String path) analyze,
  ) => AudioLevelService._(analyze: analyze);

  static const MethodChannel _channel = MethodChannel(
    'com.lineguide/audio_analysis',
  );
  final Future<dynamic> Function(String path) _analyze;

  /// Target playback loudness (RMS dBFS). Recordings hotter than this are
  /// attenuated toward it. -18 dBFS is a comfortable speech reference.
  static const double _targetRmsDbfs = -18.0;

  /// Floor on attenuation so a single very-hot clip never goes near-silent.
  static const double _minVolume = 0.3;

  /// Access-ordered path → just_audio volume multiplier.
  final LinkedHashMap<String, double> _gainCache = LinkedHashMap();
  final Map<String, Future<double>> _inFlight = {};
  final Map<String, int> _versions = {};

  /// Returns a volume multiplier that brings [path] toward the target loudness.
  /// Returns 1.0 (unchanged playback) whenever analysis is unavailable — the
  /// channel is missing (e.g. Android, where it's not yet implemented), the
  /// file can't be decoded, or anything throws.
  Future<double> volumeFor(String path) {
    final cached = _gainCache.remove(path);
    if (cached != null) {
      _gainCache[path] = cached;
      return Future.value(cached);
    }

    final existing = _inFlight[path];
    if (existing != null) return existing;

    final version = _versions.putIfAbsent(path, () => 0);
    final analysis = _measure(path, version);
    _inFlight[path] = analysis;
    return analysis.whenComplete(() {
      if (identical(_inFlight[path], analysis)) {
        _inFlight.remove(path);
      }
      if (!_inFlight.containsKey(path) && !_gainCache.containsKey(path)) {
        _versions.remove(path);
      }
    });
  }

  Future<double> _measure(String path, int version) async {
    try {
      final res = await _analyze(path);
      if (res is! Map) return 1.0;

      final rms = (res['rmsDbfs'] as num?)?.toDouble();
      if (rms == null || !rms.isFinite || rms > 0) return 1.0;

      final deltaDb = _targetRmsDbfs - rms;
      final volume = deltaDb < 0
          ? _dbToGain(deltaDb).clamp(_minVolume, 1.0)
          : 1.0;
      if ((_versions[path] ?? 0) == version) {
        if (_gainCache.length >= 512) {
          final evicted = _gainCache.keys.first;
          _gainCache.remove(evicted);
          _versions.remove(evicted);
        }
        _gainCache[path] = volume;
      }
      return volume;
    } catch (_) {
      // Analysis is an optional playback enhancement. Return unity for this
      // attempt, but do not cache it: transient channel/decoder failures retry.
      return 1.0;
    }
  }

  static Future<dynamic> _analyzeWithChannel(String path) =>
      _channel.invokeMethod<dynamic>('loudness', {'path': path});

  /// Warms the cache for [path] without blocking a caller.
  void prefetch(String path) {
    if (_gainCache.containsKey(path) || _inFlight.containsKey(path)) return;
    unawaited(volumeFor(path));
  }

  /// Drop a cached or in-flight gain after the file at [path] is replaced.
  void invalidate(String path) {
    _gainCache.remove(path);
    _inFlight.remove(path);
    _versions[path] = (_versions[path] ?? 0) + 1;
  }

  void clear() {
    _gainCache.clear();
    final activePaths = _inFlight.keys.toSet();
    _inFlight.clear();
    _versions.removeWhere((path, _) => !activePaths.contains(path));
    for (final path in activePaths) {
      _versions[path] = (_versions[path] ?? 0) + 1;
    }
  }

  static double _dbToGain(double db) => math.pow(10, db / 20).toDouble();
}
