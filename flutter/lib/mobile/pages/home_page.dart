// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/mobile/pages/connection_page.dart';
import 'package:camellia_remote_app/mobile/pages/scan_page.dart';
import 'package:camellia_remote_app/mobile/pages/server_page.dart';
import 'package:camellia_remote_app/mobile/pages/settings_page.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/widgets/chat_page.dart';
import '../../consts.dart';
import '../../models/platform_model.dart';

abstract class PageShape extends Widget {
  const PageShape({super.key});

  final String title = '';
  final Widget icon = const Icon(null);
  final List<Widget> appBarActions = const [];
}

enum _MobileTabKind { connect, share, chat, settings }

class _MobileTabSpec {
  const _MobileTabSpec({
    required this.kind,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
    this.badgeCount = 0,
  });

  final _MobileTabKind kind;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final WidgetBuilder builder;
  final int badgeCount;
}

class HomePage extends StatefulWidget {
  static final homeKey = GlobalKey<HomePageState>();

  HomePage() : super(key: homeKey);

  @override
  HomePageState createState() => HomePageState();
}

/// Hosts the mobile Precision Studio workspace with an [IndexedStack] that
/// preserves tab state across navigation and a frosted hairline bottom bar.
class HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  final Map<_MobileTabKind, Widget> _cachedTabPages = {};

  List<_MobileTabSpec> _buildTabs() {
    final tabs = <_MobileTabSpec>[];
    final canShare = isAndroid && !bind.isOutgoingOnly();
    final incomingOnly = bind.isIncomingOnly();

    if (!incomingOnly) {
      tabs.add(
        _MobileTabSpec(
          kind: _MobileTabKind.connect,
          label: translate('Connection'),
          icon: CamelliaIcons.screen,
          selectedIcon: CamelliaIcons.screen,
          builder: (_) => const ConnectionPage(appBarActions: []),
        ),
      );
    }

    if (canShare || incomingOnly) {
      tabs.add(
        _MobileTabSpec(
          kind: _MobileTabKind.share,
          label: translate('Share screen'),
          icon: Icons.mobile_screen_share_outlined,
          selectedIcon: Icons.mobile_screen_share_rounded,
          builder: (_) => ServerPage(),
        ),
      );
    }

    if (isAndroid) {
      tabs.add(
        _MobileTabSpec(
          kind: _MobileTabKind.chat,
          label: translate('Chat'),
          icon: CamelliaIcons.chat,
          selectedIcon: Icons.chat_bubble_rounded,
          badgeCount: gFFI.chatModel.mobileUnreadSum.value,
          builder: (_) => ChatPage(type: ChatPageType.mobileMain),
        ),
      );
    }

    if (!bind.isDisableSettings()) {
      tabs.add(
        _MobileTabSpec(
          kind: _MobileTabKind.settings,
          label: translate('Settings'),
          icon: CamelliaIcons.settings,
          selectedIcon: CamelliaIcons.settings,
          builder: (_) => const SettingsPage(),
        ),
      );
    }
    return tabs;
  }

  _MobileTabKind? get _activeKind {
    final tabs = _buildTabs();
    if (tabs.isEmpty) return null;
    final clamped = _selectedIndex.clamp(0, tabs.length - 1);
    return tabs[clamped].kind;
  }

  bool get isServerPageCurrentTab =>
      isAndroid && !bind.isOutgoingOnly() && _activeKind == _MobileTabKind.share;

  bool get isChatPageCurrentTab =>
      isAndroid && _activeKind == _MobileTabKind.chat;

  void refreshPages() {
    if (mounted) {
      setState(() {
        _cachedTabPages.clear();
      });
    }
  }

  void selectChatPage() {
    if (!isAndroid) return;
    final tabs = _buildTabs();
    final idx = tabs.indexWhere((t) => t.kind == _MobileTabKind.chat);
    if (idx >= 0 && mounted) {
      setState(() => _selectedIndex = idx);
    }
  }

  void _onSelectTab(int index, List<_MobileTabSpec> tabs) {
    if (index < 0 || index >= tabs.length) return;
    final previousKind = _activeKind;
    if (index != _selectedIndex) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _selectedIndex = index);
    }
    if (previousKind == _MobileTabKind.chat &&
        tabs[index].kind != _MobileTabKind.chat) {
      gFFI.chatModel.hideChatIconOverlay();
      gFFI.chatModel.hideChatWindowOverlay();
      gFFI.chatModel.mobileClearClientUnread(gFFI.chatModel.currentKey.connId);
    }
  }

  List<Widget> _resolveTabChildren(
    BuildContext context,
    List<_MobileTabSpec> tabs,
  ) {
    final activeKinds = tabs.map((t) => t.kind).toSet();
    _cachedTabPages.removeWhere((kind, _) => !activeKinds.contains(kind));
    return tabs
        .map(
          (spec) => _cachedTabPages.putIfAbsent(
            spec.kind,
            () => KeyedSubtree(
              key: ValueKey<_MobileTabKind>(spec.kind),
              child: spec.builder(context),
            ),
          ),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Obx(() {
      // Subscribe to live Android chat unread badge updates.
      final _ = gFFI.chatModel.mobileUnreadSum.value;
      final tabs = _buildTabs();
      final clampedIndex = tabs.isEmpty
          ? 0
          : _selectedIndex.clamp(0, tabs.length - 1);
      final activeTab = tabs.isEmpty ? null : tabs[clampedIndex];
      final canShare = isAndroid && !bind.isOutgoingOnly();
      final showShareMenu =
          canShare &&
          activeTab?.kind == _MobileTabKind.share &&
          !bind.isDisableSettings() &&
          bind.mainGetBuildinOption(key: kOptionHideSecuritySetting) != 'Y';
      final showBottomBar = tabs.length > 1 && !keyboardVisible;
      const navBarContentHeight = 60.0;

      return AppAmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            toolbarHeight: 56,
            centerTitle: false,
            titleSpacing: 16,
            flexibleSpace: GlassSurface(
              layer: CamelliaGlassLayer.sidebar,
              borderRadius: BorderRadius.zero,
              showShadow: false,
              strokeWidth: 0,
              child: const SizedBox.expand(),
            ),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(0.85),
              child: Container(
                height: 0.85,
                color: tokens.border.withValues(alpha: 0.72),
              ),
            ),
            title: Row(
              children: [
                CamelliaBrandMark(
                  size: 32,
                  semanticLabel: bind.mainGetAppNameSync(),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        bind.mainGetAppNameSync(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (activeTab != null)
                        Text(
                          activeTab.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: tokens.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              if (!isWeb && activeTab?.kind == _MobileTabKind.connect)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GlassIconButton(
                    icon: CamelliaIcons.qrScan,
                    tooltip: translate('Scan QR'),
                    size: 36,
                    iconSize: 18,
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ScanPage(),
                        ),
                      );
                    },
                  ),
                ),
              if (activeTab?.kind == _MobileTabKind.chat)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: unreadTopRightBuilder(
                    gFFI.chatModel.mobileUnreadSum,
                    icon: GlassIconButton(
                      icon: Icons.forum_outlined,
                      tooltip: translate('Conversations'),
                      size: 36,
                      iconSize: 18,
                      onPressed: () =>
                          ChatPage.showConversationSwitcher(context),
                    ),
                  ),
                ),
              if (showShareMenu)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: ServerAccessMenuButton(),
                ),
              const SizedBox(width: 10),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: tabs.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: EdgeInsets.only(
                      bottom: showBottomBar
                          ? navBarContentHeight + bottomSafe
                          : bottomSafe,
                    ),
                    child: IndexedStack(
                      index: clampedIndex,
                      children: _resolveTabChildren(context, tabs),
                    ),
                  ),
          ),
          bottomNavigationBar: showBottomBar
              ? _MobileStudioBottomBar(
                  tabs: tabs,
                  currentIndex: clampedIndex,
                  bottomPadding: bottomSafe,
                  height: navBarContentHeight,
                  onTap: (i) => _onSelectTab(i, tabs),
                )
              : null,
        ),
      );
    });
  }
}

class _MobileStudioBottomBar extends StatelessWidget {
  const _MobileStudioBottomBar({
    required this.tabs,
    required this.currentIndex,
    required this.bottomPadding,
    required this.height,
    required this.onTap,
  });

  final List<_MobileTabSpec> tabs;
  final int currentIndex;
  final double bottomPadding;
  final double height;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final activeColor = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: tokens.border.withValues(alpha: dark ? 0.85 : 0.90),
            width: 0.85,
          ),
        ),
      ),
      child: GlassSurface(
        layer: CamelliaGlassLayer.modal,
        borderRadius: BorderRadius.zero,
        showShadow: false,
        strokeWidth: 0,
        padding: EdgeInsets.fromLTRB(10, 6, 10, bottomPadding + 6),
        child: Center(
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SizedBox(
              height: height - 12,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: _MobileNavItem(
                        spec: tabs[i],
                        selected: i == currentIndex,
                        activeColor: activeColor,
                        mutedColor: tokens.muted,
                        dark: dark,
                        reduceMotion: reduceMotion,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onTap(i);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileNavItem extends StatelessWidget {
  const _MobileNavItem({
    required this.spec,
    required this.selected,
    required this.activeColor,
    required this.mutedColor,
    required this.dark,
    required this.reduceMotion,
    required this.onTap,
  });

  final _MobileTabSpec spec;
  final bool selected;
  final Color activeColor;
  final Color mutedColor;
  final bool dark;
  final bool reduceMotion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Semantics(
        button: true,
        selected: selected,
        label: spec.label,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              curve: CamelliaMotion.standard,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(
                color: selected
                    ? activeColor.withValues(alpha: dark ? 0.20 : 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                border: selected
                    ? Border.all(
                        color: activeColor.withValues(
                          alpha: dark ? 0.36 : 0.24,
                        ),
                        width: 0.85,
                      )
                    : null,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    selected ? spec.selectedIcon : spec.icon,
                    size: 20,
                    color: selected ? activeColor : mutedColor,
                  ),
                  if (spec.badgeCount > 0)
                    Positioned(
                      right: -10,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: CamelliaColors.statusAlertLight,
                          borderRadius: BorderRadius.circular(
                            CamelliaRadius.pill,
                          ),
                        ),
                        child: Text(
                          spec.badgeCount > 99 ? '99+' : '${spec.badgeCount}',
                          style: CamelliaTypography.tabular(
                            const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              spec.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                color: selected ? activeColor : mutedColor,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
