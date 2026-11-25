// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';

import '../../common.dart';
import '../../common/widgets/dialog.dart' show ModernDialogHeader;
import '../../models/platform_model.dart';

const _deployDialogTag = 'android-deploy-device';

void showDeployPromptDialog() {
  gFFI.dialogManager
      .dismissByTag(_deployDialogTag);
  gFFI.dialogManager
      .show<bool>((setState, close, context) {
        void submit() => close(true);
        return CustomAlertDialog(
          title: ModernDialogHeader(
            icon: CamelliaIcons.shield,
            title: translate("Deploy"),
            onClose: () => close(false),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Text(
              translate("server_requires_deployment_tip"),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          actions: [
            GlassButton(
              variant: GlassButtonVariant.secondary,
              onPressed: () => close(false),
              child: Text(translate("Cancel")),
            ),
            GlassButton(
              variant: GlassButtonVariant.primary,
              onPressed: submit,
              child: Text(translate("OK")),
            ),
          ],
          onSubmit: submit,
          onCancel: () => close(false),
        );
      }, tag: _deployDialogTag)
      .then((deploy) {
        if (deploy == true) {
          showDeployDialog();
        }
      });
}

void showDeployDialog() {
  gFFI.dialogManager.dismissByTag(_deployDialogTag);
  final tokenController = TextEditingController();
  final idController = TextEditingController();
  var errorText = "";
  var isInProgress = false;
  var obscureToken = true;

  gFFI.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      tokenController.clear();
      idController.clear();
      tokenController.dispose();
      idController.dispose();
      close();
    }

    Future<void> submit() async {
      if (isInProgress) return;
      final token = tokenController.text.trim();
      if (token.isEmpty) {
        setState(() {
          errorText = translate("token is required!");
        });
        return;
      }
      setState(() {
        errorText = "";
        isInProgress = true;
      });
      String res;
      try {
        res = await bind.mainDeployDevice(
          token: token,
          id: idController.text.trim(),
        );
      } catch (e) {
        if (isClosed) return;
        setState(() {
          errorText = translate(e.toString());
          isInProgress = false;
        });
        return;
      }
      if (res.isEmpty) {
        safeClose();
        await gFFI.serverModel.fetchID();
        showToast(translate("Successful"));
      } else if (!isClosed) {
        setState(() {
          errorText = translate(res.toString());
          isInProgress = false;
        });
      }
    }

    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.shield,
        title: translate("Deploy"),
        onClose: isInProgress ? null : safeClose,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 290, maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassInput(
              controller: tokenController,
              labelText: translate("API Token"),
              prefixIcon: Icons.vpn_key_rounded,
              obscureText: obscureToken,
              autofocus: true,
              showPasteButton: true,
              trailing: GlassIconButton(
                icon: obscureToken ? CamelliaIcons.eye : CamelliaIcons.eyeOff,
                size: 28,
                iconSize: 15,
                tooltip: obscureToken ? translate('Show') : translate('Hide'),
                onPressed: () => setState(() => obscureToken = !obscureToken),
              ),
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 12),
            GlassInput(
              controller: idController,
              labelText: translate("Custom ID (optional)"),
              prefixIcon: Icons.fingerprint_rounded,
              tabularNums: true,
              onSubmitted: (_) => submit(),
            ),
            if (errorText.isNotEmpty) ...[
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(CamelliaRadius.control),
                  border: Border.all(
                    color: tokens.danger.withValues(alpha: 0.35),
                    width: 0.85,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: SelectableText(
                    errorText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.danger,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        GlassButton(
          variant: GlassButtonVariant.secondary,
          onPressed: isInProgress ? null : safeClose,
          child: Text(translate("Cancel")),
        ),
        GlassButton(
          variant: GlassButtonVariant.primary,
          loading: isInProgress,
          onPressed: isInProgress ? null : submit,
          child: Text(translate("OK")),
        ),
      ],
      onSubmit: submit,
      onCancel: isInProgress ? null : safeClose,
    );
  }, tag: _deployDialogTag);
}
