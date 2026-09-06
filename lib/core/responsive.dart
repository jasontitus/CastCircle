import 'package:flutter/material.dart';

/// Responsive breakpoints for adaptive layouts.
class Responsive {
  /// Compact: phones (< 600dp)
  static const double compactBreakpoint = 600;

  /// Medium: small tablets, large phones in landscape (600-840dp)
  static const double mediumBreakpoint = 840;

  /// Expanded: tablets, desktops (> 840dp)
  static const double expandedBreakpoint = 1200;

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compactBreakpoint;

  static bool isMedium(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= compactBreakpoint && w < mediumBreakpoint;
  }

  static bool isExpanded(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= mediumBreakpoint;

  /// True for any non-phone layout (tablet, landscape phone, desktop).
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= compactBreakpoint;
}

/// A scaffold that shows its drawer as a permanent sidebar on wide screens.
///
/// On phones: standard Scaffold with hamburger drawer.
/// On tablets/desktop: drawer is always visible on the left.
class ResponsiveScaffold extends StatelessWidget {
  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? drawer;
  final Widget? floatingActionButton;
  final double sidebarWidth;

  const ResponsiveScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.drawer,
    this.floatingActionButton,
    this.sidebarWidth = 280,
  });

  @override
  Widget build(BuildContext context) {
    final wide = Responsive.isWide(context);

    if (wide && drawer != null) {
      return Scaffold(
        appBar: appBar,
        floatingActionButton: floatingActionButton,
        body: Row(
          children: [
            SizedBox(
              width: sidebarWidth,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: drawer!,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      drawer: drawer,
      floatingActionButton: floatingActionButton,
      body: body,
    );
  }
}

/// Constrains content to a max width, centered, for wide screens.
/// On phones, fills the full width.
class ContentConstraint extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  const ContentConstraint({
    super.key,
    required this.child,
    this.maxWidth = 720,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
