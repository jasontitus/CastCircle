import 'dart:math' as math;

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
  AudioLevelService._();
  static final AudioLevelService instance = AudioLevelService._();

  static const MethodChannel _channel =
      MethodChannel('com.lineguide/audio_analysis');

  /// Target playback loudness (RMS dBFS). Recordings hotter than this are
  /// attenuated toward it. -18 dBFS is a comfortable speech reference.
  static const double _targetRmsDbfs = -18.0;

  /// Floor on attenuation so a single very-hot clip never goes near-silent.
  static const double _minVolume = 0.3;

  /// path → just_audio volume multiplier in [_minVolume, 1.0].
  final Map<String, double> _gainCache = {};

  /// Returns a volume multiplier that brings [path] toward the target loudness.
  /// Returns 1.0 (unchanged playback) whenever analysis is unavailable — the
  /// channel is missing (e.g. Android, where it's not yet implemented), the
  /// file can't be decoded, or anything throws.
  Future<double> volumeFor(String path) async {
    final cached = _gainCache[path];
    if (cached != null) return cached;

    var volume = 1.0;
    try {
      final res =
          await _channel.invokeMethod<dynamic>('loudness', {'path': path});
      if (res is Map) {
        final rms = (res['rmsDbfs'] as num?)?.toDouble();
        if (rms != null && rms.isFinite && rms < 0) {
          final deltaDb = _targetRmsDbfs - rms; // < 0 when louder than target
          if (deltaDb < 0) {
            volume = _dbToGain(deltaDb).clamp(_minVolume, 1.0);
          }
        }
      }
    } catch (_) {
      volume = 1.0; // analysis unavailable — leave playback untouched
    }

    // Cheap LRU cap: the cache is keyed by file path and previously grew
    // without bound across re-recordings and productions. 512 doubles is
    // tiny, but unbounded-forever is how slow leaks are born.
    if (_gainCache.length >= 512) {
      _gainCache.remove(_gainCache.keys.first);
    }
    _gainCache[path] = volume;
    return volume;
  }

  /// Warms the cache for [path] without blocking a caller (fire-and-forget).
  void prefetch(String path) {
    if (_gainCache.containsKey(path)) return;
    volumeFor(path);
  }

  /// Drop a cached gain — call after a file at [path] is re-recorded.
  void invalidate(String path) => _gainCache.remove(path);

  void clear() => _gainCache.clear();

  static double _dbToGain(double db) => math.pow(10, db / 20).toDouble();
}
