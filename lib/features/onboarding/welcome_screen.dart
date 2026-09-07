import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/toast.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/demo_production_service.dart';

/// First-run walkthrough: what the app does, how a script gets in, how
/// rehearsal works, and how to get a cast into it.
///
/// Ends on the two things a new user can actually do next — open the bundled
/// demo, or import their own script — because a walkthrough that ends on
/// "Done" drops the reader back where they started.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  /// Show once per install, before anything else asks for attention.
  ///
  /// Awaited by the caller so the model-download offer queues up behind it
  /// rather than landing on top of it.
  static Future<void> maybeOffer(
    BuildContext context, {
    @visibleForTesting Future<SharedPreferences>? preferences,
  }) async {
    final prefs = await (preferences ?? SharedPreferences.getInstance());
    if (!context.mounted) return;
    // The screenshot/integration runs drive a seeded app; a walkthrough over
    // the top of it would be captured instead of the screen under test.
    if (prefs.getBool('screenshot_mode') == true) return;
    if (prefs.getBool('welcome_seen') == true) return;

    // push() completes only after the walkthrough closes. Do not consume this
    // one-time offer when the initiating route was disposed before navigation
    // could start, or when navigation itself fails.
    await context.push('/welcome');
    if (!context.mounted) return;
    await prefs.setBool('welcome_seen', true);
  }

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _Page {
  const _Page({
    required this.icon,
    required this.title,
    required this.body,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String body;

  /// Secondary paragraph, shown smaller — the "where do I tap" specifics.
  final String? detail;
}

const _pages = <_Page>[
  _Page(
    icon: Icons.theater_comedy,
    title: 'Rehearse without\nthe rest of the cast',
    body:
        'CastCircle reads everyone else’s lines aloud so you can run a '
        'scene on your own — on the bus, in the kitchen, the night before.',
    detail:
        'Everything happens on your device. No connection needed to '
        'rehearse.',
  ),
  _Page(
    icon: Icons.document_scanner_outlined,
    title: 'Bring in\nyour script',
    body:
        'Import a PDF or a text file. Scanned pages are read on-device, '
        'then you fix anything the scan got wrong — with the original page '
        'beside it, so you can see where a line came from.',
    detail:
        'No script to hand? The demo is two scenes of Hamlet, already '
        'set up.',
  ),
  _Page(
    icon: Icons.mic_none,
    title: 'Three ways\nto run a scene',
    body:
        'Listen plays the whole scene. Read follows along while you speak. '
        'Cue waits for you: it listens for your line and moves on when '
        'you’ve said it.',
    detail:
        'Turn on blind rehearsal to hide your own lines and find out '
        'what you actually know.',
  ),
  _Page(
    icon: Icons.groups_outlined,
    title: 'Invite\nyour cast',
    body:
        'Every production has a join code. Share it and your castmates '
        'get the same script, already cast, on their own phones.',
    detail:
        'Cast & Roles → tap a character → Invite sends that actor a link '
        'straight to their part. Once someone records their lines, everyone '
        'rehearsing hears the real voice instead of the AI one.',
  ),
];

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  final _controller = PageController();
  int _page = 0;
  bool _loadingDemo = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLast => _page == _pages.length - 1;

  Future<void> _openDemo() async {
    setState(() => _loadingDemo = true);
    // Capture the router BEFORE popping: this screen's context is dead once
    // the walkthrough is gone, and navigating with it would throw in
    // GoRouter.of. Same pattern as the new-production dialog.
    final router = GoRouter.of(context);
    try {
      await DemoProductionService.instance.load(ref);
      AnalyticsService.instance.logDemoOpened();
      if (!mounted) return;
      router.pop(); // leave the walkthrough behind
      router.push('/production');
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Loading the demo failed',
        e,
        stack,
      );
      if (!mounted) return;
      setState(() => _loadingDemo = false);
      ScaffoldMessenger.of(context).showAutoToast(
        SnackBar(
          content: Text("Couldn't open the demo: $e"),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: Text(_isLast ? 'Close' : 'Skip'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _buildPage(theme, _pages[i]),
              ),
            ),
            _buildDots(theme),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: _isLast ? _buildFinalActions(theme) : _buildNext(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(ThemeData theme, _Page page) {
    // Scrollable: at the smallest phone height with the largest text scale
    // these paragraphs do not fit, and a walkthrough that overflows on page
    // one is a bad first impression.
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Icon(page.icon, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 28),
          Text(
            page.title,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            page.body,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
          ),
          if (page.detail != null) ...[
            const SizedBox(height: 18),
            Text(
              page.detail!,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.4,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildDots(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pages.length, (i) {
        final active = i == _page;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.25),
          ),
        );
      }),
    );
  }

  Widget _buildNext() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: () => _controller.nextPage(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ),
        child: const Text('Next'),
      ),
    );
  }

  Widget _buildFinalActions(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _loadingDemo ? null : _openDemo,
            icon: _loadingDemo
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_circle_outline),
            label: Text(_loadingDemo ? 'Opening…' : 'Try the demo'),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _loadingDemo ? null : () => context.pop(),
            child: const Text('Start with my own script'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'You can reopen this from the ⓘ button any time.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
