// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

/// Lightweight Liquid Glass tray floating panel displaying status, ID, and quick actions.
class CamelliaTrayPanel extends StatelessWidget {
  const CamelliaTrayPanel({super.key});

  static Future<void> show(BuildContext context, {Offset? anchor}) async {
    final renderBox = context.findRenderObject() as RenderBox?;
    final targetPosition = anchor ??
        (renderBox != null
            ? renderBox.localToGlobal(Offset.zero)
            : const Offset(20, 40));

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.2),
      builder: (ctx) => Stack(
        children: [
          Positioned(
            left: targetPosition.dx.clamp(16.0, MediaQuery.sizeOf(ctx).width - 336.0),
            top: targetPosition.dy.clamp(16.0, MediaQuery.sizeOf(ctx).height - 380.0),
            child: const Material(
              color: Colors.transparent,
              child: SizedBox(
                width: 320,
                child: CamelliaTrayPanel(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);

    return Obx(() {
      final status = stateGlobal.svcStatus.value;
      final stopped = gFFI.serverModel.isStart == false;
      final statusTone = stopped
          ? GlassBadgeTone.warning
          : switch (status) {
              SvcStatus.ready => GlassBadgeTone.online,
              SvcStatus.connecting => GlassBadgeTone.connecting,
              SvcStatus.notReady => GlassBadgeTone.danger,
            };

      final statusLabel = stopped
          ? translate('Service is not running')
          : switch (status) {
              SvcStatus.ready => translate('Ready'),
              SvcStatus.connecting => translate('connecting_status'),
              SvcStatus.notReady => translate('not_ready_status'),
            };

      final myId = gFFI.serverModel.serverId.text;
      final activeConnections = gFFI.serverModel.clients.length;

      return GlassCard(
        layer: CamelliaGlassLayer.floating,
        borderRadius: BorderRadius.circular(CamelliaRadius.sheet),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Header: Branding + Status Badge
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [CamelliaColors.indigo, CamelliaColors.azure],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                  ),
                  child: const Icon(Icons.hub_rounded, color: Colors.white, size: 16),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    translate('Camellia Remote'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                GlassBadge(
                  label: statusLabel,
                  tone: statusTone,
                  showDot: true,
                  pulse: !stopped && status == SvcStatus.ready,
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Local Device ID Card
            GlassCard(
              layer: CamelliaGlassLayer.canvas,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        translate('Your ID'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        myId.isNotEmpty ? myId : '---',
                        style: CamelliaTypography.tabular(
                          theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GlassIconButton(
                    icon: Icons.copy_rounded,
                    size: 32,
                    iconSize: 16,
                    tooltip: translate('Copy ID'),
                    onPressed: () {
                      if (myId.isNotEmpty) {
                        Clipboard.setData(ClipboardData(text: myId));
                        showToast(translate('Copied'));
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Active Connections indicator
            if (activeConnections > 0) ...[
              Row(
                children: [
                  Icon(
                    Icons.sensors_rounded,
                    size: 14,
                    color: glass.statusOnline,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    translate('{count} active sessions').replaceAll(
                      '{count}',
                      activeConnections.toString(),
                    ),
                    style: CamelliaTypography.tabular(
                      theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],

            const Divider(height: 1),
            const SizedBox(height: 8),

            // Quick Actions List
            _TrayActionRow(
              icon: Icons.launch_rounded,
              label: translate('Open Main Window'),
              onTap: () async {
                Navigator.of(context, rootNavigator: true).pop();
                await windowManager.show();
                await windowManager.focus();
              },
            ),
            _TrayActionRow(
              icon: stopped ? Icons.play_arrow_rounded : Icons.stop_rounded,
              iconColor: stopped ? glass.statusOnline : glass.statusAlert,
              label: stopped ? translate('Start Service') : translate('Stop service'),
              onTap: () {
                Navigator.of(context, rootNavigator: true).pop();
                gFFI.serverModel.toggleService();
              },
            ),
            if (activeConnections > 0)
              _TrayActionRow(
                icon: Icons.link_off_rounded,
                iconColor: glass.statusAlert,
                label: translate('Disconnect All Sessions'),
                onTap: () {
                  Navigator.of(context, rootNavigator: true).pop();
                  gFFI.close();
                },
              ),
            _TrayActionRow(
              icon: Icons.power_settings_new_rounded,
              iconColor: glass.statusAlert,
              label: translate('Quit'),
              onTap: () async {
                Navigator.of(context, rootNavigator: true).pop();
                await windowManager.close();
              },
            ),
          ],
        ),
      );
    });
  }
}

class _TrayActionRow extends StatelessWidget {
  const _TrayActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(CamelliaRadius.control),
      hoverColor: glass.hoverOverlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: iconColor ?? theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
