import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/brand/portal_mark_spec.dart';

class CamelliaBrandMark extends StatelessWidget {
  const CamelliaBrandMark({
    super.key,
    this.size = 36,
    this.withPlate = true,
    this.monochrome = false,
    this.progress = 1,
    this.semanticLabel,
  });

  final double size;
  final bool withPlate;
  final bool monochrome;
  final double progress;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: semanticLabel,
      child: CustomPaint(
        size: Size.square(size),
        painter: _CamelliaBrandPainter(
          brightness: Theme.of(context).brightness,
          withPlate: withPlate,
          monochrome: monochrome,
          progress: progress,
        ),
      ),
    );
  }
}

class _CamelliaBrandPainter extends CustomPainter {
  const _CamelliaBrandPainter({
    required this.brightness,
    required this.withPlate,
    required this.monochrome,
    required this.progress,
  });

  static const _rearStart = Color(PortalMarkSpec.rearGradientStartArgb);
  static const _rearEnd = Color(PortalMarkSpec.rearGradientEndArgb);
  static const _frontStart = Color(PortalMarkSpec.frontGradientStartArgb);
  static const _frontEnd = Color(PortalMarkSpec.frontGradientEndArgb);
  static const _connectorStart = Color(
    PortalMarkSpec.connectorGradientStartArgb,
  );
  static const _connectorEnd = Color(PortalMarkSpec.connectorGradientEndArgb);
  static const _lightPlateStart = Color(PortalMarkSpec.lightPlateStartArgb);
  static const _lightPlateEnd = Color(PortalMarkSpec.lightPlateEndArgb);
  static const _lightPlateBorder = Color(PortalMarkSpec.lightPlateBorderArgb);
  static const _darkPlateStart = Color(PortalMarkSpec.darkPlateStartArgb);
  static const _darkPlateEnd = Color(PortalMarkSpec.darkPlateEndArgb);
  static const _darkPlateBorder = Color(PortalMarkSpec.darkPlateBorderArgb);

  final Brightness brightness;
  final bool withPlate;
  final bool monochrome;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final origin = Offset((size.width - side) / 2, (size.height - side) / 2);
    final dark = brightness == Brightness.dark;
    final ink = dark ? Colors.white : CamelliaColors.lightText;
    final easedProgress = Curves.easeOutCubic.transform(
      progress.clamp(0, 1).toDouble(),
    );

    if (withPlate) {
      final outerRect = Rect.fromLTWH(origin.dx, origin.dy, side, side);
      final plateRect = RRect.fromRectAndRadius(
        outerRect,
        Radius.circular(side * PortalMarkSpec.plateRadius),
      );
      final plateStart = dark ? _darkPlateStart : _lightPlateStart;
      final plateEnd = dark ? _darkPlateEnd : _lightPlateEnd;
      final plateBorder = dark ? _darkPlateBorder : _lightPlateBorder;

      canvas.drawRRect(
        plateRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [plateStart, plateEnd],
          ).createShader(outerRect),
      );

      // Apple Liquid Glass luminous top-surface specular highlight.
      canvas.save();
      canvas.clipRRect(plateRect);
      canvas.drawRect(
        Rect.fromLTWH(origin.dx, origin.dy, side, side * 0.52),
        Paint()
          ..shader =
              LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: dark ? 0.16 : 0.68),
                  Colors.white.withValues(alpha: dark ? 0.03 : 0.14),
                  Colors.white.withValues(alpha: 0),
                ],
                stops: const [0.0, 0.45, 1.0],
              ).createShader(
                Rect.fromLTWH(origin.dx, origin.dy, side, side * 0.52),
              ),
      );
      canvas.restore();

      final strokeWidth = math.max(1.0, side * 0.024);
      canvas.drawRRect(
        plateRect.deflate(strokeWidth / 2),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: dark ? 0.34 : 0.90),
              plateBorder.withValues(alpha: dark ? 0.92 : 0.94),
            ],
          ).createShader(outerRect)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
    }

    final inset = withPlate ? side * PortalMarkSpec.contentInset : 0.0;
    final contentSide = side - inset * 2;
    final contentOrigin = origin + Offset(inset, inset);
    final spread = easedProgress;
    final rearOffset = Offset(
      (1 - spread) * contentSide * 0.10,
      (1 - spread) * contentSide * 0.10,
    );
    final frontOffset = -rearOffset;

    RRect scaledRect(PortalRectSpec spec, Offset animationOffset) {
      return RRect.fromRectAndRadius(
        Rect.fromLTWH(
          contentOrigin.dx + spec.left * contentSide + animationOffset.dx,
          contentOrigin.dy + spec.top * contentSide + animationOffset.dy,
          spec.width * contentSide,
          spec.height * contentSide,
        ),
        Radius.circular(spec.radius * contentSide),
      );
    }

    Paint gradientPaint(RRect rect, Color start, Color end) => Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [start, end],
      ).createShader(rect.outerRect);

    Paint specularHighlightPaint(RRect rect) =>
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.32 * easedProgress),
              Colors.white.withValues(alpha: 0.06 * easedProgress),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.42, 1.0],
          ).createShader(rect.outerRect);

    final rear = scaledRect(PortalMarkSpec.rearScreen, rearOffset);
    final rearCutout = scaledRect(PortalMarkSpec.rearCutout, rearOffset);
    final front = scaledRect(PortalMarkSpec.frontScreen, frontOffset);
    final frontCutout = scaledRect(PortalMarkSpec.frontCutout, frontOffset);
    final rearFrame = Path.combine(
      PathOperation.difference,
      Path()..addRRect(rear),
      Path()..addRRect(rearCutout),
    );
    final frontFrame = Path.combine(
      PathOperation.difference,
      Path()..addRRect(front),
      Path()..addRRect(frontCutout),
    );

    canvas.drawPath(
      rearFrame,
      monochrome
          ? (Paint()..color = ink.withValues(alpha: easedProgress))
          : gradientPaint(
              rear,
              _rearStart.withValues(alpha: easedProgress),
              _rearEnd.withValues(alpha: easedProgress),
            ),
    );
    if (!monochrome) {
      canvas.drawPath(rearFrame, specularHighlightPaint(rear));
    }

    final connectorStart =
        contentOrigin +
        Offset(
          PortalMarkSpec.connectorStartX * contentSide,
          PortalMarkSpec.connectorStartY * contentSide,
        );
    final connectorEnd =
        contentOrigin +
        Offset(
          PortalMarkSpec.connectorEndX * contentSide,
          PortalMarkSpec.connectorEndY * contentSide,
        );
    canvas.drawLine(
      connectorStart,
      connectorEnd,
      Paint()
        ..shader = monochrome
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _connectorStart.withValues(alpha: easedProgress),
                  _connectorEnd.withValues(alpha: easedProgress),
                ],
              ).createShader(Rect.fromPoints(connectorStart, connectorEnd))
        ..color = monochrome
            ? ink.withValues(alpha: easedProgress)
            : _connectorStart.withValues(alpha: easedProgress)
        ..strokeWidth = contentSide * PortalMarkSpec.connectorWidth
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawPath(
      frontFrame,
      monochrome
          ? (Paint()..color = ink.withValues(alpha: easedProgress))
          : gradientPaint(
              front,
              _frontStart.withValues(alpha: easedProgress),
              _frontEnd.withValues(alpha: easedProgress),
            ),
    );
    if (!monochrome) {
      canvas.drawPath(frontFrame, specularHighlightPaint(front));
    }
  }

  @override
  bool shouldRepaint(_CamelliaBrandPainter oldDelegate) =>
      oldDelegate.brightness != brightness ||
      oldDelegate.withPlate != withPlate ||
      oldDelegate.monochrome != monochrome ||
      oldDelegate.progress != progress;
}

class CamelliaAnimatedBrandMark extends StatelessWidget {
  const CamelliaAnimatedBrandMark({
    super.key,
    this.size = 42,
    this.withPlate = true,
    this.semanticLabel,
  });

  final double size;
  final bool withPlate;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      builder: (context, progress, _) => CamelliaBrandMark(
        size: size,
        withPlate: withPlate,
        progress: progress,
        semanticLabel: semanticLabel,
      ),
    );
  }
}
