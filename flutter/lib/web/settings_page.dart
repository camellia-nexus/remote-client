import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'web_client_settings_page.dart';

class WebSettingsPage extends StatelessWidget {
  const WebSettingsPage({
    super.key,
    this.size = 36,
    this.iconSize = 18,
    this.onClosed,
  });

  final double size;
  final double iconSize;
  final VoidCallback? onClosed;

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      icon: CamelliaIcons.settings,
      size: size,
      iconSize: iconSize,
      tooltip: translate('Settings'),
      onPressed: () async {
        FocusManager.instance.primaryFocus?.unfocus();
        await showSettingsOverlay<void>(
          context: context,
          title: translate('Settings'),
          builder: (_) => const WebClientSettingsPage(embedded: true),
        );
        onClosed?.call();
      },
    );
  }
}
