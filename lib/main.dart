import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/database/app_database.dart';
import 'data/services/supabase_service.dart';

/// Global database instance, provided via Riverpod.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

/// SharedPreferences instance, initialized before runApp.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('Must be overridden in ProviderScope');
});

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    await SupabaseService.instance.init(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  }

  final prefs = await SharedPreferences.getInstance();

  // Determine if user already has a persisted session (Supabase login or
  // previously skipped auth). This lets the app skip the login screen on
  // subsequent launches — users only need to authenticate once per device.
  final hasPersistedSession =
      (SupabaseService.instance.isInitialized &&
          SupabaseService.instance.isSignedIn) ||
      (prefs.getBool('auth_skipped') ?? false);

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (hasPersistedSession)
          authGatePassedProvider.overrideWith((ref) => true),
      ],
      child: const LineGuideApp(),
    ),
  );
}
