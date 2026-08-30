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
  error('ERR', '❌');

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
      final message = DebugLogService.redactForSupportLog(
        line.substring(tagEnd + 2),
      );
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
  static final _sensitiveKeyValue = RegExp(
    r'''(?:"?)\b(join[_ -]?code|code|actor(?:[_ -]?name)?|contact(?:[_ -]?(?:info|name))?|char(?:acter)?(?:[_ -]?name)?|display[_ -]?name|name|production[_ -]?(?:title|name)|title|dialogue|heard|script(?:[_ -]?(?:text|content))?|(?:local[_ -]?|storage[_ -]?|object[_ -]?)?path|raw[_ -]?(?:uri|url)|uri)(?:"?)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^,\s}\])]+)''',
    caseSensitive: false,
  );
  static final _sensitiveDatabaseTuple = RegExp(
    r'\b(join[_ -]?code|code|actor[_ -]?name|contact[_ -]?info|character[_ -]?name|display[_ -]?name|production[_ -]?title)\b\)?\s*=\s*\([^)]*\)',
    caseSensitive: false,
  );
  static final _uriWithQuery = RegExp(
    r'\b([a-z][a-z0-9+.-]*://[^\s?#]+)\?[^\s#]*(?:#[^\s]*)?',
    caseSensitive: false,
  );
  static final _email = RegExp(
    r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
    caseSensitive: false,
  );
  static final _localPath = RegExp(
    r'''(?:file://)?(?:/Users/|/private/var/|/var/mobile/|/data/user/)[^\n"',;)\]}]+''',
    caseSensitive: false,
  );
  static final _contentBearingMessage = RegExp(
    r'\b(?:MY LINE|Playing|System TTS)\s*:[^\n]*',
    caseSensitive: false,
  );
  static final _joinLookupSuccess = RegExp(
    r'\bJoin lookup succeeded[^\n]*',
    caseSensitive: false,
  );
  static final _storageObjectMessage = RegExp(
    r'\bStorage (?:upload(?: FAILED)?\s*(?:→|->)|download\s*(?:←|<-))\s*[^\n]*',
    caseSensitive: false,
  );
  static final _castIdentityError = RegExp(
    r'\b(?:Cloud cast invitation failed for|Unassign failed for)\b[^\n]*',
    caseSensitive: false,
  );
  static final _productionIdentityMessage = RegExp(
    r'\b(?:ProductionsNotifier\.add:\s*"|_submitProduction:\s*(?:starting for\b|background cloud create failed\b))[^\n]*',
    caseSensitive: false,
  );
  static final _freeFormProductionIdentity = RegExp(
    r'\b(?:Join: success — opening production|Delete refused for|Cloud delete failed for|Leave failed for)\b[^\n]*',
    caseSensitive: false,
  );
  static final _characterRenameIdentity = RegExp(
    r'\b(?:Voice config rename|Cloud cast rename|Cast rename)\b[^\n]*',
    caseSensitive: false,
  );
  static final _quotedJoinCharacter = RegExp(
    r'\bas\s+"[^"]*"',
    caseSensitive: false,
  );
  static final _recordingCharacterIdentity = RegExp(
    r'\bRecordingSync:\s*(?:(?:uploaded|downloaded)\s+\S+|realtime\s+—\s+new recording for\s+\S+)\s+\([^)]*\)',
    caseSensitive: false,
  );
  static final _restoredProductionTitles = RegExp(
    r'\bRestored \d+ production\(s\) from the cloud\s+\([^\n]*\)',
    caseSensitive: false,
  );
  static final _pdfHighlightTarget = RegExp(
    r'\bHighlight p\d+:[^\n]*',
    caseSensitive: false,
  );
  static final _legacyCloudIdentityMessage = RegExp(
    r'\b(?:RPC success:|RPC cast success:|Renamed cast member|Join: self-joined)[^\n]*',
    caseSensitive: false,
  );
  static void _debugInternalFailure(String operation, Object error) {
    if (!kDebugMode) return;
    debugPrint('$operation failed: ${redactForSupportLog(error.toString())}');
  }

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
      log(
        LogCategory.general,
        'app build: ${info.version}+${info.buildNumber} (${info.packageName})',
      );
    } catch (e) {
      _debugInternalFailure('PackageInfo', e);
    }
    await _logMemory();
  }

  /// Start periodic memory monitoring (call when entering rehearsal).
  void startMemoryMonitoring() {
    _memoryTimer?.cancel();
    _memoryTimer = Timer.periodic(_memoryInterval, (_) => _logMemory());
    log(
      LogCategory.memory,
      'Memory monitoring started (${_memoryInterval.inSeconds}s interval)',
    );
  }

  /// Stop periodic memory monitoring.
  void stopMemoryMonitoring() {
    _memoryTimer?.cancel();
    _memoryTimer = null;
  }

  /// Log a message after applying the support-log privacy boundary.
  ///
  /// Call sites should still emit opaque IDs, counts, and status rather than
  /// private values. This final pass prevents credential-bearing structured
  /// fields, raw deep-link queries, contact email addresses, and local paths
  /// from reaching the persistent/exportable log when an SDK exception
  /// includes them unexpectedly.
  void log(LogCategory category, String message) {
    final safeMessage = redactForSupportLog(message);
    final entry = LogEntry(
      timestamp: DateTime.now(),
      category: category,
      message: safeMessage,
      isError: category == LogCategory.error,
    );

    _entries.add(entry);

    // Trim ring buffer
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }

    if (kDebugMode) {
      debugPrint('[${category.tag}] $safeMessage');
    }

    // Persist this entry to disk synchronously, right now. A buffered/periodic
    // flush loses the last steps when the app is hard-killed (e.g. an OOM
    // jetsam SIGKILL during a big model load) — exactly when we most need to
    // know how far it got. The append is tiny; the synchronous cost is dwarfed
    // by whatever heavy work is being logged around.
    _appendSync(entry);
  }

  @visibleForTesting
  static String redactForSupportLog(String message) {
    return message
        .replaceAll(_contentBearingMessage, '[CONTENT REDACTED]')
        .replaceAll(_joinLookupSuccess, 'Join lookup succeeded')
        .replaceAll(_storageObjectMessage, 'Storage object [PATH REDACTED]')
        .replaceAll(_castIdentityError, 'Cast operation failed')
        .replaceAll(
          _productionIdentityMessage,
          'Production operation [METADATA REDACTED]',
        )
        .replaceAll(
          _freeFormProductionIdentity,
          'Production operation [METADATA REDACTED]',
        )
        .replaceAll(
          _characterRenameIdentity,
          'Character rename failed [METADATA REDACTED]',
        )
        .replaceAll(_quotedJoinCharacter, 'as [CHARACTER REDACTED]')
        .replaceAll(
          _recordingCharacterIdentity,
          'RecordingSync: recording operation [METADATA REDACTED]',
        )
        .replaceAll(
          _restoredProductionTitles,
          'Restored productions from the cloud [METADATA REDACTED]',
        )
        .replaceAll(_pdfHighlightTarget, 'Highlight [METADATA REDACTED]')
        .replaceAll(
          _legacyCloudIdentityMessage,
          'Cloud operation [METADATA REDACTED]',
        )
        .replaceAllMapped(
          _uriWithQuery,
          (match) => '${match.group(1)}?[REDACTED]',
        )
        .replaceAllMapped(
          _sensitiveDatabaseTuple,
          (match) => '${match.group(1)}=[REDACTED]',
        )
        .replaceAllMapped(
          _sensitiveKeyValue,
          (match) => '${match.group(1)}=[REDACTED]',
        )
        .replaceAll(_email, '[EMAIL REDACTED]')
        .replaceAll(_localPath, '[PATH REDACTED]');
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
      // No flush: an fsync per entry on the CALLER'S thread (often the UI
      // isolate mid-rehearsal) costs milliseconds each. The OS buffers the
      // append; the periodic _flushTimer and crash reports cover durability.
      File(
        path,
      ).writeAsStringSync('${entry.toLine()}\n', mode: FileMode.append);
    } catch (e) {
      _debugInternalFailure('Log append', e);
    }
  }

  /// Log an error with optional stack trace.
  void logError(
    LogCategory category,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    final errorMsg = error != null ? '$message: $error' : message;
    log(LogCategory.error, '[${category.tag}] $errorMsg');
    if (stack != null) {
      log(LogCategory.error, stack.toString().split('\n').take(5).join('\n'));
    }
  }

  /// Get current memory usage from native.
  Future<Map<String, int>> getMemoryUsage() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getMemoryUsage',
      );
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
      _debugInternalFailure('Memory monitor', e);
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
      _debugInternalFailure('Log flush', e);
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

      final loadedEntries = <LogEntry>[];
      for (var i = start; i < recentLines.length; i++) {
        final entry = LogEntry.fromLine(recentLines[i]);
        if (entry != null) {
          _entries.add(entry);
          loadedEntries.add(entry);
        }
      }

      // Rewrite on every load so upgrades remove sensitive values written by
      // older app versions, not merely hide them from the in-memory export.
      final keepLines = loadedEntries.map((e) => e.toLine()).join('\n');
      await file.writeAsString(keepLines.isEmpty ? '' : '$keepLines\n');
    } catch (e) {
      _debugInternalFailure('Log load', e);
    }
  }

  void dispose() {
    _flushToDisk();
    _flushTimer?.cancel();
    _memoryTimer?.cancel();
  }
}
