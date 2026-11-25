import 'dart:async';
import 'dart:convert';

import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/peer_tab_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/credential_controls.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/utils/http_service.dart' as http;
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'address_book.dart';

const String _kPortInputRegex =
    r'^$|^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$';

class ModernDialogHeader extends StatelessWidget {
  const ModernDialogHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconWidget,
    this.tone = AppTone.brand,
    this.onClose,
    this.trailing,
  });

  const ModernDialogHeader.confirm({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.check_circle_outline_rounded,
    this.iconWidget,
    this.tone = AppTone.success,
    this.onClose,
    this.trailing,
  });

  const ModernDialogHeader.warning({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.warning_amber_rounded,
    this.iconWidget,
    this.tone = AppTone.warning,
    this.onClose,
    this.trailing,
  });

  const ModernDialogHeader.error({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.error_outline_rounded,
    this.iconWidget,
    this.tone = AppTone.danger,
    this.onClose,
    this.trailing,
  });

  const ModernDialogHeader.info({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.info_outline_rounded,
    this.iconWidget,
    this.tone = AppTone.info,
    this.onClose,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? iconWidget;
  final AppTone tone;
  final VoidCallback? onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    final toneColor = AppVisual.tone(context, tone);
    final toneBg = AppVisual.toneContainer(context, tone);

    final Widget badge =
        iconWidget ??
        (icon != null
            ? Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: toneBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: toneColor.withValues(alpha: 0.24),
                    width: 0.85,
                  ),
                ),
                child: Center(
                  child: Icon(icon, color: toneColor, size: 21),
                ),
              )
            : const SizedBox.shrink());

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null || iconWidget != null) ...[
          badge,
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
        if (onClose != null) ...[
          const SizedBox(width: 8),
          IconButton(
            onPressed: onClose,
            tooltip: translate('Close'),
            icon: const Icon(Icons.close_rounded, size: 18),
            style: IconButton.styleFrom(
              padding: const EdgeInsets.all(6),
              minimumSize: const Size(30, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ],
    );
  }
}

class _DialogInlineAlert extends StatelessWidget {
  const _DialogInlineAlert({
    required this.message,
    this.tone = AppTone.danger,
  });

  final String message;
  final AppTone tone;

  @override
  Widget build(BuildContext context) {
    if (message.trim().isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final toneColor = AppVisual.tone(context, tone);
    final iconData = switch (tone) {
      AppTone.danger => Icons.error_outline_rounded,
      AppTone.warning => Icons.warning_amber_rounded,
      AppTone.success => Icons.check_circle_outline_rounded,
      _ => Icons.info_outline_rounded,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: toneColor.withValues(alpha: dark ? 0.16 : 0.09),
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        border: Border.all(
          color: toneColor.withValues(alpha: dark ? 0.34 : 0.24),
          width: 0.85,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(iconData, size: 17, color: toneColor),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogSwitchRow extends StatelessWidget {
  const _DialogSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassSurface(
      layer: CamelliaGlassLayer.floating,
      showShadow: false,
      enableBlur: false,
      strokeWidth: 0.85,
      borderRadius: BorderRadius.circular(CamelliaRadius.control),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Switch.adaptive(
                  value: value,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void clientClose(SessionID sessionId, FFI ffi) async {
  if (allowAskForNoteAtEndOfConnection(ffi, true)) {
    if (await showConnEndAuditDialogCloseCanceled(ffi: ffi)) {
      return;
    }
    closeConnection();
  } else {
    msgBox(
      sessionId,
      'info',
      'Close',
      'Are you sure to close the connection?',
      '',
      ffi.dialogManager,
    );
  }
}

abstract class ValidationRule {
  String get name;
  bool validate(String value);
}

class LengthRangeValidationRule extends ValidationRule {
  final int _min;
  final int _max;

  LengthRangeValidationRule(this._min, this._max);

  @override
  String get name => translate(
    'length %min% to %max%',
  ).replaceAll('%min%', _min.toString()).replaceAll('%max%', _max.toString());

  @override
  bool validate(String value) {
    return value.length >= _min && value.length <= _max;
  }
}

class RegexValidationRule extends ValidationRule {
  final String _name;
  final RegExp _regex;

  RegexValidationRule(this._name, this._regex);

  @override
  String get name => translate(_name);

  @override
  bool validate(String value) {
    return value.isNotEmpty ? value.contains(_regex) : false;
  }
}

void changeIdDialog() {
  if (isChangeIdDisabled()) {
    return;
  }
  var newId = '';
  var msg = '';
  var isInProgress = false;
  var isCancelled = false;
  var dialogGen = 0;
  final TextEditingController controller = TextEditingController();
  final RxString rxId = controller.text.trim().obs;

  final rules = [
    RegexValidationRule('starts with a letter', RegExp(r'^[a-zA-Z]')),
    LengthRangeValidationRule(6, 16),
    RegexValidationRule('allowed characters', RegExp(r'^[\w-]*$')),
  ];

  gFFI.dialogManager.show((setState, close, context) {
    void handleCancel() {
      isCancelled = true;
      close();
      try {
        controller.dispose();
      } catch (_) {}
    }

    Future<void> submit() async {
      if (isInProgress || isCancelled) return;
      newId = controller.text.trim();

      final Iterable<ValidationRule> violations = rules.where(
        (r) => !r.validate(newId),
      );
      if (violations.isNotEmpty) {
        setState(() {
          msg = (isDesktop || isWebDesktop)
              ? '${translate('Prompt')}: ${violations.map((r) => r.name).join(', ')}'
              : violations.map((r) => r.name).join(', ');
        });
        return;
      }

      final currentGen = ++dialogGen;
      setState(() {
        msg = '';
        isInProgress = true;
      });

      try {
        await bind.mainChangeId(newId: newId);
        var status = await bind.mainGetAsyncStatus();
        int pollCount = 0;
        const maxPolls = 150; // 15 seconds bounded polling
        while (status == ' ' &&
            !isCancelled &&
            currentGen == dialogGen &&
            pollCount < maxPolls) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (isCancelled || currentGen != dialogGen) return;
          status = await bind.mainGetAsyncStatus();
          pollCount++;
        }
        if (isCancelled || currentGen != dialogGen) return;
        if (pollCount >= maxPolls) {
          status = 'Timeout';
        }
        if (status.isEmpty) {
          handleCancel();
          return;
        }
        setState(() {
          isInProgress = false;
          msg = (isDesktop || isWebDesktop)
              ? '${translate('Prompt')}: ${formatUserFriendlyError(status)}'
              : formatUserFriendlyError(status);
        });
      } catch (e) {
        if (isCancelled || currentGen != dialogGen) return;
        setState(() {
          isInProgress = false;
          msg = formatUserFriendlyError(e.toString());
        });
      }
    }

    final theme = Theme.of(context);
    return CustomAlertDialog(
      title: ModernDialogHeader(
        title: translate('Change ID'),
        subtitle: translate('id_change_tip'),
        icon: Icons.badge_outlined,
        tone: AppTone.brand,
        onClose: handleCancel,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 360, maxWidth: 440),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassInput(
            labelText: translate('Your new ID'),
            prefixIcon: Icons.tag_rounded,
            controller: controller,
            autofocus: true,
            tabularNums: true,
            errorText: msg.isEmpty ? null : translate(msg),
            inputFormatters: [LengthLimitingTextInputFormatter(16)],
            trailing: Obx(
              () => Text(
                '${rxId.value.length}/16',
                style: CamelliaTypography.tabular(
                  theme.textTheme.labelSmall?.copyWith(
                    color: AppVisual.subduedText(context),
                  ),
                ),
              ),
            ),
            onChanged: (value) {
              setState(() {
                rxId.value = value.trim();
                msg = '';
              });
            },
            onSubmitted: (_) => submit(),
          ).workaroundFreezeLinuxMint(),
          const SizedBox(height: 10),
          if (isDesktop || isWebDesktop)
            Obx(
              () => Wrap(
                runSpacing: 6,
                spacing: 6,
                children: rules.map((e) {
                  final checked = e.validate(rxId.value);
                  return GlassBadge(
                    label: e.name,
                    icon: checked ? CamelliaIcons.check : CamelliaIcons.close,
                    tone: checked
                        ? GlassBadgeTone.online
                        : GlassBadgeTone.danger,
                    compact: true,
                  );
                }).toList(),
              ),
            ),
        ],
      ),
      actions: [
        GlassButton(
          variant: GlassButtonVariant.secondary,
          minHeight: 38,
          onPressed: handleCancel,
          child: Text(translate('Cancel')),
        ),
        GlassButton(
          variant: GlassButtonVariant.primary,
          minHeight: 38,
          loading: isInProgress,
          onPressed: isInProgress ? null : submit,
          child: Text(translate('OK')),
        ),
      ],
      onSubmit: isInProgress ? null : submit,
      onCancel: handleCancel,
    );
  });
}

void changeWhiteList({Function()? callback}) async {
  final curWhiteList = await bind.mainGetOption(key: kOptionWhitelist);
  var newWhiteListField = curWhiteList == defaultOptionWhitelist
      ? ''
      : curWhiteList.split(',').join('\n');
  final controller = TextEditingController(text: newWhiteListField);
  var msg = '';
  var isInProgress = false;
  final isOptFixed = isOptionFixed(kOptionWhitelist);
  gFFI.dialogManager.show((setState, close, context) {
    void safeClose() {
      try {
        controller.dispose();
      } catch (_) {}
      close();
    }

    Future<void> submit() async {
      setState(() {
        msg = '';
        isInProgress = true;
      });
      newWhiteListField = controller.text.trim();
      var newWhiteList = '';
      if (newWhiteListField.isNotEmpty) {
        final ips = newWhiteListField.trim().split(RegExp(r'[\s,;\n]+'));
        final ipMatch = RegExp(
          r'^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)(\/([0-9]|[1-2][0-9]|3[0-2])){0,1}$',
        );
        final ipv6Match = RegExp(
          r'^(((?:[0-9A-Fa-f]{1,4}))*((?::[0-9A-Fa-f]{1,4}))*::((?:[0-9A-Fa-f]{1,4}))*((?::[0-9A-Fa-f]{1,4}))*|((?:[0-9A-Fa-f]{1,4}))((?::[0-9A-Fa-f]{1,4})){7})(\/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])){0,1}$',
        );
        for (final ip in ips) {
          final trimmedIp = ip.trim();
          if (trimmedIp.isEmpty) continue;
          final lower = trimmedIp.toLowerCase();
          if (lower == '0.0.0.0' ||
              lower == '0.0.0.0/32' ||
              lower == '::' ||
              lower == '::/128' ||
              lower == '0:0:0:0:0:0:0:0' ||
              lower == '0:0:0:0:0:0:0:0/128') {
            msg =
                '${translate("Invalid IP")}: $trimmedIp (${translate("Unspecified IP address not allowed")})';
            setState(() {
              isInProgress = false;
            });
            return;
          }
          if (!ipMatch.hasMatch(trimmedIp) && !ipv6Match.hasMatch(trimmedIp)) {
            msg = '${translate("Invalid IP")} $trimmedIp';
            setState(() {
              isInProgress = false;
            });
            return;
          }
        }
        newWhiteList = ips
            .map((x) => x.trim())
            .where((x) => x.isNotEmpty)
            .join(',');
      }
      if (newWhiteList.trim().isEmpty) {
        newWhiteList = defaultOptionWhitelist;
      }
      await bind.mainSetOption(key: kOptionWhitelist, value: newWhiteList);
      callback?.call();
      safeClose();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        title: translate('IP Whitelisting'),
        subtitle: translate('whitelist_sep'),
        icon: CamelliaIcons.shield,
        tone: AppTone.brand,
        onClose: safeClose,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 380, maxWidth: 460),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassInput(
            controller: controller,
            enabled: !isOptFixed,
            autofocus: true,
            maxLines: 4,
            minHeight: 100,
            showClearButton: false,
            tabularNums: true,
            hintText: '192.168.1.100\n10.0.0.0/24',
            errorText: msg.isEmpty ? null : translate(msg),
            onChanged: (_) {
              if (msg.isNotEmpty) {
                setState(() => msg = '');
              }
            },
          ).workaroundFreezeLinuxMint(),
        ],
      ),
      actions: [
        GlassButton(
          variant: GlassButtonVariant.secondary,
          minHeight: 38,
          onPressed: safeClose,
          child: Text(translate('Cancel')),
        ),
        if (!isOptFixed)
          GlassButton(
            variant: GlassButtonVariant.ghost,
            minHeight: 38,
            onPressed: () async {
              await bind.mainSetOption(
                key: kOptionWhitelist,
                value: defaultOptionWhitelist,
              );
              callback?.call();
              safeClose();
            },
            child: Text(translate('Clear')),
          ),
        if (!isOptFixed)
          GlassButton(
            variant: GlassButtonVariant.primary,
            minHeight: 38,
            loading: isInProgress,
            onPressed: isInProgress ? null : submit,
            child: Text(translate('OK')),
          ),
      ],
      onCancel: safeClose,
    );
  });
}

Future<String?> changeDirectAccessPort(
  String currentIP,
  String currentPort,
) async {
  final controller = TextEditingController(text: currentPort);
  String? committed;
  try {
    await gFFI.dialogManager.show((setState, close, context) {
      Future<void> submit() async {
        final newPort = controller.text.trim();
        await bind.mainSetOption(key: kOptionDirectAccessPort, value: newPort);
        committed = newPort;
        close();
      }

      final theme = Theme.of(context);
      return CustomAlertDialog(
        title: ModernDialogHeader(
          title: translate('Change Local Port'),
          subtitle: translate(
            'Set the TCP listening port for direct IP connections',
          ),
          icon: Icons.settings_ethernet_rounded,
          tone: AppTone.brand,
          onClose: close,
        ),
        contentBoxConstraints: const BoxConstraints(
          minWidth: 340,
          maxWidth: 420,
        ),
        content: GlassInput(
          controller: controller,
          autofocus: true,
          tabularNums: true,
          hintText: '21118',
          keyboardType: TextInputType.number,
          leading: Text(
            '$currentIP :',
            style: CamelliaTypography.tabular(
              theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(_kPortInputRegex)),
          ],
          onSubmitted: (_) => submit(),
        ).workaroundFreezeLinuxMint(),
        actions: [
          dialogButton('Cancel', onPressed: close, isOutline: true),
          dialogButton('OK', onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    });
  } finally {
    controller.dispose();
  }
  return committed;
}

Future<String?> changeAutoDisconnectTimeout(String old) async {
  final controller = TextEditingController(text: old);
  String? committed;
  try {
    await gFFI.dialogManager.show((setState, close, context) {
      Future<void> submit() async {
        final newTimeout = controller.text.trim();
        await bind.mainSetOption(
          key: kOptionAutoDisconnectTimeout,
          value: newTimeout,
        );
        committed = newTimeout;
        close();
      }

      final theme = Theme.of(context);
      return CustomAlertDialog(
        title: ModernDialogHeader(
          title: translate('Timeout in minutes'),
          subtitle: translate(
            'Automatically close inactive incoming sessions after timeout',
          ),
          icon: Icons.timer_outlined,
          tone: AppTone.brand,
          onClose: close,
        ),
        contentBoxConstraints: const BoxConstraints(
          minWidth: 340,
          maxWidth: 420,
        ),
        content: GlassInput(
          controller: controller,
          autofocus: true,
          tabularNums: true,
          hintText: '10',
          prefixIcon: Icons.schedule_rounded,
          keyboardType: TextInputType.number,
          trailing: Text(
            translate('min'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^$|^(0|[1-9]\d{0,3})$')),
          ],
          onSubmitted: (_) => submit(),
        ).workaroundFreezeLinuxMint(),
        actions: [
          dialogButton('Cancel', onPressed: close, isOutline: true),
          dialogButton('OK', onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    });
  } finally {
    controller.dispose();
  }
  return committed;
}

class DialogTextField extends StatelessWidget {
  final String title;
  final String? hintText;
  final bool obscureText;
  final String? errorText;
  final String? helperText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final bool autofocus;
  final bool tabularNums;
  final bool showClearButton;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  static const kUsernameTitle = 'Username';
  static const kUsernameIcon = Icon(Icons.person_outline_rounded, size: 18);
  static const kPasswordTitle = 'Password';
  static const kPasswordIcon = Icon(CamelliaIcons.lock, size: 18);

  const DialogTextField({
    super.key,
    this.focusNode,
    this.obscureText = false,
    this.errorText,
    this.helperText,
    this.prefixIcon,
    this.suffixIcon,
    this.hintText,
    this.keyboardType,
    this.inputFormatters,
    this.maxLength,
    this.autofocus = true,
    this.tabularNums = false,
    this.showClearButton = true,
    this.onChanged,
    this.onSubmitted,
    required this.title,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedFormatters = <TextInputFormatter>[
      ...?inputFormatters,
      if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassInput(
            labelText: title,
            hintText: hintText,
            leading: prefixIcon == null
                ? null
                : IconTheme.merge(
                    data: IconThemeData(
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    child: prefixIcon!,
                  ),
            trailing: suffixIcon,
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            obscureText: obscureText,
            tabularNums: tabularNums,
            showClearButton: showClearButton && !obscureText,
            keyboardType: keyboardType,
            inputFormatters: resolvedFormatters.isEmpty
                ? null
                : resolvedFormatters,
            errorText: errorText,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ).workaroundFreezeLinuxMint(),
          if (helperText != null && helperText!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5, left: 4),
              child: Text(
                helperText!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

abstract class ValidationField extends StatelessWidget {
  const ValidationField({super.key});

  String? validate();
  bool get isReady;
}

class Dialog2FaField extends ValidationField {
  Dialog2FaField({
    super.key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.title,
    this.hintText,
    this.errorText,
    this.readyCallback,
    this.onChanged,
  });

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? title;
  final String? hintText;
  final String? errorText;
  final VoidCallback? readyCallback;
  final VoidCallback? onChanged;
  final String errMsg = translate('2FA code must be 6 digits.');

  @override
  Widget build(BuildContext context) {
    return DialogVerificationCodeField(
      title: title ?? translate('2FA code'),
      controller: controller,
      errorText: errorText,
      autoFocus: autoFocus,
      reRequestFocus: reRequestFocus,
      hintText: hintText ?? '000000',
      readyCallback: readyCallback,
      onChanged: _onChanged,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
        LengthLimitingTextInputFormatter(6),
      ],
    );
  }

  String get text => controller.text;
  bool get isAllDigits => text.codeUnits.every((e) => e >= 48 && e <= 57);

  @override
  bool get isReady => text.length == 6 && isAllDigits;

  @override
  String? validate() => isReady ? null : errMsg;

  void _onChanged(StateSetter setState, SimpleWrapper<String?> errText) {
    onChanged?.call();

    if (text.length > 6) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (!isAllDigits) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (isReady) {
      readyCallback?.call();
      return;
    }

    if (errText.value != null) {
      setState(() => errText.value = null);
    }
  }
}

class DialogEmailCodeField extends ValidationField {
  DialogEmailCodeField({
    super.key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.hintText,
    this.errorText,
    this.readyCallback,
    this.onChanged,
  });

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? hintText;
  final String? errorText;
  final VoidCallback? readyCallback;
  final VoidCallback? onChanged;
  final String errMsg = translate(
    'Email verification code must be 6 characters.',
  );

  @override
  Widget build(BuildContext context) {
    return DialogVerificationCodeField(
      title: translate('Verification code'),
      controller: controller,
      errorText: errorText,
      autoFocus: autoFocus,
      reRequestFocus: reRequestFocus,
      hintText: hintText ?? '000000',
      readyCallback: readyCallback,
      helperText: translate('verification_tip'),
      onChanged: _onChanged,
      keyboardType: TextInputType.visiblePassword,
      inputFormatters: [LengthLimitingTextInputFormatter(6)],
    );
  }

  String get text => controller.text;

  @override
  bool get isReady => text.length == 6;

  @override
  String? validate() => isReady ? null : errMsg;

  void _onChanged(StateSetter setState, SimpleWrapper<String?> errText) {
    onChanged?.call();

    if (text.length > 6) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (isReady) {
      readyCallback?.call();
      return;
    }

    if (errText.value != null) {
      setState(() => errText.value = null);
    }
  }
}

class DialogVerificationCodeField extends StatefulWidget {
  const DialogVerificationCodeField({
    super.key,
    required this.controller,
    required this.title,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.helperText,
    this.hintText,
    this.errorText,
    this.textLength,
    this.readyCallback,
    this.onChanged,
    this.keyboardType,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String title;
  final String? helperText;
  final String? hintText;
  final String? errorText;
  final int? textLength;
  final VoidCallback? readyCallback;
  final Function(StateSetter setState, SimpleWrapper<String?> errText)?
  onChanged;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<DialogVerificationCodeField> createState() =>
      _DialogVerificationCodeField();
}

class _DialogVerificationCodeField extends State<DialogVerificationCodeField> {
  final _focusNode = FocusNode();
  Timer? _timer;
  Timer? _timerReRequestFocus;
  SimpleWrapper<String?> errorText = SimpleWrapper(null);
  String _preText = '';
  VoidCallback? _controllerListener;
  VoidCallback? _focusListener;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocus) {
      _timer = Timer(
        const Duration(milliseconds: 50),
        () {
          if (mounted && _focusNode.canRequestFocus) {
            _focusNode.requestFocus();
          }
        },
      );
    }

    if (widget.onChanged != null) {
      _controllerListener = () {
        final text = widget.controller.text.trim();
        if (text == _preText) return;
        widget.onChanged!(setState, errorText);
        _preText = text;
      };
      widget.controller.addListener(_controllerListener!);
    }

    if (isAndroid && widget.reRequestFocus) {
      _focusListener = () {
        if (_focusNode.hasFocus) {
          _timerReRequestFocus?.cancel();
          _timerReRequestFocus = Timer(
            const Duration(milliseconds: 100),
            () {
              if (mounted && _focusNode.canRequestFocus) {
                _focusNode.requestFocus();
              }
            },
          );
        }
      };
      _focusNode.addListener(_focusListener!);
    }
  }

  @override
  void didUpdateWidget(covariant DialogVerificationCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (_controllerListener != null) {
        oldWidget.controller.removeListener(_controllerListener!);
        widget.controller.addListener(_controllerListener!);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timerReRequestFocus?.cancel();
    if (_controllerListener != null) {
      widget.controller.removeListener(_controllerListener!);
    }
    if (_focusListener != null) {
      _focusNode.removeListener(_focusListener!);
    }
    _focusNode.unfocus();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogTextField(
      title: widget.title,
      hintText: widget.hintText,
      prefixIcon: const Icon(CamelliaIcons.shield, size: 18),
      controller: widget.controller,
      errorText: widget.errorText ?? errorText.value,
      focusNode: _focusNode,
      helperText: widget.helperText,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      tabularNums: true,
      onSubmitted: (_) => widget.readyCallback?.call(),
    );
  }
}

class PasswordWidget extends StatefulWidget {
  const PasswordWidget({
    super.key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.hintText,
    this.errorText,
    this.title,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? hintText;
  final String? errorText;
  final String? title;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordWidget> createState() => _PasswordWidgetState();
}

class _PasswordWidgetState extends State<PasswordWidget> {
  bool _passwordVisible = false;
  final _focusNode = FocusNode();
  final _shakeController = GlassShakeController();
  Timer? _timer;
  Timer? _timerReRequestFocus;

  @override
  void initState() {
    super.initState();
    if (widget.errorText != null && widget.errorText!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _shakeController.shake();
        final text = widget.controller.text;
        if (text.isNotEmpty) {
          widget.controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: text.length,
          );
        }
        if (_focusNode.canRequestFocus) {
          _focusNode.requestFocus();
        }
      });
    } else if (widget.autoFocus) {
      _timer = Timer(
        const Duration(milliseconds: 50),
        () {
          if (mounted && _focusNode.canRequestFocus) {
            _focusNode.requestFocus();
          }
        },
      );
    }
    if (isAndroid && widget.reRequestFocus) {
      _focusNode.addListener(() {
        if (_focusNode.hasFocus) {
          _timerReRequestFocus?.cancel();
          _timerReRequestFocus = Timer(
            const Duration(milliseconds: 100),
            () {
              if (mounted && _focusNode.canRequestFocus) {
                _focusNode.requestFocus();
              }
            },
          );
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant PasswordWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newError = widget.errorText?.trim() ?? '';
    final oldError = oldWidget.errorText?.trim() ?? '';
    if (newError.isNotEmpty && newError != oldError) {
      _shakeController.shake();
      final text = widget.controller.text;
      if (text.isNotEmpty) {
        widget.controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: text.length,
        );
      }
      if (_focusNode.canRequestFocus) {
        _focusNode.requestFocus();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timerReRequestFocus?.cancel();
    _focusNode.unfocus();
    _focusNode.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassShakeBox(
      controller: _shakeController,
      child: DialogTextField(
        title: translate(widget.title ?? DialogTextField.kPasswordTitle),
        hintText: widget.hintText == null
            ? translate('Enter your password')
            : (widget.hintText!.isEmpty ? '' : translate(widget.hintText!)),
        controller: widget.controller,
        prefixIcon: DialogTextField.kPasswordIcon,
        showClearButton: false,
        suffixIcon: Tooltip(
          message: translate(
            _passwordVisible ? 'Hide password' : 'Show password',
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CamelliaRadius.pill),
            onTap: () {
              setState(() {
                _passwordVisible = !_passwordVisible;
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                _passwordVisible ? CamelliaIcons.eye : CamelliaIcons.eyeOff,
                size: 17,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        obscureText: !_passwordVisible,
        errorText: widget.errorText,
        focusNode: _focusNode,
        maxLength: widget.maxLength,
        autofocus: widget.autoFocus,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}

final Map<String, String> _lastSessionPassword = {};

void wrongPasswordDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager,
  dynamic type,
  dynamic title,
  dynamic text,
) {
  final rawText = text?.toString().trim() ?? '';
  final errText = rawText.isNotEmpty
      ? formatUserFriendlyError(rawText)
      : translate('Wrong Password');
  final previousPassword = _lastSessionPassword[sessionId.toString()] ?? '';
  enterPasswordDialog(
    sessionId,
    dialogManager,
    initialError: errText,
    initialPassword: previousPassword,
  );
}

void enterPasswordDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager, {
  String? initialError,
  String? initialPassword,
}) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    passwordController: TextEditingController(text: initialPassword ?? ''),
    initialPasswordError: initialError,
  );
}

void enterUserLoginDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager,
  String osAccountDescTip,
  bool canRememberAccount,
) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    osUsernameController: TextEditingController(),
    osPasswordController: TextEditingController(),
    osAccountDescTip: osAccountDescTip,
    canRememberAccount: canRememberAccount,
  );
}

void enterUserLoginAndPasswordDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager,
  String osAccountDescTip,
  bool canRememberAccount,
) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    osUsernameController: TextEditingController(),
    osPasswordController: TextEditingController(),
    passwordController: TextEditingController(),
    osAccountDescTip: osAccountDescTip,
    canRememberAccount: canRememberAccount,
  );
}

Future<void> _connectDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager, {
  TextEditingController? osUsernameController,
  TextEditingController? osPasswordController,
  TextEditingController? passwordController,
  String? osAccountDescTip,
  bool canRememberAccount = true,
  String? initialPasswordError,
}) async {
  final errUsername = ''.obs;
  final errPassword = (initialPasswordError ?? '').obs;
  var submitting = false;
  var rememberPassword = false;
  if (passwordController != null) {
    rememberPassword =
        await bind.sessionGetRemember(sessionId: sessionId) ?? false;
  }
  var rememberAccount = false;
  if (canRememberAccount && osUsernameController != null) {
    rememberAccount =
        await bind.sessionGetRemember(sessionId: sessionId) ?? false;
  }
  if (osUsernameController != null) {
    osUsernameController.addListener(() {
      if (errUsername.value.isNotEmpty) {
        errUsername.value = '';
      }
    });
  }
  passwordController?.addListener(() {
    if (errPassword.value.isNotEmpty) errPassword.value = '';
  });

  dialogManager.dismissAll();
  try {
    await dialogManager.show((setState, close, context) {
      void cancel() {
        submitting = false;
        close();
        closeConnection();
      }

      void submit() {
        if (submitting) return;
        if (osUsernameController != null &&
            osUsernameController.text.trim().isEmpty) {
          errUsername.value = translate('Empty Username');
          setState(() {});
          return;
        }
        final osUsername = osUsernameController?.text.trim() ?? '';
        final osPassword = osPasswordController?.text.trim() ?? '';
        final password = passwordController?.text.trim() ?? '';
        if (passwordController != null && password.isEmpty) {
          errPassword.value = translate('Password Required');
          setState(() {});
          return;
        }
        if (password.isNotEmpty) {
          _lastSessionPassword[sessionId.toString()] = password;
        }
        setState(() => submitting = true);
        if (rememberAccount) {
          bind.sessionPeerOption(
            sessionId: sessionId,
            name: 'os-username',
            value: osUsername,
          );
          bind.sessionPeerOption(
            sessionId: sessionId,
            name: 'os-password',
            value: osPassword,
          );
        }
        gFFI.login(
          osUsername,
          osPassword,
          sessionId,
          password,
          rememberPassword,
        );
        close();
        dialogManager.showLoading(
          translate('Logging in...'),
          onCancel: closeConnection,
        );
      }

      Widget descWidget(String text) {
        final colorScheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  text,
                  softWrap: true,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      Widget rememberWidget(
        String desc,
        bool remember,
        ValueChanged<bool?>? onChanged,
      ) {
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: CredentialRememberControl(
            label: desc,
            value: remember,
            compactIconOnly: false,
            onChanged: onChanged == null ? null : (next) => onChanged(next),
          ),
        );
      }

      Widget osAccountWidget() {
        if (osUsernameController == null || osPasswordController == null) {
          return const SizedBox.shrink();
        }
        return _CredentialSection(
          icon: Icons.person_outline_rounded,
          title: translate('OS Account'),
          children: [
            if (osAccountDescTip != null)
              descWidget(translate(osAccountDescTip)),
            Obx(
              () => DialogTextField(
                title: translate(DialogTextField.kUsernameTitle),
                controller: osUsernameController,
                prefixIcon: DialogTextField.kUsernameIcon,
                errorText: errUsername.value.isEmpty ? null : errUsername.value,
                onSubmitted: (_) {
                  if (passwordController == null) submit();
                },
              ),
            ),
            PasswordWidget(
              controller: osPasswordController,
              autoFocus: false,
              onSubmitted: (_) {
                if (passwordController == null) submit();
              },
            ),
            if (canRememberAccount)
              rememberWidget(
                translate('remember_account_tip'),
                rememberAccount,
                (v) {
                  if (v != null) {
                    setState(() => rememberAccount = v);
                  }
                },
              ),
          ],
        );
      }

      Widget passwdWidget() {
        if (passwordController == null) {
          return const SizedBox.shrink();
        }
        return _CredentialSection(
          icon: CamelliaIcons.shield,
          title: translate('Connection password'),
          children: [
            descWidget(translate('verify_rustdesk_password_tip')),
            Obx(
              () => PasswordWidget(
                controller: passwordController,
                autoFocus: osUsernameController == null,
                errorText: errPassword.value.isEmpty ? null : errPassword.value,
                onSubmitted: (_) => submit(),
              ),
            ),
            rememberWidget(translate('Remember password'), rememberPassword, (
              v,
            ) {
              if (v != null) {
                setState(() => rememberPassword = v);
              }
            }),
          ],
        );
      }

      final hasInitialError =
          initialPasswordError != null && initialPasswordError.isNotEmpty;
      final titleWidget = ModernDialogHeader(
        title: translate('Password Required'),
        subtitle: translate('Authenticate to continue the secure session'),
        icon: CamelliaIcons.lock,
        tone: hasInitialError ? AppTone.danger : AppTone.brand,
        onClose: cancel,
      );
      final contentWidget = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 360, maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Obx(() {
              final bannerText = errPassword.value.isNotEmpty
                  ? errPassword.value
                  : errUsername.value;
              if (bannerText.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _DialogInlineAlert(message: bannerText),
              );
            }),
            osAccountWidget(),
            if (osUsernameController != null && passwordController != null)
              const SizedBox(height: 14),
            passwdWidget(),
          ],
        ),
      );

      return CustomAlertDialog(
        title: titleWidget,
        content: contentWidget,
        contentBoxConstraints: const BoxConstraints(
          minWidth: 360,
          maxWidth: 420,
        ),
        actions: [
          GlassButton(
            variant: GlassButtonVariant.secondary,
            minHeight: 38,
            icon: const Icon(CamelliaIcons.close, size: 16),
            onPressed: cancel,
            child: Text(translate('Cancel')),
          ),
          GlassButton(
            variant: GlassButtonVariant.primary,
            minHeight: 38,
            loading: submitting,
            icon: const Icon(CamelliaIcons.arrowForward, size: 16),
            onPressed: submitting ? null : submit,
            child: Text(translate('Connect')),
          ),
        ],
        onSubmit: submitting ? null : submit,
        onCancel: cancel,
      );
    });
  } finally {
    osUsernameController?.dispose();
    osPasswordController?.dispose();
    passwordController?.dispose();
  }
}

class _CredentialSection extends StatelessWidget {
  const _CredentialSection({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

void showWaitUacDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager,
  String type,
) {
  dialogManager.dismissAll();
  dialogManager.show(
    tag: '$sessionId-wait-uac',
    (setState, close, context) => CustomAlertDialog(
      title: ModernDialogHeader.info(
        title: translate('Wait'),
        onClose: close,
      ),
      content: Text(formatUserFriendlyError('wait_accept_uac_tip')),
      actions: [
        dialogButton('OK', icon: const Icon(CamelliaIcons.check), onPressed: close),
      ],
      onCancel: close,
    ),
  );
}

Future<void> showRequestElevationDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager,
) async {
  final groupValue = ''.obs;
  final errUser = ''.obs;
  final errPwd = ''.obs;
  final userController = TextEditingController();
  final pwdController = TextEditingController();

  void onRadioChanged(String? value) {
    if (value != null) {
      groupValue.value = value;
    }
  }

  dialogManager.dismissAll();
  try {
    await dialogManager.show<void>((setState, close, context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final dark = theme.brightness == Brightness.dark;
      final accent = dark ? scheme.secondary : scheme.primary;

      Widget choiceCard({
        required String value,
        required IconData icon,
        required String title,
        required String subtitle,
      }) {
        final selected = groupValue.value == value;
        return GlassSurface(
          layer: CamelliaGlassLayer.floating,
          showShadow: false,
          enableBlur: false,
          strokeWidth: selected ? 1.2 : 0.85,
          tintColor: selected
              ? accent.withValues(alpha: dark ? 0.16 : 0.09)
              : null,
          borderTopColor: selected ? accent.withValues(alpha: 0.65) : null,
          borderBottomColor: selected ? accent.withValues(alpha: 0.40) : null,
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(CamelliaRadius.surface),
              onTap: () => onRadioChanged(value),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 68),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(10, 10, 14, 10),
                  child: Row(
                    children: [
                      Radio<String>(value: value),
                      const SizedBox(width: 4),
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: selected
                              ? accent.withValues(alpha: 0.16)
                              : scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          icon,
                          size: 20,
                          color: selected ? accent : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subtitle,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }

      void submit() {
        if (groupValue.value == 'logon') {
          if (userController.text.trim().isEmpty) {
            errUser.value = translate('Empty Username');
            return;
          }
          if (pwdController.text.isEmpty) {
            errPwd.value = translate('Empty Password');
            return;
          }
          final username = userController.text.trim();
          final password = pwdController.text;
          pwdController.clear();
          userController.clear();
          bind.sessionElevateWithLogon(
            sessionId: sessionId,
            username: username,
            password: password,
          );
        } else {
          bind.sessionElevateDirect(sessionId: sessionId);
        }
        close();
        showWaitUacDialog(sessionId, dialogManager, 'wait-uac');
      }

      return CustomAlertDialog(
        title: ModernDialogHeader(
          icon: Icons.admin_panel_settings_rounded,
          title: translate('Request Elevation'),
          subtitle: translate(
            'Select how administrator privileges should be granted',
          ),
          onClose: close,
        ),
        contentBoxConstraints: const BoxConstraints(maxWidth: 540),
        content: Obx(
          () => RadioGroup<String>(
            groupValue: groupValue.value,
            onChanged: onRadioChanged,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                choiceCard(
                  value: '',
                  icon: Icons.person_rounded,
                  title: translate('Ask the remote user for authentication'),
                  subtitle: translate(
                    'Choose this if the remote account is administrator',
                  ),
                ),
                const SizedBox(height: 10),
                choiceCard(
                  value: 'logon',
                  icon: Icons.key_rounded,
                  title: translate(
                    'Transmit the username and password of administrator',
                  ),
                  subtitle: translate('elevation_username_tip'),
                ),
                AnimatedSwitcher(
                  duration: CamelliaMotion.resolve(
                    context,
                    CamelliaMotion.feedback,
                  ),
                  child: groupValue.value != 'logon'
                      ? const SizedBox.shrink(key: ValueKey('direct-elevation'))
                      : Padding(
                          key: const ValueKey('credential-elevation'),
                          padding: const EdgeInsets.only(top: 12),
                          child: GlassSurface(
                            layer: CamelliaGlassLayer.floating,
                            showShadow: false,
                            enableBlur: false,
                            strokeWidth: 0.85,
                            borderRadius: BorderRadius.circular(
                              CamelliaRadius.surface,
                            ),
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.info_outline_rounded,
                                      size: 18,
                                      color: accent,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        translate('still_click_uac_tip'),
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                DialogTextField(
                                  controller: userController,
                                  title: translate('Username'),
                                  hintText: translate('elevation_username_tip'),
                                  prefixIcon: DialogTextField.kUsernameIcon,
                                  errorText: errUser.isEmpty
                                      ? null
                                      : errUser.value,
                                  onChanged: (_) => errUser.value = '',
                                ),
                                PasswordWidget(
                                  controller: pwdController,
                                  autoFocus: false,
                                  errorText: errPwd.isEmpty
                                      ? null
                                      : errPwd.value,
                                  onChanged: (_) => errPwd.value = '',
                                  onSubmitted: (_) => submit(),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          dialogButton(
            'Cancel',
            icon: const Icon(CamelliaIcons.close),
            onPressed: close,
            isOutline: true,
          ),
          dialogButton(
            'Continue',
            icon: const Icon(CamelliaIcons.arrowForward),
            onPressed: submit,
          ),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    }, tag: '$sessionId-request-elevation');
  } finally {
    pwdController.clear();
    userController.clear();
    userController.dispose();
    pwdController.dispose();
    groupValue.close();
    errUser.close();
    errPwd.close();
  }
}

void showOnBlockDialog(
  SessionID sessionId,
  String type,
  String title,
  String text,
  OverlayDialogManager dialogManager,
) {
  if (dialogManager.existing('$sessionId-wait-uac') ||
      dialogManager.existing('$sessionId-request-elevation')) {
    return;
  }
  dialogManager.show(tag: '$sessionId-$type', (setState, close, context) {
    void submit() {
      close();
      showRequestElevationDialog(sessionId, dialogManager);
    }

    return CustomAlertDialog(
      title: ModernDialogHeader.warning(
        title: translate(title.isNotEmpty ? title : 'Prompt'),
        onClose: close,
      ),
      contentBoxConstraints: const BoxConstraints(maxWidth: 440),
      content: Text(
        '${formatUserFriendlyError(text)}${type.contains('uac') ? '\n' : '\n\n'}${translate('request_elevation_tip')}',
      ),
      actions: [
        dialogButton('Wait', onPressed: close, isOutline: true),
        dialogButton('Request Elevation', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void showElevationError(
  SessionID sessionId,
  String type,
  String title,
  String text,
  OverlayDialogManager dialogManager,
) {
  dialogManager.show(tag: '$sessionId-$type', (setState, close, context) {
    void submit() {
      close();
      showRequestElevationDialog(sessionId, dialogManager);
    }

    return CustomAlertDialog(
      title: ModernDialogHeader.error(
        title: translate(title.isNotEmpty ? title : 'Elevation Error'),
        onClose: close,
      ),
      content: Text(formatUserFriendlyError(text)),
      actions: [
        dialogButton(
          'Cancel',
          onPressed: close,
          isOutline: true,
        ),
        if (text != 'No permission') dialogButton('Retry', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void showWaitAcceptDialog(
  SessionID sessionId,
  String type,
  String title,
  String text,
  OverlayDialogManager dialogManager,
) {
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    void onCancel() {
      close();
      closeConnection();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader.info(
        title: translate(title.isNotEmpty ? title : 'Wait'),
        onClose: onCancel,
      ),
      content: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(formatUserFriendlyError(text))),
        ],
      ),
      actions: [dialogButton('Cancel', onPressed: onCancel, isOutline: true)],
      onCancel: onCancel,
    );
  });
}

void showRestartRemoteDevice(
  PeerInfo pi,
  String id,
  SessionID sessionId,
  OverlayDialogManager dialogManager,
) async {
  final res = await dialogManager.show<bool>(
    (setState, close, context) => CustomAlertDialog(
      title: ModernDialogHeader.warning(
        title: translate('Restart remote device'),
        tone: AppTone.danger,
        onClose: () => close(false),
      ),
      content: Text(
        '${translate('Are you sure you want to restart')} \n${pi.username}@${pi.hostname}($id) ?',
      ),
      actions: [
        dialogButton(
          'Cancel',
          icon: const Icon(CamelliaIcons.close),
          onPressed: close,
          isOutline: true,
        ),
        dialogButton(
          'OK',
          icon: const Icon(CamelliaIcons.check),
          isDestructive: true,
          onPressed: () => close(true),
        ),
      ],
      onCancel: close,
      onSubmit: () => close(true),
    ),
  );
  if (res == true) bind.sessionRestartRemoteDevice(sessionId: sessionId);
}

Future<void> showSetOSPassword(
  SessionID sessionId,
  bool login,
  OverlayDialogManager dialogManager,
  String? osPassword,
  Function()? closeCallback,
) async {
  final controller = TextEditingController();
  final hasSavedPassword = bind.sessionHasOsPassword(sessionId: sessionId);
  var autoLogin =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'auto-login') !=
      '';
  if (osPassword != null && osPassword.isNotEmpty) {
    controller.text = osPassword;
  }
  dialogManager.show((setState, close, context) {
    var isClosed = false;
    void closeWithCallback([dynamic _]) {
      if (isClosed) return;
      isClosed = true;
      controller.clear();
      controller.dispose();
      close();
      closeCallback?.call();
    }

    void submit() {
      final text = controller.text.trim();
      if (text.isNotEmpty || !hasSavedPassword) {
        bind.sessionPeerOption(
          sessionId: sessionId,
          name: 'os-password',
          value: text,
        );
      }
      bind.sessionPeerOption(
        sessionId: sessionId,
        name: 'auto-login',
        value: autoLogin ? 'Y' : '',
      );
      if (text.isNotEmpty && login) {
        bind.sessionInputOsPassword(sessionId: sessionId, value: text);
      } else if (text.isEmpty && hasSavedPassword && login) {
        bind.sessionInputStoredOsPassword(sessionId: sessionId);
      }
      closeWithCallback();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.lock,
        title: translate('OS Password'),
        subtitle: translate('Configure remote OS login password'),
        onClose: closeWithCallback,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PasswordWidget(
            controller: controller,
            hintText: hasSavedPassword ? 'Unchanged' : null,
            onSubmitted: (_) => submit(),
          ),
          const SizedBox(height: 8),
          _DialogSwitchRow(
            label: translate('Auto Login'),
            value: autoLogin,
            onChanged: (v) => setState(() => autoLogin = v),
          ),
        ],
      ),
      actions: [
        dialogButton(
          'Cancel',
          icon: const Icon(CamelliaIcons.close),
          onPressed: closeWithCallback,
          isOutline: true,
        ),
        dialogButton(
          'OK',
          icon: const Icon(CamelliaIcons.check),
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: closeWithCallback,
    );
  });
}

Future<void> showSetOSAccount(
  SessionID sessionId,
  OverlayDialogManager dialogManager,
) async {
  final usernameController = TextEditingController();
  final passwdController = TextEditingController();
  final username =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'os-username') ??
      '';
  final hasSavedPassword = bind.sessionHasOsPassword(sessionId: sessionId);
  usernameController.text = username;
  dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      usernameController.clear();
      passwdController.clear();
      usernameController.dispose();
      passwdController.dispose();
      close();
    }

    void submit() {
      final user = usernameController.text.trim();
      final password = passwdController.text.trim();
      bind.sessionPeerOption(
        sessionId: sessionId,
        name: 'os-username',
        value: user,
      );
      if (password.isNotEmpty || !hasSavedPassword) {
        bind.sessionPeerOption(
          sessionId: sessionId,
          name: 'os-password',
          value: password,
        );
      }
      safeClose();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: Icons.badge_outlined,
        title: translate('OS Account'),
        subtitle: translate('os_account_desk_tip'),
        onClose: safeClose,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 360, maxWidth: 420),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DialogTextField(
            title: translate(DialogTextField.kUsernameTitle),
            controller: usernameController,
            prefixIcon: DialogTextField.kUsernameIcon,
          ),
          PasswordWidget(
            controller: passwdController,
            autoFocus: false,
            hintText: hasSavedPassword ? 'Unchanged' : null,
            onSubmitted: (_) => submit(),
          ),
        ],
      ),
      actions: [
        dialogButton(
          'Cancel',
          icon: const Icon(CamelliaIcons.close),
          onPressed: safeClose,
          isOutline: true,
        ),
        dialogButton(
          'OK',
          icon: const Icon(CamelliaIcons.check),
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: safeClose,
    );
  });
}

Widget buildNoteTextField({
  required TextEditingController controller,
  required VoidCallback onEscape,
}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final accent = theme.brightness == Brightness.dark
          ? theme.colorScheme.secondary
          : theme.colorScheme.primary;
      return Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            onEscape();
            return KeyEventResult.handled;
          }
          if (event.logicalKey != LogicalKeyboardKey.enter &&
              event.logicalKey != LogicalKeyboardKey.numpadEnter) {
            return KeyEventResult.ignored;
          }

          final text = controller.text;
          final selection = controller.selection;
          final rawStart = selection.isValid ? selection.start : text.length;
          final rawEnd = selection.isValid ? selection.end : text.length;
          final start = rawStart.clamp(0, text.length);
          final end = rawEnd.clamp(start, text.length);
          controller.value = TextEditingValue(
            text: text.replaceRange(start, end, '\n'),
            selection: TextSelection.collapsed(offset: start + 1),
          );
          return KeyEventResult.handled;
        },
        child: GlassSurface(
          layer: CamelliaGlassLayer.floating,
          showShadow: false,
          enableBlur: false,
          strokeWidth: 0.85,
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            autofocus: true,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            cursorColor: accent,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: translate('input note here'),
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.72,
                ),
              ),
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
            ),
            minLines: 4,
            maxLines: null,
            maxLength: 256,
            controller: controller,
          ),
        ),
      ).workaroundFreezeLinuxMint();
    },
  );
}

Future<void> showAuditDialog(FFI ffi) async {
  final controller = TextEditingController(
    text: bind.sessionGetLastAuditNote(sessionId: ffi.sessionId),
  );
  ffi.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      controller.dispose();
      close();
    }

    void submit() {
      final text = controller.text;
      bind.sessionSendNote(sessionId: ffi.sessionId, note: text);
      safeClose();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: Icons.edit_note_rounded,
        title: translate('Note'),
        subtitle: translate('Record an audit note for this session'),
        onClose: safeClose,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: SizedBox(
        width: 360,
        child: buildNoteTextField(controller: controller, onEscape: safeClose),
      ),
      actions: [
        dialogButton('Cancel', onPressed: safeClose, isOutline: true),
        dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: safeClose,
    );
  });
}

bool allowAskForNoteAtEndOfConnection(FFI? ffi, bool closedByControlling) {
  if (ffi == null) {
    return false;
  }
  return mainGetLocalBoolOptionSync(kOptionAllowAskForNoteAtEndOfConnection) &&
      bind
          .sessionGetAuditServerSync(sessionId: ffi.sessionId, typ: 'conn')
          .isNotEmpty &&
      bind.sessionGetAuditGuid(sessionId: ffi.sessionId).isNotEmpty &&
      bind.sessionGetLastAuditNote(sessionId: ffi.sessionId).isEmpty &&
      (!closedByControlling ||
          bind.willSessionCloseCloseSession(sessionId: ffi.sessionId));
}

Future<bool> desktopTryShowTabAuditDialogCloseCancelled({
  required String id,
  required DesktopTabController tabController,
}) async {
  try {
    final page = tabController.state.value.tabs
        .firstWhere((tab) => tab.key == id)
        .page;
    final ffi = (page as dynamic).ffi;
    final res = await showConnEndAuditDialogCloseCanceled(ffi: ffi);
    return res;
  } catch (e) {
    debugPrint('Failed to show audit dialog: $e');
    return false;
  }
}

Future<bool> showConnEndAuditDialogCloseCanceled({
  required FFI ffi,
  String? type,
  String? title,
  String? text,
}) async {
  final res = await _showConnEndAuditDialogCloseCanceled(
    ffi: ffi,
    type: type,
    title: title,
    text: text,
  );
  return res == true;
}

Future<bool> updateAuditNoteByGuid(String auditGuid, String note) async {
  debugPrint(
    'Updating audit note for GUID: $auditGuid, note length: ${note.length}',
  );
  try {
    final apiServer = await bind.mainGetApiServer();
    if (apiServer.isEmpty) {
      debugPrint('API server is empty, cannot update audit note');
      return false;
    }
    final url = '$apiServer/api/audit';
    final headers = getHttpHeaders();
    headers['Content-Type'] = 'application/json';
    final body = jsonEncode({'guid': auditGuid, 'note': note});

    final response = await http.put(
      Uri.parse(url),
      headers: headers,
      body: body,
    );

    if (response.statusCode == 200) {
      debugPrint('Successfully updated audit note for GUID: $auditGuid');
      return true;
    } else {
      debugPrint(
        'Failed to update audit note. Status: ${response.statusCode}, Body length: ${response.body.length}',
      );
      return false;
    }
  } catch (e) {
    debugPrint('Error updating audit note: $e');
    return false;
  }
}

Future<bool?> _showConnEndAuditDialogCloseCanceled({
  required FFI ffi,
  String? type,
  String? title,
  String? text,
}) async {
  final closedByControlling = type == null;
  final showDialog = allowAskForNoteAtEndOfConnection(ffi, closedByControlling);
  if (!showDialog) {
    return false;
  }
  ffi.dialogManager.dismissAll();

  final controller = TextEditingController();
  bool askForNote = mainGetLocalBoolOptionSync(
    kOptionAllowAskForNoteAtEndOfConnection,
  );
  final isOptFixed = isOptionFixed(kOptionAllowAskForNoteAtEndOfConnection);
  bool isInProgress = false;

  return await ffi.dialogManager.show<bool>((setState, close, context) {
    var isClosed = false;
    void safeClose(bool? result) {
      if (isClosed) return;
      isClosed = true;
      controller.dispose();
      close(result);
    }

    void cancel() {
      safeClose(true);
    }

    Future<bool> saveNote() async {
      if (isInProgress) return false;
      setState(() {
        isInProgress = true;
      });
      final noteText = controller.text;
      if (noteText.isNotEmpty) {
        bool updateSuccess = false;
        try {
          updateSuccess =
              await updateAuditNoteByGuid(
                bind.sessionGetAuditGuid(sessionId: ffi.sessionId),
                noteText,
              ).timeout(
                const Duration(seconds: 6),
                onTimeout: () {
                  debugPrint('updateAuditNoteByGuid timeout after 6s');
                  return false;
                },
              );
        } catch (e) {
          debugPrint('Error updating audit note: $e');
          updateSuccess = false;
        }
        if (!updateSuccess) {
          setState(() {
            isInProgress = false;
          });
          showToast(translate('Failed to update audit note'));
          return false;
        }
      }
      if (!isOptFixed) {
        await mainSetLocalBoolOption(
          kOptionAllowAskForNoteAtEndOfConnection,
          askForNote,
        );
      }
      return true;
    }

    Future<void> submit() async {
      if (await saveNote()) {
        safeClose(false);
      }
    }

    final buttons = <Widget>[
      if (closedByControlling)
        GlassButton(
          variant: GlassButtonVariant.secondary,
          minHeight: 38,
          onPressed: isInProgress ? null : cancel,
          child: Text(translate('Cancel')),
        ),
      if (type == 'relay-hint' || type == 'relay-hint2')
        GlassButton(
          variant: GlassButtonVariant.secondary,
          minHeight: 38,
          onPressed: () async {
            if (await saveNote()) {
              safeClose(true);
              ffi.ffiModel.reconnect(ffi.dialogManager, ffi.sessionId, false);
            }
          },
          child: Text(translate('Retry')),
        ),
      if (type == 'relay-hint2')
        GlassButton(
          variant: GlassButtonVariant.secondary,
          minHeight: 38,
          onPressed: () async {
            if (await saveNote()) {
              safeClose(true);
              ffi.ffiModel.reconnect(ffi.dialogManager, ffi.sessionId, true);
            }
          },
          child: Text(translate('Connect via relay')),
        ),
      GlassButton(
        variant: GlassButtonVariant.primary,
        minHeight: 38,
        loading: isInProgress,
        onPressed: isInProgress ? null : submit,
        child: Text(translate('OK')),
      ),
    ];

    final Widget headerSummary = closedByControlling
        ? SelectionArea(
            child: msgboxContent(
              'info',
              'Close',
              'Are you sure to close the connection?',
            ),
          )
        : SelectionArea(
            child: msgboxContent(type, title ?? '', text ?? ''),
          );

    return CustomAlertDialog(
      title: null,
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            headerSummary,
            const SizedBox(height: 12),
            buildNoteTextField(controller: controller, onEscape: cancel),
            if (!isOptFixed) ...[
              const SizedBox(height: 10),
              _DialogSwitchRow(
                label: translate('note-at-conn-end-tip'),
                value: askForNote,
                onChanged: (v) => setState(() => askForNote = v),
              ),
            ],
          ],
        ),
      ),
      actions: buttons,
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void showConfirmSwitchSidesDialog(
  SessionID sessionId,
  String id,
  OverlayDialogManager dialogManager,
) async {
  dialogManager.show((setState, close, context) {
    Future<void> submit() async {
      await bind.sessionSwitchSides(sessionId: sessionId);
      closeConnection(id: id);
    }

    return CustomAlertDialog(
      title: ModernDialogHeader.info(
        title: translate('Switch Sides'),
        onClose: close,
      ),
      content: Text(
        translate('Please confirm if you want to share your desktop?'),
      ),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

Future<void> customImageQualityDialog(
  SessionID sessionId,
  String id,
  FFI ffi,
) async {
  double initQuality = kDefaultQuality;
  double initFps = kDefaultFps;
  bool qualitySet = false;
  bool fpsSet = false;

  final bool hideFps = versionCmp(ffi.ffiModel.pi.version, '1.2.0') < 0;
  final bool hideMoreQuality = versionCmp(ffi.ffiModel.pi.version, '1.2.2') < 0;

  Future<void> setCustomValues({double? quality, double? fps}) async {
    if (quality != null) {
      qualitySet = true;
      await bind.sessionSetCustomImageQuality(
        sessionId: sessionId,
        value: quality.toInt(),
      );
    }
    if (fps != null) {
      fpsSet = true;
      await bind.sessionSetCustomFps(sessionId: sessionId, fps: fps.toInt());
    }
    if (!qualitySet) {
      qualitySet = true;
      await bind.sessionSetCustomImageQuality(
        sessionId: sessionId,
        value: initQuality.toInt(),
      );
    }
    if (!hideFps && !fpsSet) {
      fpsSet = true;
      await bind.sessionSetCustomFps(
        sessionId: sessionId,
        fps: initFps.toInt(),
      );
    }
  }

  final btnClose = dialogButton(
    'Close',
    onPressed: () async {
      await setCustomValues();
      ffi.dialogManager.dismissAll();
    },
  );

  final quality = await bind.sessionGetCustomImageQuality(sessionId: sessionId);
  initQuality = quality != null && quality.isNotEmpty
      ? quality[0].toDouble()
      : kDefaultQuality;
  if (initQuality < kMinQuality ||
      initQuality > (!hideMoreQuality ? kMaxMoreQuality : kMaxQuality)) {
    initQuality = kDefaultQuality;
  }

  final fpsOption = await bind.sessionGetOption(
    sessionId: sessionId,
    arg: 'custom-fps',
  );
  initFps = fpsOption == null
      ? kDefaultFps
      : double.tryParse(fpsOption) ?? kDefaultFps;
  if (initFps < kMinFps || initFps > kMaxFps) {
    initFps = kDefaultFps;
  }

  final content = customImageQualityWidget(
    initQuality: initQuality,
    initFps: initFps,
    setQuality: (v) => setCustomValues(quality: v),
    setFps: (v) => setCustomValues(fps: v),
    showFps: !hideFps,
    showMoreQuality: !hideMoreQuality,
  );
  msgBoxCommon(ffi.dialogManager, 'Custom Image Quality', content, [btnClose]);
}

Future<void> trackpadSpeedDialog(SessionID sessionId, FFI ffi) async {
  final int initSpeed = ffi.inputModel.trackpadSpeed;
  final curSpeed = SimpleWrapper(initSpeed);
  final btnClose = dialogButton(
    'Close',
    onPressed: () async {
      if (curSpeed.value <= kMaxTrackpadSpeed &&
          curSpeed.value >= kMinTrackpadSpeed &&
          curSpeed.value != initSpeed) {
        await bind.sessionSetTrackpadSpeed(
          sessionId: sessionId,
          value: curSpeed.value,
        );
        await ffi.inputModel.updateTrackpadSpeed();
      }
      ffi.dialogManager.dismissAll();
    },
  );
  msgBoxCommon(
    ffi.dialogManager,
    'Trackpad speed',
    TrackpadSpeedWidget(value: curSpeed),
    [btnClose],
  );
}

void deleteConfirmDialog(
  FutureOr<dynamic> Function() onSubmit,
  String title,
) async {
  bool isInProgress = false;
  gFFI.dialogManager.show((setState, close, context) {
    Future<void> submit() async {
      if (isInProgress) return;
      setState(() {
        isInProgress = true;
      });
      try {
        final res = await onSubmit();
        if (res == false) {
          setState(() {
            isInProgress = false;
          });
          return;
        }
        close();
      } catch (e) {
        debugPrint('deleteConfirmDialog error: $e');
        showToast(translate('Failed'));
        setState(() {
          isInProgress = false;
        });
      }
    }

    return CustomAlertDialog(
      title: ModernDialogHeader.error(
        title: title,
        subtitle: translate('This action cannot be undone.'),
        onClose: close,
      ),
      actions: [
        dialogButton(
          'Cancel',
          icon: const Icon(CamelliaIcons.close),
          onPressed: close,
          isOutline: true,
        ),
        GlassButton(
          variant: GlassButtonVariant.danger,
          minHeight: 38,
          loading: isInProgress,
          icon: const Icon(CamelliaIcons.trash, size: 16),
          onPressed: isInProgress ? null : submit,
          child: Text(translate('OK')),
        ),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void editAbTagDialog(
  List<dynamic> currentTags,
  FutureOr<dynamic> Function(List<dynamic>) onSubmit,
) {
  var isInProgress = false;

  final tags = List.of(gFFI.abModel.currentAbTags);
  final selectedTag = currentTags.obs;

  gFFI.dialogManager.show((setState, close, context) {
    Future<void> submit() async {
      if (isInProgress) return;
      setState(() {
        isInProgress = true;
      });
      try {
        final res = await onSubmit(selectedTag);
        if (res == false) {
          setState(() {
            isInProgress = false;
          });
          return;
        }
        close();
      } catch (e) {
        debugPrint('editAbTagDialog error: $e');
        showToast(translate('Failed'));
        setState(() {
          isInProgress = false;
        });
      }
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        title: translate('Edit Tag'),
        icon: Icons.label_outline_rounded,
        tone: AppTone.brand,
        onClose: close,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Wrap(
              children: tags
                  .map(
                    (e) => AddressBookTag(
                      name: e,
                      tags: selectedTag,
                      onTap: () {
                        if (selectedTag.contains(e)) {
                          selectedTag.remove(e);
                        } else {
                          selectedTag.add(e);
                        }
                      },
                      showActionMenu: false,
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        GlassButton(
          variant: GlassButtonVariant.primary,
          minHeight: 38,
          loading: isInProgress,
          onPressed: isInProgress ? null : submit,
          child: Text(translate('OK')),
        ),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void editAbPeerNoteDialog(String id) {
  var isInProgress = false;
  final currentNote = gFFI.abModel.getPeerNote(id);
  final controller = TextEditingController(text: currentNote);

  gFFI.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      controller.dispose();
      close();
    }

    Future<void> submit() async {
      if (isInProgress) return;
      setState(() {
        isInProgress = true;
      });
      try {
        final ok = await gFFI.abModel.changeNote(id: id, note: controller.text);
        if (ok) {
          showToast(translate('Successful'));
          safeClose();
        } else {
          showToast(translate('Failed'));
          setState(() {
            isInProgress = false;
          });
        }
      } catch (e) {
        debugPrint('editAbPeerNoteDialog error: $e');
        showToast(translate('Failed'));
        setState(() {
          isInProgress = false;
        });
      }
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        title: translate('Edit note'),
        icon: Icons.edit_note_rounded,
        tone: AppTone.brand,
        onClose: safeClose,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: GlassInput(
        controller: controller,
        autofocus: true,
        maxLines: 3,
        minHeight: 78,
        showClearButton: false,
        labelText: translate('Note'),
        hintText: translate('input note here'),
        inputFormatters: [LengthLimitingTextInputFormatter(300)],
      ).workaroundFreezeLinuxMint(),
      actions: [
        dialogButton('Cancel', onPressed: safeClose, isOutline: true),
        GlassButton(
          variant: GlassButtonVariant.primary,
          minHeight: 38,
          loading: isInProgress,
          onPressed: isInProgress ? null : submit,
          child: Text(translate('OK')),
        ),
      ],
      onSubmit: submit,
      onCancel: safeClose,
    );
  });
}

void renameDialog({
  required String oldName,
  FormFieldValidator<String>? validator,
  required FutureOr<dynamic> Function(String) onSubmit,
  Function? onCancel,
}) async {
  final RxBool isInProgress = false.obs;
  final controller = TextEditingController(text: oldName);
  String? validationError;
  gFFI.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      controller.dispose();
      close();
    }

    Future<void> submit() async {
      if (isInProgress.value) return;
      final String text = controller.text.trim();
      if (validator != null) {
        final err = validator(text);
        if (err != null) {
          setState(() => validationError = err);
          return;
        }
      }
      isInProgress.value = true;
      try {
        final res = await onSubmit(text);
        if (res == false) {
          isInProgress.value = false;
          return;
        }
        safeClose();
      } catch (e) {
        debugPrint('renameDialog error: $e');
        showToast(translate('Failed'));
        isInProgress.value = false;
      }
    }

    void cancel() {
      onCancel?.call();
      safeClose();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.edit,
        title: translate('Rename'),
        onClose: cancel,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: GlassInput(
        controller: controller,
        autofocus: true,
        labelText: translate('Name'),
        errorText: validationError,
        onChanged: (_) {
          if (validationError != null) {
            setState(() => validationError = null);
          }
        },
        onSubmitted: (_) => submit(),
      ).workaroundFreezeLinuxMint(),
      actions: [
        dialogButton(
          'Cancel',
          icon: const Icon(CamelliaIcons.close),
          onPressed: cancel,
          isOutline: true,
        ),
        Obx(
          () => GlassButton(
            variant: GlassButtonVariant.primary,
            minHeight: 38,
            loading: isInProgress.value,
            icon: const Icon(CamelliaIcons.check, size: 16),
            onPressed: isInProgress.value ? null : submit,
            child: Text(translate('OK')),
          ),
        ),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void changeBot({Function()? callback}) async {
  if (bind.mainHasValidBotSync()) {
    await bind.mainSetOption(key: 'bot', value: '');
    callback?.call();
    return;
  }
  String errorText = '';
  bool loading = false;
  final controller = TextEditingController();
  gFFI.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      controller.clear();
      controller.dispose();
      close();
    }

    Future<void> onVerify() async {
      final token = controller.text.trim();
      if (token.isEmpty || loading) return;
      loading = true;
      errorText = '';
      setState(() {});
      final error = await bind.mainVerifyBot(token: token);
      if (error.isEmpty) {
        callback?.call();
        safeClose();
      } else {
        errorText = formatUserFriendlyError(error);
        loading = false;
        if (!isClosed) setState(() {});
      }
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        title: translate('Telegram bot'),
        icon: Icons.send_rounded,
        tone: AppTone.brand,
        onClose: safeClose,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 360, maxWidth: 440),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            translate('enable-bot-desc'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          GlassInput(
            autofocus: true,
            controller: controller,
            labelText: translate('Token'),
            hintText: '123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11',
            prefixIcon: Icons.vpn_key_outlined,
            tabularNums: true,
            errorText: errorText.isEmpty ? null : errorText,
            onChanged: (_) {
              if (errorText.isNotEmpty) {
                setState(() => errorText = '');
              }
            },
            onSubmitted: (_) => onVerify(),
          ).workaroundFreezeLinuxMint(),
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: safeClose, isOutline: true),
        GlassButton(
          variant: GlassButtonVariant.primary,
          minHeight: 38,
          loading: loading,
          onPressed: loading ? null : onVerify,
          child: Text(translate('OK')),
        ),
      ],
      onSubmit: loading ? null : onVerify,
      onCancel: safeClose,
    );
  });
}

void change2fa({Function()? callback}) async {
  if (bind.mainHasValid2FaSync()) {
    final ok = await bind.mainDisable2FaAndClearTrustedDevices();
    if (ok) {
      callback?.call();
    } else {
      showToast(translate('Failed'));
    }
    return;
  }
  final new2fa = await bind.mainGenerate2Fa();
  final secretRegex = RegExp(r'secret=([^&]+)');
  final secret = secretRegex.firstMatch(new2fa)?.group(1) ?? '';
  String? errorText;
  final controller = TextEditingController();
  gFFI.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      controller.clear();
      controller.dispose();
      close();
    }

    Future<void> onVerify() async {
      if (await bind.mainVerify2Fa(code: controller.text.trim())) {
        callback?.call();
        safeClose();
      } else {
        setState(() {
          errorText = translate('wrong-2fa-code');
        });
      }
    }

    final codeField = Dialog2FaField(
      controller: controller,
      errorText: errorText,
      onChanged: () => setState(() => errorText = null),
      title: translate('Verification code'),
      readyCallback: onVerify,
    );

    VoidCallback? getOnSubmit() => codeField.isReady ? onVerify : null;

    final theme = Theme.of(context);
    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.shield,
        title: translate('enable-2fa-title'),
        onClose: safeClose,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 360, maxWidth: 440),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              translate('enable-2fa-desc'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(CamelliaRadius.surface),
              border: Border.all(
                color: AppVisual.tokens(context).border,
                width: 0.85,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: SizedBox(
                width: 156,
                height: 156,
                child: QrImageView(
                  backgroundColor: Colors.white,
                  data: new2fa,
                  version: QrVersions.auto,
                  size: 156,
                  gapless: false,
                ),
              ),
            ),
          ),
          if (secret.isNotEmpty) ...[
            const SizedBox(height: 10),
            GlassSurface(
              layer: CamelliaGlassLayer.floating,
              showShadow: false,
              enableBlur: false,
              strokeWidth: 0.85,
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: SelectableText(
                      secret,
                      style: CamelliaTypography.tabular(
                        theme.textTheme.labelMedium?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GlassIconButton(
                    icon: CamelliaIcons.copy,
                    size: 28,
                    iconSize: 14,
                    tooltip: translate('Copy'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: secret));
                      showToast(translate('Copied'));
                    },
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          codeField,
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: safeClose, isOutline: true),
        dialogButton('OK', onPressed: getOnSubmit()),
      ],
      onSubmit: getOnSubmit(),
      onCancel: safeClose,
    );
  });
}

void enter2FaDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager, {
  String? errorText,
}) async {
  final controller = TextEditingController();
  final RxBool submitReady = false.obs;
  final RxBool trustThisDevice = false.obs;
  final RxString activeError =
      (errorText == null || errorText.trim().isEmpty
              ? ''
              : formatUserFriendlyError(errorText))
          .obs;

  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    var isClosed = false;
    void cancel() {
      if (isClosed) return;
      isClosed = true;
      controller.dispose();
      close();
      closeConnection();
    }

    void submit() {
      if (isClosed || !submitReady.value) return;
      isClosed = true;
      final code = controller.text.trim();
      controller.dispose();
      gFFI.send2FA(sessionId, code, trustThisDevice.value);
      close();
      dialogManager.showLoading(
        translate('Logging in...'),
        onCancel: closeConnection,
      );
    }

    late Dialog2FaField codeField;
    codeField = Dialog2FaField(
      controller: controller,
      title: translate('Verification code'),
      errorText: null,
      readyCallback: submit,
      onChanged: () {
        if (activeError.value.isNotEmpty) {
          activeError.value = '';
        }
        submitReady.value = codeField.isReady;
      },
    );

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.shield,
        title: translate('enter-2fa-title'),
        subtitle: translate(
          'Enter the 6-digit verification code from your authenticator',
        ),
        tone: activeError.value.isNotEmpty ? AppTone.danger : AppTone.brand,
        onClose: cancel,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Obx(
            () => activeError.value.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _DialogInlineAlert(message: activeError.value),
                  ),
          ),
          codeField,
          if (bind.sessionGetEnableTrustedDevices(sessionId: sessionId)) ...[
            const SizedBox(height: 8),
            Obx(
              () => _DialogSwitchRow(
                label: translate('Trust this device'),
                value: trustThisDevice.value,
                onChanged: (v) => trustThisDevice.value = v,
              ),
            ),
          ],
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: cancel, isOutline: true),
        Obx(
          () => dialogButton('OK', onPressed: submitReady.isTrue ? submit : null),
        ),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void showWindowsSessionsDialog(
  String type,
  String title,
  String text,
  OverlayDialogManager dialogManager,
  SessionID sessionId,
  String peerId,
  String sessions,
) {
  List<dynamic> sessionsList = [];
  try {
    sessionsList = json.decode(sessions);
  } catch (e) {
    debugPrint('Failed to decode Windows sessions: $e');
  }
  final List<String> sids = [];
  final List<String> names = [];
  for (final session in sessionsList) {
    if (session is Map) {
      sids.add(session['sid']?.toString() ?? '');
      names.add(session['name']?.toString() ?? '');
    }
  }
  if (sids.isEmpty) {
    return;
  }
  String selectedUserValue = sids.first;
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    void submit() {
      bind.sessionSendSelectedSessionId(
        sessionId: sessionId,
        sid: selectedUserValue,
      );
      close();
    }

    void cancel() {
      close();
      closeConnection();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: Icons.people_alt_rounded,
        title: translate(title.isNotEmpty ? title : 'Select Windows Session'),
        subtitle: text.isNotEmpty ? formatUserFriendlyError(text) : null,
        onClose: cancel,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: ComboBox(
        keys: sids,
        values: names,
        initialKey: selectedUserValue,
        onChanged: (value) {
          selectedUserValue = value;
        },
      ),
      actions: [
        dialogButton('Cancel', onPressed: cancel, isOutline: true),
        dialogButton('Connect', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void addPeersToAbDialog(List<Peer> peers) async {
  Future<bool> addTo(String abname) async {
    final mapList = peers.map((e) => e.toAddressBookCopyJson()).toList();
    final errMsg = await gFFI.abModel.addPeersTo(mapList, abname);
    if (errMsg == null) {
      showToast(translate('Successful'));
      return true;
    } else {
      showToast(formatUserFriendlyError(errMsg));
      return false;
    }
  }

  if (gFFI.abModel.addressbooks.length == 1 &&
      gFFI.abModel.current.isPersonal()) {
    await addTo(gFFI.abModel.currentName.value);
    return;
  }

  final RxBool isInProgress = false.obs;
  final names = gFFI.abModel.addressBooksCanWrite();
  final RxString currentName = gFFI.abModel.currentName.value.obs;
  if (gFFI.peerTabModel.currentTab == PeerTabIndex.ab.index) {
    names.remove(currentName.value);
  }
  if (names.isEmpty) {
    debugPrint('no address book to add peers to, should not happen');
    return;
  }
  if (!names.contains(currentName.value)) {
    currentName.value = names[0];
  }

  gFFI.dialogManager.show((setState, close, context) {
    Future<void> submit() async {
      if (isInProgress.value) return;
      isInProgress.value = true;
      if (await addTo(currentName.value)) {
        close();
      }
      isInProgress.value = false;
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.addressBook,
        title: translate('Add to address book'),
        subtitle: translate('Choose destination address book'),
        onClose: close,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: Obx(
        () => ComboBox(
          keys: names,
          values: names
              .map((e) => gFFI.abModel.translatedName(e))
              .toList(growable: false),
          initialKey: currentName.value,
          onChanged: (value) {
            currentName.value = value;
          },
        ),
      ),
      actions: [
        dialogButton(
          'Cancel',
          icon: const Icon(CamelliaIcons.close),
          onPressed: close,
          isOutline: true,
        ),
        Obx(
          () => GlassButton(
            variant: GlassButtonVariant.primary,
            minHeight: 38,
            loading: isInProgress.value,
            icon: const Icon(CamelliaIcons.check, size: 16),
            onPressed: isInProgress.value ? null : submit,
            child: Text(translate('OK')),
          ),
        ),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void setSharedAbPasswordDialog(String abName, Peer peer) {
  final TextEditingController controller = TextEditingController(text: '');
  final RxBool isInProgress = false.obs;
  final RxBool isInputEmpty = true.obs;
  bool passwordVisible = false;
  controller.addListener(() {
    isInputEmpty.value = controller.text.isEmpty;
  });
  gFFI.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void cancel() {
      if (isClosed) return;
      isClosed = true;
      controller.clear();
      controller.dispose();
      close();
    }

    Future<void> change(String password) async {
      if (isInProgress.value) return;
      isInProgress.value = true;
      try {
        final bool res = await gFFI.abModel.changeSharedPassword(
          abName,
          peer.id,
          password,
        );
        isInProgress.value = false;
        if (res) {
          showToast(translate('Successful'));
          cancel();
        } else {
          showToast(translate('Failed'));
        }
      } catch (e) {
        isInProgress.value = false;
        showToast('${translate('Failed')}: ${formatUserFriendlyError(e.toString())}');
      }
    }

    final theme = Theme.of(context);
    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: Icons.key_rounded,
        title: translate(
          peer.password.isEmpty ? 'Set shared password' : 'Change Password',
        ),
        onClose: cancel,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassInput(
            controller: controller,
            autofocus: true,
            obscureText: !passwordVisible,
            showClearButton: false,
            labelText: translate('Password'),
            prefixIcon: CamelliaIcons.lock,
            onSubmitted: (_) {
              if (!isInputEmpty.value && !isInProgress.value) {
                change(controller.text);
              }
            },
            trailing: Tooltip(
              message: translate(
                passwordVisible ? 'Hide password' : 'Show password',
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                onTap: () {
                  setState(() {
                    passwordVisible = !passwordVisible;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    passwordVisible ? CamelliaIcons.eye : CamelliaIcons.eyeOff,
                    size: 17,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ).workaroundFreezeLinuxMint(),
          if (!gFFI.abModel.current.isPersonal()) ...[
            const SizedBox(height: 10),
            _DialogInlineAlert(
              message: translate('share_warning_tip'),
              tone: AppTone.warning,
            ),
          ],
        ],
      ),
      actions: [
        Obx(
          () => dialogButton(
            'Cancel',
            icon: const Icon(CamelliaIcons.close),
            onPressed: isInProgress.value ? null : cancel,
            isOutline: true,
          ),
        ),
        if (peer.password.isNotEmpty)
          Obx(
            () => GlassButton(
              variant: GlassButtonVariant.danger,
              minHeight: 38,
              icon: const Icon(CamelliaIcons.trash, size: 16),
              onPressed: isInProgress.value ? null : () => change(''),
              child: Text(translate('Remove')),
            ),
          ),
        Obx(
          () => GlassButton(
            variant: GlassButtonVariant.primary,
            minHeight: 38,
            loading: isInProgress.value,
            icon: const Icon(CamelliaIcons.check, size: 16),
            onPressed: isInputEmpty.value || isInProgress.value
                ? null
                : () => change(controller.text),
            child: Text(translate('OK')),
          ),
        ),
      ],
      onSubmit: () {
        if (!isInputEmpty.value && !isInProgress.value) {
          change(controller.text);
        }
      },
      onCancel: cancel,
    );
  });
}

void CommonConfirmDialog(
  OverlayDialogManager dialogManager,
  String content,
  VoidCallback onConfirm,
) {
  dialogManager.show((setState, close, context) {
    void submit() {
      close();
      onConfirm.call();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader.warning(
        title: translate('Confirmation'),
        onClose: close,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
      content: Text(
        content,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void changeUnlockPinDialog(Function() callback) {
  // CRED-005: Never pre-fill existing unlock PIN; start with clean, empty controllers.
  final pinController = TextEditingController();
  final confirmController = TextEditingController();
  String? pinErrorText;
  String? confirmationErrorText;
  final maxLength = bind.mainMaxEncryptLen();
  gFFI.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      pinController.clear();
      confirmController.clear();
      pinController.dispose();
      confirmController.dispose();
      close();
    }

    Future<void> submit() async {
      pinErrorText = null;
      confirmationErrorText = null;
      final pin = pinController.text.trim();
      final confirm = confirmController.text.trim();
      if (pin != confirm) {
        setState(() {
          confirmationErrorText = translate(
            'The confirmation is not identical.',
          );
        });
        return;
      }
      final errorMsg = bind.mainSetUnlockPin(pin: pin);
      if (errorMsg.isNotEmpty) {
        setState(() {
          pinErrorText = translate(errorMsg);
        });
        return;
      }
      callback.call();
      safeClose();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.lock,
        title: translate('Set PIN'),
        subtitle: translate(
          'Protect security and network configuration with a local PIN',
        ),
        onClose: safeClose,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PasswordWidget(
            title: 'PIN',
            hintText: '',
            controller: pinController,
            errorText: pinErrorText,
            maxLength: maxLength,
            onChanged: (_) {
              if (pinErrorText != null) {
                setState(() => pinErrorText = null);
              }
            },
          ),
          PasswordWidget(
            title: 'Confirmation',
            hintText: '',
            autoFocus: false,
            controller: confirmController,
            errorText: confirmationErrorText,
            maxLength: maxLength,
            onChanged: (_) {
              if (confirmationErrorText != null) {
                setState(() => confirmationErrorText = null);
              }
            },
            onSubmitted: (_) => submit(),
          ),
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: safeClose, isOutline: true),
        dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: safeClose,
    );
  });
}

void checkUnlockPinDialog(Function() passCallback) {
  final controller = TextEditingController();
  String? errorText;
  gFFI.dialogManager.show((setState, close, context) {
    var isClosed = false;
    void safeClose() {
      if (isClosed) return;
      isClosed = true;
      controller.clear();
      controller.dispose();
      close();
    }

    Future<void> submit() async {
      final pin = controller.text.trim();
      // CRED-005: Authoritative verification against Rust core; Dart never holds or receives plaintext PIN.
      final verified =
          bind.mainGetCommonSync(key: 'verify-unlock-pin:$pin') == 'true';
      if (!verified) {
        setState(() {
          errorText = translate('Wrong PIN');
        });
        return;
      }
      passCallback.call();
      safeClose();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.lock,
        title: translate('Unlock with PIN'),
        subtitle: translate('Enter your security PIN to continue'),
        onClose: safeClose,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 340, maxWidth: 400),
      content: PasswordWidget(
        title: 'PIN',
        controller: controller,
        errorText: errorText,
        hintText: '',
        onChanged: (_) {
          if (errorText != null) {
            setState(() => errorText = null);
          }
        },
        onSubmitted: (_) => submit(),
      ),
      actions: [
        dialogButton('Cancel', onPressed: safeClose, isOutline: true),
        dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: safeClose,
    );
  });
}

bool hwidEquals(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String hwidToHex(Uint8List hwid) =>
    hwid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void confrimDeleteTrustedDevicesDialog(
  RxList<TrustedDevice> trustedDevices,
  RxList<Uint8List> selectedDevices,
) {
  CommonConfirmDialog(
    gFFI.dialogManager,
    '${translate('Confirm Delete')}?',
    () async {
      if (selectedDevices.isEmpty) return;
      // STATE-022: Verify exact set equality by byte content, not mere length equality.
      final selectedHexSet = selectedDevices.map(hwidToHex).toSet();
      final currentHexSet = trustedDevices.map((d) => d.hwidHex).toSet();
      final isExactAllSelected =
          currentHexSet.isNotEmpty &&
          currentHexSet.length == selectedHexSet.length &&
          currentHexSet.every(selectedHexSet.contains);

      if (isExactAllSelected) {
        await bind.mainClearTrustedDevices();
        trustedDevices.clear();
        selectedDevices.clear();
      } else {
        final payload = jsonEncode(
          selectedDevices.map((e) => e.toList()).toList(),
        );
        await bind.mainRemoveTrustedDevices(json: payload);
        trustedDevices.removeWhere(
          (element) => selectedHexSet.contains(element.hwidHex),
        );
        selectedDevices.clear();
      }
    },
  );
}

void manageTrustedDeviceDialog() async {
  final RxList<TrustedDevice> trustedDevices = (await TrustedDevice.get()).obs;
  final RxList<Uint8List> selectedDevices = RxList.empty();
  gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: Icons.devices_rounded,
        title: translate('Manage trusted devices'),
        subtitle: translate(
          'Review or revoke devices authorized to skip two-factor verification',
        ),
        onClose: close,
      ),
      contentBoxConstraints: const BoxConstraints(minWidth: 400, maxWidth: 500),
      content: trustedDevicesTable(trustedDevices, selectedDevices),
      actions: [
        GlassButton(
          variant: GlassButtonVariant.secondary,
          minHeight: 38,
          onPressed: close,
          child: Text(translate('Close')),
        ),
        Obx(
          () => GlassButton(
            variant: GlassButtonVariant.danger,
            minHeight: 38,
            icon: const Icon(CamelliaIcons.trash, size: 16),
            onPressed: selectedDevices.isEmpty
                ? null
                : () {
                    confrimDeleteTrustedDevicesDialog(
                      trustedDevices,
                      selectedDevices,
                    );
                  },
            child: Text(translate('Delete')),
          ),
        ),
      ],
      onCancel: close,
    );
  });
}

class TrustedDevice {
  late final Uint8List hwid;
  late final int time;
  late final String id;
  late final String name;
  late final String platform;
  late final String hwidHex;

  TrustedDevice.fromJson(Map<String, dynamic> json) {
    final hwidList = json['hwid'] as List<dynamic>;
    hwid = Uint8List.fromList(hwidList.cast<int>());
    hwidHex = hwidToHex(hwid);
    time = json['time'];
    id = json['id'];
    name = json['name'];
    platform = json['platform'];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrustedDevice &&
          runtimeType == other.runtimeType &&
          hwidHex == other.hwidHex;

  @override
  int get hashCode => hwidHex.hashCode;

  String daysRemaining() {
    final expiry = time + 90 * 24 * 60 * 60 * 1000;
    final remaining = expiry - DateTime.now().millisecondsSinceEpoch;
    if (remaining < 0) {
      return '0';
    }
    return (remaining / (24 * 60 * 60 * 1000)).toStringAsFixed(0);
  }

  static Future<List<TrustedDevice>> get() async {
    final List<TrustedDevice> devices = List.empty(growable: true);
    try {
      final devicesJson = await bind.mainGetTrustedDevices();
      if (devicesJson.isNotEmpty) {
        final devicesList = json.decode(devicesJson);
        if (devicesList is List) {
          for (final device in devicesList) {
            devices.add(TrustedDevice.fromJson(device));
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load trusted devices: $e');
    }
    devices.sort((a, b) => b.time.compareTo(a.time));
    return devices;
  }
}

Widget trustedDevicesTable(
  RxList<TrustedDevice> devices,
  RxList<Uint8List> selectedDevices,
) {
  return _TrustedDevicesTableView(
    devices: devices,
    selectedDevices: selectedDevices,
  );
}

class _TrustedDevicesTableView extends StatefulWidget {
  final RxList<TrustedDevice> devices;
  final RxList<Uint8List> selectedDevices;

  const _TrustedDevicesTableView({
    required this.devices,
    required this.selectedDevices,
  });

  @override
  State<_TrustedDevicesTableView> createState() =>
      _TrustedDevicesTableViewState();
}

class _TrustedDevicesTableViewState extends State<_TrustedDevicesTableView> {
  final RxBool selectAll = false.obs;
  Worker? _workerDevices;
  Worker? _workerSelected;

  void setSelectAll() {
    if (!mounted) return;
    final selectedHexSet = widget.selectedDevices.map(hwidToHex).toSet();
    final currentHexSet = widget.devices.map((d) => d.hwidHex).toSet();
    if (currentHexSet.isNotEmpty &&
        currentHexSet.length == selectedHexSet.length &&
        currentHexSet.every(selectedHexSet.contains)) {
      selectAll.value = true;
    } else {
      selectAll.value = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _workerDevices = ever(widget.devices, (_) => setSelectAll());
    _workerSelected = ever(widget.selectedDevices, (_) => setSelectAll());
    setSelectAll();
  }

  @override
  void dispose() {
    _workerDevices?.dispose();
    _workerSelected?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      if (widget.devices.isEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CamelliaStateIllustration(
                glyph: CamelliaGlyph.devices,
                size: 52,
              ),
              const SizedBox(height: 12),
              Text(
                translate('No trusted devices'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      }

      final selectedHexSet = widget.selectedDevices.map(hwidToHex).toSet();
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
            onTap: () {
              if (!selectAll.value) {
                widget.selectedDevices.clear();
                widget.selectedDevices.addAll(
                  widget.devices.map((e) => e.hwid),
                );
              } else {
                widget.selectedDevices.clear();
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  Checkbox(
                    value: selectAll.value,
                    onChanged: (value) {
                      if (value == true) {
                        widget.selectedDevices.clear();
                        widget.selectedDevices.addAll(
                          widget.devices.map((e) => e.hwid),
                        );
                      } else {
                        widget.selectedDevices.clear();
                      }
                    },
                  ),
                  Text(
                    translate('Select all'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          for (final device in widget.devices)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassSurface(
                layer: CamelliaGlassLayer.floating,
                showShadow: false,
                enableBlur: false,
                strokeWidth: 0.85,
                borderRadius: BorderRadius.circular(CamelliaRadius.control),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    onTap: () {
                      final isSelected = selectedHexSet.contains(device.hwidHex);
                      if (!isSelected) {
                        if (!widget.selectedDevices.any(
                          (h) => hwidEquals(h, device.hwid),
                        )) {
                          widget.selectedDevices.add(device.hwid);
                        }
                      } else {
                        widget.selectedDevices.removeWhere(
                          (h) => hwidEquals(h, device.hwid),
                        );
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            value: selectedHexSet.contains(device.hwidHex),
                            onChanged: (value) {
                              if (value == null) return;
                              if (value) {
                                if (!widget.selectedDevices.any(
                                  (h) => hwidEquals(h, device.hwid),
                                )) {
                                  widget.selectedDevices.add(device.hwid);
                                }
                              } else {
                                widget.selectedDevices.removeWhere(
                                  (h) => hwidEquals(h, device.hwid),
                                );
                              }
                            },
                          ),
                          CamelliaIcons.platformBadge(
                            device.platform,
                            size: 26,
                            showBackground: true,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  device.name.isNotEmpty
                                      ? device.name
                                      : device.platform,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  device.id,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CamelliaTypography.tabular(
                                    theme.textTheme.bodySmall?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          GlassBadge(
                            label: '${device.daysRemaining()}d',
                            tone: GlassBadgeTone.neutral,
                            tabularNums: true,
                            compact: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}
