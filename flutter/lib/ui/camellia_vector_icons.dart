import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'camellia_design.dart';

/// Precision geometric vector glyphs rendered on a normalized 24x24 canvas.
/// Ensures razor-sharp rendering at any DPI, theme color, or headless test
/// environment without external SVG or icon-font dependencies.
enum CamelliaGlyph {
  remoteDesktop,
  viewOnly,
  fileTransfer,
  terminal,
  camera,
  portTunnel,
  devices,
  addressBook,
  deviceGroup,
  settings,
  search,
  commandKey,
  shieldCheck,
  shieldRelay,
  shieldWarn,
  bolt,
  display,
  monitors,
  keyboard,
  mouse,
  trackpad,
  audioOn,
  audioMute,
  micOn,
  micOff,
  chat,
  phoneCall,
  phoneHangup,
  lock,
  unlock,
  key,
  eye,
  eyeOff,
  copy,
  check,
  paste,
  refresh,
  plus,
  close,
  minimize,
  maximize,
  restore,
  pin,
  unpin,
  folder,
  folderPlus,
  upload,
  download,
  swap,
  trash,
  tag,
  qrCode,
  sliders,
  sparkle,
  emptyDevices,
  emptyTunnels,
  emptyFiles,
  emptyGroups,
}

/// Crisp custom-painted vector icon with optional duotone fill accent.
class CamelliaVectorIcon extends StatelessWidget {
  const CamelliaVectorIcon(
    this.glyph, {
    super.key,
    this.size = 18.0,
    this.color,
    this.strokeWidth = 1.65,
    this.duotone = false,
    this.duotoneAlpha = 0.14,
    this.semanticLabel,
  });

  final CamelliaGlyph glyph;
  final double size;
  final Color? color;
  final double strokeWidth;
  final bool duotone;
  final double duotoneAlpha;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final resolvedColor =
        color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      excludeSemantics: semanticLabel == null,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _CamelliaGlyphPainter(
            glyph: glyph,
            color: resolvedColor,
            strokeWidth: strokeWidth,
            duotone: duotone,
            duotoneAlpha: duotoneAlpha,
          ),
        ),
      ),
    );
  }
}

/// Architectural state badge pairing a subtle top-lit glass container with a
/// duotone [CamelliaVectorIcon] for empty, loading, offline, and error panes.
class CamelliaStateIllustration extends StatelessWidget {
  const CamelliaStateIllustration({
    super.key,
    required this.glyph,
    this.accentColor,
    this.size = 56.0,
  });

  final CamelliaGlyph glyph;
  final Color? accentColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tone = accentColor ?? theme.colorScheme.primary;
    final radius = BorderRadius.circular(size * 0.28);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tone.withValues(alpha: dark ? 0.18 : 0.11),
            tone.withValues(alpha: dark ? 0.06 : 0.04),
          ],
        ),
        borderRadius: radius,
        border: Border.all(
          color: tone.withValues(alpha: dark ? 0.28 : 0.20),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: glass.ambientShadow,
            blurRadius: 14,
            spreadRadius: -3,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Center(
        child: CamelliaVectorIcon(
          glyph,
          size: size * 0.46,
          color: tone,
          strokeWidth: 1.7,
          duotone: true,
          duotoneAlpha: dark ? 0.22 : 0.14,
        ),
      ),
    );
  }
}

class _CamelliaGlyphPainter extends CustomPainter {
  const _CamelliaGlyphPainter({
    required this.glyph,
    required this.color,
    required this.strokeWidth,
    required this.duotone,
    required this.duotoneAlpha,
  });

  final CamelliaGlyph glyph;
  final Color color;
  final double strokeWidth;
  final bool duotone;
  final double duotoneAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final scale = math.min(size.width, size.height) / 24.0;
    canvas.save();
    canvas.translate(
      (size.width - 24.0 * scale) / 2.0,
      (size.height - 24.0 * scale) / 2.0,
    );
    canvas.scale(scale, scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final fill = Paint()
      ..color = color.withValues(alpha: duotoneAlpha.clamp(0.0, 1.0))
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final solidFill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    RRect rr(double l, double t, double w, double h, double r) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(l, t, w, h), Radius.circular(r));

    switch (glyph) {
      case CamelliaGlyph.remoteDesktop:
      case CamelliaGlyph.display:
        final screen = rr(2.5, 3.5, 19, 13, 2.4);
        if (duotone) canvas.drawRRect(screen, fill);
        canvas.drawRRect(screen, stroke);
        canvas.drawLine(const Offset(8.5, 20.5), const Offset(15.5, 20.5), stroke);
        canvas.drawLine(const Offset(12, 16.5), const Offset(12, 20.5), stroke);
        if (glyph == CamelliaGlyph.remoteDesktop) {
          final cursor = Path()
            ..moveTo(9.5, 7.5)
            ..lineTo(14.8, 10.2)
            ..lineTo(12.0, 11.1)
            ..lineTo(11.1, 13.8)
            ..close();
          canvas.drawPath(cursor, solidFill);
        }

      case CamelliaGlyph.monitors:
        final back = rr(6.5, 3.0, 15.0, 10.5, 2.0);
        final front = rr(2.5, 6.5, 15.0, 10.5, 2.0);
        if (duotone) canvas.drawRRect(front, fill);
        canvas.drawPath(
          Path()
            ..moveTo(6.5, 6.0)
            ..lineTo(6.5, 5.0)
            ..arcToPoint(const Offset(8.5, 3.0), radius: const Radius.circular(2))
            ..lineTo(19.5, 3.0)
            ..arcToPoint(const Offset(21.5, 5.0), radius: const Radius.circular(2))
            ..lineTo(21.5, 11.5)
            ..arcToPoint(const Offset(19.5, 13.5), radius: const Radius.circular(2))
            ..lineTo(18.0, 13.5),
          stroke,
        );
        canvas.drawRRect(front, stroke);
        canvas.drawLine(const Offset(7.0, 20.5), const Offset(13.0, 20.5), stroke);
        canvas.drawLine(const Offset(10.0, 17.0), const Offset(10.0, 20.5), stroke);
        // keep back reference used cleanly
        assert(back.width > 0);

      case CamelliaGlyph.viewOnly:
      case CamelliaGlyph.eye:
        final eyePath = Path()
          ..moveTo(2.2, 12.0)
          ..cubicTo(5.0, 6.5, 9.0, 5.5, 12.0, 5.5)
          ..cubicTo(15.0, 5.5, 19.0, 6.5, 21.8, 12.0)
          ..cubicTo(19.0, 17.5, 15.0, 18.5, 12.0, 18.5)
          ..cubicTo(9.0, 18.5, 5.0, 17.5, 2.2, 12.0)
          ..close();
        if (duotone) canvas.drawPath(eyePath, fill);
        canvas.drawPath(eyePath, stroke);
        canvas.drawCircle(const Offset(12.0, 12.0), 2.8, stroke);

      case CamelliaGlyph.eyeOff:
        final eyeOffPath = Path()
          ..moveTo(4.0, 8.8)
          ..cubicTo(6.2, 6.4, 9.0, 5.5, 12.0, 5.5)
          ..cubicTo(15.5, 5.5, 19.2, 7.0, 21.8, 12.0)
          ..cubicTo(20.6, 14.3, 19.1, 15.9, 17.4, 17.0);
        canvas.drawPath(eyeOffPath, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(14.2, 18.1)
            ..cubicTo(13.5, 18.4, 12.8, 18.5, 12.0, 18.5)
            ..cubicTo(8.5, 18.5, 4.8, 17.0, 2.2, 12.0)
            ..cubicTo(3.1, 10.3, 4.2, 8.9, 5.5, 7.9),
          stroke,
        );
        canvas.drawLine(const Offset(3.5, 3.5), const Offset(20.5, 20.5), stroke);

      case CamelliaGlyph.fileTransfer:
      case CamelliaGlyph.folder:
      case CamelliaGlyph.emptyFiles:
        final folderPath = Path()
          ..moveTo(3.0, 7.0)
          ..arcToPoint(const Offset(5.2, 4.8), radius: const Radius.circular(2.2))
          ..lineTo(9.4, 4.8)
          ..lineTo(11.6, 7.2)
          ..lineTo(18.8, 7.2)
          ..arcToPoint(const Offset(21.0, 9.4), radius: const Radius.circular(2.2))
          ..lineTo(21.0, 17.3)
          ..arcToPoint(const Offset(18.8, 19.5), radius: const Radius.circular(2.2))
          ..lineTo(5.2, 19.5)
          ..arcToPoint(const Offset(3.0, 17.3), radius: const Radius.circular(2.2))
          ..close();
        if (duotone) canvas.drawPath(folderPath, fill);
        canvas.drawPath(folderPath, stroke);
        if (glyph == CamelliaGlyph.fileTransfer) {
          canvas.drawLine(const Offset(9.0, 13.4), const Offset(15.0, 13.4), stroke);
          canvas.drawPath(
            Path()
              ..moveTo(13.0, 11.4)
              ..lineTo(15.2, 13.4)
              ..lineTo(13.0, 15.4),
            stroke,
          );
        }

      case CamelliaGlyph.folderPlus:
        final fp = Path()
          ..moveTo(3.0, 7.0)
          ..arcToPoint(const Offset(5.2, 4.8), radius: const Radius.circular(2.2))
          ..lineTo(9.4, 4.8)
          ..lineTo(11.6, 7.2)
          ..lineTo(18.8, 7.2)
          ..arcToPoint(const Offset(21.0, 9.4), radius: const Radius.circular(2.2))
          ..lineTo(21.0, 17.3)
          ..arcToPoint(const Offset(18.8, 19.5), radius: const Radius.circular(2.2))
          ..lineTo(5.2, 19.5)
          ..arcToPoint(const Offset(3.0, 17.3), radius: const Radius.circular(2.2))
          ..close();
        if (duotone) canvas.drawPath(fp, fill);
        canvas.drawPath(fp, stroke);
        canvas.drawLine(const Offset(12.0, 11.0), const Offset(12.0, 16.0), stroke);
        canvas.drawLine(const Offset(9.5, 13.5), const Offset(14.5, 13.5), stroke);

      case CamelliaGlyph.terminal:
        final box = rr(3.0, 4.0, 18.0, 16.0, 2.6);
        if (duotone) canvas.drawRRect(box, fill);
        canvas.drawRRect(box, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(7.2, 9.2)
            ..lineTo(10.4, 12.0)
            ..lineTo(7.2, 14.8),
          stroke,
        );
        canvas.drawLine(const Offset(12.2, 15.0), const Offset(16.6, 15.0), stroke);

      case CamelliaGlyph.camera:
        final body = rr(2.5, 6.2, 13.0, 11.6, 2.4);
        if (duotone) canvas.drawRRect(body, fill);
        canvas.drawRRect(body, stroke);
        final lens = Path()
          ..moveTo(15.5, 10.2)
          ..lineTo(21.2, 7.2)
          ..lineTo(21.2, 16.8)
          ..lineTo(15.5, 13.8)
          ..close();
        if (duotone) canvas.drawPath(lens, fill);
        canvas.drawPath(lens, stroke);

      case CamelliaGlyph.portTunnel:
      case CamelliaGlyph.emptyTunnels:
        if (duotone) {
          canvas.drawCircle(const Offset(6.0, 12.0), 2.8, fill);
          canvas.drawCircle(const Offset(18.0, 7.0), 2.6, fill);
          canvas.drawCircle(const Offset(18.0, 17.0), 2.6, fill);
        }
        canvas.drawCircle(const Offset(6.0, 12.0), 2.6, stroke);
        canvas.drawCircle(const Offset(18.0, 7.0), 2.4, stroke);
        canvas.drawCircle(const Offset(18.0, 17.0), 2.4, stroke);
        canvas.drawLine(const Offset(8.5, 10.9), const Offset(15.7, 7.9), stroke);
        canvas.drawLine(const Offset(8.5, 13.1), const Offset(15.7, 16.1), stroke);

      case CamelliaGlyph.devices:
      case CamelliaGlyph.emptyDevices:
        final laptop = rr(2.5, 4.5, 14.5, 10.5, 2.0);
        final phone = rr(15.0, 8.5, 6.5, 11.0, 1.8);
        if (duotone) {
          canvas.drawRRect(laptop, fill);
          canvas.drawRRect(phone, fill);
        }
        canvas.drawPath(
          Path()
            ..moveTo(14.5, 15.0)
            ..lineTo(4.5, 15.0)
            ..arcToPoint(const Offset(2.5, 13.0), radius: const Radius.circular(2))
            ..lineTo(2.5, 6.5)
            ..arcToPoint(const Offset(4.5, 4.5), radius: const Radius.circular(2))
            ..lineTo(15.0, 4.5)
            ..arcToPoint(const Offset(17.0, 6.5), radius: const Radius.circular(2))
            ..lineTo(17.0, 8.2),
          stroke,
        );
        canvas.drawLine(const Offset(2.0, 18.0), const Offset(13.0, 18.0), stroke);
        canvas.drawRRect(phone, stroke);
        canvas.drawCircle(const Offset(18.25, 17.2), 0.7, solidFill);

      case CamelliaGlyph.addressBook:
        final book = rr(4.5, 3.5, 15.5, 17.0, 2.4);
        if (duotone) canvas.drawRRect(book, fill);
        canvas.drawRRect(book, stroke);
        canvas.drawLine(const Offset(2.8, 7.5), const Offset(4.8, 7.5), stroke);
        canvas.drawLine(const Offset(2.8, 12.0), const Offset(4.8, 12.0), stroke);
        canvas.drawLine(const Offset(2.8, 16.5), const Offset(4.8, 16.5), stroke);
        canvas.drawCircle(const Offset(12.2, 9.8), 2.1, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(8.6, 16.2)
            ..cubicTo(9.4, 14.0, 15.0, 14.0, 15.8, 16.2),
          stroke,
        );

      case CamelliaGlyph.deviceGroup:
      case CamelliaGlyph.emptyGroups:
        if (duotone) {
          canvas.drawCircle(const Offset(9.2, 9.0), 3.0, fill);
          canvas.drawCircle(const Offset(16.2, 9.8), 2.4, fill);
        }
        canvas.drawCircle(const Offset(9.2, 9.0), 2.9, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(3.8, 18.5)
            ..cubicTo(4.6, 14.8, 13.8, 14.8, 14.6, 18.5),
          stroke,
        );
        canvas.drawCircle(const Offset(16.4, 9.6), 2.3, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(15.6, 14.6)
            ..cubicTo(17.8, 14.8, 19.6, 16.1, 20.2, 18.3),
          stroke,
        );

      case CamelliaGlyph.settings:
      case CamelliaGlyph.sliders:
        canvas.drawLine(const Offset(3.5, 7.0), const Offset(20.5, 7.0), stroke);
        canvas.drawLine(const Offset(3.5, 12.0), const Offset(20.5, 12.0), stroke);
        canvas.drawLine(const Offset(3.5, 17.0), const Offset(20.5, 17.0), stroke);
        final c1 = const Offset(9.0, 7.0);
        final c2 = const Offset(15.5, 12.0);
        final c3 = const Offset(10.5, 17.0);
        if (duotone) {
          canvas.drawCircle(c1, 2.2, fill);
          canvas.drawCircle(c2, 2.2, fill);
          canvas.drawCircle(c3, 2.2, fill);
        }
        canvas.drawCircle(c1, 2.1, stroke);
        canvas.drawCircle(c2, 2.1, stroke);
        canvas.drawCircle(c3, 2.1, stroke);

      case CamelliaGlyph.search:
        if (duotone) canvas.drawCircle(const Offset(10.8, 10.8), 6.4, fill);
        canvas.drawCircle(const Offset(10.8, 10.8), 6.4, stroke);
        canvas.drawLine(const Offset(15.6, 15.6), const Offset(20.4, 20.4), stroke);

      case CamelliaGlyph.commandKey:
        canvas.drawRRect(rr(8.8, 8.8, 6.4, 6.4, 0.8), stroke);
        for (final center in const [
          Offset(6.6, 6.6),
          Offset(17.4, 6.6),
          Offset(6.6, 17.4),
          Offset(17.4, 17.4),
        ]) {
          canvas.drawCircle(center, 2.2, stroke);
        }

      case CamelliaGlyph.shieldCheck:
      case CamelliaGlyph.shieldRelay:
      case CamelliaGlyph.shieldWarn:
        final shield = Path()
          ..moveTo(12.0, 3.0)
          ..lineTo(19.2, 5.8)
          ..lineTo(19.2, 11.4)
          ..cubicTo(19.2, 16.0, 15.9, 19.4, 12.0, 21.0)
          ..cubicTo(8.1, 19.4, 4.8, 16.0, 4.8, 11.4)
          ..lineTo(4.8, 5.8)
          ..close();
        if (duotone) canvas.drawPath(shield, fill);
        canvas.drawPath(shield, stroke);
        if (glyph == CamelliaGlyph.shieldCheck) {
          canvas.drawPath(
            Path()
              ..moveTo(9.0, 12.0)
              ..lineTo(11.1, 14.1)
              ..lineTo(15.2, 9.8),
            stroke,
          );
        } else if (glyph == CamelliaGlyph.shieldRelay) {
          canvas.drawLine(const Offset(8.8, 11.8), const Offset(15.2, 11.8), stroke);
          canvas.drawPath(
            Path()
              ..moveTo(13.3, 9.9)
              ..lineTo(15.2, 11.8)
              ..lineTo(13.3, 13.7),
            stroke,
          );
        } else {
          canvas.drawLine(const Offset(12.0, 8.6), const Offset(12.0, 13.0), stroke);
          canvas.drawCircle(const Offset(12.0, 15.8), 0.9, solidFill);
        }

      case CamelliaGlyph.bolt:
        final bolt = Path()
          ..moveTo(13.2, 3.0)
          ..lineTo(5.6, 13.2)
          ..lineTo(11.8, 13.2)
          ..lineTo(10.8, 21.0)
          ..lineTo(18.4, 10.8)
          ..lineTo(12.2, 10.8)
          ..close();
        if (duotone) canvas.drawPath(bolt, fill);
        canvas.drawPath(bolt, stroke);

      case CamelliaGlyph.keyboard:
        final kb = rr(2.5, 5.5, 19.0, 13.0, 2.4);
        if (duotone) canvas.drawRRect(kb, fill);
        canvas.drawRRect(kb, stroke);
        for (final x in const [6.5, 10.0, 13.5, 17.0]) {
          canvas.drawCircle(Offset(x, 9.5), 0.8, solidFill);
          canvas.drawCircle(Offset(x, 12.6), 0.8, solidFill);
        }
        canvas.drawLine(const Offset(8.0, 15.6), const Offset(16.0, 15.6), stroke);

      case CamelliaGlyph.mouse:
        final m = rr(6.5, 3.0, 11.0, 18.0, 5.5);
        if (duotone) canvas.drawRRect(m, fill);
        canvas.drawRRect(m, stroke);
        canvas.drawLine(const Offset(12.0, 6.8), const Offset(12.0, 10.2), stroke);

      case CamelliaGlyph.trackpad:
        final tp = rr(3.0, 4.5, 18.0, 15.0, 2.6);
        if (duotone) canvas.drawRRect(tp, fill);
        canvas.drawRRect(tp, stroke);
        canvas.drawLine(const Offset(3.0, 15.0), const Offset(21.0, 15.0), stroke);
        canvas.drawLine(const Offset(12.0, 15.0), const Offset(12.0, 19.5), stroke);

      case CamelliaGlyph.audioOn:
      case CamelliaGlyph.audioMute:
        final spk = Path()
          ..moveTo(4.0, 9.5)
          ..lineTo(8.0, 9.5)
          ..lineTo(13.0, 5.5)
          ..lineTo(13.0, 18.5)
          ..lineTo(8.0, 14.5)
          ..lineTo(4.0, 14.5)
          ..close();
        if (duotone) canvas.drawPath(spk, fill);
        canvas.drawPath(spk, stroke);
        if (glyph == CamelliaGlyph.audioOn) {
          canvas.drawArc(
            Rect.fromCircle(center: const Offset(13.5, 12.0), radius: 3.6),
            -0.8,
            1.6,
            false,
            stroke,
          );
          canvas.drawArc(
            Rect.fromCircle(center: const Offset(13.5, 12.0), radius: 6.4),
            -0.8,
            1.6,
            false,
            stroke,
          );
        } else {
          canvas.drawLine(const Offset(16.2, 9.5), const Offset(20.5, 14.5), stroke);
          canvas.drawLine(const Offset(20.5, 9.5), const Offset(16.2, 14.5), stroke);
        }

      case CamelliaGlyph.micOn:
      case CamelliaGlyph.micOff:
        final mic = rr(9.0, 3.5, 6.0, 10.5, 3.0);
        if (duotone) canvas.drawRRect(mic, fill);
        canvas.drawRRect(mic, stroke);
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(12.0, 11.0), radius: 6.0),
          0.15,
          math.pi - 0.30,
          false,
          stroke,
        );
        canvas.drawLine(const Offset(12.0, 17.0), const Offset(12.0, 20.5), stroke);
        if (glyph == CamelliaGlyph.micOff) {
          canvas.drawLine(const Offset(4.0, 4.0), const Offset(20.0, 20.0), stroke);
        }

      case CamelliaGlyph.chat:
        final bubble = Path()
          ..moveTo(5.5, 4.5)
          ..lineTo(18.5, 4.5)
          ..arcToPoint(const Offset(21.0, 7.0), radius: const Radius.circular(2.5))
          ..lineTo(21.0, 15.0)
          ..arcToPoint(const Offset(18.5, 17.5), radius: const Radius.circular(2.5))
          ..lineTo(9.5, 17.5)
          ..lineTo(4.8, 20.5)
          ..lineTo(5.5, 17.5)
          ..arcToPoint(const Offset(3.0, 15.0), radius: const Radius.circular(2.5))
          ..lineTo(3.0, 7.0)
          ..arcToPoint(const Offset(5.5, 4.5), radius: const Radius.circular(2.5))
          ..close();
        if (duotone) canvas.drawPath(bubble, fill);
        canvas.drawPath(bubble, stroke);

      case CamelliaGlyph.phoneCall:
        final call = Path()
          ..moveTo(6.6, 4.0)
          ..lineTo(9.4, 4.0)
          ..lineTo(10.8, 8.2)
          ..lineTo(8.8, 9.8)
          ..cubicTo(9.8, 12.2, 11.8, 14.2, 14.2, 15.2)
          ..lineTo(15.8, 13.2)
          ..lineTo(20.0, 14.6)
          ..lineTo(20.0, 17.4)
          ..arcToPoint(const Offset(17.6, 19.8), radius: const Radius.circular(2.4))
          ..cubicTo(10.2, 19.2, 4.8, 13.8, 4.2, 6.4)
          ..arcToPoint(const Offset(6.6, 4.0), radius: const Radius.circular(2.4))
          ..close();
        if (duotone) canvas.drawPath(call, fill);
        canvas.drawPath(call, stroke);

      case CamelliaGlyph.phoneHangup:
        canvas.drawPath(
          Path()
            ..moveTo(3.0, 14.5)
            ..cubicTo(7.5, 9.5, 16.5, 9.5, 21.0, 14.5)
            ..lineTo(19.2, 17.2)
            ..lineTo(15.8, 15.8)
            ..lineTo(15.2, 13.4)
            ..cubicTo(13.0, 12.8, 11.0, 12.8, 8.8, 13.4)
            ..lineTo(8.2, 15.8)
            ..lineTo(4.8, 17.2)
            ..close(),
          stroke,
        );

      case CamelliaGlyph.lock:
      case CamelliaGlyph.unlock:
        final body = rr(5.0, 10.5, 14.0, 10.0, 2.4);
        if (duotone) canvas.drawRRect(body, fill);
        canvas.drawRRect(body, stroke);
        if (glyph == CamelliaGlyph.lock) {
          canvas.drawPath(
            Path()
              ..moveTo(8.0, 10.5)
              ..lineTo(8.0, 7.5)
              ..arcToPoint(const Offset(16.0, 7.5), radius: const Radius.circular(4.0))
              ..lineTo(16.0, 10.5),
            stroke,
          );
        } else {
          canvas.drawPath(
            Path()
              ..moveTo(8.0, 10.5)
              ..lineTo(8.0, 7.2)
              ..arcToPoint(const Offset(15.8, 6.2), radius: const Radius.circular(4.0)),
            stroke,
          );
        }
        canvas.drawCircle(const Offset(12.0, 15.5), 1.2, solidFill);

      case CamelliaGlyph.key:
        if (duotone) canvas.drawCircle(const Offset(8.5, 14.5), 4.2, fill);
        canvas.drawCircle(const Offset(8.5, 14.5), 4.2, stroke);
        canvas.drawLine(const Offset(11.6, 11.4), const Offset(19.8, 3.8), stroke);
        canvas.drawLine(const Offset(16.6, 6.8), const Offset(19.0, 9.2), stroke);
        canvas.drawLine(const Offset(19.0, 4.5), const Offset(20.8, 6.4), stroke);

      case CamelliaGlyph.copy:
        final frontRect = rr(8.0, 8.0, 12.0, 12.0, 2.2);
        if (duotone) canvas.drawRRect(frontRect, fill);
        canvas.drawRRect(frontRect, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(16.0, 8.0)
            ..lineTo(16.0, 6.2)
            ..arcToPoint(const Offset(13.8, 4.0), radius: const Radius.circular(2.2))
            ..lineTo(6.2, 4.0)
            ..arcToPoint(const Offset(4.0, 6.2), radius: const Radius.circular(2.2))
            ..lineTo(4.0, 13.8)
            ..arcToPoint(const Offset(6.2, 16.0), radius: const Radius.circular(2.2))
            ..lineTo(8.0, 16.0),
          stroke,
        );

      case CamelliaGlyph.check:
        canvas.drawPath(
          Path()
            ..moveTo(4.8, 12.4)
            ..lineTo(9.6, 17.2)
            ..lineTo(19.2, 7.2),
          stroke,
        );

      case CamelliaGlyph.paste:
        final board = rr(5.0, 5.5, 14.0, 15.0, 2.2);
        if (duotone) canvas.drawRRect(board, fill);
        canvas.drawRRect(board, stroke);
        canvas.drawRRect(rr(9.0, 3.5, 6.0, 3.6, 1.4), stroke);

      case CamelliaGlyph.refresh:
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(12.0, 12.0), radius: 7.4),
          0.45,
          2 * math.pi - 1.15,
          false,
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(19.4, 4.8)
            ..lineTo(19.4, 9.2)
            ..lineTo(15.0, 9.2),
          stroke,
        );

      case CamelliaGlyph.plus:
        canvas.drawLine(const Offset(12.0, 5.0), const Offset(12.0, 19.0), stroke);
        canvas.drawLine(const Offset(5.0, 12.0), const Offset(19.0, 12.0), stroke);

      case CamelliaGlyph.close:
        canvas.drawLine(const Offset(6.2, 6.2), const Offset(17.8, 17.8), stroke);
        canvas.drawLine(const Offset(17.8, 6.2), const Offset(6.2, 17.8), stroke);

      case CamelliaGlyph.minimize:
        canvas.drawLine(const Offset(5.5, 12.0), const Offset(18.5, 12.0), stroke);

      case CamelliaGlyph.maximize:
        canvas.drawRRect(rr(5.5, 5.5, 13.0, 13.0, 1.8), stroke);

      case CamelliaGlyph.restore:
        canvas.drawRRect(rr(5.2, 7.8, 11.0, 11.0, 1.6), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(8.5, 7.8)
            ..lineTo(8.5, 6.6)
            ..arcToPoint(const Offset(10.1, 5.0), radius: const Radius.circular(1.6))
            ..lineTo(17.4, 5.0)
            ..arcToPoint(const Offset(19.0, 6.6), radius: const Radius.circular(1.6))
            ..lineTo(19.0, 13.9)
            ..arcToPoint(const Offset(17.4, 15.5), radius: const Radius.circular(1.6))
            ..lineTo(16.2, 15.5),
          stroke,
        );

      case CamelliaGlyph.pin:
      case CamelliaGlyph.unpin:
        final pinHead = Path()
          ..moveTo(9.0, 4.5)
          ..lineTo(15.0, 4.5)
          ..lineTo(16.2, 10.5)
          ..lineTo(18.0, 12.5)
          ..lineTo(6.0, 12.5)
          ..lineTo(7.8, 10.5)
          ..close();
        if (duotone) canvas.drawPath(pinHead, fill);
        canvas.drawPath(pinHead, stroke);
        canvas.drawLine(const Offset(12.0, 12.5), const Offset(12.0, 20.0), stroke);
        if (glyph == CamelliaGlyph.unpin) {
          canvas.drawLine(const Offset(4.5, 4.5), const Offset(19.5, 19.5), stroke);
        }

      case CamelliaGlyph.upload:
        canvas.drawLine(const Offset(12.0, 15.5), const Offset(12.0, 4.5), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(7.8, 8.8)
            ..lineTo(12.0, 4.5)
            ..lineTo(16.2, 8.8),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(4.5, 15.5)
            ..lineTo(4.5, 18.2)
            ..arcToPoint(const Offset(6.5, 20.0), radius: const Radius.circular(1.8))
            ..lineTo(17.5, 20.0)
            ..arcToPoint(const Offset(19.5, 18.2), radius: const Radius.circular(1.8))
            ..lineTo(19.5, 15.5),
          stroke,
        );

      case CamelliaGlyph.download:
        canvas.drawLine(const Offset(12.0, 4.5), const Offset(12.0, 15.5), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(7.8, 11.2)
            ..lineTo(12.0, 15.5)
            ..lineTo(16.2, 11.2),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(4.5, 15.5)
            ..lineTo(4.5, 18.2)
            ..arcToPoint(const Offset(6.5, 20.0), radius: const Radius.circular(1.8))
            ..lineTo(17.5, 20.0)
            ..arcToPoint(const Offset(19.5, 18.2), radius: const Radius.circular(1.8))
            ..lineTo(19.5, 15.5),
          stroke,
        );

      case CamelliaGlyph.swap:
        canvas.drawLine(const Offset(4.5, 8.5), const Offset(19.5, 8.5), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(16.0, 5.2)
            ..lineTo(19.5, 8.5)
            ..lineTo(16.0, 11.8),
          stroke,
        );
        canvas.drawLine(const Offset(19.5, 15.5), const Offset(4.5, 15.5), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(8.0, 12.2)
            ..lineTo(4.5, 15.5)
            ..lineTo(8.0, 18.8),
          stroke,
        );

      case CamelliaGlyph.trash:
        canvas.drawLine(const Offset(4.5, 6.8), const Offset(19.5, 6.8), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(9.2, 6.8)
            ..lineTo(9.2, 4.8)
            ..arcToPoint(const Offset(10.6, 3.6), radius: const Radius.circular(1.2))
            ..lineTo(13.4, 3.6)
            ..arcToPoint(const Offset(14.8, 4.8), radius: const Radius.circular(1.2))
            ..lineTo(14.8, 6.8),
          stroke,
        );
        final bin = rr(6.5, 6.8, 11.0, 13.2, 2.0);
        if (duotone) canvas.drawRRect(bin, fill);
        canvas.drawRRect(bin, stroke);
        canvas.drawLine(const Offset(10.2, 10.6), const Offset(10.2, 16.2), stroke);
        canvas.drawLine(const Offset(13.8, 10.6), const Offset(13.8, 16.2), stroke);

      case CamelliaGlyph.tag:
        final tagPath = Path()
          ..moveTo(4.0, 4.0)
          ..lineTo(11.6, 4.0)
          ..lineTo(20.0, 12.4)
          ..lineTo(12.4, 20.0)
          ..lineTo(4.0, 11.6)
          ..close();
        if (duotone) canvas.drawPath(tagPath, fill);
        canvas.drawPath(tagPath, stroke);
        canvas.drawCircle(const Offset(8.2, 8.2), 1.3, solidFill);

      case CamelliaGlyph.qrCode:
        canvas.drawRRect(rr(4.0, 4.0, 6.5, 6.5, 1.4), stroke);
        canvas.drawRRect(rr(13.5, 4.0, 6.5, 6.5, 1.4), stroke);
        canvas.drawRRect(rr(4.0, 13.5, 6.5, 6.5, 1.4), stroke);
        canvas.drawLine(const Offset(14.0, 14.0), const Offset(14.0, 16.5), stroke);
        canvas.drawLine(const Offset(17.0, 14.0), const Offset(20.0, 14.0), stroke);
        canvas.drawLine(const Offset(14.0, 19.5), const Offset(20.0, 19.5), stroke);
        canvas.drawLine(const Offset(20.0, 16.8), const Offset(20.0, 19.5), stroke);

      case CamelliaGlyph.sparkle:
        final star = Path()
          ..moveTo(12.0, 3.0)
          ..quadraticBezierTo(12.8, 11.2, 21.0, 12.0)
          ..quadraticBezierTo(12.8, 12.8, 12.0, 21.0)
          ..quadraticBezierTo(11.2, 12.8, 3.0, 12.0)
          ..quadraticBezierTo(11.2, 11.2, 12.0, 3.0)
          ..close();
        if (duotone) canvas.drawPath(star, fill);
        canvas.drawPath(star, stroke);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CamelliaGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.duotone != duotone ||
      oldDelegate.duotoneAlpha != duotoneAlpha;
}
