import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camellia_remote_app/ui/brand/portal_mark_spec.dart';
import 'package:image/image.dart' as image;

typedef _Rgb = ({double r, double g, double b});

_Rgb _rgbFromArgb(int argb) => (
  r: ((argb >> 16) & 0xFF) / 255.0,
  g: ((argb >> 8) & 0xFF) / 255.0,
  b: (argb & 0xFF) / 255.0,
);

_Rgb _lerpRgb(_Rgb a, _Rgb b, double t) {
  final u = t.clamp(0.0, 1.0);
  return (
    r: a.r + (b.r - a.r) * u,
    g: a.g + (b.g - a.g) * u,
    b: a.b + (b.b - a.b) * u,
  );
}

final _rearStart = _rgbFromArgb(PortalMarkSpec.rearGradientStartArgb);
final _rearEnd = _rgbFromArgb(PortalMarkSpec.rearGradientEndArgb);
final _frontStart = _rgbFromArgb(PortalMarkSpec.frontGradientStartArgb);
final _frontEnd = _rgbFromArgb(PortalMarkSpec.frontGradientEndArgb);
final _connStart = _rgbFromArgb(PortalMarkSpec.connectorGradientStartArgb);
final _connEnd = _rgbFromArgb(PortalMarkSpec.connectorGradientEndArgb);

final _lightPlateStart = _rgbFromArgb(PortalMarkSpec.lightPlateStartArgb);
final _lightPlateEnd = _rgbFromArgb(PortalMarkSpec.lightPlateEndArgb);
final _lightPlateBorder = _rgbFromArgb(PortalMarkSpec.lightPlateBorderArgb);
final _darkPlateStart = _rgbFromArgb(PortalMarkSpec.darkPlateStartArgb);
final _darkPlateEnd = _rgbFromArgb(PortalMarkSpec.darkPlateEndArgb);
final _darkPlateBorder = _rgbFromArgb(PortalMarkSpec.darkPlateBorderArgb);

const _whiteRgb = (r: 1.0, g: 1.0, b: 1.0);
const _darkInkRgb = (r: 14 / 255.0, g: 17 / 255.0, b: 28 / 255.0);
const _shadowRgb = (r: 12 / 255.0, g: 18 / 255.0, b: 36 / 255.0);

// Optical small-size portal specs (bolder walls & stronger silhouette at 16-36px).
const _opticalRearScreen = PortalRectSpec(0.05, 0.09, 0.60, 0.52, 0.15);
const _opticalRearCutout = PortalRectSpec(0.175, 0.215, 0.35, 0.27, 0.065);
const _opticalFrontScreen = PortalRectSpec(0.35, 0.39, 0.60, 0.52, 0.15);
const _opticalFrontCutout = PortalRectSpec(0.475, 0.515, 0.35, 0.27, 0.065);
const _opticalConnStart = 0.41;
const _opticalConnEnd = 0.59;
const _opticalConnWidth = 0.145;

double _sdRoundedBox(
  double px,
  double py,
  double cx,
  double cy,
  double halfW,
  double halfH,
  double radius,
) {
  final r = radius.clamp(0.0, math.min(halfW, halfH));
  final qx = (px - cx).abs() - (halfW - r);
  final qy = (py - cy).abs() - (halfH - r);
  final ox = math.max(qx, 0.0);
  final oy = math.max(qy, 0.0);
  return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0.0) - r;
}

/// Gradient-normalized superellipse SDF matching Apple's continuous-curvature
/// macOS app icon squircle silhouette.
double _sdSquircle(
  double px,
  double py,
  double cx,
  double cy,
  double halfSide, {
  double exponent = 4.8,
}) {
  final ax = (px - cx).abs() / halfSide;
  final ay = (py - cy).abs() / halfSide;
  if (ax == 0.0 && ay == 0.0) return -halfSide;
  final ux = math.pow(ax, exponent).toDouble();
  final uy = math.pow(ay, exponent).toDouble();
  final sum = ux + uy;
  final norm = math.pow(sum, 1.0 / exponent).toDouble();
  final gx = ax == 0.0 ? 0.0 : math.pow(ax, exponent - 1.0).toDouble();
  final gy = ay == 0.0 ? 0.0 : math.pow(ay, exponent - 1.0).toDouble();
  final gradNorm =
      math.pow(sum, (1.0 - exponent) / exponent).toDouble() *
      math.sqrt(gx * gx + gy * gy);
  return (norm - 1.0) * halfSide / math.max(gradNorm, 1e-6);
}

({double dist, double t}) _sdSegment(
  double px,
  double py,
  double x1,
  double y1,
  double x2,
  double y2,
  double halfWidth,
) {
  final pax = px - x1;
  final pay = py - y1;
  final bax = x2 - x1;
  final bay = y2 - y1;
  final denom = bax * bax + bay * bay;
  final t = denom > 0 ? ((pax * bax + pay * bay) / denom).clamp(0.0, 1.0) : 0.0;
  final dx = pax - bax * t;
  final dy = pay - bay * t;
  return (dist: math.sqrt(dx * dx + dy * dy) - halfWidth, t: t);
}

double _coverage(double sdf, double feather) {
  final t = (0.5 - sdf / feather).clamp(0.0, 1.0);
  // Smoothstep for clean anti-aliased edge transitions.
  return t * t * (3.0 - 2.0 * t);
}

final class _ScaledBox {
  const _ScaledBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.cx,
    required this.cy,
    required this.halfW,
    required this.halfH,
    required this.radius,
  });

  factory _ScaledBox.fromSpec(
    PortalRectSpec spec,
    double originX,
    double originY,
    double side,
  ) {
    final left = originX + spec.left * side;
    final top = originY + spec.top * side;
    final width = spec.width * side;
    final height = spec.height * side;
    return _ScaledBox(
      left: left,
      top: top,
      width: width,
      height: height,
      cx: left + width * 0.5,
      cy: top + height * 0.5,
      halfW: width * 0.5,
      halfH: height * 0.5,
      radius: spec.radius * side,
    );
  }

  final double left;
  final double top;
  final double width;
  final double height;
  final double cx;
  final double cy;
  final double halfW;
  final double halfH;
  final double radius;

  double sdf(double px, double py) =>
      _sdRoundedBox(px, py, cx, cy, halfW, halfH, radius);

  double diagT(double px, double py) =>
      (((px - left) / width) + ((py - top) / height)) * 0.5;

  double topSheen(double px, double py) {
    final ny = ((py - top) / height).clamp(0.0, 1.0);
    if (ny >= 0.55) return 0.0;
    final u = 1.0 - ny / 0.55;
    return u * u * 0.30;
  }
}

enum _PlateStyle {
  /// No plate (transparent background foreground or tray mark).
  none,

  /// Standard rounded Liquid Glass plate (`plateRadius = 0.23`).
  rounded,

  /// Full-bleed opaque square Liquid Glass plate (iOS AppIcon & Web maskable).
  fullBleedOpaque,

  /// Apple macOS HIG squircle plate with ~10% safe margin & ambient drop shadow.
  macOsSquircle,
}

image.Image _renderPortal({
  required int size,
  required _PlateStyle plateStyle,
  bool dark = false,
  bool monochrome = false,
  bool white = false,
  bool opticalSmall = false,
  double? customContentInset,
}) {
  final opaqueRgb = plateStyle == _PlateStyle.fullBleedOpaque;
  final target = image.Image(
    width: size,
    height: size,
    numChannels: opaqueRgb ? 3 : 4,
  );

  // Supersampling grid: 4x4 for crisp small icons, 2x2 for large icons.
  final ss = size <= 128 ? 4 : 2;
  final invSs = 1.0 / ss;
  final invSamples = 1.0 / (ss * ss);
  final feather = math.max(0.55, 1.0 / ss);

  final s = size.toDouble();
  final cx = s * 0.5;
  final cy = s * 0.5;

  // Compute plate bounds and content bounds.
  late final double plateMargin;
  late final double plateSide;
  late final double plateHalf;
  late final double plateRadiusPx;
  late final double contentSide;

  switch (plateStyle) {
    case _PlateStyle.none:
      plateMargin = 0.0;
      plateSide = s;
      plateHalf = s * 0.5;
      plateRadiusPx = 0.0;
      final inset = customContentInset ?? 0.03;
      contentSide = s * (1.0 - inset * 2.0);
    case _PlateStyle.rounded:
      plateMargin = 0.0;
      plateSide = s;
      plateHalf = s * 0.5;
      plateRadiusPx = s * PortalMarkSpec.plateRadius;
      final inset = customContentInset ?? PortalMarkSpec.contentInset;
      contentSide = s * (1.0 - inset * 2.0);
    case _PlateStyle.fullBleedOpaque:
      plateMargin = 0.0;
      plateSide = s;
      plateHalf = s * 0.5;
      plateRadiusPx = 0.0;
      final inset = customContentInset ?? PortalMarkSpec.contentInset;
      contentSide = s * (1.0 - inset * 2.0);
    case _PlateStyle.macOsSquircle:
      plateMargin = s * PortalMarkSpec.macSafeMargin;
      plateSide = s - plateMargin * 2.0;
      plateHalf = plateSide * 0.5;
      plateRadiusPx = plateSide * 0.225;
      final inset = customContentInset ?? PortalMarkSpec.contentInset;
      contentSide = plateSide * (1.0 - inset * 2.0);
  }

  final contentOriginX = cx - contentSide * 0.5;
  final contentOriginY = cy - contentSide * 0.5;

  final rearSpec = opticalSmall
      ? _opticalRearScreen
      : PortalMarkSpec.rearScreen;
  final rearCutSpec = opticalSmall
      ? _opticalRearCutout
      : PortalMarkSpec.rearCutout;
  final frontSpec = opticalSmall
      ? _opticalFrontScreen
      : PortalMarkSpec.frontScreen;
  final frontCutSpec = opticalSmall
      ? _opticalFrontCutout
      : PortalMarkSpec.frontCutout;

  final rearOuter = _ScaledBox.fromSpec(
    rearSpec,
    contentOriginX,
    contentOriginY,
    contentSide,
  );
  final rearCut = _ScaledBox.fromSpec(
    rearCutSpec,
    contentOriginX,
    contentOriginY,
    contentSide,
  );
  final frontOuter = _ScaledBox.fromSpec(
    frontSpec,
    contentOriginX,
    contentOriginY,
    contentSide,
  );
  final frontCut = _ScaledBox.fromSpec(
    frontCutSpec,
    contentOriginX,
    contentOriginY,
    contentSide,
  );

  final connStartNorm = opticalSmall
      ? _opticalConnStart
      : PortalMarkSpec.connectorStartX;
  final connEndNorm = opticalSmall
      ? _opticalConnEnd
      : PortalMarkSpec.connectorEndX;
  final connWidthNorm = opticalSmall
      ? _opticalConnWidth
      : PortalMarkSpec.connectorWidth;

  final connX1 = contentOriginX + connStartNorm * contentSide;
  final connY1 = contentOriginY + connStartNorm * contentSide;
  final connX2 = contentOriginX + connEndNorm * contentSide;
  final connY2 = contentOriginY + connEndNorm * contentSide;
  final connHalfW = connWidthNorm * contentSide * 0.5;

  final plateStart = dark ? _darkPlateStart : _lightPlateStart;
  final plateEnd = dark ? _darkPlateEnd : _lightPlateEnd;
  final plateBorder = dark ? _darkPlateBorder : _lightPlateBorder;
  final monoRgb = white ? _whiteRgb : _darkInkRgb;

  // Rim width for Liquid Glass bevel border.
  final plateRimWidth = math.max(1.2, plateSide * 0.014);
  final shadowOffsetY = s * (18.0 / 1024.0);
  final shadowSigma = s * (26.0 / 1024.0);
  final contactOffsetY = s * (6.0 / 1024.0);
  final contactSigma = s * (8.5 / 1024.0);

  // Subtle clearance halo behind front screen in monochrome mode so overlapping
  // frames maintain crisp silhouette separation at 16-36px and Android status bar.
  final monoKnockoutGap = monochrome ? contentSide * 0.042 : 0.0;
  final shadowCutoff = shadowSigma * 3.0 + shadowOffsetY;
  final markMinX = contentOriginX - feather * 2.0;
  final markMaxX = contentOriginX + contentSide + feather * 2.0;
  final markMinY = contentOriginY - feather * 2.0;
  final markMaxY = contentOriginY + contentSide + feather * 2.0;

  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var accR = 0.0;
      var accG = 0.0;
      var accB = 0.0;
      var accA = 0.0;

      for (var sy = 0; sy < ss; sy++) {
        final y = py + (sy + 0.5) * invSs;
        for (var sx = 0; sx < ss; sx++) {
          final x = px + (sx + 0.5) * invSs;

          // Premultiplied sample accumulator.
          var r = 0.0;
          var g = 0.0;
          var b = 0.0;
          var a = 0.0;

          void composite(_Rgb col, double alpha) {
            if (alpha <= 0.0) return;
            final clamped = alpha >= 1.0 ? 1.0 : alpha;
            final inv = 1.0 - clamped;
            r = col.r * clamped + r * inv;
            g = col.g * clamped + g * inv;
            b = col.b * clamped + b * inv;
            a = clamped + a * inv;
          }

          // 1 & 2. Liquid Glass Plate + macOS Ambient Drop Shadow.
          if (plateStyle != _PlateStyle.none) {
            final double dPlate;
            switch (plateStyle) {
              case _PlateStyle.fullBleedOpaque:
                dPlate = -1000.0;
              case _PlateStyle.rounded:
                dPlate = _sdRoundedBox(
                  x,
                  y,
                  cx,
                  cy,
                  plateHalf,
                  plateHalf,
                  plateRadiusPx,
                );
              case _PlateStyle.macOsSquircle:
                dPlate = _sdSquircle(x, y, cx, cy, plateHalf);
              case _PlateStyle.none:
                dPlate = 1000.0;
            }

            final plateCov = plateStyle == _PlateStyle.fullBleedOpaque
                ? 1.0
                : _coverage(dPlate, feather);

            // Only evaluate macOS drop shadow where plate is not fully opaque.
            if (plateStyle == _PlateStyle.macOsSquircle &&
                plateCov < 1.0 &&
                dPlate < shadowCutoff) {
              final dAmbient = _sdSquircle(
                x,
                y - shadowOffsetY,
                cx,
                cy,
                plateHalf,
              );
              if (dAmbient < shadowSigma * 3.0) {
                final dPos = math.max(0.0, dAmbient);
                final ambientAlpha =
                    0.23 *
                    math.exp(-(dPos * dPos) / (shadowSigma * shadowSigma));
                composite(_shadowRgb, ambientAlpha);
              }
              final dContact = _sdSquircle(
                x,
                y - contactOffsetY,
                cx,
                cy,
                plateHalf,
              );
              if (dContact < contactSigma * 3.0) {
                final dPos = math.max(0.0, dContact);
                final contactAlpha =
                    0.13 *
                    math.exp(-(dPos * dPos) / (contactSigma * contactSigma));
                composite(_shadowRgb, contactAlpha);
              }
            }

            if (plateCov > 0.0) {
              final nx = ((x - plateMargin) / plateSide).clamp(0.0, 1.0);
              final ny = ((y - plateMargin) / plateSide).clamp(0.0, 1.0);
              final diagT = (nx + ny) * 0.5;
              var plateCol = _lerpRgb(plateStart, plateEnd, diagT);

              // Soft radial top-surface Liquid Glass specular sheen.
              if (ny < 0.54) {
                final uy = 1.0 - ny / 0.54;
                final dxCenter = (nx - 0.5) * 1.15;
                final radial = math.max(0.0, 1.0 - dxCenter * dxCenter * 0.45);
                final sheenStrength = (dark ? 0.16 : 0.66) * uy * uy * radial;
                plateCol = _lerpRgb(plateCol, _whiteRgb, sheenStrength);
              }

              // Subtle bottom ambient cool tint for depth.
              if (ny > 0.72) {
                final by = (ny - 0.72) / 0.28;
                final bottomTint = dark
                    ? const (r: 0.03, g: 0.05, b: 0.12)
                    : const (r: 0.85, g: 0.89, b: 0.99);
                plateCol = _lerpRgb(
                  plateCol,
                  bottomTint,
                  by * by * (dark ? 0.25 : 0.30),
                );
              }

              // Luminous bevel border on rounded & macOS squircle plates.
              if (plateStyle != _PlateStyle.fullBleedOpaque &&
                  dPlate > -plateRimWidth * 1.4) {
                final innerRimCov = _coverage(
                  -(dPlate + plateRimWidth),
                  feather,
                );
                final rimFactor = innerRimCov.clamp(0.0, 1.0);
                if (rimFactor > 0.0) {
                  final topHighlight = math.max(0.0, 1.0 - ny * 1.45);
                  final rimCol = _lerpRgb(
                    plateBorder,
                    _whiteRgb,
                    dark
                        ? topHighlight * topHighlight * 0.46
                        : 0.32 + topHighlight * 0.68,
                  );
                  plateCol = _lerpRgb(
                    plateCol,
                    rimCol,
                    rimFactor * (dark ? 0.78 : 0.88),
                  );
                }
              }

              composite(plateCol, plateCov);
            }
          }

          // Skip portal mark SDFs outside the mark bounding box.
          if (x >= markMinX &&
              x <= markMaxX &&
              y >= markMinY &&
              y <= markMaxY) {
            // 3. Rear Screen Frame (Glacier-Aqua #0EA5E9 -> #06B6D4).
            final dRearOuter = rearOuter.sdf(x, y);
            final dFrontOuter = frontOuter.sdf(x, y);
            if (dRearOuter < feather) {
              final dRearInner = rearCut.sdf(x, y);
              var dRearFrame = math.max(dRearOuter, -dRearInner);
              if (monochrome && monoKnockoutGap > 0.0) {
                dRearFrame = math.max(
                  dRearFrame,
                  -(dFrontOuter - monoKnockoutGap),
                );
              }
              final rearCov = _coverage(dRearFrame, feather);
              if (rearCov > 0.0) {
                if (monochrome) {
                  composite(monoRgb, rearCov);
                } else {
                  var col = _lerpRgb(
                    _rearStart,
                    _rearEnd,
                    rearOuter.diagT(x, y),
                  );
                  final sheen = rearOuter.topSheen(x, y);
                  if (sheen > 0.0) {
                    col = _lerpRgb(col, _whiteRgb, sheen);
                  }
                  composite(col, rearCov);
                }
              }
            }

            // 4. Luminous Rose-Coral -> Indigo Connector (#FF5C7A -> #6366F1).
            final seg = _sdSegment(
              x,
              y,
              connX1,
              connY1,
              connX2,
              connY2,
              connHalfW,
            );
            final connCov = _coverage(seg.dist, feather);
            if (connCov > 0.0) {
              if (monochrome) {
                composite(monoRgb, connCov);
              } else {
                var col = _lerpRgb(_connStart, _connEnd, seg.t);
                // Gentle cylindrical specular glint along connector center.
                final centerRatio =
                    (1.0 - (seg.dist + connHalfW) / math.max(connHalfW, 1.0))
                        .clamp(0.0, 1.0);
                col = _lerpRgb(
                  col,
                  _whiteRgb,
                  centerRatio * centerRatio * 0.22,
                );
                composite(col, connCov);
              }
            }

            // 5. Front Screen Frame (Sapphire-Indigo #4F46E5 -> #7C3AED).
            if (dFrontOuter < feather) {
              final dFrontInner = frontCut.sdf(x, y);
              final dFrontFrame = math.max(dFrontOuter, -dFrontInner);
              final frontCov = _coverage(dFrontFrame, feather);
              if (frontCov > 0.0) {
                if (monochrome) {
                  composite(monoRgb, frontCov);
                } else {
                  var col = _lerpRgb(
                    _frontStart,
                    _frontEnd,
                    frontOuter.diagT(x, y),
                  );
                  final sheen = frontOuter.topSheen(x, y);
                  if (sheen > 0.0) {
                    col = _lerpRgb(col, _whiteRgb, sheen);
                  }
                  composite(col, frontCov);
                }
              }
            }
          }

          accR += r;
          accG += g;
          accB += b;
          accA += a;
        }
      }

      final avgA = (accA * invSamples).clamp(0.0, 1.0);
      if (opaqueRgb) {
        final outR = (accR * invSamples * 255.0).round().clamp(0, 255);
        final outG = (accG * invSamples * 255.0).round().clamp(0, 255);
        final outB = (accB * invSamples * 255.0).round().clamp(0, 255);
        target.setPixelRgb(px, py, outR, outG, outB);
      } else if (avgA <= 1e-6) {
        target.setPixelRgba(px, py, 0, 0, 0, 0);
      } else {
        final invA = invSamples / avgA;
        final outR = (accR * invA * 255.0).round().clamp(0, 255);
        final outG = (accG * invA * 255.0).round().clamp(0, 255);
        final outB = (accB * invA * 255.0).round().clamp(0, 255);
        final outA = (avgA * 255.0).round().clamp(0, 255);
        target.setPixelRgba(px, py, outR, outG, outB, outA);
      }
    }
  }

  return target;
}

image.Image _renderAppIcon(
  int size, {
  bool dark = false,
  bool opticalSmall = false,
}) => _renderPortal(
  size: size,
  plateStyle: _PlateStyle.rounded,
  dark: dark,
  opticalSmall: opticalSmall || size <= 36,
);

image.Image _renderMacIcon(int size) => _renderPortal(
  size: size,
  plateStyle: _PlateStyle.macOsSquircle,
  opticalSmall: size <= 36,
);

image.Image _renderIosOpaqueIcon(int size) => _renderPortal(
  size: size,
  plateStyle: _PlateStyle.fullBleedOpaque,
  opticalSmall: size <= 40,
);

image.Image _renderMaskableIcon(int size) => _renderPortal(
  size: size,
  plateStyle: _PlateStyle.fullBleedOpaque,
  customContentInset: PortalMarkSpec.maskableInset,
);

image.Image _renderForegroundMark(
  int size, {
  bool monochrome = false,
  bool white = false,
  bool opticalSmall = false,
  double contentInset = 0.06,
}) => _renderPortal(
  size: size,
  plateStyle: _PlateStyle.none,
  monochrome: monochrome,
  white: white,
  opticalSmall: opticalSmall,
  customContentInset: contentInset,
);

void _writeBytes(String path, List<int> bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

void _writePng(String path, image.Image value) {
  _writeBytes(path, image.encodePng(value));
}

Uint8List _encodeMultiSizeIco(
  List<int> sizes,
  image.Image Function(int size) renderer,
) {
  final first = renderer(sizes.first);
  for (final size in sizes.skip(1)) {
    first.addFrame(renderer(size));
  }
  return Uint8List.fromList(image.encodeIco(first));
}

Uint8List _uint32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

void _writeIcns(String path, image.Image mac1024) {
  const chunks = <(String, int)>[
    ('icp4', 16),
    ('icp5', 32),
    ('icp6', 64),
    ('ic07', 128),
    ('ic08', 256),
    ('ic09', 512),
    ('ic10', 1024),
    ('ic11', 32),
    ('ic12', 64),
    ('ic13', 256),
    ('ic14', 512),
  ];

  // Cache rendered sizes so duplicate Retina/standard sizes reuse identical PNGs.
  final pngCache = <int, Uint8List>{
    1024: Uint8List.fromList(image.encodePng(mac1024)),
  };
  Uint8List pngFor(int size) => pngCache.putIfAbsent(size, () {
    final rendered = size <= 128
        ? _renderMacIcon(size)
        : image.copyResize(
            mac1024,
            width: size,
            height: size,
            interpolation: image.Interpolation.cubic,
          );
    return Uint8List.fromList(image.encodePng(rendered));
  });

  final encoded = <(String, Uint8List)>[
    for (final (type, size) in chunks) (type, pngFor(size)),
  ];
  final totalLength =
      8 + encoded.fold<int>(0, (sum, entry) => sum + 8 + entry.$2.length);
  final output = BytesBuilder(copy: false)
    ..add('icns'.codeUnits)
    ..add(_uint32(totalLength));
  for (final (type, bytes) in encoded) {
    output
      ..add(type.codeUnits)
      ..add(_uint32(bytes.length + 8))
      ..add(bytes);
  }
  _writeBytes(path, output.takeBytes());
}

void _writeVectorAssets() {
  final markSvg = PortalMarkSpec.svg();
  for (final path in [
    '../res/camellia-mark.svg',
    '../res/scalable.svg',
    'assets/icon.svg',
    'web/favicon.svg',
  ]) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(markSvg);
  }
}

void _writeIosOpaqueIconSet(String directory) {
  final manifestFile = File('$directory/Contents.json');
  if (!manifestFile.existsSync()) return;
  final manifest = jsonDecode(manifestFile.readAsStringSync());
  final ios1024 = _renderIosOpaqueIcon(1024);
  final encodedCache = <int, List<int>>{1024: image.encodePng(ios1024)};

  List<int> pngFor(int pixels) => encodedCache.putIfAbsent(pixels, () {
    final rendered = pixels <= 256
        ? _renderIosOpaqueIcon(pixels)
        : image.copyResize(
            ios1024,
            width: pixels,
            height: pixels,
            interpolation: image.Interpolation.cubic,
          );
    assert(rendered.numChannels == 3, 'iOS AppIcon must be 3-channel RGB');
    return image.encodePng(rendered);
  });

  for (final entry in manifest['images'] as List<dynamic>) {
    if (entry is! Map<String, dynamic>) continue;
    final filename = entry['filename'];
    final logicalSize = entry['size'];
    final scaleText = entry['scale'];
    if (filename is! String || logicalSize is! String || scaleText is! String) {
      continue;
    }
    final points = double.tryParse(logicalSize.split('x').first);
    final scale = double.tryParse(scaleText.replaceAll('x', ''));
    if (points == null || scale == null) continue;
    final pixels = (points * scale).round();
    _writeBytes('$directory/$filename', pngFor(pixels));
  }
}

void main() {
  final app1024 = _renderAppIcon(1024);
  final darkApp1024 = _renderAppIcon(1024, dark: true);
  final mac1024 = _renderMacIcon(1024);

  // Shared high-resolution desktop & brand marks.
  _writePng('../res/icon.png', app1024);
  _writePng('../res/mac-icon.png', mac1024);
  _writePng(
    '../res/android-foreground.png',
    _renderForegroundMark(1024, contentInset: 0.06),
  );
  _writePng(
    '../res/android-monochrome.png',
    _renderForegroundMark(
      1024,
      monochrome: true,
      white: true,
      contentInset: 0.06,
    ),
  );

  // Windows multi-size ICO (identical across MSI, primary runner, and multi-window plugin).
  const windowsIcoSizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
  final windowsIcoBytes = _encodeMultiSizeIco(
    windowsIcoSizes,
    (size) => size <= 128
        ? _renderAppIcon(size)
        : image.copyResize(
            app1024,
            width: size,
            height: size,
            interpolation: image.Interpolation.cubic,
          ),
  );
  _writeBytes('../res/icon.ico', windowsIcoBytes);
  _writeBytes('windows/runner/resources/app_icon.ico', windowsIcoBytes);
  _writeBytes(
    'plugins/desktop_multi_window/windows/resources/app_icon.ico',
    windowsIcoBytes,
  );

  // macOS HIG squircle AppIcon.icns.
  _writeIcns('macos/Runner/AppIcon.icns', mac1024);

  // iOS 100% opaque 3-channel RGB AppIcon.appiconset (ITMS-90717 compliant).
  _writeIosOpaqueIconSet('ios/Runner/Assets.xcassets/AppIcon.appiconset');

  // Linux / desktop PNG sizes.
  for (final size in [32, 64, 128]) {
    _writePng('../res/${size}x$size.png', _renderAppIcon(size));
  }
  _writePng(
    '../res/128x128@2x.png',
    image.copyResize(
      app1024,
      width: 256,
      height: 256,
      interpolation: image.Interpolation.cubic,
    ),
  );

  // Optical small-size tray icons (crisp 16-36px silhouette).
  const trayIcoSizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
  final trayIcoBytes = _encodeMultiSizeIco(
    trayIcoSizes,
    (size) =>
        _renderForegroundMark(size, opticalSmall: true, contentInset: 0.02),
  );
  _writeBytes('../res/tray-icon.ico', trayIcoBytes);
  _writePng(
    '../res/tray-icon.png',
    _renderForegroundMark(64, opticalSmall: true, contentInset: 0.02),
  );
  _writePng(
    '../res/mac-tray-dark-x2.png',
    _renderForegroundMark(
      36,
      monochrome: true,
      white: false,
      opticalSmall: true,
      contentInset: 0.04,
    ),
  );
  _writePng(
    '../res/mac-tray-light-x2.png',
    _renderForegroundMark(
      36,
      monochrome: true,
      white: true,
      opticalSmall: true,
      contentInset: 0.04,
    ),
  );

  // Android notification status bar monochrome icons.
  const androidStatDensities = {
    'mdpi': 24,
    'hdpi': 36,
    'xhdpi': 48,
    'xxhdpi': 72,
    'xxxhdpi': 96,
  };
  for (final entry in androidStatDensities.entries) {
    _writePng(
      'android/app/src/main/res/mipmap-${entry.key}/ic_stat_logo.png',
      _renderForegroundMark(
        entry.value,
        monochrome: true,
        white: true,
        opticalSmall: entry.value <= 48,
        contentInset: 0.05,
      ),
    );
  }

  // Android legacy launcher icons.
  const androidLegacyLauncherDensities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  for (final entry in androidLegacyLauncherDensities.entries) {
    _writePng(
      'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
      entry.value <= 128
          ? _renderAppIcon(entry.value)
          : image.copyResize(
              app1024,
              width: entry.value,
              height: entry.value,
              interpolation: image.Interpolation.cubic,
            ),
    );
  }

  // Android adaptive icon layered foreground & monochrome drawables.
  // mipmap-anydpi-v26/ic_launcher*.xml applies a 16% inset; using 0.06 inner
  // padding places the mark cleanly inside the 66dp safe circle.
  const androidLauncherDensities = {
    'mdpi': 108,
    'hdpi': 162,
    'xhdpi': 216,
    'xxhdpi': 324,
    'xxxhdpi': 432,
  };
  for (final entry in androidLauncherDensities.entries) {
    final directory = 'android/app/src/main/res/drawable-${entry.key}';
    _writePng(
      '$directory/ic_launcher_foreground.png',
      _renderForegroundMark(entry.value, contentInset: 0.06),
    );
    _writePng(
      '$directory/ic_launcher_monochrome.png',
      _renderForegroundMark(
        entry.value,
        monochrome: true,
        white: true,
        contentInset: 0.06,
      ),
    );
  }

  // In-app bundled brand mark PNGs (light & dark Liquid Glass plates).
  _writePng('assets/brand-mark.png', app1024);
  _writePng('assets/brand-mark-dark.png', darkApp1024);

  // Web PWA icons: standard rounded icons + distinct full-bleed opaque maskable icons.
  _writePng('web/favicon.png', _renderAppIcon(32, opticalSmall: true));
  for (final size in [192, 512]) {
    _writePng(
      'web/icons/Icon-$size.png',
      image.copyResize(
        app1024,
        width: size,
        height: size,
        interpolation: image.Interpolation.cubic,
      ),
    );
    _writePng('web/icons/Icon-maskable-$size.png', _renderMaskableIcon(size));
  }

  _writeVectorAssets();
}
