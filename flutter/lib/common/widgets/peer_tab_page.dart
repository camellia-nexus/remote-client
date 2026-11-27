import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/address_book.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/my_group.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/widgets/material_mod_popup_menu.dart'
    as mod_menu;
import 'package:camellia_remote_app/desktop/widgets/popup_menu.dart';
import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/peer_tab_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/device_workspace_controls.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

class PeerTabPage extends StatefulWidget {
  const PeerTabPage({super.key});
  @override
  State<PeerTabPage> createState() => _PeerTabPageState();
}

class _TabEntry {
  final Widget widget;
  final Function({dynamic hint})? load;
  _TabEntry(this.widget, [this.load]);
}

EdgeInsets? _menuPadding() {
  return (isDesktop || isWebDesktop) ? kDesktopMenuPadding : null;
}

class _PeerTabPageState extends State<PeerTabPage>
    with SingleTickerProviderStateMixin {
  final List<_TabEntry> entries = [
    _TabEntry(
      RecentPeersView(menuPadding: _menuPadding()),
      ({dynamic hint}) => bind.mainLoadRecentPeers(),
    ),
    _TabEntry(
      FavoritePeersView(menuPadding: _menuPadding()),
      ({dynamic hint}) => bind.mainLoadFavPeers(),
    ),
    _TabEntry(DiscoveredPeersView(menuPadding: _menuPadding()), ({
      dynamic hint,
    }) {
      bind.mainLoadLanPeers();
      bind.mainDiscover();
    }),
    _TabEntry(
      AddressBook(menuPadding: _menuPadding()),
      ({dynamic hint}) => gFFI.abModel.pullAb(
        force: hint == null ? ForcePullAb.listAndCurrent : null,
        quiet: false,
      ),
    ),
    _TabEntry(
      MyGroup(menuPadding: _menuPadding()),
      ({dynamic hint}) => gFFI.groupModel.pull(force: hint == null),
    ),
  ];
  Offset? mobileTabContextMenuPos;
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'peer-search');
  bool _searchFocused = false;
  bool _compactSearchOpen = false;
  int? _loadedTab;
  int? _scheduledTab;

  final isOptVisiableFixed = isOptionFixed(kOptionPeerTabVisible);

  @override
  void initState() {
    super.initState();
    _loadLocalOptions();
    HardwareKeyboard.instance.addHandler(_handleGlobalFindShortcut);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalFindShortcut);
    _searchFocusNode.dispose();
    super.dispose();
  }

  bool _handleGlobalFindShortcut(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyF) return false;
    final modifierPressed =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!modifierPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return false;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (gFFI.dialogManager.activeDialogCount > 0) return false;

    _focusDeviceSearch();
    return true;
  }

  void _focusDeviceSearch() {
    if (!mounted) return;
    if (!_compactSearchOpen) {
      setState(() => _compactSearchOpen = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.requestFocus();
      final text = peerSearchTextController.text;
      if (text.isNotEmpty) {
        peerSearchTextController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: text.length,
        );
      }
    });
  }

  void _ensureTabLoaded(int tabIndex) {
    if (_loadedTab == tabIndex || _scheduledTab == tabIndex) return;
    _scheduledTab = tabIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scheduledTab = null;
      final currentTab = gFFI.peerTabModel.currentTab;
      if (currentTab != tabIndex) {
        _ensureTabLoaded(currentTab);
        return;
      }
      _loadedTab = tabIndex;
      _loadTab(tabIndex, hint: false);
    });
  }

  void _loadLocalOptions() {
    final uiType = bind.getLocalFlutterOption(k: kOptionPeerCardUiType);
    final parsedUiType = int.tryParse(uiType);
    if (parsedUiType != null) {
      peerCardUiType.value = parsedUiType == 0
          ? PeerUiType.grid
          : parsedUiType == 1
          ? PeerUiType.tile
          : PeerUiType.list;
    }
    hideAbTagsPanel.value =
        bind.mainGetLocalOption(key: kOptionHideAbTagsPanel) == 'Y';
  }

  void _loadTab(int tabIndex, {dynamic hint}) {
    if (tabIndex >= 0 && tabIndex < entries.length) {
      switch (PeerTabIndex.values[tabIndex]) {
        case PeerTabIndex.recent:
          gFFI.recentPeersModel.beginLoad();
          break;
        case PeerTabIndex.fav:
          gFFI.favoritePeersModel.beginLoad();
          break;
        case PeerTabIndex.lan:
          gFFI.lanPeersModel.beginLoad();
          break;
        case PeerTabIndex.ab:
        case PeerTabIndex.group:
          break;
      }
      entries[tabIndex].load?.call(hint: hint);
    }
  }

  Future<void> handleTabSelection(int tabIndex) async {
    if (tabIndex >= 0 && tabIndex < entries.length) {
      _loadedTab = tabIndex;
      if (tabIndex != gFFI.peerTabModel.currentTab) {
        gFFI.peerTabModel.setCurrentTabCachedPeers([]);
      }
      gFFI.peerTabModel.setCurrentTab(tabIndex);
      _loadTab(tabIndex, hint: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    _ensureTabLoaded(model.currentTab);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusDeviceSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _focusDeviceSearch,
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth = constraints.maxWidth;
          return Column(
            textBaseline: TextBaseline.ideographic,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              visibleContextMenuListener(_buildCategoryPillBar(context)),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: CamelliaMotion.resolve(context, CamelliaMotion.state),
                child: model.multiSelectionMode
                    ? ConstrainedBox(
                        key: const ValueKey('peer-multi-selection'),
                        constraints: const BoxConstraints(minHeight: 44),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: createMultiSelectionBar(model),
                        ),
                      )
                    : _buildActionBar(context, contentWidth),
              ),
              _createPeersView(),
            ],
          );
        },
      ),
    );
  }

  /// Unified horizontal labeled Glass Pill Tabs replacing the legacy 52px
  /// vertical category rail.
  Widget _buildCategoryPillBar(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    final tabs = model.visibleEnabledOrderedIndexs;
    if (tabs.isEmpty) return const SizedBox.shrink();
    final selected = tabs.contains(model.currentTab)
        ? model.currentTab
        : tabs.first;
    final fixed = isOptionFixed(kOptionPeerTabIndex);

    Future<void> select(int tab) async {
      await handleTabSelection(tab);
      await bind.setLocalFlutterOption(
        k: kOptionPeerTabIndex,
        v: tab.toString(),
      );
    }

    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _GlassCategoryPillTab(
                icon: model.tabIcon(tabs[i]),
                label: model.tabTooltip(tabs[i]),
                tooltip: model.tabTooltip(tabs[i]),
                selected: tabs[i] == selected,
                onTap: fixed ? null : () => select(tabs[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionBar(BuildContext context, double width) {
    final actions = _landscapeRightActions(context);
    if (width < 520 && !_compactSearchOpen && peerSearchText.value.isEmpty) {
      return SizedBox(
        height: 44,
        child: Row(
          children: [
            _hoverAction(
              context: context,
              child: const Icon(CamelliaIcons.search, size: 19),
              onTap: () => setState(() => _compactSearchOpen = true),
              toolTip: translate('Search ID'),
            ),
            const Spacer(),
            ...actions,
          ],
        ),
      );
    }
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          if (width < 520)
            IconButton(
              tooltip: translate('Back'),
              onPressed: () {
                FocusManager.instance.primaryFocus?.unfocus();
                peerSearchTextController.clear();
                peerSearchText.value = '';
                setState(() => _compactSearchOpen = false);
              },
              icon: const Icon(CamelliaIcons.arrowBack),
            ),
          AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
            curve: CamelliaMotion.enter,
            width: width < 520
                ? (width - 48).clamp(0, width).toDouble()
                : deviceSearchWidth(width, focused: _searchFocused),
            child: PeerSearchBar(
              focusNode: _searchFocusNode,
              onFocusChanged: (focused) {
                if (_searchFocused != focused && mounted) {
                  setState(() => _searchFocused = focused);
                }
              },
            ),
          ),
          if (width >= 520) ...[
            const SizedBox(width: 10),
            const Spacer(),
            ...actions,
          ],
        ],
      ),
    );
  }

  Widget _createPeersView() {
    final model = Provider.of<PeerTabModel>(context);
    Widget child;
    if (model.visibleEnabledOrderedIndexs.isEmpty) {
      child = visibleContextMenuListener(
        const Row(children: [Expanded(child: InkWell())]),
      );
    } else {
      if (model.visibleEnabledOrderedIndexs.contains(model.currentTab)) {
        child = entries[model.currentTab].widget;
      } else {
        debugPrint('should not happen! currentTab not in visibleIndexs');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && model.visibleEnabledOrderedIndexs.isNotEmpty) {
            model.setCurrentTab(model.visibleEnabledOrderedIndexs.first);
          }
        });
        child = entries[0].widget;
      }
    }
    return Expanded(
      child: Padding(
        padding: EdgeInsets.only(top: (isDesktop || isWebDesktop) ? 10.0 : 8.0),
        child: child,
      ),
    );
  }

  Widget _createRefresh() {
    final model = Provider.of<PeerTabModel>(context, listen: false);
    final iconColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final loading = switch (PeerTabIndex.values[model.currentTab]) {
      PeerTabIndex.ab => gFFI.abModel.currentAbLoading,
      PeerTabIndex.group => gFFI.groupModel.groupLoading,
      _ => null,
    };
    return Tooltip(
      message: translate('Refresh'),
      child: RefreshWidget(
        onPressed: () => _loadTab(model.currentTab),
        spinning: loading,
        child: Icon(CamelliaIcons.refresh, size: 19, color: iconColor),
      ),
    );
  }

  Widget _createPeerViewTypeSwitch(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: PeerViewDropdown(),
    );
  }

  Widget _createMultiSelection() {
    final model = Provider.of<PeerTabModel>(context);
    return _hoverAction(
      toolTip: translate('Select'),
      context: context,
      onTap: () {
        model.setMultiSelectionMode(true);
        if (isMobile && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      },
      child: const Icon(Icons.library_add_check_outlined, size: 19),
    );
  }

  Future<void> _showTabVisibilityMenu(Offset globalPos) async {
    final model = Provider.of<PeerTabModel>(context, listen: false);
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    final overlaySize = overlay?.size ?? MediaQuery.sizeOf(context);
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPos.dx, globalPos.dy, 0, 0),
      Offset.zero & overlaySize,
    );

    final menu = <MenuEntrySwitchSync<String>>[];
    for (int i = 0; i < model.orders.length; i++) {
      final int tabIndex = model.orders[i];
      if (tabIndex < 0 || tabIndex >= PeerTabModel.maxTabCount) continue;
      if (!model.isEnabled[tabIndex]) continue;
      menu.add(
        MenuEntrySwitchSync<String>(
          switchType: SwitchType.scheckbox,
          text: model.tabTooltip(tabIndex),
          currentValue: model.isVisibleEnabled[tabIndex],
          setter: (show) async {
            model.setTabVisible(tabIndex, show);
          },
          enabled: (!isOptVisiableFixed).obs,
        ),
      );
    }
    if (menu.isEmpty) return;

    final conf = MenuConfig(
      commonColor: Theme.of(context).colorScheme.primary,
      height: 36.0,
      dividerHeight: 8.0,
    );
    await mod_menu.showMenu<String>(
      context: context,
      position: position,
      items: menu.expand((entry) => entry.build(context, conf)).toList(),
    );
  }

  Widget visibleContextMenuListener(Widget child) {
    if (!(isDesktop || isWebDesktop)) {
      return GestureDetector(
        onLongPressDown: (e) {
          mobileTabContextMenuPos = e.globalPosition;
        },
        onLongPressUp: () {
          if (mobileTabContextMenuPos != null) {
            _showTabVisibilityMenu(mobileTabContextMenuPos!);
          }
        },
        child: child,
      );
    } else {
      return Listener(
        onPointerDown: (e) {
          if (e.kind != ui.PointerDeviceKind.mouse) {
            return;
          }
          if (e.buttons == 2) {
            _showTabVisibilityMenu(e.position);
          }
        },
        child: child,
      );
    }
  }

  Widget createMultiSelectionBar(PeerTabModel model) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Offstage(
          offstage: model.selectedPeers.isEmpty,
          child: Row(
            children: [
              deleteSelection(),
              addSelectionToFav(),
              addSelectionToAb(),
              editSelectionTags(),
            ],
          ),
        ),
        Row(
          children: [
            selectionCount(model.selectedPeers.length),
            selectAll(model),
            closeSelection(),
          ],
        ),
      ],
    );
  }

  Widget deleteSelection() {
    final model = Provider.of<PeerTabModel>(context);
    final glass = CamelliaGlassTokens.of(context);
    final currentTab = model.currentTab;
    if (currentTab == PeerTabIndex.group.index) {
      return const Offstage();
    }
    return _hoverAction(
      context: context,
      toolTip: translate('Delete'),
      onTap: () {
        final targetTab = model.selectionTab >= 0
            ? model.selectionTab
            : model.currentTab;
        if (targetTab == PeerTabIndex.group.index) return;
        final selectedSnapshot = List<Peer>.from(model.selectedPeers);
        if (selectedSnapshot.isEmpty) return;

        Future<bool> onSubmit() async {
          if (model.currentTab != targetTab) {
            gFFI.peerTabModel.setMultiSelectionMode(false);
            return false;
          }
          final peers = selectedSnapshot;
          switch (targetTab) {
            case 0:
              for (final p in peers) {
                await bind.mainRemovePeer(id: p.id);
              }
              bind.mainLoadRecentPeers();
              break;
            case 1:
              final favs = (await bind.mainGetFav()).toList();
              for (final p in peers) {
                favs.remove(p.id);
              }
              await bind.mainStoreFav(favs: favs);
              bind.mainLoadFavPeers();
              break;
            case 2:
              for (final p in peers) {
                await bind.mainRemoveDiscovered(id: p.id);
              }
              bind.mainLoadLanPeers();
              break;
            case 3:
              final ok = await gFFI.abModel.deletePeers(
                peers.map((p) => p.id).toList(),
              );
              if (ok) {
                gFFI.peerTabModel.setMultiSelectionMode(false);
                showToast(translate('Successful'));
              } else {
                showToast(translate('Failed'));
                return false;
              }
              break;
            default:
              break;
          }
          if (targetTab != 3) {
            gFFI.peerTabModel.setMultiSelectionMode(false);
            showToast(translate('Successful'));
          }
          return true;
        }

        deleteConfirmDialog(onSubmit, translate('Delete'));
      },
      child: Icon(CamelliaIcons.trash, size: 19, color: glass.statusAlert),
    );
  }

  Widget addSelectionToFav() {
    final model = Provider.of<PeerTabModel>(context);
    return Offstage(
      offstage: model.currentTab != PeerTabIndex.recent.index,
      child: _hoverAction(
        context: context,
        toolTip: translate('Add to Favorites'),
        onTap: () async {
          final peers = List<Peer>.from(model.selectedPeers);
          final favs = (await bind.mainGetFav()).toList();
          for (final p in peers) {
            if (!favs.contains(p.id)) {
              favs.add(p.id);
            }
          }
          await bind.mainStoreFav(favs: favs);
          model.setMultiSelectionMode(false);
          showToast(translate('Successful'));
        },
        child: Icon(PeerTabModel.icons[PeerTabIndex.fav.index], size: 19),
      ).marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget addSelectionToAb() {
    final model = Provider.of<PeerTabModel>(context);
    final addressbooks = gFFI.abModel.addressBooksCanWrite();
    if (model.currentTab == PeerTabIndex.ab.index) {
      addressbooks.remove(gFFI.abModel.currentName.value);
    }
    return Offstage(
      offstage: !gFFI.userModel.isLogin || addressbooks.isEmpty,
      child: _hoverAction(
        context: context,
        toolTip: translate('Add to address book'),
        onTap: () {
          final peers = model.selectedPeers.map((e) => Peer.copy(e)).toList();
          addPeersToAbDialog(peers);
          model.setMultiSelectionMode(false);
        },
        child: Icon(PeerTabModel.icons[PeerTabIndex.ab.index], size: 19),
      ).marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget editSelectionTags() {
    final model = Provider.of<PeerTabModel>(context);
    return Offstage(
      offstage:
          !gFFI.userModel.isLogin ||
          model.currentTab != PeerTabIndex.ab.index ||
          gFFI.abModel.currentAbTags.isEmpty,
      child: _hoverAction(
        context: context,
        toolTip: translate('Edit Tag'),
        onTap: () {
          editAbTagDialog(List.empty(), (selectedTags) async {
            final peers = List<Peer>.from(model.selectedPeers);
            final ok = await gFFI.abModel.changeTagForPeers(
              peers.map((p) => p.id).toList(),
              selectedTags,
            );
            if (ok) {
              model.setMultiSelectionMode(false);
              showToast(translate('Successful'));
              return true;
            } else {
              showToast(translate('Failed'));
              return false;
            }
          });
        },
        child: const Icon(Icons.tag_rounded, size: 19),
      ).marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget selectionCount(int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Align(
        alignment: Alignment.center,
        child: Text(
          '$count ${translate('Selected')}',
          style: CamelliaTypography.tabular(
            Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ),
    );
  }

  Widget selectAll(PeerTabModel model) {
    return Offstage(
      offstage:
          model.selectedPeers.length >= model.currentTabCachedPeers.length,
      child: _hoverAction(
        context: context,
        toolTip: translate('Select All'),
        onTap: () {
          model.selectAll();
        },
        child: const Icon(Icons.select_all_rounded, size: 19),
      ).marginOnly(left: 6),
    );
  }

  Widget closeSelection() {
    final model = Provider.of<PeerTabModel>(context);
    return _hoverAction(
      context: context,
      toolTip: translate('Close'),
      onTap: () {
        model.setMultiSelectionMode(false);
      },
      child: const Icon(CamelliaIcons.close, size: 19),
    ).marginOnly(left: 6);
  }

  Widget _toggleTags() {
    return _hoverAction(
      context: context,
      toolTip: translate('Toggle Tags'),
      hoverableWhenfalse: hideAbTagsPanel,
      child: const Icon(Icons.tag_rounded, size: 18),
      onTap: () async {
        await bind.mainSetLocalOption(
          key: kOptionHideAbTagsPanel,
          value: hideAbTagsPanel.value ? defaultOptionNo : 'Y',
        );
        hideAbTagsPanel.value = !hideAbTagsPanel.value;
      },
    );
  }

  List<Widget> _landscapeRightActions(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    return [
      _createRefresh(),
      if (model.currentTabCachedPeers.isNotEmpty) _createMultiSelection(),
      _createPeerViewTypeSwitch(context),
      if (model.currentTab != PeerTabIndex.recent.index)
        const PeerSortDropdown(),
      if (model.currentTab == PeerTabIndex.ab.index) _toggleTags(),
    ];
  }
}

class _GlassCategoryPillTab extends StatefulWidget {
  const _GlassCategoryPillTab({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_GlassCategoryPillTab> createState() => _GlassCategoryPillTabState();
}

class _GlassCategoryPillTabState extends State<_GlassCategoryPillTab> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final activeAccent = dark ? scheme.secondary : scheme.primary;
    final radius = BorderRadius.circular(CamelliaRadius.pill);
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    final bg = widget.selected
        ? activeAccent.withValues(alpha: dark ? 0.22 : 0.13)
        : (_hovered && _enabled
              ? Color.alphaBlend(glass.hoverOverlay, glass.floatingTint)
              : glass.floatingTint.withValues(alpha: dark ? 0.56 : 0.72));
    final fg = widget.selected
        ? (dark ? scheme.onSurface : activeAccent)
        : (_hovered ? scheme.onSurface : scheme.onSurfaceVariant);

    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: _enabled,
      label: widget.label,
      child: Tooltip(
        message: widget.tooltip,
        child: FocusableActionDetector(
          enabled: _enabled,
          mouseCursor: _enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onShowHoverHighlight: (v) {
            if (mounted) {
              setState(() {
                _hovered = v;
                if (!v) _pressed = false;
              });
            }
          },
          onShowFocusHighlight: (v) {
            if (mounted) setState(() => _focused = v);
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                if (_enabled) {
                  HapticFeedback.selectionClick();
                  widget.onTap?.call();
                }
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: _enabled
                ? () => setState(() => _pressed = false)
                : null,
            onTap: _enabled
                ? () {
                    HapticFeedback.selectionClick();
                    widget.onTap?.call();
                  }
                : null,
            child: AnimatedScale(
              scale: (!_enabled || reduceMotion)
                  ? 1.0
                  : (_pressed ? 0.97 : 1.0),
              duration: CamelliaMotion.resolve(
                context,
                CamelliaMotion.feedback,
              ),
              curve: CamelliaMotion.springSnappy,
              child: AnimatedContainer(
                duration: CamelliaMotion.resolve(context, CamelliaMotion.state),
                curve: CamelliaMotion.springSnappy,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: radius,
                  border: Border.all(
                    color: widget.selected
                        ? activeAccent.withValues(alpha: dark ? 0.42 : 0.28)
                        : AppVisual.tokens(context).border.withValues(
                            alpha: 0.78,
                          ),
                    width: 0.85,
                  ),
                  boxShadow: (_focused &&
                          FocusManager.instance.highlightMode ==
                              FocusHighlightMode.traditional)
                      ? [
                          BoxShadow(
                            color: glass.focusGlow
                                .withValues(alpha: dark ? 0.25 : 0.18),
                            blurRadius: 8,
                            spreadRadius: 0.5,
                          ),
                        ]
                      : const [],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 16, color: fg),
                    const SizedBox(width: 7),
                    Text(
                      widget.label,
                      maxLines: 1,
                      softWrap: false,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: fg,
                        fontWeight: widget.selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PeerSearchBar extends StatefulWidget {
  const PeerSearchBar({super.key, this.focusNode, this.onFocusChanged});

  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChanged;

  @override
  State<StatefulWidget> createState() => _PeerSearchBarState();
}

class _PeerSearchBarState extends State<PeerSearchBar> {
  FocusNode? _internalFocusNode;

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ??
      (_internalFocusNode ??= FocusNode(debugLabel: 'peer-search'));

  @override
  void initState() {
    super.initState();
    _effectiveFocusNode.addListener(_handleFocusChanged);
    peerSearchTextController.addListener(_handleTextChanged);
  }

  @override
  void didUpdateWidget(covariant PeerSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _internalFocusNode)?.removeListener(
        _handleFocusChanged,
      );
      if (widget.focusNode != null && _internalFocusNode != null) {
        _internalFocusNode!.dispose();
        _internalFocusNode = null;
      }
      _effectiveFocusNode.addListener(_handleFocusChanged);
    }
  }

  void _handleFocusChanged() {
    if (!mounted) return;
    widget.onFocusChanged?.call(_effectiveFocusNode.hasFocus);
  }

  void _handleTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _effectiveFocusNode.removeListener(_handleFocusChanged);
    peerSearchTextController.removeListener(_handleTextChanged);
    _internalFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassInput(
      controller: peerSearchTextController,
      focusNode: _effectiveFocusNode,
      minHeight: 40,
      prefixIcon: CamelliaIcons.search,
      hintText: translate('Search ID'),
      textInputAction: TextInputAction.search,
      showClearButton: true,
      onChanged: (searchText) => peerSearchText.value = searchText,
      onClear: () {
        peerSearchText.value = '';
        _effectiveFocusNode.requestFocus();
      },
    ).workaroundFreezeLinuxMint();
  }
}

/// 1-click frosted [GlassSegmentedControl] (`Grid | Tile | List`) exposing all
/// three peer workspace layouts cleanly.
class PeerViewDropdown extends StatefulWidget {
  const PeerViewDropdown({super.key});

  @override
  State<PeerViewDropdown> createState() => _PeerViewDropdownState();
}

class _PeerViewDropdownState extends State<PeerViewDropdown> {
  Future<void> _selectView(PeerUiType value) async {
    if (isOptionFixed(kOptionPeerCardUiType)) return;
    peerCardUiType.value = value;
    await bind.setLocalFlutterOption(
      k: kOptionPeerCardUiType,
      v: value.index.toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fixed = isOptionFixed(kOptionPeerCardUiType);
    return Obx(() {
      final active = peerCardUiType.value;
      return IgnorePointer(
        ignoring: fixed,
        child: Opacity(
          opacity: fixed ? 0.5 : 1.0,
          child: GlassSegmentedControl<PeerUiType>(
            compact: true,
            expand: false,
            height: 36,
            selected: active,
            items: [
              GlassSegmentItem<PeerUiType>(
                value: PeerUiType.grid,
                icon: Icons.grid_view_rounded,
                tooltip: translate('Big tiles'),
              ),
              GlassSegmentItem<PeerUiType>(
                value: PeerUiType.tile,
                icon: Icons.view_module_rounded,
                tooltip: translate('Small tiles'),
              ),
              GlassSegmentItem<PeerUiType>(
                value: PeerUiType.list,
                icon: Icons.view_list_rounded,
                tooltip: translate('List'),
              ),
            ],
            onChanged: _selectView,
          ),
        ),
      );
    });
  }
}

class PeerSortDropdown extends StatefulWidget {
  const PeerSortDropdown({super.key});

  @override
  State<PeerSortDropdown> createState() => _PeerSortDropdownState();
}

class _PeerSortDropdownState extends State<PeerSortDropdown> {
  _PeerSortDropdownState() {
    if (!PeerSortType.values.contains(peerSort.value)) {
      _loadLocalOptions();
    }
  }

  void _loadLocalOptions() {
    peerSort.value = PeerSortType.remoteId;
    bind.setLocalFlutterOption(k: kOptionPeerSorting, v: peerSort.value);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => DeviceOptionMenuButton<String>(
        tooltip: translate('Sort by'),
        icon: Icons.sort_rounded,
        selectedValue: peerSort.value,
        options: [
          for (final option in PeerSortType.values)
            DeviceOptionMenuItem<String>(
              value: option,
              label: translate(option),
              icon: option == PeerSortType.remoteId
                  ? Icons.numbers_rounded
                  : Icons.text_fields_rounded,
            ),
        ],
        onSelected: (value) async {
          peerSort.value = value;
          await bind.setLocalFlutterOption(
            k: kOptionPeerSorting,
            v: peerSort.value,
          );
        },
      ),
    );
  }
}

/// Frosted refresh control that rotates ONLY the inner icon glyph while
/// keeping the outer hover surface stationary.
class RefreshWidget extends StatefulWidget {
  final VoidCallback onPressed;
  final Widget child;
  final RxBool? spinning;
  const RefreshWidget({
    super.key,
    required this.onPressed,
    required this.child,
    this.spinning,
  });

  @override
  State<RefreshWidget> createState() => RefreshWidgetState();
}

class RefreshWidgetState extends State<RefreshWidget> {
  double turns = 0.0;
  bool hover = false;
  StreamSubscription<bool>? _spinningSubscription;

  void _subscribeSpinning() {
    _spinningSubscription?.cancel();
    _spinningSubscription = widget.spinning?.listen((v) {
      if (v && mounted) {
        setState(() {
          turns += 1;
        });
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _subscribeSpinning();
  }

  @override
  void didUpdateWidget(covariant RefreshWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spinning != widget.spinning) {
      _subscribeSpinning();
    }
  }

  @override
  void dispose() {
    _spinningSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = CamelliaGlassTokens.of(context);
    final radius = BorderRadius.circular(CamelliaRadius.control);
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    return SizedBox.square(
      dimension: 44,
      child: Center(
        child: Material(
          color: hover ? glass.hoverOverlay : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            hoverColor: glass.hoverOverlay,
            highlightColor: Colors.transparent,
            splashColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            focusColor: Colors.transparent,
            onTap: () {
              HapticFeedback.selectionClick();
              if (mounted && !reduceMotion) setState(() => turns += 1.0);
              widget.onPressed();
            },
            onHover: (value) {
              if (mounted) setState(() => hover = value);
            },
            child: SizedBox.square(
              dimension: 40,
              child: Center(
                child: AnimatedRotation(
                  turns: turns,
                  duration: CamelliaMotion.resolve(
                    context,
                    CamelliaMotion.route,
                  ),
                  curve: CamelliaMotion.springSnappy,
                  onEnd: () {
                    if (widget.spinning?.value == true &&
                        mounted &&
                        !reduceMotion) {
                      setState(() => turns += 1.0);
                    }
                  },
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _hoverAction({
  required BuildContext context,
  required Widget child,
  required Function() onTap,
  required String toolTip,
  GestureTapDownCallback? onTapDown,
  RxBool? hoverableWhenfalse,
  EdgeInsetsGeometry padding = const EdgeInsets.all(4.0),
}) {
  Widget action(bool selected) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final activeAccent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final radius = BorderRadius.circular(CamelliaRadius.control);
    return Tooltip(
      message: toolTip,
      child: SizedBox.square(
        dimension: 44,
        child: Center(
          child: Material(
            color: selected
                ? activeAccent.withValues(alpha: dark ? 0.22 : 0.14)
                : Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              hoverColor: glass.hoverOverlay,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
              focusColor: Colors.transparent,
              onTap: () {
                HapticFeedback.selectionClick();
                onTap();
              },
              onTapDown: onTapDown,
              child: SizedBox.square(
                dimension: 40,
                child: Center(
                  child: Padding(padding: padding, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  return hoverableWhenfalse == null
      ? action(false)
      : Obx(() => action(hoverableWhenfalse.value == false));
}
