import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    if (size.isEmpty) return;
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
    return GlassSurface(
      layer: layer,
      margin: margin,
      borderRadius: borderRadius,
      elevated: elevated,
      enableBlur: enableBlur,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasHeader)
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
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// Visual prominence variant for [GlassButton].
enum GlassButtonVariant { primary, secondary, subtle, danger }

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
    Color borderTop;
    Color borderBottom;
    switch (widget.variant) {
      case GlassButtonVariant.primary:
        bgColor = theme.colorScheme.primary;
        fgColor = Colors.white;
        borderTop = Colors.white.withValues(alpha: 0.42);
        borderBottom = Colors.black.withValues(alpha: 0.14);
      case GlassButtonVariant.danger:
        bgColor = glass.statusAlert;
        fgColor = Colors.white;
        borderTop = Colors.white.withValues(alpha: 0.36);
        borderBottom = Colors.black.withValues(alpha: 0.18);
      case GlassButtonVariant.subtle:
        bgColor = _hovered
            ? glass.hoverOverlay
            : Colors.transparent;
        fgColor = theme.colorScheme.onSurface;
        borderTop = _hovered ? glass.specularTop : Colors.transparent;
        borderBottom = _hovered ? glass.specularBottom : Colors.transparent;
      case GlassButtonVariant.secondary:
        bgColor = glass.floatingTint;
        fgColor = theme.colorScheme.onSurface;
        borderTop = glass.specularTop;
        borderBottom = glass.specularBottom;
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

    final opacity = _enabled || widget.loading ? 1.0 : 0.46;
    final scale = (!_enabled || reduceMotion)
        ? 1.0
        : _pressed
        ? 0.968
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
              if (_focused)
                BoxShadow(
                  color: glass.focusGlow,
                  blurRadius: 0,
                  spreadRadius: 2.5,
                ),
              if (widget.variant == GlassButtonVariant.primary && _enabled)
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(
                    alpha: _hovered ? 0.34 : 0.22,
                  ),
                  blurRadius: _hovered ? 16 : 10,
                  offset: Offset(0, _hovered ? 5 : 3),
                ),
            ],
          ),
          child: CustomPaint(
            foregroundPainter: SpecularEdgePainter(
              borderRadius: radius,
              topColor: borderTop,
              bottomColor: borderBottom,
              strokeWidth: 0.85,
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
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
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

    final tip = !_enabled ? (widget.disabledTooltip ?? widget.tooltip) : widget.tooltip;
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
    this.accentColor,
    this.enableHaptics = true,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;
  final bool selected;
  final Color? accentColor;
  final bool enableHaptics;

  @override
  State<GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<GlassIconButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final radius = BorderRadius.circular(widget.size / 2);
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    final bg = widget.selected
        ? accent.withValues(alpha: 0.18)
        : (_hovered && _enabled ? glass.hoverOverlay : glass.floatingTint);
    final fg = widget.selected
        ? accent
        : (_enabled
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurface.withValues(alpha: 0.38));

    Widget button = FocusableActionDetector(
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
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
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
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: glass.focusGlow,
                        blurRadius: 0,
                        spreadRadius: 2.2,
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
                strokeWidth: 0.85,
              ),
              child: Center(
                child: Icon(widget.icon, size: widget.iconSize, color: fg),
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
    final primary = theme.colorScheme.primary;
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
                      primary: primary,
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
                          color: CamelliaColors.coral,
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

/// Unified consistent vector icon helpers covering OS platforms, connection
/// modes, signal strength, and permissions.
abstract final class CamelliaIcons {
  static IconData platformIcon(String platform) {
    final normalized = platform.trim().toLowerCase();
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

  static IconData signalIcon(int? latencyMs) {
    if (latencyMs == null || latencyMs <= 0) return Icons.signal_cellular_alt_rounded;
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
