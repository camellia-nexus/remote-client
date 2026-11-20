import 'package:flutter/material.dart';
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
    required this.item,
    required this.builder,
  });

  final _MobileTabKind kind;
  final GlassFloatingTabItem item;
  final WidgetBuilder builder;
}

class HomePage extends StatefulWidget {
  static final homeKey = GlobalKey<HomePageState>();

  HomePage() : super(key: homeKey);

  @override
  HomePageState createState() => HomePageState();
}

/// Hosts the mobile Liquid Glass workspace with a thumb-friendly floating
/// capsule bottom tab bar and safe-area aware orientation layouts.
class HomePageState extends State<HomePage> {
  int _selectedIndex = 0;

  List<_MobileTabSpec> _buildTabs() {
    final tabs = <_MobileTabSpec>[];
    final canShare = isAndroid && !bind.isOutgoingOnly();
    final incomingOnly = bind.isIncomingOnly();

    if (!incomingOnly) {
      tabs.add(
        _MobileTabSpec(
          kind: _MobileTabKind.connect,
          item: GlassFloatingTabItem(
            label: translate('Connection'),
            icon: Icons.sensors_outlined,
            selectedIcon: Icons.sensors_rounded,
          ),
          builder: (_) => const ConnectionPage(appBarActions: []),
        ),
      );
    }

    if (canShare || incomingOnly) {
      tabs.add(
        _MobileTabSpec(
          kind: _MobileTabKind.share,
          item: GlassFloatingTabItem(
            label: translate('Share screen'),
            icon: Icons.mobile_screen_share_outlined,
            selectedIcon: Icons.mobile_screen_share_rounded,
          ),
          builder: (_) => ServerPage(),
        ),
      );
    }

    if (isAndroid) {
      tabs.add(
        _MobileTabSpec(
          kind: _MobileTabKind.chat,
          item: GlassFloatingTabItem(
            label: translate('Chat'),
            icon: Icons.chat_bubble_outline_rounded,
            selectedIcon: Icons.chat_bubble_rounded,
            badgeCount: gFFI.chatModel.mobileUnreadSum.value,
          ),
          builder: (_) => ChatPage(type: ChatPageType.mobileMain),
        ),
      );
    }

    if (!bind.isDisableSettings()) {
      tabs.add(
        _MobileTabSpec(
          kind: _MobileTabKind.settings,
          item: GlassFloatingTabItem(
            label: translate('Settings'),
            icon: Icons.tune_outlined,
            selectedIcon: Icons.tune_rounded,
          ),
          builder: (_) => SettingsPage(),
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
    if (mounted) setState(() {});
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
    setState(() => _selectedIndex = index);
    if (previousKind == _MobileTabKind.chat &&
        tabs[index].kind != _MobileTabKind.chat) {
      gFFI.chatModel.hideChatIconOverlay();
      gFFI.chatModel.hideChatWindowOverlay();
      gFFI.chatModel.mobileClearClientUnread(gFFI.chatModel.currentKey.connId);
    }
  }

  @override
  Widget build(BuildContext context) {
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

      return AppAmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
          appBar: AppBar(
            centerTitle: false,
            titleSpacing: 16,
            title: Row(
              children: [
                CamelliaAnimatedBrandMark(
                  size: 34,
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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                      ),
                      if (activeTab != null)
                        Text(
                          activeTab.item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
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
                    icon: Icons.qr_code_scanner_rounded,
                    tooltip: translate('Scan QR'),
                    size: 38,
                    iconSize: 19,
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => ScanPage()),
                      );
                    },
                  ),
                ),
              if (showShareMenu) const ServerAccessMenuButton(),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: tabs.isEmpty
                ? const SizedBox.shrink()
                : AnimatedSwitcher(
                    duration: CamelliaMotion.resolve(
                      context,
                      CamelliaMotion.content,
                    ),
                    switchInCurve: CamelliaMotion.enter,
                    switchOutCurve: CamelliaMotion.exit,
                    child: KeyedSubtree(
                      key: ValueKey<_MobileTabKind>(activeTab!.kind),
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: showBottomBar ? 86 : 0,
                        ),
                        child: activeTab.builder(context),
                      ),
                    ),
                  ),
          ),
          bottomNavigationBar: showBottomBar
              ? GlassFloatingTabBar(
                  items: tabs.map((t) => t.item).toList(growable: false),
                  currentIndex: clampedIndex,
                  onTap: (i) => _onSelectTab(i, tabs),
                )
              : null,
        ),
      );
    });
  }
}
