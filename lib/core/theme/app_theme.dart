import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Character colors for script display (auto-assigned to characters)
  static const List<Color> characterColors = [
    Color(0xFF64B5F6), // blue
    Color(0xFFE57373), // red
    Color(0xFF81C784), // green
    Color(0xFFFFB74D), // orange
    Color(0xFFBA68C8), // purple
    Color(0xFF4DD0E1), // cyan
    Color(0xFFFF8A65), // deep orange
    Color(0xFFA1887F), // brown
    Color(0xFF90A4AE), // blue grey
    Color(0xFFF06292), // pink
    Color(0xFFAED581), // light green
    Color(0xFF7986CB), // indigo
    Color(0xFFFFD54F), // amber
    Color(0xFF4DB6AC), // teal
    Color(0xFFE0E0E0), // grey
    Color(0xFFCE93D8), // light purple
  ];

  static Color colorForCharacter(int index) {
    return characterColors[index % characterColors.length];
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6C63FF),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6C63FF),
        brightness: Brightness.light,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
