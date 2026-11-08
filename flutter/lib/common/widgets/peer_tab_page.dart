import 'dart:async';
import 'dart:ui' as ui;

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/address_book.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/my_group.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/widgets/popup_menu.dart';
import 'package:camellia_remote_app/desktop/widgets/material_mod_popup_menu.dart'
    as mod_menu;
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/ui/device_workspace_controls.dart';

import 'package:camellia_remote_app/models/peer_tab_model.dart';
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
  RelativeRect? mobileTabContextMenuPos;
  bool _searchFocused = false;
  bool _compactSearchOpen = false;
  int? _loadedTab;
  int? _scheduledTab;

  final isOptVisiableFixed = isOptionFixed(kOptionPeerTabVisible);

  @override
  void initState() {
    super.initState();
    _loadLocalOptions();
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final categoryLayout = deviceCategoryLayoutForWidth(
          constraints.maxWidth,
        );
        final contentWidth = categoryLayout == DeviceCategoryLayout.rail
            ? constraints.maxWidth - 64
            : constraints.maxWidth;
        final content = Column(
          textBaseline: TextBaseline.ideographic,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (categoryLayout != DeviceCategoryLayout.rail) ...[
              visibleContextMenuListener(
                _createCategoryControl(context, categoryLayout),
              ),
              const SizedBox(height: 8),
            ],
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
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
        if (categoryLayout != DeviceCategoryLayout.rail) return content;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            visibleContextMenuListener(_createCategoryRail(context)),
            const SizedBox(width: 12),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  Widget _createCategoryControl(
    BuildContext context,
    DeviceCategoryLayout layout,
  ) {
    final model = Provider.of<PeerTabModel>(context);
    final tabs = model.visibleEnabledOrderedIndexs;
    if (tabs.isEmpty) return const SizedBox.shrink();
    final selected = tabs.contains(model.currentTab)
        ? model.currentTab
        : tabs.first;
    Future<void> select(int tab) async {
      await handleTabSelection(tab);
      await bind.setLocalFlutterOption(
        k: kOptionPeerTabIndex,
        v: tab.toString(),
      );
    }

    if (layout == DeviceCategoryLayout.selector) {
      return SizedBox(
        height: 44,
        child: DropdownButtonFormField<int>(
          key: ValueKey<int>(selected),
          initialValue: selected,
          isExpanded: true,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            prefixIcon: Icon(model.tabIcon(selected), size: 19),
          ),
          items: [
            for (final tab in tabs)
              DropdownMenuItem<int>(
                value: tab,
                child: Text(
                  model.tabTooltip(tab),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: isOptionFixed(kOptionPeerTabIndex)
              ? null
              : (tab) {
                  if (tab != null) select(tab);
                },
        ),
      );
    }
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          for (final tab in tabs)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 4),
              child: _categoryButton(
                context,
                tab: tab,
                selected: tab == selected,
                onPressed: isOptionFixed(kOptionPeerTabIndex)
                    ? null
                    : () => select(tab),
              ),
            ),
        ],
      ),
    );
  }

  Widget _createCategoryRail(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    final tabs = model.visibleEnabledOrderedIndexs;
    return SizedBox(
      width: 52,
      child: Column(
        children: [
          for (final tab in tabs)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _categoryButton(
                context,
                tab: tab,
                selected: tab == model.currentTab,
                onPressed: isOptionFixed(kOptionPeerTabIndex)
                    ? null
                    : () async {
                        await handleTabSelection(tab);
                        await bind.setLocalFlutterOption(
                          k: kOptionPeerTabIndex,
                          v: tab.toString(),
                        );
                      },
              ),
            ),
        ],
      ),
    );
  }

  Widget _categoryButton(
    BuildContext context, {
    required int tab,
    required bool selected,
    required VoidCallback? onPressed,
  }) {
    final model = Provider.of<PeerTabModel>(context, listen: false);
    final theme = Theme.of(context);
    final label = model.tabTooltip(tab);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: selected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: Icon(
                  model.tabIcon(tab),
                  size: 20,
                  color: selected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
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
              child: const Icon(Icons.search_rounded, size: 19),
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
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            width: width < 520
                ? (width - 48).clamp(0, width).toDouble()
                : deviceSearchWidth(width, focused: _searchFocused),
            child: PeerSearchBar(
              onFocusChanged: (focused) {
                if (_searchFocused != focused && mounted) {
                  setState(() => _searchFocused = focused);
                }
              },
            ),
          ),
          if (width >= 520) ...[
            const SizedBox(width: 8),
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
        Row(children: [Expanded(child: InkWell())]),
      );
    } else {
      if (model.visibleEnabledOrderedIndexs.contains(model.currentTab)) {
        child = entries[model.currentTab].widget;
      } else {
        debugPrint("should not happen! currentTab not in visibleIndexs");
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
        padding: EdgeInsets.only(top: (isDesktop || isWebDesktop) ? 8.0 : 6.0),
        child: child,
      ),
    );
  }

  Widget _createRefresh() {
    final model = Provider.of<PeerTabModel>(context, listen: false);
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
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
        child: RotatedBox(
          quarterTurns: 2,
          child: Icon(Icons.refresh, size: 18, color: textColor),
        ),
      ),
    );
  }

  Widget _createPeerViewTypeSwitch(BuildContext context) {
    return PeerViewDropdown();
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

  void mobileShowTabVisibilityMenu() {
    final model = gFFI.peerTabModel;
    final items = List<PopupMenuItem>.empty(growable: true);
    for (int i = 0; i < PeerTabModel.maxTabCount; i++) {
      if (!model.isEnabled[i]) continue;
      items.add(
        PopupMenuItem(
          height: kMinInteractiveDimension * 0.8,
          onTap: isOptVisiableFixed
              ? null
              : () => model.setTabVisible(i, !model.isVisibleEnabled[i]),
          enabled: !isOptVisiableFixed,
          child: Row(
            children: [
              Checkbox(
                value: model.isVisibleEnabled[i],
                onChanged: isOptVisiableFixed
                    ? null
                    : (_) {
                        model.setTabVisible(i, !model.isVisibleEnabled[i]);
                        if (Navigator.canPop(context)) {
                          Navigator.pop(context);
                        }
                      },
              ),
              Expanded(child: Text(model.tabTooltip(i))),
            ],
          ),
        ),
      );
    }
    if (mobileTabContextMenuPos != null) {
      showMenu(
        context: context,
        position: mobileTabContextMenuPos!,
        items: items,
      );
    }
  }

  Widget visibleContextMenuListener(Widget child) {
    if (!(isDesktop || isWebDesktop)) {
      return GestureDetector(
        onLongPressDown: (e) {
          final x = e.globalPosition.dx;
          final y = e.globalPosition.dy;
          mobileTabContextMenuPos = RelativeRect.fromLTRB(x, y, x, y);
        },
        onLongPressUp: () {
          mobileShowTabVisibilityMenu();
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
            showRightMenu((CancelFunc cancelFunc) {
              return visibleContextMenu(cancelFunc);
            }, target: e.position);
          }
        },
        child: child,
      );
    }
  }

  Widget visibleContextMenu(CancelFunc cancelFunc) {
    final model = Provider.of<PeerTabModel>(context);
    final menu = List<MenuEntrySwitchSync>.empty(growable: true);
    for (int i = 0; i < model.orders.length; i++) {
      int tabIndex = model.orders[i];
      if (tabIndex < 0 || tabIndex >= PeerTabModel.maxTabCount) continue;
      if (!model.isEnabled[tabIndex]) continue;
      menu.add(
        MenuEntrySwitchSync(
          switchType: SwitchType.scheckbox,
          text: model.tabTooltip(tabIndex),
          currentValue: model.isVisibleEnabled[tabIndex],
          setter: (show) async {
            model.setTabVisible(tabIndex, show);
            // Do not hide the current menu (checkbox)
            // cancelFunc();
          },
          enabled: (!isOptVisiableFixed).obs,
        ),
      );
    }
    return mod_menu.PopupMenu(
      items: menu
          .map(
            (entry) => entry.build(
              context,
              const MenuConfig(
                commonColor: MyTheme.accent,
                height: 20.0,
                dividerHeight: 12.0,
              ),
            ),
          )
          .expand((i) => i)
          .toList(),
    );
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
    final currentTab = model.currentTab;
    if (currentTab == PeerTabIndex.group.index) {
      return Offstage();
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

        onSubmit() async {
          if (model.currentTab != targetTab) {
            gFFI.peerTabModel.setMultiSelectionMode(false);
            return false;
          }
          final peers = selectedSnapshot;
          switch (targetTab) {
            case 0:
              for (var p in peers) {
                await bind.mainRemovePeer(id: p.id);
              }
              bind.mainLoadRecentPeers();
              break;
            case 1:
              final favs = (await bind.mainGetFav()).toList();
              peers.map((p) {
                favs.remove(p.id);
              }).toList();
              await bind.mainStoreFav(favs: favs);
              bind.mainLoadFavPeers();
              break;
            case 2:
              for (var p in peers) {
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
      child: Icon(Icons.delete, color: Colors.red),
    );
  }

  Widget addSelectionToFav() {
    final model = Provider.of<PeerTabModel>(context);
    return Offstage(
      offstage:
          model.currentTab != PeerTabIndex.recent.index, // show based on recent
      child: _hoverAction(
        context: context,
        toolTip: translate('Add to Favorites'),
        onTap: () async {
          final peers = List<Peer>.from(model.selectedPeers);
          final favs = (await bind.mainGetFav()).toList();
          for (var p in peers) {
            if (!favs.contains(p.id)) {
              favs.add(p.id);
            }
          }
          await bind.mainStoreFav(favs: favs);
          model.setMultiSelectionMode(false);
          showToast(translate('Successful'));
        },
        child: Icon(PeerTabModel.icons[PeerTabIndex.fav.index]),
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
        child: Icon(PeerTabModel.icons[PeerTabIndex.ab.index]),
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
        child: Icon(Icons.tag),
      ).marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget selectionCount(int count) {
    return Align(
      alignment: Alignment.center,
      child: Text('$count ${translate('Selected')}'),
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
        child: Icon(Icons.select_all),
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
      child: Icon(Icons.clear),
    ).marginOnly(left: 6);
  }

  Widget _toggleTags() {
    return _hoverAction(
      context: context,
      toolTip: translate('Toggle Tags'),
      hoverableWhenfalse: hideAbTagsPanel,
      child: Icon(Icons.tag_rounded, size: 18),
      onTap: () async {
        await bind.mainSetLocalOption(
          key: kOptionHideAbTagsPanel,
          value: hideAbTagsPanel.value ? defaultOptionNo : "Y",
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
      if (model.currentTab != PeerTabIndex.recent.index) PeerSortDropdown(),
      if (model.currentTab == PeerTabIndex.ab.index) _toggleTags(),
    ];
  }
}

class PeerSearchBar extends StatefulWidget {
  const PeerSearchBar({Key? key, this.onFocusChanged}) : super(key: key);

  final ValueChanged<bool>? onFocusChanged;

  @override
  State<StatefulWidget> createState() => _PeerSearchBarState();
}

class _PeerSearchBarState extends State<PeerSearchBar> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'peer-search');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
    peerSearchTextController.addListener(_handleTextChanged);
  }

  void _handleFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = _focusNode.hasFocus);
    widget.onFocusChanged?.call(_focusNode.hasFocus);
  }

  void _handleTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);
    peerSearchTextController.removeListener(_handleTextChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(10);
    return SizedBox(
      height: 44,
      child: TextField(
        controller: peerSearchTextController,
        focusNode: _focusNode,
        textInputAction: TextInputAction.search,
        onChanged: (searchText) => peerSearchText.value = searchText,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: theme.colorScheme.surfaceContainer.withValues(alpha: 0.72),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          hintText: translate('Search ID'),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 18,
            color: _focused
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
          ),
          suffixIcon: peerSearchTextController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: translate('Clear'),
                  onPressed: () {
                    peerSearchTextController.clear();
                    peerSearchText.value = '';
                    _focusNode.requestFocus();
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
          ),
          border: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(
              color: theme.colorScheme.primary,
              width: 1.4,
            ),
          ),
        ),
      ).workaroundFreezeLinuxMint(),
    );
  }
}

class PeerViewDropdown extends StatefulWidget {
  const PeerViewDropdown({super.key});

  @override
  State<PeerViewDropdown> createState() => _PeerViewDropdownState();
}

class _PeerViewDropdownState extends State<PeerViewDropdown> {
  IconData _icon(PeerUiType type) => switch (type) {
    PeerUiType.grid => Icons.grid_view_rounded,
    PeerUiType.tile => Icons.view_agenda_rounded,
    PeerUiType.list => Icons.view_list_rounded,
  };

  String _label(PeerUiType type) => translate(switch (type) {
    PeerUiType.grid => 'Big tiles',
    PeerUiType.tile => 'Small tiles',
    PeerUiType.list => 'List',
  });

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => DeviceOptionMenuButton<PeerUiType>(
        tooltip: translate('Change view'),
        icon: _icon(peerCardUiType.value),
        enabled: !isOptionFixed(kOptionPeerCardUiType),
        selectedValue: peerCardUiType.value,
        options: [
          for (final type in PeerUiType.values)
            DeviceOptionMenuItem<PeerUiType>(
              value: type,
              label: _label(type),
              icon: _icon(type),
            ),
        ],
        onSelected: (value) async {
          peerCardUiType.value = value;
          await bind.setLocalFlutterOption(
            k: kOptionPeerCardUiType,
            v: value.index.toString(),
          );
        },
      ),
    );
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

  @override
  void initState() {
    super.initState();
    _spinningSubscription = widget.spinning?.listen((v) {
      if (v && mounted) {
        setState(() {
          turns += 1;
        });
      }
    });
  }

  @override
  void dispose() {
    _spinningSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: turns,
      duration: const Duration(milliseconds: 200),
      onEnd: () {
        if (widget.spinning?.value == true && mounted) {
          setState(() => turns += 1.0);
        }
      },
      child: Material(
        color: hover
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            if (mounted) setState(() => turns += 1.0);
            widget.onPressed();
          },
          onHover: (value) {
            if (mounted) setState(() => hover = value);
          },
          child: SizedBox.square(
            dimension: 44,
            child: Center(child: widget.child),
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
  Widget action(bool selected) => Tooltip(
    message: toolTip,
    child: Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        hoverColor: Theme.of(context).colorScheme.primaryContainer,
        onTap: onTap,
        onTapDown: onTapDown,
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    ),
  );
  return hoverableWhenfalse == null
      ? action(false)
      : Obx(() => action(hoverableWhenfalse.value == false));
}
