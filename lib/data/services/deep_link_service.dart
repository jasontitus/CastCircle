import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Data from an incoming invite deep link.
class PendingJoin {
  final String code;
  final String? characterName;
  final String? actorName;

  const PendingJoin({
    required this.code,
    this.characterName,
    this.actorName,
  });

  Map<String, String> toMap() => {
        'code': code,
        if (characterName != null) 'char': characterName!,
        if (actorName != null) 'name': actorName!,
      };

  static PendingJoin? fromUri(Uri uri) {
    // Handle: castcircle://join?code=X&char=Y&name=Z
    if (uri.path != '/join' && uri.host != 'join') return null;
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) return null;
    return PendingJoin(
      code: code.toUpperCase(),
      characterName: uri.queryParameters['char'],
      actorName: uri.queryParameters['name'],
    );
  }

  /// Build a castcircle:// deep link URI.
  static Uri buildUri({
    required String code,
    String? characterName,
    String? actorName,
  }) {
    return Uri(
      scheme: 'castcircle',
      host: 'join',
      queryParameters: {
        'code': code,
        if (characterName != null) 'char': characterName,
        if (actorName != null) 'name': actorName,
      },
    );
  }
}

/// Listens for incoming deep links and exposes them as a stream.
class DeepLinkService {
  DeepLinkService._();
  static final instance = DeepLinkService._();

  final _appLinks = AppLinks();
  final _pendingJoinController = StreamController<PendingJoin>.broadcast();

  Stream<PendingJoin> get onPendingJoin => _pendingJoinController.stream;

  /// The most recent pending join (set on cold start or link arrival).
  PendingJoin? latestPendingJoin;

  Future<void> init() async {
    // Check for initial link (cold start) with a timeout —
    // app_links can hang on some iOS betas.
    try {
      final initialUri = await _appLinks.getInitialLink()
          .timeout(const Duration(seconds: 2));
      if (initialUri != null) {
        _handleUri(initialUri);
      }
    } on TimeoutException {
      debugPrint('Deep link: getInitialLink timed out');
    } catch (e) {
      debugPrint('Deep link: no initial link ($e)');
    }

    // Listen for links while app is running
    try {
      _appLinks.uriLinkStream.listen(
        _handleUri,
        onError: (e) => debugPrint('Deep link error: $e'),
      );
    } catch (e) {
      debugPrint('Deep link: stream listen failed ($e)');
    }
  }

  void _handleUri(Uri uri) {
    debugPrint('Deep link received: $uri');
    final pending = PendingJoin.fromUri(uri);
    if (pending != null) {
      latestPendingJoin = pending;
      _pendingJoinController.add(pending);
    }
  }

  /// Clear the pending join after it has been consumed.
  void clearPending() {
    latestPendingJoin = null;
  }

  void dispose() {
    _pendingJoinController.close();
  }
}
