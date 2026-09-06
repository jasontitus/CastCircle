import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'dart:io';

import '../../core/responsive.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/cast_member_model.dart';
import '../../data/models/script_models.dart';
import '../../data/models/voice_preset.dart';
import '../../data/services/contact_picker_service.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/deep_link_service.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';
import '../../core/toast.dart';

final _recordedCountsByCharacterProvider =
    Provider.autoDispose<Map<String, int>>((ref) {
      final script = ref.watch(currentScriptProvider);
      final recordings = ref.watch(recordingsProvider);
      if (script == null || recordings.isEmpty) return const {};

      final counts = <String, int>{};
      for (final line in script.lines) {
        if (line.lineType != LineType.dialogue ||
            !recordings.containsKey(line.id)) {
          continue;
        }
        if (line.character.isNotEmpty) {
          counts[line.character] = (counts[line.character] ?? 0) + 1;
        }
        for (final character in line.multiCharacters) {
          if (character != line.character) {
            counts[character] = (counts[character] ?? 0) + 1;
          }
        }
      }
      return counts;
    });

class CastManagerScreen extends ConsumerStatefulWidget {
  const CastManagerScreen({super.key});

  @override
  ConsumerState<CastManagerScreen> createState() => _CastManagerScreenState();
}

class _CastManagerScreenState extends ConsumerState<CastManagerScreen> {
  // assignVoicesFromScript memo: a full script walk + graph coloring whose
  // inputs change rarely, but cast changes still rebuild this screen.
  Map<String, String>? _assignmentCache;
  Object? _assignmentKey;

  // linesByChar depends only on the script, so cast-member updates should not
  // re-walk a multi-thousand-line script.
  Map<String, List<ScriptLine>>? _linesByCharCache;
  List<ScriptLine>? _linesByCharKey;

  Map<String, List<ScriptLine>> _memoLinesByChar(ParsedScript script) {
    if (_linesByCharCache != null && identical(_linesByCharKey, script.lines)) {
      return _linesByCharCache!;
    }
    // Mirrors isForCharacter: character match OR multiCharacters membership.
    final linesByChar = <String, List<ScriptLine>>{};
    for (final l in script.lines) {
      if (l.lineType != LineType.dialogue) continue;
      if (l.character.isNotEmpty) (linesByChar[l.character] ??= []).add(l);
      for (final c in l.multiCharacters) {
        if (c != l.character) (linesByChar[c] ??= []).add(l);
      }
    }
    _linesByCharKey = script.lines;
    return _linesByCharCache = linesByChar;
  }

  Map<String, String> _memoAssignment(ParsedScript script) {
    final key = Object.hash(
      identityHashCode(script),
      _currentPreset,
      _genderOverrides.toString(),
    );
    if (_assignmentCache != null && _assignmentKey == key) {
      return _assignmentCache!;
    }
    _assignmentKey = key;
    return _assignmentCache = VoiceConfigService.assignVoicesFromScript(
      lines: script.lines,
      characters: script.characters,
      femaleVoices: _currentPreset.femaleVoices,
      maleVoices: _currentPreset.maleVoices,
      genderOverrides: _genderOverrides,
    );
  }

  final _voiceConfig = VoiceConfigService.instance;
  VoicePreset _currentPreset = VoicePresets.modernAmerican;
  Map<String, CharacterVoiceConfig> _voiceOverrides = {};
  Map<String, CharacterGender> _genderOverrides = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final production = ref.read(currentProductionProvider);
      if (production != null) {
        await ref
            .read(castMembersProvider.notifier)
            .loadForProduction(production.id);
        if (!mounted) return;
        _loadVoiceConfig(production.id);
        _syncCastFromCloud(production.id);
      }
    });
  }

  /// Sync cast member statuses from Supabase so we see who has joined.
  Future<void> _syncCastFromCloud(String productionId) async {
    final supa = SupabaseService.instance;
    if (!supa.isSignedIn) return;
    final notifier = ref.read(castMembersProvider.notifier);

    try {
      final cloudMembers = await supa.fetchCastMembers(productionId);
      if (!mounted) return;
      final localById = {
        for (final member in ref.read(castMembersProvider)) member.id: member,
      };
      final upserts = <CastMemberModel>[];
      for (final cm in cloudMembers) {
        final member = CastMemberModel(
          id: cm['id'] as String,
          productionId: productionId,
          userId: cm['user_id'] as String?,
          characterName: cm['character_name'] as String? ?? '',
          displayName: cm['display_name'] as String? ?? '',
          contactInfo: cm['contact_info'] as String?,
          role: CastRole.fromString(cm['role'] as String? ?? 'actor'),
          invitedAt: cm['invited_at'] != null
              ? DateTime.tryParse(cm['invited_at'] as String)
              : null,
          joinedAt: cm['joined_at'] != null
              ? DateTime.tryParse(cm['joined_at'] as String)
              : null,
        );
        final local = localById[member.id];
        if (local == null || !_sameCastMember(local, member)) {
          upserts.add(member);
        }
      }
      if (upserts.isNotEmpty) {
        await notifier.applyChanges(upserts: upserts, deleteIds: const {});
      }
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Cast cloud sync failed',
        e,
      );
    }
  }

  static bool _sameCastMember(CastMemberModel local, CastMemberModel cloud) {
    return local.productionId == cloud.productionId &&
        local.userId == cloud.userId &&
        local.characterName == cloud.characterName &&
        local.displayName == cloud.displayName &&
        local.contactInfo == cloud.contactInfo &&
        local.role == cloud.role &&
        local.invitedAt == cloud.invitedAt &&
        local.joinedAt == cloud.joinedAt;
  }

  Future<void> _loadVoiceConfig(String productionId) async {
    final preset = await _voiceConfig.getPreset(productionId);
    final overrides = await _voiceConfig.getOverrides(productionId);
    // Saved gender toggles too — without them the voice shown here diverged
    // from the voice rehearsal actually plays (rehearsal passes them).
    final genders = await _voiceConfig.getGenders(productionId);
    if (mounted) {
      setState(() {
        _currentPreset = preset;
        _voiceOverrides = overrides;
        _genderOverrides = genders;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final production = ref.watch(currentProductionProvider);
    final castMembers = ref.watch(castMembersProvider);

    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cast Manager')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    final joinCode = production?.joinCode;
    final joinedCount = castMembers
        .where((m) => m.hasJoined && m.role != CastRole.organizer)
        .length;

    // Adjacency-aware voice assignment — memoized on its actual inputs
    // (script identity, preset, overrides), so cast updates cannot rerun the
    // full script walk and graph coloring. Gender overrides keep the voice
    // shown here aligned with rehearsal playback.
    final autoAssignment = _memoAssignment(script);
    final totalLines = script.lines
        .where((l) => l.lineType == LineType.dialogue)
        .length;

    // Per-build indexes: the card builder used to do a linear scan over
    // castMembers (primaryFor/understudyFor) and a full-script
    // linesForCharacter walk per card.
    final primaryByChar = <String, CastMemberModel>{};
    final understudyByChar = <String, CastMemberModel>{};
    for (final m in castMembers) {
      if (m.role == CastRole.primary) {
        primaryByChar.putIfAbsent(m.characterName, () => m);
      } else if (m.role == CastRole.understudy) {
        understudyByChar.putIfAbsent(m.characterName, () => m);
      }
    }
    final linesByChar = _memoLinesByChar(script);

    // Check if any characters still need actors assigned
    final unassignedCount = script.characters
        .where((char) => !primaryByChar.containsKey(char.name))
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cast & Roles'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            tooltip: 'Voice settings',
            onPressed: () => context.push('/voice-config'),
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share cast list',
            onPressed: () => _shareCastList(script, castMembers),
          ),
        ],
      ),
      body: Column(
        children: [
          // -- Join code banner --
          if (joinCode != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Join Code',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer
                                    .withValues(alpha: 0.7),
                              ),
                        ),
                        const SizedBox(height: 2),
                        SelectableText(
                          joinCode,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 4,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimaryContainer,
                              ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: 'Copy code',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: joinCode));
                      ScaffoldMessenger.of(context).showAutoToast(
                        const SnackBar(
                          content: Text('Join code copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.share),
                    tooltip: 'Share code',
                    onPressed: () => _shareJoinCode(joinCode),
                  ),
                ],
              ),
            ),
          // -- Bulk setup banner --
          if (unassignedCount > 0)
            InkWell(
              onTap: () => context.push('/cast-setup'),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: Row(
                  children: [
                    Icon(
                      Icons.group_add,
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '$unassignedCount characters need actors — Set up cast',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onTertiaryContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: Theme.of(
                        context,
                      ).colorScheme.onTertiaryContainer.withValues(alpha: 0.5),
                    ),
                  ],
                ),
              ),
            ),
          // -- Summary bar --
          Consumer(
            builder: (context, ref, _) {
              final totalRecordedLines = ref.watch(
                recordingsProvider.select((recordings) => recordings.length),
              );
              final progressPct = totalLines > 0
                  ? (totalRecordedLines / totalLines * 100).round()
                  : 0;
              return Container(
                padding: const EdgeInsets.all(16),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.people,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '$joinedCount of ${script.characters.length} '
                            'actors joined · $totalRecordedLines/$totalLines '
                            'lines recorded ($progressPct%)',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (totalLines > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: totalRecordedLines / totalLines,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.1),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
          const Divider(height: 1),
          // -- Character list --
          Expanded(
            child: ContentConstraint(
              maxWidth: 720,
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: script.characters.length,
                itemBuilder: (context, index) {
                  final char = script.characters[index];
                  final color = AppTheme.colorForCharacter(char.colorIndex);
                  final primary = primaryByChar[char.name];
                  final understudy = understudyByChar[char.name];

                  final charLines = linesByChar[char.name] ?? const [];
                  final lineCount = charLines.length;

                  return Consumer(
                    builder: (context, ref, _) {
                      final recordedCount = ref.watch(
                        _recordedCountsByCharacterProvider.select(
                          (counts) => counts[char.name] ?? 0,
                        ),
                      );
                      final recordProgress = lineCount == 0
                          ? 0.0
                          : recordedCount / lineCount;
                      return _buildCharacterCard(
                        context,
                        char,
                        primary,
                        understudy,
                        color,
                        recordProgress,
                        recordedCount,
                        lineCount,
                        autoAssignment,
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCharacterCard(
    BuildContext context,
    ScriptCharacter char,
    CastMemberModel? primary,
    CastMemberModel? understudy,
    Color color,
    double recordProgress,
    int recordedCount,
    int totalLines,
    Map<String, String> autoAssignment,
  ) {
    final override = _voiceOverrides[char.name];
    final presetVoice = autoAssignment[char.name] ?? 'af_heart';
    final activeVoice = override?.voiceId ?? presetVoice;
    final activeSpeed = override?.speed ?? _currentPreset.defaultSpeed;
    final voiceLabel = VoicePresets.voiceLabels[activeVoice] ?? activeVoice;
    final effectiveGender = _genderOverrides[char.name] ?? char.gender;

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
                    char.name.isEmpty ? '?' : char.name[0],
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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${char.lineCount} lines',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                // Gender toggle
                IconButton(
                  icon: Icon(
                    _genderIcon(effectiveGender),
                    color: _genderColor(effectiveGender),
                    size: 22,
                  ),
                  tooltip: _genderLabel(effectiveGender),
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await _toggleGender(char, effectiveGender);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.person_add_outlined),
                  tooltip: 'Invite actor',
                  onPressed: () => _inviteActor(char.name),
                ),
              ],
            ),
            // Voice config row
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text(
                    'Voice',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                  ),
                ),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        _showVoiceSheet(char, activeVoice, activeSpeed),
                    icon: const Icon(Icons.record_voice_over, size: 16),
                    label: Text(
                      '$voiceLabel  ${activeSpeed.toStringAsFixed(1)}x',
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                      foregroundColor: override != null
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Primary assignment
            _buildRoleRow(
              context,
              label: 'Primary',
              member: primary,
              color: color,
              onAssign: () => _assignRole(char.name, CastRole.primary),
            ),
            const SizedBox(height: 8),
            // Understudy assignment
            _buildRoleRow(
              context,
              label: 'Understudy',
              member: understudy,
              color: color.withValues(alpha: 0.6),
              onAssign: () => _assignRole(char.name, CastRole.understudy),
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
    required CastMemberModel? member,
    required Color color,
    required VoidCallback onAssign,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
          ),
        ),
        if (member != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  member.displayName.isNotEmpty
                      ? member.displayName
                      : 'Unnamed',
                  style: TextStyle(color: color, fontSize: 13),
                ),
                const SizedBox(width: 6),
                _statusBadge(member),
              ],
            ),
          ),
          const Spacer(),
          // Nudge button if invited but not joined
          if (!member.hasJoined)
            IconButton(
              icon: Icon(
                Icons.notifications_active,
                size: 16,
                color: Colors.orange[600],
              ),
              tooltip: 'Send reminder',
              onPressed: () => _nudge(member),
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: Colors.grey[600]),
            onPressed: () => _unassignRole(member),
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

  Widget _statusBadge(CastMemberModel member) {
    final joined = member.hasJoined;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: (joined ? Colors.green : Colors.orange).withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        joined ? 'Joined' : 'Invited',
        style: TextStyle(
          fontSize: 10,
          color: joined ? Colors.green : Colors.orange,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  void _assignRole(String characterName, CastRole role) {
    final nameController = TextEditingController();
    final contactController = TextEditingController();
    // The Assign handler awaits (local save, cloud invitation, share sheet)
    // before the dialog closes — a second tap in that window minted a second
    // cast member with its own id, its own cloud invitation and its own live
    // invite link.
    var isSubmitting = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Assign ${role.name} for $characterName'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Actor name',
                        border: OutlineInputBorder(),
                        hintText: 'Enter actor name',
                      ),
                      autofocus: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.contacts),
                    tooltip: 'Pick from contacts',
                    onPressed: () async {
                      try {
                        final contact = await ContactPickerService.instance
                            .pickContact();
                        if (contact == null) return;
                        nameController.text = contact.displayName;
                        contactController.text =
                            contact.phone ?? contact.email ?? '';
                        setDialogState(() {});
                      } catch (e) {
                        // A denied Contacts permission threw here silently —
                        // the button just looked dead.
                        DebugLogService.instance.logError(
                          LogCategory.general,
                          'Contact pick failed',
                          e,
                        );
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showAutoToast(
                          const SnackBar(
                            content: Text(
                              "Couldn't open your contacts — check that "
                              'CastCircle has Contacts permission, or type '
                              'the name in by hand.',
                            ),
                            duration: Duration(seconds: 5),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contactController,
                decoration: const InputDecoration(
                  labelText: 'Phone or email (optional)',
                  border: OutlineInputBorder(),
                  hintText: 'For sending join code',
                ),
                keyboardType: TextInputType.phone,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) return;

                      final production = ref.read(currentProductionProvider);
                      if (production == null) return;

                      setDialogState(() => isSubmitting = true);

                      final contact = contactController.text.trim();
                      final member = CastMemberModel(
                        id: const Uuid().v4(),
                        productionId: production.id,
                        characterName: characterName,
                        displayName: name,
                        contactInfo: contact.isNotEmpty ? contact : null,
                        role: role,
                        invitedAt: DateTime.now(),
                      );

                      final supa = SupabaseService.instance;
                      final hasCloudBacking =
                          supa.isSignedIn &&
                          production.organizerId.isNotEmpty &&
                          production.organizerId != 'local';
                      if (hasCloudBacking) {
                        try {
                          await supa.createCastInvitation(
                            productionId: production.id,
                            characterName: characterName,
                            displayName: name,
                            contactInfo: contact.isNotEmpty ? contact : null,
                            role: role.toSupabaseString(),
                            id: member.id,
                          );
                        } on CastPrimaryAlreadyAssignedException {
                          DebugLogService.instance.log(
                            LogCategory.network,
                            'Skipped $characterName primary invitation: '
                            'already assigned',
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                          if (mounted) {
                            await _syncCastFromCloud(production.id);
                          }
                          if (mounted) {
                            ScaffoldMessenger.of(context).showAutoToast(
                              SnackBar(
                                content: Text(
                                  '$characterName already has a primary actor',
                                ),
                                duration: const Duration(seconds: 5),
                              ),
                            );
                          }
                          return;
                        } catch (e, stack) {
                          DebugLogService.instance.logError(
                            LogCategory.network,
                            'Cloud cast invitation failed for "$name"',
                            e,
                            stack,
                          );
                          if (dialogContext.mounted) {
                            setDialogState(() => isSubmitting = false);
                          }
                          if (mounted) {
                            ScaffoldMessenger.of(context).showAutoToast(
                              const SnackBar(
                                content: Text(
                                  "Couldn't create the cloud invitation — "
                                  'check your connection and try again.',
                                ),
                                duration: Duration(seconds: 6),
                              ),
                            );
                          }
                          return;
                        }
                      }

                      try {
                        await ref
                            .read(castMembersProvider.notifier)
                            .save(member);
                      } catch (e, stack) {
                        DebugLogService.instance.logError(
                          LogCategory.general,
                          'Saving local cast assignment failed for "$name"',
                          e,
                          stack,
                        );
                        if (hasCloudBacking) {
                          try {
                            await supa.removeCastMember(
                              castMemberId: member.id,
                              productionId: production.id,
                            );
                          } catch (cleanupError, cleanupStack) {
                            DebugLogService.instance.logError(
                              LogCategory.network,
                              'Rolling back cloud cast invitation failed for '
                              '"$name"',
                              cleanupError,
                              cleanupStack,
                            );
                          }
                        }
                        if (dialogContext.mounted) {
                          setDialogState(() => isSubmitting = false);
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(context).showAutoToast(
                            const SnackBar(
                              content: Text('Could not save cast assignment'),
                            ),
                          );
                        }
                        return;
                      }

                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                        FocusScope.of(context).unfocus();
                      }

                      // Delay to let dialog and keyboard fully dismiss
                      await Future.delayed(const Duration(milliseconds: 400));

                      // Open share sheet with the invite
                      if (mounted) {
                        _inviteActor(characterName);
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Assign'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _unassignRole(CastMemberModel member) async {
    final who = member.displayName.isNotEmpty ? member.displayName : 'Actor';
    final supa = SupabaseService.instance;
    final production = ref.read(currentProductionProvider);
    final cloudBackedProduction =
        production != null &&
        production.organizerId.isNotEmpty &&
        production.organizerId != 'local';
    if (!supa.isSignedIn && cloudBackedProduction) {
      ScaffoldMessenger.of(context).showAutoToast(
        SnackBar(
          content: Text(
            "Can't remove $who while offline because the shared cast would "
            'restore them on the next sync. Reconnect and try again.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    // Delete the cloud row FIRST: _syncCastFromCloud re-saves every cloud row
    // locally, so a local-only removal boomerangs back on the next open — and
    // the invite link would still work in the meantime.
    if (supa.isSignedIn && cloudBackedProduction) {
      try {
        await supa.removeCastMember(
          castMemberId: member.id,
          productionId: member.productionId,
        );
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.network,
          'Unassign failed for "$who" (${member.characterName})',
          e,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text(
              "Couldn't remove $who from the shared cast — they'd "
              'reappear on the next sync. Check your connection, or ask the '
              'organizer to remove them.',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
        return;
      }
    }

    await ref.read(castMembersProvider.notifier).remove(member.id);
  }

  /// Build a smart invite link and share it directly.
  void _inviteActor(String characterName) {
    final production = ref.read(currentProductionProvider);
    final productionTitle = production?.title ?? 'a production';
    final joinCode = production?.joinCode;
    final supa = SupabaseService.instance;
    final hasCloudBacking =
        supa.isSignedIn &&
        production != null &&
        production.organizerId.isNotEmpty &&
        production.organizerId != 'local' &&
        joinCode != null &&
        joinCode.isNotEmpty;

    final deepLink = hasCloudBacking
        ? PendingJoin.buildUri(code: joinCode, characterName: characterName)
        : null;

    final shareText = deepLink != null
        ? 'You\'re invited to play $characterName in "$productionTitle" '
              'on CastCircle!\n\n'
              'Tap to join: $deepLink\n\n'
              'Or open CastCircle and enter code: $joinCode'
        : 'You\'ve been invited to join "$productionTitle" as $characterName '
              'on CastCircle! The organizer will send a join code once the '
              'production is online.';

    // Get position for iPad share popover
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? Rect.fromCenter(
            center: box.localToGlobal(box.size.center(Offset.zero)),
            width: 100,
            height: 50,
          )
        : null;

    Share.share(
      shareText,
      subject: 'CastCircle Invitation',
      sharePositionOrigin: origin,
    );
  }

  // pi-review 2026-08-13: UNREACHABLE — no caller wires this sheet (or the
  // invite-card flow behind it) into the UI; _inviteActor shares plain text
  // directly. Kept as the intended richer invite flow; wire or delete.
  // ignore: unused_element
  void _showInviteOptions({
    required String productionTitle,
    required String characterName,
    required String joinCode,
    required Uri deepLink,
  }) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Invite to $characterName',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.message),
              title: const Text('Send text invite'),
              subtitle: const Text('Share via Messages, WhatsApp, etc.'),
              onTap: () async {
                Navigator.pop(ctx);
                await Future.delayed(const Duration(milliseconds: 400));
                if (!mounted) return;
                _shareTextInvite(
                  productionTitle: productionTitle,
                  characterName: characterName,
                  joinCode: joinCode,
                  deepLink: deepLink,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('Send invite card'),
              subtitle: const Text('Visual card with QR code'),
              onTap: () async {
                Navigator.pop(ctx);
                await Future.delayed(const Duration(milliseconds: 400));
                if (!mounted) return;
                _shareInviteCard(
                  productionTitle: productionTitle,
                  characterName: characterName,
                  joinCode: joinCode,
                  deepLink: deepLink,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy join code'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: joinCode));
                ScaffoldMessenger.of(context).showAutoToast(
                  const SnackBar(
                    content: Text('Join code copied'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _shareTextInvite({
    required String productionTitle,
    required String characterName,
    required String joinCode,
    required Uri deepLink,
  }) {
    final shareText =
        'You\'ve been invited to play $characterName in "$productionTitle" '
        'on CastCircle!\n\n'
        'Tap to join: $deepLink\n\n'
        'Or open CastCircle and enter code: $joinCode';

    _shareWithOrigin(shareText, 'CastCircle Invitation');
  }

  /// Share text with a position origin (required for iOS share sheet).
  void _shareWithOrigin(String text, String subject) {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? Rect.fromCenter(
            center: box.localToGlobal(box.size.center(Offset.zero)),
            width: 100,
            height: 50,
          )
        : null;
    Share.share(text, subject: subject, sharePositionOrigin: origin);
  }

  Future<void> _shareInviteCard({
    required String productionTitle,
    required String characterName,
    required String joinCode,
    required Uri deepLink,
  }) async {
    // Build the invite card widget off-screen and capture as image
    final key = GlobalKey();
    final overlay = Overlay.of(context);

    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: -1000,
        top: -1000,
        child: RepaintBoundary(
          key: key,
          child: _InviteCardWidget(
            productionTitle: productionTitle,
            characterName: characterName,
            joinCode: joinCode,
          ),
        ),
      ),
    );

    overlay.insert(entry);
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      entry.remove();

      if (byteData == null) return;

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/castcircle_invite.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());

      await Share.shareXFiles(
        [XFile(file.path)],
        text:
            'Join "$productionTitle" as $characterName on CastCircle!\n'
            'Tap to join: $deepLink\n'
            'Or enter code: $joinCode',
        subject: 'CastCircle Invitation',
      );
    } catch (e) {
      entry.remove();
      debugPrint('Invite card share failed: $e');
      // Fallback to text
      _shareTextInvite(
        productionTitle: productionTitle,
        characterName: characterName,
        joinCode: joinCode,
        deepLink: deepLink,
      );
    }
  }

  void _shareJoinCode(String code) {
    final production = ref.read(currentProductionProvider);
    final title = production?.title ?? 'a production';

    final supa = SupabaseService.instance;
    final hasCloudBacking =
        supa.isSignedIn &&
        production != null &&
        production.organizerId.isNotEmpty &&
        production.organizerId != 'local' &&
        code.isNotEmpty;
    final deepLink = hasCloudBacking ? PendingJoin.buildUri(code: code) : null;
    final text = deepLink != null
        ? 'Join "$title" on CastCircle!\n\n'
              'Tap to join: $deepLink\n\n'
              'Or open CastCircle and enter code: $code'
        : 'You\'re invited to join "$title" on CastCircle! The organizer '
              'will send a join code once the production is online.';

    _shareWithOrigin(text, 'CastCircle Join Code');
  }

  void _nudge(CastMemberModel member) {
    final production = ref.read(currentProductionProvider);
    final title = production?.title ?? 'the production';
    final code = production?.joinCode ?? '';
    final supa = SupabaseService.instance;
    final hasCloudBacking =
        supa.isSignedIn &&
        production != null &&
        production.organizerId.isNotEmpty &&
        production.organizerId != 'local' &&
        code.isNotEmpty;
    final deepLink = hasCloudBacking
        ? PendingJoin.buildUri(code: code, characterName: member.characterName)
        : null;

    final text = deepLink != null
        ? 'Reminder: You\'re invited to play ${member.characterName} in '
              '"$title" on CastCircle.\n\nTap to join: $deepLink\n\n'
              'Or enter code: $code'
        : 'Reminder: You\'re invited to play ${member.characterName} in '
              '"$title" on CastCircle. Download the app to get started.';

    _shareWithOrigin(text, 'CastCircle Reminder');
  }

  void _shareCastList(ParsedScript script, List<CastMemberModel> members) {
    final production = ref.read(currentProductionProvider);
    final buffer = StringBuffer();
    buffer.writeln('Cast List: ${production?.title ?? script.title}');
    if (production?.joinCode != null) {
      buffer.writeln('Join Code: ${production!.joinCode}');
    }
    buffer.writeln('=' * 30);
    buffer.writeln();

    for (final char in script.characters) {
      buffer.writeln(char.name);
      final primary = members
          .where(
            (m) => m.characterName == char.name && m.role == CastRole.primary,
          )
          .toList();
      if (primary.isNotEmpty) {
        buffer.writeln(
          '  Primary: ${primary.first.displayName}'
          '${primary.first.hasJoined ? " (joined)" : " (invited)"}',
        );
      } else {
        buffer.writeln('  Primary: (unassigned)');
      }
      final understudies = members
          .where(
            (m) =>
                m.characterName == char.name && m.role == CastRole.understudy,
          )
          .toList();
      if (understudies.isNotEmpty) {
        buffer.writeln(
          '  Understudy: ${understudies.first.displayName}'
          '${understudies.first.hasJoined ? " (joined)" : " (invited)"}',
        );
      }
      buffer.writeln('  Lines: ${char.lineCount}');
      buffer.writeln();
    }

    _shareWithOrigin(buffer.toString(), 'Cast List');
  }

  // -- Gender helpers --

  static String _genderLabel(CharacterGender gender) => switch (gender) {
    CharacterGender.female => 'Female',
    CharacterGender.male => 'Male',
    CharacterGender.nonGendered => 'Non-gendered',
  };

  static IconData _genderIcon(CharacterGender gender) => switch (gender) {
    CharacterGender.female => Icons.female,
    CharacterGender.male => Icons.male,
    CharacterGender.nonGendered => Icons.transgender,
  };

  static Color _genderColor(CharacterGender gender) => switch (gender) {
    CharacterGender.female => Colors.pink,
    CharacterGender.male => Colors.blue,
    CharacterGender.nonGendered => Colors.purple,
  };

  Future<void> _toggleGender(
    ScriptCharacter char,
    CharacterGender currentGender,
  ) async {
    final newGender = switch (currentGender) {
      CharacterGender.female => CharacterGender.male,
      CharacterGender.male => CharacterGender.nonGendered,
      CharacterGender.nonGendered => CharacterGender.female,
    };

    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    try {
      await VoiceConfigService.instance.setGender(
        production.id,
        char.name,
        newGender,
      );
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Saving ${char.name} gender failed',
        e,
        stack,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(content: Text('Could not save character gender')),
        );
      }
      return;
    }
    if (!mounted) return;

    setState(() => _genderOverrides[char.name] = newGender);
    final script = ref.read(currentScriptProvider);
    if (script == null) return;
    final updatedCharacters = script.characters.map((c) {
      if (c.name == char.name) return c.copyWith(gender: newGender);
      return c;
    }).toList();

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: script.lines,
      characters: updatedCharacters,
      scenes: script.scenes,
      rawText: script.rawText,
    );
    scheduleScriptSave(ref);
  }

  // -- Voice config --

  void _showVoiceSheet(
    ScriptCharacter char,
    String currentVoice,
    double currentSpeed,
  ) {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;

    String selectedVoice = currentVoice;
    double selectedSpeed = currentSpeed;
    bool isPersisting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) => Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${char.name} Voice',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (_voiceOverrides.containsKey(char.name))
                      TextButton(
                        onPressed: isPersisting
                            ? null
                            : () async {
                                if (isPersisting) return;
                                setSheetState(() => isPersisting = true);
                                try {
                                  await _voiceConfig.removeOverride(
                                    production.id,
                                    char.name,
                                  );
                                  final overrides = await _voiceConfig
                                      .getOverrides(production.id);
                                  if (mounted) {
                                    setState(() => _voiceOverrides = overrides);
                                  }
                                  if (ctx.mounted) Navigator.pop(ctx);
                                } catch (e, stack) {
                                  DebugLogService.instance.logError(
                                    LogCategory.general,
                                    'Resetting ${char.name} voice failed',
                                    e,
                                    stack,
                                  );
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showAutoToast(
                                      const SnackBar(
                                        content: Text(
                                          'Could not reset the voice',
                                        ),
                                      ),
                                    );
                                  }
                                } finally {
                                  if (ctx.mounted) {
                                    setSheetState(() => isPersisting = false);
                                  }
                                }
                              },
                        child: const Text('Reset'),
                      ),
                    FilledButton(
                      onPressed: isPersisting
                          ? null
                          : () async {
                              if (isPersisting) return;
                              setSheetState(() => isPersisting = true);
                              try {
                                await _voiceConfig.setOverride(
                                  production.id,
                                  CharacterVoiceConfig(
                                    characterName: char.name,
                                    voiceId: selectedVoice,
                                    speed: selectedSpeed,
                                  ),
                                );
                                final overrides = await _voiceConfig
                                    .getOverrides(production.id);
                                if (mounted) {
                                  setState(() => _voiceOverrides = overrides);
                                }
                                if (ctx.mounted) Navigator.pop(ctx);
                              } catch (e, stack) {
                                DebugLogService.instance.logError(
                                  LogCategory.general,
                                  'Saving ${char.name} voice failed',
                                  e,
                                  stack,
                                );
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx).showAutoToast(
                                    const SnackBar(
                                      content: Text('Could not save the voice'),
                                    ),
                                  );
                                }
                              } finally {
                                if (ctx.mounted) {
                                  setSheetState(() => isPersisting = false);
                                }
                              }
                            },
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text('Speed', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Slider(
                        value: selectedSpeed,
                        min: 0.5,
                        max: 2.0,
                        divisions: 15,
                        label: '${selectedSpeed.toStringAsFixed(1)}x',
                        onChanged: (v) =>
                            setSheetState(() => selectedSpeed = v),
                      ),
                    ),
                    Text(
                      '${selectedSpeed.toStringAsFixed(1)}x',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: VoicePresets.voiceLabels.entries.map((entry) {
                    return RadioListTile<String>(
                      value: entry.key,
                      groupValue: selectedVoice,
                      title: Text(entry.value),
                      dense: true,
                      onChanged: (v) {
                        if (v != null) {
                          setSheetState(() => selectedVoice = v);
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visual invite card rendered off-screen and captured as an image.
class _InviteCardWidget extends StatelessWidget {
  final String productionTitle;
  final String characterName;
  final String joinCode;

  const _InviteCardWidget({
    required this.productionTitle,
    required this.characterName,
    required this.joinCode,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 400,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1a1a2e), Color(0xFF16213e)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // App branding
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.theater_comedy, color: Colors.amber[300], size: 28),
              const SizedBox(width: 8),
              Text(
                'CastCircle',
                style: TextStyle(
                  color: Colors.amber[300],
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // "You're invited"
          const Text(
            'YOU\'RE INVITED',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              letterSpacing: 3,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          // Production title
          Text(
            productionTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          // Character
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Text(
              'as $characterName',
              style: TextStyle(
                color: Colors.amber[200],
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 28),
          // Join code
          const Text(
            'JOIN CODE',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: Text(
              joinCode,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Instructions
          Text(
            'Download CastCircle and enter the code above',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
