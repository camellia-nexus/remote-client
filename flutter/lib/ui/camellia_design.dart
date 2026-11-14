import 'package:flutter/material.dart';

enum CamelliaLanguage { english, simplifiedChinese, traditionalChinese }

abstract final class CamelliaTypography {
  static const simplifiedFamily = 'CamelliaSansSC';
  static const traditionalFamily = 'CamelliaSansTC';

  static const systemFontFallbacks = <String>[
    'PingFang SC',
    'Microsoft YaHei',
    'Heiti SC',
    'sans-serif',
  ];

  static CamelliaLanguage resolve({
    required String savedLanguage,
    required Locale systemLocale,
  }) {
    final saved = savedLanguage.trim().toLowerCase().replaceAll('_', '-');
    final system = <String>[
      systemLocale.languageCode,
      if (systemLocale.scriptCode != null) systemLocale.scriptCode!,
      if (systemLocale.countryCode != null) systemLocale.countryCode!,
    ].join('-').toLowerCase();
    final candidate = saved.isEmpty || saved == 'default' ? system : saved;
    if (!candidate.startsWith('zh')) return CamelliaLanguage.english;
    if (candidate.contains('hans')) {
      return CamelliaLanguage.simplifiedChinese;
    }
    if (candidate.contains('hant') ||
        candidate.contains('-tw') ||
        candidate.contains('-hk') ||
        candidate.contains('-mo')) {
      return CamelliaLanguage.traditionalChinese;
    }
    return CamelliaLanguage.simplifiedChinese;
  }

  static String family(CamelliaLanguage language) =>
      language == CamelliaLanguage.traditionalChinese
      ? traditionalFamily
      : simplifiedFamily;
}

abstract final class CamelliaColors {
  static const indigo = Color(0xFF6558F5);
  static const indigoStrong = Color(0xFF4338CA);
  static const indigoSoft = Color(0xFFECEAFF);
  static const coral = Color(0xFFFF5C7A);
  static const coralStrong = Color(0xFFD83A5B);
  static const azure = Color(0xFF1B8FFF);
  static const azureStrong = Color(0xFF0068C9);
  static const aqua = Color(0xFF19BFA9);
  static const aquaStrong = Color(0xFF087F73);
  static const orchid = Color(0xFF8C63F7);
  static const sun = Color(0xFFF0A202);
  static const sunStrong = Color(0xFF9A6200);
  static const leaf = Color(0xFF16A36A);

  static const portalBlue = Color(0xFF1BA7FF);
  static const portalIndigo = Color(0xFF6558F5);
  static const portalGlow = Color(0xFFFF5C7A);
  static const portalPlateLight = Color(0xFFF3F5FF);
  static const portalPlateDark = Color(0xFF121522);
  static const portalPlateBorderLight = Color(0xFFD9DDF2);
  static const portalPlateBorderDark = Color(0xFF343951);
  static const portalCutoutLight = Color(0xFFF9FAFF);
  static const portalCutoutDark = Color(0xFF0B0D15);

  static const lightCanvas = Color(0xFFF4F7FC);
  static const lightSurface = Color(0xFFFCFDFF);
  static const lightInset = Color(0xFFEDF3FB);
  static const lightRaised = Color(0xFFFFFFFF);
  static const lightBorder = Color(0xFFD6DFEC);
  static const lightText = Color(0xFF172033);
  static const lightMuted = Color(0xFF617087);

  static const darkCanvas = Color(0xFF090F1D);
  static const darkSurface = Color(0xFF111A2B);
  static const darkInset = Color(0xFF18243A);
  static const darkRaised = Color(0xFF202E47);
  static const darkBorder = Color(0xFF30405C);
  static const darkText = Color(0xFFEDF4FF);
  static const darkMuted = Color(0xFF9AAAC2);

  static const lightAccentWash = indigoSoft;
  static const darkAccentWash = Color(0xFF29264F);
}

abstract final class CamelliaSpace {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

abstract final class CamelliaRadius {
  static const control = 10.0;
  static const surface = 14.0;
  static const sheet = 18.0;
  static const status = 999.0;
}

abstract final class CamelliaMotion {
  static const hover = Duration(milliseconds: 120);
  static const feedback = Duration(milliseconds: 160);
  static const state = Duration(milliseconds: 200);
  static const content = Duration(milliseconds: 220);
  static const modal = Duration(milliseconds: 260);
  static const route = Duration(milliseconds: 280);
  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;
  static const standard = Curves.easeInOutCubic;
}

abstract final class CamelliaTheme {
  static ThemeData build({
    required Brightness brightness,
    required bool desktopDensity,
    String fontFamily = CamelliaTypography.simplifiedFamily,
    List<String> fontFamilyFallback = CamelliaTypography.systemFontFallbacks,
    List<ThemeExtension<dynamic>> extensions = const [],
  }) {
    final dark = brightness == Brightness.dark;
    final canvas = dark
        ? CamelliaColors.darkCanvas
        : CamelliaColors.lightCanvas;
    final surface = dark
        ? CamelliaColors.darkSurface
        : CamelliaColors.lightSurface;
    final inset = dark ? CamelliaColors.darkInset : CamelliaColors.lightInset;
    final raised = dark
        ? CamelliaColors.darkRaised
        : CamelliaColors.lightRaised;
    final border = dark
        ? CamelliaColors.darkBorder
        : CamelliaColors.lightBorder;
    final text = dark ? CamelliaColors.darkText : CamelliaColors.lightText;
    final muted = dark ? CamelliaColors.darkMuted : CamelliaColors.lightMuted;
    final primary = dark ? const Color(0xFFAAA7FF) : CamelliaColors.indigo;
    final primaryContainer = dark
        ? CamelliaColors.darkAccentWash
        : CamelliaColors.lightAccentWash;
    final onPrimaryContainer = dark
        ? const Color(0xFFE4E2FF)
        : const Color(0xFF292274);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: CamelliaColors.indigo,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: Colors.white,
          primaryContainer: primaryContainer,
          onPrimaryContainer: onPrimaryContainer,
          secondary: dark
              ? const Color(0xFF77C7FF)
              : CamelliaColors.indigoStrong,
          onSecondary: dark ? const Color(0xFF211B66) : Colors.white,
          secondaryContainer: dark
              ? const Color(0xFF302C63)
              : const Color(0xFFEDEBFF),
          tertiary: dark ? const Color(0xFF67DDCE) : CamelliaColors.aquaStrong,
          tertiaryContainer: dark
              ? const Color(0xFF30343C)
              : const Color(0xFFE9EBEF),
          surface: surface,
          onSurface: text,
          surfaceContainerLowest: canvas,
          surfaceContainerLow: surface,
          surfaceContainer: inset,
          surfaceContainerHigh: raised,
          surfaceContainerHighest: raised,
          onSurfaceVariant: muted,
          outline: border,
          outlineVariant: border.withValues(alpha: dark ? 0.72 : 0.82),
          error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
          onError: Colors.white,
        );
    TextStyle style(
      double size,
      FontWeight weight, {
      double height = 1.35,
      double tracking = 0,
      Color? color,
    }) => TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
      color: color ?? text,
      letterSpacing: tracking,
    );
    // Apple-inspired scale: bold-but-not-heavy titles with tightened tracking,
    // regular body text with generous line height.
    final textTheme = TextTheme(
      displaySmall: style(32, FontWeight.w700, height: 1.12, tracking: -0.5),
      headlineMedium: style(28, FontWeight.w700, height: 1.18, tracking: -0.4),
      headlineSmall: style(24, FontWeight.w700, height: 1.2, tracking: -0.3),
      titleLarge: style(20, FontWeight.w700, height: 1.24, tracking: -0.2),
      titleMedium: style(16, FontWeight.w600, height: 1.3, tracking: -0.1),
      titleSmall: style(14, FontWeight.w600),
      bodyLarge: style(16, FontWeight.w400, height: 1.45),
      bodyMedium: style(14, FontWeight.w400, height: 1.42),
      bodySmall: style(12, FontWeight.w400, height: 1.4, color: muted),
      labelLarge: style(14, FontWeight.w600, height: 1.2),
      labelMedium: style(12, FontWeight.w600, height: 1.2),
      labelSmall: style(11, FontWeight.w600, height: 1.2, color: muted),
    );
    final controlHeight = desktopDensity ? 44.0 : 48.0;
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(CamelliaRadius.control),
    );
    final surfaceShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(CamelliaRadius.surface),
      side: BorderSide(color: border),
    );
    final buttonPadding = EdgeInsets.symmetric(
      horizontal: desktopDensity ? 16 : 18,
      vertical: desktopDensity ? 10 : 12,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      cardColor: surface,
      dividerColor: border,
      disabledColor: muted.withValues(alpha: 0.45),
      focusColor: CamelliaColors.azure.withValues(alpha: dark ? 0.28 : 0.18),
      hoverColor: primaryContainer.withValues(alpha: dark ? 0.72 : 0.64),
      highlightColor: primary.withValues(alpha: 0.10),
      splashColor: primary.withValues(alpha: 0.12),
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: muted, size: 21),
      primaryIconTheme: IconThemeData(color: primary, size: 21),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: !desktopDensity,
        backgroundColor: Colors.transparent,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: desktopDensity ? 64 : 64,
        titleTextStyle: textTheme.titleMedium,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inset,
        isDense: false,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: desktopDensity ? 12 : 14,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(color: muted),
        labelStyle: textTheme.bodyMedium?.copyWith(color: muted),
        floatingLabelStyle: textTheme.labelMedium?.copyWith(color: primary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          borderSide: BorderSide(
            color: dark ? const Color(0xFF5FA8DE) : CamelliaColors.azure,
            width: 1.6,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, controlHeight)),
          padding: WidgetStatePropertyAll(buttonPadding),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: WidgetStatePropertyAll(controlShape),
          elevation: const WidgetStatePropertyAll(0),
          animationDuration: CamelliaMotion.feedback,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: Size(0, controlHeight),
          padding: buttonPadding,
          backgroundColor: primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: inset,
          disabledForegroundColor: muted,
          elevation: 0,
          shape: controlShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: Size(0, controlHeight),
          padding: buttonPadding,
          foregroundColor: text,
          backgroundColor: surface,
          side: BorderSide(color: border),
          shape: controlShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: Size(0, controlHeight),
          padding: buttonPadding,
          foregroundColor: primary,
          shape: controlShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: Size.square(controlHeight),
          foregroundColor: muted,
          hoverColor: primaryContainer,
          highlightColor: primary.withValues(alpha: 0.10),
          shape: controlShape,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, controlHeight)),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return primaryContainer;
            return surface;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return onPrimaryContainer;
            }
            return muted;
          }),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(textTheme.labelMedium),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return muted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return inset;
        }),
        trackOutlineColor: WidgetStatePropertyAll(border),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? primary : surface;
        }),
        side: BorderSide(color: border, width: 1.2),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? primary : muted;
        }),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: surfaceShape,
      ),
      dialogTheme: DialogThemeData(
        elevation: 24,
        backgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.48 : 0.18),
        shape: surfaceShape,
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        elevation: 18,
        backgroundColor: raised,
        modalBackgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: border,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(CamelliaRadius.sheet),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        elevation: 12,
        color: raised,
        surfaceTintColor: Colors.transparent,
        textStyle: textTheme.bodyMedium,
        shape: surfaceShape,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(12),
          backgroundColor: WidgetStatePropertyAll(raised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(surfaceShape),
        ),
      ),
      menuBarTheme: MenuBarThemeData(
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(10),
          backgroundColor: WidgetStatePropertyAll(raised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(
            Colors.black.withValues(alpha: dark ? 0.42 : 0.16),
          ),
          shape: WidgetStatePropertyAll(surfaceShape),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: desktopDensity
            ? const Duration(milliseconds: 450)
            : Duration.zero,
        showDuration: const Duration(seconds: 2),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFE7EEFB) : const Color(0xFF111A2B),
          borderRadius: BorderRadius.circular(5),
        ),
        textStyle: style(12, FontWeight.w500, color: Colors.white),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: states.contains(WidgetState.selected) ? 24 : 22,
            color: states.contains(WidgetState.selected) ? primary : muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => style(
            11,
            states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? text : muted,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        elevation: 0,
        backgroundColor: surface,
        indicatorColor: primaryContainer,
        selectedIconTheme: IconThemeData(color: primary, size: 23),
        unselectedIconTheme: IconThemeData(color: muted, size: 21),
        selectedLabelTextStyle: style(12, FontWeight.w700, color: text),
        unselectedLabelTextStyle: style(12, FontWeight.w500, color: muted),
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: border,
        indicatorColor: primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: text,
        unselectedLabelColor: muted,
        labelStyle: textTheme.labelLarge,
        unselectedLabelStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: false,
        minTileHeight: desktopDensity ? 48 : 56,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        iconColor: muted,
        textColor: text,
        shape: controlShape,
        selectedColor: text,
        selectedTileColor: primaryContainer,
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: border),
        shape: const StadiumBorder(),
        backgroundColor: inset,
        selectedColor: primaryContainer,
        labelStyle: textTheme.labelMedium!,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: inset,
        circularTrackColor: inset,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 12,
        backgroundColor: dark ? raised : CamelliaColors.lightText,
        contentTextStyle: style(14, FontWeight.w500, color: Colors.white),
        actionTextColor: dark
            ? const Color(0xFFC5C2FF)
            : const Color(0xFFD8D5FF),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStatePropertyAll(desktopDensity ? 6 : 4),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.dragged)) return primary;
          if (states.contains(WidgetState.hovered)) return muted;
          return muted.withValues(alpha: 0.55);
        }),
      ),
      extensions: extensions,
    );
  }
}

class CamelliaBackdrop extends StatelessWidget {
  const CamelliaBackdrop({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.scaffoldBackgroundColor,
            Color.alphaBlend(
              (dark ? CamelliaColors.indigo : CamelliaColors.azure).withValues(
                alpha: dark ? 0.16 : 0.065,
              ),
              theme.scaffoldBackgroundColor,
            ),
            Color.alphaBlend(
              (dark ? CamelliaColors.azure : CamelliaColors.indigo).withValues(
                alpha: dark ? 0.10 : 0.04,
              ),
              theme.scaffoldBackgroundColor,
            ),
            if (dark)
              Color.alphaBlend(
                CamelliaColors.aqua.withValues(alpha: 0.045),
                theme.scaffoldBackgroundColor,
              ),
          ],
          stops: dark ? const [0, 0.36, 0.72, 1] : const [0, 0.5, 1],
        ),
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
  }
}

class CamelliaPageHeader extends StatelessWidget {
  const CamelliaPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(width: 16),
          Wrap(spacing: 8, children: actions),
        ],
      ],
    );
  }
}

class CamelliaSection extends StatelessWidget {
  const CamelliaSection({
    super.key,
    required this.child,
    this.title,
    this.description,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.accent,
  });

  final Widget child;
  final String? title;
  final String? description;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final border = theme.colorScheme.outlineVariant;
    return Padding(
      padding: margin,
      child: Material(
        color: theme.colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: theme.brightness == Brightness.dark ? 2 : 0,
        shadowColor: Colors.black.withValues(alpha: 0.34),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null || description != null || trailing != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // A Row measures non-flex children with an unbounded main
                    // axis. Bound the shared trailing slot before layouts such
                    // as OnlineStatusWidget introduce their own Flexible rows.
                    final availableWidth = constraints.hasBoundedWidth
                        ? constraints.maxWidth
                        : MediaQuery.sizeOf(context).width;
                    final trailingMaxWidth =
                        availableWidth.isFinite && availableWidth > 0
                        ? availableWidth / 2
                        : 0.0;
                    return Row(
                      children: [
                        if (accent != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: Container(
                              width: 3.5,
                              height: 18,
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(
                                  CamelliaRadius.status,
                                ),
                              ),
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (title != null)
                                Text(
                                  title!,
                                  style: theme.textTheme.titleMedium,
                                ),
                              if (description != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  description!,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (trailing != null)
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: trailingMaxWidth,
                            ),
                            child: trailing!,
                          ),
                      ],
                    );
                  },
                ),
              ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

class CamelliaStatusDot extends StatelessWidget {
  const CamelliaStatusDot({super.key, required this.color, this.size = 10});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.surface,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.28), blurRadius: 5),
          ],
        ),
      ),
    );
  }
}
