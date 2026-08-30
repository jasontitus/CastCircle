import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';

import '../../main.dart' show rootScaffoldMessengerKey;
import 'debug_log_service.dart';
import '../../core/toast.dart';

/// Data from an incoming invite deep link.
class PendingJoin {
  final String code;
  final String? characterName;
  final String? actorName;

  const PendingJoin({required this.code, this.characterName, this.actorName});

  /// Join codes are always six uppercase alphanumerics (see
  /// SupabaseService.generateJoinCode) — anything else is a malformed or
  /// hostile link, not a code the server could ever match.
  static final _codePattern = RegExp(r'^[A-Z0-9]{6}$');

  /// Longest character/actor name accepted from a link. Real names are far
  /// shorter; the cap stops a link from filling the screen with text.
  static const _maxNameLength = 60;

  /// Control, bidi-override and zero-width characters, which let link text
  /// masquerade as app chrome (line breaks, reversed text, invisible padding).
  static final _unsafeChars = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u200B-\u200F\u2028\u2029\u202A-\u202E'
    r'\u2066-\u2069\uFEFF]',
  );

  Map<String, String> toMap() => {
    'code': code,
    if (characterName != null) 'char': characterName!,
    if (actorName != null) 'name': actorName!,
  };

  static PendingJoin? fromUri(Uri uri) {
    // Handle: castcircle://join?code=X&char=Y&name=Z
    if (uri.path != '/join' && uri.host != 'join') return null;
    final code = uri.queryParameters['code']?.trim().toUpperCase();
    if (code == null || !_codePattern.hasMatch(code)) return null;
    return PendingJoin(
      code: code,
      characterName: _sanitizeName(uri.queryParameters['char']),
      actorName: _sanitizeName(uri.queryParameters['name']),
    );
  }

  /// Link-supplied names are rendered verbatim in trusted app chrome (right
  /// next to the green "Production found!"), so an unfiltered value could plant
  /// a convincing "Session expired — re-enter your password". Strip anything
  /// that isn't plain single-line text and cap the length.
  static String? _sanitizeName(String? raw) {
    if (raw == null) return null;
    final cleaned = raw
        .replaceAll(_unsafeChars, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length > _maxNameLength
        ? cleaned.substring(0, _maxNameLength)
        : cleaned;
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
  final List<int> _correlationSalt = List<int>.generate(
    32,
    (_) => Random.secure().nextInt(256),
  );

  Stream<PendingJoin> get onPendingJoin => _pendingJoinController.stream;

  /// The most recent pending join (set on cold start or link arrival).
  PendingJoin? latestPendingJoin;

  Future<void> init() async {
    // Check for initial link (cold start) with a timeout —
    // app_links can hang on some iOS betas.
    try {
      final initialUri = await _appLinks.getInitialLink().timeout(
        const Duration(seconds: 2),
      );
      if (initialUri != null) {
        _handleUri(initialUri);
      }
    } on TimeoutException catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Deep link initial lookup failed type=timeout',
        e,
        stack,
      );
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Deep link initial lookup failed type=${e.runtimeType}',
        null,
        stack,
      );
    }

    // Listen for links while app is running
    try {
      _appLinks.uriLinkStream.listen(
        _handleUri,
        onError: (Object error, StackTrace stack) =>
            DebugLogService.instance.logError(
              LogCategory.general,
              'Deep link stream failed type=${error.runtimeType}',
              null,
              stack,
            ),
      );
    } catch (error, stack) {
      // Invites tapped from now on will do nothing for the whole session.
      DebugLogService.instance.logError(
        LogCategory.general,
        'Deep link stream listen failed type=${error.runtimeType}',
        null,
        stack,
      );
    }
  }

  void _handleUri(Uri uri) {
    final route = uri.path == '/join' || uri.host == 'join'
        ? '/join'
        : '/other';
    final correlation = crypto.sha256
        .convert([..._correlationSalt, ...utf8.encode(uri.toString())])
        .toString()
        .substring(0, 12);
    DebugLogService.instance.log(
      LogCategory.general,
      'Deep link received scheme=${uri.scheme} route=$route '
      'hasCode=${uri.queryParameters.containsKey('code')} '
      'hasCharacter=${uri.queryParameters.containsKey('char')} '
      'hasActor=${uri.queryParameters.containsKey('name')} '
      'correlation=$correlation',
    );
    final pending = PendingJoin.fromUri(uri);
    if (pending != null) {
      latestPendingJoin = pending;
      _pendingJoinController.add(pending);
      return;
    }
    // A /join link we refused (bad or missing code) would otherwise open the
    // app and do nothing at all, which reads as "the invite is broken".
    if (uri.path == '/join' || uri.host == 'join') {
      // Log the shape of the link, not its raw text: the debug log is
      // line-based, and a link is free to contain newlines.
      final rawCode = uri.queryParameters['code'] ?? '';
      DebugLogService.instance.logError(
        LogCategory.general,
        'Deep link rejected — invalid join code (${rawCode.length} chars) '
        'scheme=${uri.scheme} route=/join',
      );
      // On a cold start there is no messenger yet; the log above is then the
      // only record, and the join screen still lets them type the code.
      rootScaffoldMessengerKey.currentState?.showAutoToast(
        const SnackBar(
          content: Text(
            "That invite link isn't valid — ask your director for "
            'the 6-character join code.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
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
