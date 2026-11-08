import 'dart:async';
import 'dart:convert';

import 'package:auto_size_text_field/auto_size_text_field.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/common/widgets/autocomplete.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/web/web_client_settings_page.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../common.dart';
import '../models/model.dart';
import '../models/platform_model.dart';

class WebClientHomePage extends StatefulWidget {
  const WebClientHomePage({super.key});

  @override
  State<WebClientHomePage> createState() => _WebClientHomePageState();
}

class _WebClientHomePageState extends State<WebClientHomePage> {
  final IDTextEditingController _idController = IDTextEditingController();
  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();
  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  StreamSubscription? _uniLinksSubscription;
  Iterable<Peer> _autocompleteOpts = [];
  bool _idEmpty = true;
  bool _isFieldFocused = false;
  Timer? _statusTimer;
  String _myId = '';

  @override
  void initState() {
    super.initState();
    stateGlobal.isInMainPage = true;
    if (!isWeb) {
      _uniLinksSubscription = listenUniLinks();
    }
    _allPeersLoader.init(setState);
    _idController.addListener(() {
      final empty = _idController.text.isEmpty;
      if (empty != _idEmpty) {
        setState(() {
          _idEmpty = empty;
        });
      }
    });
    _idFocusNode.addListener(_onFocusChanged);

    if (_idController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = await bind.mainGetLastRemoteId();
        if (!mounted) return;
        if (lastRemoteId != _idController.id) {
          setState(() {
            _idController.id = lastRemoteId;
          });
        }
      });
    }

    Get.put<IDTextEditingController>(_idController);
    Get.put<TextEditingController>(_idEditingController);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleUnilink(context);
    });
    _syncClientStatus();
    _refreshMyId();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _syncClientStatus();
    });
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    _idController.dispose();
    _idFocusNode.removeListener(_onFocusChanged);
    _idFocusNode.dispose();
    _idEditingController.dispose();
    _statusTimer?.cancel();
    _allPeersLoader.clear();
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }

  Future<void> _syncClientStatus() async {
    try {
      final rawStatus = await bind.mainGetConnectStatus();
      final status = jsonDecode(rawStatus) as Map<String, dynamic>;
      final statusNum = (status['status_num'] as num?)?.toInt() ?? -1;
      if (statusNum == 1) {
        stateGlobal.svcStatus.value = SvcStatus.ready;
      } else if (statusNum == 0) {
        stateGlobal.svcStatus.value = SvcStatus.connecting;
      } else {
        stateGlobal.svcStatus.value = SvcStatus.notReady;
      }
    } catch (_) {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    }

    // Control-only web client: no local ID/password status to refresh.
    if (_myId.isEmpty) {
      _refreshMyId();
    }
  }

  Future<void> _refreshMyId() async {
    try {
      final id = await bind.mainGetMyId();
      if (mounted && id.isNotEmpty && id != _myId) {
        setState(() {
          _myId = id;
        });
      }
    } catch (_) {
      // Ignore ID refresh failures; keep last known value.
    }
  }

  Future<void> _rotateMyId() async {
    try {
      await bind.mainChangeId(newId: '');
      await _refreshMyId();
    } catch (_) {
      // Ignore rotation errors for now.
    }
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.forWidth(constraints.maxWidth);
        final compact = layout == AppLayoutSize.compact;
        final content = AdaptiveContent(
          maxWidth: 1440,
          child: Column(
            children: [
              _buildWorkspaceHeader(context),
              const SizedBox(height: 18),
              if (compact) ...[
                _buildConnectionSection(),
                const SizedBox(height: 12),
                _buildStatusCard(),
              ] else
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _buildConnectionSection()),
                      const SizedBox(width: 18),
                      SizedBox(width: 324, child: _buildStatusCard()),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              _buildPeersPanel(),
            ],
          ),
        );
        return Scaffold(
          backgroundColor: AppVisual.tokens(context).page,
          body: CamelliaBackdrop(
            child: SafeArea(
              child: FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: SingleChildScrollView(child: content),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openSettings() {
    return showSettingsOverlay<void>(
      context: context,
      title: translate('Settings'),
      builder: (_) => const WebClientSettingsPage(),
    );
  }

  Widget _buildWorkspaceHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CamelliaPageHeader(
        title: translate('Remote workspace'),
        subtitle: translate(
          'Connect and manage trusted devices in your browser',
        ),
        leading: CamelliaAnimatedBrandMark(
          size: 42,
          semanticLabel: bind.mainGetAppNameSync(),
        ),
        actions: [
          IconButton.filledTonal(
            tooltip: translate('Settings'),
            onPressed: _openSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
    );
  }

  void _onFocusChanged() {
    final focused = _idFocusNode.hasFocus;
    if (focused != _isFieldFocused) {
      setState(() {
        _isFieldFocused = focused;
      });
    }
    _idEmpty = _idEditingController.text.isEmpty;
    if (_idFocusNode.hasFocus) {
      if (_allPeersLoader.needLoad) {
        _allPeersLoader.getAllPeers();
      }
      final textLength = _idEditingController.value.text.length;
      _idEditingController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: textLength,
      );
    }
  }

  void _onConnect({
    bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isTerminal = false,
  }) {
    final id = _idController.id;
    connect(
      context,
      id,
      isFileTransfer: isFileTransfer,
      isViewCamera: isViewCamera,
      isTerminal: isTerminal,
    );
  }

  void _handleUnilink(BuildContext context) {
    if (!mounted || webInitialLink.isEmpty) {
      return;
    }
    final link = webInitialLink;
    webInitialLink = '';
    final splitter = ["/#/", "/#", "#/", "#"];
    var fakelink = '';
    for (var s in splitter) {
      if (link.contains(s)) {
        var list = link.split(s);
        if (list.length < 2 || list[1].isEmpty) {
          return;
        }
        list.removeAt(0);
        fakelink = "${bind.mainUriPrefixSync()}${list.join(s)}";
        break;
      }
    }
    if (fakelink.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(fakelink);
    if (uri == null) {
      return;
    }
    final args = urlLinkToCmdArgs(uri);
    if (args == null || args.isEmpty) {
      return;
    }
    bool isFileTransfer = false;
    bool isViewCamera = false;
    bool isTerminal = false;
    bool isTerminalRunAsAdmin = false;
    String? id;
    String? password;
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--connect':
        case '--play':
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--file-transfer':
          isFileTransfer = true;
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--view-camera':
          isViewCamera = true;
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--terminal':
          isTerminal = true;
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--terminal-admin':
          isTerminal = true;
          isTerminalRunAsAdmin = true;
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--password':
          if (i + 1 < args.length) {
            password = args[i + 1];
            i++;
          }
          break;
        default:
          break;
      }
    }
    if (id != null && mounted) {
      connect(
        context,
        id,
        isFileTransfer: isFileTransfer,
        isViewCamera: isViewCamera,
        isTerminal: isTerminal,
        password: password,
        isTerminalRunAsAdmin: isTerminalRunAsAdmin,
      );
    }
  }

  Widget _buildStatusCard() {
    const rowGap = SizedBox(height: 12);
    final muted = AppVisual.subduedText(context);
    return CamelliaSection(
      padding: const EdgeInsets.all(18),
      accent: CamelliaColors.aqua,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translate('Session status'),
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: muted),
          ),
          const SizedBox(height: 12),
          Obx(() {
            final status = stateGlobal.svcStatus.value;
            String label;
            Color color;
            switch (status) {
              case SvcStatus.ready:
                label = translate('Ready');
                color = AppVisual.tone(context, AppTone.success);
                break;
              case SvcStatus.connecting:
                label = translate('Connecting');
                color = AppVisual.tone(context, AppTone.warning);
                break;
              default:
                label = translate('Not ready');
                color = muted;
            }
            return _buildStatusRow(
              icon: Icons.circle,
              color: color,
              title: translate('Service'),
              value: label,
            );
          }),
          rowGap,
          _buildStatusRow(
            icon: Icons.lock_outline,
            color: muted,
            title: translate('Mode'),
            value: translate('Control-only'),
            trailing: Tooltip(
              message: translate(
                'Web client does not accept incoming connections. Use desktop/mobile to be controlled.',
              ),
              child: const Icon(Icons.info_outline, size: 16),
            ),
          ),
          rowGap,
          _buildStatusRow(
            icon: Icons.badge_outlined,
            color: muted,
            title: translate('Your ID'),
            value: _myId.isEmpty ? '—' : _myId,
            trailing: isChangeIdDisabled()
                ? null
                : Tooltip(
                    message: translate('Change ID'),
                    child: IconButton(
                      onPressed: _rotateMyId,
                      icon: const Icon(Icons.autorenew_rounded),
                      iconSize: 16,
                      padding: EdgeInsets.zero,
                      color: Theme.of(context).colorScheme.primary,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                    ),
                  ),
          ),
          rowGap,
          _buildStatusRow(
            icon: Icons.shield_outlined,
            color: Theme.of(context).colorScheme.primary,
            title: translate('Security'),
            value: translate('Encrypted channels'),
          ),
          rowGap,
          _buildStatusRow(
            icon: Icons.tune,
            color: muted,
            title: translate('Relay'),
            value: translate('Auto routing'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRow({
    required IconData icon,
    required Color color,
    required String title,
    required String value,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Row(
        children: [
          SizedBox(width: 18, child: Icon(icon, size: 16, color: color)),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppVisual.subduedText(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 24,
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionSection() {
    return CamelliaSection(
      padding: const EdgeInsets.all(20),
      accent: CamelliaColors.coral,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translate('Connect to a device'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            translate('Enter a Remote ID to start a session.'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppVisual.subduedText(context),
            ),
          ),
          const SizedBox(height: 16),
          _buildRemoteIdField(),
          const SizedBox(height: 12),
          _buildQuickActions(),
        ],
      ),
    );
  }

  Widget _buildRemoteIdField() {
    return AnimatedContainer(
      duration: AppMotion.duration(context, AppMotion.stateChange),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppVisual.inset(context),
        borderRadius: BorderRadius.circular(AppVisual.radius),
        border: Border.all(
          color: _isFieldFocused
              ? CamelliaColors.azure
              : AppVisual.border(context),
          width: _isFieldFocused ? 1.4 : 1.0,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: RawAutocomplete<Peer>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text == '') {
                  _autocompleteOpts = const Iterable<Peer>.empty();
                } else if (_allPeersLoader.peers.isEmpty &&
                    !_allPeersLoader.isPeersLoaded) {
                  Peer emptyPeer = Peer(
                    id: '',
                    username: '',
                    hostname: '',
                    alias: '',
                    platform: '',
                    tags: [],
                    hash: '',
                    password: '',
                    forceAlwaysRelay: false,
                    rdpPort: '',
                    rdpUsername: '',
                    loginName: '',
                    device_group_name: '',
                    note: '',
                  );
                  _autocompleteOpts = [emptyPeer];
                } else {
                  String textWithoutSpaces = textEditingValue.text.replaceAll(
                    " ",
                    "",
                  );
                  if (int.tryParse(textWithoutSpaces) != null) {
                    textEditingValue = TextEditingValue(
                      text: textWithoutSpaces,
                      selection: textEditingValue.selection,
                    );
                  }
                  String textToFind = textEditingValue.text.toLowerCase();
                  _autocompleteOpts = _allPeersLoader.peers
                      .where(
                        (peer) =>
                            peer.id.toLowerCase().contains(textToFind) ||
                            peer.username.toLowerCase().contains(textToFind) ||
                            peer.hostname.toLowerCase().contains(textToFind) ||
                            peer.alias.toLowerCase().contains(textToFind),
                      )
                      .toList();
                }
                return _autocompleteOpts;
              },
              focusNode: _idFocusNode,
              textEditingController: _idEditingController,
              fieldViewBuilder:
                  (
                    BuildContext context,
                    TextEditingController fieldTextEditingController,
                    FocusNode fieldFocusNode,
                    VoidCallback onFieldSubmitted,
                  ) {
                    updateTextAndPreserveSelection(
                      fieldTextEditingController,
                      _idController.text,
                    );
                    return AutoSizeTextField(
                      controller: fieldTextEditingController,
                      focusNode: fieldFocusNode,
                      minFontSize: 18,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      onChanged: (String text) {
                        _idController.id = text;
                      },
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        labelText: translate('Remote ID'),
                        border: InputBorder.none,
                        labelStyle: Theme.of(context).textTheme.labelMedium,
                      ),
                      inputFormatters: [IDTextInputFormatter()],
                      onSubmitted: (_) {
                        _onConnect();
                      },
                    );
                  },
              onSelected: (option) {
                setState(() {
                  _idController.id = option.id;
                  FocusScope.of(context).unfocus();
                });
              },
              optionsViewBuilder:
                  (
                    BuildContext context,
                    AutocompleteOnSelected<Peer> onSelected,
                    Iterable<Peer> options,
                  ) {
                    options = _autocompleteOpts;
                    double maxHeight = options.length * 50.0;
                    if (options.length == 1) {
                      maxHeight = 52;
                    } else if (options.length == 3) {
                      maxHeight = 146;
                    } else if (options.length == 4) {
                      maxHeight = 193;
                    }
                    maxHeight = maxHeight.clamp(0, 220);
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(AppVisual.radius),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: maxHeight,
                            maxWidth: 360,
                          ),
                          child:
                              _allPeersLoader.peers.isEmpty &&
                                  !_allPeersLoader.isPeersLoaded
                              ? const SizedBox(
                                  height: 80,
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : ListView(
                                  padding: const EdgeInsets.only(top: 6),
                                  children: options
                                      .map(
                                        (peer) => AutocompletePeerTile(
                                          onSelect: () => onSelected(peer),
                                          peer: peer,
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                      ),
                    );
                  },
            ),
          ),
          if (!_idEmpty)
            IconButton(
              onPressed: () {
                setState(() {
                  _idController.clear();
                });
              },
              icon: const Icon(Icons.clear),
              color: AppVisual.subduedText(context),
              tooltip: translate('Clear'),
            ),
          const SizedBox(width: 6),
          _ActionButton(
            label: translate('Connect'),
            icon: Icons.desktop_windows_outlined,
            onPressed: _idEmpty ? null : () => _onConnect(),
            isPrimary: true,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _ActionButton(
          label: translate('Remote Control'),
          icon: Icons.connected_tv,
          onPressed: _idEmpty ? null : () => _onConnect(),
        ),
        _ActionButton(
          label: translate('File Transfer'),
          icon: Icons.folder_copy_outlined,
          onPressed: _idEmpty ? null : () => _onConnect(isFileTransfer: true),
        ),
        _ActionButton(
          label: translate('Terminal'),
          icon: Icons.terminal,
          onPressed: _idEmpty ? null : () => _onConnect(isTerminal: true),
        ),
        _ActionButton(
          label: translate('View Camera'),
          icon: Icons.videocam_outlined,
          onPressed: _idEmpty ? null : () => _onConnect(isViewCamera: true),
        ),
      ],
    );
  }

  Widget _buildPeersPanel() {
    final viewportHeight = MediaQuery.of(context).size.height;
    final peersPanelHeight = viewportHeight < 760 ? 340.0 : 420.0;
    return AppSurface(
      padding: const EdgeInsets.all(20),
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translate('Your devices'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            translate('Recent, favorites, LAN, and address book peers.'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppVisual.subduedText(context),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(height: peersPanelHeight, child: PeerTabPage()),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.isPrimary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(
      label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      animationDuration: AppMotion.duration(context, AppMotion.feedback),
    );
    if (isPrimary) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: labelWidget,
        style: style,
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: labelWidget,
      style: style,
    );
  }
}
