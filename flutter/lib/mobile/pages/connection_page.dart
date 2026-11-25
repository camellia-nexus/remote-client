import 'dart:async';
import 'dart:math' as math;

import 'package:auto_size_text_field/auto_size_text_field.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/connection_page_title.dart';
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
import 'scan_page.dart';

enum _MobileConnectMode { desktop, files, camera, terminal }

/// Connection page for connecting to a remote peer.
class ConnectionPage extends StatefulWidget implements PageShape {
  const ConnectionPage({
    super.key,
    required this.appBarActions,
    this.shareSection,
  });

  @override
  Icon get icon => const Icon(CamelliaIcons.screen);

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
        if (mounted && lastRemoteId != _idController.id) {
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactVertical =
            constraints.maxHeight < 460 || widget.shareSection != null;

        if (!compactVertical) {
          // Non-contending studio split: Connect Deck stays pinned at top while
          // PeerTabPage owns the single vertical scroll surface below.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: _buildRemoteIDTextField(),
              ),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 2, 16, 4),
                  child: PeerTabPage(),
                ),
              ),
            ],
          );
        }

        // Compact landscape / embedded shareSection fallback with bounded peer height.
        final peerHeight = math.max(260.0, constraints.maxHeight - 72.0);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          children: [
            _buildRemoteIDTextField(),
            if (widget.shareSection != null) ...[
              const SizedBox(height: 12),
              CamelliaPageHeader(
                title: translate('Share screen'),
                subtitle: translate('Your Device'),
              ),
              const SizedBox(height: 8),
              widget.shareSection!,
            ],
            const SizedBox(height: 10),
            SizedBox(height: peerHeight, child: const PeerTabPage()),
          ],
        );
      },
    );
  }

  /// Connects to the selected peer using the active session mode.
  void onConnect() {
    final id = _idController.id.trim();
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
    final cleaned = raw.replaceAll(RegExp(r'[\s\-]+'), '');
    final numericMatch = RegExp(r'\d[\d\s\-]{4,}\d').firstMatch(raw);
    final String extracted;
    if (RegExp(r'^[\d\s\-]+$').hasMatch(raw) && cleaned.isNotEmpty) {
      extracted = cleaned;
    } else if (numericMatch != null) {
      extracted = numericMatch.group(0)!.replaceAll(RegExp(r'[\s\-]+'), '');
    } else {
      extracted = raw.split(RegExp(r'\s+')).first;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _idController.id = extracted;
    });
  }

  void _openQrScanner() {
    HapticFeedback.selectionClick();
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ScanPage()));
  }

  String _modeLabel(_MobileConnectMode mode) => switch (mode) {
    _MobileConnectMode.desktop => translate('Control'),
    _MobileConnectMode.files => translate('Transfer file'),
    _MobileConnectMode.camera => translate('View camera'),
    _MobileConnectMode.terminal => translate('Terminal'),
  };

  IconData _modeIcon(_MobileConnectMode mode) => switch (mode) {
    _MobileConnectMode.desktop => CamelliaIcons.display,
    _MobileConnectMode.files => CamelliaIcons.transfer,
    _MobileConnectMode.camera => CamelliaIcons.camera,
    _MobileConnectMode.terminal => CamelliaIcons.terminal,
  };

  void onFocusChanged() {
    _idEmpty.value = _idEditingController.text.isEmpty;
    _idFocused.value = _idFocusNode.hasFocus;
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

  /// Studio Connect Deck: tactile tabular ID field, quick Paste / QR / Clear,
  /// segmented session mode selector, and full-width primary Connect CTA.
  Widget _buildRemoteIDTextField() {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compactSegments = screenWidth < 390;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: kMobilePageConstraints,
        child: GlassCard(
          padding: const EdgeInsets.all(14),
          elevated: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWebDesktop)
                getConnectionPageTitle(
                  context,
                  true,
                ).marginOnly(bottom: 10, left: 2)
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      CamelliaVectorIcon(
                        CamelliaGlyph.remoteDesktop,
                        size: 18,
                        color: accent,
                        duotone: true,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          translate('Control Remote Desktop'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                      GlassIconButton(
                        icon: CamelliaIcons.paste,
                        tooltip: translate('Paste'),
                        size: 34,
                        iconSize: 16,
                        onPressed: _pasteFromClipboard,
                      ),
                      if (!isWeb) ...[
                        const SizedBox(width: 6),
                        GlassIconButton(
                          icon: CamelliaIcons.qrScan,
                          tooltip: translate('Scan QR'),
                          size: 34,
                          iconSize: 16,
                          onPressed: _openQrScanner,
                        ),
                      ],
                    ],
                  ),
                ),
              Obx(
                () => AnimatedContainer(
                  duration: CamelliaMotion.resolve(
                    context,
                    CamelliaMotion.hover,
                  ),
                  curve: CamelliaMotion.standard,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.surfaceContainer.withValues(
                      alpha: dark ? 0.72 : 0.82,
                    ),
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    border: Border.all(
                      color: _idFocused.value
                          ? accent.withValues(alpha: 0.85)
                          : tokens.border.withValues(alpha: 0.85),
                      width: _idFocused.value ? 1.2 : 0.85,
                    ),
                    boxShadow: _idFocused.value
                        ? [
                            BoxShadow(
                              color: accent.withValues(
                                alpha: dark ? 0.22 : 0.14,
                              ),
                              blurRadius: 10,
                            ),
                          ]
                        : const [],
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final optionsWidth = (constraints.maxWidth - 40)
                          .clamp(200.0, 440.0);
                      return Row(
                        children: <Widget>[
                          Expanded(child: _buildAutocomplete(optionsWidth)),
                          Obx(
                            () => _idEmpty.value
                                ? const SizedBox.shrink()
                                : GlassIconButton(
                                    icon: CamelliaIcons.close,
                                    tooltip: translate('Clear'),
                                    size: 32,
                                    iconSize: 15,
                                    onPressed: () {
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _idController.clear();
                                      });
                                    },
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              GlassSegmentedControl<_MobileConnectMode>(
                expand: true,
                compact: compactSegments,
                selected: _connectMode,
                items: [
                  GlassSegmentItem(
                    value: _MobileConnectMode.desktop,
                    icon: CamelliaIcons.display,
                    label: compactSegments ? null : translate('Control'),
                    tooltip: translate('Control'),
                  ),
                  GlassSegmentItem(
                    value: _MobileConnectMode.files,
                    icon: CamelliaIcons.transfer,
                    label: compactSegments ? null : translate('Transfer file'),
                    tooltip: translate('Transfer file'),
                  ),
                  GlassSegmentItem(
                    value: _MobileConnectMode.camera,
                    icon: CamelliaIcons.camera,
                    label: compactSegments ? null : translate('View camera'),
                    tooltip: translate('View camera'),
                  ),
                  GlassSegmentItem(
                    value: _MobileConnectMode.terminal,
                    icon: CamelliaIcons.terminal,
                    label: compactSegments ? null : translate('Terminal'),
                    tooltip: translate('Terminal'),
                  ),
                ],
                onChanged: (next) {
                  setState(() => _connectMode = next);
                },
              ),
              const SizedBox(height: 10),
              GlassButton(
                variant: GlassButtonVariant.primary,
                expand: true,
                minHeight: 44,
                icon: Icon(_modeIcon(_connectMode), size: 18),
                onPressed: onConnect,
                child: Text(
                  '${translate('Connect')} · ${_modeLabel(_connectMode)}',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutocomplete(double optionsWidth) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
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
              minFontSize: 16,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              onChanged: (String text) {
                _idController.id = text;
              },
              style: CamelliaTypography.tabular(
                TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 24,
                  letterSpacing: 0.4,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              decoration: InputDecoration(
                labelText: translate('Remote ID'),
                hintText: '000 000 000',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: 4,
                ),
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  letterSpacing: 0,
                  color: tokens.muted,
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
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
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
                              padding: const EdgeInsets.symmetric(vertical: 4),
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
