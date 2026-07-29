import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app.dart';
import '../../core/responsive.dart';
import '../../data/models/cast_member_model.dart';
import '../../data/models/production_models.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/deep_link_service.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';
import '../../core/toast.dart';

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

    final scaffold = Scaffold(
      appBar: AppBar(
        title: const Text('Join a Production'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _loading ? null : () => context.pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ContentConstraint(
          maxWidth: 520,
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
                        Icon(
                          Icons.lock_outline,
                          size: 48,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Sign in to join a production',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'You need an account to join productions and sync your recordings.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
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
                            ref.read(authGatePassedProvider.notifier).state =
                                false;
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
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.5),
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
                    hintStyle: Theme.of(context).textTheme.headlineLarge
                        ?.copyWith(
                          letterSpacing: 8,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.2),
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
                        Icon(
                          Icons.theater_comedy,
                          size: 48,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _foundProduction!['title'] as String? ?? 'Untitled',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Production found!',
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: Colors.green),
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
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                // Show available characters (those without a joined primary)
                if (_castMembers != null) ...[
                  Text(
                    'Pick your character:',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
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
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _loading || _nameController.text.trim().isEmpty
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
      ),
    );

    // Leaving mid-request would tear this State down while a lookup/join is
    // still in flight; a half-finished join can also create the cloud cast row
    // without ever saving the production locally. Hold the screen (and the
    // swipe/system back it covers) until the request settles.
    return PopScope(
      canPop: !_loading,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_loading) return;
        ScaffoldMessenger.of(context).showAutoToast(const SnackBar(
          content: Text('Still contacting the server — one moment.'),
          duration: Duration(seconds: 2),
        ));
      },
      child: scaffold,
    );
  }

  List<Widget> _buildCharacterOptions() {
    if (_castMembers == null) return [];

    // Find unclaimed invitations (a character assigned by the director with no
    // user yet) — these are the roles a joiner can claim.
    final unclaimedInvitations = _castMembers!.where((cm) {
      return cm['user_id'] == null &&
          (cm['character_name'] as String? ?? '').isNotEmpty;
    }).toList();

    final widgets = <Widget>[];

    // Show unclaimed invitations first
    for (final inv in unclaimedInvitations) {
      final charName = inv['character_name'] as String;
      final isPreselected =
          _prefilledCharacter != null &&
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
      if (!mounted) return;

      if (production == null) {
        setState(() {
          _error =
              'No production found with code "$code". '
              'Check the code and try again. '
              '(signed in: ${supa.isSignedIn})';
          _loading = false;
        });
        return;
      }

      // Fetch cast members to show available characters
      final productionId = production['id'] as String;
      final cast = await supa.fetchCastMembers(productionId);
      if (!mounted) return;

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
      DebugLogService.instance
          .logError(LogCategory.network, 'Join lookup failed', e, stack);
      if (!mounted) return;
      setState(() {
        _error = 'Lookup failed: $e';
        _loading = false;
      });
    }
  }

  Future<void> _joinProduction() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final dlog = DebugLogService.instance;
    try {
      final supa = SupabaseService.instance;
      final userId = supa.currentUser!.id;
      final productionId = _foundProduction!['id'] as String;
      final characterName = _selectedCharacter == '__none__'
          ? ''
          : (_selectedCharacter ?? '');

      dlog.log(LogCategory.network,
          'Join: joining production $productionId as '
          '"${characterName.isEmpty ? '(no character)' : characterName}" user=$userId');

      // Check if there's an unclaimed invitation for this character
      CastMemberModel? localMember;
      if (_castMembers != null && characterName.isNotEmpty) {
        final invitation = _castMembers!.where((cm) {
          return cm['user_id'] == null && cm['character_name'] == characterName;
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
              invitation.first['role'] as String? ?? 'actor',
            ),
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

      // Save production locally (including organizer's locale)
      final production = Production(
        id: productionId,
        title: _foundProduction!['title'] as String? ?? 'Untitled',
        organizerId: _foundProduction!['organizer_id'] as String? ?? '',
        createdAt:
            DateTime.tryParse(
              _foundProduction!['created_at'] as String? ?? '',
            ) ??
            DateTime.now(),
        status: ProductionStatus.draft,
        joinCode: _foundProduction!['join_code'] as String?,
        locale: _foundProduction!['locale'] as String? ?? 'en-US',
      );

      // The cast row now exists in the cloud. If the screen went away during
      // those calls `ref` is dead, so stop here rather than throwing — the next
      // sync pulls the production down.
      if (!mounted) {
        dlog.log(LogCategory.network,
            'Join: screen closed mid-join — cloud row created, local save '
            'deferred to the next sync');
        return;
      }

      await ref.read(productionsProvider.notifier).add(production);
      if (!mounted) return;
      await ref.read(castMembersProvider.notifier).save(localMember);
      if (!mounted) return;
      AnalyticsService.instance.logProductionJoined();

      // Sync script from cloud
      final cloudLines = await fetchCloudScriptLines(productionId);
      if (!mounted) return;
      if (cloudLines != null && cloudLines.isNotEmpty) {
        dlog.log(LogCategory.network,
            'Join: pulled ${cloudLines.length} script lines from cloud');
        final script = buildParsedScript(production.title, cloudLines);
        ref.read(currentScriptProvider.notifier).state = script;
        ref.read(currentProductionProvider.notifier).state = production;
        // Local-only save: this script just came FROM the cloud. persistScript
        // would push it straight back (a delete+reinsert the joiner isn't even
        // allowed to do, racing the organizer if RLS ever permits it).
        await persistScriptLocally(ref, productionId, script);
        if (!mounted) return;
      } else {
        dlog.log(LogCategory.network,
            'Join: no cloud script yet — director may not have imported one');
        ref.read(currentProductionProvider.notifier).state = production;
      }

      // Sync organizer's voice preset (from production row or lookup data)
      final voicePreset = _foundProduction!['voice_preset'] as String?;
      if (voicePreset != null) {
        await VoiceConfigService.instance.setPreset(productionId, voicePreset);
      }

      dlog.log(LogCategory.network,
          'Join: success — opening production "${production.title}"');

      // Navigate to production hub. Clear _loading first so the screen isn't
      // still holding the back gesture as the router swaps it out.
      if (mounted) {
        setState(() => _loading = false);
        context.go('/production');
      }
    } catch (e, stack) {
      dlog.logError(LogCategory.network, 'Join FAILED', e, stack);
      if (!mounted) return;
      setState(() {
        _error = 'Failed to join: $e';
        _loading = false;
      });
    }
  }
}
