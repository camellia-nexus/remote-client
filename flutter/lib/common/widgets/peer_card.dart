import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/peer_tab_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../desktop/widgets/popup_menu.dart';
import 'dart:math' as math;

typedef PopupMenuEntryBuilder =
    Future<List<mod_menu.PopupMenuEntry<String>>> Function(BuildContext);

enum PeerUiType { grid, tile, list }

final peerCardUiType = PeerUiType.grid.obs;

bool? hideUsernameOnCard;

Color _getCohesiveCardTint(String id, bool isLight) {
  const tints = [
    CamelliaColors.azure,
    CamelliaColors.indigo,
    CamelliaColors.aqua,
    CamelliaColors.orchid,
    CamelliaColors.sun,
  ];
  final index = id.hashCode.abs() % tints.length;
  return tints[index].withValues(alpha: isLight ? 0.08 : 0.14);
}

class _PeerCard extends StatefulWidget {
  final Peer peer;
  final PeerTabIndex tab;
  final Function(BuildContext, String) connect;
  final PopupMenuEntryBuilder popupMenuEntryBuilder;

  const _PeerCard({
    required this.peer,
    required this.tab,
    required this.connect,
    required this.popupMenuEntryBuilder,
  });

  @override
  _PeerCardState createState() => _PeerCardState();
}

/// State for the connection page.
class _PeerCardState extends State<_PeerCard>
    with AutomaticKeepAliveClientMixin {
  var _menuPos = RelativeRect.fill;
  bool _hovered = false;
  final double _cardRadius = AppVisual.radius;
  final double _tileRadius = AppVisual.compactRadius;
  final double _borderWidth = 1;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Obx(
      () =>
          stateGlobal.isPortrait.isTrue ? _buildPortrait() : _buildLandscape(),
    );
  }

  Widget gestureDetector({required Widget child}) {
    final PeerTabModel peerTabModel = Provider.of(context);
    final peer = super.widget.peer;
    return GestureDetector(
      onDoubleTap: peerTabModel.multiSelectionMode
          ? null
          : () => widget.connect(context, peer.id),
      onTap: () {
        if (peerTabModel.multiSelectionMode) {
          peerTabModel.select(peer);
        } else {
          if (isMobile) {
            widget.connect(context, peer.id);
          } else {
            peerTabModel.select(peer);
          }
        }
      },
      onLongPress: () => peerTabModel.select(peer),
      child: child,
    );
  }

  Widget _buildPortrait() {
    final peer = super.widget.peer;
    return Card(
      elevation: 0,
      color: AppVisual.surface(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_tileRadius),
        side: BorderSide(color: AppVisual.border(context)),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      child: gestureDetector(
        child: Container(
          padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
          child: _buildPeerTile(context, peer, false),
        ),
      ),
    );
  }

  Widget _buildLandscape() {
    final peer = super.widget.peer;
    return MouseRegion(
      onEnter: (evt) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (evt) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: gestureDetector(
        child: Obx(
          () => peerCardUiType.value == PeerUiType.grid
              ? _buildPeerCard(context, peer, _hovered)
              : _buildPeerTile(context, peer, _hovered),
        ),
      ),
    );
  }

  bool _showNote(Peer peer) {
    return peerTabShowNote(widget.tab) && peer.note.isNotEmpty;
  }

  Widget makeChild(bool isPortrait, Peer peer) {
    final name = hideUsernameOnCard == true
        ? peer.hostname
        : '${peer.username}${peer.username.isNotEmpty && peer.hostname.isNotEmpty ? '@' : ''}${peer.hostname}';
    final greyStyle = TextStyle(
      fontSize: 12,
      color: Theme.of(
        context,
      ).textTheme.titleLarge?.color?.withValues(alpha: 0.62),
    );
    final showNote = _showNote(peer);
    final isLight = AppVisual.isLight(context);
    final tokens = AppVisual.tokens(context);

    final platformBadge = Container(
      width: isPortrait ? 40 : 38,
      height: isPortrait ? 40 : 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.surfaceContainer.withValues(alpha: isLight ? 0.7 : 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: tokens.border.withValues(alpha: isLight ? 0.5 : 0.3),
          width: 1,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          getPlatformImage(
            peer.platform,
            size: isPortrait ? 26 : 24,
          ),
          if (_shouldBuildPasswordIcon(peer))
            Positioned(
              top: 2,
              left: 2,
              child: Icon(
                Icons.key,
                size: 8,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
        ],
      ),
    );

    if (!isPortrait && peerCardUiType.value == PeerUiType.list) {
      return Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            platformBadge,
            const SizedBox(width: 12),
            SizedBox(
              width: 180,
              child: Row(
                children: [
                  getOnline(8, peer.online),
                  Expanded(
                    child: Text(
                      peer.alias.isEmpty ? formatID(peer.id) : peer.alias,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: name,
                waitDuration: const Duration(seconds: 1),
                child: Text(
                  name,
                  style: greyStyle,
                  textAlign: TextAlign.start,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (showNote)
              SizedBox(
                width: 160,
                child: Tooltip(
                  message: peer.note,
                  waitDuration: const Duration(seconds: 1),
                  child: Text(
                    peer.note,
                    style: greyStyle,
                    textAlign: TextAlign.start,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            checkBoxOrActionMoreLandscape(peer, isTile: true),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isPortrait ? 8 : 10,
        vertical: isPortrait ? 4 : 6,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          platformBadge,
          SizedBox(width: isPortrait ? 10 : 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    getOnline(isPortrait ? 4 : 8, peer.online),
                    Expanded(
                      child: Text(
                        peer.alias.isEmpty ? formatID(peer.id) : peer.alias,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Tooltip(
                        message: name,
                        waitDuration: const Duration(seconds: 1),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            name,
                            style: isPortrait ? null : greyStyle,
                            textAlign: TextAlign.start,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    if (showNote)
                      Expanded(
                        child: Tooltip(
                          message: peer.note,
                          waitDuration: const Duration(seconds: 1),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              peer.note,
                              style: isPortrait ? null : greyStyle,
                              textAlign: TextAlign.start,
                              overflow: TextOverflow.ellipsis,
                            ).marginOnly(left: 4),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          isPortrait
              ? checkBoxOrActionMorePortrait(peer)
              : checkBoxOrActionMoreLandscape(peer, isTile: true),
        ],
      ),
    );
  }

  Widget _buildPeerTile(
    BuildContext context,
    Peer peer,
    bool isHovered,
  ) {
    hideUsernameOnCard ??=
        bind.mainGetBuildinOption(key: kHideUsernameOnCard) == 'Y';
    final colors = _frontN(
      peer.tags,
      25,
    ).map((e) => gFFI.abModel.getCurrentAbTagColor(e)).toList();
    final tokens = AppVisual.tokens(context);
    final isLight = AppVisual.isLight(context);
    final theme = Theme.of(context);

    final tileDeco = stateGlobal.isPortrait.isTrue
        ? null
        : BoxDecoration(
            color: isHovered
                ? (isLight ? theme.colorScheme.surface : tokens.surfaceContainer)
                : theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(_tileRadius),
            border: Border.all(
              color: isHovered
                  ? theme.colorScheme.primary.withValues(alpha: 0.6)
                  : tokens.border.withValues(alpha: isLight ? 0.7 : 0.4),
              width: _borderWidth,
            ),
            boxShadow: isHovered ? AppVisual.shadow(context) : null,
          );

    final child = tileDeco == null
        ? makeChild(stateGlobal.isPortrait.isTrue, peer)
        : Container(
            decoration: tileDeco,
            clipBehavior: Clip.antiAlias,
            child: makeChild(stateGlobal.isPortrait.isTrue, peer),
          );

    return Tooltip(
      message: !(isDesktop || isWebDesktop)
          ? ''
          : peer.tags.isNotEmpty
          ? '${translate('Tags')}: ${peer.tags.join(', ')}'
          : '',
      child: Stack(
        children: [
          child,
          if (colors.isNotEmpty)
            Positioned(
              top: 2,
              right: stateGlobal.isPortrait.isTrue ? 20 : 10,
              child: CustomPaint(
                painter: TagPainter(radius: 3, colors: colors),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPeerCard(
    BuildContext context,
    Peer peer,
    bool isHovered,
  ) {
    hideUsernameOnCard ??=
        bind.mainGetBuildinOption(key: kHideUsernameOnCard) == 'Y';
    final name = hideUsernameOnCard == true
        ? peer.hostname
        : '${peer.username}${peer.username.isNotEmpty && peer.hostname.isNotEmpty ? '@' : ''}${peer.hostname}';
    final isLight = AppVisual.isLight(context);
    final tokens = AppVisual.tokens(context);
    final theme = Theme.of(context);
    final tint = _getCohesiveCardTint(peer.id, isLight);

    final cardDeco = BoxDecoration(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(_cardRadius),
      border: Border.all(
        color: isHovered
            ? theme.colorScheme.primary.withValues(alpha: 0.6)
            : tokens.border.withValues(alpha: isLight ? 0.7 : 0.4),
        width: _borderWidth,
      ),
      boxShadow: isHovered
          ? AppVisual.shadow(context, elevated: true)
          : AppVisual.shadow(context),
    );

    final child = Container(
      decoration: cardDeco,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_cardRadius - _borderWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                    tint,
                    isLight ? tokens.surfaceContainer : theme.colorScheme.surfaceContainerLow,
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: tokens.border.withValues(alpha: isLight ? 0.5 : 0.3),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            child: Container(
                              width: 48,
                              height: 48,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: (isLight
                                        ? theme.colorScheme.surface
                                        : tokens.surfaceContainer)
                                    .withValues(alpha: isLight ? 0.9 : 0.7),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: tokens.border.withValues(
                                    alpha: isLight ? 0.6 : 0.3,
                                  ),
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: isLight ? 0.04 : 0.15,
                                    ),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              child: getPlatformImage(
                                peer.platform,
                                size: 32,
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: Tooltip(
                                  message: name,
                                  waitDuration: const Duration(seconds: 1),
                                  child: Text(
                                    name,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                    textAlign: TextAlign.center,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_showNote(peer))
                            Row(
                              children: [
                                Expanded(
                                  child: Tooltip(
                                    message: peer.note,
                                    waitDuration: const Duration(
                                      seconds: 1,
                                    ),
                                    child: Text(
                                      peer.note,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: tokens.muted,
                                        fontSize: 10,
                                      ),
                                      textAlign: TextAlign.center,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ).paddingOnly(top: 4.0, left: 4.0, right: 4.0),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              color: isLight
                  ? theme.colorScheme.surface
                  : theme.colorScheme.surfaceContainerLow,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        getOnline(8, peer.online),
                        Expanded(
                          child: Text(
                            peer.alias.isEmpty
                                ? formatID(peer.id)
                                : peer.alias,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ).paddingSymmetric(vertical: 8),
                  ),
                  checkBoxOrActionMoreLandscape(peer, isTile: false),
                ],
              ).paddingSymmetric(horizontal: 12.0),
            ),
          ],
        ),
      ),
    );

    final colors = _frontN(
      peer.tags,
      25,
    ).map((e) => gFFI.abModel.getCurrentAbTagColor(e)).toList();
    return Tooltip(
      message: peer.tags.isNotEmpty
          ? '${translate('Tags')}: ${peer.tags.join(', ')}'
          : '',
      child: Stack(
        children: [
          child,
          if (_shouldBuildPasswordIcon(peer))
            Positioned(
              top: 6,
              left: 10,
              child: Icon(
                Icons.key,
                size: 14,
                color: theme.colorScheme.primary,
              ),
            ),
          if (colors.isNotEmpty)
            Positioned(
              top: 4,
              right: 12,
              child: CustomPaint(
                painter: TagPainter(radius: 4, colors: colors),
              ),
            ),
        ],
      ),
    );
  }

  List<T> _frontN<T>(List<T> list, int n) {
    if (list.length <= n) {
      return list;
    } else {
      return list.sublist(0, n);
    }
  }

  Widget checkBoxOrActionMorePortrait(Peer peer) {
    final PeerTabModel peerTabModel = Provider.of(context);
    final selected = peerTabModel.isPeerSelected(peer.id);
    if (peerTabModel.multiSelectionMode) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: selected
            ? Icon(Icons.check_box, color: Theme.of(context).colorScheme.primary)
            : Icon(Icons.check_box_outline_blank),
      );
    } else {
      return InkWell(
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.more_vert),
        ),
        onTapDown: (e) {
          final x = e.globalPosition.dx;
          final y = e.globalPosition.dy;
          _menuPos = RelativeRect.fromLTRB(x, y, x, y);
        },
        onTap: () {
          _showPeerMenu(peer.id);
        },
      );
    }
  }

  Widget checkBoxOrActionMoreLandscape(Peer peer, {required bool isTile}) {
    final PeerTabModel peerTabModel = Provider.of(context);
    final selected = peerTabModel.isPeerSelected(peer.id);
    if (peerTabModel.multiSelectionMode) {
      final icon = selected
          ? Icon(Icons.check_box, color: Theme.of(context).colorScheme.primary)
          : Icon(Icons.check_box_outline_blank);
      bool last = peerTabModel.isShiftDown && peer.id == peerTabModel.lastId;
      double right = isTile ? 4 : 0;
      if (last) {
        return Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 1,
            ),
          ),
          child: icon,
        ).marginOnly(right: right);
      } else {
        return icon.marginOnly(right: right);
      }
    } else {
      return _actionMore(peer);
    }
  }

  Widget _actionMore(Peer peer) => Listener(
    onPointerDown: (e) {
      final x = e.position.dx;
      final y = e.position.dy;
      _menuPos = RelativeRect.fromLTRB(x, y, x, y);
    },
    onPointerUp: (_) => _showPeerMenu(peer.id),
    child: build_more(context),
  );

  bool _shouldBuildPasswordIcon(Peer peer) {
    if (gFFI.peerTabModel.currentTab != PeerTabIndex.ab.index) return false;
    if (gFFI.abModel.current.isPersonal()) return false;
    return peer.password.isNotEmpty;
  }

  /// Show the peer menu and handle user's choice.
  /// User might remove the peer or send a file to the peer.
  void _showPeerMenu(String id) async {
    await mod_menu.showMenu(
      context: context,
      position: _menuPos,
      items: await super.widget.popupMenuEntryBuilder(context),
      elevation: 8,
    );
  }

  @override
  bool get wantKeepAlive => true;
}

abstract class BasePeerCard extends StatelessWidget {
  final Peer peer;
  final PeerTabIndex tab;
  final EdgeInsets? menuPadding;

  const BasePeerCard({
    required this.peer,
    required this.tab,
    this.menuPadding,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return _PeerCard(
      peer: peer,
      tab: tab,
      connect: (BuildContext context, String id) =>
          connectInPeerTab(context, peer, tab),
      popupMenuEntryBuilder: _buildPopupMenuEntry,
    );
  }

  Future<List<mod_menu.PopupMenuEntry<String>>> _buildPopupMenuEntry(
    BuildContext context,
  ) async => (await _buildMenuItems(context))
      .map(
        (e) => e.build(
          context,
          const MenuConfig(
            commonColor: CustomPopupMenuTheme.commonColor,
            height: CustomPopupMenuTheme.height,
            dividerHeight: CustomPopupMenuTheme.dividerHeight,
          ),
        ),
      )
      .expand((i) => i)
      .toList();

  @protected
  Future<List<MenuEntryBase<String>>> _buildMenuItems(BuildContext context);

  MenuEntryBase<String> _connectCommonAction(
    BuildContext context,
    String title, {
    bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isTcpTunneling = false,
    bool isRDP = false,
    bool isTerminal = false,
    bool isTerminalRunAsAdmin = false,
  }) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(title, style: style),
      proc: () {
        connectInPeerTab(
          context,
          peer,
          tab,
          isFileTransfer: isFileTransfer,
          isViewCamera: isViewCamera,
          isTcpTunneling: isTcpTunneling,
          isRDP: isRDP,
          isTerminal: isTerminal || isTerminalRunAsAdmin,
          isTerminalRunAsAdmin: isTerminalRunAsAdmin,
        );
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _connectAction(BuildContext context) {
    return _connectCommonAction(
      context,
      (peer.alias.isEmpty
          ? translate('Connect')
          : '${translate('Connect')} ${peer.id}'),
    );
  }

  @protected
  MenuEntryBase<String> _transferFileAction(BuildContext context) {
    return _connectCommonAction(
      context,
      translate('Transfer file'),
      isFileTransfer: true,
    );
  }

  @protected
  MenuEntryBase<String> _viewCameraAction(BuildContext context) {
    return _connectCommonAction(
      context,
      translate('View camera'),
      isViewCamera: true,
    );
  }

  @protected
  MenuEntryBase<String> _terminalAction(BuildContext context) {
    return _connectCommonAction(
      context,
      '${translate('Terminal')} (beta)',
      isTerminal: true,
    );
  }

  @protected
  MenuEntryBase<String> _terminalRunAsAdminAction(BuildContext context) {
    return _connectCommonAction(
      context,
      '${translate('Terminal (Run as administrator)')} (beta)',
      isTerminalRunAsAdmin: true,
    );
  }

  @protected
  MenuEntryBase<String> _tcpTunnelingAction(BuildContext context) {
    return _connectCommonAction(
      context,
      translate('TCP tunneling'),
      isTcpTunneling: true,
    );
  }

  @protected
  MenuEntryBase<String> _rdpAction(BuildContext context, String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Container(
        alignment: AlignmentDirectional.center,
        height: CustomPopupMenuTheme.height,
        child: Row(
          children: [
            Text(translate('RDP'), style: style),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Transform.scale(
                  scale: 0.8,
                  child: IconButton(
                    icon: const Icon(Icons.edit),
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      if (Navigator.canPop(context)) {
                        Navigator.pop(context);
                      }
                      _rdpDialog(id);
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      proc: () {
        connectInPeerTab(context, peer, tab, isRDP: true);
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _wolAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(translate('WOL'), style: style),
      proc: () {
        bind.mainWol(id: id);
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  /// Only available on Windows.
  @protected
  MenuEntryBase<String> _createShortCutAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate('Create desktop shortcut'), style: style),
      proc: () {
        bind.mainCreateShortcut(id: id);
        showToast(translate('Successful'));
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  Future<MenuEntryBase<String>> _openNewConnInAction(
    String id,
    String label,
    String key,
  ) async {
    return MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate(label),
      getter: () async => mainGetPeerBoolOptionSync(id, key),
      setter: (bool v) async {
        await bind.mainSetPeerOption(
          id: id,
          key: key,
          value: bool2option(key, v),
        );
        showToast(translate('Successful'));
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  Future<MenuEntryBase<String>> _openInTabsAction(String id) async =>
      await _openNewConnInAction(id, 'Open in New Tab', kOptionOpenInTabs);

  Future<MenuEntryBase<String>> _openInWindowsAction(String id) async =>
      await _openNewConnInAction(
        id,
        'Open in new window',
        kOptionOpenInWindows,
      );

  // ignore: unused_element
  Future<MenuEntryBase<String>> _openNewConnInOptAction(String id) async =>
      mainGetLocalBoolOptionSync(kOptionOpenNewConnInTabs)
          ? await _openInWindowsAction(id)
          : await _openInTabsAction(id);

  @protected
  Future<bool> _isForceAlwaysRelay(String id) async {
    return option2bool(
      kOptionForceAlwaysRelay,
      (await bind.mainGetPeerOption(id: id, key: kOptionForceAlwaysRelay)),
    );
  }

  @protected
  Future<MenuEntryBase<String>> _forceAlwaysRelayAction(String id) async {
    return MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate('Always connect via relay'),
      getter: () async {
        return await _isForceAlwaysRelay(id);
      },
      setter: (bool v) async {
        await bind.mainSetPeerOption(
          id: id,
          key: kOptionForceAlwaysRelay,
          value: bool2option(kOptionForceAlwaysRelay, v),
        );
        showToast(translate('Successful'));
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _renameAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate('Rename'), style: style),
      proc: () async {
        String oldName = await _getAlias(id);
        renameDialog(
          oldName: oldName,
          onSubmit: (String newName) async {
            if (newName != oldName) {
              if (tab == PeerTabIndex.ab) {
                final ok = await gFFI.abModel.changeAlias(
                  id: id,
                  alias: newName,
                );
                if (ok) {
                  await bind.mainSetPeerAlias(id: id, alias: newName);
                  showToast(translate('Successful'));
                  _update();
                  return true;
                } else {
                  showToast(translate('Failed'));
                  return false;
                }
              } else {
                await bind.mainSetPeerAlias(id: id, alias: newName);
                showToast(translate('Successful'));
                _update();
                return true;
              }
            }
            return true;
          },
        );
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _removeAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(translate('Delete'), style: style?.copyWith(color: Colors.red)),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Transform.scale(
                scale: 0.8,
                child: Icon(Icons.delete_forever, color: Colors.red),
              ),
            ).marginOnly(right: 4),
          ),
        ],
      ),
      proc: () {
        onSubmit() async {
          switch (tab) {
            case PeerTabIndex.recent:
              await bind.mainRemovePeer(id: id);
              bind.mainLoadRecentPeers();
              break;
            case PeerTabIndex.fav:
              final favs = (await bind.mainGetFav()).toList();
              if (favs.remove(id)) {
                await bind.mainStoreFav(favs: favs);
                bind.mainLoadFavPeers();
              }
              break;
            case PeerTabIndex.lan:
              await bind.mainRemoveDiscovered(id: id);
              bind.mainLoadLanPeers();
              break;
            case PeerTabIndex.ab:
              await gFFI.abModel.deletePeers([id]);
              break;
            case PeerTabIndex.group:
              break;
          }
          if (tab != PeerTabIndex.ab) {
            showToast(translate('Successful'));
          }
        }

        deleteConfirmDialog(
          onSubmit,
          '${translate('Delete')} "${peer.alias.isEmpty ? formatID(peer.id) : peer.alias}"?',
        );
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _unrememberPasswordAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate('Forget Password'), style: style),
      proc: () async {
        bool succ = await gFFI.abModel.changePersonalHashPassword(id, '');
        await bind.mainForgetPassword(id: id);
        if (succ) {
          showToast(translate('Successful'));
        } else {
          if (tab.index == PeerTabIndex.ab.index) {
            BotToast.showText(
              contentColor: Colors.red,
              text: translate("Failed"),
            );
          }
        }
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _addFavAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(translate('Add to Favorites'), style: style),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Transform.scale(
                scale: 0.8,
                child: Icon(Icons.star_outline),
              ),
            ).marginOnly(right: 4),
          ),
        ],
      ),
      proc: () {
        () async {
          final favs = (await bind.mainGetFav()).toList();
          if (!favs.contains(id)) {
            favs.add(id);
            await bind.mainStoreFav(favs: favs);
          }
          showToast(translate('Successful'));
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _rmFavAction(
    String id,
    Future<void> Function() reloadFunc,
  ) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(translate('Remove from Favorites'), style: style),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Transform.scale(scale: 0.8, child: Icon(Icons.star)),
            ).marginOnly(right: 4),
          ),
        ],
      ),
      proc: () {
        () async {
          final favs = (await bind.mainGetFav()).toList();
          if (favs.remove(id)) {
            await bind.mainStoreFav(favs: favs);
            await reloadFunc();
          }
          showToast(translate('Successful'));
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _addToAb(Peer peer) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate('Add to address book'), style: style),
      proc: () {
        () async {
          addPeersToAbDialog([Peer.copy(peer)]);
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  Future<String> _getAlias(String id) async =>
      await bind.mainGetPeerOption(id: id, key: 'alias');

  @protected
  void _update();
}

class RecentPeerCard extends BasePeerCard {
  const RecentPeerCard({required super.peer, super.menuPadding, super.key})
    : super(
        tab: PeerTabIndex.recent,
      );

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
    BuildContext context,
  ) async {
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      _transferFileAction(context),
      _viewCameraAction(context),
      _terminalAction(context),
    ];

    if (peer.platform == kPeerPlatformWindows) {
      menuItems.add(_terminalRunAsAdminAction(context));
    }

    final List favs = (await bind.mainGetFav()).toList();

    if (isDesktop && peer.platform != kPeerPlatformAndroid) {
      menuItems.add(_tcpTunnelingAction(context));
    }
    // menuItems.add(await _openNewConnInOptAction(peer.id));
    if (!isWeb) {
      menuItems.add(await _forceAlwaysRelayAction(peer.id));
    }
    if (isWindows && peer.platform == kPeerPlatformWindows) {
      menuItems.add(_rdpAction(context, peer.id));
    }
    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    menuItems.add(MenuEntryDivider());
    if (isMobile || isDesktop || isWebDesktop) {
      menuItems.add(_renameAction(peer.id));
    }
    if (await bind.mainPeerHasPassword(id: peer.id)) {
      menuItems.add(_unrememberPasswordAction(peer.id));
    }

    if (!favs.contains(peer.id)) {
      menuItems.add(_addFavAction(peer.id));
    } else {
      menuItems.add(_rmFavAction(peer.id, () async {}));
    }

    if (gFFI.userModel.userName.isNotEmpty) {
      menuItems.add(_addToAb(peer));
    }

    menuItems.add(MenuEntryDivider());
    menuItems.add(_removeAction(peer.id));
    return menuItems;
  }

  @protected
  @override
  void _update() => bind.mainLoadRecentPeers();
}

class FavoritePeerCard extends BasePeerCard {
  const FavoritePeerCard({required super.peer, super.menuPadding, super.key})
    : super(
        tab: PeerTabIndex.fav,
      );

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
    BuildContext context,
  ) async {
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      _transferFileAction(context),
      _viewCameraAction(context),
      _terminalAction(context),
    ];

    if (peer.platform == kPeerPlatformWindows) {
      menuItems.add(_terminalRunAsAdminAction(context));
    }

    if (isDesktop && peer.platform != kPeerPlatformAndroid) {
      menuItems.add(_tcpTunnelingAction(context));
    }
    // menuItems.add(await _openNewConnInOptAction(peer.id));
    if (!isWeb) {
      menuItems.add(await _forceAlwaysRelayAction(peer.id));
    }
    if (isWindows && peer.platform == kPeerPlatformWindows) {
      menuItems.add(_rdpAction(context, peer.id));
    }
    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    menuItems.add(MenuEntryDivider());
    if (isMobile || isDesktop || isWebDesktop) {
      menuItems.add(_renameAction(peer.id));
    }
    if (await bind.mainPeerHasPassword(id: peer.id)) {
      menuItems.add(_unrememberPasswordAction(peer.id));
    }
    menuItems.add(
      _rmFavAction(peer.id, () async {
        await bind.mainLoadFavPeers();
      }),
    );

    if (gFFI.userModel.userName.isNotEmpty) {
      menuItems.add(_addToAb(peer));
    }

    menuItems.add(MenuEntryDivider());
    menuItems.add(_removeAction(peer.id));
    return menuItems;
  }

  @protected
  @override
  void _update() => bind.mainLoadFavPeers();
}

class DiscoveredPeerCard extends BasePeerCard {
  const DiscoveredPeerCard({required super.peer, super.menuPadding, super.key})
    : super(
        tab: PeerTabIndex.lan,
      );

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
    BuildContext context,
  ) async {
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      _transferFileAction(context),
      _viewCameraAction(context),
      _terminalAction(context),
    ];

    if (peer.platform == kPeerPlatformWindows) {
      menuItems.add(_terminalRunAsAdminAction(context));
    }

    final List favs = (await bind.mainGetFav()).toList();

    if (isDesktop && peer.platform != kPeerPlatformAndroid) {
      menuItems.add(_tcpTunnelingAction(context));
    }
    // menuItems.add(await _openNewConnInOptAction(peer.id));
    if (!isWeb) {
      menuItems.add(await _forceAlwaysRelayAction(peer.id));
    }
    if (isWindows && peer.platform == kPeerPlatformWindows) {
      menuItems.add(_rdpAction(context, peer.id));
    }
    menuItems.add(_wolAction(peer.id));
    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }

    if (!favs.contains(peer.id)) {
      menuItems.add(_addFavAction(peer.id));
    } else {
      menuItems.add(_rmFavAction(peer.id, () async {}));
    }

    if (gFFI.userModel.userName.isNotEmpty) {
      menuItems.add(_addToAb(peer));
    }

    menuItems.add(MenuEntryDivider());
    menuItems.add(_removeAction(peer.id));
    return menuItems;
  }

  @protected
  @override
  void _update() => bind.mainLoadLanPeers();
}

class AddressBookPeerCard extends BasePeerCard {
  const AddressBookPeerCard({required super.peer, super.menuPadding, super.key})
    : super(
        tab: PeerTabIndex.ab,
      );

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
    BuildContext context,
  ) async {
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      _transferFileAction(context),
      _viewCameraAction(context),
      _terminalAction(context),
    ];

    if (peer.platform == kPeerPlatformWindows) {
      menuItems.add(_terminalRunAsAdminAction(context));
    }

    if (isDesktop && peer.platform != kPeerPlatformAndroid) {
      menuItems.add(_tcpTunnelingAction(context));
    }
    // menuItems.add(await _openNewConnInOptAction(peer.id));
    if (!isWeb) {
      menuItems.add(await _forceAlwaysRelayAction(peer.id));
    }
    if (isWindows && peer.platform == kPeerPlatformWindows) {
      menuItems.add(_rdpAction(context, peer.id));
    }
    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    if (gFFI.abModel.current.canWrite()) {
      menuItems.add(MenuEntryDivider());
      if (isMobile || isDesktop || isWebDesktop) {
        menuItems.add(_renameAction(peer.id));
      }
      if (gFFI.abModel.current.isPersonal() && peer.hash.isNotEmpty) {
        menuItems.add(_unrememberPasswordAction(peer.id));
      }
      if (!gFFI.abModel.current.isPersonal()) {
        menuItems.add(_changeSharedAbPassword());
      }
      if (gFFI.abModel.currentAbTags.isNotEmpty) {
        menuItems.add(_editTagAction(peer.id));
      }
      menuItems.add(_editNoteAction(peer.id));
    }
    final addressbooks = gFFI.abModel.addressBooksCanWrite();
    if (gFFI.peerTabModel.currentTab == PeerTabIndex.ab.index) {
      addressbooks.remove(gFFI.abModel.currentName.value);
    }
    if (addressbooks.isNotEmpty) {
      menuItems.add(_addToAb(peer));
    }
    menuItems.add(_existIn());
    if (gFFI.abModel.current.canWrite()) {
      menuItems.add(MenuEntryDivider());
      menuItems.add(_removeAction(peer.id));
    }
    return menuItems;
  }

  // address book does not need to update
  @protected
  @override
  void _update() => {}; //gFFI.abModel.pullAb(force: ForcePullAb.current, quiet: true);

  @protected
  MenuEntryBase<String> _editTagAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate('Edit Tag'), style: style),
      proc: () {
        editAbTagDialog(gFFI.abModel.getPeerTags(id), (selectedTag) async {
          final ok = await gFFI.abModel.changeTagForPeers([id], selectedTag);
          if (ok) {
            showToast(translate('Successful'));
            return true;
          } else {
            showToast(translate('Failed'));
            return false;
          }
        });
      },
      padding: super.menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _editNoteAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate('Edit note'), style: style),
      proc: () {
        editAbPeerNoteDialog(id);
      },
      padding: super.menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  @override
  Future<String> _getAlias(String id) async =>
      gFFI.abModel.find(id)?.alias ?? '';

  MenuEntryBase<String> _changeSharedAbPassword() {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate(
          peer.password.isEmpty ? 'Set shared password' : 'Change Password',
        ),
        style: style,
      ),
      proc: () {
        setSharedAbPasswordDialog(gFFI.abModel.currentName.value, peer);
      },
      padding: super.menuPadding,
      dismissOnClicked: true,
    );
  }

  MenuEntryBase<String> _existIn() {
    final names = gFFI.abModel.idExistIn(peer.id);
    final text = names.join(', ');
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate('Exist in'), style: style),
      proc: () {
        gFFI.dialogManager.show((setState, close, context) {
          return CustomAlertDialog(
            title: Text(translate('Exist in')),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(text)],
            ),
            actions: [
              dialogButton(
                "OK",
                icon: Icon(Icons.done_rounded),
                onPressed: close,
              ),
            ],
            onSubmit: close,
            onCancel: close,
          );
        });
      },
      padding: super.menuPadding,
      dismissOnClicked: true,
    );
  }
}

class MyGroupPeerCard extends BasePeerCard {
  const MyGroupPeerCard({required super.peer, super.menuPadding, super.key})
    : super(
        tab: PeerTabIndex.group,
      );

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
    BuildContext context,
  ) async {
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      _transferFileAction(context),
      _viewCameraAction(context),
      _terminalAction(context),
    ];

    if (peer.platform == kPeerPlatformWindows) {
      menuItems.add(_terminalRunAsAdminAction(context));
    }

    if (isDesktop && peer.platform != kPeerPlatformAndroid) {
      menuItems.add(_tcpTunnelingAction(context));
    }
    // menuItems.add(await _openNewConnInOptAction(peer.id));
    if (!isWeb) {
      menuItems.add(await _forceAlwaysRelayAction(peer.id));
    }
    if (isWindows && peer.platform == kPeerPlatformWindows) {
      menuItems.add(_rdpAction(context, peer.id));
    }
    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    // menuItems.add(MenuEntryDivider());
    // menuItems.add(_renameAction(peer.id));
    // if (await bind.mainPeerHasPassword(id: peer.id)) {
    //   menuItems.add(_unrememberPasswordAction(peer.id));
    // }
    if (gFFI.userModel.userName.isNotEmpty) {
      menuItems.add(_addToAb(peer));
    }
    return menuItems;
  }

  @protected
  @override
  void _update() => gFFI.groupModel.pull();
}

void _rdpDialog(String id) async {
  final maxLength = bind.mainMaxEncryptLen();
  final port = await bind.mainGetPeerOption(id: id, key: 'rdp_port');
  final username = await bind.mainGetPeerOption(id: id, key: 'rdp_username');
  final hasStoredPassword =
      (await bind.mainGetPeerOption(id: id, key: 'has_rdp_password')) == 'true';
  final portController = TextEditingController(text: port);
  final userController = TextEditingController(text: username);
  final passwordController = TextEditingController();
  final RxBool clearPassword = false.obs;

  gFFI.dialogManager.show((setState, close, context) {
    void cleanup() {
      passwordController.clear();
      passwordController.dispose();
      portController.dispose();
      userController.dispose();
    }

    void handleClose() {
      cleanup();
      close();
    }

    submit() async {
      String port = portController.text.trim();
      String username = userController.text;
      String password = passwordController.text;
      await bind.mainSetPeerOption(id: id, key: 'rdp_port', value: port);
      await bind.mainSetPeerOption(
        id: id,
        key: 'rdp_username',
        value: username,
      );
      if (hasStoredPassword) {
        if (clearPassword.value) {
          await bind.mainSetPeerOption(id: id, key: 'rdp_password', value: '');
        } else if (password.isNotEmpty) {
          await bind.mainSetPeerOption(
            id: id,
            key: 'rdp_password',
            value: password,
          );
        }
      } else {
        if (password.isNotEmpty) {
          await bind.mainSetPeerOption(
            id: id,
            key: 'rdp_password',
            value: password,
          );
        }
      }
      showToast(translate('Successful'));
      handleClose();
    }

    return CustomAlertDialog(
      title: Text(translate('RDP Settings')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                isDesktop
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 140),
                        child: Text(
                          "${translate('Port')}:",
                          textAlign: TextAlign.right,
                        ).marginOnly(right: 10),
                      )
                    : SizedBox.shrink(),
                Expanded(
                  child: TextField(
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(
                          r'^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$',
                        ),
                      ),
                    ],
                    decoration: InputDecoration(
                      labelText: isDesktop ? null : translate('Port'),
                      hintText: '3389',
                    ),
                    controller: portController,
                    autofocus: true,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ).marginOnly(bottom: isDesktop ? 8 : 0),
            Obx(
              () => Row(
                children: [
                  stateGlobal.isPortrait.isFalse
                      ? ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 140),
                          child: Text(
                            "${translate('Username')}:",
                            textAlign: TextAlign.right,
                          ).marginOnly(right: 10),
                        )
                      : SizedBox.shrink(),
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        labelText: isDesktop ? null : translate('Username'),
                      ),
                      controller: userController,
                    ).workaroundFreezeLinuxMint(),
                  ),
                ],
              ).marginOnly(bottom: stateGlobal.isPortrait.isFalse ? 8 : 0),
            ),
            Obx(
              () => Row(
                children: [
                  stateGlobal.isPortrait.isFalse
                      ? ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 140),
                          child: Text(
                            "${translate('Password')}:",
                            textAlign: TextAlign.right,
                          ).marginOnly(right: 10),
                        )
                      : SizedBox.shrink(),
                  Expanded(
                    child: Obx(
                      () => TextField(
                        obscureText: true,
                        maxLength: maxLength,
                        enabled: !clearPassword.value,
                        decoration: InputDecoration(
                          labelText: isDesktop ? null : translate('Password'),
                          hintText: hasStoredPassword
                              ? (clearPassword.value
                                    ? translate('Password cleared')
                                    : '●●●●●● (${translate("Saved")})')
                              : null,
                          suffixIcon: hasStoredPassword
                              ? IconButton(
                                  tooltip: clearPassword.value
                                      ? translate('Undo')
                                      : translate('Clear'),
                                  onPressed: () {
                                    clearPassword.value = !clearPassword.value;
                                    if (clearPassword.value) {
                                      passwordController.clear();
                                    }
                                  },
                                  icon: Icon(
                                    clearPassword.value
                                        ? Icons.undo
                                        : Icons.clear,
                                  ),
                                )
                              : null,
                        ),
                        controller: passwordController,
                      ).workaroundFreezeLinuxMint(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        dialogButton("Cancel", onPressed: handleClose, isOutline: true),
        dialogButton("OK", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: handleClose,
    );
  });
}

Widget getOnline(double rightPadding, bool online) {
  return Tooltip(
    message: translate(online ? 'Online' : 'Offline'),
    waitDuration: const Duration(seconds: 1),
    child: Padding(
      padding: EdgeInsets.fromLTRB(0, 4, rightPadding, 4),
      child: Builder(
        builder: (context) {
          final isLight = AppVisual.isLight(context);
          final color = AppVisual.tone(
            context,
            online ? AppTone.success : AppTone.warning,
          );
          return Container(
            width: 12,
            height: 12,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: online
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: isLight ? 0.35 : 0.45),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: CircleAvatar(
              radius: 4,
              backgroundColor: color,
            ),
          );
        },
      ),
    ),
  );
}

Widget build_more(BuildContext context, {bool invert = false}) {
  return _BuildMoreButton(invert: invert);
}

class _BuildMoreButton extends StatefulWidget {
  final bool invert;
  const _BuildMoreButton({this.invert = false});

  @override
  State<_BuildMoreButton> createState() => _BuildMoreButtonState();
}

class _BuildMoreButtonState extends State<_BuildMoreButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isHovered = _hovered;
    final invert = widget.invert;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: CircleAvatar(
        radius: 14,
        backgroundColor: isHovered
            ? (invert
                  ? theme.colorScheme.surface
                  : theme.scaffoldBackgroundColor)
            : (invert
                  ? theme.scaffoldBackgroundColor
                  : theme.colorScheme.surface),
        child: Icon(
          Icons.more_vert,
          size: 18,
          color: isHovered
              ? theme.textTheme.titleLarge?.color
              : theme.textTheme.titleLarge?.color?.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class TagPainter extends CustomPainter {
  final double radius;
  late final List<Color> colors;

  TagPainter({required this.radius, required List<Color> colors}) {
    this.colors = colors.reversed.toList();
  }

  @override
  void paint(Canvas canvas, Size size) {
    double x = 0;
    double y = radius;
    for (int i = 0; i < colors.length; i++) {
      Paint paint = Paint();
      paint.color = colors[i];
      x -= radius + 1;
      if (i == colors.length - 1) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      } else {
        Path path = Path();
        path.addArc(
          Rect.fromCircle(center: Offset(x, y), radius: radius),
          math.pi * 4 / 3,
          math.pi * 4 / 3,
        );
        path.addArc(
          Rect.fromCircle(center: Offset(x - radius, y), radius: radius),
          math.pi * 5 / 3,
          math.pi * 2 / 3,
        );
        path.fillType = PathFillType.evenOdd;
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

void connectInPeerTab(
  BuildContext context,
  Peer peer,
  PeerTabIndex tab, {
  bool isFileTransfer = false,
  bool isViewCamera = false,
  bool isTcpTunneling = false,
  bool isRDP = false,
  bool isTerminal = false,
  bool isTerminalRunAsAdmin = false,
}) async {
  var password = '';
  bool isSharedPassword = false;
  if (tab == PeerTabIndex.ab) {
    // If recent peer's alias is empty, set it to ab's alias
    // Because the platform is not set, it may not take effect, but it is more important not to display if the connection is not successful
    if (peer.alias.isNotEmpty &&
        (await bind.mainGetPeerOption(id: peer.id, key: "alias")).isEmpty) {
      await bind.mainSetPeerAlias(id: peer.id, alias: peer.alias);
    }
    if (!gFFI.abModel.current.isPersonal()) {
      if (peer.password.isNotEmpty) {
        password = peer.password;
        isSharedPassword = true;
      }
      if (password.isEmpty) {
        final abPassword = await gFFI.abModel.getDefaultSharedPassword(peer.id);
        if (abPassword != null) {
          password = abPassword;
          isSharedPassword = true;
        }
      }
    }
  }
  connect(
    context,
    peer.id,
    password: password,
    isSharedPassword: isSharedPassword,
    isFileTransfer: isFileTransfer,
    isTerminal: isTerminal,
    isViewCamera: isViewCamera,
    isTcpTunneling: isTcpTunneling,
    isRDP: isRDP,
    isTerminalRunAsAdmin: isTerminalRunAsAdmin,
  );
}
