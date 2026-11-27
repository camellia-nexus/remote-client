import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/toolbar.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/widgets/dialog.dart' show ModernDialogHeader;
import '../../models/platform_model.dart';

void _showSuccess() {
  showToast(translate("Successful"));
}

void setTemporaryPasswordLengthDialog(
  OverlayDialogManager dialogManager, {
  BuildContext? sheetContext,
}) async {
  const lengths = <String>['6', '8', '10'];
  String length = await bind.mainGetOption(key: "temporary-password-length");
  var index = lengths.indexOf(length);
  if (index < 0) index = 0;
  length = lengths[index];

  Future<void> applyLength(String newValue, VoidCallback dismiss) async {
    if (length == newValue) return;
    length = newValue;
    HapticFeedback.selectionClick();
    await bind.mainSetOption(
      key: "temporary-password-length",
      value: newValue,
    );
    await bind.mainUpdateTemporaryPassword();
    dismiss();
    _showSuccess();
  }

  if (sheetContext != null && sheetContext.mounted) {
    await showGlassBottomSheet<void>(
      context: sheetContext,
      title: translate("Set one-time password length"),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: GlassSegmentedControl<String>(
              expand: true,
              selected: length,
              items: [
                for (final v in lengths)
                  GlassSegmentItem<String>(value: v, label: v),
              ],
              onChanged: (next) {
                setSheetState(() {});
                applyLength(next, () {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                });
              },
            ),
          );
        },
      ),
    );
    return;
  }

  dialogManager.show(
    (setState, close, context) {
      return CustomAlertDialog(
        title: ModernDialogHeader(
          icon: CamelliaIcons.lock,
          title: translate("Set one-time password length"),
          onClose: close,
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GlassSegmentedControl<String>(
              expand: true,
              selected: length,
              items: [
                for (final v in lengths)
                  GlassSegmentItem<String>(value: v, label: v),
              ],
              onChanged: (newValue) {
                setState(() {});
                applyLength(newValue, close);
              },
            ),
          ),
        ),
        actions: [
          GlassButton(
            variant: GlassButtonVariant.secondary,
            onPressed: close,
            child: Text(translate("Cancel")),
          ),
        ],
        onCancel: close,
      );
    },
    backDismiss: true,
    clickMaskDismiss: true,
  );
}

void setPrivacyModeDialog(
  OverlayDialogManager dialogManager,
  List<TToggleMenu> privacyModeList,
  RxString privacyModeState, {
  BuildContext? sheetContext,
}) async {
  final rxStates = privacyModeList.map((e) => e.value.obs).toList();

  Widget buildOptionTiles(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return Obx(() {
      final _ = privacyModeState.value;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < privacyModeList.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.surfaceContainer.withValues(
                    alpha: dark ? 0.68 : 0.82,
                  ),
                  borderRadius: BorderRadius.circular(CamelliaRadius.control),
                  border: Border.all(
                    color: tokens.border.withValues(alpha: 0.85),
                    width: 0.85,
                  ),
                ),
                child: SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  title: DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    child: privacyModeList[i].child,
                  ),
                  value: rxStates[i].value,
                  onChanged: privacyModeList[i].onChanged == null
                      ? null
                      : (next) {
                          HapticFeedback.selectionClick();
                          privacyModeList[i].onChanged?.call(next);
                          rxStates[i].value = next;
                        },
                ),
              ),
            ),
        ],
      );
    });
  }

  if (sheetContext != null && sheetContext.mounted) {
    await showGlassBottomSheet<void>(
      context: sheetContext,
      title: translate('Privacy mode'),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: buildOptionTiles(ctx),
      ),
    );
    return;
  }

  dialogManager.dismissAll();
  dialogManager.show(
    (setState, close, context) {
      return CustomAlertDialog(
        title: ModernDialogHeader(
          icon: CamelliaIcons.privacy,
          title: translate('Privacy mode'),
          onClose: close,
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
          child: buildOptionTiles(context),
        ),
        actions: [
          GlassButton(
            variant: GlassButtonVariant.primary,
            onPressed: close,
            child: Text(translate('OK')),
          ),
        ],
        onCancel: close,
      );
    },
    backDismiss: true,
    clickMaskDismiss: true,
  );
}
