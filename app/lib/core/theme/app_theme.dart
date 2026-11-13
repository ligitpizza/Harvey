import 'package:flutter/material.dart';

/// Single Material 3 theme shared by all three entrypoints (docs/07 "Visual system").
abstract final class AppTheme {
  static const _seed = Color(0xFF1D6FA3); // clinical blue

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  /// D-84: the staff portal (web): a soft page background, white cards with a light
  /// shadow and border, bolder headings, rounder buttons and filled inputs, hover feedback.
  static ThemeData portalLight() => _portal(Brightness.light);
  static ThemeData portalDark() => _portal(Brightness.dark);

  static ThemeData _portal(Brightness brightness) {
    final base = _build(brightness);
    final scheme = base.colorScheme;
    final light = brightness == Brightness.light;
    final cardColor = light ? Colors.white : scheme.surfaceContainer;
    final border = scheme.outlineVariant.withValues(alpha: light ? 0.55 : 0.4);
    final shape12 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return base.copyWith(
      scaffoldBackgroundColor: light ? const Color(0xFFF2F5FA) : scheme.surface,
      cardTheme: CardThemeData(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: light ? 1.5 : 0,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border),
        ),
      ),
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      listTileTheme: ListTileThemeData(
        shape: shape12,
        iconColor: scheme.primary,
        titleTextStyle: base.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 46),
          shape: shape12,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 46),
          shape: shape12,
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.5)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: shape12,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide(color: border),
        labelStyle: const TextStyle(fontWeight: FontWeight.w500),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(shape12),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: cardColor,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      dividerTheme: DividerThemeData(color: border, space: 1),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(scheme.primaryContainer.withValues(alpha: 0.35)),
        headingTextStyle: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
        dataRowColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ? scheme.primary.withValues(alpha: 0.05) : null,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // NFR-3.1: minimum 48 dp touch targets.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
      ),
      // D-82: form errors wrap instead of being cut off ("Height must be betwee…") and
      // are a little larger and bolder so they stand out.
      inputDecorationTheme: InputDecorationTheme(
        errorMaxLines: 3,
        helperMaxLines: 3,
        errorStyle: TextStyle(
          color: scheme.error,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
    );
  }
}

/// BP category colours (docs/06 §E). Used for all BP/risk badges.
abstract final class BpColors {
  static const normal = Color(0xFF1D9E75);
  static const elevated = Color(0xFFEF9F27);
  static const stage1 = Color(0xFFD85A30);
  static const stage2 = Color(0xFFE24B4A);
  static const crisis = Color(0xFFA32D2D);
}
