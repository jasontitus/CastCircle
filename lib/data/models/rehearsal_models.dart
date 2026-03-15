/// A completed rehearsal session for analytics tracking.
class RehearsalSession {
  final String id;
  final String productionId;
  final String sceneId;
  final String sceneName;
  final String character;
  final DateTime startedAt;
  final DateTime endedAt;
  final int totalLines;
  final int completedLines;
  final double averageMatchScore;
  final List<LineAttempt> lineAttempts;
  final String rehearsalMode; // 'sceneReadthrough' or 'cuePractice'

  const RehearsalSession({
    required this.id,
    required this.productionId,
    required this.sceneId,
    required this.sceneName,
    required this.character,
    required this.startedAt,
    required this.endedAt,
    required this.totalLines,
    required this.completedLines,
    required this.averageMatchScore,
    required this.lineAttempts,
    required this.rehearsalMode,
  });

  Duration get duration => endedAt.difference(startedAt);

  double get completionRate =>
      totalLines > 0 ? completedLines / totalLines : 0.0;

  /// Lines the actor struggled with (below threshold).
  List<LineAttempt> get struggledLines =>
      lineAttempts.where((a) => a.bestScore < 0.7).toList();
}

/// Record of an actor's attempt at a single line.
class LineAttempt {
  final String lineId;
  final String lineText;
  final int attemptCount; // how many tries before advancing
  final double bestScore; // best match score achieved
  final bool skipped; // manually advanced without matching

  const LineAttempt({
    required this.lineId,
    required this.lineText,
    required this.attemptCount,
    required this.bestScore,
    required this.skipped,
  });
}
