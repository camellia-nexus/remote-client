/// Geometry and brand palette shared by the runtime painter, vector exports,
/// and the multi-platform asset generator.
///
/// Values are normalized to a 1 x 1 canvas so every platform artifact is
/// derived from the same source instead of maintaining separate drawings.
final class PortalRectSpec {
  const PortalRectSpec(
    this.left,
    this.top,
    this.width,
    this.height,
    this.radius,
  );

  final double left;
  final double top;
  final double width;
  final double height;
  final double radius;
}

abstract final class PortalMarkSpec {
  static const rearScreen = PortalRectSpec(0.08, 0.12, 0.58, 0.50, 0.15);
  static const rearCutout = PortalRectSpec(0.17, 0.21, 0.40, 0.32, 0.09);
  static const frontScreen = PortalRectSpec(0.34, 0.38, 0.58, 0.50, 0.15);
  static const frontCutout = PortalRectSpec(0.43, 0.47, 0.40, 0.32, 0.09);

  static const connectorStartX = 0.43;
  static const connectorStartY = 0.43;
  static const connectorEndX = 0.57;
  static const connectorEndY = 0.57;
  static const connectorWidth = 0.12;

  static const plateRadius = 0.23;
  static const contentInset = 0.12;
  static const adaptiveForegroundInset = 0.20;
  static const maskableInset = 0.20;
  static const macSafeMargin = 100 / 1024;

  // Unified Camellia Liquid Glass brand palette.
  static const rearGradientStartHex = '#0EA5E9';
  static const rearGradientEndHex = '#06B6D4';
  static const frontGradientStartHex = '#4F46E5';
  static const frontGradientEndHex = '#7C3AED';
  static const connectorGradientStartHex = '#FF5C7A';
  static const connectorGradientEndHex = '#6366F1';

  static const lightPlateStartHex = '#F8FAFF';
  static const lightPlateEndHex = '#E8EEFF';
  static const lightPlateBorderHex = '#D2DCF6';
  static const darkPlateStartHex = '#141B2E';
  static const darkPlateEndHex = '#0B1020';
  static const darkPlateBorderHex = '#2E3B5C';

  static const rearGradientStartArgb = 0xFF0EA5E9;
  static const rearGradientEndArgb = 0xFF06B6D4;
  static const frontGradientStartArgb = 0xFF4F46E5;
  static const frontGradientEndArgb = 0xFF7C3AED;
  static const connectorGradientStartArgb = 0xFFFF5C7A;
  static const connectorGradientEndArgb = 0xFF6366F1;

  static const lightPlateStartArgb = 0xFFF8FAFF;
  static const lightPlateEndArgb = 0xFFE8EEFF;
  static const lightPlateBorderArgb = 0xFFD2DCF6;
  static const darkPlateStartArgb = 0xFF141B2E;
  static const darkPlateEndArgb = 0xFF0B1020;
  static const darkPlateBorderArgb = 0xFF2E3B5C;

  static String _fmt(double value) {
    final rounded = (value * 10).round() / 10;
    if (rounded == rounded.roundToDouble()) {
      return rounded.round().toString();
    }
    return rounded.toStringAsFixed(1);
  }

  static String _roundedRectPath(
    double x,
    double y,
    double w,
    double h,
    double r, {
    required bool clockwise,
  }) {
    final radius = r.clamp(0.0, (w < h ? w : h) / 2);
    final x0 = _fmt(x);
    final y0 = _fmt(y);
    final x1 = _fmt(x + w);
    final y1 = _fmt(y + h);
    final xr0 = _fmt(x + radius);
    final xr1 = _fmt(x + w - radius);
    final yr0 = _fmt(y + radius);
    final yr1 = _fmt(y + h - radius);
    final rf = _fmt(radius);

    if (clockwise) {
      return 'M$xr0 $y0'
          'H$xr1'
          'A$rf $rf 0 0 1 $x1 $yr0'
          'V$yr1'
          'A$rf $rf 0 0 1 $xr1 $y1'
          'H$xr0'
          'A$rf $rf 0 0 1 $x0 $yr1'
          'V$yr0'
          'A$rf $rf 0 0 1 $xr0 $y0'
          'Z';
    }
    return 'M$xr0 $y0'
        'A$rf $rf 0 0 0 $x0 $yr0'
        'V$yr1'
        'A$rf $rf 0 0 0 $xr0 $y1'
        'H$xr1'
        'A$rf $rf 0 0 0 $x1 $yr1'
        'V$yr0'
        'A$rf $rf 0 0 0 $xr1 $y0'
        'H$xr0'
        'Z';
  }

  /// Builds a universally supported compound `evenodd` path for a hollow
  /// rounded portal screen frame (outer contour clockwise, inner cutout
  /// counter-clockwise).
  static String framePathData(
    PortalRectSpec outer,
    PortalRectSpec inner, {
    double inset = contentInset,
    double canvasSize = 1024,
  }) {
    final contentSide = (1 - inset * 2) * canvasSize;
    final origin = inset * canvasSize;
    final outerPath = _roundedRectPath(
      origin + outer.left * contentSide,
      origin + outer.top * contentSide,
      outer.width * contentSide,
      outer.height * contentSide,
      outer.radius * contentSide,
      clockwise: true,
    );
    final innerPath = _roundedRectPath(
      origin + inner.left * contentSide,
      origin + inner.top * contentSide,
      inner.width * contentSide,
      inner.height * contentSide,
      inner.radius * contentSide,
      clockwise: false,
    );
    return '$outerPath $innerPath';
  }

  static ({
    String rearPath,
    String frontPath,
    String rearX1,
    String rearY1,
    String rearX2,
    String rearY2,
    String frontX1,
    String frontY1,
    String frontX2,
    String frontY2,
    String connX1,
    String connY1,
    String connX2,
    String connY2,
    String connWidth,
  })
  _portalGeometry({required double inset, double canvasSize = 1024}) {
    final contentSide = (1 - inset * 2) * canvasSize;
    final origin = inset * canvasSize;
    return (
      rearPath: framePathData(
        rearScreen,
        rearCutout,
        inset: inset,
        canvasSize: canvasSize,
      ),
      frontPath: framePathData(
        frontScreen,
        frontCutout,
        inset: inset,
        canvasSize: canvasSize,
      ),
      rearX1: _fmt(origin + rearScreen.left * contentSide),
      rearY1: _fmt(origin + rearScreen.top * contentSide),
      rearX2: _fmt(origin + (rearScreen.left + rearScreen.width) * contentSide),
      rearY2: _fmt(origin + (rearScreen.top + rearScreen.height) * contentSide),
      frontX1: _fmt(origin + frontScreen.left * contentSide),
      frontY1: _fmt(origin + frontScreen.top * contentSide),
      frontX2: _fmt(
        origin + (frontScreen.left + frontScreen.width) * contentSide,
      ),
      frontY2: _fmt(
        origin + (frontScreen.top + frontScreen.height) * contentSide,
      ),
      connX1: _fmt(origin + connectorStartX * contentSide),
      connY1: _fmt(origin + connectorStartY * contentSide),
      connX2: _fmt(origin + connectorEndX * contentSide),
      connY2: _fmt(origin + connectorEndY * contentSide),
      connWidth: _fmt(connectorWidth * contentSide),
    );
  }

  /// Full Camellia Portal Mark SVG with Liquid Glass plate, specular top
  /// highlight, and `fill-rule="evenodd"` compound screen frames.
  static String svg({bool monochrome = false, bool dark = false}) {
    final g = _portalGeometry(inset: contentInset);
    final plateRadiusPx = _fmt(plateRadius * 1024);
    final plateStart = dark ? darkPlateStartHex : lightPlateStartHex;
    final plateEnd = dark ? darkPlateEndHex : lightPlateEndHex;
    final plateBorder = dark ? darkPlateBorderHex : lightPlateBorderHex;
    final sheenOpacity = dark ? '0.14' : '0.62';
    final rimStartOpacity = dark ? '0.32' : '0.88';

    if (monochrome) {
      return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <path d="${g.rearPath}" fill="#ffffff" fill-rule="evenodd"/>
  <path d="M${g.connX1} ${g.connY1} L${g.connX2} ${g.connY2}" stroke="#ffffff" stroke-width="${g.connWidth}" stroke-linecap="round"/>
  <path d="${g.frontPath}" fill="#ffffff" fill-rule="evenodd"/>
</svg>''';
    }

    return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="plate" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="1024" y2="1024">
      <stop offset="0" stop-color="$plateStart"/>
      <stop offset="1" stop-color="$plateEnd"/>
    </linearGradient>
    <linearGradient id="plate-specular" gradientUnits="userSpaceOnUse" x1="512" y1="0" x2="512" y2="480">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="$sheenOpacity"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="plate-rim" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="1024" y2="1024">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="$rimStartOpacity"/>
      <stop offset="1" stop-color="$plateBorder" stop-opacity="0.92"/>
    </linearGradient>
    <linearGradient id="rear" gradientUnits="userSpaceOnUse" x1="${g.rearX1}" y1="${g.rearY1}" x2="${g.rearX2}" y2="${g.rearY2}">
      <stop offset="0" stop-color="$rearGradientStartHex"/>
      <stop offset="1" stop-color="$rearGradientEndHex"/>
    </linearGradient>
    <linearGradient id="connector" gradientUnits="userSpaceOnUse" x1="${g.connX1}" y1="${g.connY1}" x2="${g.connX2}" y2="${g.connY2}">
      <stop offset="0" stop-color="$connectorGradientStartHex"/>
      <stop offset="1" stop-color="$connectorGradientEndHex"/>
    </linearGradient>
    <linearGradient id="front" gradientUnits="userSpaceOnUse" x1="${g.frontX1}" y1="${g.frontY1}" x2="${g.frontX2}" y2="${g.frontY2}">
      <stop offset="0" stop-color="$frontGradientStartHex"/>
      <stop offset="1" stop-color="$frontGradientEndHex"/>
    </linearGradient>
    <linearGradient id="frame-specular" gradientUnits="userSpaceOnUse" x1="512" y1="180" x2="512" y2="620">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.34"/>
      <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.06"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="$plateRadiusPx" fill="url(#plate)"/>
  <rect x="8" y="8" width="1008" height="1008" rx="${_fmt(plateRadius * 1024 - 6)}" fill="url(#plate-specular)"/>
  <rect x="10" y="10" width="1004" height="1004" rx="${_fmt(plateRadius * 1024 - 8)}" fill="none" stroke="url(#plate-rim)" stroke-width="12"/>
  <path d="${g.rearPath}" fill="url(#rear)" fill-rule="evenodd"/>
  <path d="${g.rearPath}" fill="url(#frame-specular)" fill-rule="evenodd"/>
  <path d="M${g.connX1} ${g.connY1} L${g.connX2} ${g.connY2}" stroke="url(#connector)" stroke-width="${g.connWidth}" stroke-linecap="round"/>
  <path d="${g.frontPath}" fill="url(#front)" fill-rule="evenodd"/>
  <path d="${g.frontPath}" fill="url(#frame-specular)" fill-rule="evenodd"/>
</svg>''';
  }

  /// Transparent-background foreground SVG sized for adaptive launcher masks
  /// and glass overlays, with Liquid Glass specular depth and zero `<mask>`
  /// dependencies.
  static String adaptiveForegroundSvg({
    bool monochrome = false,
    double inset = adaptiveForegroundInset,
  }) {
    final g = _portalGeometry(inset: inset);
    if (monochrome) {
      return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <path d="${g.rearPath}" fill="#ffffff" fill-rule="evenodd"/>
  <path d="M${g.connX1} ${g.connY1} L${g.connX2} ${g.connY2}" stroke="#ffffff" stroke-width="${g.connWidth}" stroke-linecap="round"/>
  <path d="${g.frontPath}" fill="#ffffff" fill-rule="evenodd"/>
</svg>''';
    }

    return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="rear" gradientUnits="userSpaceOnUse" x1="${g.rearX1}" y1="${g.rearY1}" x2="${g.rearX2}" y2="${g.rearY2}">
      <stop offset="0" stop-color="$rearGradientStartHex"/>
      <stop offset="1" stop-color="$rearGradientEndHex"/>
    </linearGradient>
    <linearGradient id="connector" gradientUnits="userSpaceOnUse" x1="${g.connX1}" y1="${g.connY1}" x2="${g.connX2}" y2="${g.connY2}">
      <stop offset="0" stop-color="$connectorGradientStartHex"/>
      <stop offset="1" stop-color="$connectorGradientEndHex"/>
    </linearGradient>
    <linearGradient id="front" gradientUnits="userSpaceOnUse" x1="${g.frontX1}" y1="${g.frontY1}" x2="${g.frontX2}" y2="${g.frontY2}">
      <stop offset="0" stop-color="$frontGradientStartHex"/>
      <stop offset="1" stop-color="$frontGradientEndHex"/>
    </linearGradient>
    <linearGradient id="frame-specular" gradientUnits="userSpaceOnUse" x1="512" y1="${g.rearY1}" x2="512" y2="${g.frontY2}">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.34"/>
      <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0.06"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <path d="${g.rearPath}" fill="url(#rear)" fill-rule="evenodd"/>
  <path d="${g.rearPath}" fill="url(#frame-specular)" fill-rule="evenodd"/>
  <path d="M${g.connX1} ${g.connY1} L${g.connX2} ${g.connY2}" stroke="url(#connector)" stroke-width="${g.connWidth}" stroke-linecap="round"/>
  <path d="${g.frontPath}" fill="url(#front)" fill-rule="evenodd"/>
  <path d="${g.frontPath}" fill="url(#frame-specular)" fill-rule="evenodd"/>
</svg>''';
  }
}
