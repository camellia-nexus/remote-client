// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../common.dart' show AppDesignTokens, AppVisual;
import 'camellia_design.dart';
import 'glass_components.dart';

enum DeviceCategoryLayout { selector, bar, rail }

/// Returns the horizontal category bar layout across desktop and tablet widths,
/// keeping compact dropdown selector only for ultra-narrow containers.
/// The redundant vertical category rail has been removed in favor of unified
/// horizontal Glass Pill Tabs.
DeviceCategoryLayout deviceCategoryLayoutForWidth(double width) =>
    width < 520 ? DeviceCategoryLayout.selector : DeviceCategoryLayout.bar;

double deviceSearchWidth(double availableWidth, {bool focused = false}) {
  if (availableWidth < 520) return availableWidth;
  final preferred = focused ? 280.0 : 208.0;
  return preferred.clamp(0, availableWidth * 0.52).toDouble();
}

class DeviceOptionMenuItem<T> {
  const DeviceOptionMenuItem({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;
  final IconData icon;
}

class DeviceOptionMenuButton<T> extends StatefulWidget {
  const DeviceOptionMenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.options,
    required this.selectedValue,
    required this.onSelected,
    this.enabled = true,
  });

  final String tooltip;
  final IconData icon;
  final List<DeviceOptionMenuItem<T>> options;
  final T selectedValue;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  State<DeviceOptionMenuButton<T>> createState() =>
      _DeviceOptionMenuButtonState<T>();
}

class _DeviceOptionMenuButtonState<T> extends State<DeviceOptionMenuButton<T>> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final AppDesignTokens tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final activeAccent = dark ? scheme.secondary : scheme.primary;
    final radius = BorderRadius.circular(CamelliaRadius.control);

    return SizedBox.square(
      dimension: 44,
      child: MouseRegion(
        onEnter: (_) {
          if (mounted) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (mounted) setState(() => _hovered = false);
        },
        child: Theme(
          data: theme.copyWith(
            highlightColor: Colors.transparent,
            focusColor: Colors.transparent,
            splashColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
          ),
          child: PopupMenuButton<T>(
            tooltip: widget.tooltip,
            enabled: widget.enabled,
            position: PopupMenuPosition.under,
            borderRadius: radius,
            offset: const Offset(0, 6),
            padding: EdgeInsets.zero,
            color: tokens.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CamelliaRadius.surface),
              side: BorderSide(color: tokens.border, width: 0.85),
            ),
            constraints: const BoxConstraints(minWidth: 184, maxWidth: 224),
            onSelected: widget.onSelected,
            itemBuilder: (context) => [
              for (final option in widget.options)
                PopupMenuItem<T>(
                  value: option.value,
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Semantics(
                    selected: option.value == widget.selectedValue,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: Icon(
                            option.icon,
                            size: 18,
                            color: option.value == widget.selectedValue
                                ? activeAccent
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            option.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: option.value == widget.selectedValue
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 18,
                          child: option.value == widget.selectedValue
                              ? Icon(
                                  CamelliaIcons.check,
                                  size: 18,
                                  color: activeAccent,
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            child: Semantics(
              button: true,
              enabled: widget.enabled,
              label: widget.tooltip,
              excludeSemantics: true,
              child: Center(
                child: AnimatedContainer(
                  duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _hovered && widget.enabled
                        ? Color.alphaBlend(glass.hoverOverlay, glass.floatingTint)
                        : glass.floatingTint,
                    borderRadius: radius,
                    border: Border.all(color: tokens.border, width: 0.85),
                  ),
                  child: Center(
                    child: Icon(
                      widget.icon,
                      size: 19,
                      color: widget.enabled
                          ? scheme.onSurface
                          : scheme.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
