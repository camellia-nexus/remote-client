import 'dart:async';

import 'package:auto_size_text_field/auto_size_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/connection_page_title.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:camellia_remote_app/models/peer_model.dart';

import '../../common.dart';
import '../../common/widgets/peer_tab_page.dart';
import '../../common/widgets/autocomplete.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'home_page.dart';

enum _MobileConnectMode { desktop, files, camera, terminal }

/// Connection page for connecting to a remote peer.
class ConnectionPage extends StatefulWidget implements PageShape {
  const ConnectionPage({super.key, required this.appBarActions, this.shareSection});

  @override
  Icon get icon => const Icon(Icons.connected_tv_outlined);

  @override
  String get title => translate("Connection");

  @override
  final List<Widget> appBarActions;
  final Widget? shareSection;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

/// State for the connection page.
class _ConnectionPageState extends State<ConnectionPage> {
  /// Controller for the id input bar.
  final _idController = IDTextEditingController();
  final RxBool _idEmpty = true.obs;
  final RxBool _idFocused = false.obs;
  _MobileConnectMode _connectMode = _MobileConnectMode.desktop;

  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();

  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  StreamSubscription? _uniLinksSubscription;

  // https://github.com/flutter/flutter/issues/157244
  Iterable<Peer> _autocompleteOpts = [];

  _ConnectionPageState() {
    if (!isWeb) _uniLinksSubscription = listenUniLinks();
    _idController.addListener(() {
      _idEmpty.value = _idController.text.isEmpty;
    });
    Get.put<IDTextEditingController>(_idController);
  }

  @override
  void initState() {
    super.initState();
    _allPeersLoader.init(setState);
    _idFocusNode.addListener(onFocusChanged);
    if (_idController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = await bind.mainGetLastRemoteId();
        if (lastRemoteId != _idController.id) {
          setState(() {
            _idController.id = lastRemoteId;
          });
        }
      });
    }
    Get.put<TextEditingController>(_idEditingController);
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _buildRemoteIDTextField(),
              if (widget.shareSection != null) ...[
                const SizedBox(height: 12),
                CamelliaPageHeader(
                  title: translate('Share screen'),
                  subtitle: translate('Your Device'),
                  leading: const AppIconBadge(
                    icon: Icons.screen_share_rounded,
                    colors: AppVisual.securityGradient,
                    size: 36,
                    iconSize: 19,
                  ),
                ),
                const SizedBox(height: 10),
                widget.shareSection!,
              ],
            ]),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CamelliaPageHeader(
                  title: translate('Devices'),
                  subtitle: translate('Recent and trusted connections'),
                  leading: const AppIconBadge(
                    icon: Icons.devices_other_rounded,
                    colors: AppVisual.identityGradient,
                    size: 36,
                    iconSize: 19,
                  ),
                ),
                const SizedBox(height: 10),
                const Expanded(child: PeerTabPage()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Callback for the connect button.
  /// Connects to the selected peer using the active session mode.
  void onConnect() {
    var id = _idController.id;
    HapticFeedback.mediumImpact();
    connect(
      context,
      id,
      isFileTransfer: _connectMode == _MobileConnectMode.files,
      isViewCamera: _connectMode == _MobileConnectMode.camera,
      isTerminal: _connectMode == _MobileConnectMode.terminal,
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty || !mounted) return;
    HapticFeedback.lightImpact();
    setState(() {
      _idController.id = raw;
    });
  }

  String _modeLabel(_MobileConnectMode mode) => switch (mode) {
    _MobileConnectMode.desktop => translate('Control'),
    _MobileConnectMode.files => translate('Transfer file'),
    _MobileConnectMode.camera => translate('View camera'),
    _MobileConnectMode.terminal => translate('Terminal'),
  };

  IconData _modeIcon(_MobileConnectMode mode) => switch (mode) {
    _MobileConnectMode.desktop => Icons.desktop_windows_rounded,
    _MobileConnectMode.files => Icons.folder_copy_rounded,
    _MobileConnectMode.camera => Icons.videocam_rounded,
    _MobileConnectMode.terminal => Icons.terminal_rounded,
  };

  Color _modeAccent(_MobileConnectMode mode) => switch (mode) {
    _MobileConnectMode.desktop => CamelliaColors.indigo,
    _MobileConnectMode.files => CamelliaColors.azure,
    _MobileConnectMode.camera => CamelliaColors.aqua,
    _MobileConnectMode.terminal => CamelliaColors.orchid,
  };

  void onFocusChanged() {
    _idEmpty.value = _idEditingController.text.isEmpty;
    _idFocused.value = _idFocusNode.hasFocus;
    if (_idFocusNode.hasFocus) {
      if (_allPeersLoader.needLoad) {
        _allPeersLoader.getAllPeers();
      }

      final textLength = _idEditingController.value.text.length;
      // Select all to facilitate removing text, just following the behavior of address input of chrome.
      _idEditingController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: textLength,
      );
    }
  }

  /// UI for the remote ID TextField.
  /// Search for a peer and connect to it if the id exists.
  Widget _buildRemoteIDTextField() {
    final glass = CamelliaGlassTokens.of(context);
    final activeAccent = _modeAccent(_connectMode);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: kMobilePageConstraints,
        child: GlassCard(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          elevated: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWebDesktop)
                getConnectionPageTitle(
                  context,
                  true,
                ).marginOnly(bottom: 12, left: 2),
              if (!isWebDesktop)
                Row(
                  children: [
                    const CamelliaAnimatedBrandMark(size: 38),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            translate('Control Remote Desktop'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            translate('Remote ID'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: AppVisual.subduedText(context),
                                ),
                          ),
                        ],
                      ),
                    ),
                    GlassIconButton(
                      icon: Icons.content_paste_rounded,
                      tooltip: translate('Paste'),
                      size: 36,
                      iconSize: 17,
                      onPressed: _pasteFromClipboard,
                    ),
                  ],
                ).marginOnly(bottom: 14),
              Obx(
                () => AnimatedContainer(
                  duration: CamelliaMotion.resolve(
                    context,
                    CamelliaMotion.state,
                  ),
                  curve: CamelliaMotion.springSnappy,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppVisual.inset(context).withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                    border: Border.all(
                      color: _idFocused.value
                          ? activeAccent
                          : glass.specularBottom,
                      width: _idFocused.value ? 1.5 : 1.0,
                    ),
                    boxShadow: _idFocused.value
                        ? [
                            BoxShadow(
                              color: activeAccent.withValues(alpha: 0.20),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ]
                        : const [],
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final optionsWidth = (constraints.maxWidth - 96)
                          .clamp(220, 420)
                          .toDouble();
                      return Row(
                        children: <Widget>[
                          Expanded(child: _buildAutocomplete(optionsWidth)),
                          Obx(
                            () => Offstage(
                              offstage: _idEmpty.value,
                              child: IconButton(
                                tooltip: translate('Clear'),
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  setState(() {
                                    _idController.clear();
                                  });
                                },
                                icon: Icon(
                                  Icons.clear_rounded,
                                  color: AppVisual.subduedText(context),
                                ),
                              ),
                            ),
                          ),
                          GlassButton(
                            variant: GlassButtonVariant.primary,
                            tooltip: translate('Connect'),
                            minHeight: 46,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            borderRadius: BorderRadius.circular(
                              CamelliaRadius.control,
                            ),
                            onPressed: onConnect,
                            child: const Icon(
                              Icons.arrow_forward_rounded,
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final mode in _MobileConnectMode.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _buildModeChip(mode),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeChip(_MobileConnectMode mode) {
    final selected = _connectMode == mode;
    final accent = _modeAccent(mode);
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _connectMode = mode);
      },
      child: AnimatedContainer(
        duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
        curve: CamelliaMotion.springSnappy,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.24 : 0.14,
                )
              : AppVisual.inset(context).withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(CamelliaRadius.pill),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.55)
                : AppVisual.border(context).withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _modeIcon(mode),
              size: 15,
              color: selected ? accent : AppVisual.subduedText(context),
            ),
            const SizedBox(width: 6),
            Text(
              _modeLabel(mode),
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected ? accent : theme.colorScheme.onSurface,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutocomplete(double optionsWidth) {
    return RawAutocomplete<Peer>(
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
          String textWithoutSpaces = textEditingValue.text.replaceAll(" ", "");
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
          _allPeersLoader.queryOnlines(_autocompleteOpts);
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
              style: CamelliaTypography.tabular(
                TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 28,
                  letterSpacing: 0.4,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              decoration: InputDecoration(
                labelText: translate('Remote ID'),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: 0,
                  color: AppVisual.subduedText(context),
                ),
              ),
              inputFormatters: [IDTextInputFormatter()],
              onSubmitted: (_) {
                onConnect();
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
            double maxHeight = options.length * 50;
            if (options.length == 1) {
              maxHeight = 52;
            } else if (options.length == 3) {
              maxHeight = 146;
            } else if (options.length == 4) {
              maxHeight = 193;
            }
            maxHeight = maxHeight.clamp(0, 200);
            return Align(
              alignment: Alignment.topLeft,
              child: GlassSurface(
                layer: CamelliaGlassLayer.modal,
                elevated: true,
                borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: maxHeight,
                      maxWidth: optionsWidth,
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
                            padding: const EdgeInsets.only(top: 5),
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
              ),
            );
          },
    );
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    _idController.dispose();
    _idFocusNode.removeListener(onFocusChanged);
    _allPeersLoader.clear();
    _idFocusNode.dispose();
    _idEditingController.dispose();
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }
}
