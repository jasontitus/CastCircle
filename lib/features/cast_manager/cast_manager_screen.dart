import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/stt_adaptation_service.dart';
import '../../data/services/voice_clone_service.dart';
import '../../providers/production_providers.dart';

/// Local cast assignment data — who plays which character.
class CastAssignment {
  final String characterName;
  final String? primaryName; // display name of primary actor
  final String? understudyName;
  final String? primaryUserId;
  final String? understudyUserId;

  const CastAssignment({
    required this.characterName,
    this.primaryName,
    this.understudyName,
    this.primaryUserId,
    this.understudyUserId,
  });

  CastAssignment copyWith({
    String? characterName,
    String? primaryName,
    String? understudyName,
    String? primaryUserId,
    String? understudyUserId,
  }) {
    return CastAssignment(
      characterName: characterName ?? this.characterName,
      primaryName: primaryName ?? this.primaryName,
      understudyName: understudyName ?? this.understudyName,
      primaryUserId: primaryUserId ?? this.primaryUserId,
      understudyUserId: understudyUserId ?? this.understudyUserId,
    );
  }

  bool get hasAssignment => primaryName != null || understudyName != null;
}

/// Provider for cast assignments, keyed by character name.
final castAssignmentsProvider =
    StateNotifierProvider<CastAssignmentsNotifier, Map<String, CastAssignment>>(
        (ref) {
  return CastAssignmentsNotifier();
});

class CastAssignmentsNotifier
    extends StateNotifier<Map<String, CastAssignment>> {
  CastAssignmentsNotifier() : super({});

  void assign(CastAssignment assignment) {
    state = {...state, assignment.characterName: assignment};
  }

  void remove(String characterName) {
    state = Map.from(state)..remove(characterName);
  }

  void initFromScript(ParsedScript script) {
    final map = <String, CastAssignment>{};
    for (final char in script.characters) {
      map[char.name] =
          state[char.name] ?? CastAssignment(characterName: char.name);
    }
    state = map;
  }
}

class CastManagerScreen extends ConsumerStatefulWidget {
  const CastManagerScreen({super.key});

  @override
  ConsumerState<CastManagerScreen> createState() => _CastManagerScreenState();
}

class _CastManagerScreenState extends ConsumerState<CastManagerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final script = ref.read(currentScriptProvider);
      if (script != null) {
        ref.read(castAssignmentsProvider.notifier).initFromScript(script);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final assignments = ref.watch(castAssignmentsProvider);
    final recordings = ref.watch(recordingsProvider);

    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cast Manager')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    final assignedCount =
        assignments.values.where((a) => a.hasAssignment).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cast & Roles'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.model_training),
            tooltip: 'Train AI models',
            onPressed: () => _showTrainingDialog(context, script),
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share cast list',
            onPressed: () => _shareCastList(script, assignments),
          ),
        ],
      ),
      body: Column(
        children: [
          // Summary bar
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(Icons.people, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${script.characters.length} characters',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '$assignedCount assigned',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (assignedCount == script.characters.length)
                  Chip(
                    label: const Text('Cast Complete'),
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    avatar: const Icon(Icons.check, size: 16),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Character list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: script.characters.length,
              itemBuilder: (context, index) {
                final char = script.characters[index];
                final assignment = assignments[char.name] ??
                    CastAssignment(characterName: char.name);
                final color = AppTheme.colorForCharacter(char.colorIndex);

                // Recording progress for this character
                final charLines = script.linesForCharacter(char.name);
                final recordedCount = charLines
                    .where((l) => recordings.containsKey(l.id))
                    .length;
                final recordProgress = charLines.isEmpty
                    ? 0.0
                    : recordedCount / charLines.length;

                return _buildCharacterCard(
                  context, char, assignment, color, recordProgress,
                  recordedCount, charLines.length,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCharacterCard(
    BuildContext context,
    ScriptCharacter char,
    CastAssignment assignment,
    Color color,
    double recordProgress,
    int recordedCount,
    int totalLines,
  ) {
    final production = ref.read(currentProductionProvider);
    final voiceClone = VoiceCloneService.instance;
    final sttAdapt = SttAdaptationService.instance;
    final canClone = voiceClone.canClone(char.name);
    final voiceProfile = voiceClone.getProfile(char.name);
    final sttProfile = production != null
        ? sttAdapt.getActorProfile(production.id, char.name)
        : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Character header
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color,
                  radius: 20,
                  child: Text(
                    char.name[0],
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        char.name,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      Text(
                        '${char.lineCount} lines',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                // Invite button
                IconButton(
                  icon: const Icon(Icons.person_add_outlined),
                  tooltip: 'Invite actor',
                  onPressed: () => _inviteActor(char.name),
                ),
              ],
            ),
            // AI readiness badges
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _aiBadge(
                  icon: Icons.record_voice_over,
                  label: 'Voice Clone',
                  ready: canClone,
                  detail: voiceProfile != null
                      ? '${(voiceProfile.quality * 100).toInt()}%'
                      : null,
                ),
                _aiBadge(
                  icon: Icons.hearing,
                  label: 'STT Adapt',
                  ready: sttProfile?.hasEnoughData ?? false,
                  detail: sttProfile != null
                      ? '${sttProfile.totalAudioSeconds.toStringAsFixed(0)}s'
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Primary assignment
            _buildRoleRow(
              context,
              label: 'Primary',
              assignedName: assignment.primaryName,
              color: color,
              onAssign: () => _assignRole(char.name, 'primary'),
            ),
            const SizedBox(height: 8),
            // Understudy assignment
            _buildRoleRow(
              context,
              label: 'Understudy',
              assignedName: assignment.understudyName,
              color: color.withValues(alpha: 0.6),
              onAssign: () => _assignRole(char.name, 'understudy'),
            ),
            // Recording progress
            if (totalLines > 0) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: recordProgress,
                      backgroundColor: color.withValues(alpha: 0.1),
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$recordedCount/$totalLines',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.mic, size: 14, color: Colors.grey[600]),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRoleRow(
    BuildContext context, {
    required String label,
    required String? assignedName,
    required Color color,
    required VoidCallback onAssign,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
        ),
        if (assignedName != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Text(
              assignedName,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: Colors.grey[600]),
            onPressed: () => _unassignRole(
                assignedName, label == 'Primary' ? 'primary' : 'understudy'),
            visualDensity: VisualDensity.compact,
          ),
        ] else ...[
          OutlinedButton.icon(
            onPressed: onAssign,
            icon: const Icon(Icons.add, size: 16),
            label: Text('Assign $label'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  void _showTrainingDialog(BuildContext context, ParsedScript script) {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;

    final sttAdapt = SttAdaptationService.instance;
    final voiceClone = VoiceCloneService.instance;
    final strategy = sttAdapt.recommendStrategy(production.id);
    final actorProfiles = sttAdapt.getProductionActorProfiles(production.id);
    final prodProfile = sttAdapt.getProductionProfile(production.id);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.model_training),
            SizedBox(width: 8),
            Text('AI Training'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Strategy recommendation
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: strategy == TrainingStrategy.notReady
                      ? Colors.orange.withValues(alpha: 0.1)
                      : Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      strategy == TrainingStrategy.notReady
                          ? Icons.hourglass_empty
                          : Icons.check_circle,
                      color: strategy == TrainingStrategy.notReady
                          ? Colors.orange
                          : Colors.green,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        switch (strategy) {
                          TrainingStrategy.perActor =>
                            'Ready for per-actor training! Each character has enough audio.',
                          TrainingStrategy.perProduction =>
                            'Ready for production-wide training. Pool all recordings together.',
                          TrainingStrategy.notReady =>
                            'Need more recordings. Keep recording to unlock AI features.',
                        },
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Per-actor status
              Text('Per-Actor Status',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              ...script.characters.map((char) {
                final ap = sttAdapt.getActorProfile(production.id, char.name);
                final vp = voiceClone.getProfile(char.name);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(char.name,
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis),
                      ),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: ap.readiness,
                          backgroundColor: Colors.grey[800],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${ap.totalAudioSeconds.toStringAsFixed(0)}s',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey[500])),
                    ],
                  ),
                );
              }),

              // Production totals
              const SizedBox(height: 12),
              Text(
                'Total: ${prodProfile.totalAudioSeconds.toStringAsFixed(0)}s audio, '
                '${prodProfile.samples.length} samples',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (strategy != TrainingStrategy.notReady)
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await _startTraining(production.id, strategy);
              },
              icon: const Icon(Icons.play_arrow),
              label: Text(strategy == TrainingStrategy.perActor
                  ? 'Train Per-Actor'
                  : 'Train Production'),
            ),
        ],
      ),
    );
  }

  Future<void> _startTraining(String productionId, TrainingStrategy strategy) async {
    final sttAdapt = SttAdaptationService.instance;

    try {
      if (strategy == TrainingStrategy.perActor) {
        final profiles = sttAdapt.getProductionActorProfiles(productionId);
        for (final profile in profiles) {
          if (profile.hasEnoughData) {
            await sttAdapt.requestActorTraining(
              productionId: productionId,
              actorId: profile.actorId,
            );
          }
        }
      } else {
        await sttAdapt.requestProductionTraining(productionId: productionId);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strategy == TrainingStrategy.perActor
              ? 'Per-actor training requested'
              : 'Production training requested'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Training failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _aiBadge({
    required IconData icon,
    required String label,
    required bool ready,
    String? detail,
  }) {
    final color = ready ? Colors.green : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            detail != null ? '$label ($detail)' : label,
            style: TextStyle(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }

  void _assignRole(String characterName, String role) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Assign $role for $characterName'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Actor name',
            border: OutlineInputBorder(),
            hintText: 'Enter actor name',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;

              final current = ref.read(castAssignmentsProvider)[characterName] ??
                  CastAssignment(characterName: characterName);

              final updated = role == 'primary'
                  ? current.copyWith(primaryName: name)
                  : current.copyWith(understudyName: name);

              ref.read(castAssignmentsProvider.notifier).assign(updated);
              Navigator.pop(context);
            },
            child: const Text('Assign'),
          ),
        ],
      ),
    );
  }

  void _unassignRole(String actorName, String role) {
    // Find the assignment with this actor and clear it
    final assignments = ref.read(castAssignmentsProvider);
    for (final entry in assignments.entries) {
      final a = entry.value;
      if (role == 'primary' && a.primaryName == actorName) {
        ref.read(castAssignmentsProvider.notifier).assign(
              a.copyWith(primaryName: null),
            );
        break;
      }
      if (role == 'understudy' && a.understudyName == actorName) {
        ref.read(castAssignmentsProvider.notifier).assign(
              a.copyWith(understudyName: null),
            );
        break;
      }
    }
  }

  void _inviteActor(String characterName) {
    final production = ref.read(currentProductionProvider);
    final productionTitle = production?.title ?? 'a production';

    // Generate share text with deep link placeholder
    final shareText =
        'You\'ve been invited to join "$productionTitle" as $characterName '
        'on LineGuide! Download the app to get started.';

    Share.share(shareText, subject: 'LineGuide Invitation');
  }

  void _shareCastList(
      ParsedScript script, Map<String, CastAssignment> assignments) {
    final buffer = StringBuffer();
    buffer.writeln('Cast List: ${script.title}');
    buffer.writeln('=' * 30);
    buffer.writeln();

    for (final char in script.characters) {
      final a = assignments[char.name];
      buffer.writeln(char.name);
      if (a?.primaryName != null) {
        buffer.writeln('  Primary: ${a!.primaryName}');
      } else {
        buffer.writeln('  Primary: (unassigned)');
      }
      if (a?.understudyName != null) {
        buffer.writeln('  Understudy: ${a!.understudyName}');
      }
      buffer.writeln('  Lines: ${char.lineCount}');
      buffer.writeln();
    }

    Share.share(buffer.toString(), subject: 'Cast List');
  }
}
