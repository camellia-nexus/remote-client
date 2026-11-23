import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

const String kStoredPasswordSentinel =
    '\u0000\u0000STORED_PASSWORD\u0000\u0000';

void changeSocks5Proxy({OverlayDialogManager? dialogManager}) async {
  final dm = dialogManager ?? gFFI.dialogManager;
  var socks = await bind.mainGetSocks();

  String proxy = '';
  String proxyMsg = '';
  String username = '';
  String password = '';
  if (socks.length == 3) {
    proxy = socks[0];
    username = socks[1];
    password = socks[2];
  }
  var proxyController = TextEditingController(text: proxy);
  var userController = TextEditingController(text: username);
  var pwdController = TextEditingController(text: password);
  RxBool obscure = true.obs;

  // proxy settings
  // The following option is a not real key, it is just used for custom client advanced settings.
  const String optionProxyUrl = "proxy-url";
  final isOptFixed = isOptionFixed(optionProxyUrl);

  var isInProgress = false;
  var isClosed = false;
  dm.show((setState, close, context) {
    safeClose() {
      if (isClosed) return;
      isClosed = true;
      proxyController.clear();
      userController.clear();
      pwdController.clear();
      proxyController.dispose();
      userController.dispose();
      pwdController.dispose();
      close();
    }

    submit() async {
      if (isInProgress || isClosed) return;
      setState(() {
        proxyMsg = '';
        isInProgress = true;
      });
      cancel() {
        if (isClosed) return;
        setState(() {
          isInProgress = false;
        });
      }

      proxy = proxyController.text.trim();
      username = userController.text.trim();
      password = pwdController.text.trim();

      if (proxy.isNotEmpty) {
        String domainPort = proxy;
        if (domainPort.contains('://')) {
          domainPort = domainPort.split('://')[1];
        }
        proxyMsg = translate(
          await bind.mainTestIfValidServer(
            server: domainPort,
            testWithProxy: false,
          ),
        );
        if (isClosed) return;
        if (proxyMsg.isEmpty) {
          // ignore
        } else {
          cancel();
          return;
        }
      }
      if (isClosed) return;
      await bind.mainSetSocks(
        proxy: proxy,
        username: username,
        password: password,
      );
      safeClose();
    }

    final responsiveMinWidth = math.max(
      0.0,
      math.min(MediaQuery.sizeOf(context).width - 32, 500.0),
    );

    return CustomAlertDialog(
      title: Text(translate('Socks5/Http(s) Proxy')),
      content: ConstrainedBox(
        constraints: BoxConstraints(minWidth: responsiveMinWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (!isMobile)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 140),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        children: [
                          Text(translate('Server')).marginOnly(right: 4),
                          Tooltip(
                            waitDuration: const Duration(milliseconds: 0),
                            message: translate("default_proxy_tip"),
                            child: Icon(
                              Icons.help_outline_outlined,
                              size: 16,
                              color: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.color
                                  ?.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ).marginOnly(right: 10),
                  ),
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      errorText: proxyMsg.isNotEmpty ? proxyMsg : null,
                      labelText: isMobile ? translate('Server') : null,
                      helperText: isMobile
                          ? translate("default_proxy_tip")
                          : null,
                      helperMaxLines: isMobile ? 3 : null,
                    ),
                    controller: proxyController,
                    autofocus: true,
                    enabled: !isOptFixed,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ).marginOnly(bottom: 8),
            Row(
              children: [
                if (!isMobile)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 140),
                    child: Text(
                      '${translate("Username")}:',
                      textAlign: TextAlign.right,
                    ).marginOnly(right: 10),
                  ),
                Expanded(
                  child: TextField(
                    controller: userController,
                    decoration: InputDecoration(
                      labelText: isMobile ? translate('Username') : null,
                    ),
                    enabled: !isOptFixed,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ).marginOnly(bottom: 8),
            Row(
              children: [
                if (!isMobile)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 140),
                    child: Text(
                      '${translate("Password")}:',
                      textAlign: TextAlign.right,
                    ).marginOnly(right: 10),
                  ),
                Expanded(
                  child: Obx(
                    () => TextField(
                      obscureText: obscure.value,
                      decoration: InputDecoration(
                        labelText: isMobile ? translate('Password') : null,
                        hintText: password == kStoredPasswordSentinel
                            ? translate('Unchanged')
                            : null,
                        suffixIcon: IconButton(
                          onPressed: () => obscure.value = !obscure.value,
                          icon: Icon(
                            obscure.value
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                      ),
                      controller: pwdController,
                      enabled: !isOptFixed,
                      maxLength: bind.mainMaxEncryptLen(),
                    ).workaroundFreezeLinuxMint(),
                  ),
                ),
              ],
            ),
            // NOT use Offstage to wrap LinearProgressIndicator
            if (isInProgress)
              const LinearProgressIndicator().marginOnly(top: 8),
          ],
        ),
      ),
      actions: [
        dialogButton('Cancel', onPressed: safeClose, isOutline: true),
        if (!isOptFixed) dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: safeClose,
    );
  });
}
