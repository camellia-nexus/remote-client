import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/server_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';

/// Opens the Security / Safety settings tab in-shell when hosted inside
/// `CamelliaDesktopShell`, falling back cleanly to [DesktopSettingPage.switch2page].
void _openSecuritySettings(BuildContext context) {
  DesktopSettingPage.switch2page(SettingsTabKey.safety, context: context);
}

/// Reusable one-click copy button with spring icon morph (`copy -> check`).
class AppCopyFeedbackButton extends StatefulWidget {
  const AppCopyFeedbackButton({
    super.key,
    required this.text,
    required this.tooltip,
    this.copiedTooltip,
    this.size = 30,
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
    HapticFeedback.lightImpact();
    showToast(translate('Copied'));
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
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final isActionable = widget.text.isNotEmpty && widget.text != '-';

    return Tooltip(
      message: _copied
          ? (widget.copiedTooltip ?? translate('Copied'))
          : widget.tooltip,
      child: IconButton(
        iconSize: widget.iconSize,
        style: IconButton.styleFrom(
          minimumSize: Size(widget.size, widget.size),
          maximumSize: Size(widget.size, widget.size),
          padding: EdgeInsets.zero,
          hoverColor: glass.hoverOverlay,
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
            side: BorderSide.none,
          ),
        ),
        onPressed: isActionable ? _copy : null,
        icon: AnimatedSwitcher(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
          switchInCurve: CamelliaMotion.springSnappy,
          switchOutCurve: CamelliaMotion.exit,
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: Icon(
            _copied ? CamelliaIcons.check : CamelliaIcons.copy,
            key: ValueKey<bool>(_copied),
            color: _copied
                ? glass.statusOnline
                : theme.colorScheme.onSurfaceVariant,
            size: widget.iconSize,
          ),
        ),
      ),
    );
  }
}

/// Spring-spin refresh icon button registering a single `onPressed` callback
/// so rotating the refresh glyph never double-invokes the underlying FFI call.
class _SpinRefreshButton extends StatefulWidget {
  const _SpinRefreshButton({
    required this.tooltip,
    required this.onPressed,
    this.size = 30,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  State<_SpinRefreshButton> createState() => _SpinRefreshButtonState();
}

class _SpinRefreshButtonState extends State<_SpinRefreshButton> {
  static const double _iconSize = 18;
  double _turns = 0.0;

  void _trigger() {
    HapticFeedback.selectionClick();
    if (!CamelliaMotion.reduceMotion(context)) {
      setState(() => _turns += 1.0);
    }
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    return Tooltip(
      message: widget.tooltip,
      child: IconButton(
        iconSize: _iconSize,
        style: IconButton.styleFrom(
          minimumSize: Size(widget.size, widget.size),
          maximumSize: Size(widget.size, widget.size),
          padding: EdgeInsets.zero,
          hoverColor: glass.hoverOverlay,
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
            side: BorderSide.none,
          ),
        ),
        onPressed: _trigger,
        icon: AnimatedRotation(
          turns: _turns,
          duration: CamelliaMotion.resolve(context, CamelliaMotion.route),
          curve: CamelliaMotion.springSnappy,
          child: Icon(
            CamelliaIcons.refresh,
            size: _iconSize,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// One-click combined "Copy ID & Password" frosted action pill with spring
/// icon morph (`copy -> check`) and toast feedback.
class _CopyCombinedCredentialsPill extends StatefulWidget {
  const _CopyCombinedCredentialsPill({
    required this.deviceId,
    required this.password,
  });

  final String deviceId;
  final String password;

  @override
  State<_CopyCombinedCredentialsPill> createState() =>
      _CopyCombinedCredentialsPillState();
}

class _CopyCombinedCredentialsPillState
    extends State<_CopyCombinedCredentialsPill> {
  bool _copied = false;
  Timer? _revertTimer;

  bool get _canCopy =>
      widget.deviceId.trim().isNotEmpty &&
      widget.deviceId.trim() != '-' &&
      widget.password.trim().isNotEmpty &&
      widget.password.trim() != '-';

  void _copyCombined() {
    if (!_canCopy) return;
    final payload =
        '${translate('ID')}: ${widget.deviceId}\n${translate('Password')}: ${widget.password}';
    Clipboard.setData(ClipboardData(text: payload));
    HapticFeedback.lightImpact();
    showToast(translate('Copied'));
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
    final glass = CamelliaGlassTokens.of(context);
    return GlassButton(
      variant: GlassButtonVariant.secondary,
      minHeight: 36,
      expand: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      onPressed: _canCopy ? _copyCombined : null,
      icon: AnimatedSwitcher(
        duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
        switchInCurve: CamelliaMotion.springSnappy,
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: animation,
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: Icon(
          _copied ? CamelliaIcons.check : CamelliaIcons.copy,
          key: ValueKey<bool>(_copied),
          size: 16,
          color: _copied ? glass.statusOnline : null,
        ),
      ),
      child: Text(
        _copied
            ? translate('Copied')
            : '${translate('Copy')} ${translate('ID')} & ${translate('Password')}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Unified Apple Liquid Glass local identity card combining This Device ID,
/// masked password readout with reveal/spin-refresh/edit actions, the single
/// live [OnlineStatusWidget] relay pill, and 1-click combined credential copy.
class UnifiedIdentityCard extends StatefulWidget {
  const UnifiedIdentityCard({
    super.key,
    this.showStatus = true,
    this.onOpenSecuritySettings,
  });

  final bool showStatus;
  final VoidCallback? onOpenSecuritySettings;

  @override
  State<UnifiedIdentityCard> createState() => _UnifiedIdentityCardState();
}

class _UnifiedIdentityCardState extends State<UnifiedIdentityCard> {
  // Masked by default for privacy on shared displays.
  bool _obscurePassword = true;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, child) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final tokens = AppVisual.tokens(context);
          final glass = CamelliaGlassTokens.of(context);
          final dark = theme.brightness == Brightness.dark;
          final accent = dark ? scheme.secondary : scheme.primary;

          final isPermanent =
              model.verificationMethod == kUsePermanentPassword;
          final isClickOnly = model.approveMode == 'click';
          final showOneTime = !isClickOnly && !isPermanent;
          final passwordLabel = isPermanent
              ? translate('Permanent Password')
              : translate('One-time Password');
          final accessModeLabel = isClickOnly
              ? translate('Accept sessions via click')
              : isPermanent
              ? translate('Permanent Password')
              : translate('One-time Password');

          final insetRadius = BorderRadius.circular(CamelliaRadius.control);
          final insetBg = tokens.surfaceContainer.withValues(
            alpha: dark ? 0.66 : 0.76,
          );

          return GlassCard(
            layer: CamelliaGlassLayer.floating,
            title: translate('Your Desktop'),
            subtitle: translate('desk_tip'),
            leading: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: dark ? 0.18 : 0.10),
                borderRadius: BorderRadius.circular(CamelliaRadius.control),
                border: Border.all(
                  color: accent.withValues(alpha: dark ? 0.34 : 0.22),
                  width: 0.85,
                ),
              ),
              child: Center(
                child: CamelliaVectorIcon(
                  CamelliaGlyph.key,
                  size: 17,
                  color: accent,
                  duotone: true,
                ),
              ),
            ),
            trailing: widget.showStatus
                ? const OnlineStatusWidget(compact: true)
                : null,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Device ID Hardware-Key Inset
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: insetBg,
                    borderRadius: insetRadius,
                    border: Border.all(color: tokens.border, width: 0.85),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    translate('ID'),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: GlassBadge(
                                      label: accessModeLabel,
                                      tone: isClickOnly
                                          ? GlassBadgeTone.encrypted
                                          : GlassBadgeTone.brand,
                                      compact: true,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              GestureDetector(
                                onDoubleTap: () {
                                  if (model.serverId.text.isEmpty ||
                                      model.serverId.text == '-') {
                                    return;
                                  }
                                  Clipboard.setData(
                                    ClipboardData(text: model.serverId.text),
                                  );
                                  showToast(translate('Copied'));
                                },
                                child: TextFormField(
                                  controller: model.serverId,
                                  readOnly: true,
                                  decoration: const InputDecoration(
                                    filled: false,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      vertical: 5,
                                    ),
                                  ),
                                  style: CamelliaTypography.tabular(
                                    theme.textTheme.headlineSmall?.copyWith(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ).workaroundFreezeLinuxMint(),
                              ),
                            ],
                          ),
                        ),
                        AppCopyFeedbackButton(
                          text: model.serverId.text,
                          tooltip: translate('Copy ID'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // One-Time / Permanent Password Hardware-Key Inset
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: insetBg,
                    borderRadius: insetRadius,
                    border: Border.all(color: tokens.border, width: 0.85),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                passwordLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (showOneTime) ...[
                              _SpinRefreshButton(
                                tooltip: translate('Refresh Password'),
                                onPressed: () {
                                  bind.mainUpdateTemporaryPassword();
                                  showToast(translate('Refreshed'));
                                },
                              ),
                              const SizedBox(width: CamelliaSpace.xxs),
                            ],
                            if (!bind.isDisableSettings())
                              Tooltip(
                                message: translate('Change Password'),
                                child: IconButton(
                                  iconSize: 17,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(30, 30),
                                    maximumSize: const Size(30, 30),
                                    padding: EdgeInsets.zero,
                                    hoverColor: glass.hoverOverlay,
                                    highlightColor: Colors.transparent,
                                    focusColor: Colors.transparent,
                                    splashFactory: NoSplash.splashFactory,
                                    side: BorderSide.none,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        CamelliaRadius.control,
                                      ),
                                      side: BorderSide.none,
                                    ),
                                  ),
                                  icon: Icon(
                                    CamelliaIcons.edit,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  onPressed: () {
                                    if (widget.onOpenSecuritySettings != null) {
                                      widget.onOpenSecuritySettings!();
                                    } else {
                                      _openSecuritySettings(context);
                                    }
                                  },
                                ),
                              ),
                          ],
                        ),
                        Row(
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
                                    showToast(translate('Copied'));
                                  }
                                },
                                child: TextFormField(
                                  controller: model.serverPasswd,
                                  readOnly: true,
                                  obscureText: showOneTime
                                      ? _obscurePassword
                                      : false,
                                  decoration: const InputDecoration(
                                    filled: false,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      vertical: 5,
                                    ),
                                  ),
                                  style: CamelliaTypography.tabular(
                                    theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      letterSpacing:
                                          showOneTime && _obscurePassword
                                          ? 2.4
                                          : 0.8,
                                    ),
                                  ),
                                ).workaroundFreezeLinuxMint(),
                              ),
                            ),
                            if (showOneTime) ...[
                              Tooltip(
                                message: _obscurePassword
                                    ? translate('Show Password')
                                    : translate('Hide Password'),
                                child: IconButton(
                                  iconSize: 18,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(30, 30),
                                    maximumSize: const Size(30, 30),
                                    padding: EdgeInsets.zero,
                                    hoverColor: glass.hoverOverlay,
                                    highlightColor: Colors.transparent,
                                    focusColor: Colors.transparent,
                                    splashFactory: NoSplash.splashFactory,
                                    side: BorderSide.none,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        CamelliaRadius.control,
                                      ),
                                      side: BorderSide.none,
                                    ),
                                  ),
                                  icon: Icon(
                                    _obscurePassword
                                        ? CamelliaIcons.eye
                                        : CamelliaIcons.eyeOff,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                ),
                              ),
                              const SizedBox(width: CamelliaSpace.xxs),
                              AppCopyFeedbackButton(
                                text: model.serverPasswd.text,
                                tooltip: translate('Copy Password'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (showOneTime) ...[
                  const SizedBox(height: 10),
                  _CopyCombinedCredentialsPill(
                    deviceId: model.serverId.text,
                    password: model.serverPasswd.text,
                  ),
                ],
                const SizedBox(height: 10),
                // Compact E2EE security & settings footer strip
                Row(
                  children: [
                    CamelliaVectorIcon(
                      CamelliaGlyph.shieldCheck,
                      size: 14,
                      color: glass.statusEncrypted,
                      duotone: true,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        translate('End-to-end encrypted'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (!bind.isDisableSettings())
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () {
                            if (widget.onOpenSecuritySettings != null) {
                              widget.onOpenSecuritySettings!();
                            } else {
                              _openSecuritySettings(context);
                            }
                          },
                          child: Text(
                            translate('Security'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Standalone frosted Identity ID Board retained for modular reuse and tests.
class IdentityIdBoard extends StatelessWidget {
  const IdentityIdBoard({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, child) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final dark = theme.brightness == Brightness.dark;
          final accent = dark ? scheme.secondary : scheme.primary;

          return GlassCard(
            layer: CamelliaGlassLayer.floating,
            margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: dark ? 0.20 : 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: accent.withValues(alpha: dark ? 0.36 : 0.24),
                      width: 0.9,
                    ),
                  ),
                  child: Icon(Icons.fingerprint_rounded, size: 20, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        translate('ID'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      GestureDetector(
                        onDoubleTap: () {
                          Clipboard.setData(
                            ClipboardData(text: model.serverId.text),
                          );
                          showToast(translate('Copied'));
                        },
                        child: TextFormField(
                          controller: model.serverId,
                          readOnly: true,
                          decoration: const InputDecoration(
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.only(top: 2, bottom: 2),
                          ),
                          style: CamelliaTypography.tabular(
                            theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ).workaroundFreezeLinuxMint(),
                      ),
                    ],
                  ),
                ),
                AppCopyFeedbackButton(
                  text: model.serverId.text,
                  tooltip: translate('Copy ID'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Standalone frosted Password Board retained for modular reuse and tests.
/// Uses a clean neutral frosted surface (never amber warning tint) and a
/// single-registered spring-spin refresh action.
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
          final scheme = theme.colorScheme;
          final glass = CamelliaGlassTokens.of(context);
          final dark = theme.brightness == Brightness.dark;
          final accent = dark ? scheme.secondary : scheme.primary;
          final isPermanent =
              model.verificationMethod == kUsePermanentPassword;
          final showOneTime = model.approveMode != 'click' && !isPermanent;
          final label = isPermanent
              ? translate('Permanent Password')
              : translate('One-time Password');

          return GlassCard(
            layer: CamelliaGlassLayer.floating,
            margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: dark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: accent.withValues(alpha: dark ? 0.36 : 0.24),
                        width: 0.9,
                      ),
                    ),
                    child: Icon(Icons.key_rounded, size: 20, color: accent),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (showOneTime)
                            _SpinRefreshButton(
                              tooltip: translate('Refresh Password'),
                              onPressed: () {
                                bind.mainUpdateTemporaryPassword();
                                showToast(translate('Refreshed'));
                              },
                              size: 28,
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
                                  hoverColor: glass.hoverOverlay,
                                  highlightColor: Colors.transparent,
                                  focusColor: Colors.transparent,
                                  splashFactory: NoSplash.splashFactory,
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      CamelliaRadius.control,
                                    ),
                                    side: BorderSide.none,
                                  ),
                                ),
                                icon: Icon(
                                  CamelliaIcons.edit,
                                  color: scheme.onSurfaceVariant,
                                ),
                                onPressed: () => _openSecuritySettings(context),
                              ),
                            ),
                        ],
                      ),
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
                                  showToast(translate('Copied'));
                                }
                              },
                              child: TextFormField(
                                controller: model.serverPasswd,
                                readOnly: true,
                                obscureText: _obscurePassword,
                                decoration: const InputDecoration(
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.only(
                                    top: 2,
                                    bottom: 2,
                                  ),
                                ),
                                style: CamelliaTypography.tabular(
                                  theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: _obscurePassword ? 2.5 : 0.8,
                                  ),
                                ),
                              ).workaroundFreezeLinuxMint(),
                            ),
                          ),
                          if (showOneTime) ...[
                            Tooltip(
                              message: _obscurePassword
                                  ? translate('Show Password')
                                  : translate('Hide Password'),
                              child: IconButton(
                                iconSize: 18,
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(28, 28),
                                  maximumSize: const Size(28, 28),
                                  padding: EdgeInsets.zero,
                                  hoverColor: glass.hoverOverlay,
                                  highlightColor: Colors.transparent,
                                  focusColor: Colors.transparent,
                                  splashFactory: NoSplash.splashFactory,
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      CamelliaRadius.control,
                                    ),
                                    side: BorderSide.none,
                                  ),
                                ),
                                icon: Icon(
                                  _obscurePassword
                                      ? CamelliaIcons.eye
                                      : CamelliaIcons.eyeOff,
                                  color: scheme.onSurfaceVariant,
                                ),
                                onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                              ),
                            ),
                            const SizedBox(width: CamelliaSpace.xxs),
                            AppCopyFeedbackButton(
                              text: model.serverPasswd.text,
                              tooltip: translate('Copy Password'),
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
