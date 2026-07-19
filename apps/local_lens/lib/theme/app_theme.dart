import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

abstract final class AppTheme {
  static const accent = Color(0xFF5B67D8);
  static const accentDark = Color(0xFF929BFF);
  static const lightCanvas = Color(0xFFF5F6F8);
  static const lightSidebar = Color(0xFFFBFBFC);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightBorder = Color(0xFFE4E7EC);
  static const darkCanvas = Color(0xFF0E0F11);
  static const darkSidebar = Color(0xFF131416);
  static const darkSurface = Color(0xFF181A1D);
  static const darkBorder = Color(0xFF2A2D32);

  static const radiusSmall = 8.0;
  static const radius = 12.0;
  static const radiusLarge = 16.0;

  static const _windowsFontFamily = 'Microsoft YaHei UI';
  static const _fontFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Segoe UI',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'PingFang SC',
    'Arial Unicode MS',
  ];

  static ThemeData get light => _materialTheme(Brightness.light);
  static ThemeData get dark => _materialTheme(Brightness.dark);

  static ShadThemeData get shadLight => ShadThemeData(
        brightness: Brightness.light,
        colorScheme: const ShadZincColorScheme.light(),
      );

  static ShadThemeData get shadDark => ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: const ShadZincColorScheme.dark(),
      );

  static ThemeData _materialTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final scheme = ColorScheme.fromSeed(
      seedColor: dark ? accentDark : accent,
      brightness: brightness,
      surface: dark ? darkSurface : lightSurface,
    );
    final border = dark ? darkBorder : lightBorder;
    final canvas = dark ? darkCanvas : lightCanvas;
    final surface = dark ? darkSurface : lightSurface;

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      fontFamily: windows ? _windowsFontFamily : null,
    );
    final textTheme = _localizedTextTheme(base.textTheme, windows: windows);

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: _localizedTextTheme(
        base.primaryTextTheme,
        windows: windows,
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: border),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
          fontFamilyFallback: _fontFallback,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontFamilyFallback: _fontFallback,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 15),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontFamilyFallback: _fontFallback,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 38),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontFamilyFallback: _fontFallback,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(38),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 68,
        backgroundColor: dark ? darkSidebar : lightSidebar,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            fontFamilyFallback: _fontFallback,
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        labelStyle: textTheme.bodyMedium,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: border),
          ),
        ),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFF4F4F5) : const Color(0xFF202124),
          borderRadius: BorderRadius.circular(7),
        ),
        textStyle: TextStyle(
          color: dark ? const Color(0xFF202124) : Colors.white,
          fontSize: 12,
          fontFamilyFallback: _fontFallback,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      ),
    );
  }

  static TextTheme _localizedTextTheme(
    TextTheme source, {
    required bool windows,
  }) {
    TextStyle? style(
      TextStyle? value, {
      FontWeight? weight,
      double? height,
      double? letterSpacing,
    }) {
      return value?.copyWith(
        fontFamily: windows ? _windowsFontFamily : value.fontFamily,
        fontFamilyFallback: _fontFallback,
        fontWeight: weight,
        height: height,
        letterSpacing: letterSpacing,
      );
    }

    return source.copyWith(
      displayLarge: style(source.displayLarge, height: 1.2, letterSpacing: 0),
      displayMedium: style(source.displayMedium, height: 1.2, letterSpacing: 0),
      displaySmall: style(source.displaySmall, height: 1.2, letterSpacing: 0),
      headlineLarge: style(
        source.headlineLarge,
        weight: FontWeight.w700,
        height: 1.25,
        letterSpacing: 0,
      ),
      headlineMedium: style(
        source.headlineMedium,
        weight: FontWeight.w700,
        height: 1.25,
        letterSpacing: 0,
      ),
      headlineSmall: style(
        source.headlineSmall,
        weight: FontWeight.w700,
        height: 1.25,
        letterSpacing: 0,
      ),
      titleLarge: style(
        source.titleLarge,
        weight: FontWeight.w700,
        height: 1.3,
      ),
      titleMedium: style(
        source.titleMedium,
        weight: FontWeight.w600,
        height: 1.3,
      ),
      titleSmall: style(source.titleSmall, height: 1.3),
      bodyLarge: style(source.bodyLarge, height: 1.4),
      bodyMedium: style(source.bodyMedium, height: 1.4),
      bodySmall: style(source.bodySmall, height: 1.4),
      labelLarge: style(
        source.labelLarge,
        weight: FontWeight.w600,
        height: 1.25,
      ),
      labelMedium: style(source.labelMedium, height: 1.25),
      labelSmall: style(source.labelSmall, height: 1.25),
    );
  }
}
