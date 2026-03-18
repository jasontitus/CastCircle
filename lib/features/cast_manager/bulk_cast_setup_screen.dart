import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/cast_member_model.dart';
import '../../data/models/script_models.dart';
import '../../data/services/contact_picker_service.dart';
import '../../data/services/deep_link_service.dart';
import '../../data/services/supabase_service.dart';
import '../../providers/production_providers.dart';

/// Bulk cast setup: single scrollable form for assigning actors to characters.
/// Fill in as many or as few as you want, then save.
class BulkCastSetupScreen extends ConsumerStatefulWidget {
  const BulkCastSetupScreen({super.key});

  @override
  ConsumerState<BulkCastSetupScreen> createState() =>
      _BulkCastSetupScreenState();
}

class _BulkCastSetupScreenState extends ConsumerState<BulkCastSetupScreen> {
  final Map<String, TextEditingController> _nameControllers = {};
  final Map<String, TextEditingController> _contactControllers = {};

  bool _saving = false;

  @override
  void dispose() {
    for (final c in _nameControllers.values) {
      c.dispose();
    }
    for (final c in _contactControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _nameFor(String charName) {
    return _nameControllers.putIfAbsent(
        charName, () => TextEditingController());
  }

  TextEditingController _contactFor(String charName) {
    return _contactControllers.putIfAbsent(
        charName, () => TextEditingController());
  }

  int get _filledCount => _nameControllers.values
      .where((c) => c.text.trim().isNotEmpty)
      .length;

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final castMembers = ref.watch(castMembersProvider);
    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Set Up Cast')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    // Show only characters that don't already have a primary actor
    final unassigned = script.characters.where((char) {
      return !castMembers.any(
          (m) => m.characterName == char.name && m.role == CastRole.primary);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set Up Cast'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          if (!unassigned.every((c) => _nameFor(c.name).text.trim().isEmpty))
            TextButton.icon(
              onPressed: _saving ? null : _saveAndShowInvites,
              icon: const Icon(Icons.check),
              label: const Text('Save'),
            ),
        ],
      ),
      body: unassigned.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 64,
                      color: Colors.green.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  const Text('All characters have actors assigned!'),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              itemCount: unassigned.length + 1, // +1 for header
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Fill in as many as you like, then save.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                          ),
                    ),
                  );
                }
                final char = unassigned[index - 1];
                final color = AppTheme.colorForCharacter(char.colorIndex);
                return _buildCharacterCard(char, color);
              },
            ),
      bottomNavigationBar: unassigned.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text(
                      '$_filledCount of ${unassigned.length} filled in',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _saving ? null : _saveAndShowInvites,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save),
                      label: const Text('Save'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildCharacterCard(ScriptCharacter char, Color color) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color,
                  radius: 14,
                  child: Text(
                    char.name[0],
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${char.name}  (${char.lineCount} lines)',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameFor(char.name),
              decoration: InputDecoration(
                labelText: 'Actor name',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.person_add, size: 20),
                  tooltip: 'Pick from contacts',
                  onPressed: () => _pickContact(char.name),
                ),
              ),
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contactFor(char.name),
              decoration: const InputDecoration(
                labelText: 'Phone or email (for invite)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickContact(String charName) async {
    try {
      final contact = await ContactPickerService.instance.pickContact();
      if (contact == null) return;

      _nameFor(charName).text = contact.displayName;
      _contactFor(charName).text = contact.phone ?? contact.email ?? '';
      setState(() {});
    } catch (e) {
      debugPrint('Contact pick failed: $e');
    }
  }

  Future<void> _saveCastAssignments() async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;

    final supa = SupabaseService.instance;

    for (final entry in _nameControllers.entries) {
      final charName = entry.key;
      final name = entry.value.text.trim();
      if (name.isEmpty) continue;

      final contact = _contactFor(charName).text.trim();

      // Create in Supabase first so we can use its ID locally
      String memberId = const Uuid().v4();
      if (supa.isSignedIn) {
        try {
          final row = await supa.createCastInvitation(
            productionId: production.id,
            characterName: charName,
            displayName: name,
            contactInfo: contact.isNotEmpty ? contact : null,
            role: 'actor',
          );
          memberId = row['id'] as String;
        } catch (e) {
          debugPrint('Supabase cast invitation failed: $e');
        }
      }

      final member = CastMemberModel(
        id: memberId,
        productionId: production.id,
        characterName: charName,
        displayName: name,
        contactInfo: contact.isNotEmpty ? contact : null,
        role: CastRole.primary,
        invitedAt: DateTime.now(),
      );

      await ref.read(castMembersProvider.notifier).save(member);
    }
  }

  Future<void> _saveAndShowInvites() async {
    // Dismiss keyboard before showing the invite sheet
    FocusScope.of(context).unfocus();

    setState(() => _saving = true);
    await _saveCastAssignments();
    setState(() => _saving = false);

    if (!mounted) return;

    final saved = _filledCount;
    if (saved == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No actors to save (fill in at least one name)')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$saved actor(s) saved')),
    );

    // Show invite links sheet so director can share individually
    _showInviteLinksSheet();
  }

  void _showInviteLinksSheet() {
    final production = ref.read(currentProductionProvider);
    final joinCode = production?.joinCode ?? '';
    final title = production?.title ?? 'a production';

    // Collect actors that were filled in
    final actors = <MapEntry<String, String>>[];
    for (final entry in _nameControllers.entries) {
      final name = entry.value.text.trim();
      if (name.isNotEmpty) {
        actors.add(MapEntry(entry.key, name));
      }
    }

    if (actors.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.85,
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Send Invites',
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      context.pop(); // back to cast manager
                    },
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: actors.length,
                itemBuilder: (context, index) {
                  final charName = actors[index].key;
                  final actorName = actors[index].value;
                  final deepLink = PendingJoin.buildUri(
                    code: joinCode,
                    characterName: charName,
                    actorName: actorName,
                  );
                  final inviteText =
                      'You\'re invited to play $charName in "$title" '
                      'on CastCircle!\n\n'
                      'Tap to join: $deepLink\n\n'
                      'Or open CastCircle and enter code: $joinCode';

                  return ListTile(
                    title: Text(actorName),
                    subtitle: Text('as $charName'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.copy, size: 20),
                          tooltip: 'Copy invite',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: inviteText));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Invite for $actorName copied'),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                        Builder(
                          builder: (btnContext) => IconButton(
                            icon: const Icon(Icons.share, size: 20),
                            tooltip: 'Share invite',
                            onPressed: () {
                              final box = btnContext.findRenderObject() as RenderBox?;
                              final origin = box != null
                                  ? box.localToGlobal(Offset.zero) & box.size
                                  : null;
                              Share.share(
                                inviteText,
                                subject: 'CastCircle: $charName',
                                sharePositionOrigin: origin,
                              );
                            },
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
}
