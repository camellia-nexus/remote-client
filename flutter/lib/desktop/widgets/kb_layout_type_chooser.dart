import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';

import '../../common.dart';

typedef KBChosenCallback = Future<bool> Function(String);

const String _kKBLayoutTypeISO = 'ISO';
const String _kKBLayoutTypeNotISO = 'Not ISO';

class _KBOptionCard extends StatefulWidget {
  final String kbLayoutType;
  final double cardWidth;
  final RxString chosenType;
  final KBChosenCallback cb;

  const _KBOptionCard({
    required this.kbLayoutType,
    required this.cardWidth,
    required this.chosenType,
    required this.cb,
  });

  @override
  State<_KBOptionCard> createState() => _KBOptionCardState();
}

class _KBOptionCardState extends State<_KBOptionCard> {
  bool _hovered = false;

  Future<void> _select(String? value) async {
    if (value == null) return;
    if (await widget.cb(value)) {
      widget.chosenType.value = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dark ? theme.colorScheme.secondary : theme.colorScheme.primary;
    final isIso = widget.kbLayoutType == _kKBLayoutTypeISO;
    final previewWidth = (widget.cardWidth - 28).clamp(96.0, 210.0);
    final previewHeight = (previewWidth * 0.44).clamp(52.0, 86.0);

    return Obx(() {
      final selected = widget.chosenType.value == widget.kbLayoutType;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _select(widget.kbLayoutType),
          child: AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
            curve: CamelliaMotion.standard,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: dark ? 0.18 : 0.10)
                  : (_hovered ? glass.hoverOverlay : glass.floatingTint),
              borderRadius: BorderRadius.circular(CamelliaRadius.surface),
              border: Border.all(
                color: selected
                    ? accent.withValues(alpha: dark ? 0.72 : 0.60)
                    : tokens.border.withValues(alpha: 0.82),
                width: selected ? 1.4 : 0.85,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: dark ? 0.22 : 0.12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : const [],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: tokens.surfaceContainer.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    border: Border.all(
                      color: tokens.border.withValues(alpha: 0.6),
                      width: 0.85,
                    ),
                  ),
                  child: CamelliaIcons.keyboardLayoutPreview(
                    isIso: isIso,
                    width: previewWidth,
                    height: previewHeight,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RadioGroup<String>(
                      groupValue: widget.chosenType.value,
                      onChanged: _select,
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: Radio<String>(
                          value: widget.kbLayoutType,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        translate(widget.kbLayoutType),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: selected
                              ? accent
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    });
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
    final gap = (dividerWidth * 2).clamp(8.0, 20.0);
    final cardWidth = (width - gap) / 2;
    return SizedBox(
      width: width,
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _KBOptionCard(
              kbLayoutType: _kKBLayoutTypeISO,
              cardWidth: cardWidth,
              chosenType: chosenType,
              cb: cb,
            ),
          ),
          SizedBox(width: gap),
          Expanded(
            child: _KBOptionCard(
              kbLayoutType: _kKBLayoutTypeNotISO,
              cardWidth: cardWidth,
              chosenType: chosenType,
              cb: cb,
            ),
          ),
        ],
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
        width: 392,
        height: 184,
        dividerWidth: 6.0,
        cb: (String v) async {
          await bind.setLocalKbLayoutType(kbLayoutType: v);
          KBLayoutType.value = bind.getLocalKbLayoutType();
          return v == KBLayoutType.value;
        },
      ),
      actions: [
        GlassButton(
          variant: GlassButtonVariant.primary,
          minHeight: 40,
          onPressed: close,
          child: Text(translate('Done')),
        ),
      ],
      onCancel: close,
    );
  });
}
