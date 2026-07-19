import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

abstract final class AppTheme {
  static const accent = Color(0xFF4F5FD5);
  static const accentDark = Color(0xFFAAB2FF);
  static const lightCanvas = Color(0xFFF3F5F8);
  static const lightSidebar = Color(0xFFF8F9FB);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightBorder = Color(0xFFDDE2EA);
  static const darkCanvas = Color(0xFF0D0F12);
  static const darkSidebar = Color(0xFF121418);
  static const darkSurface = Color(0xFF171A1F);
  static const darkBorder = Color(0xFF2A2F38);

  static const radiusSmall = 8.0;
  static const radius = 12.0;
  static const radiusLarge = 18.0;

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
    final canvas = dark ? darkCanvas : lightCanvas;
    final sidebar = dark ? darkSidebar : lightSidebar;
    final surface = dark ? darkSurface : lightSurface;
    final border = dark ? darkBorder : lightBorder;
    final scheme = ColorScheme.fromSeed(
      seedColor: dark ? accentDark : accent,
      brightness: brightness,
      surface: surface,
    ).copyWith(
      surfaceContainerLowest: dark ? const Color(0xFF101216) : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF15181D) : const Color(0xFFF9FAFC),
      surfaceContainer: dark ? const Color(0xFF1A1E24) : const Color(0xFFF3F5F8),
      surfaceContainerHigh: dark ? const Color(0xFF20252C) : const Color(0xFFEDF0F4),
      surfaceContainerHighest: dark ? const Color(0xFF272D36) : const Color(0xFFE7EBF1),
      outline: dark ? const Color(0xFF727A87) : const Color(0xFF777F8D),
      outlineVariant: border,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
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
      dividerColor: border,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: canvas,
        foregroundColor: scheme.onSurface,
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
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
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused) ? scheme.primary : border,
            width: states.contains(WidgetState.focused) ? 1.5 : 1,
          ),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14),
        ),
        textStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
        hintStyle: WidgetStatePropertyAll(
          textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant.withValues(alpha: 0.76),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 17),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 70,
        backgroundColor: sidebar,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelMedium?.copyWith(
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: false,
        minVerticalPadding: 9,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        titleTextStyle: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        subtitleTextStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        labelStyle: textTheme.labelMedium,
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
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLarge)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(7),
        radius: const Radius.circular(999),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => scheme.onSurfaceVariant.withValues(
            alpha: states.contains(WidgetState.hovered) ? 0.48 : 0.28,
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 420),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFF3F4F6) : const Color(0xFF20242A),
          borderRadius: BorderRadius.circular(7),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: dark ? const Color(0xFF20242A) : Colors.white,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? const Color(0xFFE9ECF2) : const Color(0xFF252A32),
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: dark ? const Color(0xFF1B1F25) : Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
    );
  }

  static TextTheme _localizedTextTheme(
    TextTheme source, {
    required bool windows,
  }) {
    TextStyle? localize(
      TextStyle? style, {
      FontWeight? weight,
      double? height,
      double? letterSpacing,
    }) {
      return style?.copyWith(
        fontFamily: windows ? _windowsFontFamily : style.fontFamily,
        fontFamilyFallback: _fontFallback,
        fontWeight: weight ?? style.fontWeight,
        height: height ?? 1.38,
        letterSpacing: letterSpacing ?? 0,
      );
    }

    return source.copyWith(
      displayLarge: localize(source.displayLarge, weight: FontWeight.w700),
      displayMedium: localize(source.displayMedium, weight: FontWeight.w700),
      displaySmall: localize(source.displaySmall, weight: FontWeight.w700),
      headlineLarge: localize(source.headlineLarge, weight: FontWeight.w700),
      headlineMedium: localize(source.headlineMedium, weight: FontWeight.w700),
      headlineSmall: localize(source.headlineSmall, weight: FontWeight.w700),
      titleLarge: localize(source.titleLarge, weight: FontWeight.w700),
      titleMedium: localize(source.titleMedium, weight: FontWeight.w600),
      titleSmall: localize(source.titleSmall, weight: FontWeight.w600),
      bodyLarge: localize(source.bodyLarge),
      bodyMedium: localize(source.bodyMedium),
      bodySmall: localize(source.bodySmall, height: 1.42),
      labelLarge: localize(source.labelLarge, weight: FontWeight.w600, height: 1.2),
      labelMedium: localize(source.labelMedium, weight: FontWeight.w600, height: 1.2),
      labelSmall: localize(source.labelSmall, weight: FontWeight.w600, height: 1.2),
    );
  }
}
