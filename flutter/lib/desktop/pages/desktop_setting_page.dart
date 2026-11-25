import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/audio_input.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
import 'package:camellia_remote_app/common/widgets/settings_components.dart';
import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
import 'package:camellia_remote_app/common/widgets/socks5_proxy_dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/desktop/widgets/remote_toolbar.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/printer_model.dart';
import 'package:camellia_remote_app/models/server_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/plugin/manager.dart';
import 'package:camellia_remote_app/plugin/widgets/desktop_settings.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:file_picker/file_picker.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

export 'package:camellia_remote_app/common/widgets/socks5_proxy_dialog.dart';

const double _kTabWidth = 220;
const double _kCardFixedWidth = 780;
const double _kListViewBottomMargin = 24;
const String _kSettingPageControllerTag = 'settingPageController';
const String _kSettingPageTabKeyTag = 'settingPageTabKey';
const String _kPortRegex =
    r'^$|^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$';

class _TabInfo {
  final SettingsTabKey key;
  final String label;
  final IconData unselected;
  final IconData selected;
  const _TabInfo(this.key, this.label, this.unselected, this.selected);
}

enum SettingsTabKey {
  general,
  safety,
  network,
  display,
  plugin,
  account,
  printer,
  about,
}

class DesktopSettingPage extends StatefulWidget {
  final SettingsTabKey initialTabkey;
  static final List<SettingsTabKey> tabKeys = [
    SettingsTabKey.general,
    if (!isWeb &&
        !bind.isOutgoingOnly() &&
        !bind.isDisableSettings() &&
        bind.mainGetBuildinOption(key: kOptionHideSecuritySetting) != 'Y')
      SettingsTabKey.safety,
    if (!bind.isDisableSettings() &&
        bind.mainGetBuildinOption(key: kOptionHideNetworkSetting) != 'Y')
      SettingsTabKey.network,
    if (!bind.isIncomingOnly()) SettingsTabKey.display,
    if (!isWeb && !bind.isIncomingOnly() && bind.pluginFeatureIsEnabled())
      SettingsTabKey.plugin,
    if (!bind.isDisableAccount()) SettingsTabKey.account,
    if (isWindows &&
        bind.mainGetBuildinOption(key: kOptionHideRemotePrinterSetting) != 'Y')
      SettingsTabKey.printer,
    SettingsTabKey.about,
  ];

  static SettingsTabKey? pendingInitialTabKey;

  const DesktopSettingPage({super.key, required this.initialTabkey});

  @override
  State<DesktopSettingPage> createState() => _DesktopSettingPageState();

  static void switch2page(SettingsTabKey page) {
    try {
      final int index = tabKeys.indexOf(page);
      if (index == -1) {
        return;
      }
      final context = globalKey.currentContext;
      if (context != null) {
        final shell = CamelliaDesktopShell.of(context);
        if (shell != null) {
          shell.setDestination(DesktopNavDestination.settings);
        }
      }
      pendingInitialTabKey = page;
      if (Get.isRegistered<PageController>(tag: _kSettingPageControllerTag)) {
        final PageController controller = Get.find<PageController>(
          tag: _kSettingPageControllerTag,
        );
        final Rx<SettingsTabKey> selected = Get.find<Rx<SettingsTabKey>>(
          tag: _kSettingPageTabKeyTag,
        );
        selected.value = page;
        if (controller.hasClients) {
          controller.jumpToPage(index);
        }
      } else {
        if (context == null) return;
        final shell = CamelliaDesktopShell.of(context);
        if (shell == null) {
          showSettingsOverlay<void>(
            context: context,
            title: translate('Settings'),
            builder: (_) => DesktopSettingPage(initialTabkey: page),
          );
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Get.isRegistered<PageController>(
              tag: _kSettingPageControllerTag,
            )) {
              final controller = Get.find<PageController>(
                tag: _kSettingPageControllerTag,
              );
              final selected = Get.find<Rx<SettingsTabKey>>(
                tag: _kSettingPageTabKeyTag,
              );
              selected.value = page;
              if (controller.hasClients) {
                controller.jumpToPage(index);
              }
            }
          });
        }
      }
    } catch (e) {
      debugPrintStack(label: '$e');
    }
  }
}

class _DesktopSettingPageState extends State<DesktopSettingPage>
    with
        TickerProviderStateMixin,
        AutomaticKeepAliveClientMixin,
        WidgetsBindingObserver {
  late PageController controller;
  late Rx<SettingsTabKey> selectedTab;

  @override
  bool get wantKeepAlive => true;

  final RxBool _block = false.obs;
  final RxBool _canBeBlocked = false.obs;
  Timer? _videoConnTimer;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      shouldBeBlocked(_block, _shouldUseBlock);
    }
  }

  @override
  void initState() {
    super.initState();
    final effectiveTab =
        DesktopSettingPage.pendingInitialTabKey ?? widget.initialTabkey;
    DesktopSettingPage.pendingInitialTabKey = null;
    var initialIndex = DesktopSettingPage.tabKeys.indexOf(effectiveTab);
    if (initialIndex == -1) {
      initialIndex = 0;
    }
    selectedTab = DesktopSettingPage.tabKeys[initialIndex].obs;
    Get.put<Rx<SettingsTabKey>>(selectedTab, tag: _kSettingPageTabKeyTag);
    controller = PageController(initialPage: initialIndex);
    Get.put<PageController>(controller, tag: _kSettingPageControllerTag);
    controller.addListener(() {
      if (controller.page != null) {
        final int page = controller.page!.toInt();
        if (page < DesktopSettingPage.tabKeys.length) {
          selectedTab.value = DesktopSettingPage.tabKeys[page];
        }
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _videoConnTimer = periodic_immediate(
      const Duration(milliseconds: 1000),
      () async {
        if (!mounted) {
          return;
        }
        _canBeBlocked.value = await canBeBlocked();
      },
    );
  }

  @override
  void dispose() {
    _videoConnTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    Get.delete<PageController>(tag: _kSettingPageControllerTag);
    Get.delete<Rx<SettingsTabKey>>(tag: _kSettingPageTabKeyTag);
    controller.dispose();
    super.dispose();
  }

  List<_TabInfo> _settingTabs() {
    final List<_TabInfo> settingTabs = <_TabInfo>[];
    for (final tab in DesktopSettingPage.tabKeys) {
      switch (tab) {
        case SettingsTabKey.general:
          settingTabs.add(
            const _TabInfo(
              SettingsTabKey.general,
              'General',
              Icons.tune_rounded,
              Icons.tune_rounded,
            ),
          );
        case SettingsTabKey.safety:
          settingTabs.add(
            const _TabInfo(
              SettingsTabKey.safety,
              'Security',
              Icons.shield_outlined,
              Icons.shield_rounded,
            ),
          );
        case SettingsTabKey.network:
          settingTabs.add(
            const _TabInfo(
              SettingsTabKey.network,
              'Network',
              Icons.hub_outlined,
              Icons.hub_rounded,
            ),
          );
        case SettingsTabKey.display:
          settingTabs.add(
            const _TabInfo(
              SettingsTabKey.display,
              'Display',
              Icons.desktop_windows_outlined,
              Icons.desktop_windows_rounded,
            ),
          );
        case SettingsTabKey.plugin:
          settingTabs.add(
            const _TabInfo(
              SettingsTabKey.plugin,
              'Plugin',
              Icons.extension_outlined,
              Icons.extension_rounded,
            ),
          );
        case SettingsTabKey.account:
          settingTabs.add(
            const _TabInfo(
              SettingsTabKey.account,
              'Account',
              Icons.person_outline_rounded,
              Icons.person_rounded,
            ),
          );
        case SettingsTabKey.printer:
          settingTabs.add(
            const _TabInfo(
              SettingsTabKey.printer,
              'Printer',
              Icons.print_outlined,
              Icons.print_rounded,
            ),
          );
        case SettingsTabKey.about:
          settingTabs.add(
            const _TabInfo(
              SettingsTabKey.about,
              'About',
              Icons.info_outline_rounded,
              Icons.info_rounded,
            ),
          );
      }
    }
    return settingTabs;
  }

  List<Widget> _children() {
    final children = List<Widget>.empty(growable: true);
    for (final tab in DesktopSettingPage.tabKeys) {
      switch (tab) {
        case SettingsTabKey.general:
          children.add(const _General());
        case SettingsTabKey.safety:
          children.add(const _Safety());
        case SettingsTabKey.network:
          children.add(const _Network());
        case SettingsTabKey.display:
          children.add(const _Display());
        case SettingsTabKey.plugin:
          children.add(const _Plugin());
        case SettingsTabKey.account:
          children.add(const _Account());
        case SettingsTabKey.printer:
          children.add(const _Printer());
        case SettingsTabKey.about:
          children.add(const _About());
      }
    }
    return children;
  }

  Future<bool> _shouldUseBlock() async =>
      await canBeBlocked() && stateGlobal.videoConnCount > 0;

  Widget _buildBlock({required List<Widget> children}) {
    return Obx(() {
      final videoConnBlock =
          _canBeBlocked.value && stateGlobal.videoConnCount > 0;
      return Stack(
        children: [
          buildRemoteBlock(
            block: _block,
            mask: false,
            use: _shouldUseBlock,
            child: preventMouseKeyBuilder(
              child: Row(children: children),
              block: videoConnBlock,
            ),
          ),
          if (videoConnBlock)
            Container(color: Colors.black.withValues(alpha: 0.5)),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final inShell = CamelliaDesktopShell.of(context) != null;
    final bodyContent = LayoutBuilder(
      builder: (context, constraints) {
        final useHorizontalTabs = constraints.maxWidth < 860;
        final compact = constraints.maxWidth < 720;
        final glass = CamelliaGlassTokens.of(context);
        final pageArea = Expanded(
          child: LayoutBuilder(
            builder: (context, contentConstraints) {
              final contentWidth = contentConstraints.maxWidth
                  .clamp(0.0, 820.0)
                  .toDouble();
              return Center(
                child: SizedBox(
                  width: contentWidth,
                  height: contentConstraints.maxHeight,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 12 : 24,
                      0,
                      compact ? 12 : 24,
                      10,
                    ),
                    child: PageView(
                      controller: controller,
                      physics: const NeverScrollableScrollPhysics(),
                      children: _children(),
                    ),
                  ),
                ),
              );
            },
          ),
        );

        if (useHorizontalTabs) {
          return _buildBlock(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _horizontalTabStrip(context, tabs: _settingTabs()),
                    Divider(
                      height: 1,
                      thickness: 0.85,
                      color: glass.specularBottom,
                    ),
                    _contentHeader(context, compact: compact),
                    Divider(
                      height: 1,
                      thickness: 0.85,
                      color: glass.specularBottom,
                    ),
                    pageArea,
                  ],
                ),
              ),
            ],
          );
        }

        return _buildBlock(
          children: <Widget>[
            GlassSurface(
              layer: CamelliaGlassLayer.sidebar,
              borderRadius: BorderRadius.zero,
              showShadow: false,
              strokeWidth: 0,
              child: SizedBox(
                width: _kTabWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 16, 8),
                      child: Text(
                        translate('Settings'),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                      ),
                    ),
                    Flexible(
                      child: _listView(tabs: _settingTabs(), compact: false),
                    ),
                  ],
                ),
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 0.85,
              color: glass.specularBottom,
            ),
            Expanded(
              child: Column(
                children: [
                  _contentHeader(context, compact: false),
                  Divider(
                    height: 1,
                    thickness: 0.85,
                    color: glass.specularBottom,
                  ),
                  pageArea,
                ],
              ),
            ),
          ],
        );
      },
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: inShell ? bodyContent : CamelliaBackdrop(child: bodyContent),
    );
  }

  Widget _horizontalTabStrip(
    BuildContext context, {
    required List<_TabInfo> tabs,
  }) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Obx(() {
        final activeKey = selectedTab.value;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                      onTap: () {
                        selectedTab.value = tabs[i].key;
                        if (controller.hasClients) {
                          controller.jumpToPage(i);
                        }
                      },
                      child: AnimatedContainer(
                        duration: CamelliaMotion.resolve(
                          context,
                          CamelliaMotion.feedback,
                        ),
                        curve: CamelliaMotion.springSnappy,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: tabs[i].key == activeKey
                              ? accent.withValues(alpha: isDark ? 0.22 : 0.14)
                              : glass.floatingTint.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(
                            CamelliaRadius.pill,
                          ),
                          border: Border.all(
                            color: tabs[i].key == activeKey
                                ? accent.withValues(alpha: 0.48)
                                : glass.specularBottom,
                            width: 0.85,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              tabs[i].key == activeKey
                                  ? tabs[i].selected
                                  : tabs[i].unselected,
                              size: 16,
                              color: tabs[i].key == activeKey
                                  ? accent
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              translate(tabs[i].label),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: tabs[i].key == activeKey
                                    ? (isDark
                                          ? theme.colorScheme.onSurface
                                          : accent)
                                    : theme.colorScheme.onSurfaceVariant,
                                fontWeight: tabs[i].key == activeKey
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
            ],
          ),
        );
      }),
    );
  }

  Widget _contentHeader(BuildContext context, {required bool compact}) {
    return Obx(() {
      final tabs = _settingTabs();
      final tab = tabs.firstWhere(
        (entry) => entry.key == selectedTab.value,
        orElse: () => tabs.first,
      );
      return Container(
        height: compact ? 52 : 60,
        padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 24),
        color: Colors.transparent,
        child: Row(
          children: [
            if (isWeb) ...[
              GlassIconButton(
                icon: Icons.arrow_back_rounded,
                size: 36,
                iconSize: 18,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () {
                  if (Navigator.canPop(context)) {
                    Navigator.pop(context);
                  }
                },
              ),
              const SizedBox(width: 8),
            ],
            AppIconBadge(
              icon: tab.selected,
              colors: AppVisual.connectGradient,
              size: compact ? 32 : 36,
              iconSize: compact ? 17 : 19,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    translate(tab.label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!compact)
                    Text(
                      translate(_tabDescription(tab.key)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  String _tabDescription(SettingsTabKey key) => switch (key) {
    SettingsTabKey.general => 'Appearance, language, and app behavior',
    SettingsTabKey.safety => 'Authentication and incoming access',
    SettingsTabKey.network => 'Servers, proxy, and transport',
    SettingsTabKey.display => 'Image quality and remote screen behavior',
    SettingsTabKey.plugin => 'Extensions and integrations',
    SettingsTabKey.account => 'Profile and cloud services',
    SettingsTabKey.printer => 'Remote printing preferences',
    SettingsTabKey.about => 'Version, privacy, and licenses',
  };

  Widget _listView({required List<_TabInfo> tabs, required bool compact}) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: tabs
          .map((tab) => _listItem(tab: tab, compact: compact))
          .toList(),
    );
  }

  Widget _listItem({required _TabInfo tab, required bool compact}) {
    return Obx(() {
      final bool selected = tab.key == selectedTab.value;
      final theme = Theme.of(context);
      final isDark = theme.brightness == Brightness.dark;
      final label = translate(tab.label);
      final tone = isDark
          ? theme.colorScheme.secondary
          : theme.colorScheme.primary;
      final item = Semantics(
        selected: selected,
        button: true,
        label: compact ? label : null,
        excludeSemantics: compact,
        child: AnimatedContainer(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
          curve: CamelliaMotion.standard,
          height: compact ? 44 : 40,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: selected
                ? tone.withValues(alpha: isDark ? 0.20 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
            border: Border.all(
              color: selected
                  ? tone.withValues(alpha: 0.36)
                  : Colors.transparent,
              width: 0.85,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              onTap: () {
                if (selectedTab.value != tab.key) {
                  final int index = DesktopSettingPage.tabKeys.indexOf(tab.key);
                  if (index == -1) {
                    return;
                  }
                  controller.jumpToPage(index);
                }
                selectedTab.value = tab.key;
              },
              child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                      left: compact ? 0 : 12,
                      right: compact ? 0 : 10,
                    ),
                    child: Icon(
                      selected ? tab.selected : tab.unselected,
                      color: selected ? tone : AppVisual.subduedText(context),
                      size: 19,
                    ),
                  ),
                  if (!compact)
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: selected
                              ? (isDark ? theme.colorScheme.onSurface : tone)
                              : theme.colorScheme.onSurface,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      return compact ? Tooltip(message: label, child: item) : item;
    });
  }
}

//#region pages

class _General extends StatefulWidget {
  const _General();

  @override
  State<_General> createState() => _GeneralState();
}

class _GeneralState extends State<_General> {
  final RxBool serviceStop = isWeb
      ? RxBool(false)
      : Get.find<RxBool>(tag: 'stop-service');
  final RxBool serviceBtnEnabled = true.obs;
  final GlobalKey _minToolbarOptionKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
      children: [
        if (!isWeb) service(),
        theme(),
        languageSection(),
        if (!isWeb) hwcodec(),
        if (!isWeb) audio(context),
        if (!isWeb) record(context),
        if (!isWeb) const WaylandCard(),
        other(),
      ],
    );
  }

  Widget theme() {
    final current = switch (MyTheme.getThemePreference()) {
      CamelliaThemePreference.light => 'light',
      CamelliaThemePreference.dark => 'dark',
      CamelliaThemePreference.midnight => 'midnight',
      CamelliaThemePreference.system => 'system',
    };
    Future<void> onChanged(String value) async {
      await MyTheme.changeThemePreference(
        MyTheme.themePreferenceFromString(value),
      );
    }

    final isOptFixed = isOptionFixed(kCommConfKeyTheme);
    final currentStyle = MyTheme.getThemeStyle().name;
    Future<void> onStyleChanged(String value) async {
      await MyTheme.changeThemeStyle(CamelliaThemeStyle.fromString(value));
    }

    return SettingsGroup(
      title: translate('Theme'),
      subtitle: translate('Choose interface brightness and surface aesthetic'),
      tiles: [
        CustomSettingsTile(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    translate('Appearance Mode'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 460;
                    return GlassSegmentedControl<String>(
                      compact: compact,
                      expand: true,
                      selected: current,
                      items: [
                        GlassSegmentItem(
                          value: 'light',
                          icon: Icons.light_mode_rounded,
                          label: compact ? null : translate('Light'),
                          tooltip: translate('Light'),
                        ),
                        GlassSegmentItem(
                          value: 'dark',
                          icon: Icons.dark_mode_rounded,
                          label: compact ? null : translate('Dark'),
                          tooltip: translate('Dark'),
                        ),
                        GlassSegmentItem(
                          value: 'midnight',
                          icon: Icons.nights_stay_rounded,
                          label: compact ? null : translate('OLED Midnight'),
                          tooltip: translate('OLED Midnight'),
                        ),
                        GlassSegmentItem(
                          value: 'system',
                          icon: Icons.brightness_auto_rounded,
                          label: compact ? null : translate('Follow System'),
                          tooltip: translate('Follow System'),
                        ),
                      ],
                      onChanged: isOptFixed ? (_) {} : onChanged,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        CustomSettingsTile(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    translate('Theme Style'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 460;
                    return GlassSegmentedControl<String>(
                      compact: compact,
                      expand: true,
                      selected: currentStyle,
                      items: [
                        GlassSegmentItem(
                          value: 'auroraFrost',
                          icon: Icons.auto_awesome_rounded,
                          label: compact ? null : translate('Aurora Frost'),
                          tooltip: translate('Aurora Frost'),
                        ),
                        GlassSegmentItem(
                          value: 'obsidianCyber',
                          icon: Icons.space_dashboard_rounded,
                          label: compact ? null : translate('Obsidian Cyber'),
                          tooltip: translate('Obsidian Cyber'),
                        ),
                        GlassSegmentItem(
                          value: 'nordicTitanium',
                          icon: Icons.texture_rounded,
                          label: compact ? null : translate('Nordic Titanium'),
                          tooltip: translate('Nordic Titanium'),
                        ),
                      ],
                      onChanged: onStyleChanged,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget service() {
    if (bind.isOutgoingOnly()) {
      return const Offstage();
    }

    final hideStopService =
        bind.mainGetBuildinOption(key: kOptionHideStopService) == 'Y';

    return Obx(() {
      if (hideStopService && !serviceStop.value) {
        return const Offstage();
      }
      final stopped = serviceStop.value;
      return SettingsGroup(
        title: translate('Service'),
        subtitle: translate('Control the background remote access service'),
        tiles: [
          SettingsTile(
            leading: Icon(
              stopped
                  ? Icons.pause_circle_outline_rounded
                  : Icons.verified_rounded,
            ),
            title: Text(translate('Service')),
            description: Text(
              translate(
                stopped
                    ? 'Background service is currently stopped'
                    : 'Background service is active and ready for connections',
              ),
            ),
            value: GlassBadge(
              label: translate(stopped ? 'Stopped' : 'Running'),
              tone: stopped ? GlassBadgeTone.offline : GlassBadgeTone.online,
              showDot: true,
              compact: true,
            ),
            trailing: GlassButton(
              variant: stopped
                  ? GlassButtonVariant.primary
                  : GlassButtonVariant.secondary,
              minHeight: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              onPressed: serviceBtnEnabled.value
                  ? () async {
                      serviceBtnEnabled.value = false;
                      await start_service(serviceStop.value);
                      Future.delayed(const Duration(seconds: 1), () {
                        if (mounted) {
                          serviceBtnEnabled.value = true;
                        }
                      });
                    }
                  : null,
              child: Text(translate(stopped ? 'Start' : 'Stop')),
            ),
          ),
        ],
      );
    });
  }

  Widget languageSection() {
    return SettingsGroup(
      title: translate('Language'),
      subtitle: translate('Select display language for menus and dialogs'),
      tiles: [
        CustomSettingsTile(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: language(),
          ),
        ),
      ],
    );
  }

  Widget other() {
    final incomingOnly = bind.isIncomingOnly();
    final outgoingOnly = bind.isOutgoingOnly();
    final tiles = <AbstractSettingsTile>[
      if (!isWeb && !incomingOnly)
        _OptionSwitchTile(
          label: 'Confirm before closing multiple tabs',
          optionKey: kOptionEnableConfirmClosingTabs,
          isServer: false,
        ),
      if (!isWeb && !outgoingOnly)
        _OptionSwitchTile(
          label: 'Adaptive bitrate',
          optionKey: kOptionEnableAbr,
        ),
      if (!isWeb && !outgoingOnly) CustomSettingsTile(child: wallpaper()),
      if (!isWeb && !incomingOnly) ...[
        _OptionSwitchTile(
          label: 'Open connection in new tab',
          optionKey: kOptionOpenNewConnInTabs,
          isServer: false,
        ),
        if (isLinux)
          _OptionSwitchTile(
            label: 'Always use software rendering',
            description: 'software_render_tip',
            optionKey: kOptionAllowAlwaysSoftwareRender,
          ),
        if (!isWeb)
          _OptionSwitchTile(
            label: 'Use texture rendering',
            description: 'texture_render_tip',
            optionKey: kOptionTextureRender,
            optGetter: bind.mainGetUseTextureRender,
            optSetter: (k, v) async =>
                await bind.mainSetLocalOption(key: k, value: v ? 'Y' : 'N'),
          ),
        if (isWindows)
          _OptionSwitchTile(
            label: 'Use D3D rendering',
            description: 'd3d_render_tip',
            optionKey: kOptionD3DRender,
            isServer: false,
          ),
      ],
      if (isWindows && !outgoingOnly)
        _OptionSwitchTile(
          label: 'Capture screen using DirectX',
          optionKey: kOptionDirectxCapture,
        ),
      if (!isWeb && !incomingOnly) ...[
        _OptionSwitchTile(
          label: 'Enable UDP hole punching',
          optionKey: kOptionEnableUdpPunch,
          isServer: false,
        ),
        _OptionSwitchTile(
          label: 'Enable IPv6 P2P connection',
          optionKey: kOptionEnableIpv6Punch,
          isServer: false,
        ),
      ],
      if (!bind.isIncomingOnly())
        _OptionSwitchTile(
          label: 'keep-awake-during-outgoing-sessions-label',
          optionKey: kOptionKeepAwakeDuringOutgoingSessions,
          isServer: false,
        ),
      if (!isWeb && bind.mainShowOption(key: kOptionAllowLinuxHeadless))
        _OptionSwitchTile(
          label: 'Allow linux headless',
          optionKey: kOptionAllowLinuxHeadless,
        ),
      if (!bind.isDisableAccount())
        _OptionSwitchTile(
          label: 'note-at-conn-end-tip',
          optionKey: kOptionAllowAskForNoteAtEndOfConnection,
          isServer: false,
          optSetter: (key, value) async {
            if (value && !gFFI.userModel.isLogin) {
              final res = await loginDialog();
              if (res != true) return;
            }
            await mainSetLocalBoolOption(key, value);
          },
        ),
      _OptionSwitchTile(
        label: 'Show monitor switch button on the main toolbar',
        optionKey: kOptionAllowMonitorSwitchMainToolbar,
        isServer: false,
        update: (enabled) async {
          if (!enabled) {
            await mainSetLocalBoolOption(
              kOptionAllowMonitorSwitchMinToolbar,
              false,
            );
          }
          if (mounted) setState(() {});
          reloadAllWindows();
          if (enabled) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final ctx = _minToolbarOptionKey.currentContext;
              if (ctx != null) {
                Scrollable.ensureVisible(
                  ctx,
                  alignment: 0.5,
                  duration: const Duration(milliseconds: 250),
                  curve: CamelliaMotion.standard,
                );
              }
            });
          }
        },
      ),
      if (mainGetLocalBoolOptionSync(kOptionAllowMonitorSwitchMainToolbar))
        CustomSettingsTile(
          key: _minToolbarOptionKey,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 20),
            child: _OptionSwitchTile(
              label: 'Show on the minimized toolbar',
              optionKey: kOptionAllowMonitorSwitchMinToolbar,
              isServer: false,
              update: (_) {
                reloadAllWindows();
              },
            ),
          ),
        ),
    ];

    return SettingsGroup(
      title: translate('Other'),
      subtitle: translate(
        'Configure session tabs, rendering backend, and network transport options',
      ),
      tiles: tiles,
    );
  }

  Widget wallpaper() {
    if (bind.isOutgoingOnly()) {
      return const SizedBox.shrink();
    }

    return futureBuilder(
      future: () async {
        final support = await bind.mainSupportRemoveWallpaper();
        return support;
      }(),
      hasData: (data) {
        if (data is bool && data == true) {
          final bool value = mainGetBoolOptionSync(kOptionAllowRemoveWallpaper);
          return _OptionSwitchTile(
            label: 'Remove wallpaper during incoming sessions',
            optionKey: kOptionAllowRemoveWallpaper,
            trailing: value
                ? _CountDownButton(
                    text: 'Test',
                    second: 5,
                    onPressed: () {
                      bind.mainTestWallpaper(second: 5);
                    },
                  )
                : null,
            update: (bool v) {
              setState(() {});
            },
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget hwcodec() {
    final hwcodec = bind.mainHasHwcodec();
    final vram = bind.mainHasVram();
    if (!(hwcodec || vram)) {
      return const Offstage();
    }
    return SettingsGroup(
      title: translate('Hardware Codec'),
      subtitle: translate(
        'Accelerate video encoding and decoding using GPU hardware',
      ),
      tiles: [
        _OptionSwitchTile(
          label: 'Enable hardware codec',
          optionKey: kOptionEnableHwcodec,
          update: (bool v) {
            if (v) {
              bind.mainCheckHwcodec();
            }
          },
        ),
      ],
    );
  }

  Widget audio(BuildContext context) {
    if (bind.isOutgoingOnly()) {
      return const Offstage();
    }

    Widget builder(
      List<String> devices,
      String currentDevice,
      Function(String) setDevice,
    ) {
      return SettingsGroup(
        title: translate('Audio Input Device'),
        subtitle: translate(
          'Select microphone or audio source transmitted to remote peers',
        ),
        tiles: [
          CustomSettingsTile(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: ComboBox(
                keys: devices,
                values: devices,
                initialKey: currentDevice,
                onChanged: (key) async {
                  setDevice(key);
                  setState(() {});
                },
              ),
            ),
          ),
        ],
      );
    }

    return AudioInput(builder: builder, isCm: false, isVoiceCall: false);
  }

  Widget record(BuildContext context) {
    final showRootDir = isWindows && bind.mainIsInstalled();
    return futureBuilder(
      future: () async {
        final String userDir = bind.mainVideoSaveDirectory(root: false);
        final String rootDir = showRootDir
            ? bind.mainVideoSaveDirectory(root: true)
            : '';
        final bool userDirExists = await Directory(userDir).exists();
        final bool rootDirExists = showRootDir
            ? await Directory(rootDir).exists()
            : false;
        return {
          'user_dir': userDir,
          'root_dir': rootDir,
          'user_dir_exists': userDirExists,
          'root_dir_exists': rootDirExists,
        };
      }(),
      hasData: (data) {
        final Map<String, dynamic> map = data as Map<String, dynamic>;
        final String userDir = map['user_dir']!;
        final String rootDir = map['root_dir']!;
        final bool rootDirExists = map['root_dir_exists']!;
        final bool userDirExists = map['user_dir_exists']!;
        final theme = Theme.of(context);
        return SettingsGroup(
          title: translate('Recording'),
          subtitle: translate(
            'Configure automatic session recording and storage paths',
          ),
          tiles: [
            if (!bind.isOutgoingOnly())
              _OptionSwitchTile(
                label: 'Automatically record incoming sessions',
                optionKey: kOptionAllowAutoRecordIncoming,
              ),
            if (!bind.isOutgoingOnly())
              _OptionSwitchTile(
                label: 'Upload incoming session recordings to server',
                optionKey: kOptionUploadRecordingsToServer,
              ),
            if (!bind.isIncomingOnly())
              _OptionSwitchTile(
                label: 'Automatically record outgoing sessions',
                optionKey: kOptionAllowAutoRecordOutgoing,
                isServer: false,
              ),
            if (showRootDir && !bind.isOutgoingOnly())
              SettingsTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  translate(bind.isIncomingOnly() ? 'Directory' : 'Incoming'),
                ),
                description: SelectableText(
                  rootDir,
                  style: theme.textTheme.bodySmall?.copyWith(
                    decoration: rootDirExists ? TextDecoration.underline : null,
                  ),
                ),
                onPressed: rootDirExists
                    ? (_) => launchUrl(Uri.file(rootDir))
                    : null,
              ),
            if (!(showRootDir && bind.isIncomingOnly()))
              SettingsTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: Text(
                  translate(
                    (showRootDir && !bind.isOutgoingOnly())
                        ? 'Outgoing'
                        : 'Directory',
                  ),
                ),
                description: GestureDetector(
                  onTap: userDirExists
                      ? () => launchUrl(Uri.file(userDir))
                      : null,
                  child: Text(
                    userDir,
                    style: theme.textTheme.bodySmall?.copyWith(
                      decoration: userDirExists
                          ? TextDecoration.underline
                          : null,
                    ),
                  ),
                ),
                trailing: GlassButton(
                  variant: GlassButtonVariant.secondary,
                  minHeight: 34,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  onPressed: isOptionFixed(kOptionVideoSaveDirectory)
                      ? null
                      : () async {
                          String? initialDirectory;
                          if (await Directory.fromUri(
                            Uri.directory(userDir),
                          ).exists()) {
                            initialDirectory = userDir;
                          }
                          final String? selectedDirectory =
                              await FilePicker.getDirectoryPath(
                                initialDirectory: initialDirectory,
                              );
                          if (selectedDirectory != null) {
                            await bind.mainSetLocalOption(
                              key: kOptionVideoSaveDirectory,
                              value: selectedDirectory,
                            );
                            if (mounted) setState(() {});
                          }
                        },
                  child: Text(translate('Change')),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget language() {
    return futureBuilder(
      future: () async {
        try {
          final String langs = await bind.mainGetLangs();
          return {'langs': langs};
        } catch (e) {
          return {'error': e.toString()};
        }
      }(),
      hasData: (res) {
        final Map<String, dynamic> data = res as Map<String, dynamic>;
        if (data.containsKey('error')) {
          return Row(
            children: [
              Expanded(
                child: Text(
                  '${translate("Failed to load language list")}: ${formatUserFriendlyError(data['error'].toString())}',
                  style: TextStyle(
                    color: CamelliaGlassTokens.of(context).statusAlert,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: CamelliaIcons.refresh,
                size: 34,
                iconSize: 17,
                tooltip: translate('Retry'),
                onPressed: () {
                  setState(() {});
                },
              ),
            ],
          );
        }
        List<dynamic> langsList = [];
        try {
          final decoded = jsonDecode(data['langs'] as String);
          if (decoded is List) {
            langsList = decoded;
          }
        } catch (e) {
          debugPrint('JSON decode failed for langs: $e');
        }
        final Map<String, String> langsMap = {};
        for (final v in langsList) {
          if (v is List && v.length >= 2) {
            langsMap[v[0].toString()] = v[1].toString();
          }
        }
        final List<String> keys = langsMap.keys.toList();
        final List<String> values = langsMap.values.toList();
        keys.insert(0, defaultOptionLang);
        values.insert(0, translate('Default'));
        String currentKey = bind.mainGetLocalOption(key: kCommConfKeyLang);
        if (!keys.contains(currentKey)) {
          currentKey = defaultOptionLang;
        }
        final isOptFixed = isOptionFixed(kCommConfKeyLang);
        return ComboBox(
          keys: keys,
          values: values,
          initialKey: currentKey,
          onChanged: (key) async {
            await bind.mainSetLocalOption(key: kCommConfKeyLang, value: key);
            if (isWeb) reloadCurrentWindow();
            if (!isWeb) reloadAllWindows();
            if (!isWeb) bind.mainChangeLanguage(lang: key);
          },
          enabled: !isOptFixed,
        );
      },
    );
  }
}

enum _AccessMode { custom, full, view }

class _Safety extends StatefulWidget {
  const _Safety();

  @override
  State<_Safety> createState() => _SafetyState();
}

class _SafetyState extends State<_Safety> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  bool locked = bind.mainIsInstalled();

  final TextEditingController _directIpController = TextEditingController();
  final RxBool _directIpApplyEnabled = false.obs;

  final TextEditingController _autoDisconnectController =
      TextEditingController();
  final RxBool _autoDisconnectApplyEnabled = false.obs;

  @override
  void initState() {
    super.initState();
    _directIpController.text = bind.mainGetOptionSync(
      key: kOptionDirectAccessPort,
    );
    _autoDisconnectController.text = bind.mainGetOptionSync(
      key: kOptionAutoDisconnectTimeout,
    );
  }

  @override
  void dispose() {
    _directIpController.dispose();
    _autoDisconnectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
      child: Column(
        children: [
          _lock(locked, 'Unlock Security Settings', () {
            locked = false;
            setState(() {});
          }),
          preventMouseKeyBuilder(
            block: locked,
            child: Column(
              children: [
                permissions(context),
                password(context),
                tfaSection(),
                // COMPAT-001 contract: _Card(title: 'ID', children: [changeId()])
                if (!isChangeIdDisabled()) changeId(),
                more(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget tfaSection() {
    final bool enabled = !locked;
    final bool has2fa = bind.mainHasValid2FaSync();
    final bool hasBot = bind.mainHasValidBotSync();
    final bool trustedEnabled = mainGetBoolOptionSync(
      kOptionEnableTrustedDevices,
    );

    void refreshState() {
      if (mounted) setState(() {});
    }

    void toggle2fa(bool next) {
      if (!next) {
        CommonConfirmDialog(
          gFFI.dialogManager,
          translate('cancel-2fa-confirm-tip'),
          () => change2fa(callback: refreshState),
        );
      } else {
        change2fa(callback: refreshState);
      }
    }

    void toggleBot(bool next) {
      if (!next) {
        CommonConfirmDialog(
          gFFI.dialogManager,
          translate('cancel-bot-confirm-tip'),
          () => changeBot(callback: refreshState),
        );
      } else {
        changeBot(callback: refreshState);
      }
    }

    return SettingsGroup(
      title: translate('2FA'),
      subtitle: translate(
        'Add two-factor verification and trusted device management',
      ),
      tiles: [
        SettingsTile.switchTile(
          leading: const Icon(CamelliaIcons.shield),
          title: Text(translate('enable-2fa-title')),
          description: Text(
            translate(
              'Protect incoming connections with time-based verification codes',
            ),
          ),
          enabled: enabled,
          initialValue: has2fa,
          onToggle: toggle2fa,
        ),
        if (has2fa) ...[
          SettingsTile.switchTile(
            leading: const Icon(Icons.send_rounded),
            title: Text(translate('Telegram bot')),
            description: Text(translate('enable-bot-tip')),
            enabled: enabled,
            initialValue: hasBot,
            onToggle: toggleBot,
          ),
          _OptionSwitchTile(
            label: 'Enable trusted devices',
            description: 'enable-trusted-devices-tip',
            optionKey: kOptionEnableTrustedDevices,
            enabled: enabled,
            update: (_) => refreshState(),
          ),
          if (trustedEnabled)
            SettingsTile(
              leading: const Icon(Icons.devices_rounded),
              title: Text(translate('Manage trusted devices')),
              description: Text(
                translate(
                  'Review or revoke devices authorized to skip two-factor verification',
                ),
              ),
              enabled: enabled,
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onPressed: (_) => manageTrustedDeviceDialog(),
            ),
        ],
      ],
    );
  }

  Widget changeId() {
    if (isChangeIdDisabled()) {
      return const SizedBox.shrink();
    }
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, child) {
          final canChange = !locked && model.connectStatus > 0;
          return SettingsGroup(
            title: translate('ID'),
            subtitle: translate(
              'Customize your device identifier on the rendezvous server',
            ),
            tiles: [
              SettingsTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(translate('Change ID')),
                description: Text(translate('id_change_tip')),
                enabled: canChange,
                trailing: GlassButton(
                  variant: GlassButtonVariant.secondary,
                  minHeight: 34,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  onPressed: canChange ? changeIdDialog : null,
                  child: Text(translate('Change ID')),
                ),
                onPressed: canChange ? (_) => changeIdDialog() : null,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget permissions(BuildContext context) {
    final bool enabled = !locked;
    final String accessMode = bind.mainGetOptionSync(key: kOptionAccessMode);
    final _AccessMode mode = switch (accessMode) {
      'full' => _AccessMode.full,
      'view' => _AccessMode.view,
      _ => _AccessMode.custom,
    };
    final (String initialKey, bool? fakeValue) = switch (mode) {
      _AccessMode.custom => ('', null),
      _AccessMode.full => ('full', true),
      _AccessMode.view => ('view', false),
    };

    return SettingsGroup(
      title: translate('Permissions'),
      subtitle: translate(
        'Configure capabilities granted to incoming remote sessions',
      ),
      tiles: [
        CustomSettingsTile(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: ComboBox(
              keys: [defaultOptionAccessMode, 'full', 'view'],
              values: [
                translate('Custom'),
                translate('Full Access'),
                translate('Screen Share'),
              ],
              enabled: enabled && !isOptionFixed(kOptionAccessMode),
              initialKey: initialKey,
              onChanged: (nextMode) async {
                await bind.mainSetOption(
                  key: kOptionAccessMode,
                  value: nextMode,
                );
                if (mounted) setState(() {});
              },
            ),
          ),
        ),
        _OptionSwitchTile(
          label: 'Enable keyboard/mouse',
          optionKey: kOptionEnableKeyboard,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        if (isWindows)
          _OptionSwitchTile(
            label: 'Enable remote printer',
            optionKey: kOptionEnableRemotePrinter,
            enabled: enabled,
            fakeValue: fakeValue,
          ),
        _OptionSwitchTile(
          label: 'Enable clipboard',
          optionKey: kOptionEnableClipboard,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        _OptionSwitchTile(
          label: 'Enable file transfer',
          optionKey: kOptionEnableFileTransfer,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        _OptionSwitchTile(
          label: 'Enable audio',
          optionKey: kOptionEnableAudio,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        _OptionSwitchTile(
          label: 'Enable camera',
          optionKey: kOptionEnableCamera,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        _OptionSwitchTile(
          label: 'Enable terminal',
          optionKey: kOptionEnableTerminal,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        _OptionSwitchTile(
          label: 'Enable TCP tunneling',
          optionKey: kOptionEnableTunnel,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        _OptionSwitchTile(
          label: 'Enable remote restart',
          optionKey: kOptionEnableRemoteRestart,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        _OptionSwitchTile(
          label: 'Enable recording session',
          optionKey: kOptionEnableRecordSession,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
        if (isWindows)
          _OptionSwitchTile(
            label: 'Enable blocking user input',
            optionKey: kOptionEnableBlockInput,
            enabled: enabled,
            fakeValue: fakeValue,
          ),
        if (bind.mainSupportedPrivacyModeImpls() != '[]')
          _OptionSwitchTile(
            label: 'Enable privacy mode',
            optionKey: kOptionEnablePrivacyMode,
            enabled: enabled,
            fakeValue: fakeValue,
          ),
        _OptionSwitchTile(
          label: 'Enable remote configuration modification',
          optionKey: kOptionAllowRemoteConfigModification,
          enabled: enabled,
          fakeValue: fakeValue,
        ),
      ],
    );
  }

  Widget password(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, child) {
          final List<String> passwordKeys = [
            kUseTemporaryPassword,
            kUsePermanentPassword,
            kUseBothPasswords,
          ];
          final List<String> passwordValues = [
            translate('Use one-time password'),
            translate('Use permanent password'),
            translate('Use both passwords'),
          ];
          final bool tmpEnabled =
              model.verificationMethod != kUsePermanentPassword;
          final bool permEnabled =
              model.verificationMethod != kUseTemporaryPassword;
          final int currentIdx = passwordKeys.indexOf(model.verificationMethod);
          final String currentValue =
              passwordValues[currentIdx < 0 ? 0 : currentIdx];

          Future<void> onMethodChanged(String? value) async {
            if (value == null || locked) return;
            Future<void> applyMethod() async {
              await model.setVerificationMethod(
                passwordKeys[passwordValues.indexOf(value)],
              );
              await model.updatePasswordModel();
            }

            if (value ==
                    passwordValues[passwordKeys.indexOf(
                      kUsePermanentPassword,
                    )] &&
                (await bind.mainGetCommon(key: 'permanent-password-set')) !=
                    'true') {
              if (isChangePermanentPasswordDisabled()) {
                await applyMethod();
                return;
              }
              setPasswordDialog(notEmptyCallback: applyMethod);
            } else {
              await applyMethod();
            }
          }

          final bool canEditLength = tmpEnabled && !locked;
          final bool isOptFixedNumOtp = isOptionFixed(
            kOptionAllowNumericOneTimePassword,
          );
          final bool isNumOtpChangeable =
              !isOptFixedNumOtp && tmpEnabled && !locked;

          final modeKeys = <String>[
            'password',
            'click',
            defaultOptionApproveMode,
          ];
          final modeValues = [
            translate('Accept sessions via password'),
            translate('Accept sessions via click'),
            translate('Accept sessions via both'),
          ];
          var modeInitialKey = model.approveMode;
          if (!modeKeys.contains(modeInitialKey)) {
            modeInitialKey = defaultOptionApproveMode;
          }
          final usePassword = model.approveMode != 'click';
          final isApproveModeFixed = isOptionFixed(kOptionApproveMode);

          return SettingsGroup(
            title: translate('Password'),
            subtitle: translate(
              'Manage session approval mode and authentication credentials',
            ),
            tiles: [
              CustomSettingsTile(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: ComboBox(
                    enabled: !locked && !isApproveModeFixed,
                    keys: modeKeys,
                    values: modeValues,
                    initialKey: modeInitialKey,
                    onChanged: (key) => model.setApproveMode(key),
                  ),
                ),
              ),
              if (usePassword) ...[
                CustomSettingsTile(
                  child: RadioGroup<String>(
                    groupValue: currentValue,
                    onChanged: locked ? (_) {} : onMethodChanged,
                    child: Column(
                      children: [
                        for (final label in passwordValues)
                          _RadioRow<String>(
                            value: label,
                            label: label,
                            enabled: !locked,
                            onSelected: () => onMethodChanged(label),
                          ),
                      ],
                    ),
                  ),
                ),
                SettingsTile(
                  title: Text(translate('One-time password length')),
                  enabled: canEditLength,
                  trailing: GlassSegmentedControl<String>(
                    compact: true,
                    selected:
                        const [
                          '6',
                          '8',
                          '10',
                        ].contains(model.temporaryPasswordLength)
                        ? model.temporaryPasswordLength
                        : '6',
                    items: const [
                      GlassSegmentItem(value: '6', label: '6'),
                      GlassSegmentItem(value: '8', label: '8'),
                      GlassSegmentItem(value: '10', label: '10'),
                    ],
                    onChanged: canEditLength
                        ? (len) async {
                            await model.setTemporaryPasswordLength(len);
                            await model.updatePasswordModel();
                          }
                        : (_) {},
                  ),
                ),
                SettingsTile.switchTile(
                  title: Text(translate('Numeric one-time password')),
                  description: Text(
                    translate(
                      'Generate digits-only temporary passcodes for easier entry',
                    ),
                  ),
                  enabled: isNumOtpChangeable,
                  initialValue: model.allowNumericOneTimePassword,
                  onToggle: (_) => model.switchAllowNumericOneTimePassword(),
                ),
                if (!isChangePermanentPasswordDisabled())
                  SettingsTile(
                    leading: const Icon(Icons.password_rounded),
                    title: Text(translate('Set permanent password')),
                    enabled: permEnabled && !locked,
                    trailing: GlassButton(
                      variant: GlassButtonVariant.secondary,
                      minHeight: 34,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      onPressed: permEnabled && !locked
                          ? setPasswordDialog
                          : null,
                      child: Text(translate('Set permanent password')),
                    ),
                    onPressed: permEnabled && !locked
                        ? (_) => setPasswordDialog()
                        : null,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget more(BuildContext context) {
    final bool enabled = !locked;
    final bool directIpEnabled = option2bool(
      kOptionEnableDirectServer,
      bind.mainGetOptionSync(key: kOptionEnableDirectServer),
    );
    if (!directIpEnabled) _directIpApplyEnabled.value = false;
    if (!_directIpApplyEnabled.value) {
      _directIpController.text = bind.mainGetOptionSync(
        key: kOptionDirectAccessPort,
      );
    }
    final bool isDirectPortFixed = isOptionFixed(kOptionDirectAccessPort);

    final bool autoDisconnectEnabled = option2bool(
      kOptionAllowAutoDisconnect,
      bind.mainGetOptionSync(key: kOptionAllowAutoDisconnect),
    );
    if (!autoDisconnectEnabled) _autoDisconnectApplyEnabled.value = false;
    if (!_autoDisconnectApplyEnabled.value) {
      _autoDisconnectController.text = bind.mainGetOptionSync(
        key: kOptionAutoDisconnectTimeout,
      );
    }
    final bool isAutoDisconnectFixed = isOptionFixed(
      kOptionAutoDisconnectTimeout,
    );

    final bool hasWhitelist = whitelistNotEmpty();
    final bool isWhitelistFixed = isOptionFixed(kOptionWhitelist);
    final bool hasPin = bind.mainGetUnlockPin().isNotEmpty;

    return SettingsGroup(
      title: translate('Security'),
      subtitle: translate(
        'Network discovery, direct IP access, whitelisting, and session protection',
      ),
      tiles: [
        if (isWindows && bind.mainIsInstalled())
          SettingsTile.switchTile(
            title: Text(translate('Enable RDP session sharing')),
            description: Text(
              translate(
                'Share active Windows RDP sessions instead of creating a separate login',
              ),
            ),
            enabled: enabled,
            initialValue: bind.mainIsShareRdp(),
            onToggle: (b) async {
              await bind.mainSetShareRdp(enable: b);
              if (mounted) setState(() {});
            },
          ),
        _OptionSwitchTile(
          label: 'Deny LAN discovery',
          optionKey: 'enable-lan-discovery',
          reverse: true,
          enabled: enabled,
        ),
        _OptionSwitchTile(
          label: 'Enable direct IP access',
          optionKey: kOptionEnableDirectServer,
          enabled: enabled,
          update: (_) {
            if (mounted) setState(() {});
          },
        ),
        if (directIpEnabled)
          SettingsTile(
            title: Text(translate('Port')),
            enabled: enabled && !isDirectPortFixed,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 108,
                  child: GlassInput(
                    controller: _directIpController,
                    enabled: enabled && !isDirectPortFixed,
                    tabularNums: true,
                    showClearButton: false,
                    minHeight: 36,
                    hintText: '21118',
                    keyboardType: TextInputType.number,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 0,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(_kPortRegex)),
                    ],
                    onChanged: (_) => _directIpApplyEnabled.value = true,
                  ).workaroundFreezeLinuxMint(),
                ),
                const SizedBox(width: 8),
                Obx(
                  () => GlassButton(
                    variant: GlassButtonVariant.primary,
                    minHeight: 36,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    onPressed:
                        _directIpApplyEnabled.value &&
                            enabled &&
                            !isDirectPortFixed
                        ? () async {
                            _directIpApplyEnabled.value = false;
                            await bind.mainSetOption(
                              key: kOptionDirectAccessPort,
                              value: _directIpController.text.trim(),
                            );
                          }
                        : null,
                    child: Text(translate('Apply')),
                  ),
                ),
              ],
            ),
          ),
        SettingsTile.switchTile(
          title: Text(translate('Use IP Whitelisting')),
          description: Text(translate('whitelist_tip')),
          enabled: enabled && !isWhitelistFixed,
          initialValue: hasWhitelist,
          trailing: hasWhitelist
              ? GlassBadge(
                  label: translate('Active'),
                  tone: GlassBadgeTone.warning,
                  icon: Icons.warning_amber_rounded,
                  compact: true,
                )
              : null,
          onToggle: (_) {
            changeWhiteList(
              callback: () {
                if (mounted) setState(() {});
              },
            );
          },
        ),
        _OptionSwitchTile(
          label: 'auto_disconnect_option_tip',
          optionKey: kOptionAllowAutoDisconnect,
          enabled: enabled,
          update: (_) {
            if (mounted) setState(() {});
          },
        ),
        if (autoDisconnectEnabled)
          SettingsTile(
            title: Text(translate('Timeout in minutes')),
            enabled: enabled && !isAutoDisconnectFixed,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 108,
                  child: GlassInput(
                    controller: _autoDisconnectController,
                    enabled: enabled && !isAutoDisconnectFixed,
                    tabularNums: true,
                    showClearButton: false,
                    minHeight: 36,
                    hintText: '10',
                    keyboardType: TextInputType.number,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 0,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^$|^(0|[1-9]\d{0,3})$'),
                      ),
                    ],
                    onChanged: (_) => _autoDisconnectApplyEnabled.value = true,
                  ).workaroundFreezeLinuxMint(),
                ),
                const SizedBox(width: 8),
                Obx(
                  () => GlassButton(
                    variant: GlassButtonVariant.primary,
                    minHeight: 36,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    onPressed:
                        _autoDisconnectApplyEnabled.value &&
                            enabled &&
                            !isAutoDisconnectFixed
                        ? () async {
                            _autoDisconnectApplyEnabled.value = false;
                            await bind.mainSetOption(
                              key: kOptionAutoDisconnectTimeout,
                              value: _autoDisconnectController.text.trim(),
                            );
                          }
                        : null,
                    child: Text(translate('Apply')),
                  ),
                ),
              ],
            ),
          ),
        _OptionSwitchTile(
          label: 'keep-awake-during-incoming-sessions-label',
          optionKey: kOptionKeepAwakeDuringIncomingSessions,
          enabled: enabled,
        ),
        if (bind.mainIsInstalled())
          _OptionSwitchTile(
            label: 'allow-only-conn-window-open-tip',
            optionKey: 'allow-only-conn-window-open',
            enabled: enabled,
          ),
        if (bind.mainIsInstalled() && !isUnlockPinDisabled())
          SettingsTile.switchTile(
            leading: const Icon(CamelliaIcons.lock),
            title: Text(translate('Unlock with PIN')),
            description: Text(
              translate(
                'Require a local security PIN before unlocking protected settings',
              ),
            ),
            enabled: enabled && !isWhitelistFixed,
            initialValue: hasPin,
            onToggle: (_) {
              changeUnlockPinDialog(() {
                if (mounted) setState(() {});
              });
            },
          ),
      ],
    );
  }
}

class _Network extends StatefulWidget {
  const _Network();

  @override
  State<_Network> createState() => _NetworkState();
}

class _NetworkState extends State<_Network> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  bool locked = !isWeb && bind.mainIsInstalled();
  final Set<String> _pendingSwitchKeys = {};

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
      children: [
        _lock(locked, 'Unlock Network Settings', () {
          locked = false;
          setState(() {});
        }),
        preventMouseKeyBuilder(
          block: locked,
          child: Column(children: [network(context)]),
        ),
      ],
    );
  }

  Widget network(BuildContext context) {
    final hideServer =
        bind.mainGetBuildinOption(key: kOptionHideServerSetting) == 'Y';
    final hideProxy =
        isWeb || bind.mainGetBuildinOption(key: kOptionHideProxySetting) == 'Y';
    final hideWebSocket =
        isWeb ||
        bind.mainGetBuildinOption(key: kOptionHideWebSocketSetting) == 'Y';

    if (hideServer && hideProxy && hideWebSocket) {
      return const Offstage();
    }

    final outgoingOnly = bind.isOutgoingOnly();

    final tiles = <AbstractSettingsTile>[];
    if (!hideServer) {
      tiles.add(
        SettingsTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text(translate('ID/Relay Server')),
          description: Text(
            translate(
              'Configure custom rendezvous, relay, and API endpoints',
            ),
          ),
          enabled: !locked,
          trailing: const Icon(Icons.chevron_right_rounded, size: 20),
          onPressed: (_) => showServerSettings(gFFI.dialogManager, setState),
        ),
      );
    }
    if (!hideProxy) {
      tiles.add(
        SettingsTile(
          leading: const Icon(Icons.network_ping_outlined),
          title: Text(translate('Socks5/Http(s) Proxy')),
          description: Text(translate('default_proxy_tip')),
          enabled: !locked,
          trailing: const Icon(Icons.chevron_right_rounded, size: 20),
          onPressed: (_) => changeSocks5Proxy(),
        ),
      );
    }
    if (!hideWebSocket) {
      tiles.add(
        SettingsTile.switchTile(
          leading: const Icon(Icons.web_asset_outlined),
          title: Text(translate('Use WebSocket')),
          description: Text(translate('websocket_tip')),
          enabled:
              !locked &&
              !isOptionFixed(kOptionAllowWebSocket) &&
              !_pendingSwitchKeys.contains(kOptionAllowWebSocket),
          initialValue: mainGetBoolOptionSync(kOptionAllowWebSocket),
          onToggle: (value) async {
            _pendingSwitchKeys.add(kOptionAllowWebSocket);
            setState(() {});
            try {
              await mainSetBoolOption(kOptionAllowWebSocket, value);
            } finally {
              _pendingSwitchKeys.remove(kOptionAllowWebSocket);
              if (mounted) {
                setState(() {});
              }
            }
          },
        ),
      );
    }

    final sectionWidget = SettingsGroup(
      title: translate('Network'),
      subtitle: translate(
        'Configure rendezvous, relay, proxy, and transport protocols',
      ),
      tiles: tiles,
    );

    if (!isWeb) {
      return Column(
        children: [
          sectionWidget,
          futureBuilder(
            future: bind.mainIsUsingPublicServer(),
            hasData: (isUsingPublicServer) {
              if (isUsingPublicServer || outgoingOnly) {
                return const Offstage();
              } else {
                return SettingsGroup(
                  tiles: [
                    SettingsTile.switchTile(
                      leading: const Icon(Icons.lan_outlined),
                      title: Text(translate('Disable UDP')),
                      description: Text(translate('disable-udp-tip')),
                      enabled: !locked && !isOptionFixed(kOptionDisableUdp),
                      initialValue:
                          bind.mainGetOptionSync(key: kOptionDisableUdp) == 'Y',
                      onToggle: (value) async {
                        await bind.mainSetOption(
                          key: kOptionDisableUdp,
                          value: value ? 'Y' : 'N',
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                );
              }
            },
          ),
        ],
      );
    }

    return sectionWidget;
  }
}

class _Display extends StatefulWidget {
  const _Display();

  @override
  State<_Display> createState() => _DisplayState();
}

class _DisplayState extends State<_Display> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
      children: [
        viewStyle(context),
        scrollStyle(context),
        imageQuality(context),
        codec(context),
        if (isDesktop) trackpadSpeed(context),
        if (!isWeb) privacyModeImpl(context),
        other(context),
      ],
    );
  }

  Widget viewStyle(BuildContext context) {
    final isOptFixed = isOptionFixed(kOptionViewStyle);
    Future<void> onChanged(String value) async {
      await bind.mainSetUserDefaultOption(key: kOptionViewStyle, value: value);
      if (mounted) setState(() {});
    }

    final groupValue = bind.mainGetUserDefaultOption(key: kOptionViewStyle);
    final selected = groupValue == kRemoteViewStyleAdaptive
        ? kRemoteViewStyleAdaptive
        : kRemoteViewStyleOriginal;

    return SettingsGroup(
      title: translate('Default View Style'),
      subtitle: translate(
        'Choose how remote screens scale inside session windows',
      ),
      tiles: [
        CustomSettingsTile(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: GlassSegmentedControl<String>(
              expand: true,
              selected: selected,
              items: [
                GlassSegmentItem(
                  value: kRemoteViewStyleOriginal,
                  icon: Icons.aspect_ratio_rounded,
                  label: translate('Scale original'),
                ),
                GlassSegmentItem(
                  value: kRemoteViewStyleAdaptive,
                  icon: Icons.fit_screen_rounded,
                  label: translate('Scale adaptive'),
                ),
              ],
              onChanged: isOptFixed ? (_) {} : onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget scrollStyle(BuildContext context) {
    final isOptFixed = isOptionFixed(kOptionScrollStyle);
    Future<void> onChanged(String value) async {
      await bind.mainSetUserDefaultOption(
        key: kOptionScrollStyle,
        value: value,
      );
      if (mounted) setState(() {});
    }

    final rawValue = bind.mainGetUserDefaultOption(key: kOptionScrollStyle);
    final selected =
        rawValue == kRemoteScrollStyleBar ||
            (!isWeb && rawValue == kRemoteScrollStyleEdge)
        ? rawValue
        : kRemoteScrollStyleAuto;

    Future<void> onEdgeScrollEdgeThicknessChanged(double value) async {
      await bind.mainSetUserDefaultOption(
        key: kOptionEdgeScrollEdgeThickness,
        value: value.round().toString(),
      );
      if (mounted) setState(() {});
    }

    return SettingsGroup(
      title: translate('Default Scroll Style'),
      subtitle: translate(
        'Select viewport panning behavior when remote screen exceeds window size',
      ),
      tiles: [
        CustomSettingsTile(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: GlassSegmentedControl<String>(
              expand: true,
              selected: selected,
              items: [
                GlassSegmentItem(
                  value: kRemoteScrollStyleAuto,
                  label: translate('ScrollAuto'),
                ),
                GlassSegmentItem(
                  value: kRemoteScrollStyleBar,
                  label: translate('Scrollbar'),
                ),
                if (!isWeb)
                  GlassSegmentItem(
                    value: kRemoteScrollStyleEdge,
                    label: translate('ScrollEdge'),
                  ),
              ],
              onChanged: isOptFixed ? (_) {} : onChanged,
            ),
          ),
        ),
        if (!isWeb && selected == kRemoteScrollStyleEdge)
          CustomSettingsTile(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: EdgeThicknessControl(
                value:
                    double.tryParse(
                      bind.mainGetUserDefaultOption(
                        key: kOptionEdgeScrollEdgeThickness,
                      ),
                    ) ??
                    100.0,
                onChanged: isOptionFixed(kOptionEdgeScrollEdgeThickness)
                    ? null
                    : onEdgeScrollEdgeThicknessChanged,
              ),
            ),
          ),
      ],
    );
  }

  Widget imageQuality(BuildContext context) {
    Future<void> onChanged(String? value) async {
      if (value == null) return;
      await bind.mainSetUserDefaultOption(
        key: kOptionImageQuality,
        value: value,
      );
      if (mounted) setState(() {});
    }

    final isOptFixed = isOptionFixed(kOptionImageQuality);
    final rawVal = bind.mainGetUserDefaultOption(key: kOptionImageQuality);
    final groupValue = rawVal.isEmpty ? kRemoteImageQualityBalanced : rawVal;

    const options = <(String, String)>[
      (kRemoteImageQualityBest, 'Good image quality'),
      (kRemoteImageQualityBalanced, 'Balanced'),
      (kRemoteImageQualityLow, 'Optimize reaction time'),
      (kRemoteImageQualityCustom, 'Custom'),
    ];

    return SettingsGroup(
      title: translate('Default Image Quality'),
      subtitle: translate(
        'Balance visual fidelity, frame rate, and bandwidth usage',
      ),
      tiles: [
        CustomSettingsTile(
          child: RadioGroup<String>(
            groupValue: groupValue,
            onChanged: isOptFixed ? (_) {} : onChanged,
            child: Column(
              children: [
                for (final item in options)
                  _RadioRow<String>(
                    value: item.$1,
                    label: translate(item.$2),
                    enabled: !isOptFixed,
                    onSelected: () => onChanged(item.$1),
                  ),
              ],
            ),
          ),
        ),
        if (groupValue == kRemoteImageQualityCustom)
          CustomSettingsTile(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: customImageQualitySetting(),
            ),
          ),
      ],
    );
  }

  Widget trackpadSpeed(BuildContext context) {
    final initSpeed =
        int.tryParse(bind.mainGetUserDefaultOption(key: kKeyTrackpadSpeed)) ??
        kDefaultTrackpadSpeed;
    final curSpeed = SimpleWrapper(initSpeed);
    void onDebouncer(int v) {
      bind.mainSetUserDefaultOption(
        key: kKeyTrackpadSpeed,
        value: v.toString(),
      );
    }

    return SettingsGroup(
      title: translate('Default trackpad speed'),
      subtitle: translate(
        'Adjust trackpad scrolling sensitivity in remote sessions',
      ),
      tiles: [
        CustomSettingsTile(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: TrackpadSpeedWidget(
              value: curSpeed,
              onDebouncer: onDebouncer,
            ),
          ),
        ),
      ],
    );
  }

  Widget codec(BuildContext context) {
    Future<void> onChanged(String? value) async {
      if (value == null) return;
      await bind.mainSetUserDefaultOption(
        key: kOptionCodecPreference,
        value: value,
      );
      if (mounted) setState(() {});
    }

    final rawCodec = bind.mainGetUserDefaultOption(key: kOptionCodecPreference);
    final groupValue = rawCodec.isEmpty ? 'auto' : rawCodec;
    final isOptFixed = isOptionFixed(kOptionCodecPreference);

    final codecOptions = <(String, String)>[
      ('auto', translate('Auto')),
      ('vp8', 'VP8'),
      ('vp9', 'VP9'),
      ('av1', 'AV1'),
    ];
    try {
      final Map codecsJson = jsonDecode(bind.mainSupportedHwdecodings());
      if (codecsJson['h264'] == true) {
        codecOptions.add(('h264', 'H264'));
      }
      if (codecsJson['h265'] == true) {
        codecOptions.add(('h265', 'H265'));
      }
    } catch (e) {
      debugPrint('failed to parse supported hwdecodings, err=$e');
    }

    return SettingsGroup(
      title: translate('Default Codec'),
      subtitle: translate(
        'Select preferred video codec for outgoing connections',
      ),
      tiles: [
        CustomSettingsTile(
          child: RadioGroup<String>(
            groupValue: groupValue,
            onChanged: isOptFixed ? (_) {} : onChanged,
            child: Column(
              children: [
                for (final item in codecOptions)
                  _RadioRow<String>(
                    value: item.$1,
                    label: item.$2,
                    enabled: !isOptFixed,
                    onSelected: () => onChanged(item.$1),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget privacyModeImpl(BuildContext context) {
    final supportedPrivacyModeImpls = bind.mainSupportedPrivacyModeImpls();
    late final List<dynamic> privacyModeImpls;
    try {
      privacyModeImpls = jsonDecode(supportedPrivacyModeImpls);
    } catch (e) {
      debugPrint('failed to parse supported privacy mode impls, err=$e');
      return const Offstage();
    }
    if (privacyModeImpls.length < 2) {
      return const Offstage();
    }

    const key = 'privacy-mode-impl-key';
    Future<void> onChanged(String? value) async {
      if (value == null) return;
      await bind.mainSetOption(key: key, value: value);
      if (mounted) setState(() {});
    }

    String groupValue = bind.mainGetOptionSync(key: key);
    if (groupValue.isEmpty) {
      groupValue = bind.mainDefaultPrivacyModeImpl();
    }
    return SettingsGroup(
      title: translate('Privacy mode'),
      subtitle: translate(
        'Select screen blanking driver for privacy mode sessions',
      ),
      tiles: [
        CustomSettingsTile(
          child: RadioGroup<String>(
            groupValue: groupValue,
            onChanged: onChanged,
            child: Column(
              children: privacyModeImpls.map((impl) {
                final d = impl as List<dynamic>;
                final val = d[0] as String;
                final label = translate(d[1] as String);
                return _RadioRow<String>(
                  value: val,
                  label: label,
                  enabled: true,
                  onSelected: () => onChanged(val),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  AbstractSettingsTile otherRow(String label, String key) {
    final value = bind.mainGetUserDefaultOption(key: key) == 'Y';
    final isOptFixed = isOptionFixed(key);
    Future<void> onChanged(bool b) async {
      await bind.mainSetUserDefaultOption(
        key: key,
        value: b
            ? 'Y'
            : (key == kOptionEnableFileCopyPaste ? 'N' : defaultOptionNo),
      );
      if (mounted) setState(() {});
    }

    return SettingsTile.switchTile(
      title: Text(translate(label)),
      enabled: !isOptFixed,
      initialValue: value,
      onToggle: onChanged,
    );
  }

  Widget other(BuildContext context) {
    final tiles = otherDefaultSettings()
        .map((e) => otherRow(e.$1, e.$2))
        .toList();
    return SettingsGroup(
      title: translate('Other Default Options'),
      subtitle: translate(
        'Default session toolbar, cursor, audio, and multi-monitor preferences',
      ),
      tiles: tiles,
    );
  }
}

class _Account extends StatefulWidget {
  const _Account();

  @override
  State<_Account> createState() => _AccountState();
}

class _AccountState extends State<_Account> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
      children: [
        Obx(() {
          final isSignedIn = gFFI.userModel.userName.value.isNotEmpty;
          return SettingsGroup(
            title: translate('Account'),
            subtitle: translate(
              'Sign in to sync devices, tags, and address books across workspaces',
            ),
            tiles: [
              CustomSettingsTile(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: isSignedIn
                      ? Row(
                          children: [
                            ?_buildUserAvatar(),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          gFFI.userModel.displayNameOrUserName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      GlassBadge(
                                        label: translate('Connected'),
                                        tone: GlassBadgeTone.online,
                                        showDot: true,
                                        compact: true,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  SelectionArea(
                                    child: Text(
                                      '@${gFFI.userModel.userName.value}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: CamelliaTypography.tabular(
                                        theme.textTheme.bodySmall?.copyWith(
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            GlassButton(
                              variant: GlassButtonVariant.danger,
                              minHeight: 38,
                              icon: const Icon(Icons.logout_rounded, size: 16),
                              onPressed: logOutConfirmDialog,
                              child: Text(translate('Logout')),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            const CamelliaStateIllustration(
                              glyph: CamelliaGlyph.addressBook,
                              size: 50,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    translate('Account'),
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    translate(
                                      'Sign in to sync devices and address book',
                                    ),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            GlassButton(
                              variant: GlassButtonVariant.primary,
                              minHeight: 38,
                              icon: const Icon(Icons.login_rounded, size: 17),
                              onPressed: loginDialog,
                              child: Text(translate('Login')),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget? _buildUserAvatar() {
    final avatar = bind.mainResolveAvatarUrl(
      avatar: gFFI.userModel.avatar.value,
    );
    return buildAvatarWidget(avatar: avatar, size: 46);
  }
}

class _Plugin extends StatefulWidget {
  const _Plugin();

  @override
  State<_Plugin> createState() => _PluginState();
}

class _PluginState extends State<_Plugin> {
  @override
  Widget build(BuildContext context) {
    bind.pluginListReload();
    final theme = Theme.of(context);
    return ChangeNotifierProvider.value(
      value: pluginManager,
      child: Consumer<PluginManager>(
        builder: (context, model, child) {
          if (model.plugins.isEmpty) {
            return ListView(
              padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
              children: [
                SettingsGroup(
                  title: translate('Plugin'),
                  subtitle: translate('Extensions and integrations'),
                  tiles: [
                    CustomSettingsTile(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 32,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CamelliaStateIllustration(
                              glyph: CamelliaGlyph.sliders,
                              size: 54,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              translate('No plugins installed'),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              translate(
                                'Installed extensions will appear here for configuration.',
                              ),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
            children: model.plugins.map((entry) => pluginCard(entry)).toList(),
          );
        },
      ),
    );
  }

  Widget pluginCard(PluginInfo plugin) {
    return ChangeNotifierProvider.value(
      value: plugin,
      child: Consumer<PluginInfo>(
        builder: (context, model, child) => DesktopSettingsCard(plugin: model),
      ),
    );
  }
}

class _Printer extends StatefulWidget {
  const _Printer();

  @override
  State<_Printer> createState() => _PrinterState();
}

class _PrinterState extends State<_Printer> {
  @override
  void dispose() {
    platformFFI.removeEventHandler('install-printer-res');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
      children: [outgoing(context), incoming(context)],
    );
  }

  Widget outgoing(BuildContext context) {
    final isSupportPrinterDriver =
        bind.mainGetCommonSync(key: 'is-support-printer-driver') == 'true';
    final installed = bind.mainIsInstalled();
    final isPrinterInstalled =
        bind.mainGetCommonSync(key: 'is-printer-installed') == 'true';

    Widget statusContent;
    if (!isSupportPrinterDriver) {
      statusContent = Text(translate('printer-os-requirement-tip'));
    } else if (!installed) {
      statusContent = Text(
        translate('printer-requires-installed-{$appName}-client-tip'),
      );
    } else if (!isPrinterInstalled) {
      final failedMsg = ''.obs;
      platformFFI.registerEventHandler(
        'install-printer-res',
        'install-printer-res',
        (evt) async {
          if (!mounted) return;
          if (evt['success'] as bool) {
            setState(() {});
          } else {
            failedMsg.value = evt['msg'] as String;
          }
        },
        replace: true,
      );
      statusContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Obx(
            () => failedMsg.value.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      formatUserFriendlyError(failedMsg.value),
                      style: TextStyle(
                        color: AppVisual.tone(context, AppTone.danger),
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      translate('printer-{$appName}-not-installed-tip'),
                    ),
                  ),
          ),
          GlassButton(
            variant: GlassButtonVariant.primary,
            minHeight: 38,
            icon: const Icon(Icons.print_rounded, size: 17),
            onPressed: () {
              failedMsg.value = '';
              bind.mainSetCommon(key: 'install-printer', value: '');
            },
            child: Text(translate('Install {$appName} Printer')),
          ),
        ],
      );
    } else {
      statusContent = Row(
        children: [
          GlassBadge(
            label: translate('Ready'),
            tone: GlassBadgeTone.online,
            showDot: true,
            compact: true,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(translate('printer-{$appName}-ready-tip'))),
        ],
      );
    }

    return SettingsGroup(
      title: translate('Outgoing Print Jobs'),
      subtitle: translate(
        'Manage local virtual printer driver for remote printing',
      ),
      tiles: [
        CustomSettingsTile(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: statusContent,
          ),
        ),
      ],
    );
  }

  Widget incoming(BuildContext context) {
    Future<void> onRadioChanged(String? value) async {
      if (value == null) return;
      await bind.mainSetLocalOption(
        key: kKeyPrinterIncomingJobAction,
        value: value,
      );
      if (mounted) setState(() {});
    }

    final PrinterOptions printerOptions = PrinterOptions.load();
    final incomingOptions = <(String, String)>[
      (kValuePrinterIncomingJobDismiss, translate('Dismiss')),
      (
        kValuePrinterIncomingJobDefault,
        translate('use-the-default-printer-tip'),
      ),
      (
        kValuePrinterIncomingJobSelected,
        translate('use-the-selected-printer-tip'),
      ),
    ];

    return SettingsGroup(
      title: translate('Incoming Print Jobs'),
      subtitle: translate(
        'Choose how incoming remote print jobs are handled on this device',
      ),
      tiles: [
        CustomSettingsTile(
          child: RadioGroup<String>(
            groupValue: printerOptions.action,
            onChanged: onRadioChanged,
            child: Column(
              children: [
                for (final item in incomingOptions)
                  _RadioRow<String>(
                    value: item.$1,
                    label: item.$2,
                    enabled: true,
                    onSelected: () => onRadioChanged(item.$1),
                  ),
              ],
            ),
          ),
        ),
        if (printerOptions.printerNames.isNotEmpty)
          CustomSettingsTile(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: ComboBox(
                initialKey: printerOptions.printerName,
                keys: printerOptions.printerNames,
                values: printerOptions.printerNames,
                enabled:
                    printerOptions.action == kValuePrinterIncomingJobSelected,
                onChanged: (value) async {
                  await bind.mainSetLocalOption(
                    key: kKeyPrinterSelected,
                    value: value,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
        _OptionSwitchTile(
          label: 'auto-print-tip',
          optionKey: kKeyPrinterAllowAutoPrint,
          isServer: false,
          enabled: printerOptions.action != kValuePrinterIncomingJobDismiss,
        ),
      ],
    );
  }
}

class _About extends StatefulWidget {
  const _About();

  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> {
  @override
  Widget build(BuildContext context) {
    return futureBuilder(
      future: () async {
        final license = await bind.mainGetLicense();
        final version = await bind.mainGetVersion();
        final buildDate = await bind.mainGetBuildDate();
        final fingerprint = await bind.mainGetFingerprint();
        return {
          'license': license,
          'version': version,
          'buildDate': buildDate,
          'fingerprint': fingerprint,
        };
      }(),
      hasData: (data) {
        final license = data['license'].toString();
        final appVer = data['version'].toString();
        final buildDate = data['buildDate'].toString();
        final fingerprint = data['fingerprint'].toString();
        final theme = Theme.of(context);
        final tokens = AppVisual.tokens(context);

        void copyDiagnostics() {
          final diagnostics = <String>[
            'Camellia Remote v$appVer',
            '${translate("Build Date")}: $buildDate',
            'OS: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
            if (!isWeb && fingerprint.isNotEmpty)
              '${translate("Fingerprint")}: $fingerprint',
          ].join('\n');
          Clipboard.setData(ClipboardData(text: diagnostics));
          showToast(translate('Copied diagnostics to clipboard'));
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: _kListViewBottomMargin),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kCardFixedWidth),
              child: Column(
                children: [
                  const SizedBox(height: 14),
                  GlassCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 26,
                    ),
                    child: Column(
                      children: [
                        const CamelliaBrandMark(size: 52, withPlate: true),
                        const SizedBox(height: 14),
                        Text(
                          'Camellia Remote',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        GlassBadge(
                          label: 'v$appVer',
                          tone: GlassBadgeTone.brand,
                          tabularNums: true,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          translate('Slogan_tip'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: tokens.muted,
                          ),
                        ),
                        const SizedBox(height: 16),
                        GlassButton(
                          variant: GlassButtonVariant.secondary,
                          minHeight: 36,
                          icon: const Icon(CamelliaIcons.copy, size: 15),
                          onPressed: copyDiagnostics,
                          child: Text(translate('Copy Diagnostics')),
                        ),
                      ],
                    ),
                  ),
                  SettingsGroup(
                    title: translate('About'),
                    subtitle: translate(
                      'Build metadata, security fingerprint, and legal notices',
                    ),
                    tiles: [
                      SettingsTile(
                        leading: const Icon(Icons.info_outline_rounded),
                        title: Text(translate('Version')),
                        value: SelectableText(
                          appVer,
                          style: CamelliaTypography.tabular(
                            theme.textTheme.bodyMedium?.copyWith(
                              color: tokens.muted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.calendar_today_outlined),
                        title: Text(translate('Build Date')),
                        value: SelectableText(
                          buildDate,
                          style: CamelliaTypography.tabular(
                            theme.textTheme.bodyMedium?.copyWith(
                              color: tokens.muted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      if (!isWeb)
                        SettingsTile(
                          leading: const Icon(Icons.fingerprint_rounded),
                          title: Text(translate('Fingerprint')),
                          value: SelectableText(
                            fingerprint,
                            maxLines: 1,
                            style: CamelliaTypography.tabular(
                              const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                            ),
                          ),
                          trailing: GlassIconButton(
                            icon: CamelliaIcons.copy,
                            size: 32,
                            iconSize: 15,
                            tooltip: translate('Copy'),
                            onPressed: () => onCopyFingerprint(fingerprint),
                          ),
                        ),
                      SettingsTile(
                        leading: const Icon(Icons.privacy_tip_outlined),
                        title: Text(translate('Privacy Statement')),
                        trailing: const Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                        ),
                        onPressed: (_) {
                          launchUrlString(
                            'https://github.com/camellia-nexus/remote-client/blob/main/docs/privacy.md',
                          );
                        },
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.language_rounded),
                        title: Text(translate('Website')),
                        trailing: const Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                        ),
                        onPressed: (_) {
                          launchUrlString(
                            'https://github.com/camellia-nexus/remote-client',
                          );
                        },
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.copyright_rounded),
                        title: Text(
                          'Copyright © ${DateTime.now().year} Camellia Nexus',
                        ),
                        description: license.trim().isEmpty
                            ? null
                            : SelectableText(
                                license,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: tokens.muted,
                                ),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

//#endregion

//#region components

class _OptionSwitchTile extends AbstractSettingsTile {
  const _OptionSwitchTile({
    required this.label,
    required this.optionKey,
    this.description,
    this.update,
    this.reverse = false,
    this.enabled = true,
    this.fakeValue,
    this.isServer = true,
    this.trailing,
    this.optGetter,
    this.optSetter,
  });

  final String label;
  final String optionKey;
  final String? description;
  final Function(bool)? update;
  final bool reverse;
  final bool enabled;
  final bool? fakeValue;
  final bool isServer;
  final Widget? trailing;
  final bool Function()? optGetter;
  final Future<void> Function(String, bool)? optSetter;

  @override
  Widget build(BuildContext context) {
    return _OptionSwitchTileBody(
      label: label,
      optionKey: optionKey,
      description: description,
      update: update,
      reverse: reverse,
      enabled: enabled,
      fakeValue: fakeValue,
      isServer: isServer,
      trailing: trailing,
      optGetter: optGetter,
      optSetter: optSetter,
    );
  }
}

class _OptionSwitchTileBody extends StatefulWidget {
  const _OptionSwitchTileBody({
    required this.label,
    required this.optionKey,
    this.description,
    this.update,
    this.reverse = false,
    this.enabled = true,
    this.fakeValue,
    this.isServer = true,
    this.trailing,
    this.optGetter,
    this.optSetter,
  });

  final String label;
  final String optionKey;
  final String? description;
  final Function(bool)? update;
  final bool reverse;
  final bool enabled;
  final bool? fakeValue;
  final bool isServer;
  final Widget? trailing;
  final bool Function()? optGetter;
  final Future<void> Function(String, bool)? optSetter;

  @override
  State<_OptionSwitchTileBody> createState() => _OptionSwitchTileBodyState();
}

class _OptionSwitchTileBodyState extends State<_OptionSwitchTileBody> {
  bool _readOption() {
    final raw = widget.optGetter != null
        ? widget.optGetter!()
        : (widget.isServer
              ? mainGetBoolOptionSync(widget.optionKey)
              : mainGetLocalBoolOptionSync(widget.optionKey));
    return widget.reverse ? !raw : raw;
  }

  @override
  Widget build(BuildContext context) {
    final isOptFixed = isOptionFixed(widget.optionKey);
    final resolvedValue = widget.fakeValue ?? _readOption();
    final interactive =
        widget.fakeValue == null && widget.enabled && !isOptFixed;

    return SettingsTile.switchTile(
      title: Text(translate(widget.label)),
      description: widget.description == null
          ? null
          : Text(translate(widget.description!)),
      trailing: widget.trailing,
      enabled: interactive,
      initialValue: resolvedValue,
      onToggle: interactive
          ? (next) async {
              final target = widget.reverse ? !next : next;
              final setter =
                  widget.optSetter ??
                  (widget.isServer
                      ? mainSetBoolOption
                      : mainSetLocalBoolOption);
              await setter(widget.optionKey, target);
              final updatedRaw = widget.optGetter != null
                  ? widget.optGetter!()
                  : (widget.isServer
                        ? mainGetBoolOptionSync(widget.optionKey)
                        : mainGetLocalBoolOptionSync(widget.optionKey));
              if (mounted) setState(() {});
              widget.update?.call(updatedRaw);
            }
          : null,
    );
  }
}

class _RadioRow<T> extends StatelessWidget {
  const _RadioRow({
    required this.value,
    required this.label,
    required this.enabled,
    required this.onSelected,
  });

  final T value;
  final String label;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: enabled ? onSelected : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 14, 4),
            child: Row(
              children: [
                Radio<T>(
                  value: value,
                  enabled: enabled,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: disabledTextColor(context, enabled),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WaylandCard extends StatefulWidget {
  const WaylandCard({super.key});

  @override
  State<WaylandCard> createState() => _WaylandCardState();
}

class _WaylandCardState extends State<WaylandCard> {
  final restoreTokenKey = 'wayland-restore-token';
  static const _kClearShortcutsInhibitorEventKey =
      'clear-gnome-shortcuts-inhibitor-permission-res';
  final _clearShortcutsInhibitorFailedMsg = ''.obs;
  final showResetInhibitorPermission = false;

  @override
  void initState() {
    super.initState();
    if (showResetInhibitorPermission) {
      platformFFI.registerEventHandler(
        _kClearShortcutsInhibitorEventKey,
        _kClearShortcutsInhibitorEventKey,
        (evt) async {
          if (!mounted) return;
          if (evt['success'] == true) {
            setState(() {});
          } else {
            _clearShortcutsInhibitorFailedMsg.value =
                evt['msg'] as String? ?? 'Unknown error';
          }
        },
      );
    }
  }

  @override
  void dispose() {
    if (showResetInhibitorPermission) {
      platformFFI.unregisterEventHandler(
        _kClearShortcutsInhibitorEventKey,
        _kClearShortcutsInhibitorEventKey,
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return futureBuilder(
      future: bind.mainHandleWaylandScreencastRestoreToken(
        key: restoreTokenKey,
        value: 'get',
      ),
      hasData: (restoreToken) {
        final hasShortcutsPermission =
            showResetInhibitorPermission &&
            bind.mainGetCommonSync(
                  key: 'has-gnome-shortcuts-inhibitor-permission',
                ) ==
                'true';

        final tiles = <AbstractSettingsTile>[
          if (restoreToken.isNotEmpty) _buildClearScreenSelection(context),
          if (hasShortcutsPermission)
            _buildClearShortcutsInhibitorPermission(context),
        ];
        if (tiles.isEmpty) {
          return const Offstage();
        }
        return SettingsGroup(
          title: translate('Wayland'),
          subtitle: translate(
            'Manage Wayland screencast portal permissions and screen selection',
          ),
          tiles: tiles,
        );
      },
    );
  }

  AbstractSettingsTile _buildClearScreenSelection(BuildContext context) {
    Future<void> onConfirm() async {
      final msg = await bind.mainHandleWaylandScreencastRestoreToken(
        key: restoreTokenKey,
        value: 'clear',
      );
      gFFI.dialogManager.dismissAll();
      if (msg.isNotEmpty) {
        msgBox(
          gFFI.sessionId,
          'custom-nocancel',
          'Error',
          msg,
          '',
          gFFI.dialogManager,
        );
      } else {
        if (mounted) setState(() {});
      }
    }

    void showConfirmMsgBox() => msgBoxCommon(
      gFFI.dialogManager,
      'Confirmation',
      Text(translate('confirm_clear_Wayland_screen_selection_tip')),
      [
        dialogButton(
          'Cancel',
          onPressed: () => gFFI.dialogManager.dismissAll(),
          isOutline: true,
        ),
        dialogButton('OK', onPressed: onConfirm, isDestructive: true),
      ],
    );

    return SettingsTile(
      leading: const Icon(Icons.desktop_access_disabled_rounded),
      title: Text(translate('Clear Wayland screen selection')),
      description: Text(translate('clear_Wayland_screen_selection_tip')),
      trailing: GlassButton(
        variant: GlassButtonVariant.danger,
        minHeight: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        onPressed: showConfirmMsgBox,
        child: Text(translate('Clear')),
      ),
      onPressed: (_) => showConfirmMsgBox(),
    );
  }

  AbstractSettingsTile _buildClearShortcutsInhibitorPermission(
    BuildContext context,
  ) {
    void onConfirm() {
      _clearShortcutsInhibitorFailedMsg.value = '';
      bind.mainSetCommon(
        key: 'clear-gnome-shortcuts-inhibitor-permission',
        value: '',
      );
      gFFI.dialogManager.dismissAll();
    }

    void showConfirmMsgBox() => msgBoxCommon(
      gFFI.dialogManager,
      'Confirmation',
      Text(translate('confirm-clear-shortcuts-inhibitor-permission-tip')),
      [
        dialogButton(
          'Cancel',
          onPressed: () => gFFI.dialogManager.dismissAll(),
          isOutline: true,
        ),
        dialogButton('OK', onPressed: onConfirm, isDestructive: true),
      ],
    );

    return CustomSettingsTile(
      child: Column(
        children: [
          Obx(
            () => _clearShortcutsInhibitorFailedMsg.value.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        formatUserFriendlyError(
                          _clearShortcutsInhibitorFailedMsg.value,
                        ),
                        style: TextStyle(
                          color: AppVisual.tone(context, AppTone.danger),
                        ),
                      ),
                    ),
                  ),
          ),
          SettingsTile(
            leading: const Icon(CamelliaIcons.keyboard),
            title: Text(translate('Reset keyboard shortcuts permission')),
            description: Text(
              translate('clear-shortcuts-inhibitor-permission-tip'),
            ),
            trailing: GlassButton(
              variant: GlassButtonVariant.danger,
              minHeight: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              onPressed: showConfirmMsgBox,
              child: Text(translate('Reset')),
            ),
            onPressed: (_) => showConfirmMsgBox(),
          ),
        ],
      ),
    );
  }
}

Widget _lock(bool locked, String label, Function() onUnlock) {
  return Offstage(
    offstage: !locked,
    child: Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kCardFixedWidth),
          child: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              final isDark = theme.brightness == Brightness.dark;
              final accent = isDark
                  ? theme.colorScheme.secondary
                  : theme.colorScheme.primary;
              return GlassSurface(
                layer: CamelliaGlassLayer.floating,
                strokeWidth: 0.85,
                tintColor: accent.withValues(alpha: isDark ? 0.14 : 0.08),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(CamelliaIcons.lock, size: 18, color: accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            translate(label),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            translate(
                              'Unlock protected controls to modify security and service settings.',
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    GlassButton(
                      variant: GlassButtonVariant.primary,
                      minHeight: 38,
                      icon: const Icon(Icons.lock_open_rounded, size: 17),
                      onPressed: () async {
                        final unlockPin = bind.mainGetUnlockPin();
                        if (unlockPin.isEmpty || isUnlockPinDisabled()) {
                          final checked =
                              await callMainCheckSuperUserPermission();
                          if (checked) {
                            onUnlock();
                          }
                        } else {
                          checkUnlockPinDialog(onUnlock);
                        }
                      },
                      child: Text(translate(label)),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _CountDownButton extends StatefulWidget {
  const _CountDownButton({
    required this.text,
    required this.second,
    required this.onPressed,
  });

  final String text;
  final VoidCallback? onPressed;
  final int second;

  @override
  State<_CountDownButton> createState() => _CountDownButtonState();
}

class _CountDownButtonState extends State<_CountDownButton> {
  bool _isButtonDisabled = false;
  late int _countdownSeconds = widget.second;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdownTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdownSeconds <= 0) {
        setState(() {
          _isButtonDisabled = false;
        });
        timer.cancel();
      } else {
        setState(() {
          _countdownSeconds--;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GlassButton(
      variant: GlassButtonVariant.secondary,
      minHeight: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      onPressed: _isButtonDisabled
          ? null
          : () {
              widget.onPressed?.call();
              setState(() {
                _isButtonDisabled = true;
                _countdownSeconds = widget.second;
              });
              _startCountdownTimer();
            },
      child: Text(
        _isButtonDisabled ? '${_countdownSeconds}s' : translate(widget.text),
        style: _isButtonDisabled
            ? CamelliaTypography.tabular(const TextStyle())
            : null,
      ),
    );
  }
}

//#endregion
