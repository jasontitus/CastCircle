import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/rehearsal_models.dart';

/// Provider storing rehearsal session history.
final rehearsalHistoryProvider =
    StateNotifierProvider<RehearsalHistoryNotifier, List<RehearsalSession>>(
        (ref) {
  return RehearsalHistoryNotifier();
});

class RehearsalHistoryNotifier
    extends StateNotifier<List<RehearsalSession>> {
  RehearsalHistoryNotifier() : super([]);

  void add(RehearsalSession session) {
    state = [session, ...state]; // newest first
  }

  void clear() {
    state = [];
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
                  Text('No rehearsal sessions yet',
                      style: TextStyle(color: Colors.grey)),
                  SizedBox(height: 8),
                  Text('Complete a scene to see your stats here',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
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
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: sessions.length,
                    itemBuilder: (context, index) =>
                        _buildSessionCard(context, sessions[index]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSummary(
      BuildContext context, List<RehearsalSession> sessions) {
    final totalSessions = sessions.length;
    final totalTime = sessions.fold<Duration>(
        Duration.zero, (sum, s) => sum + s.duration);
    final avgScore = sessions.isEmpty
        ? 0.0
        : sessions.fold<double>(
                0.0, (sum, s) => sum + s.averageMatchScore) /
            sessions.length;

    // Unique scenes practiced
    final uniqueScenes =
        sessions.map((s) => s.sceneId).toSet().length;

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
              context, '${(avgScore * 100).toInt()}%', 'Avg Score'),
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
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
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
                if (session.cueToCueMode)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('Cue-to-Cue',
                        style: TextStyle(fontSize: 10, color: Colors.blue)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'as ${session.character}',
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
                // Score
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
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
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
              ...session.struggledLines.take(3).map((attempt) => Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 2),
                    child: Text(
                      '- ${attempt.lineText}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  )),
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
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.month}/${dt.day}';
  }
}
