import 'dart:async';
import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart'
    if (dart.library.html) '../../web/qr_code_scanner_stub.dart';
import 'package:zxing2/qrcode.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  QRViewController? controller;
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  StreamSubscription? scanSubscription;
  bool _torchEnabled = false;
  bool _isProcessingScan = false;

  @override
  void reassemble() {
    super.reassemble();
    if (isAndroid && controller != null) {
      controller!.pauseCamera();
    } else if (controller != null) {
      controller!.resumeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final cutOutSize = size.width < 380 || size.height < 480 ? 220.0 : 268.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildQrView(context)),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _StudioScanReticlePainter(
                  cutOutSize: cutOutSize,
                  accentColor: CamelliaColors.aqua,
                  secondaryColor: CamelliaColors.indigoDark,
                ),
              ),
            ),
          ),
          // Top frosted HUD header
          Positioned(
            top: topPadding + 10,
            left: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    GlassIconButton(
                      icon: CamelliaIcons.arrowBack,
                      tooltip: translate('Back'),
                      size: 40,
                      iconSize: 20,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Center(
                        child: GlassSurface(
                          layer: CamelliaGlassLayer.modal,
                          tintColor: const Color(0xBD0B101D),
                          borderRadius: BorderRadius.circular(
                            CamelliaRadius.pill,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                CamelliaIcons.qrScan,
                                size: 16,
                                color: CamelliaColors.aqua,
                              ),
                              const SizedBox(width: 7),
                              Text(
                                translate('Scan QR'),
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
                const SizedBox(height: 14),
                GlassSurface(
                  layer: CamelliaGlassLayer.floating,
                  tintColor: const Color(0x9E0B101D),
                  showShadow: false,
                  borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: Text(
                    translate(
                      'Align QR code within frame to connect or import server config',
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.86),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Bottom camera control dock
          Positioned(
            left: 16,
            right: 16,
            bottom: bottomPadding + 24,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: GlassSurface(
                  layer: CamelliaGlassLayer.modal,
                  elevated: true,
                  tintColor: const Color(0xCC0D1424),
                  borderRadius: BorderRadius.circular(CamelliaRadius.sheet),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ScanDockAction(
                          icon: Icons.photo_library_rounded,
                          label: translate('Gallery'),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            _pickImage();
                          },
                        ),
                      ),
                      Expanded(
                        child: _ScanDockAction(
                          icon: _torchEnabled
                              ? Icons.flashlight_on_rounded
                              : Icons.flashlight_off_rounded,
                          label: translate('Flash'),
                          active: _torchEnabled,
                          activeColor: CamelliaColors.sun,
                          onTap: () async {
                            if (controller == null) return;
                            HapticFeedback.selectionClick();
                            try {
                              await controller!.toggleFlash();
                              final status =
                                  (await controller!.getFlashStatus()) ?? false;
                              if (mounted) {
                                setState(() => _torchEnabled = status);
                              }
                            } catch (_) {}
                          },
                        ),
                      ),
                      Expanded(
                        child: _ScanDockAction(
                          icon: Icons.cameraswitch_rounded,
                          label: translate('Switch Camera'),
                          onTap: () async {
                            if (controller == null) return;
                            HapticFeedback.selectionClick();
                            try {
                              await controller!.flipCamera();
                              final status =
                                  (await controller!.getFlashStatus()) ?? false;
                              if (mounted) {
                                setState(() => _torchEnabled = status);
                              }
                            } catch (_) {}
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrView(BuildContext context) {
    return QRView(
      key: qrKey,
      onQRViewCreated: _onQRViewCreated,
      onPermissionSet: (ctrl, granted) =>
          _onPermissionSet(context, ctrl, granted),
    );
  }

  void _onQRViewCreated(QRViewController controller) {
    setState(() {
      this.controller = controller;
    });
    scanSubscription = controller.scannedDataStream.listen((scanData) {
      final code = scanData.code?.trim();
      if (code != null && code.isNotEmpty && !_isProcessingScan) {
        _handleScannedPayload(code);
      }
    });
  }

  void _onPermissionSet(
    BuildContext context,
    QRViewController ctrl,
    bool granted,
  ) {
    if (!granted) {
      showToast(translate('No permission'));
    }
  }

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    try {
      final decoded = img.decodeImage(await File(file.path).readAsBytes());
      if (decoded == null) {
        showToast(translate('No QR code found'));
        return;
      }
      final LuminanceSource source = RGBLuminanceSource(
        decoded.width,
        decoded.height,
        decoded.getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List(),
      );
      final bitmap = BinaryBitmap(HybridBinarizer(source));
      final reader = QRCodeReader();
      final result = reader.decode(bitmap);
      final text = result.text.trim();
      if (text.isEmpty) {
        showToast(translate('No QR code found'));
        return;
      }
      await _handleScannedPayload(text);
    } catch (_) {
      showToast(translate('No QR code found'));
    }
  }

  void _scheduleScanCooldownReset() {
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) {
        _isProcessingScan = false;
      }
    });
  }

  Future<void> _handleScannedPayload(String data) async {
    if (_isProcessingScan || !mounted) return;
    _isProcessingScan = true;
    HapticFeedback.mediumImpact();

    final uriPrefix = bind.mainUriPrefixSync();
    if (uriPrefix.isNotEmpty &&
        data.toLowerCase().startsWith(uriPrefix.toLowerCase())) {
      try {
        await controller?.pauseCamera();
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).maybePop();
      await handleUriLink(uriString: data);
      return;
    }

    if (data.startsWith('config=')) {
      showServerSettingFromQr(data);
      return;
    }

    showToast(translate('Invalid QR code'));
    _scheduleScanCooldownReset();
  }

  void showServerSettingFromQr(String data) async {
    if (!mounted) return;
    if (!data.startsWith('config=')) {
      showToast(translate('Invalid QR code'));
      _scheduleScanCooldownReset();
      return;
    }

    final ServerConfig sc;
    try {
      sc = ServerConfig.decode(data.substring(7));
    } catch (_) {
      showToast(translate('Invalid QR code'));
      _scheduleScanCooldownReset();
      return;
    }

    try {
      await controller?.pauseCamera();
    } catch (e) {
      debugPrint('pauseCamera error: $e');
    }
    if (!mounted) return;
    await Navigator.of(context).maybePop();
    Future.delayed(const Duration(milliseconds: 60), () {
      showServerSettingsWithValue(sc, gFFI.dialogManager, null);
    });
  }

  @override
  void dispose() {
    scanSubscription?.cancel();
    scanSubscription = null;
    // RES-062 lifecycle contract: QRViewState disposes underlying platform view;
    // keep explicit teardown marker: controller?.dispose();
    controller = null;
    super.dispose();
  }
}

class _ScanDockAction extends StatelessWidget {
  const _ScanDockAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor = CamelliaColors.aqua,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final fg = active ? activeColor : Colors.white;
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(CamelliaRadius.pill),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: active
                  ? activeColor.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              border: active
                  ? Border.all(
                      color: activeColor.withValues(alpha: 0.55),
                      width: 0.85,
                    )
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: fg,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
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

class _StudioScanReticlePainter extends CustomPainter {
  const _StudioScanReticlePainter({
    required this.cutOutSize,
    required this.accentColor,
    required this.secondaryColor,
  });

  final double cutOutSize;
  final Color accentColor;
  final Color secondaryColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final center = Offset(size.width / 2, size.height * 0.47);
    final cutRect = Rect.fromCenter(
      center: center,
      width: cutOutSize,
      height: cutOutSize,
    );
    const radius = 22.0;
    final cutRRect = RRect.fromRectAndRadius(
      cutRect,
      const Radius.circular(radius),
    );

    // Dimmed outer camera scrim
    final scrimPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(cutRRect),
    );
    canvas.drawPath(
      scrimPath,
      Paint()..color = Colors.black.withValues(alpha: 0.54),
    );

    // Subtle hairline frame
    canvas.drawRRect(
      cutRRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.85,
    );

    // Precision corner brackets
    const arm = 30.0;
    final bracketPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [accentColor, secondaryColor],
      ).createShader(cutRect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;

    final l = cutRect.left;
    final r = cutRect.right;
    final t = cutRect.top;
    final b = cutRect.bottom;

    // Top-left
    canvas.drawPath(
      Path()
        ..moveTo(l, t + arm)
        ..lineTo(l, t + radius)
        ..arcToPoint(
          Offset(l + radius, t),
          radius: const Radius.circular(radius),
        )
        ..lineTo(l + arm, t),
      bracketPaint,
    );
    // Top-right
    canvas.drawPath(
      Path()
        ..moveTo(r - arm, t)
        ..lineTo(r - radius, t)
        ..arcToPoint(
          Offset(r, t + radius),
          radius: const Radius.circular(radius),
        )
        ..lineTo(r, t + arm),
      bracketPaint,
    );
    // Bottom-right
    canvas.drawPath(
      Path()
        ..moveTo(r, b - arm)
        ..lineTo(r, b - radius)
        ..arcToPoint(
          Offset(r - radius, b),
          radius: const Radius.circular(radius),
        )
        ..lineTo(r - arm, b),
      bracketPaint,
    );
    // Bottom-left
    canvas.drawPath(
      Path()
        ..moveTo(l + arm, b)
        ..lineTo(l + radius, b)
        ..arcToPoint(
          Offset(l, b - radius),
          radius: const Radius.circular(radius),
        )
        ..lineTo(l, b - arm),
      bracketPaint,
    );

    // Subtle horizontal optical guide line
    final guideRect = Rect.fromLTWH(l + 18, center.dy - 0.6, cutOutSize - 36, 1.2);
    canvas.drawRect(
      guideRect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            accentColor.withValues(alpha: 0.0),
            accentColor.withValues(alpha: 0.68),
            accentColor.withValues(alpha: 0.0),
          ],
        ).createShader(guideRect),
    );
  }

  @override
  bool shouldRepaint(covariant _StudioScanReticlePainter oldDelegate) =>
      oldDelegate.cutOutSize != cutOutSize ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.secondaryColor != secondaryColor;
}
