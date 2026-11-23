import 'dart:math' as math;
import 'dart:ui';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common.dart' show translate;
import 'camellia_design.dart';

/// Paints a physical top-lit specular edge highlight (bright top refraction fading
/// to a softer bottom edge) around rounded glass surfaces.
class SpecularEdgePainter extends CustomPainter {
  const SpecularEdgePainter({
    required this.borderRadius,
    required this.topColor,
    required this.bottomColor,
    this.strokeWidth = 0.9,
  });

  final BorderRadius borderRadius;
  final Color topColor;
  final Color bottomColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strokeWidth <= 0.0) return;
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect).deflate(strokeWidth / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          topColor,
          Color.lerp(topColor, bottomColor, 0.55)!,
          bottomColor,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant SpecularEdgePainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.topColor != topColor ||
      oldDelegate.bottomColor != bottomColor ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// GPU-isolated Soft Frosted Glass container with multi-tier depth, specular
/// top-lit highlight rim, and diffused ambient shadow.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.layer = CamelliaGlassLayer.floating,
    this.borderRadius,
    this.padding,
    this.margin,
    this.tintColor,
    this.blurSigma,
    this.elevated = false,
    this.showShadow = true,
    this.enableBlur = true,
    this.borderTopColor,
    this.borderBottomColor,
    this.strokeWidth = 0.9,
  });

  final Widget child;
  final CamelliaGlassLayer layer;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? tintColor;
  final double? blurSigma;
  final bool elevated;
  final bool showShadow;
  final bool enableBlur;
  final Color? borderTopColor;
  final Color? borderBottomColor;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final glass = CamelliaGlassTokens.of(context);
    final radius =
        borderRadius ?? BorderRadius.circular(CamelliaRadius.surface);
    final tint = tintColor ?? glass.tintFor(layer);
    final sigma = enableBlur ? (blurSigma ?? glass.blurFor(layer)) : 0.0;
    final shadowColor = elevated ? glass.elevatedShadow : glass.ambientShadow;

    Widget surfaceBody = DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: radius,
      ),
      child: CustomPaint(
        foregroundPainter: SpecularEdgePainter(
          borderRadius: radius,
          topColor: borderTopColor ?? glass.specularTop,
          bottomColor: borderBottomColor ?? glass.specularBottom,
          strokeWidth: strokeWidth,
        ),
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ),
    );

    if (sigma > 0) {
      surfaceBody = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: surfaceBody,
        ),
      );
    } else {
      surfaceBody = ClipRRect(borderRadius: radius, child: surfaceBody);
    }

    if (showShadow) {
      surfaceBody = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: elevated ? 28 : 14,
              spreadRadius: elevated ? -2 : -1,
              offset: Offset(0, elevated ? 10 : 4),
            ),
            BoxShadow(
              color: shadowColor.withValues(alpha: shadowColor.a * 0.45),
              blurRadius: elevated ? 8 : 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: surfaceBody,
      );
    }

    final isolated = RepaintBoundary(child: surfaceBody);
    if (margin != null) {
      return Padding(padding: margin!, child: isolated);
    }
    return isolated;
  }
}

/// Convenience card built on [GlassSurface] with optional header and accent bar.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.accent,
    this.layer = CamelliaGlassLayer.floating,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.borderRadius,
    this.elevated = false,
    this.enableBlur = true,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Color? accent;
  final CamelliaGlassLayer layer;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius? borderRadius;
  final bool elevated;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasHeader =
        title != null || subtitle != null || leading != null || trailing != null;

    final Widget body;
    if (!hasHeader) {
      body = padding == EdgeInsets.zero
          ? child
          : Padding(padding: padding, child: child);
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (accent != null) ...[
                  Container(
                    width: 3.5,
                    height: 18,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.pill,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                if (leading != null) ...[leading!, const SizedBox(width: 10)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (title != null)
                        Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
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
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ],
              ],
            ),
          ),
          padding == EdgeInsets.zero
              ? child
              : Padding(padding: padding, child: child),
        ],
      );
    }

    return GlassSurface(
      layer: layer,
      margin: margin,
      borderRadius: borderRadius,
      elevated: elevated,
      enableBlur: enableBlur,
      child: body,
    );
  }
}

/// Visual prominence variant for [GlassButton].
enum GlassButtonVariant { primary, secondary, subtle, ghost, danger }

/// Full 6-state interactive button (Default, Hover, Pressed with spring scale &
/// haptic feedback, Focused keyboard glow ring, Loading/Busy spinner, Disabled
/// with Tooltip reason).
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.variant = GlassButtonVariant.secondary,
    this.loading = false,
    this.disabledTooltip,
    this.tooltip,
    this.padding,
    this.minHeight,
    this.borderRadius,
    this.enableHaptics = true,
    this.expand = false,
    this.focusNode,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final GlassButtonVariant variant;
  final bool loading;
  final String? disabledTooltip;
  final String? tooltip;
  final EdgeInsetsGeometry? padding;
  final double? minHeight;
  final BorderRadius? borderRadius;
  final bool enableHaptics;
  final bool expand;
  final FocusNode? focusNode;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null && !widget.loading;

  void _handleTap() {
    if (!_enabled) return;
    if (widget.enableHaptics) {
      HapticFeedback.lightImpact();
    }
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final radius =
        widget.borderRadius ?? BorderRadius.circular(CamelliaRadius.control);
    final reduceMotion = CamelliaMotion.reduceMotion(context);
    final height = widget.minHeight ?? 44.0;

    Color bgColor;
    Color fgColor;
    switch (widget.variant) {
      case GlassButtonVariant.primary:
        if (glass.themeStyle == CamelliaThemeStyle.obsidianCyber) {
          bgColor = dark ? const Color(0xFF10B981) : const Color(0xFF059669);
        } else if (glass.themeStyle == CamelliaThemeStyle.nordicTitanium) {
          bgColor = dark ? const Color(0xFFF59E0B) : const Color(0xFFB45309);
        } else {
          bgColor = theme.colorScheme.primary;
        }
        fgColor = Colors.white;
      case GlassButtonVariant.danger:
        // Ensure >= 4.7:1 WCAG AA contrast with white ink across all 3 themes.
        bgColor = dark ? CamelliaColors.statusAlertLight : glass.statusAlert;
        fgColor = Colors.white;
      case GlassButtonVariant.subtle:
      case GlassButtonVariant.ghost:
        bgColor = _hovered && _enabled
            ? glass.hoverOverlay
            : Colors.transparent;
        fgColor = theme.colorScheme.onSurface;
      case GlassButtonVariant.secondary:
        if (glass.themeStyle == CamelliaThemeStyle.obsidianCyber) {
          bgColor = dark ? const Color(0xD00D1522) : const Color(0xE0E2E8F0);
          fgColor = dark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
        } else if (glass.themeStyle == CamelliaThemeStyle.nordicTitanium) {
          bgColor = dark ? const Color(0xD0202026) : const Color(0xE0EDE9E3);
          fgColor = dark ? const Color(0xFFFAF7F2) : const Color(0xFF1C1917);
        } else {
          bgColor = glass.floatingTint;
          fgColor = theme.colorScheme.onSurface;
        }
    }

    if (_hovered && _enabled) {
      if (widget.variant == GlassButtonVariant.primary ||
          widget.variant == GlassButtonVariant.danger) {
        bgColor = Color.alphaBlend(
          Colors.white.withValues(alpha: dark ? 0.12 : 0.10),
          bgColor,
        );
      } else if (widget.variant == GlassButtonVariant.secondary) {
        bgColor = Color.alphaBlend(glass.hoverOverlay, bgColor);
      }
    }

    if (_pressed && _enabled) {
      bgColor = Color.alphaBlend(
        dark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.06),
        bgColor,
      );
    }

    final opacity = _enabled || widget.loading ? 1.0 : 0.46;
    final scale = (!_enabled || reduceMotion)
        ? 1.0
        : _pressed
        ? 0.96
        : (_hovered ? 1.01 : 1.0);

    Widget content = AnimatedOpacity(
      duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
      opacity: opacity,
      child: AnimatedScale(
        scale: scale,
        duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
        curve: CamelliaMotion.springSnappy,
        child: AnimatedContainer(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
          curve: CamelliaMotion.standard,
          constraints: BoxConstraints(
            minHeight: height,
            minWidth: widget.expand ? double.infinity : 0,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: radius,
            boxShadow: [
              if (_focused &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional)
                BoxShadow(
                  color: glass.focusGlow.withValues(alpha: dark ? 0.35 : 0.25),
                  blurRadius: 8,
                  spreadRadius: 0.5,
                ),
              if (widget.variant == GlassButtonVariant.primary && _enabled)
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(
                    alpha: _hovered ? 0.34 : 0.22,
                  ),
                  blurRadius: _hovered ? 16 : 10,
                  offset: Offset(0, _hovered ? 5 : 3),
                ),
              if (widget.variant == GlassButtonVariant.danger && _enabled)
                BoxShadow(
                  color: CamelliaColors.statusAlertLight.withValues(
                    alpha: _hovered ? 0.32 : 0.20,
                  ),
                  blurRadius: _hovered ? 14 : 8,
                  offset: Offset(0, _hovered ? 4 : 2),
                ),
            ],
          ),
          child: CustomPaint(
            foregroundPainter: SpecularEdgePainter(
              borderRadius: radius,
              topColor: Colors.transparent,
              bottomColor: Colors.transparent,
              strokeWidth: 0.0,
            ),
            child: Padding(
              padding:
                  widget.padding ??
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: IconTheme(
                data: IconThemeData(color: fgColor, size: 18),
                child: DefaultTextStyle(
                  style: (theme.textTheme.labelLarge ?? const TextStyle())
                      .copyWith(color: fgColor, fontWeight: FontWeight.w600),
                  child: Row(
                    mainAxisSize: widget.expand
                        ? MainAxisSize.max
                        : MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.loading) ...[
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(fgColor),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ] else if (widget.icon != null) ...[
                        widget.icon!,
                        const SizedBox(width: 8),
                      ],
                      Flexible(child: widget.child),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    content = FocusableActionDetector(
      focusNode: widget.focusNode,
      enabled: _enabled,
      mouseCursor: _enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      onShowHoverHighlight: (v) {
        if (mounted) setState(() => _hovered = v);
      },
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _handleTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled
            ? (_) => setState(() {
                _pressed = true;
                _focused = false;
              })
            : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: _enabled ? _handleTap : null,
        child: Semantics(
          button: true,
          enabled: _enabled,
          child: content,
        ),
      ),
    );

    final tip = !_enabled
        ? (widget.disabledTooltip ?? widget.tooltip)
        : widget.tooltip;
    if (tip != null && tip.isNotEmpty) {
      return Tooltip(message: tip, child: content);
    }
    return content;
  }
}

/// Compact 6-state glass icon button with spring scale & haptic feedback.
class GlassIconButton extends StatefulWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 40,
    this.iconSize = 20,
    this.selected = false,
    this.loading = false,
    this.accentColor,
    this.enableHaptics = true,
    this.focusNode,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;
  final bool selected;
  final bool loading;
  final Color? accentColor;
  final bool enableHaptics;
  final FocusNode? focusNode;

  @override
  State<GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<GlassIconButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent =
        widget.accentColor ??
        (dark ? theme.colorScheme.secondary : theme.colorScheme.primary);
    final radius = BorderRadius.circular(widget.size / 2);
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    final bg = widget.selected
        ? accent.withValues(alpha: dark ? 0.22 : 0.16)
        : (_hovered && _enabled ? glass.hoverOverlay : glass.floatingTint);
    final fg = widget.selected
        ? accent
        : (_enabled
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurface.withValues(alpha: 0.38));

    Widget button = FocusableActionDetector(
      focusNode: widget.focusNode,
      enabled: _enabled,
      mouseCursor: _enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      onShowHoverHighlight: (v) {
        if (mounted) setState(() => _hovered = v);
      },
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (_enabled) {
              if (widget.enableHaptics) HapticFeedback.selectionClick();
              widget.onPressed?.call();
            }
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled
            ? (_) => setState(() {
                _pressed = true;
                _focused = false;
              })
            : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: _enabled
            ? () {
                if (widget.enableHaptics) HapticFeedback.selectionClick();
                widget.onPressed?.call();
              }
            : null,
        child: AnimatedScale(
          scale: (!_enabled || reduceMotion)
              ? 1.0
              : (_pressed ? 0.94 : 1.0),
          duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
          curve: CamelliaMotion.springSnappy,
          child: AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              boxShadow: (_focused &&
                      FocusManager.instance.highlightMode ==
                          FocusHighlightMode.traditional)
                  ? [
                      BoxShadow(
                        color: glass.focusGlow.withValues(alpha: dark ? 0.35 : 0.25),
                        blurRadius: 8,
                        spreadRadius: 0.5,
                      ),
                    ]
                  : const [],
            ),
            child: CustomPaint(
              foregroundPainter: SpecularEdgePainter(
                borderRadius: radius,
                topColor: widget.selected
                    ? accent.withValues(alpha: 0.45)
                    : glass.specularTop,
                bottomColor: widget.selected
                    ? accent.withValues(alpha: 0.22)
                    : glass.specularBottom,
                strokeWidth: 0.0,
              ),
              child: Center(
                child: widget.loading
                    ? SizedBox(
                        width: widget.iconSize,
                        height: widget.iconSize,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.0,
                          valueColor: AlwaysStoppedAnimation<Color>(fg),
                        ),
                      )
                    : Icon(widget.icon, size: widget.iconSize, color: fg),
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return Semantics(button: true, enabled: _enabled, child: button);
  }
}

/// Controller for triggering a horizontal error shake on auth/password fields.
class GlassShakeController extends ChangeNotifier {
  int _triggerCount = 0;
  int get triggerCount => _triggerCount;

  void shake() {
    _triggerCount++;
    HapticFeedback.heavyImpact();
    notifyListeners();
  }
}

/// Wraps a child (such as a password input) and performs a crisp horizontal
/// damped oscillation when [controller.shake()] is invoked.
class GlassShakeBox extends StatefulWidget {
  const GlassShakeBox({
    super.key,
    required this.controller,
    required this.child,
    this.amplitude = 9.0,
  });

  final GlassShakeController controller;
  final Widget child;
  final double amplitude;

  @override
  State<GlassShakeBox> createState() => _GlassShakeBoxState();
}

class _GlassShakeBoxState extends State<GlassShakeBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    widget.controller.addListener(_onShake);
  }

  void _onShake() {
    if (!mounted) return;
    if (CamelliaMotion.reduceMotion(context)) return;
    _anim.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant GlassShakeBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onShake);
      widget.controller.addListener(_onShake);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onShake);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final t = _anim.value;
        final decay = 1.0 - t;
        final dx = math.sin(t * math.pi * 6) * widget.amplitude * decay;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: widget.child,
    );
  }
}

/// Compact frosted telemetry pill using tabular numerals (`tabular-nums`) for
/// zero-jitter latency, FPS, bitrate, or connection state readout.
class TelemetryPill extends StatelessWidget {
  const TelemetryPill({
    super.key,
    required this.label,
    required this.statusColor,
    this.icon,
    this.secondaryLabel,
    this.onTap,
    this.compact = false,
  });

  final String label;
  final Color statusColor;
  final IconData? icon;
  final String? secondaryLabel;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = CamelliaTypography.tabular(
      (compact ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
          ?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
    );

    final pill = GlassSurface(
      layer: CamelliaGlassLayer.floating,
      borderRadius: BorderRadius.circular(CamelliaRadius.pill),
      showShadow: false,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 11,
        vertical: compact ? 4 : 6,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 7 : 8,
            height: compact ? 7 : 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: statusColor.withValues(alpha: 0.48),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          if (icon != null) ...[
            const SizedBox(width: 6),
            Icon(icon, size: compact ? 13 : 15, color: statusColor),
          ],
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
          if (secondaryLabel != null && secondaryLabel!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              secondaryLabel!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CamelliaTypography.tabular(
                theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return pill;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap?.call();
      },
      child: MouseRegion(cursor: SystemMouseCursors.click, child: pill),
    );
  }
}

/// Destination entry for [GlassFloatingTabBar].
class GlassFloatingTabItem {
  const GlassFloatingTabItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.badgeCount = 0,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final int badgeCount;
}

/// Mobile Apple-style Floating Capsule Bottom Tab Bar with frosted glass
/// depth, specular top highlight, animated active indicator pill, and haptics.
class GlassFloatingTabBar extends StatelessWidget {
  const GlassFloatingTabBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<GlassFloatingTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Center(
        heightFactor: 1.0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: GlassSurface(
            layer: CamelliaGlassLayer.modal,
            elevated: true,
            borderRadius: BorderRadius.circular(CamelliaRadius.pill),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _FloatingTabButton(
                      item: items[i],
                      selected: i == currentIndex,
                      primary: activeColor,
                      muted: muted,
                      reduceMotion: reduceMotion,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onTap(i);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingTabButton extends StatelessWidget {
  const _FloatingTabButton({
    required this.item,
    required this.selected,
    required this.primary,
    required this.muted,
    required this.reduceMotion,
    required this.onTap,
  });

  final GlassFloatingTabItem item;
  final bool selected;
  final Color primary;
  final Color muted;
  final bool reduceMotion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Semantics(
        button: true,
        selected: selected,
        label: item.label,
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : CamelliaMotion.state,
          curve: CamelliaMotion.springSnappy,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? primary.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.22 : 0.13,
                  )
                : Colors.transparent,
            borderRadius: BorderRadius.circular(CamelliaRadius.pill),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    selected ? item.selectedIcon : item.icon,
                    size: 22,
                    color: selected ? primary : muted,
                  ),
                  if (item.badgeCount > 0)
                    Positioned(
                      right: -8,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: CamelliaColors.statusAlertLight,
                          borderRadius: BorderRadius.circular(
                            CamelliaRadius.pill,
                          ),
                        ),
                        child: Text(
                          item.badgeCount > 99 ? '99+' : '${item.badgeCount}',
                          style: CamelliaTypography.tabular(
                            const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: selected ? primary : muted,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Presents a physics-damped frosted glass bottom sheet with specular top rim,
/// smooth grab handle, and safe area awareness.
Future<T?> showGlassBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  String? subtitle,
  List<Widget> actions = const [],
  bool isScrollControlled = true,
  bool showDragHandle = true,
}) {
  HapticFeedback.lightImpact();
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.44),
    elevation: 0,
    useSafeArea: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final bottomInset = MediaQuery.viewInsetsOf(sheetContext).bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: GlassSurface(
          layer: CamelliaGlassLayer.modal,
          elevated: true,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(CamelliaRadius.sheet),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDragHandle)
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 10, bottom: 6),
                      width: 38,
                      height: 4.5,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.36,
                        ),
                        borderRadius: BorderRadius.circular(
                          CamelliaRadius.pill,
                        ),
                      ),
                    ),
                  ),
                if (title != null || actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 14, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (title != null)
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              if (subtitle != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                        ...actions,
                      ],
                    ),
                  ),
                Flexible(child: builder(sheetContext)),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Clean 6-state frosted text input container with focus glow ring, optional
/// clear & clipboard paste slots, tabular numerals, and inline error state.
class GlassInput extends StatefulWidget {
  const GlassInput({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.labelText,
    this.errorText,
    this.prefixIcon,
    this.leading,
    this.trailing,
    this.showClearButton = true,
    this.showPasteButton = false,
    this.tabularNums = false,
    this.obscureText = false,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.borderRadius,
    this.contentPadding,
    this.style,
    this.textFieldKey,
    this.minHeight = 44,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final String? labelText;
  final String? errorText;
  final IconData? prefixIcon;
  final Widget? leading;
  final Widget? trailing;
  final bool showClearButton;
  final bool showPasteButton;
  final bool tabularNums;
  final bool obscureText;
  final bool enabled;
  final bool readOnly;
  final bool autofocus;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? style;
  final Key? textFieldKey;
  final double minHeight;

  @override
  State<GlassInput> createState() => _GlassInputState();
}

class _GlassInputState extends State<GlassInput> {
  TextEditingController? _internalController;
  FocusNode? _internalFocusNode;
  bool _hovered = false;
  bool _focused = false;
  bool _hasText = false;

  TextEditingController get _controller =>
      widget.controller ?? (_internalController ??= TextEditingController());

  FocusNode get _focusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _hasText = _controller.text.isNotEmpty;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
    _focused = _focusNode.hasFocus;
  }

  @override
  void didUpdateWidget(covariant GlassInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _internalController)?.removeListener(
        _onTextChanged,
      );
      if (widget.controller != null && _internalController != null) {
        _internalController!.dispose();
        _internalController = null;
      }
      _controller.addListener(_onTextChanged);
      _hasText = _controller.text.isNotEmpty;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _internalFocusNode)?.removeListener(
        _onFocusChanged,
      );
      if (widget.focusNode != null && _internalFocusNode != null) {
        _internalFocusNode!.dispose();
        _internalFocusNode = null;
      }
      _focusNode.addListener(_onFocusChanged);
      _focused = _focusNode.hasFocus;
    }
  }

  void _onTextChanged() {
    final nextHasText = _controller.text.isNotEmpty;
    if (nextHasText != _hasText && mounted) {
      setState(() => _hasText = nextHasText);
    }
  }

  void _onFocusChanged() {
    final nextFocused = _focusNode.hasFocus;
    if (nextFocused != _focused && mounted) {
      setState(() => _focused = nextFocused);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _internalController?.dispose();
    _internalFocusNode?.dispose();
    super.dispose();
  }

  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    HapticFeedback.selectionClick();
    widget.onChanged?.call(text);
  }

  void _handleClear() {
    _controller.clear();
    HapticFeedback.selectionClick();
    widget.onChanged?.call('');
    widget.onClear?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final radius =
        widget.borderRadius ?? BorderRadius.circular(CamelliaRadius.control);

    final baseBg = _hovered && widget.enabled
        ? Color.alphaBlend(glass.hoverOverlay, glass.floatingTint)
        : glass.floatingTint;
    final borderTop = hasError
        ? glass.statusAlert
        : _focused
        ? accent.withValues(alpha: 0.85)
        : glass.specularTop;
    final borderBottom = hasError
        ? glass.statusAlert.withValues(alpha: 0.78)
        : _focused
        ? accent.withValues(alpha: 0.55)
        : glass.specularBottom;

    final rawStyle = (widget.style ?? theme.textTheme.bodyMedium)?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    final textStyle = widget.tabularNums
        ? CamelliaTypography.tabular(rawStyle)
        : rawStyle;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.labelText != null && widget.labelText!.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              widget.labelText!,
              style: theme.textTheme.labelMedium?.copyWith(
                color: hasError
                    ? glass.statusAlert
                    : _focused
                    ? accent
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        MouseRegion(
          onEnter: (_) {
            if (mounted) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (mounted) setState(() => _hovered = false);
          },
          child: AnimatedOpacity(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
            opacity: widget.enabled ? 1.0 : 0.52,
            child: AnimatedContainer(
              duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
              curve: CamelliaMotion.standard,
              constraints: BoxConstraints(minHeight: widget.minHeight),
              decoration: BoxDecoration(
                color: baseBg,
                borderRadius: radius,
                boxShadow: [
                  if (_focused && widget.enabled)
                    BoxShadow(
                      color: (hasError
                              ? glass.statusAlert
                              : glass.focusGlow)
                          .withValues(alpha: dark ? 0.32 : 0.22),
                      blurRadius: 8,
                      spreadRadius: 0.5,
                    ),
                ],
              ),
              child: CustomPaint(
                foregroundPainter: SpecularEdgePainter(
                  borderRadius: radius,
                  topColor: borderTop,
                  bottomColor: borderBottom,
                  strokeWidth: (_focused || hasError) ? 1.25 : 0.9,
                ),
                child: Padding(
                  padding:
                      widget.contentPadding ??
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Row(
                    crossAxisAlignment: widget.maxLines > 1
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.center,
                    children: [
                      if (widget.leading != null) ...[
                        widget.leading!,
                        const SizedBox(width: 8),
                      ] else if (widget.prefixIcon != null) ...[
                        Padding(
                          padding: EdgeInsets.only(
                            top: widget.maxLines > 1 ? 10 : 0,
                          ),
                          child: Icon(
                            widget.prefixIcon,
                            size: 18,
                            color: hasError
                                ? glass.statusAlert
                                : _focused
                                ? accent
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: TextField(
                          key: widget.textFieldKey,
                          controller: _controller,
                          focusNode: _focusNode,
                          enabled: widget.enabled,
                          readOnly: widget.readOnly,
                          autofocus: widget.autofocus,
                          obscureText: widget.obscureText,
                          maxLines: widget.maxLines,
                          keyboardType: widget.keyboardType,
                          textInputAction: widget.textInputAction,
                          inputFormatters: widget.inputFormatters,
                          onChanged: widget.onChanged,
                          onSubmitted: widget.onSubmitted,
                          style: textStyle,
                          cursorColor: accent,
                          decoration: InputDecoration(
                            hintText: widget.hintText,
                            hintStyle: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.78),
                            ),
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      if (widget.showClearButton &&
                          _hasText &&
                          widget.enabled &&
                          !widget.readOnly)
                        _GlassInputSlotButton(
                          icon: CamelliaIcons.close,
                          tooltip: translate('Clear'),
                          onPressed: _handleClear,
                        ),
                      if (widget.showPasteButton &&
                          !_hasText &&
                          widget.enabled &&
                          !widget.readOnly)
                        _GlassInputSlotButton(
                          icon: CamelliaIcons.paste,
                          tooltip: translate('Paste'),
                          onPressed: _handlePaste,
                        ),
                      if (widget.trailing != null) ...[
                        const SizedBox(width: 4),
                        widget.trailing!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              widget.errorText!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: glass.statusAlert,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _GlassInputSlotButton extends StatelessWidget {
  const _GlassInputSlotButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    return Tooltip(
      message: translate(tooltip),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(CamelliaRadius.pill),
          hoverColor: glass.hoverOverlay,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          focusColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              icon,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Option descriptor for [GlassSegmentedControl].
class GlassSegmentItem<T> {
  const GlassSegmentItem({
    required this.value,
    this.label,
    this.icon,
    this.tooltip,
  }) : assert(
         label != null || icon != null,
         'GlassSegmentItem requires a label or an icon.',
       );

  final T value;
  final String? label;
  final IconData? icon;
  final String? tooltip;
}

/// Sleek frosted sliding-pill segmented switcher supporting icons, labels,
/// spring highlight motion, and WCAG AA+ contrast in Light, Dark, and Midnight.
class GlassSegmentedControl<T> extends StatelessWidget {
  const GlassSegmentedControl({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.compact = false,
    this.expand = false,
    this.enableBlur = false,
    this.height,
  });

  final List<GlassSegmentItem<T>> items;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool compact;
  final bool expand;
  final bool enableBlur;
  final double? height;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final reduceMotion = CamelliaMotion.reduceMotion(context);
    final trackRadius = BorderRadius.circular(CamelliaRadius.control + 2);
    final thumbRadius = BorderRadius.circular(CamelliaRadius.control);
    final controlHeight = height ?? (compact ? 34.0 : 40.0);
    const trackPadding = 3.0;

    final trackBg = dark
        ? theme.colorScheme.surfaceContainer.withValues(alpha: 0.78)
        : theme.colorScheme.surfaceContainer.withValues(alpha: 0.90);
    final thumbBg = switch (glass.themeStyle) {
      CamelliaThemeStyle.obsidianCyber => dark
          ? const Color(0xFF142032)
          : const Color(0xFFE2E8F0),
      CamelliaThemeStyle.nordicTitanium => dark
          ? const Color(0xFF2E2C28)
          : const Color(0xFFEDE9E3),
      _ => dark
          ? theme.colorScheme.surfaceContainerHigh
          : theme.colorScheme.surfaceContainerHighest,
    };
    final activeFg = switch (glass.themeStyle) {
      CamelliaThemeStyle.obsidianCyber => dark
          ? const Color(0xFF10B981)
          : const Color(0xFF059669),
      CamelliaThemeStyle.nordicTitanium => dark
          ? const Color(0xFFF59E0B)
          : const Color(0xFFB45309),
      _ => dark ? theme.colorScheme.onSurface : theme.colorScheme.primary,
    };
    final inactiveFg = theme.colorScheme.onSurfaceVariant;

    final selectedIndex = items
        .indexWhere((item) => item.value == selected)
        .clamp(0, items.length - 1);

    Widget buildItem(GlassSegmentItem<T> item, bool isSelected, bool drawPill) {
      final fg = isSelected ? activeFg : inactiveFg;
      final labelStyle =
          (compact ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
              ?.copyWith(
                color: fg,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              );

      Widget content = AnimatedContainer(
        duration: reduceMotion ? Duration.zero : CamelliaMotion.state,
        curve: CamelliaMotion.standard,
        height: controlHeight - trackPadding * 2,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: 4,
        ),
        decoration: drawPill && isSelected
            ? BoxDecoration(
                color: thumbBg,
                borderRadius: thumbRadius,
                boxShadow: [
                  BoxShadow(
                    color: glass.ambientShadow,
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              )
            : BoxDecoration(borderRadius: thumbRadius),
        child: _SegmentLabelRow(
          item: item,
          fg: fg,
          compact: compact,
          labelStyle: labelStyle,
        ),
      );

      content = _GlassSegmentTapTarget(
        selected: isSelected,
        label: item.label ?? item.tooltip,
        tooltip: item.tooltip,
        focusGlow: glass.focusGlow,
        borderRadius: thumbRadius,
        onTap: () {
          if (!isSelected) {
            HapticFeedback.selectionClick();
            onChanged(item.value);
          }
        },
        child: content,
      );
      return content;
    }

    Widget shell(Widget child) => GlassSurface(
      layer: CamelliaGlassLayer.floating,
      tintColor: trackBg,
      borderRadius: trackRadius,
      showShadow: false,
      enableBlur: enableBlur,
      strokeWidth: 0.0,
      padding: const EdgeInsets.all(trackPadding),
      child: child,
    );

    if (!expand) {
      return shell(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in items)
              buildItem(item, item.value == selected, true),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth) {
          return shell(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items)
                  buildItem(item, item.value == selected, true),
              ],
            ),
          );
        }

        final innerWidth = math.max(0.0, constraints.maxWidth - trackPadding * 2);
        final segmentWidth = innerWidth / items.length;
        final innerHeight = controlHeight - trackPadding * 2;

        return shell(
          SizedBox(
            height: innerHeight,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: reduceMotion ? Duration.zero : CamelliaMotion.state,
                  curve: CamelliaMotion.springSnappy,
                  left: selectedIndex * segmentWidth,
                  top: 0,
                  bottom: 0,
                  width: segmentWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: thumbBg,
                      borderRadius: thumbRadius,
                      boxShadow: [
                        BoxShadow(
                          color: glass.ambientShadow,
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final item in items)
                      Expanded(
                        child: buildItem(item, item.value == selected, false),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SegmentLabelRow<T> extends StatelessWidget {
  const _SegmentLabelRow({
    required this.item,
    required this.fg,
    required this.compact,
    required this.labelStyle,
  });

  final GlassSegmentItem<T> item;
  final Color fg;
  final bool compact;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (item.icon != null) Icon(item.icon, size: compact ? 15 : 17, color: fg),
        if (item.icon != null && item.label != null)
          SizedBox(width: compact ? 5 : 6),
        if (item.label != null)
          Flexible(
            child: Text(
              item.label!,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
      ],
    );
  }
}

class _GlassSegmentTapTarget extends StatefulWidget {
  const _GlassSegmentTapTarget({
    required this.selected,
    required this.focusGlow,
    required this.borderRadius,
    required this.onTap,
    required this.child,
    this.label,
    this.tooltip,
  });

  final bool selected;
  final Color focusGlow;
  final BorderRadius borderRadius;
  final VoidCallback onTap;
  final Widget child;
  final String? label;
  final String? tooltip;

  @override
  State<_GlassSegmentTapTarget> createState() => _GlassSegmentTapTargetState();
}

class _GlassSegmentTapTargetState extends State<_GlassSegmentTapTarget> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    Widget body = FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            boxShadow: (_focused &&
                    FocusManager.instance.highlightMode ==
                        FocusHighlightMode.traditional)
                ? [
                    BoxShadow(
                      color: widget.focusGlow.withValues(alpha: 0.20),
                      blurRadius: 6,
                      spreadRadius: 0.5,
                    ),
                  ]
                : const [],
          ),
          child: Semantics(
            button: true,
            selected: widget.selected,
            label: widget.label,
            child: widget.child,
          ),
        ),
      ),
    );

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      body = Tooltip(message: widget.tooltip!, child: body);
    }
    return body;
  }
}

/// Semantic tone for [GlassBadge].
enum GlassBadgeTone {
  online,
  offline,
  connecting,
  encrypted,
  warning,
  danger,
  neutral,
  brand,
}

/// Compact semantic status badge/chip with optional pulsing live dot and
/// `tabular-nums` telemetry support.
class GlassBadge extends StatelessWidget {
  const GlassBadge({
    super.key,
    required this.label,
    this.tone = GlassBadgeTone.neutral,
    this.icon,
    this.showDot = false,
    this.pulse = false,
    this.tabularNums = false,
    this.compact = false,
    this.borderRadius,
    this.onTap,
  });

  final String label;
  final GlassBadgeTone tone;
  final IconData? icon;
  final bool showDot;
  final bool pulse;
  final bool tabularNums;
  final bool compact;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;

    final accent = switch (tone) {
      GlassBadgeTone.online => glass.statusOnline,
      GlassBadgeTone.offline => glass.statusOffline,
      GlassBadgeTone.connecting => glass.statusConnecting,
      GlassBadgeTone.encrypted => glass.statusEncrypted,
      GlassBadgeTone.warning => glass.statusHighLatency,
      GlassBadgeTone.danger => glass.statusAlert,
      GlassBadgeTone.neutral => theme.colorScheme.onSurfaceVariant,
      GlassBadgeTone.brand =>
        dark ? theme.colorScheme.secondary : theme.colorScheme.primary,
    };

    final bg = accent.withValues(alpha: dark ? 0.18 : 0.12);
    final borderColor = accent.withValues(alpha: dark ? 0.24 : 0.18);
    // Keep foreground contrast WCAG AA+ across light/dark/midnight frosted glass.
    final textColor = theme.colorScheme.onSurface;
    final rawStyle =
        (compact ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
            ?.copyWith(color: textColor, fontWeight: FontWeight.w600);
    final textStyle = tabularNums
        ? CamelliaTypography.tabular(rawStyle)
        : rawStyle;

    final badge = DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius:
            borderRadius ?? BorderRadius.circular(CamelliaRadius.control),
        border: Border.all(color: borderColor, width: 0.75),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 3 : 5,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showDot) ...[
              _PulsingStatusDot(
                color: accent,
                size: compact ? 6.5 : 7.5,
                pulse: pulse,
              ),
              const SizedBox(width: 6),
            ],
            if (icon != null) ...[
              Icon(icon, size: compact ? 13 : 14, color: accent),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
          ],
        ),
      ),
    );

    if (onTap == null) return badge;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap?.call();
        },
        child: badge,
      ),
    );
  }
}

class _PulsingStatusDot extends StatefulWidget {
  const _PulsingStatusDot({
    required this.color,
    required this.size,
    required this.pulse,
  });

  final Color color;
  final double size;
  final bool pulse;

  @override
  State<_PulsingStatusDot> createState() => _PulsingStatusDotState();
}

class _PulsingStatusDotState extends State<_PulsingStatusDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.pulse) {
      _startPulse();
    }
  }

  void _startPulse() {
    _controller ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant _PulsingStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !oldWidget.pulse) {
      _startPulse();
    } else if (!widget.pulse && oldWidget.pulse) {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: widget.color.withValues(alpha: 0.45),
            blurRadius: 5,
          ),
        ],
      ),
    );
  }
}

/// Frosted modal card shell (`CamelliaGlassLayer.modal`) with specular edge,
/// diffused ambient shadow, responsive width clamping, and clean modal spacing.
class GlassModalShell extends StatelessWidget {
  const GlassModalShell({
    super.key,
    required this.child,
    this.title,
    this.actions,
    this.maxWidth = 500,
    this.padding,
    this.titlePadding,
    this.contentPadding,
    this.actionsPadding,
    this.borderRadius,
    this.scrollable = true,
    this.enableBlur = true,
  });

  final Widget child;
  final Widget? title;
  final List<Widget>? actions;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? titlePadding;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? actionsPadding;
  final double? borderRadius;
  final bool scrollable;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final clampedMaxWidth = math.min(
      maxWidth,
      math.max(260.0, screenWidth - 32.0),
    );
    final radius = BorderRadius.circular(borderRadius ?? CamelliaRadius.sheet);
    final hasTitle = title != null;
    final hasActions = actions != null && actions!.isNotEmpty;

    final resolvedTitlePadding =
        titlePadding ?? const EdgeInsets.fromLTRB(24, 22, 24, 10);
    final resolvedContentPadding =
        contentPadding ??
        padding ??
        EdgeInsets.fromLTRB(
          24,
          hasTitle ? 6 : 22,
          24,
          hasActions ? 16 : 22,
        );
    final resolvedActionsPadding =
        actionsPadding ?? const EdgeInsets.fromLTRB(24, 6, 24, 20);

    Widget body = Padding(padding: resolvedContentPadding, child: child);
    if (scrollable) {
      body = Flexible(
        fit: FlexFit.loose,
        child: SingleChildScrollView(child: body),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: clampedMaxWidth),
      child: GlassSurface(
        layer: CamelliaGlassLayer.modal,
        borderRadius: radius,
        elevated: true,
        enableBlur: enableBlur,
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: theme.textTheme.bodyMedium ?? const TextStyle(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasTitle)
                  Padding(
                    padding: resolvedTitlePadding,
                    child: DefaultTextStyle(
                      style:
                          theme.textTheme.titleLarge ??
                          const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                      child: title!,
                    ),
                  ),
                body,
                if (hasActions)
                  Padding(
                    padding: resolvedActionsPadding,
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      spacing: 10,
                      overflowSpacing: 8,
                      overflowAlignment: OverflowBarAlignment.end,
                      children: actions!,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Unified consistent vector icon library covering OS platforms, security
/// indicators, file categories, auth providers, toolbar actions, and keyboard
/// layout diagrams — zero missing `.svg` dependencies.
abstract final class CamelliaIcons {
  // Named semantic action & navigation icon constants
  static const IconData refresh = Icons.refresh_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData transfer = Icons.swap_horiz_rounded;
  static const IconData upload = Icons.upload_rounded;
  static const IconData download = Icons.download_rounded;
  static const IconData arrowUp = Icons.arrow_upward_rounded;
  static const IconData arrowBack = Icons.arrow_back_rounded;
  static const IconData arrowForward = Icons.arrow_forward_rounded;
  static const IconData search = Icons.search_rounded;
  static const IconData home = Icons.home_rounded;
  static const IconData folderNew = Icons.create_new_folder_rounded;
  static const IconData trash = Icons.delete_outline_rounded;
  static const IconData more = Icons.more_horiz_rounded;
  static const IconData chat = Icons.chat_bubble_outline_rounded;
  static const IconData voiceCall = Icons.call_rounded;
  static const IconData endCall = Icons.call_end_rounded;
  static const IconData screen = Icons.monitor_rounded;
  static const IconData addressBook = Icons.contacts_rounded;
  static const IconData deviceGroup = Icons.workspaces_rounded;
  static const IconData deviceGroupOutlined = Icons.workspaces_outline;
  static const IconData minimize = Icons.remove_rounded;
  static const IconData maximize = Icons.crop_square_rounded;
  static const IconData restore = Icons.filter_none_rounded;
  static const IconData add = Icons.add_rounded;
  static const IconData lock = Icons.lock_rounded;
  static const IconData privacy = Icons.visibility_off_rounded;
  static const IconData record = Icons.fiber_manual_record_rounded;
  static const IconData keyboard = Icons.keyboard_rounded;
  static const IconData mouse = Icons.mouse_rounded;
  static const IconData touch = Icons.touch_app_rounded;
  static const IconData display = Icons.display_settings_rounded;
  static const IconData audio = Icons.volume_up_rounded;
  static const IconData clipboard = Icons.content_paste_rounded;
  static const IconData tunnel = Icons.hub_rounded;
  static const IconData terminal = Icons.terminal_rounded;
  static const IconData camera = Icons.videocam_rounded;
  static const IconData settings = Icons.tune_rounded;
  static const IconData copy = Icons.content_copy_rounded;
  static const IconData check = Icons.check_rounded;
  static const IconData paste = Icons.content_paste_go_rounded;
  static const IconData qrScan = Icons.qr_code_scanner_rounded;
  static const IconData edit = Icons.edit_rounded;
  static const IconData eye = Icons.visibility_rounded;
  static const IconData eyeOff = Icons.visibility_off_rounded;
  static const IconData shield = Icons.shield_rounded;

  static IconData platformIcon(String os) {
    final normalized = os.trim().toLowerCase();
    if (normalized.contains('win')) return Icons.window_rounded;
    if (normalized.contains('mac') || normalized.contains('darwin')) {
      return Icons.laptop_mac_rounded;
    }
    if (normalized.contains('ios') || normalized.contains('iphone')) {
      return Icons.phone_iphone_rounded;
    }
    if (normalized.contains('android')) return Icons.phone_android_rounded;
    if (normalized.contains('linux') ||
        normalized.contains('ubuntu') ||
        normalized.contains('debian') ||
        normalized.contains('fedora') ||
        normalized.contains('arch')) {
      return Icons.terminal_rounded;
    }
    if (normalized.contains('web')) return Icons.public_rounded;
    return Icons.desktop_windows_rounded;
  }

  /// Renders a clean theme-harmonized OS platform vector badge (zero SVG assets).
  static Widget platformBadge(
    String os, {
    double size = 24,
    bool showBackground = false,
    Color? color,
  }) {
    final iconData = platformIcon(os);
    final normalized = os.trim().toLowerCase();
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final glass = CamelliaGlassTokens.of(context);
        final dark = theme.brightness == Brightness.dark;
        final resolvedColor =
            color ??
            (normalized.contains('win')
                ? glass.statusConnecting
                : normalized.contains('android')
                ? glass.statusOnline
                : normalized.contains('linux') ||
                      normalized.contains('ubuntu') ||
                      normalized.contains('debian') ||
                      normalized.contains('fedora') ||
                      normalized.contains('arch')
                ? glass.statusHighLatency
                : normalized.contains('mac') ||
                      normalized.contains('darwin') ||
                      normalized.contains('ios') ||
                      normalized.contains('iphone')
                ? (dark
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.primary)
                : normalized.contains('web')
                ? glass.statusEncrypted
                : theme.colorScheme.onSurfaceVariant);

        if (!showBackground) {
          return SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(iconData, size: size * 0.84, color: resolvedColor),
            ),
          );
        }

        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: resolvedColor.withValues(alpha: dark ? 0.18 : 0.12),
            borderRadius: BorderRadius.circular(size * 0.28),
            border: Border.all(
              color: resolvedColor.withValues(alpha: dark ? 0.34 : 0.24),
              width: 0.9,
            ),
          ),
          child: Center(
            child: Icon(iconData, size: size * 0.56, color: resolvedColor),
          ),
        );
      },
    );
  }

  static IconData securityIcon({required bool secure, required bool direct}) {
    if (secure) {
      return direct
          ? Icons.verified_user_rounded
          : Icons.enhanced_encryption_rounded;
    }
    return direct ? Icons.gpp_maybe_rounded : Icons.gpp_bad_rounded;
  }

  /// Replaces legacy `secure*.svg` / `insecure*.svg` with crisp vector badges.
  static Widget securityBadge({
    required bool secure,
    required bool direct,
    double size = 18,
  }) {
    final iconData = securityIcon(secure: secure, direct: direct);
    return Builder(
      builder: (context) {
        final glass = CamelliaGlassTokens.of(context);
        final color = secure
            ? (direct ? glass.statusOnline : glass.statusEncrypted)
            : (direct ? glass.statusHighLatency : glass.statusAlert);
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(iconData, size: size, color: color),
              if (!direct)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: size * 0.42,
                    height: size * 0.42,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.swap_horiz_rounded,
                      size: size * 0.34,
                      color: color,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _fileExtension(String name) {
    final trimmed = name.trim().toLowerCase();
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0 || dot >= trimmed.length - 1) return '';
    return trimmed.substring(dot + 1);
  }

  static const Set<String> _imageExts = {
    'png', 'jpg', 'jpeg', 'webp', 'svg', 'gif', 'heic', 'heif', 'bmp', 'ico',
    'tiff', 'tif', 'avif',
  };
  static const Set<String> _videoExts = {
    'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'flv', 'wmv', '3gp',
  };
  static const Set<String> _audioExts = {
    'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'wma',
  };
  static const Set<String> _archiveExts = {
    'zip', 'tar', 'gz', 'tgz', 'bz2', '7z', 'rar', 'xz', 'zst',
  };
  static const Set<String> _codeExts = {
    'dart', 'rs', 'py', 'js', 'ts', 'jsx', 'tsx', 'json', 'yaml', 'yml',
    'toml', 'xml', 'md', 'html', 'htm', 'css', 'scss', 'c', 'h', 'cpp', 'cc',
    'hpp', 'go', 'java', 'kt', 'swift', 'sh', 'bash', 'zsh', 'sql', 'rb',
    'php', 'lua', 'zig', 'gradle', 'cmake',
  };
  static const Set<String> _documentExts = {
    'doc', 'docx', 'txt', 'rtf', 'odt', 'pages', 'log',
  };
  static const Set<String> _spreadsheetExts = {
    'xls', 'xlsx', 'csv', 'tsv', 'ods', 'numbers',
  };
  static const Set<String> _presentationExts = {
    'ppt', 'pptx', 'key', 'odp',
  };
  static const Set<String> _executableExts = {
    'exe', 'msi', 'dmg', 'pkg', 'appimage', 'deb', 'rpm', 'apk', 'ipa', 'bin',
    'bat', 'cmd', 'ps1', 'so', 'dll', 'dylib',
  };

  static IconData fileTypeIcon(
    String name, {
    bool isDirectory = false,
    bool isDrive = false,
  }) {
    if (isDrive) return Icons.storage_rounded;
    if (isDirectory) return Icons.folder_rounded;
    final ext = _fileExtension(name);
    if (_imageExts.contains(ext)) return Icons.image_rounded;
    if (_videoExts.contains(ext)) return Icons.movie_rounded;
    if (_audioExts.contains(ext)) return Icons.audiotrack_rounded;
    if (_archiveExts.contains(ext)) return Icons.folder_zip_rounded;
    if (_codeExts.contains(ext)) return Icons.code_rounded;
    if (ext == 'pdf') return Icons.picture_as_pdf_rounded;
    if (_documentExts.contains(ext)) return Icons.description_rounded;
    if (_spreadsheetExts.contains(ext)) return Icons.table_chart_rounded;
    if (_presentationExts.contains(ext)) return Icons.slideshow_rounded;
    if (_executableExts.contains(ext)) return Icons.memory_rounded;
    return Icons.insert_drive_file_rounded;
  }

  static Color fileTypeColor(
    BuildContext context,
    String name, {
    bool isDirectory = false,
    bool isDrive = false,
  }) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    if (isDrive) return glass.statusEncrypted;
    if (isDirectory) return accent;

    final ext = _fileExtension(name);
    if (_imageExts.contains(ext)) return glass.statusEncrypted;
    if (_videoExts.contains(ext)) return accent;
    if (_audioExts.contains(ext)) return glass.statusConnecting;
    if (_archiveExts.contains(ext)) return glass.statusHighLatency;
    if (_codeExts.contains(ext)) return glass.statusOnline;
    if (ext == 'pdf') return glass.statusAlert;
    if (_documentExts.contains(ext)) return glass.statusConnecting;
    if (_spreadsheetExts.contains(ext)) return glass.statusOnline;
    if (_presentationExts.contains(ext)) return glass.statusHighLatency;
    if (_executableExts.contains(ext)) return glass.statusAlert;
    return theme.colorScheme.onSurfaceVariant;
  }

  static IconData authProviderIcon(String provider) {
    final normalized = provider.trim().toLowerCase();
    if (normalized.contains('google')) return Icons.g_mobiledata_rounded;
    if (normalized.contains('github') || normalized.contains('gitlab')) {
      return Icons.code_rounded;
    }
    if (normalized.contains('microsoft') ||
        normalized.contains('azure') ||
        normalized.contains('entra')) {
      return Icons.window_rounded;
    }
    if (normalized.contains('apple')) return Icons.laptop_mac_rounded;
    if (normalized.contains('facebook')) return Icons.public_rounded;
    if (normalized.contains('okta') ||
        normalized.contains('auth0') ||
        normalized.contains('oidc') ||
        normalized.contains('sso')) {
      return Icons.verified_user_rounded;
    }
    if (normalized.contains('ldap') || normalized.contains('ad')) {
      return Icons.badge_rounded;
    }
    if (normalized.contains('wechat') ||
        normalized.contains('feishu') ||
        normalized.contains('dingtalk')) {
      return Icons.forum_rounded;
    }
    return Icons.key_rounded;
  }

  /// Crisp theme-aware vector diagram distinguishing ISO vs ANSI keyboard layouts,
  /// replacing deleted `assets/kb_layout_iso.svg` and `assets/kb_layout_not_iso.svg`.
  static Widget keyboardLayoutPreview({
    required bool isIso,
    double width = 160,
    double height = 64,
  }) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final glass = CamelliaGlassTokens.of(context);
        final dark = theme.brightness == Brightness.dark;
        final accent = dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;
        return RepaintBoundary(
          child: SizedBox(
            width: width,
            height: height,
            child: CustomPaint(
              painter: _KeyboardLayoutPainter(
                isIso: isIso,
                keyFill: glass.floatingTint,
                keyBorder: theme.colorScheme.outlineVariant,
                highlightFill: accent.withValues(alpha: dark ? 0.28 : 0.16),
                highlightBorder: accent,
              ),
            ),
          ),
        );
      },
    );
  }

  static IconData signalIcon(int? latencyMs) {
    if (latencyMs == null || latencyMs <= 0) {
      return Icons.signal_cellular_alt_rounded;
    }
    if (latencyMs < 60) return Icons.signal_cellular_alt_rounded;
    if (latencyMs < 150) return Icons.signal_cellular_alt_2_bar_rounded;
    return Icons.signal_cellular_alt_1_bar_rounded;
  }

  static Color signalColor(BuildContext context, int? latencyMs) {
    final glass = CamelliaGlassTokens.of(context);
    if (latencyMs == null || latencyMs <= 0) return glass.statusOnline;
    if (latencyMs < 80) return glass.statusOnline;
    if (latencyMs < 180) return glass.statusHighLatency;
    return glass.statusAlert;
  }
}

class _KeyboardLayoutPainter extends CustomPainter {
  const _KeyboardLayoutPainter({
    required this.isIso,
    required this.keyFill,
    required this.keyBorder,
    required this.highlightFill,
    required this.highlightBorder,
  });

  final bool isIso;
  final Color keyFill;
  final Color keyBorder;
  final Color highlightFill;
  final Color highlightBorder;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final pad = 4.0;
    final gap = 3.0;
    final innerW = size.width - pad * 2;
    final innerH = size.height - pad * 2;
    final rowH = (innerH - gap * 2) / 3.0;
    final unit = (innerW - gap * 9) / 10.0;
    final r = Radius.circular(math.min(4.0, rowH * 0.24));

    final fillPaint = Paint()..color = keyFill;
    final strokePaint = Paint()
      ..color = keyBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    final hiFill = Paint()..color = highlightFill;
    final hiStroke = Paint()
      ..color = highlightBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;

    void drawKey(
      double left,
      double top,
      double width,
      double height, {
      bool highlight = false,
    }) {
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, width, height),
        r,
      );
      canvas.drawRRect(rrect, highlight ? hiFill : fillPaint);
      canvas.drawRRect(rrect, highlight ? hiStroke : strokePaint);
    }

    // Row 0: Q..P + top of ISO Enter or ANSI backslash
    final y0 = pad;
    final y1 = pad + rowH + gap;
    final y2 = pad + (rowH + gap) * 2;

    double x = pad;
    for (var i = 0; i < 8; i++) {
      drawKey(x, y0, unit, rowH);
      x += unit + gap;
    }
    final topRightStart = x;
    final rightEdge = size.width - pad;

    if (isIso) {
      // One regular key + L-shaped ISO Enter spanning Row 0 and Row 1
      drawKey(topRightStart, y0, unit, rowH);
      final enterTopLeft = topRightStart + unit + gap;
      final enterW = rightEdge - enterTopLeft;
      final enterLowerLeft = enterTopLeft + enterW * 0.22;
      final rad = math.min(4.0, rowH * 0.24);
      final path = Path()
        ..moveTo(enterTopLeft + rad, y0)
        ..lineTo(rightEdge - rad, y0)
        ..quadraticBezierTo(rightEdge, y0, rightEdge, y0 + rad)
        ..lineTo(rightEdge, y1 + rowH - rad)
        ..quadraticBezierTo(
          rightEdge,
          y1 + rowH,
          rightEdge - rad,
          y1 + rowH,
        )
        ..lineTo(enterLowerLeft + rad, y1 + rowH)
        ..quadraticBezierTo(
          enterLowerLeft,
          y1 + rowH,
          enterLowerLeft,
          y1 + rowH - rad,
        )
        ..lineTo(enterLowerLeft, y0 + rowH + gap)
        ..lineTo(enterTopLeft + rad, y0 + rowH + gap)
        ..quadraticBezierTo(
          enterTopLeft,
          y0 + rowH + gap,
          enterTopLeft,
          y0 + rowH + gap - rad,
        )
        ..lineTo(enterTopLeft, y0 + rad)
        ..quadraticBezierTo(enterTopLeft, y0, enterTopLeft + rad, y0)
        ..close();
      canvas.drawPath(path, hiFill);
      canvas.drawPath(path, hiStroke);
    } else {
      // ANSI backslash key spanning top-right
      drawKey(topRightStart, y0, rightEdge - topRightStart, rowH);
    }

    // Row 1: Home row + ANSI wide Enter (or extra key next to ISO Enter)
    x = pad;
    final row1Count = isIso ? 9 : 8;
    for (var i = 0; i < row1Count; i++) {
      drawKey(x, y1, unit, rowH);
      x += unit + gap;
    }
    if (!isIso) {
      drawKey(x, y1, rightEdge - x, rowH, highlight: true);
    }

    // Row 2: ISO split Left Shift + extra key vs ANSI wide Left Shift
    x = pad;
    if (isIso) {
      drawKey(x, y2, unit * 1.1, rowH, highlight: true);
      x += unit * 1.1 + gap;
      drawKey(x, y2, unit * 0.9, rowH, highlight: true);
      x += unit * 0.9 + gap;
    } else {
      drawKey(x, y2, unit * 2.0 + gap, rowH, highlight: true);
      x += unit * 2.0 + gap * 2;
    }
    for (var i = 0; i < 6; i++) {
      drawKey(x, y2, unit, rowH);
      x += unit + gap;
    }
    if (rightEdge - x > 6) {
      drawKey(x, y2, rightEdge - x, rowH);
    }
  }

  @override
  bool shouldRepaint(covariant _KeyboardLayoutPainter oldDelegate) =>
      oldDelegate.isIso != isIso ||
      oldDelegate.keyFill != keyFill ||
      oldDelegate.keyBorder != keyBorder ||
      oldDelegate.highlightFill != highlightFill ||
      oldDelegate.highlightBorder != highlightBorder;
}
