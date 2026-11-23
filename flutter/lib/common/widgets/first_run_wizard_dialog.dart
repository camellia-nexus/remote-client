// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';

/// First-run onboarding wizard showcasing Camellia Remote Liquid Glass UI,
/// real-time relay latency/connectivity verification, and core security features.
class FirstRunWizardDialog extends StatefulWidget {
  const FirstRunWizardDialog({super.key});

  static const String optionKey = 'first_run_completed';

  /// Evaluates whether the onboarding wizard should be presented, and displays it if pending.
  static Future<void> checkAndShow(BuildContext context) async {
    if (isTest) return;
    final completed = bind.getLocalFlutterOption(k: optionKey);
    if (completed == 'Y') return;

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const FirstRunWizardDialog(),
    );
  }

  @override
  State<FirstRunWizardDialog> createState() => _FirstRunWizardDialogState();
}

class _FirstRunWizardDialogState extends State<FirstRunWizardDialog> {
  int _connectionStatus = 0; // 0: connecting, 1: ready, 2: not ready
  bool _isPublicServer = true;
  String _serverHost = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadNetworkStatus();
  }

  Future<void> _loadNetworkStatus() async {
    try {
      final rawStatus = await bind.mainGetConnectStatus();
      Map<String, dynamic> statusMap = {};
      try {
        statusMap = jsonDecode(rawStatus) as Map<String, dynamic>;
      } catch (_) {}
      final isPublic = await bind.mainIsUsingPublicServer();
      final customServer = bind.mainGetOptionSync(key: 'custom-rendezvous-server');

      if (mounted) {
        setState(() {
          _connectionStatus = (statusMap['status_num'] as num?)?.toInt() ?? 0;
          _isPublicServer = isPublic;
          _serverHost = customServer.isNotEmpty ? customServer : 'Official Relay Cluster';
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _connectionStatus = 0;
          _isLoading = false;
        });
      }
    }
  }

  void _finishOnboarding() {
    bind.setLocalFlutterOption(k: FirstRunWizardDialog.optionKey, v: 'Y');
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final statusTone = switch (_connectionStatus) {
      1 => GlassBadgeTone.online,
      2 => GlassBadgeTone.danger,
      _ => GlassBadgeTone.connecting,
    };

    final statusLabel = switch (_connectionStatus) {
      1 => translate('Ready'),
      2 => translate('not_ready_status'),
      _ => translate('connecting_status'),
    };

    return GlassModalShell(
      maxWidth: 520,
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [CamelliaColors.indigo, CamelliaColors.azure],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              boxShadow: [
                BoxShadow(
                  color: CamelliaColors.indigo.withValues(alpha: 0.28),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  translate('Welcome to Camellia Remote'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  translate('Liquid Glass Experience & Zero-Trust Architecture'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        GlassButton(
          variant: GlassButtonVariant.primary,
          icon: const Icon(Icons.arrow_forward_rounded, size: 16),
          onPressed: _finishOnboarding,
          child: Text(translate('Get Started')),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Network & Relay Status Card
          GlassCard(
            layer: CamelliaGlassLayer.floating,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      translate('Network Status'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    GlassBadge(
                      label: statusLabel,
                      tone: statusTone,
                      showDot: true,
                      pulse: _connectionStatus == 1,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      _isPublicServer ? Icons.public : Icons.dns_outlined,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isLoading
                            ? translate('Checking...')
                            : '${translate('Relay')}: $_serverHost',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Pillar 1: High Performance
          _FeatureCard(
            icon: Icons.speed_rounded,
            iconColor: CamelliaColors.azure,
            title: translate('Ultra-Responsive Canvas'),
            description: translate('60/120 FPS high refresh rate rendering with hardware accelerated decoding.'),
          ),
          const SizedBox(height: 8),

          // Pillar 2: Security
          _FeatureCard(
            icon: Icons.shield_rounded,
            iconColor: CamelliaColors.statusOnlineDark,
            title: translate('Zero-Trust Security'),
            description: translate('End-to-end encrypted direct peer-to-peer transport with cryptographic verification.'),
          ),
          const SizedBox(height: 8),

          // Pillar 3: Multi-Platform
          _FeatureCard(
            icon: Icons.devices_rounded,
            iconColor: CamelliaColors.orchid,
            title: translate('Unified Cross-Platform'),
            description: translate('Shared clipboard, multi-tab windowing, instant file transfer and remote audio.'),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GlassCard(
      layer: CamelliaGlassLayer.floating,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
