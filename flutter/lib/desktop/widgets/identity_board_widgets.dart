import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/common/widgets/animated_rotation_widget.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/server_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';

/// Reusable one-click copy button with animated icon switcher to check_rounded.
class AppCopyFeedbackButton extends StatefulWidget {
  const AppCopyFeedbackButton({
    super.key,
    required this.text,
    required this.tooltip,
    this.copiedTooltip,
    this.size = 28,
    this.iconSize = 18,
  });

  final String text;
  final String tooltip;
  final String? copiedTooltip;
  final double size;
  final double iconSize;

  @override
  State<AppCopyFeedbackButton> createState() => _AppCopyFeedbackButtonState();
}

class _AppCopyFeedbackButtonState extends State<AppCopyFeedbackButton> {
  bool _copied = false;
  Timer? _revertTimer;

  void _copy() {
    if (widget.text.isEmpty || widget.text == '-') return;
    Clipboard.setData(ClipboardData(text: widget.text));
    showToast(translate("Copied"));
    setState(() => _copied = true);
    _revertTimer?.cancel();
    _revertTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _revertTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final successColor = AppVisual.tone(context, AppTone.success);
    final defaultColor = AppVisual.subduedText(context);
    final isActionable = widget.text.isNotEmpty && widget.text != '-';

    return Tooltip(
      message: _copied
          ? (widget.copiedTooltip ?? translate("Copied"))
          : widget.tooltip,
      child: IconButton(
        iconSize: widget.iconSize,
        style: IconButton.styleFrom(
          minimumSize: Size(widget.size, widget.size),
          maximumSize: Size(widget.size, widget.size),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
          ),
        ),
        onPressed: isActionable ? _copy : null,
        icon: AnimatedSwitcher(
          duration: AppMotion.duration(context, AppMotion.feedback),
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: Icon(
            _copied ? Icons.check_rounded : Icons.copy_rounded,
            key: ValueKey<bool>(_copied),
            color: _copied ? successColor : defaultColor,
            size: widget.iconSize,
          ),
        ),
      ),
    );
  }
}

/// Modern Identity ID Board with tabular typography, card elevation, and one-click copy button.
class IdentityIdBoard extends StatelessWidget {
  const IdentityIdBoard({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, child) {
          final theme = Theme.of(context);

          return AppSurface(
            elevated: true,
            margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            padding: const EdgeInsets.all(12),
            color: AppVisual.toneContainer(context, AppTone.info),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const AppIconBadge(
                  icon: Icons.fingerprint_rounded,
                  colors: AppVisual.identityGradient,
                  size: 38,
                  iconSize: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        translate("ID"),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: AppVisual.subduedText(context),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      GestureDetector(
                        onDoubleTap: () {
                          Clipboard.setData(
                            ClipboardData(text: model.serverId.text),
                          );
                          showToast(translate("Copied"));
                        },
                        child: TextFormField(
                          controller: model.serverId,
                          readOnly: true,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.only(top: 2, bottom: 2),
                          ),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ).workaroundFreezeLinuxMint(),
                      ),
                    ],
                  ),
                ),
                AppCopyFeedbackButton(
                  text: model.serverId.text,
                  tooltip: translate("Copy ID"),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Modern Password Board with two-tier layout, tabular figures, visibility toggle, and copy feedback.
class IdentityPasswordBoard extends StatefulWidget {
  const IdentityPasswordBoard({super.key});

  @override
  State<IdentityPasswordBoard> createState() => _IdentityPasswordBoardState();
}

class _IdentityPasswordBoardState extends State<IdentityPasswordBoard> {
  bool _obscurePassword = false;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, child) {
          final theme = Theme.of(context);
          final isPermanent =
              model.verificationMethod == kUsePermanentPassword;
          final showOneTime = model.approveMode != 'click' && !isPermanent;
          final label = isPermanent
              ? translate("Permanent Password")
              : translate("One-time Password");
          final subduedColor = AppVisual.subduedText(context);

          return AppSurface(
            elevated: true,
            margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            padding: const EdgeInsets.all(12),
            color: AppVisual.toneContainer(context, AppTone.warning),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppIconBadge(
                  icon: Icons.key_rounded,
                  colors: AppVisual.securityGradient,
                  size: 38,
                  iconSize: 20,
                ).marginOnly(top: 2),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Header Row: Label + Management Actions (Refresh, Edit)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: subduedColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (showOneTime)
                            AnimatedRotationWidget(
                              onPressed: () =>
                                  bind.mainUpdateTemporaryPassword(),
                              child: Tooltip(
                                message: translate('Refresh Password'),
                                child: IconButton(
                                  iconSize: 18,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(28, 28),
                                    maximumSize: const Size(28, 28),
                                    padding: EdgeInsets.zero,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        CamelliaRadius.control,
                                      ),
                                    ),
                                  ),
                                  icon: Icon(
                                    Icons.refresh_rounded,
                                    color: subduedColor,
                                  ),
                                  onPressed: () =>
                                      bind.mainUpdateTemporaryPassword(),
                                ),
                              ),
                            ),
                          if (!bind.isDisableSettings())
                            Tooltip(
                              message: translate('Change Password'),
                              child: IconButton(
                                iconSize: 18,
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(28, 28),
                                  maximumSize: const Size(28, 28),
                                  padding: EdgeInsets.zero,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      CamelliaRadius.control,
                                    ),
                                  ),
                                ),
                                icon: Icon(
                                  Icons.edit_rounded,
                                  color: subduedColor,
                                ),
                                onPressed: () => DesktopSettingPage.switch2page(
                                  SettingsTabKey.safety,
                                ),
                              ),
                            ),
                        ],
                      ),
                      // Value Row: Tabular Password Text + Reveal Eye & One-Click Copy
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onDoubleTap: () {
                                if (showOneTime &&
                                    model.serverPasswd.text.isNotEmpty &&
                                    model.serverPasswd.text != '-') {
                                  Clipboard.setData(
                                    ClipboardData(
                                      text: model.serverPasswd.text,
                                    ),
                                  );
                                  showToast(translate("Copied"));
                                }
                              },
                              child: TextFormField(
                                controller: model.serverPasswd,
                                readOnly: true,
                                obscureText: _obscurePassword,
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.only(
                                    top: 2,
                                    bottom: 2,
                                  ),
                                ),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing:
                                      _obscurePassword ? 2.5 : 0.8,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ).workaroundFreezeLinuxMint(),
                            ),
                          ),
                          if (showOneTime) ...[
                            Tooltip(
                              message: _obscurePassword
                                  ? translate("Show Password")
                                  : translate("Hide Password"),
                              child: IconButton(
                                iconSize: 18,
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(28, 28),
                                  maximumSize: const Size(28, 28),
                                  padding: EdgeInsets.zero,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      CamelliaRadius.control,
                                    ),
                                  ),
                                ),
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  color: subduedColor,
                                ),
                                onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                              ),
                            ),
                            AppCopyFeedbackButton(
                              text: model.serverPasswd.text,
                              tooltip: translate("Copy Password"),
                              size: 28,
                              iconSize: 18,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
