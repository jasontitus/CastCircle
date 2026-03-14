import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'app.dart';
import 'data/database/app_database.dart';
import 'data/services/supabase_service.dart';
import 'data/services/tts_service.dart';
import 'data/services/stt_service.dart';

/// Global database instance, provided via Riverpod.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize sherpa-onnx native bindings
  sherpa.initBindings();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    try {
      await SupabaseService.instance.init(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
      );
    } catch (e) {
      debugPrint('Supabase init failed: $e');
    }
  }

  // Initialize ML services (non-blocking — will use fallbacks if models not ready)
  Future.microtask(() async {
    await TtsService.instance.init();
    await SttService.instance.init();
  });

  runApp(
    const ProviderScope(
      child: LineGuideApp(),
    ),
  );
}
