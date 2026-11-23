import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';

import '../../common.dart';

typedef KBChosenCallback = Future<bool> Function(String);

const double _kImageMarginVertical = 6.0;
const double _kImageMarginHorizontal = 8.0;
const double _kImagePaddingWidth = 10.0;
const String _kKBLayoutTypeISO = 'ISO';
const String _kKBLayoutTypeNotISO = 'Not ISO';

class _KBImage extends StatelessWidget {
  final String kbLayoutType;
  final double imageWidth;
  final RxString chosenType;
  const _KBImage({
    Key? key,
    required this.kbLayoutType,
    required this.imageWidth,
    required this.chosenType,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glass = CamelliaGlassTokens.of(context);
    final isIso = kbLayoutType == _kKBLayoutTypeISO;
    final previewWidth = (imageWidth -
            _kImageMarginHorizontal * 2 -
            _kImagePaddingWidth * 2 -
            4)
        .clamp(80.0, 220.0);
    final previewHeight = (previewWidth * 0.44).clamp(52.0, 88.0);

    return Obx(() {
      final selected = chosenType.value == kbLayoutType;
      return AnimatedContainer(
        duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
        curve: CamelliaMotion.standard,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.14)
              : glass.floatingTint,
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2.0 : 1.0,
          ),
        ),
        margin: const EdgeInsets.symmetric(
          horizontal: _kImageMarginHorizontal,
          vertical: _kImageMarginVertical,
        ),
        padding: const EdgeInsets.all(_kImagePaddingWidth),
        child: CamelliaIcons.keyboardLayoutPreview(
          isIso: isIso,
          width: previewWidth,
          height: previewHeight,
        ),
      );
    });
  }
}

class _KBChooser extends StatelessWidget {
  final String kbLayoutType;
  final double imageWidth;
  final RxString chosenType;
  final KBChosenCallback cb;
  const _KBChooser({
    Key? key,
    required this.kbLayoutType,
    required this.imageWidth,
    required this.chosenType,
    required this.cb,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Future<void> onChanged(String? v) async {
      if (v != null) {
        if (await cb(v)) {
          chosenType.value = v;
        }
      }
    }

    return InkWell(
      borderRadius: BorderRadius.circular(CamelliaRadius.surface),
      onTap: () => onChanged(kbLayoutType),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _KBImage(
            kbLayoutType: kbLayoutType,
            imageWidth: imageWidth,
            chosenType: chosenType,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(
                () => RadioGroup<String>(
                  groupValue: chosenType.value,
                  onChanged: onChanged,
                  child: Radio<String>(
                    value: kbLayoutType,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              Text(
                kbLayoutType,
                style: theme.textTheme.labelLarge,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class KBLayoutTypeChooser extends StatelessWidget {
  final RxString chosenType;
  final double width;
  final double height;
  final double dividerWidth;
  final KBChosenCallback cb;
  const KBLayoutTypeChooser({
    Key? key,
    required this.chosenType,
    required this.width,
    required this.height,
    required this.dividerWidth,
    required this.cb,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final imageWidth = width / 2 - dividerWidth;
    return SizedBox(
      width: width,
      height: height,
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: _KBChooser(
                kbLayoutType: _kKBLayoutTypeISO,
                imageWidth: imageWidth,
                chosenType: chosenType,
                cb: cb,
              ),
            ),
            VerticalDivider(
              width: dividerWidth * 2,
              indent: 14,
              endIndent: 14,
            ),
            Expanded(
              child: _KBChooser(
                kbLayoutType: _kKBLayoutTypeNotISO,
                imageWidth: imageWidth,
                chosenType: chosenType,
                cb: cb,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

RxString KBLayoutType = ''.obs;

String getLocalPlatformForKBLayoutType(String peerPlatform) {
  String localPlatform = '';
  if (peerPlatform != kPeerPlatformMacOS) {
    return localPlatform;
  }

  if (isWindows) {
    localPlatform = kPeerPlatformWindows;
  } else if (isLinux) {
    localPlatform = kPeerPlatformLinux;
  } else if (isWebOnWindows || isWebOnLinux) {
    localPlatform = kPeerPlatformWebDesktop;
  }
  return localPlatform;
}

showKBLayoutTypeChooserIfNeeded(
  String peerPlatform,
  OverlayDialogManager dialogManager,
) async {
  final localPlatform = getLocalPlatformForKBLayoutType(peerPlatform);
  if (localPlatform == '') {
    return;
  }
  KBLayoutType.value = bind.getLocalKbLayoutType();
  if (KBLayoutType.value == _kKBLayoutTypeISO ||
      KBLayoutType.value == _kKBLayoutTypeNotISO) {
    return;
  }
  showKBLayoutTypeChooser(localPlatform, dialogManager);
}

showKBLayoutTypeChooser(
  String localPlatform,
  OverlayDialogManager dialogManager,
) {
  dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: ModernDialogHeader(
        title: translate('Select local keyboard type'),
        subtitle: localPlatform,
        icon: CamelliaIcons.keyboard,
        tone: AppTone.brand,
        onClose: close,
      ),
      content: KBLayoutTypeChooser(
        chosenType: KBLayoutType,
        width: 360,
        height: 172,
        dividerWidth: 6.0,
        cb: (String v) async {
          await bind.setLocalKbLayoutType(kbLayoutType: v);
          KBLayoutType.value = bind.getLocalKbLayoutType();
          return v == KBLayoutType.value;
        },
      ),
      actions: [dialogButton('Close', onPressed: close)],
      onCancel: close,
    );
  });
}
