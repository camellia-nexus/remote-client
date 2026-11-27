import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

void showServerSettings(
  OverlayDialogManager dialogManager,
  void Function(VoidCallback) setState,
) async {
  try {
    final rawOptions = await bind.mainGetOptions();
    final decoded = jsonDecode(rawOptions);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Server options is not a valid JSON map');
    }
    showServerSettingsWithValue(
      ServerConfig.fromOptions(decoded),
      dialogManager,
      setState,
    );
  } catch (e) {
    debugPrint('Failed to load server config: $e');
    dialogManager.show((setStateDialog, close, context) {
      return CustomAlertDialog(
        title: ModernDialogHeader.error(
          title: translate('ID/Relay Server'),
          subtitle: translate('Failed to load server configuration'),
          onClose: close,
        ),
        content: SelectableText(formatUserFriendlyError(e.toString())),
        actions: [
          GlassButton(
            variant: GlassButtonVariant.secondary,
            minHeight: 38,
            onPressed: close,
            child: Text(translate('Cancel')),
          ),
          GlassButton(
            variant: GlassButtonVariant.primary,
            minHeight: 38,
            icon: const Icon(CamelliaIcons.refresh, size: 16),
            onPressed: () {
              close();
              showServerSettings(dialogManager, setState);
            },
            child: Text(translate('Retry')),
          ),
        ],
        onCancel: close,
      );
    });
  }
}

void showServerSettingsWithValue(
  ServerConfig serverConfig,
  OverlayDialogManager dialogManager,
  void Function(VoidCallback)? upSetState,
) async {
  var isInProgress = false;
  var isClosed = false;
  final idCtrl = TextEditingController(text: serverConfig.idServer);
  final relayCtrl = TextEditingController(text: serverConfig.relayServer);
  final apiCtrl = TextEditingController(text: serverConfig.apiServer);
  final keyCtrl = TextEditingController(text: serverConfig.key);

  final RxString idServerMsg = ''.obs;
  final RxString relayServerMsg = ''.obs;
  final RxString apiServerMsg = ''.obs;

  final controllers = [idCtrl, relayCtrl, apiCtrl, keyCtrl];
  final errMsgs = [idServerMsg, relayServerMsg, apiServerMsg];

  try {
    await dialogManager.show((setState, close, context) {
      void onCancel() {
        if (isClosed) return;
        isClosed = true;
        close();
      }

      void clearAll() {
        if (isClosed) return;
        for (final c in controllers) {
          c.clear();
        }
        for (final m in errMsgs) {
          m.value = '';
        }
        setState(() {});
      }

      Future<bool> submit() async {
        if (isInProgress || isClosed) return false;
        setState(() {
          isInProgress = true;
        });
        final ret = await setServerConfig(
          null,
          errMsgs,
          ServerConfig(
            idServer: idCtrl.text.trim(),
            relayServer: relayCtrl.text.trim(),
            apiServer: apiCtrl.text.trim(),
            key: keyCtrl.text.trim(),
          ),
        );
        if (!isClosed) {
          setState(() {
            isInProgress = false;
          });
        }
        return ret;
      }

      Future<void> onOk() async {
        if (await submit()) {
          if (isClosed) return;
          isClosed = true;
          close();
          showToast(translate('Successful'));
          upSetState?.call(() {});
        } else {
          if (isClosed) return;
          showToast(translate('Failed'));
        }
      }

      return CustomAlertDialog(
        title: ModernDialogHeader(
          icon: Icons.dns_rounded,
          title: translate('ID/Relay Server'),
          subtitle: translate(
            'Configure custom rendezvous, relay, and API endpoints',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: ServerConfigImportExportWidgets(
              controllers,
              errMsgs,
              isClosed: () => isClosed,
            ),
          ),
          onClose: onCancel,
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: math.max(
              0.0,
              math.min(MediaQuery.sizeOf(context).width - 48, 480.0),
            ),
            maxWidth: 500.0,
          ),
          child: Form(
            child: Obx(
              () => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isInProgress) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                      child: const LinearProgressIndicator(minHeight: 2.5),
                    ),
                    const SizedBox(height: 12),
                  ],
                  serverSettingsTextFormField(
                    label: translate('ID Server'),
                    hintText: 'id.example.com:21116',
                    prefixIcon: Icons.hub_outlined,
                    controller: idCtrl,
                    errorMsg: idServerMsg.value,
                    autofocus: true,
                    onSubmitted: (_) => onOk(),
                  ).workaroundFreezeLinuxMint(),
                  const SizedBox(height: 12),
                  if (!isIOS && !isWeb) ...[
                    serverSettingsTextFormField(
                      label: translate('Relay Server'),
                      hintText: 'relay.example.com:21117',
                      prefixIcon: Icons.swap_horiz_rounded,
                      controller: relayCtrl,
                      errorMsg: relayServerMsg.value,
                      onSubmitted: (_) => onOk(),
                    ).workaroundFreezeLinuxMint(),
                    const SizedBox(height: 12),
                  ],
                  serverSettingsTextFormField(
                    label: translate('API Server'),
                    hintText: 'https://api.example.com',
                    prefixIcon: Icons.cloud_outlined,
                    controller: apiCtrl,
                    errorMsg: apiServerMsg.value,
                    validator: (v) {
                      if (v != null && v.isNotEmpty) {
                        if (!(v.startsWith('http://') ||
                            v.startsWith('https://'))) {
                          return translate('invalid_http');
                        }
                      }
                      return null;
                    },
                    onSubmitted: (_) => onOk(),
                  ).workaroundFreezeLinuxMint(),
                  const SizedBox(height: 12),
                  serverSettingsTextFormField(
                    label: translate('Key'),
                    hintText: translate('Public key'),
                    prefixIcon: Icons.vpn_key_outlined,
                    controller: keyCtrl,
                    errorMsg: '',
                    onSubmitted: (_) => onOk(),
                  ).workaroundFreezeLinuxMint(),
                ],
              ),
            ),
          ),
        ),
        actions: [
          GlassButton(
            variant: GlassButtonVariant.ghost,
            minHeight: 38,
            onPressed: isInProgress ? null : clearAll,
            child: Text(translate('Clear')),
          ),
          GlassButton(
            variant: GlassButtonVariant.secondary,
            minHeight: 38,
            onPressed: onCancel,
            child: Text(translate('Cancel')),
          ),
          GlassButton(
            variant: GlassButtonVariant.primary,
            minHeight: 38,
            loading: isInProgress,
            onPressed: isInProgress ? null : onOk,
            child: Text(translate('OK')),
          ),
        ],
        onSubmit: onOk,
        onCancel: onCancel,
      );
    });
  } finally {
    isClosed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in controllers) {
        c.dispose();
      }
      for (final m in errMsgs) {
        m.close();
      }
    });
  }
}

/// Precision frosted technical text field preserving literal host/key input
/// (no autocorrect, smart quotes, smart dashes, capitalization, or spellcheck).
Widget serverSettingsTextFormField({
  required String label,
  required TextEditingController controller,
  required String errorMsg,
  String? hintText,
  IconData? prefixIcon,
  String? Function(String?)? validator,
  bool autofocus = false,
  bool showLabelText = true,
  EdgeInsetsGeometry? contentPadding,
  ValueChanged<String>? onSubmitted,
}) {
  return _ServerLiteralGlassField(
    label: label,
    controller: controller,
    errorMsg: errorMsg,
    hintText: hintText,
    prefixIcon: prefixIcon,
    validator: validator,
    autofocus: autofocus,
    showLabelText: showLabelText,
    contentPadding: contentPadding,
    onSubmitted: onSubmitted,
  );
}

class _ServerLiteralGlassField extends StatefulWidget {
  const _ServerLiteralGlassField({
    required this.label,
    required this.controller,
    required this.errorMsg,
    this.hintText,
    this.prefixIcon,
    this.validator,
    this.autofocus = false,
    this.showLabelText = true,
    this.contentPadding,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String errorMsg;
  final String? hintText;
  final IconData? prefixIcon;
  final String? Function(String?)? validator;
  final bool autofocus;
  final bool showLabelText;
  final EdgeInsetsGeometry? contentPadding;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_ServerLiteralGlassField> createState() =>
      _ServerLiteralGlassFieldState();
}

class _ServerLiteralGlassFieldState extends State<_ServerLiteralGlassField> {
  final FocusNode _focusNode = FocusNode();
  bool _hovered = false;
  bool _focused = false;
  bool _hasText = false;
  String? _validationMsg;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _ServerLiteralGlassField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
      _hasText = widget.controller.text.isNotEmpty;
    }
  }

  void _onTextChanged() {
    final nextHasText = widget.controller.text.isNotEmpty;
    final nextVal = widget.validator?.call(widget.controller.text);
    if ((nextHasText != _hasText || nextVal != _validationMsg) && mounted) {
      setState(() {
        _hasText = nextHasText;
        _validationMsg = nextVal;
      });
    }
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus != _focused && mounted) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final resolvedError = widget.errorMsg.isNotEmpty
        ? widget.errorMsg
        : (_validationMsg ?? '');
    final hasError = resolvedError.isNotEmpty;
    final radius = BorderRadius.circular(CamelliaRadius.control);

    final baseBg = _hovered
        ? Color.alphaBlend(glass.hoverOverlay, glass.floatingTint)
        : glass.floatingTint;
    final borderTop = hasError
        ? glass.statusAlert
        : _focused
        ? accent.withValues(alpha: 0.85)
        : glass.specularTop;
    final borderBottom = hasError
        ? glass.statusAlert.withValues(alpha: 0.78)
        : _focused
        ? accent.withValues(alpha: 0.55)
        : glass.specularBottom;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showLabelText && widget.label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              widget.label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: hasError
                    ? glass.statusAlert
                    : _focused
                    ? accent
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        MouseRegion(
          onEnter: (_) {
            if (mounted) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (mounted) setState(() => _hovered = false);
          },
          child: AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
            curve: CamelliaMotion.standard,
            constraints: const BoxConstraints(minHeight: 44),
            decoration: BoxDecoration(
              color: baseBg,
              borderRadius: radius,
              boxShadow: [
                if (_focused)
                  BoxShadow(
                    color: (hasError ? glass.statusAlert : glass.focusGlow)
                        .withValues(alpha: dark ? 0.32 : 0.22),
                    blurRadius: 8,
                    spreadRadius: 0.5,
                  ),
              ],
            ),
            child: CustomPaint(
              foregroundPainter: SpecularEdgePainter(
                borderRadius: radius,
                topColor: borderTop,
                bottomColor: borderBottom,
                strokeWidth: (_focused || hasError) ? 1.2 : 0.85,
              ),
              child: Padding(
                padding:
                    widget.contentPadding ??
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: Row(
                  children: [
                    if (widget.prefixIcon != null) ...[
                      Icon(
                        widget.prefixIcon,
                        size: 18,
                        color: hasError
                            ? glass.statusAlert
                            : _focused
                            ? accent
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        focusNode: _focusNode,
                        autofocus: widget.autofocus,
                        keyboardType: TextInputType.visiblePassword,
                        textCapitalization: TextCapitalization.none,
                        autocorrect: false,
                        enableSuggestions: false,
                        smartDashesType: SmartDashesType.disabled,
                        smartQuotesType: SmartQuotesType.disabled,
                        enableIMEPersonalizedLearning: false,
                        spellCheckConfiguration:
                            const SpellCheckConfiguration.disabled(),
                        onSubmitted: widget.onSubmitted,
                        style: CamelliaTypography.tabular(
                          theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        cursorColor: accent,
                        decoration: InputDecoration(
                          hintText: widget.hintText,
                          hintStyle: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.72),
                          ),
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    if (_hasText)
                      Tooltip(
                        message: translate('Clear'),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(
                            CamelliaRadius.pill,
                          ),
                          onTap: () {
                            widget.controller.clear();
                            HapticFeedback.selectionClick();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              CamelliaIcons.close,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              resolvedError,
              style: theme.textTheme.bodySmall?.copyWith(
                color: glass.statusAlert,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
