import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app.dart';
import '../../data/models/cast_member_model.dart';
import '../../data/models/production_models.dart';
import '../../data/services/deep_link_service.dart';
import '../../data/services/supabase_service.dart';
import '../../providers/production_providers.dart';

class JoinProductionScreen extends ConsumerStatefulWidget {
  const JoinProductionScreen({super.key});

  @override
  ConsumerState<JoinProductionScreen> createState() =>
      _JoinProductionScreenState();
}

class _JoinProductionScreenState extends ConsumerState<JoinProductionScreen> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  bool _loading = false;
  String? _error;

  // After lookup
  Map<String, dynamic>? _foundProduction;
  List<Map<String, dynamic>>? _castMembers;
  String? _selectedCharacter;

  // Deep link pre-fill
  String? _prefilledCharacter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingJoin();
    });
  }

  void _checkPendingJoin() {
    final pending = ref.read(pendingJoinProvider);
    if (pending != null) {
      _codeController.text = pending.code;
      _prefilledCharacter = pending.characterName;
      if (pending.actorName != null) {
        _nameController.text = pending.actorName!;
      }
      // Clear the pending join so it doesn't trigger again
      ref.read(pendingJoinProvider.notifier).state = null;
      DeepLinkService.instance.clearPending();
      // Auto-lookup the code
      _lookupCode();
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final supa = SupabaseService.instance;
    final isSignedIn = supa.isSignedIn;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Join a Production'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!isSignedIn) ...[
              // Auth guard
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(Icons.lock_outline,
                          size: 48,
                          color:
                              Theme.of(context).colorScheme.onErrorContainer),
                      const SizedBox(height: 12),
                      Text(
                        'Sign in to join a production',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'You need an account to join productions and sync your recordings.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer
                                  .withValues(alpha: 0.7),
                            ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () {
                          // Reset auth gate so router allows auth screen
                          ref.read(authGatePassedProvider.notifier).state = false;
                          context.go('/auth');
                        },
                        child: const Text('Sign In'),
                      ),
                    ],
                  ),
                ),
              ),
            ] else if (_foundProduction == null) ...[
              // Step 1: Enter join code
              Icon(
                Icons.vpn_key_outlined,
                size: 64,
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'Enter the 6-character code\nshared by your director',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _codeController,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.characters,
                maxLength: 6,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      letterSpacing: 8,
                      fontWeight: FontWeight.bold,
                    ),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  counterText: '',
                  hintText: 'H4MK7P',
                  hintStyle: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        letterSpacing: 8,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.2),
                      ),
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _lookupCode(),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _loading ? null : _lookupCode,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                label: const Text('Find Production'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ] else ...[
              // Step 2: Confirm production and pick character
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(Icons.theater_comedy,
                          size: 48,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(
                        _foundProduction!['title'] as String? ?? 'Untitled',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Production found!',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.green,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  border: OutlineInputBorder(),
                  hintText: 'How should others see you?',
                ),
              ),
              const SizedBox(height: 16),
              // Show available characters (those without a joined primary)
              if (_castMembers != null) ...[
                Text('Pick your character:',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                ..._buildCharacterOptions(),
              ],
              const SizedBox(height: 8),
              // Option to join without a specific character
              RadioListTile<String>(
                value: '__none__',
                groupValue: _selectedCharacter,
                title: const Text('Join without a character'),
                subtitle: const Text('You can be assigned one later'),
                onChanged: (v) => setState(() => _selectedCharacter = v),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              FilledButton.icon(
                onPressed:
                    _loading || _nameController.text.trim().isEmpty
                        ? null
                        : _joinProduction,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.group_add),
                label: const Text('Join Production'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() {
                  _foundProduction = null;
                  _castMembers = null;
                  _selectedCharacter = null;
                  _error = null;
                }),
                child: const Text('Try a different code'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCharacterOptions() {
    if (_castMembers == null) return [];

    // Find characters that have been assigned but not joined
    // or characters that have no assignment at all
    final assignedChars = <String>{};
    final joinedChars = <String>{};
    for (final cm in _castMembers!) {
      final charName = cm['character_name'] as String? ?? '';
      if (charName.isNotEmpty) {
        assignedChars.add(charName);
        if (cm['user_id'] != null) joinedChars.add(charName);
      }
    }

    // Find unclaimed invitations that match current user
    final unclaimedInvitations = _castMembers!.where((cm) {
      return cm['user_id'] == null &&
          (cm['character_name'] as String? ?? '').isNotEmpty;
    }).toList();

    final widgets = <Widget>[];

    // Show unclaimed invitations first
    for (final inv in unclaimedInvitations) {
      final charName = inv['character_name'] as String;
      final isPreselected = _prefilledCharacter != null &&
          charName.toUpperCase() == _prefilledCharacter!.toUpperCase();
      widgets.add(
        RadioListTile<String>(
          value: charName,
          groupValue: _selectedCharacter,
          title: Text(charName),
          subtitle: Text(
            isPreselected
                ? 'You were invited for this role'
                : 'Invited as ${inv['role'] ?? 'actor'} - claim this spot',
          ),
          secondary: isPreselected
              ? Icon(Icons.star, color: Theme.of(context).colorScheme.primary)
              : null,
          onChanged: (v) => setState(() => _selectedCharacter = v),
        ),
      );
    }

    return widgets;
  }

  Future<void> _lookupCode() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(() => _error = 'Enter a 6-character code');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final supa = SupabaseService.instance;

      if (!supa.isInitialized) {
        setState(() {
          _error = 'Not connected to server. Check your internet connection.';
          _loading = false;
        });
        return;
      }

      final production = await supa.lookupByJoinCode(code);

      if (production == null) {
        setState(() {
          _error = 'No production found with code "$code". '
              'Check the code and try again. '
              '(signed in: ${supa.isSignedIn})';
          _loading = false;
        });
        return;
      }

      // Fetch cast members to show available characters
      final productionId = production['id'] as String;
      final cast = await supa.fetchCastMembers(productionId);

      // Auto-select the character that was pre-filled from deep link
      String? autoSelected;
      if (_prefilledCharacter != null) {
        for (final cm in cast) {
          final charName = cm['character_name'] as String? ?? '';
          if (charName.toUpperCase() == _prefilledCharacter!.toUpperCase() &&
              cm['user_id'] == null) {
            autoSelected = charName;
            break;
          }
        }
      }

      setState(() {
        _foundProduction = production;
        _castMembers = cast;
        _selectedCharacter = autoSelected;
        _loading = false;
      });
    } catch (e, stack) {
      setState(() {
        _error = 'Lookup failed: $e';
        _loading = false;
      });
      debugPrint('Join lookup error: $e\n$stack');
    }
  }

  Future<void> _joinProduction() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final supa = SupabaseService.instance;
      final userId = supa.currentUser!.id;
      final productionId = _foundProduction!['id'] as String;
      final characterName =
          _selectedCharacter == '__none__' ? '' : (_selectedCharacter ?? '');

      // Check if there's an unclaimed invitation for this character
      CastMemberModel? localMember;
      if (_castMembers != null && characterName.isNotEmpty) {
        final invitation = _castMembers!.where((cm) {
          return cm['user_id'] == null &&
              cm['character_name'] == characterName;
        }).toList();

        if (invitation.isNotEmpty) {
          // Claim existing invitation
          await supa.claimInvitation(
            castMemberId: invitation.first['id'] as String,
            userId: userId,
          );
          localMember = CastMemberModel(
            id: invitation.first['id'] as String,
            productionId: productionId,
            userId: userId,
            characterName: characterName,
            displayName: name,
            role: CastRole.fromString(
                invitation.first['role'] as String? ?? 'actor'),
            joinedAt: DateTime.now(),
          );
        }
      }

      if (localMember == null) {
        // Self-join: create new cast member
        final row = await supa.selfJoinProduction(
          productionId: productionId,
          userId: userId,
          characterName: characterName,
          displayName: name,
          role: 'actor',
        );
        localMember = CastMemberModel(
          id: row['id'] as String,
          productionId: productionId,
          userId: userId,
          characterName: characterName,
          displayName: name,
          role: CastRole.primary,
          joinedAt: DateTime.now(),
        );
      }

      // Save production locally
      final production = Production(
        id: productionId,
        title: _foundProduction!['title'] as String? ?? 'Untitled',
        organizerId: _foundProduction!['organizer_id'] as String? ?? '',
        createdAt: DateTime.tryParse(
                _foundProduction!['created_at'] as String? ?? '') ??
            DateTime.now(),
        status: ProductionStatus.draft,
        joinCode: _foundProduction!['join_code'] as String?,
      );

      await ref.read(productionsProvider.notifier).add(production);
      await ref.read(castMembersProvider.notifier).save(localMember);

      // Sync script from cloud
      final cloudLines = await fetchCloudScriptLines(productionId);
      if (cloudLines != null && cloudLines.isNotEmpty) {
        final script = buildParsedScript(production.title, cloudLines);
        ref.read(currentScriptProvider.notifier).state = script;
        ref.read(currentProductionProvider.notifier).state = production;
        await persistScript(ref);
      } else {
        ref.read(currentProductionProvider.notifier).state = production;
      }

      // Navigate to production hub
      if (mounted) {
        context.go('/production');
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to join: $e';
        _loading = false;
      });
    }
  }
}
