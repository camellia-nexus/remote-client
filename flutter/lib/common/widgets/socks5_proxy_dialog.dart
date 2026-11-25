import 'dart:math' as math;

import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

const String kStoredPasswordSentinel =
    '\u0000\u0000STORED_PASSWORD\u0000\u0000';

void changeSocks5Proxy({OverlayDialogManager? dialogManager}) async {
  final dm = dialogManager ?? gFFI.dialogManager;
  final socks = await bind.mainGetSocks();

  String proxy = '';
  String proxyMsg = '';
  String username = '';
  String password = '';
  if (socks.length == 3) {
    proxy = socks[0];
    username = socks[1];
    password = socks[2];
  }
  final proxyController = TextEditingController(text: proxy);
  final userController = TextEditingController(text: username);
  final pwdController = TextEditingController(text: password);
  final RxBool obscure = true.obs;

  const String optionProxyUrl = 'proxy-url';
  final isOptFixed = isOptionFixed(optionProxyUrl);
  final maxEncryptLen = bind.mainMaxEncryptLen();

  var isInProgress = false;
  var isClosed = false;
  dm.show((setState, close, context) {
    void safeClose() {
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

    void clearAll() {
      proxyController.clear();
      userController.clear();
      pwdController.clear();
      setState(() {
        proxyMsg = '';
        password = '';
      });
    }

    Future<void> submit() async {
      if (isInProgress || isClosed || isOptFixed) return;
      setState(() {
        proxyMsg = '';
        isInProgress = true;
      });
      void cancelLoading() {
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
        if (proxyMsg.isNotEmpty) {
          cancelLoading();
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
      math.min(MediaQuery.sizeOf(context).width - 48, 460.0),
    );
    final theme = Theme.of(context);

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: CamelliaIcons.tunnel,
        title: translate('Socks5/Http(s) Proxy'),
        subtitle: translate('default_proxy_tip'),
        onClose: safeClose,
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: responsiveMinWidth,
          maxWidth: 480.0,
        ),
        child: Column(
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
            GlassInput(
              labelText: translate('Server'),
              hintText: 'socks5://127.0.0.1:1080',
              prefixIcon: Icons.dns_outlined,
              controller: proxyController,
              autofocus: true,
              enabled: !isOptFixed,
              tabularNums: true,
              errorText: proxyMsg.isNotEmpty ? proxyMsg : null,
              onChanged: (_) {
                if (proxyMsg.isNotEmpty) {
                  setState(() => proxyMsg = '');
                }
              },
              onSubmitted: (_) => submit(),
            ).workaroundFreezeLinuxMint(),
            const SizedBox(height: 12),
            GlassInput(
              labelText: translate('Username'),
              hintText: translate('Optional'),
              prefixIcon: Icons.person_outline_rounded,
              controller: userController,
              enabled: !isOptFixed,
              onSubmitted: (_) => submit(),
            ).workaroundFreezeLinuxMint(),
            const SizedBox(height: 12),
            Obx(
              () => GlassInput(
                labelText: translate('Password'),
                hintText: password == kStoredPasswordSentinel
                    ? translate('Unchanged')
                    : translate('Optional'),
                prefixIcon: CamelliaIcons.lock,
                obscureText: obscure.value,
                showClearButton: false,
                controller: pwdController,
                enabled: !isOptFixed,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(maxEncryptLen),
                ],
                onSubmitted: (_) => submit(),
                trailing: Tooltip(
                  message: translate(
                    obscure.value ? 'Show password' : 'Hide password',
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                    onTap: () => obscure.value = !obscure.value,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        obscure.value
                            ? CamelliaIcons.eyeOff
                            : CamelliaIcons.eye,
                        size: 17,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ).workaroundFreezeLinuxMint(),
            ),
          ],
        ),
      ),
      actions: [
        if (!isOptFixed)
          GlassButton(
            variant: GlassButtonVariant.ghost,
            minHeight: 38,
            onPressed: isInProgress ? null : clearAll,
            child: Text(translate('Clear')),
          ),
        GlassButton(
          variant: GlassButtonVariant.secondary,
          minHeight: 38,
          onPressed: safeClose,
          child: Text(translate('Cancel')),
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
      onSubmit: isOptFixed ? null : submit,
      onCancel: safeClose,
    );
  });
}
