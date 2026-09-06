import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/responsive.dart';
import '../../data/models/rehearsal_models.dart';
import '../../data/services/debug_log_service.dart';
import '../../providers/production_providers.dart';

/// User-scoped, locally persisted rehearsal session history.
final rehearsalHistoryProvider =
    StateNotifierProvider<RehearsalHistoryNotifier, List<RehearsalSession>>((
      ref,
    ) {
      final accountNamespace = ref.watch(activeAccountNamespaceProvider);
      return RehearsalHistoryNotifier(
        storageKey: 'rehearsal_history:$accountNamespace',
      );
    });

class RehearsalHistoryNotifier extends StateNotifier<List<RehearsalSession>> {
  RehearsalHistoryNotifier({required this.storageKey}) : super([]) {
    unawaited(_load());
  }

  final String storageKey;
  static const _maxSessions = 100;
  Future<void> _writes = Future.value();
  bool _disposed = false;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    final raw = prefs.getString(storageKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final persisted = decoded
          .map(
            (item) => _sessionFromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
      final currentIds = state.map((session) => session.id).toSet();
      state = [
        ...state,
        ...persisted.where((session) => !currentIds.contains(session.id)),
      ].take(_maxSessions).toList();
      if (currentIds.isNotEmpty) _persist();
    } catch (_) {
      // Ignore malformed legacy data; the next successful write replaces it.
    }
  }

  void add(RehearsalSession session) {
    state = [
      session,
      ...state.where((existing) => existing.id != session.id),
    ].take(_maxSessions).toList();
    _persist();
  }

  void clear() {
    state = [];
    _persist();
  }

  void _persist() {
    final snapshot = jsonEncode(state.map(_sessionToJson).toList());
    _writes = _writes
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          final saved = await prefs.setString(storageKey, snapshot);
          if (!saved) {
            throw StateError('SharedPreferences rejected $storageKey');
          }
        })
        .catchError((Object error, StackTrace stack) {
          DebugLogService.instance.logError(
            LogCategory.rehearsal,
            'Could not persist rehearsal history',
            error,
            stack,
          );
          // Handling the error keeps the queue usable for the next write.
        });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static Map<String, dynamic> _sessionToJson(RehearsalSession session) => {
    'id': session.id,
    'productionId': session.productionId,
    'sceneId': session.sceneId,
    'sceneName': session.sceneName,
    'character': session.character,
    'startedAt': session.startedAt.toIso8601String(),
    'endedAt': session.endedAt.toIso8601String(),
    'totalLines': session.totalLines,
    'completedLines': session.completedLines,
    'averageMatchScore': session.averageMatchScore,
    'rehearsalMode': session.rehearsalMode,
    'lineAttempts': session.lineAttempts
        .map(
          (attempt) => {
            'lineId': attempt.lineId,
            'lineText': attempt.lineText,
            'attemptCount': attempt.attemptCount,
            'bestScore': attempt.bestScore,
            'skipped': attempt.skipped,
          },
        )
        .toList(),
  };

  static RehearsalSession _sessionFromJson(Map<String, dynamic> json) {
    final attempts = (json['lineAttempts'] as List<dynamic>? ?? const []).map((
      item,
    ) {
      final attempt = Map<String, dynamic>.from(item as Map);
      return LineAttempt(
        lineId: attempt['lineId'] as String,
        lineText: attempt['lineText'] as String,
        attemptCount: attempt['attemptCount'] as int,
        bestScore: (attempt['bestScore'] as num).toDouble(),
        skipped: attempt['skipped'] as bool,
      );
    }).toList();
    return RehearsalSession(
      id: json['id'] as String,
      productionId: json['productionId'] as String,
      sceneId: json['sceneId'] as String,
      sceneName: json['sceneName'] as String,
      character: json['character'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      totalLines: json['totalLines'] as int,
      completedLines: json['completedLines'] as int,
      averageMatchScore: (json['averageMatchScore'] as num).toDouble(),
      lineAttempts: attempts,
      rehearsalMode: json['rehearsalMode'] as String,
    );
  }
}

class RehearsalHistoryScreen extends ConsumerWidget {
  const RehearsalHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(rehearsalHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rehearsal History'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: sessions.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No rehearsal sessions yet',
                    style: TextStyle(color: Colors.grey),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Complete a scene to see your stats here',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // Summary stats
                _buildSummary(context, sessions),
                const Divider(height: 1),
                // Session list
                Expanded(
                  child: ContentConstraint(
                    maxWidth: 720,
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: sessions.length,
                      itemBuilder: (context, index) =>
                          _buildSessionCard(context, sessions[index]),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSummary(BuildContext context, List<RehearsalSession> sessions) {
    final totalSessions = sessions.length;
    final totalTime = sessions.fold<Duration>(
      Duration.zero,
      (sum, s) => sum + s.duration,
    );
    final scoredSessions = sessions
        .where((session) => session.lineAttempts.isNotEmpty)
        .toList();
    final avgScore = scoredSessions.isEmpty
        ? null
        : scoredSessions.fold<double>(
                0.0,
                (sum, session) => sum + session.averageMatchScore,
              ) /
              scoredSessions.length;

    // Unique scenes practiced
    final uniqueScenes = sessions.map((s) => s.sceneId).toSet().length;

    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statColumn(context, '$totalSessions', 'Sessions'),
          _statColumn(context, _formatDuration(totalTime), 'Total Time'),
          _statColumn(context, '$uniqueScenes', 'Scenes'),
          _statColumn(
            context,
            avgScore == null ? '—' : '${(avgScore * 100).toInt()}%',
            'Avg Score',
          ),
        ],
      ),
    );
  }

  Widget _statColumn(BuildContext context, String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildSessionCard(BuildContext context, RehearsalSession session) {
    final scoreColor = session.averageMatchScore >= 0.8
        ? Colors.green
        : session.averageMatchScore >= 0.6
        ? Colors.orange
        : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    session.sceneName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: session.rehearsalMode == 'cuePractice'
                        ? Colors.blue.withValues(alpha: 0.1)
                        : Colors.teal.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    session.rehearsalMode == 'cuePractice'
                        ? 'Cue Practice'
                        : 'Readthrough',
                    style: TextStyle(
                      fontSize: 10,
                      color: session.rehearsalMode == 'cuePractice'
                          ? Colors.blue
                          : Colors.teal,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              session.rehearsalMode == 'readthrough'
                  ? 'Full cast'
                  : 'as ${session.character}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                // Completion
                _miniStat(
                  Icons.check_circle_outline,
                  '${session.completedLines}/${session.totalLines}',
                  Colors.grey,
                ),
                const SizedBox(width: 16),
                if (session.lineAttempts.isNotEmpty)
                  _miniStat(
                    Icons.star_outline,
                    '${(session.averageMatchScore * 100).toInt()}%',
                    scoreColor,
                  ),
                const SizedBox(width: 16),
                // Duration
                _miniStat(
                  Icons.timer_outlined,
                  _formatDuration(session.duration),
                  Colors.grey,
                ),
                const Spacer(),
                // Date
                Text(
                  _formatDate(session.startedAt),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                ),
              ],
            ),
            // Struggled lines
            if (session.struggledLines.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Needs practice:',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.orange,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              ...session.struggledLines
                  .take(3)
                  .map(
                    (attempt) => Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 2),
                      child: Text(
                        '- ${attempt.lineText}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _miniStat(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(local.year, local.month, local.day);
    final daysAgo = today.difference(date).inDays;
    if (daysAgo < 0) return '${local.month}/${local.day}';
    if (daysAgo == 0) return 'Today';
    if (daysAgo == 1) return 'Yesterday';
    if (daysAgo < 7) return '$daysAgo days ago';
    return '${local.month}/${local.day}';
  }
}
