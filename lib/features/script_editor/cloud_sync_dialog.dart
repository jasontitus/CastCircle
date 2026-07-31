import 'package:flutter/material.dart';

import '../../data/models/script_models.dart';

/// Describes the type of change between local and cloud script lines.
enum DiffType { added, removed, changed, unchanged }

class LineDiff {
  final DiffType type;
  final ScriptLine? local;
  final ScriptLine? cloud;

  const LineDiff({required this.type, this.local, this.cloud});
}

/// Compare local and cloud script lines to produce a diff summary.
///
/// Keyed by line id (stable across the cast since build 96) rather than
/// position: the old index-to-index comparison made a single inserted line
/// report every subsequent line as "changed", which both misled the user and
/// made the dialog O(all lines differ) on any insertion.
List<LineDiff> diffScriptLines(List<ScriptLine> local, List<ScriptLine> cloud) {
  final diffs = <LineDiff>[];
  final localById = {for (final l in local) l.id: l};
  final matchedLocalIds = <String>{};

  // Cloud order drives the display: matched lines compare content by id;
  // cloud lines with no local counterpart are additions.
  for (final cld in cloud) {
    final loc = localById[cld.id];
    if (loc == null) {
      diffs.add(LineDiff(type: DiffType.added, cloud: cld));
      continue;
    }
    matchedLocalIds.add(loc.id);
    final same = loc.character == cld.character &&
        loc.text == cld.text &&
        loc.lineType == cld.lineType &&
        loc.stageDirection == cld.stageDirection;
    diffs.add(LineDiff(
        type: same ? DiffType.unchanged : DiffType.changed,
        local: loc,
        cloud: cld));
  }

  // Local lines absent from the cloud version are removals.
  for (final loc in local) {
    if (!matchedLocalIds.contains(loc.id)) {
      diffs.add(LineDiff(type: DiffType.removed, local: loc));
    }
  }

  return diffs;
}

/// Shows a dialog comparing local vs cloud script and lets the user
/// accept or reject the cloud version.
///
/// Returns `true` if the user accepts the cloud version, `false` if rejected,
/// or `null` if dismissed.
Future<bool?> showCloudSyncDialog({
  required BuildContext context,
  required List<ScriptLine> localLines,
  required List<ScriptLine> cloudLines,
}) {
  final diffs = diffScriptLines(localLines, cloudLines);
  final added = diffs.where((d) => d.type == DiffType.added).length;
  final removed = diffs.where((d) => d.type == DiffType.removed).length;
  final changed = diffs.where((d) => d.type == DiffType.changed).length;
  final unchanged = diffs.where((d) => d.type == DiffType.unchanged).length;
  final changedDiffs =
      diffs.where((d) => d.type != DiffType.unchanged).toList();

  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.cloud_sync, size: 24),
          SizedBox(width: 8),
          Text('Cloud Script Updated'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Summary bar
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _statChip(context, '+$added', 'added',
                      Colors.green),
                  _statChip(context, '-$removed', 'removed',
                      Colors.red),
                  _statChip(context, '~$changed', 'changed',
                      Colors.orange),
                  _statChip(context, '$unchanged', 'same',
                      Colors.grey),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Changes from cloud:',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            // Diff list
            Expanded(
              child: changedDiffs.isEmpty
                  ? const Center(
                      child: Text('No changes detected',
                          style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.builder(
                      itemCount: changedDiffs.length,
                      itemBuilder: (context, index) {
                        final diff = changedDiffs[index];
                        return _buildDiffTile(context, diff);
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep Local'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.cloud_download, size: 18),
          label: const Text('Accept Cloud'),
        ),
      ],
    ),
  );
}

Widget _statChip(
    BuildContext context, String value, String label, Color color) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        value,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 16,
          color: color,
        ),
      ),
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
            ),
      ),
    ],
  );
}

Widget _buildDiffTile(BuildContext context, LineDiff diff) {
  final Color bgColor;
  final IconData icon;
  final String label;

  switch (diff.type) {
    case DiffType.added:
      bgColor = Colors.green.withValues(alpha: 0.1);
      icon = Icons.add_circle_outline;
      label = 'NEW';
    case DiffType.removed:
      bgColor = Colors.red.withValues(alpha: 0.1);
      icon = Icons.remove_circle_outline;
      label = 'DEL';
    case DiffType.changed:
      bgColor = Colors.orange.withValues(alpha: 0.1);
      icon = Icons.edit;
      label = 'MOD';
    case DiffType.unchanged:
      return const SizedBox.shrink();
  }

  final line = diff.cloud ?? diff.local!;
  final isDialogue =
      line.lineType == LineType.dialogue || line.lineType == LineType.song;

  return Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: bgColor == Colors.green.withValues(alpha: 0.1) ? Colors.green : bgColor == Colors.red.withValues(alpha: 0.1) ? Colors.red : Colors.orange),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            color: Colors.white.withValues(alpha: 0.1),
          ),
          child: Text(label,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isDialogue && line.character.isNotEmpty)
                Text(
                  line.character,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              Text(
                line.text,
                style: const TextStyle(fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              // Show what changed for modified lines
              if (diff.type == DiffType.changed && diff.local != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Was: ${diff.local!.character.isNotEmpty ? "${diff.local!.character}. " : ""}${diff.local!.text}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[500],
                    fontStyle: FontStyle.italic,
                    decoration: TextDecoration.lineThrough,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
