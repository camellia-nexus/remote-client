import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/overlay.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/pages/install_page.dart';
import 'package:camellia_remote_app/desktop/pages/server_page.dart';
import 'package:camellia_remote_app/desktop/screen/desktop_file_transfer_screen.dart';
import 'package:camellia_remote_app/desktop/screen/desktop_view_camera_screen.dart';
import 'package:camellia_remote_app/desktop/screen/desktop_port_forward_screen.dart';
import 'package:camellia_remote_app/desktop/screen/desktop_remote_screen.dart';
import 'package:camellia_remote_app/desktop/screen/desktop_terminal_screen.dart';
import 'package:camellia_remote_app/desktop/widgets/refresh_wrapper.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'common.dart';
import 'consts.dart';
import 'mobile/pages/server_page.dart';
import 'mobile/widgets/deploy_dialog.dart';
import 'models/platform_model.dart';
import 'web/main_home_entry.dart';

import 'package:camellia_remote_app/plugin/handlers.dart'
    if (dart.library.html) 'package:camellia_remote_app/web/plugin/handlers.dart';

/// Basic window and launch properties.
int? kWindowId;
WindowType? kWindowType;
late List<String> kBootArgs;

Future<void> main(List<String> args) async {
  LogSanitizer.install();
  runZonedGuarded(() async {
    earlyAssert();
    WidgetsFlutterBinding.ensureInitialized();

    debugPrint("launch args: ${args.map(LogSanitizer.sanitize).toList()}");
    kBootArgs = List.from(args);

    if (!isDesktop) {
      runMobileApp();
      return;
    }
    // main window
    if (args.isNotEmpty && args.first == 'multi_window') {
      if (args.length < 3) {
        debugPrint(
          "Invalid multi_window arguments count: expected >= 3, got ${args.length}",
        );
        runMainApp(true);
        return;
      }
      final parsedWindowId = int.tryParse(args[1]);
      if (parsedWindowId == null) {
        debugPrint("Invalid multi_window windowId: ${args[1]}");
        runMainApp(true);
        return;
      }
      kWindowId = parsedWindowId;
      stateGlobal.setWindowId(kWindowId!);
      if (!isMacOS) {
        WindowController.fromWindowId(kWindowId!).showTitleBar(false);
      }
      Map<String, dynamic> argument;
      try {
        argument = args[2].isEmpty
            ? <String, dynamic>{}
            : (jsonDecode(args[2]) as Map<String, dynamic>);
      } catch (e) {
        debugPrint("Invalid multi_window argument payload: $e");
        argument = <String, dynamic>{};
      }
      int type = argument['type'] ?? -1;
      // to-do: No need to parse window id ?
      // Because stateGlobal.windowId is a global value.
      argument['windowId'] = kWindowId;
      kWindowType = type.windowType;
      switch (kWindowType) {
        case WindowType.RemoteDesktop:
          desktopType = DesktopType.remote;
          runMultiWindow(argument, kAppTypeDesktopRemote);
          break;
        case WindowType.FileTransfer:
          desktopType = DesktopType.fileTransfer;
          runMultiWindow(argument, kAppTypeDesktopFileTransfer);
          break;
        case WindowType.ViewCamera:
          desktopType = DesktopType.viewCamera;
          runMultiWindow(argument, kAppTypeDesktopViewCamera);
          break;
        case WindowType.PortForward:
          desktopType = DesktopType.portForward;
          runMultiWindow(argument, kAppTypeDesktopPortForward);
          break;
        case WindowType.Terminal:
          desktopType = DesktopType.terminal;
          runMultiWindow(argument, kAppTypeDesktopTerminal);
        default:
          break;
      }
    } else if (args.isNotEmpty && args.first == '--cm') {
      debugPrint("--cm started");
      desktopType = DesktopType.cm;
      await windowManager.ensureInitialized();
      runConnectionManagerScreen();
    } else if (args.contains('--install')) {
      runInstallPage();
    } else {
      desktopType = DesktopType.main;
      await windowManager.ensureInitialized();
      windowManager.setPreventClose(true);
      if (isMacOS) {
        disableWindowMovable(kWindowId);
      }
      runMainApp(true);
    }
  }, (error, stack) {
    debugPrint("Unhandled zone error: $error\n$stack");
  }, zoneSpecification: LogSanitizer.zoneSpecification());
}

Future<StartupResult> initEnv(String appType) async {
  // global shared preference
  final result = await platformFFI.init(appType);
  if (!result.isSuccess) {
    debugPrint('initEnv failed at stage ${result.stage}: ${result.error}');
    return result;
  }
  // global FFI, use this **ONLY** for global configuration
  // for convenience, use global FFI on mobile platform
  // focus on multi-ffi on desktop first
  await initGlobalFFI();
  // Hydrate persisted theme mode and aesthetic preset synchronously before UI mounts.
  MyTheme.hydrateFromStorage();
  // await Firebase.initializeApp();
  _registerEventHandler();
  // Update the system theme.
  updateSystemWindowTheme();
  return result;
}

void runMainApp(bool startService) async {
  // register uni links
  final startupResult = await initEnv(kAppTypeMain);
  if (!startupResult.isSuccess) {
    debugPrint('Fatal: runMainApp startup transaction failed: ${startupResult.error}');
    runApp(StartupErrorFallbackApp(
      stage: startupResult.stage.name,
      error: '${startupResult.error}',
    ));
    return;
  }
  // trigger connection status updater
  await bind.mainCheckConnectStatus();
  if (startService) {
    gFFI.serverModel.startService();
    bind.pluginSyncUi(syncTo: kAppTypeMain);
    bind.pluginListReload();
  }
  await Future.wait([gFFI.abModel.loadCache(), gFFI.groupModel.loadCache()]);
  gFFI.userModel.refreshCurrentUser();
  runApp(App());

  bool? alwaysOnTop;
  if (isDesktop) {
    alwaysOnTop =
        bind.mainGetBuildinOption(key: "main-window-always-on-top") == 'Y';
  }

  // Set window option.
  WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
    isMainWindow: true,
    alwaysOnTop: alwaysOnTop,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // Restore the location of the main window before window hide or show.
    await restoreWindowPosition(WindowType.Main);
    // Check the startup argument, if we successfully handle the argument, we keep the main window hidden.
    final handledByUniLinks = await initUniLinks();
    debugPrint("handled by uni links: $handledByUniLinks");
    final handledByBootArgs = await handleUriLink(cmdArgs: kBootArgs);
    if (handledByUniLinks || handledByBootArgs) {
      windowManager.hide();
    } else {
      windowManager.show();
      windowManager.focus();
      // Move registration of active main window here to prevent from async visible check.
      rustDeskWinManager.registerActiveWindow(kWindowMainId);
    }
    windowManager.setOpacity(1);
    windowManager.setTitle(getWindowName());
    await windowManager.setMinimumSize(const Size(600, 560));
    setResizable(true);
  });
}

void runMobileApp() async {
  final startupResult = await initEnv(kAppTypeMain);
  if (!startupResult.isSuccess) {
    debugPrint('Fatal: runMobileApp startup transaction failed: ${startupResult.error}');
    runApp(StartupErrorFallbackApp(
      stage: startupResult.stage.name,
      error: '${startupResult.error}',
    ));
    return;
  }
  if (isWeb) {
    await bind.mainCheckConnectStatus();
  }
  if (isAndroid) androidChannelInit();
  if (isAndroid) platformFFI.syncAndroidServiceAppDirConfigPath();
  draggablePositions.load();
  await Future.wait([gFFI.abModel.loadCache(), gFFI.groupModel.loadCache()]);
  gFFI.userModel.refreshCurrentUser();
  runApp(App());
  await initUniLinks();
}

void runMultiWindow(Map<String, dynamic> argument, String appType) async {
  final startupResult = await initEnv(appType);
  if (!startupResult.isSuccess) {
    debugPrint('Fatal: runMultiWindow startup transaction failed: ${startupResult.error}');
    return;
  }
  final title = getWindowName();
  // set prevent close to true, we handle close event manually
  WindowController.fromWindowId(kWindowId!).setPreventClose(true);
  if (isMacOS) {
    disableWindowMovable(kWindowId);
  }
  late Widget widget;
  switch (appType) {
    case kAppTypeDesktopRemote:
      draggablePositions.load();
      widget = DesktopRemoteScreen(params: argument);
      break;
    case kAppTypeDesktopFileTransfer:
      widget = DesktopFileTransferScreen(params: argument);
      break;
    case kAppTypeDesktopViewCamera:
      draggablePositions.load();
      widget = DesktopViewCameraScreen(params: argument);
      break;
    case kAppTypeDesktopPortForward:
      widget = DesktopPortForwardScreen(params: argument);
      break;
    case kAppTypeDesktopTerminal:
      widget = DesktopTerminalScreen(params: argument);
      break;
    default:
      // no such appType
      exit(0);
  }
  _runApp(title, widget, MyTheme.currentThemeMode());
  switch (appType) {
    case kAppTypeDesktopRemote:
      // If screen rect is set, the window will be moved to the target screen and then set fullscreen.
      if (argument['screen_rect'] == null) {
        // display can be used to control the offset of the window.
        await restoreWindowPosition(
          WindowType.RemoteDesktop,
          windowId: kWindowId!,
          peerId: argument['id'] as String?,
          display: argument['display'] as int?,
        );
      }
      break;
    case kAppTypeDesktopFileTransfer:
      await restoreWindowPosition(
        WindowType.FileTransfer,
        windowId: kWindowId!,
      );
      break;
    case kAppTypeDesktopViewCamera:
      // If screen rect is set, the window will be moved to the target screen and then set fullscreen.
      if (argument['screen_rect'] == null) {
        // display can be used to control the offset of the window.
        await restoreWindowPosition(
          WindowType.ViewCamera,
          windowId: kWindowId!,
          peerId: argument['id'] as String?,
          // FIXME: fix display index.
          display: argument['display'] as int?,
        );
      }
      break;
    case kAppTypeDesktopPortForward:
      await restoreWindowPosition(WindowType.PortForward, windowId: kWindowId!);
      break;
    case kAppTypeDesktopTerminal:
      await restoreWindowPosition(WindowType.Terminal, windowId: kWindowId!);
      break;
    default:
      // no such appType
      exit(0);
  }
  // show window from hidden status
  WindowController.fromWindowId(kWindowId!).show();
}

void runConnectionManagerScreen() async {
  final startupResult = await initEnv(kAppTypeConnectionManager);
  if (!startupResult.isSuccess) {
    debugPrint('Fatal: runConnectionManagerScreen startup transaction failed: ${startupResult.error}');
    return;
  }
  _runApp('', const DesktopServerPage(), MyTheme.currentThemeMode());
  final hide = await bind.cmGetConfig(name: "hide_cm") == 'true';
  gFFI.serverModel.hideCm = hide;
  if (hide) {
    await hideCmWindow(isStartup: true);
  } else {
    await showCmWindow(isStartup: true);
  }
  setResizable(false);
  // Start the uni links handler and redirect links to Native, not for Flutter.
  listenUniLinks(handleByFlutter: false);
}

bool _isCmReadyToShow = false;

showCmWindow({bool isStartup = false}) async {
  if (isStartup) {
    WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
      size: kConnectionManagerWindowSizeClosedChat,
      alwaysOnTop: true,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, null);
    bind.mainHideDock();
    await Future.wait([
      windowManager.show(),
      windowManager.focus(),
      windowManager.setOpacity(1),
    ]);
    // ensure initial window size to be changed
    await windowManager.setSizeAlignment(
      kConnectionManagerWindowSizeClosedChat,
      Alignment.topRight,
    );
    _isCmReadyToShow = true;
  } else if (_isCmReadyToShow) {
    if (await windowManager.getOpacity() != 1) {
      await windowManager.setOpacity(1);
      await windowManager.focus();
      await windowManager.minimize(); //needed
      await windowManager.setSizeAlignment(
        kConnectionManagerWindowSizeClosedChat,
        Alignment.topRight,
      );
      windowOnTop(null);
    }
  }
}

hideCmWindow({bool isStartup = false}) async {
  if (isStartup) {
    WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
      size: kConnectionManagerWindowSizeClosedChat,
    );
    windowManager.setOpacity(0);
    await windowManager.waitUntilReadyToShow(windowOptions, null);
    bind.mainHideDock();
    await windowManager.minimize();
    await windowManager.hide();
    _isCmReadyToShow = true;
  } else if (_isCmReadyToShow) {
    if (await windowManager.getOpacity() != 0) {
      await windowManager.setOpacity(0);
      bind.mainHideDock();
      await windowManager.minimize();
      await windowManager.hide();
    }
  }
}

void _runApp(String title, Widget home, ThemeMode themeMode) {
  final botToastBuilder = BotToastInit();
  runApp(
    RefreshWrapper(
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([
          MyTheme.themeNotifier,
          MyTheme.themeStyleNotifier,
        ]),
        builder: (context, _) {
          final pref = MyTheme.themeNotifier.value;
          final resolvedMode = switch (pref) {
            CamelliaThemePreference.light => ThemeMode.light,
            CamelliaThemePreference.dark ||
            CamelliaThemePreference.midnight => ThemeMode.dark,
            CamelliaThemePreference.system => ThemeMode.system,
          };
          final lightTheme = MyTheme.lightTheme;
          final darkTheme = pref == CamelliaThemePreference.midnight
              ? MyTheme.midnightTheme
              : MyTheme.darkTheme;
          return GetMaterialApp(
            navigatorKey: globalKey,
            debugShowCheckedModeBanner: false,
            title: title,
            theme: lightTheme,
            darkTheme: darkTheme,
            themeMode: resolvedMode,
            scrollBehavior: const CamelliaScrollBehavior(),
            home: home,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: supportedLocales,
            navigatorObservers: [
              // FirebaseAnalyticsObserver(analytics: analytics),
              BotToastNavigatorObserver(),
            ],
            builder: (context, child) {
              final platformBrightness = MediaQuery.platformBrightnessOf(
                context,
              );
              final activeTheme =
                  resolvedMode == ThemeMode.light ||
                      (resolvedMode == ThemeMode.system &&
                          platformBrightness == Brightness.light)
                  ? lightTheme
                  : darkTheme;
              final scaledChild = _keepScaleBuilder(context, child);
              return AnimatedTheme(
                data: activeTheme,
                duration: Duration.zero,
                child: Builder(
                  builder: (themedContext) =>
                      botToastBuilder(themedContext, scaledChild),
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

class StartupErrorFallbackApp extends StatelessWidget {
  const StartupErrorFallbackApp({
    super.key,
    required this.stage,
    required this.error,
  });

  final String stage;
  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0B0E),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: const Color(0xFF12141A),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 0.85,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 32,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.28),
                        width: 0.85,
                      ),
                    ),
                    child: const Icon(
                      Icons.error_outline_rounded,
                      color: Color(0xFFEF4444),
                      size: 26,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    translate('Startup Error'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${translate('Stage')}: $stage',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.65),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 0.85,
                      ),
                    ),
                    child: Text(
                      error,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
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

void runInstallPage() async {
  await windowManager.ensureInitialized();
  final startupResult = await initEnv(kAppTypeMain);
  if (!startupResult.isSuccess) {
    debugPrint('Fatal: runInstallPage startup transaction failed: ${startupResult.error}');
    return;
  }
  _runApp('', const InstallPage(), MyTheme.currentThemeMode());
  WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
    size: Size(800, 600),
    center: true,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    windowManager.show();
    windowManager.focus();
    windowManager.setOpacity(1);
    windowManager.setAlignment(Alignment.center); // ensure
  });
}

WindowOptions getHiddenTitleBarWindowOptions({
  bool isMainWindow = false,
  Size? size,
  bool center = false,
  bool? alwaysOnTop,
}) {
  var defaultTitleBarStyle = TitleBarStyle.hidden;
  return WindowOptions(
    size: size,
    center: center,
    backgroundColor: (isMacOS && isMainWindow) ? null : Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: defaultTitleBarStyle,
    alwaysOnTop: alwaysOnTop,
  );
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateOrientation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    final userPreference = MyTheme.getThemeModePreference();
    if (userPreference != ThemeMode.system) return;
    final systemIsDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    final ThemeMode to = systemIsDark ? ThemeMode.dark : ThemeMode.light;
    if (mounted) {
      setState(() {});
    }
    // Synchronize the window theme of the system.
    updateSystemWindowTheme();
    if (desktopType == DesktopType.main) {
      bind.mainChangeTheme(dark: to.toShortString());
    }
  }

  @override
  void didChangeMetrics() {
    _updateOrientation();
  }

  void _updateOrientation() {
    if (isDesktop) return;

    // Don't use `MediaQuery.of(context).orientation` in `didChangeMetrics()`,
    // my test (Flutter 3.19.6, Android 14) is always the reverse value.
    // https://github.com/flutter/flutter/issues/60899
    // stateGlobal.isPortrait.value =
    //     MediaQuery.of(context).orientation == Orientation.portrait;

    final orientation = View.of(context).physicalSize.aspectRatio > 1
        ? Orientation.landscape
        : Orientation.portrait;
    stateGlobal.isPortrait.value = orientation == Orientation.portrait;
  }

  @override
  Widget build(BuildContext context) {
    // final analytics = FirebaseAnalytics.instance;
    final botToastBuilder = BotToastInit();
    return RefreshWrapper(
      builder: (context) {
        return MultiProvider(
          providers: [
            // global configuration
            // use session related FFI when in remote control or file transfer page
            ChangeNotifierProvider.value(value: gFFI.ffiModel),
            ChangeNotifierProvider.value(value: gFFI.imageModel),
            ChangeNotifierProvider.value(value: gFFI.cursorModel),
            ChangeNotifierProvider.value(value: gFFI.canvasModel),
            ChangeNotifierProvider.value(value: gFFI.peerTabModel),
          ],
          child: ListenableBuilder(
            listenable: Listenable.merge([
              MyTheme.themeNotifier,
              MyTheme.themeStyleNotifier,
            ]),
            builder: (context, _) {
              final pref = MyTheme.themeNotifier.value;
              final resolvedMode = switch (pref) {
                CamelliaThemePreference.light => ThemeMode.light,
                CamelliaThemePreference.dark ||
                CamelliaThemePreference.midnight => ThemeMode.dark,
                CamelliaThemePreference.system => ThemeMode.system,
              };
              final lightTheme = MyTheme.lightTheme;
              final darkTheme = pref == CamelliaThemePreference.midnight
                  ? MyTheme.midnightTheme
                  : MyTheme.darkTheme;
              return GetMaterialApp(
                navigatorKey: globalKey,
                debugShowCheckedModeBanner: false,
                title: buildMainAppTitle(bind.mainGetAppNameSync()),
                theme: lightTheme,
                darkTheme: darkTheme,
                themeMode: resolvedMode,
                scrollBehavior: const CamelliaScrollBehavior(),
                home: isDesktop ? const DesktopHomePage() : buildMainHomePage(),
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: supportedLocales,
                navigatorObservers: [
                  // FirebaseAnalyticsObserver(analytics: analytics),
                  BotToastNavigatorObserver(),
                ],
                builder: isAndroid
                    ? (context, child) {
                        final platformBrightness =
                            MediaQuery.platformBrightnessOf(context);
                        final activeTheme =
                            resolvedMode == ThemeMode.light ||
                                (resolvedMode == ThemeMode.system &&
                                    platformBrightness == Brightness.light)
                            ? lightTheme
                            : darkTheme;
                        return AnimatedTheme(
                          data: activeTheme,
                          duration: Duration.zero,
                          child: Builder(
                            builder: (themedContext) => AccessibilityListener(
                              child: botToastBuilder(
                                themedContext,
                                child ?? const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        );
                      }
                    : (context, child) {
                        final platformBrightness =
                            MediaQuery.platformBrightnessOf(context);
                        final activeTheme =
                            resolvedMode == ThemeMode.light ||
                                (resolvedMode == ThemeMode.system &&
                                    platformBrightness == Brightness.light)
                            ? lightTheme
                            : darkTheme;
                        Widget current = _keepScaleBuilder(context, child);
                        if ((isDesktop && desktopType == DesktopType.main) ||
                            isWebDesktop) {
                          current = keyListenerBuilder(context, current);
                        }
                        if (isWeb) {
                          current = FocusTraversalGroup(
                            policy: WidgetOrderTraversalPolicy(),
                            child: current,
                          );
                        }
                        final framedChild = isLinux
                            ? buildVirtualWindowFrame(context, current)
                            : workaroundWindowBorder(context, current);
                        return AnimatedTheme(
                          data: activeTheme,
                          duration: Duration.zero,
                          child: Builder(
                            builder: (themedContext) =>
                                botToastBuilder(themedContext, framedChild),
                          ),
                        );
                      },
              );
            },
          ),
        );
      },
    );
  }
}

Widget _keepScaleBuilder(BuildContext context, Widget? child) {
  return child ?? const SizedBox.shrink();
}

void _registerEventHandler() {
  if (isDesktop && desktopType != DesktopType.main) {
    platformFFI.registerEventHandler('theme', 'theme', (evt) async {
      String? dark = evt['dark'];
      if (dark != null) {
        try {
          final style = bind.mainGetLocalOption(key: 'theme_style');
          MyTheme.themeStyleNotifier.value = CamelliaThemeStyle.fromString(style);
        } catch (_) {}
        await MyTheme.changeThemePreference(
          MyTheme.themePreferenceFromString(dark),
        );
      }
    });
    platformFFI.registerEventHandler('language', 'language', (_) async {
      reloadAllWindows();
    });
  }
  // Register native handlers.
  if (isDesktop) {
    HardwareKeyboard.instance.addHandler((KeyEvent event) {
      if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
          event.logicalKey == LogicalKeyboardKey.shiftRight) {
        if (event is KeyDownEvent) {
          gFFI.peerTabModel.setShiftDown(true);
        } else if (event is KeyUpEvent) {
          gFFI.peerTabModel.setShiftDown(false);
        }
      }
      return false;
    });
    platformFFI.registerEventHandler('native_ui', 'native_ui', (evt) async {
      NativeUiHandler.instance.onEvent(evt);
    });
  }
  if (isAndroid) {
    platformFFI.registerEventHandler(
      'android_needs_deploy',
      'android_needs_deploy',
      (_) async {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          showDeployPromptDialog();
        });
      },
    );
  }
}

Widget keyListenerBuilder(BuildContext context, Widget? child) {
  return child ?? Container();
}
