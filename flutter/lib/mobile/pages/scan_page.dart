import 'dart:async';
import 'dart:io';

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
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(
          translate('Scan QR'),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildQrView(context)),
          Positioned(
            left: 20,
            right: 20,
            bottom: 24,
            child: SafeArea(
              top: false,
              child: Center(
                child: GlassSurface(
                  layer: CamelliaGlassLayer.modal,
                  elevated: true,
                  tintColor: const Color(0xB80E1422),
                  borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildImagePickerButton(),
                      const SizedBox(width: 12),
                      _buildFlashToggleButton(),
                      const SizedBox(width: 12),
                      _buildCameraSwitchButton(),
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
    final size = MediaQuery.sizeOf(context);
    var scanArea = size.width < 400 || size.height < 400 ? 220.0 : 280.0;
    return QRView(
      key: qrKey,
      onQRViewCreated: _onQRViewCreated,
      overlay: QrScannerOverlayShape(
        borderColor: CamelliaColors.aqua,
        borderRadius: 18,
        borderLength: 34,
        borderWidth: 6,
        cutOutSize: scanArea,
      ),
      onPermissionSet: (ctrl, p) => _onPermissionSet(context, ctrl, p),
    );
  }

  void _onQRViewCreated(QRViewController controller) {
    setState(() {
      this.controller = controller;
    });
    scanSubscription = controller.scannedDataStream.listen((scanData) {
      if (scanData.code != null && !_isProcessingScan) {
        showServerSettingFromQr(scanData.code!);
      }
    });
  }

  void _onPermissionSet(BuildContext context, QRViewController ctrl, bool p) {
    if (!p) {
      showToast('No permission');
    }
  }

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file != null) {
      try {
        var image = img.decodeImage(await File(file.path).readAsBytes())!;
        LuminanceSource source = RGBLuminanceSource(
          image.width,
          image.height,
          image.getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List(),
        );
        var bitmap = BinaryBitmap(HybridBinarizer(source));

        var reader = QRCodeReader();
        var result = reader.decode(bitmap);
        if (result.text.startsWith(bind.mainUriPrefixSync())) {
          await handleUriLink(uriString: result.text);
        } else {
          showServerSettingFromQr(result.text);
        }
      } catch (e) {
        showToast('No QR code found');
      }
    }
  }

  Widget _buildImagePickerButton() {
    return IconButton(
      tooltip: translate('Gallery'),
      color: Colors.white,
      icon: const Icon(Icons.photo_library_rounded),
      iconSize: 24.0,
      onPressed: () {
        HapticFeedback.selectionClick();
        _pickImage();
      },
    );
  }

  Widget _buildFlashToggleButton() {
    return IconButton(
      tooltip: translate('Flash'),
      color: CamelliaColors.sun,
      icon: const Icon(Icons.flashlight_on_rounded),
      iconSize: 24.0,
      onPressed: () async {
        HapticFeedback.selectionClick();
        await controller?.toggleFlash();
      },
    );
  }

  Widget _buildCameraSwitchButton() {
    return IconButton(
      tooltip: translate('Switch Camera'),
      color: Colors.white,
      icon: const Icon(Icons.cameraswitch_rounded),
      iconSize: 24.0,
      onPressed: () async {
        HapticFeedback.selectionClick();
        await controller?.flipCamera();
      },
    );
  }

  bool _isProcessingScan = false;
  Timer? _openDialogTimer;

  @override
  void dispose() {
    _openDialogTimer?.cancel();
    _openDialogTimer = null;
    scanSubscription?.cancel();
    scanSubscription = null;
    controller = null;
    super.dispose();
  }

  void showServerSettingFromQr(String data) async {
    if (_isProcessingScan || !mounted) return;
    _isProcessingScan = true;

    if (!data.startsWith('config=')) {
      showToast('Invalid QR code');
      _isProcessingScan = false;
      return;
    }

    final ServerConfig sc;
    try {
      sc = ServerConfig.decode(data.substring(7));
    } catch (e) {
      showToast('Invalid QR code');
      _isProcessingScan = false;
      return;
    }

    try {
      await controller?.pauseCamera();
    } catch (e) {
      debugPrint('pauseCamera error: $e');
    }
    if (!mounted) return;
    closeConnection();

    _openDialogTimer?.cancel();
    _openDialogTimer = Timer(const Duration(milliseconds: 60), () {
      _openDialogTimer = null;
      showServerSettingsWithValue(sc, gFFI.dialogManager, null);
    });
  }
}
