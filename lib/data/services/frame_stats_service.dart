import 'package:flutter/scheduler.dart';

import 'debug_log_service.dart';

/// Aggregates Flutter [FrameTiming] and logs a summary line periodically —
/// HWUI's `dumpsys gfxinfo` cannot see Flutter's frames, so this is the only
/// way to measure UI jank in field logs (and A/B perf fixes across builds).
///
/// Logged as e.g.:
///   [MEM] frames: 412 in 30s, jank 6.3% (>16.7ms), build p90 3.2ms p99 11.0ms,
///   raster p90 5.1ms p99 18.7ms
class FrameStatsService {
  FrameStatsService._();
  static final instance = FrameStatsService._();

  static const _reportEvery = Duration(seconds: 30);

  final List<double> _buildMs = [];
  final List<double> _rasterMs = [];
  int _jank = 0;
  DateTime _windowStart = DateTime.now();
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    _windowStart = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds / 1000.0;
      final raster = t.rasterDuration.inMicroseconds / 1000.0;
      _buildMs.add(build);
      _rasterMs.add(raster);
      if (t.totalSpan.inMicroseconds > 16700) _jank++;
    }
    final now = DateTime.now();
    if (now.difference(_windowStart) >= _reportEvery && _buildMs.isNotEmpty) {
      _report(now);
    }
  }

  double _pct(List<double> sorted, double p) =>
      sorted[((sorted.length - 1) * p).round()];

  void _report(DateTime now) {
    final n = _buildMs.length;
    final secs = now.difference(_windowStart).inSeconds;
    final b = List<double>.of(_buildMs)..sort();
    final r = List<double>.of(_rasterMs)..sort();
    DebugLogService.instance.log(
      LogCategory.memory,
      'frames: $n in ${secs}s, jank ${(100 * _jank / n).toStringAsFixed(1)}% '
      '(>16.7ms), build p90 ${_pct(b, 0.9).toStringAsFixed(1)}ms '
      'p99 ${_pct(b, 0.99).toStringAsFixed(1)}ms, '
      'raster p90 ${_pct(r, 0.9).toStringAsFixed(1)}ms '
      'p99 ${_pct(r, 0.99).toStringAsFixed(1)}ms',
    );
    _buildMs.clear();
    _rasterMs.clear();
    _jank = 0;
    _windowStart = now;
  }
}
