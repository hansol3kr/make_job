import 'package:flutter/material.dart';

/// 디자인 시스템 — 신뢰(딥 인디고) + 실시간 에너지(일렉트릭) 톤.
class AppColors {
  static const primary = Color(0xFF2B50E2); // 신뢰·속도
  static const primaryDark = Color(0xFF1B3BB8);
  static const accent = Color(0xFF12B76A); // 확정·성공(GO)
  static const warn = Color(0xFFF79009);
  static const danger = Color(0xFFF04438);
  static const bg = Color(0xFFF6F7F9);
  static const surface = Colors.white;
  static const ink = Color(0xFF101828);
  static const inkSub = Color(0xFF475467);
  static const line = Color(0xFFE4E7EC);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primary,
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      foregroundColor: AppColors.ink,
      titleTextStyle: TextStyle(
        color: AppColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w800,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        side: const BorderSide(color: AppColors.line),
        foregroundColor: AppColors.ink,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    // 40~50대 가독성: 크기 미지정 텍스트의 기본 하한을 올린다(하드코딩 지정분은 화면별 처리).
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 16, height: 1.4, color: AppColors.ink),
      bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: AppColors.ink),
      bodySmall: TextStyle(fontSize: 13, height: 1.4, color: AppColors.inkSub),
    ),
    // 입력 필드: 키 크고(세로 18) 테두리 뚜렷하게, 힌트·라벨 16px — 노안·오조작 대비.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      hintStyle: const TextStyle(fontSize: 16, color: AppColors.inkSub),
      labelStyle: const TextStyle(fontSize: 16, color: AppColors.inkSub),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
      ),
    ),
  );
}
