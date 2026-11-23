import 'dart:math' as math;

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/peer_tab_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../desktop/widgets/popup_menu.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';

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
    CamelliaColors.leaf,
  ];
  final index = id.hashCode.abs() % tints.length;
  return tints[index].withValues(alpha: isLight ? 0.06 : 0.12);
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

class _PeerCardState extends State<_PeerCard>
    with AutomaticKeepAliveClientMixin {
  var _menuPos = RelativeRect.fill;
  bool _hovered = false;
  bool _focused = false;
  bool? _isFavorite;
  final double _cardRadius = CamelliaRadius.surface;
  final double _tileRadius = CamelliaRadius.control;

  Future<void> _ensureFavoriteLoaded() async {
    if (_isFavorite != null) return;
    if (widget.tab == PeerTabIndex.fav) {
      if (mounted) setState(() => _isFavorite = true);
      return;
    }
    try {
      final favs = await bind.mainGetFav();
      if (mounted) {
        setState(() => _isFavorite = favs.contains(widget.peer.id));
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    try {
      final favs = (await bind.mainGetFav()).toList();
      final currentlyFav = favs.contains(widget.peer.id);
      if (currentlyFav) {
        favs.remove(widget.peer.id);
      } else {
        favs.add(widget.peer.id);
      }
      await bind.mainStoreFav(favs: favs);
      if (widget.tab == PeerTabIndex.fav) {
        await bind.mainLoadFavPeers();
      }
      if (mounted) {
        setState(() => _isFavorite = !currentlyFav);
      }
      HapticFeedback.selectionClick();
      showToast(translate('Successful'));
    } catch (_) {}
  }

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
    return GlassCard(
      layer: CamelliaGlassLayer.floating,
      enableBlur: false,
      borderRadius: BorderRadius.circular(_tileRadius),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: EdgeInsets.zero,
      child: gestureDetector(
        child: Padding(
          padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
          child: _buildPeerTile(context, peer, false),
        ),
      ),
    );
  }

  Widget _buildLandscape() {
    final peer = super.widget.peer;
    final glass = CamelliaGlassTokens.of(context);
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    return FocusableActionDetector(
      onShowHoverHighlight: (hovered) {
        if (_hovered != hovered && mounted) {
          setState(() => _hovered = hovered);
          if (hovered) _ensureFavoriteLoaded();
        }
      },
      onShowFocusHighlight: (focused) {
        if (_focused != focused && mounted) {
          setState(() => _focused = focused);
        }
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.connect(context, peer.id);
            return null;
          },
        ),
      },
      child: AnimatedContainer(
        duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
        curve: CamelliaMotion.springSnappy,
        transform: Matrix4.translationValues(
          0,
          (_hovered && !reduceMotion) ? -2.0 : 0.0,
          0,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(
            peerCardUiType.value == PeerUiType.grid ? _cardRadius : _tileRadius,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: glass.focusGlow.withValues(alpha: 0.30),
                    blurRadius: 8,
                    spreadRadius: 0.5,
                  ),
                ]
              : const [],
        ),
        child: gestureDetector(
          child: Obx(
            () => peerCardUiType.value == PeerUiType.grid
                ? _buildPeerCard(context, peer, _hovered)
                : _buildPeerTile(context, peer, _hovered),
          ),
        ),
      ),
    );
  }

  bool _showNote(Peer peer) {
    return peerTabShowNote(widget.tab) && peer.note.isNotEmpty;
  }

  Widget _buildQuickActionOverlay(
    BuildContext context,
    Peer peer,
    bool visible, {
    bool inline = false,
  }) {
    final PeerTabModel peerTabModel = Provider.of(context);
    if (peerTabModel.multiSelectionMode) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dark ? theme.colorScheme.secondary : theme.colorScheme.primary;
    final favActive = _isFavorite == true || widget.tab == PeerTabIndex.fav;

    final buttons = <Widget>[
      _QuickCardActionIcon(
        icon: Icons.play_arrow_rounded,
        tooltip: translate('Connect'),
        accentColor: accent,
        emphasized: true,
        onTap: () => widget.connect(context, peer.id),
      ),
      _QuickCardActionIcon(
        icon: Icons.folder_copy_outlined,
        tooltip: translate('Transfer file'),
        onTap: () =>
            connectInPeerTab(context, peer, widget.tab, isFileTransfer: true),
      ),
      _QuickCardActionIcon(
        icon: Icons.terminal_rounded,
        tooltip: translate('Terminal'),
        onTap: () =>
            connectInPeerTab(context, peer, widget.tab, isTerminal: true),
      ),
      _QuickCardActionIcon(
        icon: favActive ? Icons.star_rounded : Icons.star_outline_rounded,
        tooltip: favActive
            ? translate('Remove from Favorites')
            : translate('Add to Favorites'),
        accentColor: favActive ? glass.statusHighLatency : null,
        onTap: _toggleFavorite,
      ),
      if (!inline)
        Listener(
          onPointerDown: (e) {
            final x = e.position.dx;
            final y = e.position.dy;
            _menuPos = RelativeRect.fromLTRB(x, y, x, y);
          },
          child: _QuickCardActionIcon(
            icon: CamelliaIcons.more,
            tooltip: translate('More'),
            onTap: () => _showPeerMenu(peer.id),
          ),
        ),
    ];

    final pill = GlassSurface(
      layer: CamelliaGlassLayer.modal,
      borderRadius: BorderRadius.circular(CamelliaRadius.pill),
      enableBlur: false,
      showShadow: !inline,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
    );

    if (inline) {
      return IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
          curve: CamelliaMotion.springSnappy,
          child: pill,
        ),
      );
    }

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
        curve: CamelliaMotion.springSnappy,
        child: AnimatedScale(
          scale: visible ? 1.0 : 0.92,
          duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
          curve: CamelliaMotion.springSnappy,
          child: pill,
        ),
      ),
    );
  }

  Widget makeChild(bool isPortrait, Peer peer, bool isHovered) {
    final name = hideUsernameOnCard == true
        ? peer.hostname
        : '${peer.username}${peer.username.isNotEmpty && peer.hostname.isNotEmpty ? '@' : ''}${peer.hostname}';
    final theme = Theme.of(context);
    final mutedStyle = theme.textTheme.bodySmall;
    final idStyle = CamelliaTypography.tabular(theme.textTheme.titleSmall);
    final showNote = _showNote(peer);

    final platformBadge = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        CamelliaIcons.platformBadge(
          peer.platform,
          size: isPortrait ? 40 : 38,
          showBackground: true,
        ),
        if (_shouldBuildPasswordIcon(peer))
          Positioned(
            top: -2,
            left: -2,
            child: Icon(
              Icons.key_rounded,
              size: 11,
              color: theme.brightness == Brightness.dark
                  ? theme.colorScheme.secondary
                  : theme.colorScheme.primary,
            ),
          ),
      ],
    );

    if (!isPortrait && peerCardUiType.value == PeerUiType.list) {
      return SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              platformBadge,
              const SizedBox(width: 12),
              SizedBox(
                width: 190,
                child: Row(
                  children: [
                    getOnline(8, peer.online),
                    Expanded(
                      child: Text(
                        peer.alias.isEmpty ? formatID(peer.id) : peer.alias,
                        overflow: TextOverflow.ellipsis,
                        style: idStyle,
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
                    style: mutedStyle,
                    textAlign: TextAlign.start,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (showNote && !isHovered)
                SizedBox(
                  width: 150,
                  child: Tooltip(
                    message: peer.note,
                    waitDuration: const Duration(seconds: 1),
                    child: Text(
                      peer.note,
                      style: mutedStyle,
                      textAlign: TextAlign.start,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (isHovered) ...[
                _buildQuickActionOverlay(context, peer, true, inline: true),
                const SizedBox(width: 6),
              ],
              checkBoxOrActionMoreLandscape(peer, isTile: true),
            ],
          ),
        ),
      );
    }

    return Padding(
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
                        style: idStyle,
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
                            style: mutedStyle,
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
                              style: mutedStyle,
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

  Widget _buildPeerTile(BuildContext context, Peer peer, bool isHovered) {
    hideUsernameOnCard ??=
        bind.mainGetBuildinOption(key: kHideUsernameOnCard) == 'Y';
    final colors = _frontN(
      peer.tags,
      25,
    ).map((e) => gFFI.abModel.getCurrentAbTagColor(e)).toList();

    final inner = makeChild(stateGlobal.isPortrait.isTrue, peer, isHovered);
    final child = stateGlobal.isPortrait.isTrue
        ? inner
        : GlassCard(
            layer: CamelliaGlassLayer.floating,
            enableBlur: false,
            elevated: isHovered,
            borderRadius: BorderRadius.circular(_tileRadius),
            padding: EdgeInsets.zero,
            child: inner,
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

  Widget _buildPeerCard(BuildContext context, Peer peer, bool isHovered) {
    hideUsernameOnCard ??=
        bind.mainGetBuildinOption(key: kHideUsernameOnCard) == 'Y';
    final name = hideUsernameOnCard == true
        ? peer.hostname
        : '${peer.username}${peer.username.isNotEmpty && peer.hostname.isNotEmpty ? '@' : ''}${peer.hostname}';
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final isLight = theme.brightness == Brightness.light;
    final accent = isLight
        ? theme.colorScheme.primary
        : theme.colorScheme.secondary;
    final tint = _getCohesiveCardTint(peer.id, isLight);
    final colors = _frontN(
      peer.tags,
      25,
    ).map((e) => gFFI.abModel.getCurrentAbTagColor(e)).toList();

    final cardBody = LayoutBuilder(
      builder: (context, constraints) {
        final hasBoundedHeight = constraints.hasBoundedHeight;
        final topSection = DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            border: Border(
              bottom: BorderSide(color: glass.specularBottom, width: 0.75),
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CamelliaIcons.platformBadge(
                      peer.platform,
                      size: 46,
                      showBackground: true,
                    ),
                    const SizedBox(height: 6),
                    Tooltip(
                      message: name,
                      waitDuration: const Duration(seconds: 1),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_showNote(peer)) ...[
                      const SizedBox(height: 2),
                      Tooltip(
                        message: peer.note,
                        waitDuration: const Duration(seconds: 1),
                        child: Text(
                          peer.note,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_shouldBuildPasswordIcon(peer))
                Positioned(
                  top: 8,
                  left: 10,
                  child: Icon(Icons.key_rounded, size: 14, color: accent),
                ),
              if (colors.isNotEmpty)
                Positioned(
                  top: 6,
                  right: 12,
                  child: CustomPaint(
                    painter: TagPainter(radius: 4, colors: colors),
                  ),
                ),
              // Spring-fade Hover Quick-Action Overlay Bar
              Positioned(
                bottom: 8,
                child: _buildQuickActionOverlay(context, peer, isHovered),
              ),
            ],
          ),
        );

        return GlassCard(
          layer: CamelliaGlassLayer.floating,
          enableBlur: false,
          elevated: isHovered,
          borderRadius: BorderRadius.circular(_cardRadius),
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              hasBoundedHeight
                  ? Expanded(child: topSection)
                  : SizedBox(height: 104, child: topSection),
              SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      getOnline(8, peer.online),
                      Expanded(
                        child: Text(
                          peer.alias.isEmpty ? formatID(peer.id) : peer.alias,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CamelliaTypography.tabular(
                            theme.textTheme.titleSmall,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      checkBoxOrActionMoreLandscape(peer, isTile: false),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    return Tooltip(
      message: peer.tags.isNotEmpty
          ? '${translate('Tags')}: ${peer.tags.join(', ')}'
          : '',
      child: cardBody,
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
            : const Icon(Icons.check_box_outline_blank),
      );
    } else {
      return InkWell(
        borderRadius: BorderRadius.circular(CamelliaRadius.pill),
        hoverColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        focusColor: Colors.transparent,
        onTapDown: (e) {
          final x = e.globalPosition.dx;
          final y = e.globalPosition.dy;
          _menuPos = RelativeRect.fromLTRB(x, y, x, y);
        },
        onTap: () {
          _showPeerMenu(peer.id);
        },
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.more_vert),
        ),
      );
    }
  }

  Widget checkBoxOrActionMoreLandscape(Peer peer, {required bool isTile}) {
    final PeerTabModel peerTabModel = Provider.of(context);
    final selected = peerTabModel.isPeerSelected(peer.id);
    if (peerTabModel.multiSelectionMode) {
      final icon = selected
          ? Icon(Icons.check_box, color: Theme.of(context).colorScheme.primary)
          : const Icon(Icons.check_box_outline_blank);
      final bool last =
          peerTabModel.isShiftDown && peer.id == peerTabModel.lastId;
      final double right = isTile ? 4 : 0;
      if (last) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
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

class _QuickCardActionIcon extends StatefulWidget {
  const _QuickCardActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.accentColor,
    this.emphasized = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? accentColor;
  final bool emphasized;

  @override
  State<_QuickCardActionIcon> createState() => _QuickCardActionIconState();
}

class _QuickCardActionIconState extends State<_QuickCardActionIcon> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    final bg = widget.emphasized
        ? theme.colorScheme.primary
        : (_hovered ? glass.hoverOverlay : Colors.transparent);
    final fg = widget.emphasized
        ? Colors.white
        : (widget.accentColor ?? theme.colorScheme.onSurface);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onTap();
          },
          child: AnimatedScale(
            scale: reduceMotion ? 1.0 : (_pressed ? 0.92 : 1.0),
            duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
            curve: CamelliaMotion.springSnappy,
            child: AnimatedContainer(
              duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
              width: 28,
              height: 28,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(CamelliaRadius.pill),
              ),
              child: Center(child: Icon(widget.icon, size: 15, color: fg)),
            ),
          ),
        ),
      ),
    );
  }
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
      peer.alias.isEmpty
          ? translate('Connect')
          : '${translate('Connect')} ${peer.id}',
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
      translate('Terminal'),
      isTerminal: true,
    );
  }

  @protected
  MenuEntryBase<String> _terminalRunAsAdminAction(BuildContext context) {
    return _connectCommonAction(
      context,
      translate('Terminal (Run as administrator)'),
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
                    icon: const Icon(CamelliaIcons.edit),
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

  @protected
  Future<bool> _isForceAlwaysRelay(String id) async {
    return option2bool(
      kOptionForceAlwaysRelay,
      await bind.mainGetPeerOption(id: id, key: kOptionForceAlwaysRelay),
    );
  }

  @protected
  Future<MenuEntryBase<String>> _forceAlwaysRelayAction(String id) async {
    return MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate('Always connect via relay'),
      getter: () async => await _isForceAlwaysRelay(id),
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
        final String oldName = await _getAlias(id);
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
      childBuilder: (TextStyle? style) => Builder(
        builder: (context) {
          final alert = CamelliaGlassTokens.of(context).statusAlert;
          return Row(
            children: [
              Text(translate('Delete'), style: style?.copyWith(color: alert)),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Transform.scale(
                    scale: 0.8,
                    child: Icon(CamelliaIcons.trash, color: alert),
                  ),
                ).marginOnly(right: 4),
              ),
            ],
          );
        },
      ),
      proc: () {
        Future<void> onSubmit() async {
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
        final bool succ = await gFFI.abModel.changePersonalHashPassword(id, '');
        await bind.mainForgetPassword(id: id);
        if (succ) {
          showToast(translate('Successful'));
        } else {
          if (tab.index == PeerTabIndex.ab.index) {
            final alertCtx = globalKey.currentContext;
            final alertColor = alertCtx != null
                ? CamelliaGlassTokens.of(alertCtx).statusAlert
                : CamelliaColors.statusAlertLight;
            BotToast.showText(
              contentColor: alertColor,
              text: translate('Failed'),
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
                child: const Icon(Icons.star_outline_rounded),
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
              child: Transform.scale(
                scale: 0.8,
                child: const Icon(Icons.star_rounded),
              ),
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
    : super(tab: PeerTabIndex.recent);

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
    : super(tab: PeerTabIndex.fav);

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
    : super(tab: PeerTabIndex.lan);

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
    : super(tab: PeerTabIndex.ab);

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

  @protected
  @override
  void _update() => {};

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
            title: ModernDialogHeader.info(
              title: translate('Exist in'),
              onClose: close,
            ),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(text)],
            ),
            actions: [
              GlassButton(
                variant: GlassButtonVariant.primary,
                icon: const Icon(CamelliaIcons.check, size: 17),
                onPressed: close,
                child: Text(translate('OK')),
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
    : super(tab: PeerTabIndex.group);

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
    if (!isWeb) {
      menuItems.add(await _forceAlwaysRelayAction(peer.id));
    }
    if (isWindows && peer.platform == kPeerPlatformWindows) {
      menuItems.add(_rdpAction(context, peer.id));
    }
    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
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
      clearPassword.close();
    }

    void handleClose() {
      cleanup();
      close();
    }

    Future<void> submit() async {
      final String portVal = portController.text.trim();
      final String usernameVal = userController.text;
      final String passwordVal = passwordController.text;
      await bind.mainSetPeerOption(id: id, key: 'rdp_port', value: portVal);
      await bind.mainSetPeerOption(
        id: id,
        key: 'rdp_username',
        value: usernameVal,
      );
      if (hasStoredPassword) {
        if (clearPassword.value) {
          await bind.mainSetPeerOption(id: id, key: 'rdp_password', value: '');
        } else if (passwordVal.isNotEmpty) {
          await bind.mainSetPeerOption(
            id: id,
            key: 'rdp_password',
            value: passwordVal,
          );
        }
      } else {
        if (passwordVal.isNotEmpty) {
          await bind.mainSetPeerOption(
            id: id,
            key: 'rdp_password',
            value: passwordVal,
          );
        }
      }
      showToast(translate('Successful'));
      handleClose();
    }

    final limitFormatters = maxLength > 0
        ? <TextInputFormatter>[LengthLimitingTextInputFormatter(maxLength)]
        : const <TextInputFormatter>[];

    return CustomAlertDialog(
      title: ModernDialogHeader(
        icon: Icons.desktop_windows_rounded,
        title: translate('RDP Settings'),
        subtitle: formatID(id),
        onClose: handleClose,
      ),
      contentBoxConstraints: const BoxConstraints(maxWidth: 460),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassInput(
              controller: portController,
              autofocus: true,
              tabularNums: true,
              labelText: translate('Port'),
              hintText: '3389',
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                  RegExp(
                    r'^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$',
                  ),
                ),
              ],
            ).workaroundFreezeLinuxMint(),
            const SizedBox(height: 12),
            GlassInput(
              controller: userController,
              labelText: translate('Username'),
              hintText: translate('Username'),
            ).workaroundFreezeLinuxMint(),
            const SizedBox(height: 12),
            Obx(
              () => GlassInput(
                controller: passwordController,
                obscureText: true,
                enabled: !clearPassword.value,
                showClearButton: false,
                labelText: translate('Password'),
                hintText: hasStoredPassword
                    ? (clearPassword.value
                          ? translate('Password cleared')
                          : '●●●●●● (${translate('Saved')})')
                    : translate('Password'),
                inputFormatters: limitFormatters,
                trailing: hasStoredPassword
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
                              ? Icons.undo_rounded
                              : CamelliaIcons.close,
                          size: 18,
                        ),
                      )
                    : null,
              ).workaroundFreezeLinuxMint(),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          variant: GlassButtonVariant.secondary,
          onPressed: handleClose,
          child: Text(translate('Cancel')),
        ),
        GlassButton(
          variant: GlassButtonVariant.primary,
          onPressed: submit,
          child: Text(translate('OK')),
        ),
      ],
      onSubmit: submit,
      onCancel: handleClose,
    );
  });
}

/// Semantic online/offline indicator dot:
/// - Online: emerald (`glass.statusOnline`) with subtle glow
/// - Offline: calm neutral slate (`glass.statusOffline`) — NEVER amber warning
Widget getOnline(double rightPadding, bool online) {
  return Tooltip(
    message: translate(online ? 'Online' : 'Offline'),
    waitDuration: const Duration(seconds: 1),
    child: Padding(
      padding: EdgeInsets.fromLTRB(0, 4, rightPadding, 4),
      child: Builder(
        builder: (context) {
          final glass = CamelliaGlassTokens.of(context);
          final isLight = Theme.of(context).brightness == Brightness.light;
          final color = online ? glass.statusOnline : glass.statusOffline;
          return Container(
            width: 12,
            height: 12,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: online
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: isLight ? 0.35 : 0.48),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: CircleAvatar(radius: 4, backgroundColor: color),
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
    final glass = CamelliaGlassTokens.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _hovered
              ? glass.hoverOverlay
              : (widget.invert
                    ? glass.floatingTint.withValues(alpha: 0.72)
                    : Colors.transparent),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.more_vert,
          size: 18,
          color: _hovered
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class TagPainter extends CustomPainter {
  final double radius;
  late final List<Color> colors;

  TagPainter({required this.radius, required List<Color> colors}) {
    this.colors = colors.reversed.toList(growable: false);
  }

  @override
  void paint(Canvas canvas, Size size) {
    double x = 0;
    final double y = radius;
    for (int i = 0; i < colors.length; i++) {
      final Paint paint = Paint()..color = colors[i];
      x -= radius + 1;
      if (i == colors.length - 1) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      } else {
        final Path path = Path();
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
  bool shouldRepaint(covariant TagPainter oldDelegate) {
    if (oldDelegate.radius != radius ||
        oldDelegate.colors.length != colors.length) {
      return true;
    }
    for (var i = 0; i < colors.length; i++) {
      if (oldDelegate.colors[i] != colors[i]) return true;
    }
    return false;
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
    if (peer.alias.isNotEmpty &&
        (await bind.mainGetPeerOption(id: peer.id, key: 'alias')).isEmpty) {
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
  if (!context.mounted) return;
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
