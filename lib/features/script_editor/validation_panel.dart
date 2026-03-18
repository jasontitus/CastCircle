import 'package:flutter/material.dart';

import '../../data/models/script_models.dart';

/// Validation check result.
class ValidationCheck {
  final String label;
  final bool passed;
  final String? detail;
  final IconData icon;
  final bool isWarning; // warning = amber, error = red

  const ValidationCheck({
    required this.label,
    required this.passed,
    this.detail,
    this.icon = Icons.check_circle,
    this.isWarning = false,
  });
}

/// Runs validation checks on a parsed script and returns results.
List<ValidationCheck> validateScript(ParsedScript script) {
  final checks = <ValidationCheck>[];

  // 1. Has characters
  final hasCharacters = script.characters.isNotEmpty;
  checks.add(ValidationCheck(
    label: 'Cast list detected',
    passed: hasCharacters,
    detail: hasCharacters
        ? '${script.characters.length} characters found'
        : 'No characters detected',
    icon: Icons.people,
  ));

  // 2. All dialogue lines attributed
  final unattributed = script.lines
      .where(
          (l) => l.lineType == LineType.dialogue && l.character.isEmpty)
      .length;
  checks.add(ValidationCheck(
    label: 'All lines attributed',
    passed: unattributed == 0,
    detail: unattributed == 0
        ? 'Every dialogue line has a character'
        : '$unattributed lines have no character',
    icon: Icons.assignment_ind,
  ));

  // 3. No single-line characters (likely OCR errors)
  final singleLine =
      script.characters.where((c) => c.lineCount == 1).toList();
  checks.add(ValidationCheck(
    label: 'No single-line characters',
    passed: singleLine.isEmpty,
    detail: singleLine.isEmpty
        ? 'All characters have 2+ lines'
        : '${singleLine.map((c) => c.name).join(", ")} have only 1 line',
    icon: Icons.warning_amber,
  ));

  // 4. Scenes detected
  final hasScenes = script.scenes.isNotEmpty;
  checks.add(ValidationCheck(
    label: 'Scenes detected',
    passed: hasScenes,
    detail: hasScenes
        ? '${script.scenes.length} scenes across ${script.acts.length} act(s)'
        : 'No scenes found — add them in Scene Editor',
    icon: Icons.auto_awesome_mosaic,
  ));

  // 5. Scenes have multiple characters
  final thinScenes =
      script.scenes.where((s) => s.characters.length < 2).toList();
  checks.add(ValidationCheck(
    label: 'Scenes have 2+ characters',
    passed: thinScenes.isEmpty,
    detail: thinScenes.isEmpty
        ? 'All scenes have multiple characters'
        : '${thinScenes.length} scene(s) have fewer than 2 characters',
    icon: Icons.group,
  ));

  // 6. Has dialogue (not all stage directions)
  final dialogueCount = script.lines
      .where((l) => l.lineType == LineType.dialogue)
      .length;
  final totalLines = script.lines.length;
  final dialogueRatio =
      totalLines > 0 ? dialogueCount / totalLines : 0.0;
  checks.add(ValidationCheck(
    label: 'Healthy dialogue ratio',
    passed: dialogueRatio > 0.5,
    detail:
        '$dialogueCount dialogue lines of $totalLines total (${(dialogueRatio * 100).toInt()}%)',
    icon: Icons.chat_bubble_outline,
  ));

  // 7. Act headers present
  final hasActs = script.acts.isNotEmpty;
  checks.add(ValidationCheck(
    label: 'Act structure detected',
    passed: hasActs,
    detail: hasActs
        ? 'Acts: ${script.acts.join(", ")}'
        : 'No act headers found',
    icon: Icons.format_list_numbered,
  ));

  // 8. OCR confidence — flag lines below 0.85 threshold
  final lowConfidenceLines = script.lines
      .where((l) => l.ocrConfidence != null && l.ocrConfidence! < 0.85)
      .length;
  final hasOcrData = script.lines.any((l) => l.ocrConfidence != null);
  if (hasOcrData) {
    checks.add(ValidationCheck(
      label: 'OCR quality',
      passed: lowConfidenceLines == 0,
      detail: lowConfidenceLines == 0
          ? 'All OCR lines have good confidence'
          : '$lowConfidenceLines line${lowConfidenceLines == 1 ? '' : 's'} may need review (low OCR confidence)',
      icon: Icons.document_scanner,
      isWarning: true,
    ));
  }

  return checks;
}

/// Shows the validation panel as a bottom sheet.
void showValidationPanel(BuildContext context, ParsedScript script) {
  final checks = validateScript(script);
  final passCount = checks.where((c) => c.passed).length;
  final allPassed = passCount == checks.length;

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.8,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  allPassed ? Icons.check_circle : Icons.info_outline,
                  color: allPassed ? Colors.green : Colors.orange,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        allPassed
                            ? 'Script looks good!'
                            : '$passCount / ${checks.length} checks passed',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        allPassed
                            ? 'Ready to assign cast and start recording'
                            : 'Review the issues below',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Check list
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: checks.length,
              itemBuilder: (context, index) {
                final check = checks[index];
                final failColor = check.isWarning
                    ? Colors.amber.shade700
                    : Colors.red;
                final failDetailColor = check.isWarning
                    ? Colors.amber.shade600
                    : Colors.red[300];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        check.passed
                            ? Icons.check_circle
                            : (check.isWarning
                                ? Icons.warning_amber_rounded
                                : Icons.cancel),
                        color: check.passed ? Colors.green : failColor,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              check.label,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (check.detail != null)
                              Text(
                                check.detail!,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: check.passed
                                          ? Colors.grey[600]
                                          : failDetailColor,
                                    ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
