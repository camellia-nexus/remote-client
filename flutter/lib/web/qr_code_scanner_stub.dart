import 'dart:async';

import 'package:flutter/widgets.dart';

class Barcode {
  Barcode({this.code});
  final String? code;
}

class QRViewController {
  final StreamController<Barcode> _controller =
      StreamController<Barcode>.broadcast();

  Stream<Barcode> get scannedDataStream => _controller.stream;

  Future<void> pauseCamera() async {}
  Future<void> resumeCamera() async {}
  Future<void> toggleFlash() async {}
  Future<bool?> getFlashStatus() async => false;
  Future<void> flipCamera() async {}

  void dispose() {
    _controller.close();
  }
}

class QrScannerOverlayShape {
  const QrScannerOverlayShape({
    this.borderColor,
    this.borderRadius,
    this.borderLength,
    this.borderWidth,
    this.cutOutSize,
  });

  final Color? borderColor;
  final double? borderRadius;
  final double? borderLength;
  final double? borderWidth;
  final double? cutOutSize;
}

class QRView extends StatefulWidget {
  const QRView({
    super.key,
    required this.onQRViewCreated,
    this.overlay,
    this.onPermissionSet,
  });

  final void Function(QRViewController) onQRViewCreated;
  final QrScannerOverlayShape? overlay;
  final void Function(QRViewController, bool)? onPermissionSet;

  @override
  State<QRView> createState() => _QRViewState();
}

class _QRViewState extends State<QRView> {
  late final QRViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = QRViewController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onPermissionSet?.call(_controller, false);
      widget.onQRViewCreated(_controller);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
