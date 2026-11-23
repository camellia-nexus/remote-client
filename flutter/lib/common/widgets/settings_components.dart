import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../ui/camellia_design.dart';
import '../../ui/glass_components.dart';

/// Liquid Glass settings primitives shared across Desktop, Mobile, and Web.
///
/// Keeping these primitives in-tree ensures every settings surface shares the
/// same frosted material depth, specular rim, focus ring, and accessibility
/// ergonomics as the rest of Camellia Remote.
class SettingsThemeData {
  const SettingsThemeData({
    required this.settingsListBackground,
    required this.settingsSectionBackground,
    required this.dividerColor,
    required this.tileHighlightColor,
    required this.titleTextColor,
    required this.leadingIconsColor,
    required this.trailingTextColor,
    required this.tileDescriptionTextColor,
    required this.settingsTileTextColor,
    required this.inactiveTitleColor,
    required this.inactiveSubtitleColor,
    required this.inactiveSwitchColor,
    required this.titleTextStyle,
    required this.tileTextStyle,
  });

  factory SettingsThemeData.adaptive(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final accent = isDark ? scheme.secondary : scheme.primary;
    return SettingsThemeData(
      settingsListBackground: Colors.transparent,
      settingsSectionBackground: glass.floatingTint,
      dividerColor: glass.specularBottom.withValues(alpha: isDark ? 0.55 : 0.7),
      tileHighlightColor: accent.withValues(alpha: isDark ? 0.14 : 0.08),
      titleTextColor: accent,
      leadingIconsColor: accent,
      trailingTextColor: scheme.onSurfaceVariant,
      tileDescriptionTextColor: scheme.onSurfaceVariant,
      settingsTileTextColor: scheme.onSurface,
      inactiveTitleColor: tokens.muted.withValues(alpha: 0.62),
      inactiveSubtitleColor: tokens.muted.withValues(alpha: 0.52),
      inactiveSwitchColor: tokens.muted.withValues(alpha: 0.34),
      titleTextStyle:
          Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ) ??
          const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      tileTextStyle:
          Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600) ??
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );
  }

  final Color settingsListBackground;
  final Color settingsSectionBackground;
  final Color dividerColor;
  final Color tileHighlightColor;
  final Color titleTextColor;
  final Color leadingIconsColor;
  final Color trailingTextColor;
  final Color tileDescriptionTextColor;
  final Color settingsTileTextColor;
  final Color inactiveTitleColor;
  final Color inactiveSubtitleColor;
  final Color inactiveSwitchColor;
  final TextStyle titleTextStyle;
  final TextStyle tileTextStyle;
}

class SettingsList extends StatelessWidget {
  const SettingsList({
    super.key,
    required this.sections,
    this.lightTheme,
    this.darkTheme,
    this.contentPadding = const EdgeInsets.fromLTRB(16, 12, 16, 32),
  });

  final List<Widget> sections;
  final SettingsThemeData? lightTheme;
  final SettingsThemeData? darkTheme;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final adaptive = SettingsThemeData.adaptive(context);
    final settingsTheme = Theme.of(context).brightness == Brightness.dark
        ? (darkTheme ?? adaptive)
        : (lightTheme ?? adaptive);
    final list = Scrollbar(
      child: ListView.separated(
        primary: true,
        padding: contentPadding,
        itemCount: sections.length,
        separatorBuilder: (_, _) => const SizedBox(height: 16),
        itemBuilder: (context, index) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: sections[index],
          ),
        ),
      ),
    );
    return _SettingsTheme(
      data: settingsTheme,
      child: settingsTheme.settingsListBackground == Colors.transparent
          ? list
          : ColoredBox(
              color: settingsTheme.settingsListBackground,
              child: list,
            ),
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, this.title, required this.tiles});

  final Widget? title;
  final List<AbstractSettingsTile> tiles;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();
    final settingsTheme = _SettingsTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6, bottom: 9),
            child: DefaultTextStyle.merge(
              style: settingsTheme.titleTextStyle.copyWith(
                color: settingsTheme.titleTextColor,
              ),
              child: title!,
            ),
          ),
        GlassSurface(
          layer: CamelliaGlassLayer.floating,
          tintColor: settingsTheme.settingsSectionBackground,
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                for (var index = 0; index < tiles.length; index++) ...[
                  tiles[index],
                  if (index != tiles.length - 1)
                    Divider(
                      height: 1,
                      thickness: 0.85,
                      indent: 62,
                      endIndent: 12,
                      color: settingsTheme.dividerColor,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class CustomSettingsSection extends StatelessWidget {
  const CustomSettingsSection({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: child);
}

abstract class AbstractSettingsTile extends StatelessWidget {
  const AbstractSettingsTile({super.key});
}

class CustomSettingsTile extends AbstractSettingsTile {
  const CustomSettingsTile({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

typedef SettingsTilePressed = void Function(BuildContext context);

class SettingsTile extends AbstractSettingsTile {
  const SettingsTile({
    super.key,
    required this.title,
    this.description,
    this.leading,
    this.trailing,
    this.value,
    this.onPressed,
    this.enabled = true,
  }) : initialValue = null,
       onToggle = null;

  const SettingsTile.switchTile({
    super.key,
    required this.title,
    required bool this.initialValue,
    required this.onToggle,
    this.description,
    this.leading,
    this.enabled = true,
  }) : trailing = null,
       value = null,
       onPressed = null;

  final Widget title;
  final Widget? description;
  final Widget? leading;
  final Widget? trailing;
  final Widget? value;
  final SettingsTilePressed? onPressed;
  final bool enabled;
  final bool? initialValue;
  final ValueChanged<bool>? onToggle;

  bool get _isSwitch => initialValue != null;

  @override
  Widget build(BuildContext context) {
    final settingsTheme = _SettingsTheme.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final interactive = enabled && (onPressed != null || onToggle != null);
    final titleColor = enabled
        ? settingsTheme.settingsTileTextColor
        : settingsTheme.inactiveTitleColor;
    final subtitleColor = enabled
        ? settingsTheme.tileDescriptionTextColor
        : settingsTheme.inactiveSubtitleColor;
    final iconColor = enabled
        ? settingsTheme.leadingIconsColor
        : settingsTheme.inactiveTitleColor;

    final tile = ListTile(
      enabled: enabled,
      titleAlignment: ListTileTitleAlignment.center,
      minVerticalPadding: 10,
      minTileHeight: 54,
      contentPadding: const EdgeInsetsDirectional.fromSTEB(14, 2, 14, 2),
      leading: leading == null
          ? null
          : Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: isDark ? 0.16 : 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: iconColor, size: 19),
                child: leading!,
              ),
            ),
      title: DefaultTextStyle.merge(
        style: settingsTheme.tileTextStyle.copyWith(color: titleColor),
        child: title,
      ),
      subtitle: description == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 3),
              child: DefaultTextStyle.merge(
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: subtitleColor),
                child: description!,
              ),
            ),
      trailing: _isSwitch
          ? Switch.adaptive(
              value: initialValue!,
              onChanged: enabled
                  ? (v) {
                      HapticFeedback.selectionClick();
                      onToggle?.call(v);
                    }
                  : null,
            )
          : _SettingsTileTrailing(
              value: value,
              trailing: trailing,
              color: settingsTheme.trailingTextColor,
            ),
      onTap: !interactive
          ? null
          : () {
              HapticFeedback.selectionClick();
              if (_isSwitch) {
                onToggle?.call(!initialValue!);
              } else {
                onPressed?.call(context);
              }
            },
      hoverColor: settingsTheme.tileHighlightColor,
      focusColor: settingsTheme.tileHighlightColor,
      splashColor: settingsTheme.tileHighlightColor,
    );

    return Semantics(
      button: interactive && !_isSwitch,
      toggled: _isSwitch ? initialValue : null,
      enabled: enabled,
      child: tile,
    );
  }
}

class _SettingsTileTrailing extends StatelessWidget {
  const _SettingsTileTrailing({
    required this.value,
    required this.trailing,
    required this.color,
  });

  final Widget? value;
  final Widget? trailing;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (value == null && trailing == null) return const SizedBox.shrink();
    return IconTheme.merge(
      data: IconThemeData(color: color, size: 18),
      child: DefaultTextStyle.merge(
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.end,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (value != null)
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: value!,
                ),
              ),
            if (value != null && trailing != null) const SizedBox(width: 8),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _SettingsTheme extends InheritedWidget {
  const _SettingsTheme({required this.data, required super.child});

  final SettingsThemeData data;

  static SettingsThemeData of(BuildContext context) {
    final inherited = context
        .dependOnInheritedWidgetOfExactType<_SettingsTheme>();
    if (inherited != null) return inherited.data;
    return SettingsThemeData.adaptive(context);
  }

  @override
  bool updateShouldNotify(_SettingsTheme oldWidget) => data != oldWidget.data;
}
