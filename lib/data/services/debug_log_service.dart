import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Log entry categories.
enum LogCategory {
  memory('MEM', '🧠'),
  stt('STT', '🎤'),
  tts('TTS', '🔊'),
  rehearsal('REH', '🎭'),
  network('NET', '🌐'),
  firebase('FIR', '🔥'),
  general('GEN', '📋'),
  ai('AI', '✨'),
  error('ERR', '❌'),
  ;

  const LogCategory(this.tag, this.icon);
  final String tag;
  final String icon;
}

/// A single log entry.
class LogEntry {
  LogEntry({
    required this.timestamp,
    required this.category,
    required this.message,
    this.isError = false,
  });

  final DateTime timestamp;
  final LogCategory category;
  final String message;
  final bool isError;

  String get timeString => timestamp.toString().substring(11, 19);

  String toLine() =>
      '${timestamp.toIso8601String()} [${category.tag}] $message';

  static LogEntry? fromLine(String line) {
    try {
      final isoEnd = line.indexOf(' [');
      if (isoEnd < 0) return null;
      final timestamp = DateTime.parse(line.substring(0, isoEnd));
      final tagEnd = line.indexOf('] ', isoEnd);
      if (tagEnd < 0) return null;
      final tag = line.substring(isoEnd + 2, tagEnd);
      final message = line.substring(tagEnd + 2);
      final category = LogCategory.values.firstWhere(
        (c) => c.tag == tag,
        orElse: () => LogCategory.general,
      );
      return LogEntry(
        timestamp: timestamp,
        category: category,
        message: message,
        isError: category == LogCategory.error,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Centralized debug logging service with memory monitoring and disk persistence.
///
/// - Ring buffer of the last [maxEntries] log entries in memory
/// - Periodic disk flush (every 30s and on errors)
/// - Memory monitoring via native iOS plugin (every 10s during rehearsal)
/// - Survives crashes: disk file is append-only between flushes
class DebugLogService {
  DebugLogService._();
  static final instance = DebugLogService._();

  static const _channel = MethodChannel('com.lineguide/memory_monitor');
  static const int maxEntries = 500;
  static const _flushInterval = Duration(seconds: 30);
  static const _memoryInterval = Duration(seconds: 10);

  final List<LogEntry> _entries = [];
  final List<LogEntry> _pendingFlush = [];
  Timer? _flushTimer;
  Timer? _memoryTimer;
  bool _initialized = false;
  String? _logFilePath;

  // Latest memory stats
  int _lastPhysicalMB = 0;
  int _lastAvailableMB = 0;
  int get lastPhysicalMB => _lastPhysicalMB;
  int get lastAvailableMB => _lastAvailableMB;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Initialize the service. Call once at app startup.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Set up log file path
    final dir = await getApplicationDocumentsDirectory();
    _logFilePath = p.join(dir.path, 'debug_log.txt');

    // Load recent entries from disk
    await _loadFromDisk();

    // Drain any entries logged before the path was known.
    await _flushToDisk();

    // Periodic flush remains as a backstop for the rare pre-init queue; normal
    // logs now persist synchronously per entry (see [_appendSync]).
    _flushTimer = Timer.periodic(_flushInterval, (_) => _flushToDisk());

    log(LogCategory.general, 'Debug logging initialized');
    // Stamp the running build so every log file says which build produced it —
    // build number alone is ambiguous (a dev build and a TestFlight build can
    // share it), so we log the full version+build. Best-effort; never blocks.
    try {
      final info = await PackageInfo.fromPlatform();
      log(LogCategory.general,
          'app build: ${info.version}+${info.buildNumber} (${info.packageName})');
    } catch (e) {
      debugPrint('PackageInfo failed: $e');
    }
    await _logMemory();
  }

  /// Start periodic memory monitoring (call when entering rehearsal).
  void startMemoryMonitoring() {
    _memoryTimer?.cancel();
    _memoryTimer = Timer.periodic(_memoryInterval, (_) => _logMemory());
    log(LogCategory.memory, 'Memory monitoring started (${_memoryInterval.inSeconds}s interval)');
  }

  /// Stop periodic memory monitoring.
  void stopMemoryMonitoring() {
    _memoryTimer?.cancel();
    _memoryTimer = null;
  }

  /// Log a message.
  void log(LogCategory category, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      category: category,
      message: message,
      isError: category == LogCategory.error,
    );

    _entries.add(entry);

    // Trim ring buffer
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }

    // Also print to console in debug mode
    debugPrint('[${category.tag}] $message');

    // Persist this entry to disk synchronously, right now. A buffered/periodic
    // flush loses the last steps when the app is hard-killed (e.g. an OOM
    // jetsam SIGKILL during a big model load) — exactly when we most need to
    // know how far it got. The append is tiny; the synchronous cost is dwarfed
    // by whatever heavy work is being logged around.
    _appendSync(entry);
  }

  /// Append a single entry to the on-disk log immediately. Before [init] sets
  /// the path, entries queue in [_pendingFlush] and are drained on init.
  void _appendSync(LogEntry entry) {
    final path = _logFilePath;
    if (path == null) {
      _pendingFlush.add(entry);
      return;
    }
    try {
      File(path).writeAsStringSync('${entry.toLine()}\n',
          mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('Log append failed: $e');
    }
  }

  /// Log an error with optional stack trace.
  void logError(LogCategory category, String message, [Object? error, StackTrace? stack]) {
    final errorMsg = error != null ? '$message: $error' : message;
    log(LogCategory.error, '[${category.tag}] $errorMsg');
    if (stack != null) {
      log(LogCategory.error, stack.toString().split('\n').take(5).join('\n'));
    }
  }

  /// Get current memory usage from native.
  Future<Map<String, int>> getMemoryUsage() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getMemoryUsage');
      if (result != null) {
        _lastPhysicalMB = result['physicalFootprintMB'] as int? ?? 0;
        _lastAvailableMB = result['availableMemoryMB'] as int? ?? 0;
        return {
          'physicalFootprintMB': _lastPhysicalMB,
          'availableMemoryMB': _lastAvailableMB,
          'totalPhysicalMemoryMB': result['totalPhysicalMemoryMB'] as int? ?? 0,
        };
      }
    } on MissingPluginException {
      // Not on iOS or plugin not registered
    } catch (e) {
      debugPrint('Memory monitor error: $e');
    }
    return {};
  }

  /// Total entry count — cheap dirty-check for UI refresh timers.
  int get entryCount => _entries.length;

  /// Get entries filtered by category.
  List<LogEntry> entriesForCategory(LogCategory? category) {
    if (category == null) return List.unmodifiable(_entries);
    return _entries.where((e) => e.category == category).toList();
  }

  /// Clear all in-memory entries and the disk log.
  Future<void> clear() async {
    _entries.clear();
    _pendingFlush.clear();
    if (_logFilePath != null) {
      final file = File(_logFilePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  /// Export the full log as a string.
  String export() {
    return _entries.map((e) => e.toLine()).join('\n');
  }

  // ── Internal ──────────────────────────────────────────

  Future<void> _logMemory() async {
    final mem = await getMemoryUsage();
    if (mem.isNotEmpty) {
      final physical = mem['physicalFootprintMB'] ?? 0;
      final available = mem['availableMemoryMB'] ?? 0;
      log(LogCategory.memory, '${physical}MB used, ${available}MB available');
    }
  }

  Future<void> _flushToDisk() async {
    if (_logFilePath == null || _pendingFlush.isEmpty) return;
    try {
      final file = File(_logFilePath!);
      final lines = _pendingFlush.map((e) => e.toLine()).join('\n');
      await file.writeAsString('$lines\n', mode: FileMode.append);
      _pendingFlush.clear();
    } catch (e) {
      debugPrint('Log flush failed: $e');
    }
  }

  Future<void> _loadFromDisk() async {
    if (_logFilePath == null) return;
    try {
      final file = File(_logFilePath!);
      if (!await file.exists()) return;

      final content = await file.readAsString();
      final lines = content.split('\n').where((l) => l.isNotEmpty);

      // Only load last maxEntries lines
      final recentLines = lines.toList();
      final start = recentLines.length > maxEntries
          ? recentLines.length - maxEntries
          : 0;

      for (var i = start; i < recentLines.length; i++) {
        final entry = LogEntry.fromLine(recentLines[i]);
        if (entry != null) {
          _entries.add(entry);
        }
      }

      // Truncate file if it's gotten too large (> 200KB)
      final stat = await file.stat();
      if (stat.size > 200 * 1024) {
        final keepLines = _entries.map((e) => e.toLine()).join('\n');
        await file.writeAsString('$keepLines\n');
      }
    } catch (e) {
      debugPrint('Log load failed: $e');
    }
  }

  void dispose() {
    _flushToDisk();
    _flushTimer?.cancel();
    _memoryTimer?.cancel();
  }
}
