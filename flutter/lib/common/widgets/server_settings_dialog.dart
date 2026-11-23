import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
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
      throw FormatException("Server options is not a valid JSON map");
    }
    showServerSettingsWithValue(
      ServerConfig.fromOptions(decoded),
      dialogManager,
      setState,
    );
  } catch (e) {
    debugPrint("Failed to load server config: $e");
    dialogManager.show((setStateDialog, close, context) {
      return CustomAlertDialog(
        title: Text(translate('ID/Relay Server')),
        content: Text(
          '${translate("Failed to load server configuration")}: $e',
        ),
        actions: [
          dialogButton("Cancel", onPressed: close, isOutline: true),
          dialogButton(
            "Retry",
            onPressed: () {
              close();
              showServerSettings(dialogManager, setState);
            },
          ),
        ],
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

  RxString idServerMsg = ''.obs;
  RxString relayServerMsg = ''.obs;
  RxString apiServerMsg = ''.obs;

  final controllers = [idCtrl, relayCtrl, apiCtrl, keyCtrl];
  final errMsgs = [idServerMsg, relayServerMsg, apiServerMsg];

  try {
    await dialogManager.show((setState, close, context) {
      void onCancel() {
        isClosed = true;
        close();
      }

      Future<bool> submit() async {
        if (isInProgress || isClosed) return false;
        setState(() {
          isInProgress = true;
        });
        bool ret = await setServerConfig(
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
          close();
          showToast(translate('Successful'));
          upSetState?.call(() {});
        } else {
          if (isClosed) return;
          showToast(translate('Failed'));
        }
      }

      Widget buildField(
        String label,
        TextEditingController controller,
        String errorMsg, {
        String? Function(String?)? validator,
        bool autofocus = false,
      }) {
        if (isDesktop || isWeb) {
          return Row(
            children: [
              SizedBox(width: 120, child: Text(label)),
              SizedBox(width: 8),
              Expanded(
                child: serverSettingsTextFormField(
                  label: label,
                  controller: controller,
                  errorMsg: errorMsg,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  showLabelText: false,
                  validator: validator,
                  autofocus: autofocus,
                ).workaroundFreezeLinuxMint(),
              ),
            ],
          );
        }

        return serverSettingsTextFormField(
          label: label,
          controller: controller,
          errorMsg: errorMsg,
          validator: validator,
        ).workaroundFreezeLinuxMint();
      }

      return CustomAlertDialog(
        title: Row(
          children: [
            Expanded(child: Text(translate('ID/Relay Server'))),
            ...ServerConfigImportExportWidgets(controllers, errMsgs),
          ],
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: math.max(
              0.0,
              math.min(MediaQuery.sizeOf(context).width - 32, 500.0),
            ),
          ),
          child: Form(
            child: Obx(
              () => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  buildField(
                    translate('ID Server'),
                    idCtrl,
                    idServerMsg.value,
                    autofocus: true,
                  ),
                  SizedBox(height: 8),
                  if (!isIOS && !isWeb) ...[
                    buildField(
                      translate('Relay Server'),
                      relayCtrl,
                      relayServerMsg.value,
                    ),
                    SizedBox(height: 8),
                  ],
                  buildField(
                    translate('API Server'),
                    apiCtrl,
                    apiServerMsg.value,
                    validator: (v) {
                      if (v != null && v.isNotEmpty) {
                        if (!(v.startsWith('http://') ||
                            v.startsWith("https://"))) {
                          return translate("invalid_http");
                        }
                      }
                      return null;
                    },
                  ),
                  SizedBox(height: 8),
                  buildField('Key', keyCtrl, ''),
                  if (isInProgress)
                    Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          dialogButton(
            'Cancel',
            onPressed: onCancel,
            isOutline: true,
          ),
          dialogButton(
            'OK',
            onPressed: onOk,
          ),
        ],
        onSubmit: onOk,
        onCancel: onCancel,
      );
    });
  } finally {
    isClosed = true;
    for (final c in controllers) {
      c.dispose();
    }
  }
}

TextFormField serverSettingsTextFormField({
  required String label,
  required TextEditingController controller,
  required String errorMsg,
  String? Function(String?)? validator,
  bool autofocus = false,
  bool showLabelText = true,
  EdgeInsetsGeometry? contentPadding,
}) {
  return TextFormField(
    controller: controller,
    decoration: InputDecoration(
      labelText: showLabelText ? label : null,
      errorText: errorMsg.isEmpty ? null : errorMsg,
      contentPadding: contentPadding,
    ),
    validator: validator,
    autofocus: autofocus,
    keyboardType: TextInputType.visiblePassword,
    textCapitalization: TextCapitalization.none,
    autocorrect: false,
    enableSuggestions: false,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
    enableIMEPersonalizedLearning: false,
    spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
  );
}
