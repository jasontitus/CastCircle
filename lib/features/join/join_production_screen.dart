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
  bool _prefilledCharacterUnavailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingJoin();
    });
  }

  void _checkPendingJoin() {
    final pending = ref.read(pendingJoinProvider);
    if (pending == null) return;

    _codeController.text = pending.code;
    _prefilledCharacter = pending.characterName;
    if (pending.actorName != null) {
      _nameController.text = pending.actorName!;
    }

    // Authentication may dispose this screen. Keep the pending invite intact
    // so AuthScreen can route back here and the recreated screen can consume it.
    if (!SupabaseService.instance.isSignedIn) return;
    _lookupCode();
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
                if (_prefilledCharacterUnavailable)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'The invited role "$_prefilledCharacter" is no longer '
                        'available. Choose another role, or explicitly choose '
                        'to join without a character.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
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
                // ValueListenableBuilder instead of a per-keystroke
                // setState on the screen root: with a large cast, every
                // keystroke rebuilt the whole character list just to
                // enable/disable this button.
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _nameController,
                  builder: (context, nameValue, _) => FilledButton.icon(
                    onPressed:
                        _loading ||
                            nameValue.text.trim().isEmpty ||
                            _selectedCharacter == null
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
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() {
                    _foundProduction = null;
                    _castMembers = null;
                    _selectedCharacter = null;
                    _error = null;
                    _prefilledCharacter = null;
                    _prefilledCharacterUnavailable = false;
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
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text('Still contacting the server — one moment.'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: scaffold,
    );
  }

  List<Widget> _buildCharacterOptions() {
    if (_castMembers == null) return [];

    // Find unclaimed invitations (a character assigned by the director with no
    // user yet) — these are the roles a joiner can claim.
    final unclaimedInvitations = _castMembers!.where((cm) {
      return cm['claimed'] == false &&
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
              'Check the code and try again.';
          _loading = false;
        });
        return;
      }

      // Fetch cast members to show available characters. Pass the code:
      // the caller isn't a member yet, and the v3 RPC authorizes pre-join
      // roster reads by code knowledge only.
      final productionId = production['id'] as String;
      final cast = await supa.fetchCastMembers(
        productionId,
        joinCode: _codeController.text.trim().toUpperCase(),
      );
      if (!mounted) return;

      // Auto-select the character that was pre-filled from deep link
      String? autoSelected;
      if (_prefilledCharacter != null) {
        for (final cm in cast) {
          final charName = cm['character_name'] as String? ?? '';
          if (charName.toUpperCase() == _prefilledCharacter!.toUpperCase() &&
              cm['claimed'] == false) {
            autoSelected = charName;
            break;
          }
        }
      }

      setState(() {
        _foundProduction = production;
        _castMembers = cast;
        _selectedCharacter = autoSelected;
        _prefilledCharacterUnavailable =
            _prefilledCharacter != null && autoSelected == null;
        _loading = false;
      });
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Join lookup failed',
        e,
        stack,
      );
      if (!mounted) return;
      setState(() {
        _error =
            'Couldn\'t look up that code. '
            'Check your connection and try again.';
        _loading = false;
      });
    }
  }

  void _clearConsumedPendingJoin() {
    final pending = ref.read(pendingJoinProvider);
    final joinedCode = _codeController.text.trim().toUpperCase();
    if (pending == null || pending.code.toUpperCase() != joinedCode) return;

    ref.read(pendingJoinProvider.notifier).state = null;
    DeepLinkService.instance.clearPending();
  }

  Future<void> _joinProduction() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final dlog = DebugLogService.instance;
    var membershipCommitted = false;
    var localMembershipDurable = false;
    try {
      final supa = SupabaseService.instance;
      final user = supa.currentUser;
      if (user == null) {
        // Session lapsed between render (isSignedIn gate) and the tap.
        setState(() {
          _loading = false;
          _error = 'Your session expired — please sign in again.';
        });
        return;
      }
      final userId = user.id;
      final productionId = _foundProduction!['id'] as String;
      final characterName = _selectedCharacter == '__none__'
          ? ''
          : (_selectedCharacter ?? '');

      dlog.log(
        LogCategory.network,
        'Join: joining production $productionId as '
        '"${characterName.isEmpty ? '(no character)' : characterName}" user=$userId',
      );

      // Check if there's an unclaimed invitation for this character
      CastMemberModel? localMember;
      if (_castMembers != null && characterName.isNotEmpty) {
        final invitation = _castMembers!.where((cm) {
          return cm['claimed'] == false &&
              cm['character_name'] == characterName;
        }).toList();

        if (invitation.isNotEmpty) {
          // Claim existing invitation
          await supa.claimInvitation(
            castMemberId: invitation.first['id'] as String,
            userId: userId,
            joinCode: _codeController.text.trim().toUpperCase(),
            displayName: name,
          );
          membershipCommitted = true;
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
          joinCode: _codeController.text.trim().toUpperCase(),
        );
        membershipCommitted = true;
        localMember = CastMemberModel(
          id: row['id'] as String,
          productionId: productionId,
          userId: userId,
          characterName: row['character_name'] as String? ?? characterName,
          displayName: row['display_name'] as String? ?? name,
          role: CastRole.fromString(row['role'] as String? ?? 'actor'),
          joinedAt:
              DateTime.tryParse(row['joined_at'] as String? ?? '') ??
              DateTime.now(),
        );
      }

      // From here on the user is a cloud member. Everything else is local
      // setup and must not turn a successful join into a reported join failure.
      if (!mounted) {
        dlog.log(
          LogCategory.network,
          'Join: screen closed after cloud membership commit — local setup '
          'deferred to the next sync',
        );
        return;
      }

      // The pre-join lookup intentionally exposes only id/title. Membership
      // now authorizes fetching the complete production row for local storage.
      final productionRow = await supa.fetchProduction(productionId);
      if (!mounted) return;
      final production = Production(
        id: productionId,
        title: productionRow['title'] as String? ?? 'Untitled',
        organizerId: productionRow['organizer_id'] as String? ?? '',
        createdAt:
            DateTime.tryParse(productionRow['created_at'] as String? ?? '') ??
            DateTime.now(),
        status: ProductionStatus.draft,
        joinCode: productionRow['join_code'] as String?,
        locale: productionRow['locale'] as String? ?? 'en-US',
      );

      await ref.read(productionsProvider.notifier).add(production);
      if (!mounted) return;
      await ref.read(castMembersProvider.notifier).save(localMember);
      localMembershipDurable = true;
      if (!mounted) return;

      _clearConsumedPendingJoin();
      AnalyticsService.instance.logProductionJoined();
      // Publish the production scope before its script. Hub listeners use this
      // ordering to avoid applying a new production's script to old selection
      // preferences.
      ref.read(rehearsalCharacterProvider.notifier).state = null;
      ref.read(selectedSceneProvider.notifier).state = null;
      ref.read(currentProductionProvider.notifier).state = production;
      ref.read(currentScriptProvider.notifier).state = null;

      // Sync script from cloud
      final cloudLines = await fetchCloudScriptLines(productionId);
      if (!mounted) return;
      if (cloudLines != null && cloudLines.isNotEmpty) {
        dlog.log(
          LogCategory.network,
          'Join: pulled ${cloudLines.length} script lines from cloud',
        );
        final script = await buildParsedScriptWithCloudScenes(
          production.title,
          cloudLines,
          production.id,
        );
        ref.read(currentScriptProvider.notifier).state = script;
        // Local-only save: this script just came FROM the cloud. persistScript
        // would push it straight back (a delete+reinsert the joiner isn't even
        // allowed to do, racing the organizer if RLS ever permits it).
        await persistScriptLocally(ref, productionId, script);
        if (!mounted) return;
      } else {
        dlog.log(
          LogCategory.network,
          'Join: no cloud script yet — director may not have imported one',
        );
      }

      // Sync organizer's voice preset from the member-authorized full row.
      final voicePreset = productionRow['voice_preset'] as String?;
      if (voicePreset != null) {
        await VoiceConfigService.instance.setPreset(productionId, voicePreset);
      }

      dlog.log(
        LogCategory.network,
        'Join: success — opening production "${production.title}"',
      );

      // Navigate to production hub. Clear _loading first so the screen isn't
      // still holding the back gesture as the router swaps it out.
      if (mounted) {
        setState(() => _loading = false);
        context.go('/production');
      }
    } catch (e, stack) {
      if (membershipCommitted) {
        dlog.logError(
          LogCategory.network,
          localMembershipDurable
              ? 'Join membership saved locally, but optional setup failed'
              : 'Join membership committed in cloud, but local save failed',
          e,
          stack,
        );
        if (!mounted) return;
        if (!localMembershipDurable) {
          setState(() {
            _error =
                'You joined in the cloud, but this device could not save '
                'the production yet. Tap Join Production to retry setup.';
            _loading = false;
          });
          return;
        }

        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
              'You joined successfully, but optional setup on this '
              'device could not finish. Reopen the production to retry.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
        context.go('/');
        return;
      }

      dlog.logError(LogCategory.network, 'Join FAILED', e, stack);
      if (!mounted) return;
      setState(() {
        _error =
            'Couldn\'t join this production. '
            'Check your connection and try again.';
        _loading = false;
      });
    }
  }
}
