import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/shared_state.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';

class _PortForward {
  int localPort;
  String remoteHost;
  int remotePort;

  _PortForward.fromJson(List<dynamic> json)
    : localPort = json[0] as int,
      remoteHost = json[1] as String,
      remotePort = json[2] as int;
}

class PortForwardPage extends StatefulWidget {
  PortForwardPage({
    Key? key,
    required this.id,
    required this.password,
    required this.tabController,
    required this.isRDP,
    required this.isSharedPassword,
    this.forceRelay,
    this.connToken,
  }) : super(key: key);
  final String id;
  final String? password;
  final DesktopTabController tabController;
  final bool isRDP;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final SimpleWrapper<State<PortForwardPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _PortForwardPageState)._ffi;

  @override
  State<PortForwardPage> createState() {
    final state = _PortForwardPageState();
    _lastState.value = state;
    return state;
  }
}

class _PortForwardPageState extends State<PortForwardPage>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController localPortController = TextEditingController();
  final TextEditingController remoteHostController = TextEditingController();
  final TextEditingController remotePortController = TextEditingController();
  final _overlayKeyState = OverlayKeyState();
  RxList<_PortForward> pfs = RxList.empty(growable: true);
  late FFI _ffi;
  Worker? _connReadyWorker;

  @override
  void initState() {
    super.initState();
    _ffi = FFI(null);
    _ffi.dialogManager.setOverlayState(_overlayKeyState);
    _ffi.start(
      widget.id,
      isPortForward: true,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
      connToken: widget.connToken,
      isRdp: widget.isRDP,
    );
    if (Get.isRegistered<FFI>(tag: 'pf_${widget.id}')) {
      Get.delete<FFI>(tag: 'pf_${widget.id}', force: true);
    }
    Get.put<FFI>(_ffi, tag: 'pf_${widget.id}');
    if (!widget.isRDP) {
      refreshTunnelConfig();
    }
    _connReadyWorker = ever<bool>(_ffi.ffiModel.pi.isSet, (bool ready) {
      if (ready && mounted) {
        _ffi.dialogManager.dismissAll();
        if (!widget.isRDP) {
          refreshTunnelConfig();
        }
      }
    });
    debugPrint("Port forward page init success with id ${widget.id}");
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_ffi.ffiModel.pi.isSet.isFalse) {
        _ffi.dialogManager.showLoading(
          translate('Connecting...'),
          onCancel: closeConnection,
        );
      }
      widget.tabController.onSelected?.call(widget.id);
    });
  }

  @override
  void dispose() {
    _connReadyWorker?.dispose();
    localPortController.dispose();
    remoteHostController.dispose();
    remotePortController.dispose();
    _ffi.close();
    _ffi.dialogManager.dismissAll();
    deleteIfMatching<FFI>('pf_${widget.id}', _ffi);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Overlay(
      key: _overlayKeyState.key,
      initialEntries: [
        OverlayEntry(
          builder: (_) => Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: CamelliaBackdrop(
              padding: const EdgeInsets.all(20),
              child: GlassCard(
                accent: CamelliaColors.aqua,
                padding: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    buildPrompt(context),
                    Flexible(
                      child: widget.isRDP
                          ? buildRdp(context)
                          : buildTunnel(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildPrompt(BuildContext context) {
    final glass = CamelliaGlassTokens.of(context);
    return Obx(() {
      final connected = _ffi.ffiModel.pi.isSet.isTrue;
      return Offstage(
        offstage: pfs.isEmpty && !widget.isRDP && !connected,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: GlassSurface(
            layer: CamelliaGlassLayer.floating,
            strokeWidth: 0.85,
            tintColor: glass.statusEncrypted.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.14
                  : 0.08,
            ),
            showShadow: false,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                TelemetryPill(
                  label: connected
                      ? translate('Listening ...')
                      : translate('Connecting...'),
                  statusColor: connected
                      ? glass.statusOnline
                      : glass.statusConnecting,
                  icon: Icons.lan_rounded,
                  compact: true,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    translate('not_close_tcp_tip'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget buildTunnel(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(
      () => ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        children: [
          buildTunnelAddRow(context),
          if (pfs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CamelliaStateIllustration(
                      glyph: CamelliaGlyph.emptyTunnels,
                      accentColor: CamelliaColors.aqua,
                      size: 56,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      translate('No active port tunnels'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      translate('Add a local-to-remote port forward rule above'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            for (var i = 0; i < pfs.length; i++)
              buildTunnelDataRow(context, pfs[i], i),
        ],
      ),
    );
  }

  Widget buildTunnelAddRow(BuildContext context) {
    final portInputFormatter = <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(5),
    ];

    Future<void> onAddTunnel() async {
      final int? localPort = int.tryParse(localPortController.text.trim());
      final int? remotePort = int.tryParse(remotePortController.text.trim());
      if (localPort == null ||
          remotePort == null ||
          localPort < 1 ||
          localPort > 65535 ||
          remotePort < 1 ||
          remotePort > 65535) {
        showToast(translate('Invalid port'));
        return;
      }
      final remoteHost = remoteHostController.text.trim().isEmpty
          ? 'localhost'
          : remoteHostController.text.trim();
      await bind.sessionAddPortForward(
        sessionId: _ffi.sessionId,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );
      localPortController.clear();
      remoteHostController.clear();
      remotePortController.clear();
      refreshTunnelConfig();
    }

    final addButton = GlassButton(
      variant: GlassButtonVariant.primary,
      icon: const Icon(CamelliaIcons.add, size: 18),
      onPressed: onAddTunnel,
      child: Text(translate('Add')),
    );

    return GlassCard(
      margin: const EdgeInsets.only(bottom: 14),
      title: translate('Add'),
      subtitle:
          '${translate('Local Port')} → ${translate('Remote Host')}:${translate('Remote Port')}',
      accent: CamelliaColors.aqua,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    buildTunnelInputCell(
                      context,
                      controller: localPortController,
                      inputFormatters: portInputFormatter,
                      label: translate('Local Port'),
                      hint: '8080',
                      tabularNums: true,
                      onSubmitted: onAddTunnel,
                    ),
                    buildTunnelInputCell(
                      context,
                      controller: remotePortController,
                      inputFormatters: portInputFormatter,
                      label: translate('Remote Port'),
                      hint: '80',
                      tabularNums: true,
                      onSubmitted: onAddTunnel,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    buildTunnelInputCell(
                      context,
                      controller: remoteHostController,
                      label: translate('Remote Host'),
                      hint: 'localhost',
                      onSubmitted: onAddTunnel,
                    ),
                    const SizedBox(width: 8),
                    addButton,
                  ],
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              buildTunnelInputCell(
                context,
                controller: localPortController,
                inputFormatters: portInputFormatter,
                label: translate('Local Port'),
                hint: '8080',
                tabularNums: true,
                onSubmitted: onAddTunnel,
              ),
              const Padding(
                padding: EdgeInsets.only(left: 6, right: 6, bottom: 10),
                child: Icon(CamelliaIcons.arrowForward, size: 18),
              ),
              buildTunnelInputCell(
                context,
                controller: remoteHostController,
                label: translate('Remote Host'),
                hint: 'localhost',
                onSubmitted: onAddTunnel,
              ),
              buildTunnelInputCell(
                context,
                controller: remotePortController,
                inputFormatters: portInputFormatter,
                label: translate('Remote Port'),
                hint: '80',
                tabularNums: true,
                onSubmitted: onAddTunnel,
              ),
              const SizedBox(width: 8),
              addButton,
            ],
          );
        },
      ),
    );
  }

  Widget buildTunnelInputCell(
    BuildContext context, {
    required TextEditingController controller,
    List<TextInputFormatter>? inputFormatters,
    String? label,
    String? hint,
    bool tabularNums = false,
    VoidCallback? onSubmitted,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: GlassInput(
          controller: controller,
          labelText: label,
          hintText: hint,
          tabularNums: tabularNums,
          minHeight: 40,
          inputFormatters: inputFormatters,
          onSubmitted: onSubmitted != null ? (_) => onSubmitted() : null,
        ),
      ),
    );
  }

  Widget buildTunnelDataRow(BuildContext context, _PortForward pf, int index) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);

    Widget endpointBadge(String title, String value, IconData icon, Color tone) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppVisual.inset(context).withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
            border: Border.all(
              color: tone.withValues(alpha: 0.28),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 17, color: tone),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CamelliaTypography.tabular(
                        theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GlassSurface(
      layer: CamelliaGlassLayer.floating,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: glass.statusOnline,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: glass.statusOnline.withValues(alpha: 0.5),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          endpointBadge(
            translate('Local Port'),
            ':${pf.localPort}',
            Icons.laptop_rounded,
            theme.brightness == Brightness.dark
                ? theme.colorScheme.secondary
                : theme.colorScheme.primary,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Icon(
              Icons.double_arrow_rounded,
              size: 18,
              color: glass.statusEncrypted,
            ),
          ),
          endpointBadge(
            translate('Remote Host'),
            '${pf.remoteHost}:${pf.remotePort}',
            Icons.dns_rounded,
            glass.statusEncrypted,
          ),
          const SizedBox(width: 12),
          GlassIconButton(
            icon: Icons.close_rounded,
            tooltip: translate('Remove'),
            accentColor: glass.statusAlert,
            onPressed: () async {
              await bind.sessionRemovePortForward(
                sessionId: _ffi.sessionId,
                localPort: pf.localPort,
              );
              refreshTunnelConfig();
            },
          ),
        ],
      ),
    );
  }

  void refreshTunnelConfig() {
    try {
      final peer = bind.mainGetPeerSync(id: widget.id);
      if (!mounted || peer.isEmpty) return;
      final Map<String, dynamic> config = jsonDecode(peer);
      final infos = (config['port_forwards'] as List?) ?? const [];
      final List<_PortForward> result = [];
      for (final e in infos) {
        result.add(_PortForward.fromJson(e));
      }
      pfs.value = result;
    } catch (e) {
      debugPrint('refreshTunnelConfig failed: $e');
    }
  }

  Widget buildRdp(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    Widget endpointTile({
      required String label,
      required String value,
      required IconData icon,
      required Color tone,
    }) {
      return Expanded(
        child: GlassSurface(
          layer: CamelliaGlassLayer.floating,
          showShadow: false,
          enableBlur: false,
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 17, color: tone),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CamelliaTypography.tabular(
                        theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      child: GlassCard(
        title: translate('RDP'),
        subtitle: translate('Launch an encrypted local RDP tunnel session'),
        accent: accent,
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final launchBtn = GlassButton(
              variant: GlassButtonVariant.primary,
              icon: const Icon(CamelliaIcons.display, size: 18),
              onPressed: () => bind.sessionNewRdp(sessionId: _ffi.sessionId),
              child: Text(translate('New RDP')),
            );
            final endpoints = Row(
              children: [
                endpointTile(
                  label: translate('Remote Host'),
                  value: 'localhost',
                  icon: Icons.dns_rounded,
                  tone: accent,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(
                    Icons.double_arrow_rounded,
                    size: 18,
                    color: glass.statusEncrypted,
                  ),
                ),
                endpointTile(
                  label: translate('Remote Port'),
                  value: 'RDP',
                  icon: Icons.desktop_windows_rounded,
                  tone: glass.statusEncrypted,
                ),
              ],
            );
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [endpoints, const SizedBox(height: 12), launchBtn],
              );
            }
            return Row(
              children: [
                launchBtn,
                const SizedBox(width: 14),
                Expanded(child: endpoints),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
