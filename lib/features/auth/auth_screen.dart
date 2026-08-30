import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;

import '../../app.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/supabase_service.dart';
import '../../main.dart';
import '../../providers/production_providers.dart';
import '../../core/toast.dart';

/// Auth state provider — tracks whether user is signed in.
final authStateProvider = StateProvider<bool>((ref) {
  return SupabaseService.instance.isSignedIn;
});

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  static const _minimumPasswordLength = 12;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _isLoading = false;
  String? _error;

  /// Set once a signup succeeds but returns no session (email confirmation
  /// required), or a sign-in is rejected for an unconfirmed address. Drives
  /// the "check your inbox" panel instead of dropping the user into the app
  /// without a session.
  String? _awaitingConfirmationFor;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pendingJoin = ref.watch(pendingJoinProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Pending invite banner
                  if (pendingJoin != null) ...[
                    Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.mail_outline,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'You\'ve been invited!',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onPrimaryContainer,
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    pendingJoin.characterName != null
                                        ? 'Join as ${pendingJoin.characterName}'
                                        : 'Sign in to join the production',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimaryContainer
                                              .withValues(alpha: 0.8),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Logo area
                  Icon(
                    Icons.theater_comedy,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'CastCircle',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your scene partner in your pocket',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 48),
                  // Email field
                  AutofillGroup(
                    child: Column(
                      children: [
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.email_outlined),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Password field
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          autofillHints: _isSignUp
                              ? const [AutofillHints.newPassword]
                              : const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            helperText: _isSignUp
                                ? 'Use at least $_minimumPasswordLength characters; '
                                      'a passphrase works well.'
                                : null,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.lock_outlined),
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                      ],
                    ),
                  ),
                  // Signup succeeded but the account needs email confirmation
                  // before it has a session — say so instead of silently
                  // doing nothing when the button is tapped.
                  if (_awaitingConfirmationFor != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Icon(
                              Icons.mark_email_unread_outlined,
                              size: 36,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Confirm your email',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSecondaryContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'We sent a link to $_awaitingConfirmationFor. '
                              'Tap it, then come back and sign in.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSecondaryContainer
                                        .withValues(alpha: 0.85),
                                  ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              children: [
                                TextButton.icon(
                                  onPressed: _isLoading
                                      ? null
                                      : _resendConfirmation,
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: const Text('Resend email'),
                                ),
                                TextButton(
                                  onPressed: _isLoading
                                      ? null
                                      : () => setState(() {
                                          _awaitingConfirmationFor = null;
                                          _isSignUp = false;
                                          _error = null;
                                        }),
                                  child: const Text('I confirmed — sign in'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  // Submit button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isLoading ? null : _submit,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isSignUp ? 'Create Account' : 'Sign In'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Toggle sign in / sign up
                  TextButton(
                    onPressed: () => setState(() {
                      _isSignUp = !_isSignUp;
                      _error = null;
                    }),
                    child: Text(
                      _isSignUp
                          ? 'Already have an account? Sign in'
                          : 'New here? Create an account',
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Skip auth for local-only usage
                  if (pendingJoin != null) ...[
                    Text(
                      'An account is required to join shared productions.',
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                    ),
                  ] else ...[
                    OutlinedButton(
                      onPressed: _skipAuth,
                      child: const Text('Continue without account'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'You can sign in later to sync with your cast',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please enter email and password');
      return;
    }
    if (_isSignUp && password.length < _minimumPasswordLength) {
      setState(
        () => _error =
            'Use a password of at least $_minimumPasswordLength characters.',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      if (_isSignUp) {
        final res = await SupabaseService.instance.signUpWithEmail(
          email,
          password,
        );
        // With email confirmation enabled the server returns a user but NO
        // session — the account isn't usable until the link is clicked. The
        // old code navigated straight into the app, leaving the user
        // "signed in" with no session and every cloud call failing.
        if (res.session == null) {
          if (mounted) {
            setState(() {
              _awaitingConfirmationFor = email;
              _isLoading = false;
            });
          }
          return;
        }
      } else {
        await SupabaseService.instance.signInWithEmail(email, password);
      }
      TextInput.finishAutofillContext();
      if (mounted) {
        ref.read(authStateProvider.notifier).state = true;
        ref.read(authGatePassedProvider.notifier).state = true;

        // If there's a pending join, go straight to join screen
        final pendingJoin = ref.read(pendingJoinProvider);
        if (pendingJoin != null) {
          context.go('/join');
        } else {
          context.go('/');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = _friendlyAuthError(e, email));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Raw Supabase errors are unhelpful to actors ("AuthApiException(message:
  /// Email not confirmed, statusCode: 400)"). Translate the ones users
  /// actually hit.
  String _friendlyAuthError(Object e, String email) {
    final text = e.toString().toLowerCase();
    if (text.contains('not confirmed')) {
      _awaitingConfirmationFor = email;
      return 'Confirm your email first — check your inbox for the link '
          'we sent to $email.';
    }
    if (text.contains('invalid login credentials')) {
      return 'Wrong email or password.';
    }
    if (text.contains('already registered') ||
        text.contains('already been registered')) {
      return 'That email already has an account — try signing in.';
    }
    if (text.contains('password') && text.contains('characters')) {
      return 'Use a password of at least $_minimumPasswordLength characters.';
    }
    return e.toString();
  }

  Future<void> _resendConfirmation() async {
    final email = _awaitingConfirmationFor;
    if (email == null) return;
    setState(() => _isLoading = true);
    try {
      await SupabaseService.instance.client.auth.resend(
        type: OtpType.signup,
        email: email,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(content: Text('Confirmation email re-sent to $email')),
        );
      }
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Resend confirmation failed',
        e,
      );
      if (mounted) {
        setState(() => _error = "Couldn't resend the email: $e");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _skipAuth() {
    // Guest mode is a SUPPORTED product state (confirmed 2026-07-30): the
    // whole local experience works without an account; an email/sign-in is
    // required only to join or share productions, and every cloud entry
    // point (join screen, share/sync paths) independently checks
    // isSignedIn. The flag below is therefore a UX convenience, not a
    // security boundary — a spuriously-restored flag grants nothing that
    // tapping "skip" wouldn't.
    // Persist the skip choice so the user isn't asked again on next launch.
    ref.read(sharedPreferencesProvider).setBool('auth_skipped', true);
    ref.read(authStateProvider.notifier).state = true;
    ref.read(authGatePassedProvider.notifier).state = true;
    context.go('/');
  }
}
