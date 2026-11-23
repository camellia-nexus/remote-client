import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:flutter/material.dart';

import 'web_client_settings_page.dart';

class WebSettingsPage extends StatelessWidget {
  const WebSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      icon: CamelliaIcons.settings,
      tooltip: translate('Settings'),
      onPressed: () {
        FocusManager.instance.primaryFocus?.unfocus();
        showSettingsOverlay<void>(
          context: context,
          title: translate('Settings'),
          builder: (_) => const WebClientSettingsPage(embedded: true),
        );
      },
    );
  }
}
