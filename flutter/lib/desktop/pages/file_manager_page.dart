import 'dart:async';
import 'dart:math';

import 'package:camellia_remote_app/common/widgets/extended_text_compat.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/desktop/widgets/dragable_divider.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:camellia_remote_app/desktop/widgets/list_search_action_listener.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/models/file_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:camellia_remote_app/web/dummy.dart'
    if (dart.library.html) 'package:camellia_remote_app/web/web_unique.dart';
import 'file_manager_drop_stub.dart'
    if (dart.library.io) 'file_manager_drop_native.dart';

import '../../consts.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../common/shared_state.dart';
import '../widgets/popup_menu.dart';

/// status of location bar
enum LocationStatus {
  /// normal bread crumb bar
  bread,

  /// show path text field
  pathLocation,

  /// show file search bar text field
  fileSearchBar,
}

/// The status of currently focused scope of the mouse
enum MouseFocusScope {
  /// Mouse is in local field.
  local,

  /// Mouse is in remote field.
  remote,

  /// Mouse is not in local field, remote neither.
  none,
}

class FileManagerPage extends StatefulWidget {
  FileManagerPage({
    Key? key,
    required this.id,
    required this.password,
    required this.isSharedPassword,
    this.tabController,
    this.connToken,
    this.forceRelay,
  }) : super(key: key);
  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? connToken;
  final DesktopTabController? tabController;
  final SimpleWrapper<State<FileManagerPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _FileManagerPageState)._ffi;

  @override
  State<StatefulWidget> createState() {
    final state = _FileManagerPageState();
    _lastState.value = state;
    return state;
  }
}

class _FileManagerPageState extends State<FileManagerPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _mouseFocusScope = Rx<MouseFocusScope>(MouseFocusScope.none);

  final _dropMaskVisible = false.obs;
  final _transferDrawerExpanded = false.obs;
  final _transferScrollController = ScrollController();
  final _overlayKeyState = OverlayKeyState();
  final _uniqueKey = UniqueKey();

  late FFI _ffi;

  FileModel get model => _ffi.fileModel;
  JobController get jobController => model.jobController;

  @override
  void initState() {
    super.initState();
    _ffi = FFI(null);
    _ffi.start(
      widget.id,
      isFileTransfer: true,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      connToken: widget.connToken,
      forceRelay: widget.forceRelay,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ffi.dialogManager.showLoading(
        translate('Connecting...'),
        onCancel: closeConnection,
      );
    });
    if (Get.isRegistered<FFI>(tag: 'ft_${widget.id}')) {
      Get.delete<FFI>(tag: 'ft_${widget.id}', force: true);
    }
    Get.put<FFI>(_ffi, tag: 'ft_${widget.id}');
    WakelockManager.enable(_uniqueKey);
    if (isWeb) {
      _ffi.ffiModel.updateEventListener(_ffi.sessionId, widget.id);
    }
    debugPrint("File manager page init success with id ${widget.id}");
    _ffi.dialogManager.setOverlayState(_overlayKeyState);
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController?.onSelected?.call(widget.id);
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _transferScrollController.dispose();
    final ffi = _ffi;
    model.close().whenComplete(() {
      ffi.close();
      ffi.dialogManager.dismissAll();
      WakelockManager.disable(_uniqueKey);
      deleteIfMatching<FFI>('ft_${widget.id}', ffi);
    });
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      jobController.jobTable.refresh();
    }
  }

  Widget willPopScope(Widget child) {
    if (isWeb) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          clientClose(_ffi.sessionId, _ffi);
        },
        child: child,
      );
    } else {
      return child;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Overlay(
      key: _overlayKeyState.key,
      initialEntries: [
        OverlayEntry(
          builder: (_) {
            return willPopScope(
              Scaffold(
                backgroundColor: Colors.transparent,
                body: CamelliaBackdrop(
                  child: Column(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                          child: Row(
                            children: [
                              if (!isWeb) ...[
                                Expanded(
                                  child: dropArea(
                                    FileManagerView(
                                      model.localController,
                                      _ffi,
                                      _mouseFocusScope,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: dropArea(
                                  FileManagerView(
                                    model.remoteController,
                                    _ffi,
                                    _mouseFocusScope,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      _buildFloatingTransferDrawer(context),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget dropArea(FileManagerView fileView) {
    return DropTarget(
      onDragDone: (detail) {
        _dropMaskVisible.value = false;
        handleDragDone(detail, fileView.controller.isLocal);
      },
      onDragEntered: (enter) {
        _dropMaskVisible.value = true;
      },
      onDragExited: (exit) {
        _dropMaskVisible.value = false;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          fileView,
          Obx(() {
            if (!_dropMaskVisible.value) return const SizedBox.shrink();
            final theme = Theme.of(context);
            final accent = theme.brightness == Brightness.dark
                ? theme.colorScheme.secondary
                : theme.colorScheme.primary;
            return IgnorePointer(
              child: GlassSurface(
                layer: CamelliaGlassLayer.modal,
                tintColor: accent.withValues(alpha: 0.16),
                borderTopColor: accent.withValues(alpha: 0.85),
                borderBottomColor: accent.withValues(alpha: 0.55),
                strokeWidth: 1.6,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          CamelliaIcons.upload,
                          size: 28,
                          color: accent,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        translate('Drop files here to transfer'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  /// Collapsible bottom floating Liquid Glass transfer queue drawer.
  Widget _buildFloatingTransferDrawer(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    Widget getDirectionIcon(JobProgress job) {
      switch (job.type) {
        case JobType.deleteDir:
        case JobType.deleteFile:
          return Icon(CamelliaIcons.trash, size: 17, color: glass.statusAlert);
        default:
          return Transform.rotate(
            angle: isWeb
                ? (job.isRemoteToLocal ? pi / 2 : pi / 2 * 3)
                : (job.isRemoteToLocal ? pi : 0),
            child: Icon(
              CamelliaIcons.arrowForward,
              size: 16,
              color: job.state == JobState.done
                  ? glass.statusOnline
                  : accent,
            ),
          );
      }
    }

    return Obx(() {
      final jobs = jobController.jobTable;
      final activeCount = jobs
          .where(
            (j) => j.state == JobState.inProgress || j.state == JobState.paused,
          )
          .length;
      final expanded = _transferDrawerExpanded.value;

      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: GlassSurface(
          layer: CamelliaGlassLayer.modal,
          elevated: expanded,
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                  onTap: () => _transferDrawerExpanded.value = !expanded,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(CamelliaIcons.transfer, size: 18, color: accent),
                        const SizedBox(width: 10),
                        Text(
                          translate('Transfer Queue'),
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 10),
                        GlassBadge(
                          label: jobs.isEmpty
                              ? translate('Idle')
                              : activeCount > 0
                              ? '$activeCount / ${jobs.length}'
                              : '${jobs.length}',
                          tone: activeCount > 0
                              ? GlassBadgeTone.connecting
                              : jobs.isNotEmpty
                              ? GlassBadgeTone.online
                              : GlassBadgeTone.neutral,
                          showDot: activeCount > 0,
                          pulse: activeCount > 0,
                          tabularNums: true,
                          compact: true,
                        ),
                        const Spacer(),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_up_rounded,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: CamelliaMotion.resolve(context, CamelliaMotion.state),
                curve: CamelliaMotion.springSnappy,
                child: !expanded
                    ? const SizedBox.shrink()
                    : SizedBox(
                        height: jobs.isEmpty ? 76 : 210,
                        child: Column(
                          children: [
                            Divider(
                              height: 1,
                              thickness: 0.8,
                              color: glass.specularBottom,
                            ),
                            Expanded(
                              child: jobs.isEmpty
                                  ? Center(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            CamelliaIcons.transfer,
                                            size: 20,
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            translate(
                                              'No transfers in progress',
                                            ),
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : ListView.separated(
                                      controller: _transferScrollController,
                                      padding: const EdgeInsets.all(10),
                                      itemCount: jobs.length,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(height: 6),
                                      itemBuilder: (context, index) {
                                        final item = jobs[index];
                                        final status = item.getStatus();
                                        final showProgress =
                                            item.type == JobType.transfer &&
                                            item.effectiveTotalSize > 0 &&
                                            (item.state ==
                                                    JobState.inProgress ||
                                                item.state == JobState.done ||
                                                item.state == JobState.paused);
                                        return GlassSurface(
                                          layer: CamelliaGlassLayer.floating,
                                          showShadow: false,
                                          enableBlur: false,
                                          borderRadius: BorderRadius.circular(
                                            CamelliaRadius.control,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          child: Row(
                                            children: [
                                              getDirectionIcon(item),
                                              const SizedBox(width: 10),
                                              Icon(
                                                CamelliaIcons.fileTypeIcon(
                                                  item.jobName,
                                                ),
                                                size: 18,
                                                color:
                                                    CamelliaIcons.fileTypeColor(
                                                      context,
                                                      item.jobName,
                                                    ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Tooltip(
                                                      waitDuration:
                                                          const Duration(
                                                            milliseconds: 500,
                                                          ),
                                                      message: item.jobName,
                                                      child: ExtendedText(
                                                        item.jobName,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        overflowWidget:
                                                            TextOverflowWidget(
                                                              child: const Text(
                                                                "...",
                                                              ),
                                                              position:
                                                                  TextOverflowPosition
                                                                      .start,
                                                            ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      status,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style:
                                                          CamelliaTypography.tabular(
                                                            theme
                                                                .textTheme
                                                                .labelSmall
                                                                ?.copyWith(
                                                                  color: theme
                                                                      .colorScheme
                                                                      .onSurfaceVariant,
                                                                ),
                                                          ),
                                                    ),
                                                    if (showProgress) ...[
                                                      const SizedBox(height: 6),
                                                      Row(
                                                        children: [
                                                          Expanded(
                                                            child: ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    CamelliaRadius
                                                                        .pill,
                                                                  ),
                                                              child: LinearProgressIndicator(
                                                                value: item
                                                                    .percent
                                                                    .clamp(
                                                                      0.0,
                                                                      1.0,
                                                                    ),
                                                                minHeight: 6,
                                                                backgroundColor:
                                                                    theme
                                                                        .colorScheme
                                                                        .surfaceContainerHighest,
                                                                valueColor:
                                                                    AlwaysStoppedAnimation<
                                                                      Color
                                                                    >(
                                                                      item.state ==
                                                                              JobState.done
                                                                          ? glass.statusOnline
                                                                          : accent,
                                                                    ),
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                          if (item.speedText.isNotEmpty) ...[
                                                            ThroughputSparkline(
                                                              speeds: item.speedHistory,
                                                              color: accent,
                                                            ),
                                                            const SizedBox(width: 4),
                                                            Text(
                                                              item.speedText,
                                                              style: CamelliaTypography.tabular(
                                                                theme.textTheme.labelSmall?.copyWith(
                                                                  color: theme.colorScheme.onSurfaceVariant,
                                                                  fontSize: 10,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(width: 6),
                                                          ],
                                                          Text(
                                                            item.percentText,
                                                            style:
                                                                CamelliaTypography.tabular(
                                                                  theme
                                                                      .textTheme
                                                                      .labelSmall
                                                                      ?.copyWith(
                                                                        fontWeight:
                                                                            FontWeight
                                                                                .w600,
                                                                      ),
                                                                ),
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              if (item.state == JobState.done)
                                                Icon(
                                                  CamelliaIcons.check,
                                                  size: 18,
                                                  color: glass.statusOnline,
                                                ),
                                              if (item.state == JobState.inProgress)
                                                GlassIconButton(
                                                  icon: Icons.pause_rounded,
                                                  size: 32,
                                                  iconSize: 16,
                                                  tooltip: translate("Pause"),
                                                  onPressed: () {
                                                    jobController.pauseJob(item.id);
                                                  },
                                                ),
                                              if (item.state == JobState.paused)
                                                GlassIconButton(
                                                  icon: CamelliaIcons.refresh,
                                                  size: 32,
                                                  iconSize: 16,
                                                  tooltip: translate("Resume"),
                                                  onPressed: () {
                                                    jobController.resumeJob(
                                                      item.id,
                                                    );
                                                  },
                                                ),
                                              const SizedBox(width: 4),
                                              GlassIconButton(
                                                icon: CamelliaIcons.close,
                                                size: 32,
                                                iconSize: 16,
                                                tooltip: translate("Delete"),
                                                accentColor: glass.statusAlert,
                                                onPressed: () {
                                                  jobController.cancelJob(item.id);
                                                  jobController.jobTable.removeWhere(
                                                    (j) => j.id == item.id,
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> handleDragDone(DropDoneDetails details, bool isLocal) async {
    if (isLocal) {
      // ignore local
      return;
    }
    if (isWeb) {
      final files = <Map<String, dynamic>>[];
      for (final file in details.files) {
        files.add({
          'uri': file.path,
          'name': file.name,
          'mime_type': file.mimeType ?? '',
          'last_modified': (await file.lastModified()).millisecondsSinceEpoch,
        });
      }
      if (files.isNotEmpty) {
        await webRegisterDroppedFiles(files: files);
      }
      return;
    }
    final items = await buildDroppedItems(details.files, isLocal: false);
    final otherSideData = model.localController.directoryData();
    await model.remoteController.sendFiles(items, otherSideData);
  }
}

class FileManagerView extends StatefulWidget {
  final FileController controller;
  final FFI _ffi;
  final Rx<MouseFocusScope> _mouseFocusScope;

  FileManagerView(this.controller, this._ffi, this._mouseFocusScope);

  @override
  State<StatefulWidget> createState() => _FileManagerViewState();
}

class _FileManagerViewState extends State<FileManagerView> {
  final _locationStatus = LocationStatus.bread.obs;
  final _locationNode = FocusNode();
  final _locationBarKey = GlobalKey();
  final _searchText = "".obs;
  final _breadCrumbScroller = ScrollController();
  final _keyboardNode = FocusNode();
  final _listSearchBuffer = TimeoutStringBuffer();
  final _nameColWidth = 0.0.obs;
  final _modifiedColWidth = 0.0.obs;
  final _sizeColWidth = 0.0.obs;
  final _fileListScrollController = ScrollController();
  final _pathInputController = TextEditingController();
  final _globalHeaderKey = GlobalKey();

  /// [_lastClickTime], [_lastClickEntry] help to handle double click
  var _lastClickTime =
      DateTime.now().millisecondsSinceEpoch - bind.getDoubleClickTime() - 1000;
  Entry? _lastClickEntry;

  double? _windowWidthPrev;
  double _fileTransferMinimumWidth = 0.0;

  FileController get controller => widget.controller;
  bool get isLocal => widget.controller.isLocal;
  FFI get _ffi => widget._ffi;
  SelectedItems get selectedItems => controller.selectedItems;

  StreamSubscription<FileDirectory>? _directorySubscription;

  @override
  void initState() {
    super.initState();
    // register location listener
    _locationNode.addListener(onLocationFocusChanged);
    _directorySubscription =
        controller.directory.listen((e) => breadCrumbScrollToEnd());
  }

  @override
  void dispose() {
    _directorySubscription?.cancel();
    _directorySubscription = null;
    _locationNode.removeListener(onLocationFocusChanged);
    _locationNode.dispose();
    _keyboardNode.dispose();
    _breadCrumbScroller.dispose();
    _fileListScrollController.dispose();
    _pathInputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _handleColumnPorportions();
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          headTools(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: MouseRegion(
                    onEnter: (evt) {
                      widget._mouseFocusScope.value = isLocal
                          ? MouseFocusScope.local
                          : MouseFocusScope.remote;
                      _keyboardNode.requestFocus();
                    },
                    onExit: (evt) =>
                        widget._mouseFocusScope.value = MouseFocusScope.none,
                    child: _buildFileList(context, _fileListScrollController),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _handleColumnPorportions() {
    final windowWidthNow = MediaQuery.sizeOf(context).width;
    if (_windowWidthPrev == null) {
      _windowWidthPrev = windowWidthNow;
      final defaultColumnWidth = windowWidthNow * 0.115;
      _fileTransferMinimumWidth = defaultColumnWidth / 3;
      _nameColWidth.value = defaultColumnWidth;
      _modifiedColWidth.value = defaultColumnWidth;
      _sizeColWidth.value = defaultColumnWidth;
    }

    if (_windowWidthPrev != windowWidthNow) {
      final difference = windowWidthNow / _windowWidthPrev!;
      _windowWidthPrev = windowWidthNow;
      _fileTransferMinimumWidth *= difference;
      _nameColWidth.value *= difference;
      _modifiedColWidth.value *= difference;
      _sizeColWidth.value *= difference;
    }
  }

  void onLocationFocusChanged() {
    debugPrint("focus changed on local");
    if (_locationNode.hasFocus) {
      // ignore
    } else {
      // lost focus, change to bread
      if (_locationStatus.value != LocationStatus.fileSearchBar) {
        _locationStatus.value = LocationStatus.bread;
      }
    }
  }

  Widget headTools() {
    var uploadButtonTapPosition = RelativeRect.fill;
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final RxBool isUploadFolder =
        (bind.mainGetLocalOption(key: 'upload-folder-button') == 'Y').obs;
    return Column(
      children: [
        // Pane header
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: accent.withValues(alpha: 0.14),
                ),
                alignment: Alignment.center,
                child: FutureBuilder<String>(
                  future: bind.sessionGetPlatform(
                    sessionId: _ffi.sessionId,
                    isRemote: !isLocal,
                  ),
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                      return CamelliaIcons.platformBadge(
                        snapshot.data!,
                        size: 22,
                        color: accent,
                      );
                    }
                    return SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isLocal
                      ? translate("Local Computer")
                      : translate("Remote Computer"),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              GlassBadge(
                label: isLocal ? translate('Local') : translate('Remote'),
                tone: isLocal ? GlassBadgeTone.brand : GlassBadgeTone.encrypted,
                compact: true,
              ),
            ],
          ),
        ),
        // Navigation + breadcrumb bar
        Row(
          children: [
            GlassIconButton(
              icon: CamelliaIcons.arrowBack,
              size: 34,
              iconSize: 17,
              tooltip: translate('Back'),
              onPressed: () {
                selectedItems.clear();
                controller.goBack();
              },
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              icon: CamelliaIcons.arrowUp,
              size: 34,
              iconSize: 17,
              tooltip: translate('Parent directory'),
              onPressed: () {
                selectedItems.clear();
                controller.goToParentDirectory();
              },
            ),
            const SizedBox(width: 6),
            Expanded(
              child: GlassSurface(
                layer: CamelliaGlassLayer.floating,
                showShadow: false,
                enableBlur: false,
                borderRadius: BorderRadius.circular(CamelliaRadius.control),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2.5,
                ),
                child: GestureDetector(
                  onTap: () {
                    _locationStatus.value =
                        _locationStatus.value == LocationStatus.bread
                        ? LocationStatus.pathLocation
                        : LocationStatus.bread;
                    Future.delayed(Duration.zero, () {
                      if (_locationStatus.value ==
                          LocationStatus.pathLocation) {
                        _locationNode.requestFocus();
                      }
                    });
                  },
                  child: Obx(
                    () => Row(
                      children: [
                        Expanded(
                          child: _locationStatus.value == LocationStatus.bread
                              ? buildBread()
                              : buildPathLocation(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Obx(() {
              switch (_locationStatus.value) {
                case LocationStatus.bread:
                  return GlassIconButton(
                    icon: CamelliaIcons.search,
                    size: 34,
                    iconSize: 17,
                    tooltip: translate('Search'),
                    onPressed: () {
                      _locationStatus.value = LocationStatus.fileSearchBar;
                      Future.delayed(
                        Duration.zero,
                        () => _locationNode.requestFocus(),
                      );
                    },
                  );
                case LocationStatus.pathLocation:
                  return GlassIconButton(
                    icon: CamelliaIcons.close,
                    size: 34,
                    iconSize: 17,
                    tooltip: translate('Close'),
                    onPressed: () {
                      _locationStatus.value = LocationStatus.bread;
                    },
                  );
                case LocationStatus.fileSearchBar:
                  return GlassIconButton(
                    icon: CamelliaIcons.close,
                    size: 34,
                    iconSize: 17,
                    tooltip: translate('Clear'),
                    onPressed: () {
                      onSearchText("", isLocal);
                      _locationStatus.value = LocationStatus.bread;
                    },
                  );
              }
            }),
            const SizedBox(width: 4),
            GlassIconButton(
              icon: CamelliaIcons.refresh,
              size: 34,
              iconSize: 17,
              tooltip: translate('Refresh File'),
              onPressed: () {
                controller.refresh();
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Action row
        Row(
          textDirection: isLocal ? TextDirection.ltr : TextDirection.rtl,
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: isLocal
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.end,
                children: [
                  GlassIconButton(
                    icon: CamelliaIcons.home,
                    size: 34,
                    iconSize: 17,
                    tooltip: translate('Home'),
                    onPressed: () {
                      controller.goToHomeDirectory();
                    },
                  ),
                  const SizedBox(width: 4),
                  GlassIconButton(
                    icon: CamelliaIcons.folderNew,
                    size: 34,
                    iconSize: 17,
                    tooltip: translate('Create Folder'),
                    onPressed: () async {
                      final name = TextEditingController();
                      String? errorText;
                      void onTextChanged() {
                        if (errorText != null) {
                          errorText = null;
                        }
                      }

                      name.addListener(onTextChanged);
                      try {
                        await _ffi.dialogManager.show((
                          setState,
                          close,
                          context,
                        ) {
                          submit() {
                            if (name.value.text.isNotEmpty) {
                              if (!PathUtil.validName(
                                name.value.text,
                                controller.options.value.isWindows,
                              )) {
                                setState(() {
                                  errorText = translate("Invalid folder name");
                                });
                                return;
                              }
                              controller.createDir(
                                PathUtil.join(
                                  controller.directory.value.path,
                                  name.value.text,
                                  controller.options.value.isWindows,
                                ),
                              );
                              close();
                            }
                          }

                          cancel() => close(false);
                          return CustomAlertDialog(
                            title: ModernDialogHeader(
                              icon: CamelliaIcons.folderNew,
                              title: translate("Create Folder"),
                              onClose: cancel,
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextFormField(
                                  decoration: InputDecoration(
                                    labelText: translate(
                                      "Please enter the folder name",
                                    ),
                                    errorText: errorText,
                                  ),
                                  controller: name,
                                  autofocus: true,
                                ).workaroundFreezeLinuxMint(),
                              ],
                            ),
                            actions: [
                              dialogButton(
                                "Cancel",
                                icon: const Icon(CamelliaIcons.close),
                                onPressed: cancel,
                                isOutline: true,
                              ),
                              dialogButton(
                                "Ok",
                                icon: const Icon(CamelliaIcons.check),
                                onPressed: submit,
                              ),
                            ],
                            onSubmit: submit,
                            onCancel: cancel,
                          );
                        });
                      } finally {
                        name.removeListener(onTextChanged);
                        name.dispose();
                      }
                    },
                  ),
                  const SizedBox(width: 4),
                  Obx(
                    () => GlassIconButton(
                      icon: CamelliaIcons.trash,
                      size: 34,
                      iconSize: 17,
                      accentColor: glass.statusAlert,
                      tooltip: translate('Delete'),
                      onPressed: SelectedItems.valid(selectedItems.items)
                          ? () async {
                              await controller.removeAction(selectedItems);
                              selectedItems.clear();
                            }
                          : null,
                    ),
                  ),
                  const SizedBox(width: 4),
                  menu(isLocal: isLocal),
                ],
              ),
            ),
            if (isWeb)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Obx(
                  () => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GlassButton(
                        variant: GlassButtonVariant.secondary,
                        minHeight: 34,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        icon: const Icon(CamelliaIcons.upload, size: 15),
                        onPressed: () {
                          webselectFiles(is_folder: isUploadFolder.value);
                        },
                        child: Text(
                          translate(
                            isUploadFolder.isTrue
                                ? 'Upload folder'
                                : 'Upload files',
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      GestureDetector(
                        onTapDown: (e) {
                          final x = e.globalPosition.dx;
                          final y = e.globalPosition.dy;
                          uploadButtonTapPosition = RelativeRect.fromLTRB(
                            x,
                            y,
                            x,
                            y,
                          );
                        },
                        child: GlassIconButton(
                          icon: Icons.keyboard_arrow_down_rounded,
                          size: 32,
                          iconSize: 17,
                          tooltip: translate('Upload options'),
                          onPressed: () async {
                            final value = await showMenu<bool>(
                              context: context,
                              position: uploadButtonTapPosition,
                              items: [
                                PopupMenuItem<bool>(
                                  value: false,
                                  child: Text(translate('Upload files')),
                                ),
                                PopupMenuItem<bool>(
                                  value: true,
                                  child: Text(translate('Upload folder')),
                                ),
                              ],
                            );
                            if (value != null) {
                              isUploadFolder.value = value;
                              bind.mainSetLocalOption(
                                key: 'upload-folder-button',
                                value: value ? 'Y' : '',
                              );
                              webselectFiles(is_folder: value);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(width: 6),
            Obx(
              () => GlassButton(
                variant: GlassButtonVariant.primary,
                minHeight: 34,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                icon: Icon(
                  isLocal
                      ? CamelliaIcons.arrowForward
                      : (isWeb
                            ? CamelliaIcons.download
                            : CamelliaIcons.arrowBack),
                  size: 16,
                ),
                onPressed: SelectedItems.valid(selectedItems.items)
                    ? () {
                        final otherSideData = controller
                            .getOtherSideDirectoryData();
                        controller.sendFiles(selectedItems, otherSideData);
                        selectedItems.clear();
                      }
                    : null,
                child: Text(
                  isLocal
                      ? translate('Send')
                      : translate(isWeb ? 'Download' : 'Receive'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget menu({bool isLocal = false}) {
    var menuPos = RelativeRect.fill;

    final List<MenuEntryBase<String>> items = [
      MenuEntrySwitch<String>(
        switchType: SwitchType.scheckbox,
        text: translate("Show Hidden Files"),
        getter: () async {
          return controller.options.value.showHidden;
        },
        setter: (bool v) async {
          controller.toggleShowHidden();
        },
        padding: kDesktopMenuPadding,
        dismissOnClicked: true,
      ),
      MenuEntryButton(
        childBuilder: (style) => Text(translate("Select All"), style: style),
        proc: () => setState(
          () => selectedItems.selectAll(controller.directory.value.entries),
        ),
        padding: kDesktopMenuPadding,
        dismissOnClicked: true,
      ),
      MenuEntryButton(
        childBuilder: (style) => Text(translate("Unselect All"), style: style),
        proc: () => selectedItems.clear(),
        padding: kDesktopMenuPadding,
        dismissOnClicked: true,
      ),
    ];

    return Listener(
      onPointerDown: (e) {
        final x = e.position.dx;
        final y = e.position.dy;
        menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      child: GlassIconButton(
        icon: CamelliaIcons.more,
        size: 34,
        iconSize: 17,
        tooltip: translate('More'),
        onPressed: () => mod_menu.showMenu(
          context: context,
          position: menuPos,
          items: items
              .map(
                (e) => e.build(
                  context,
                  MenuConfig(
                    commonColor: CustomPopupMenuTheme.commonColor,
                    height: CustomPopupMenuTheme.height,
                    dividerHeight: CustomPopupMenuTheme.dividerHeight,
                  ),
                ),
              )
              .expand((i) => i)
              .toList(),
          elevation: 8,
        ),
      ),
    );
  }

  Widget _buildFileList(
    BuildContext context,
    ScrollController scrollController,
  ) {
    final fd = controller.directory.value;
    final entries = fd.entries;
    Rx<Entry?> rightClickEntry = Rx(null);

    return ListSearchActionListener(
      node: _keyboardNode,
      buffer: _listSearchBuffer,
      onNext: (buffer) {
        debugPrint("searching next for $buffer");
        assert(buffer.length == 1);
        assert(selectedItems.items.length <= 1);
        var skipCount = 0;
        if (selectedItems.items.isNotEmpty) {
          final index = entries.indexOf(selectedItems.items.first);
          if (index < 0) {
            return;
          }
          skipCount = index + 1;
        }
        var searchResult = entries
            .skip(skipCount)
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        if (searchResult.isEmpty) {
          // cannot find next, lets restart search from head
          debugPrint("restart search from head");
          searchResult = entries.where(
            (element) => element.name.toLowerCase().startsWith(buffer),
          );
        }
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(
          isLocal,
          searchResult.first,
          scrollController,
          kDesktopFileTransferRowHeight,
        );
      },
      onSearch: (buffer) {
        debugPrint("searching for $buffer");
        final selectedEntries = selectedItems;
        final searchResult = entries.where(
          (element) => element.name.toLowerCase().startsWith(buffer),
        );
        selectedEntries.clear();
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(
          isLocal,
          searchResult.first,
          scrollController,
          kDesktopFileTransferRowHeight,
        );
      },
      child: Obx(() {
        final entries = controller.directory.value.entries;
        final filteredEntries = _searchText.isNotEmpty
            ? entries
                  .where((element) {
                    return element.name.contains(_searchText.value);
                  })
                  .toList(growable: false)
            : entries;
        final rows = filteredEntries
            .map((entry) {
              final sizeStr = entry.isFile
                  ? readableFileSize(entry.size.toDouble())
                  : "";
              final lastModifiedStr = entry.isDrive
                  ? " "
                  : "${entry.lastModified().toString().replaceAll(".000", "")}   ";
              var secondaryPosition = RelativeRect.fromLTRB(0, 0, 0, 0);
              onTap() {
                final items = selectedItems;
                // handle double click
                if (_checkDoubleClick(entry)) {
                  controller.openDirectory(entry.path);
                  items.clear();
                  return;
                }
                _onSelectedChanged(items, filteredEntries, entry, isLocal);
              }

              onSecondaryTap() {
                final items = [
                  if (!entry.isDrive &&
                      versionCmp(_ffi.ffiModel.pi.version, "1.3.0") >= 0)
                    mod_menu.PopupMenuItem(
                      child: Text(translate("Rename")),
                      height: CustomPopupMenuTheme.height,
                      onTap: () {
                        controller.renameAction(entry, isLocal);
                      },
                    ),
                ];
                if (items.isNotEmpty) {
                  rightClickEntry.value = entry;
                  final future = mod_menu.showMenu(
                    context: context,
                    position: secondaryPosition,
                    items: items,
                  );
                  future.then((value) {
                    rightClickEntry.value = null;
                  });
                  future.onError((error, stackTrace) {
                    rightClickEntry.value = null;
                  });
                }
              }

              onSecondaryTapDown(details) {
                secondaryPosition = RelativeRect.fromLTRB(
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                );
              }

              return Padding(
                padding: EdgeInsets.symmetric(vertical: 1),
                child: Obx(
                  () => Container(
                    decoration: BoxDecoration(
                      color: selectedItems.items.contains(entry)
                          ? MyTheme.button
                          : Theme.of(context).cardColor,
                      borderRadius: BorderRadius.all(Radius.circular(5.0)),
                      border: rightClickEntry.value == entry
                          ? Border.all(color: MyTheme.button, width: 1.0)
                          : null,
                    ),
                    key: ValueKey(entry.name),
                    height: kDesktopFileTransferRowHeight,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Expanded(
                          child: InkWell(
                            child: Row(
                              children: [
                                GestureDetector(
                                  child: Obx(
                                    () => Container(
                                      width: _nameColWidth.value,
                                      child: Tooltip(
                                        waitDuration: Duration(
                                          milliseconds: 500,
                                        ),
                                        message: entry.name,
                                        child: Row(
                                          children: [
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                right: 8,
                                              ),
                                              child: Icon(
                                                CamelliaIcons.fileTypeIcon(
                                                  entry.name,
                                                  isDirectory: !entry.isFile,
                                                  isDrive: entry.isDrive,
                                                ),
                                                size: 19,
                                                color:
                                                    selectedItems.items
                                                        .contains(entry)
                                                    ? Colors.white
                                                    : CamelliaIcons.fileTypeColor(
                                                        context,
                                                        entry.name,
                                                        isDirectory:
                                                            !entry.isFile,
                                                        isDrive: entry.isDrive,
                                                      ),
                                              ),
                                            ),
                                            Expanded(
                                              child: Text(
                                                entry.name.nonBreaking,
                                                style: TextStyle(
                                                  color:
                                                      selectedItems.items
                                                          .contains(entry)
                                                      ? Colors.white
                                                      : null,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  onTap: onTap,
                                  onSecondaryTap: onSecondaryTap,
                                  onSecondaryTapDown: onSecondaryTapDown,
                                ),
                                const SizedBox(width: 2.0),
                                GestureDetector(
                                  child: Obx(
                                    () => SizedBox(
                                      width: _modifiedColWidth.value,
                                      child: Tooltip(
                                        waitDuration: const Duration(
                                          milliseconds: 500,
                                        ),
                                        message: lastModifiedStr,
                                        child: Text(
                                          lastModifiedStr,
                                          overflow: TextOverflow.ellipsis,
                                          style: CamelliaTypography.tabular(
                                            Theme.of(
                                              context,
                                            ).textTheme.bodySmall?.copyWith(
                                              color:
                                                  selectedItems.items.contains(
                                                    entry,
                                                  )
                                                  ? Colors.white70
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  onTap: onTap,
                                  onSecondaryTap: onSecondaryTap,
                                  onSecondaryTapDown: onSecondaryTapDown,
                                ),
                                const SizedBox(width: 2.0),
                                Expanded(
                                  child: GestureDetector(
                                    child: Tooltip(
                                      waitDuration: const Duration(
                                        milliseconds: 500,
                                      ),
                                      message: sizeStr,
                                      child: Text(
                                        sizeStr,
                                        overflow: TextOverflow.ellipsis,
                                        style: CamelliaTypography.tabular(
                                          Theme.of(
                                            context,
                                          ).textTheme.bodySmall?.copyWith(
                                            color:
                                                selectedItems.items.contains(
                                                  entry,
                                                )
                                                ? Colors.white70
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ),
                                    onTap: onTap,
                                    onSecondaryTap: onSecondaryTap,
                                    onSecondaryTapDown: onSecondaryTapDown,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            })
            .toList(growable: false);

        return Column(
          children: [
            // Header
            Row(children: [Expanded(child: _buildFileBrowserHeader(context))]),
            // Body
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemExtent: kDesktopFileTransferRowHeight,
                itemBuilder: (context, index) {
                  return rows[index];
                },
                itemCount: rows.length,
              ),
            ),
          ],
        );
      }),
    );
  }

  onSearchText(String searchText, bool isLocal) {
    selectedItems.clear();
    _searchText.value = searchText;
  }

  void _jumpToEntry(
    bool isLocal,
    Entry entry,
    ScrollController scrollController,
    double rowHeight,
  ) {
    final entries = controller.directory.value.entries;
    final index = entries.indexOf(entry);
    if (index == -1) {
      debugPrint("entry is not valid: ${entry.path}");
    }
    final selectedEntries = selectedItems;
    final searchResult = entries.where((element) => element == entry);
    selectedEntries.clear();
    if (searchResult.isEmpty) {
      return;
    }
    final offset = min(
      max(
        scrollController.position.minScrollExtent,
        entries.indexOf(searchResult.first) * rowHeight,
      ),
      scrollController.position.maxScrollExtent,
    );
    scrollController.jumpTo(offset);
    selectedEntries.add(searchResult.first);
    debugPrint("focused on ${searchResult.first.name}");
  }

  void _onSelectedChanged(
    SelectedItems selectedItems,
    List<Entry> entries,
    Entry entry,
    bool isLocal,
  ) {
    final isCtrlDown = HardwareKeyboard.instance.isControlPressed;
    final isShiftDown = HardwareKeyboard.instance.isShiftPressed;
    if (isCtrlDown) {
      if (selectedItems.items.contains(entry)) {
        selectedItems.remove(entry);
      } else {
        selectedItems.add(entry);
      }
    } else if (isShiftDown) {
      final List<int> indexGroup = [];
      for (var selected in selectedItems.items) {
        indexGroup.add(entries.indexOf(selected));
      }
      indexGroup.add(entries.indexOf(entry));
      indexGroup.removeWhere((e) => e == -1);
      final maxIndex = indexGroup.reduce(max);
      final minIndex = indexGroup.reduce(min);
      selectedItems.clear();
      entries
          .getRange(minIndex, maxIndex + 1)
          .forEach((e) => selectedItems.add(e));
    } else {
      selectedItems.clear();
      selectedItems.add(entry);
    }
    setState(() {});
  }

  bool _checkDoubleClick(Entry entry) {
    final current = DateTime.now().millisecondsSinceEpoch;
    final elapsed = current - _lastClickTime;
    _lastClickTime = current;
    if (_lastClickEntry == entry) {
      if (elapsed < bind.getDoubleClickTime()) {
        return true;
      }
    } else {
      _lastClickEntry = entry;
    }
    return false;
  }

  void _onDrag(double dx, RxDouble column1, RxDouble column2) {
    if (column1.value + dx <= _fileTransferMinimumWidth ||
        column2.value - dx <= _fileTransferMinimumWidth) {
      return;
    }
    column1.value += dx;
    column2.value -= dx;
    column1.value = max(_fileTransferMinimumWidth, column1.value);
    column2.value = max(_fileTransferMinimumWidth, column2.value);
  }

  Widget _buildFileBrowserHeader(BuildContext context) {
    final padding = EdgeInsets.all(1.0);
    return SizedBox(
      key: _globalHeaderKey,
      height: kDesktopFileTransferHeaderHeight,
      child: Row(
        children: [
          Obx(
            () => headerItemFunc(
              _nameColWidth.value,
              SortBy.name,
              translate("Name"),
            ),
          ),
          DraggableDivider(
            axis: Axis.vertical,
            onPointerMove: (dx) =>
                _onDrag(dx, _nameColWidth, _modifiedColWidth),
            padding: padding,
          ),
          Obx(
            () => headerItemFunc(
              _modifiedColWidth.value,
              SortBy.modified,
              translate("Modified"),
            ),
          ),
          DraggableDivider(
            axis: Axis.vertical,
            onPointerMove: (dx) =>
                _onDrag(dx, _modifiedColWidth, _sizeColWidth),
            padding: padding,
          ),
          Expanded(
            child: headerItemFunc(
              _sizeColWidth.value,
              SortBy.size,
              translate("Size"),
            ),
          ),
        ],
      ),
    );
  }

  Widget headerItemFunc(double? width, SortBy sortBy, String name) {
    final headerTextStyle =
        Theme.of(context).dataTableTheme.headingTextStyle ?? TextStyle();
    return ObxValue<Rx<bool?>>(
      (ascending) => InkWell(
        onTap: () {
          if (ascending.value == null) {
            ascending.value = true;
          } else {
            ascending.value = !ascending.value!;
          }
          controller.changeSortStyle(
            sortBy,
            isLocal: isLocal,
            ascending: ascending.value!,
          );
        },
        child: SizedBox(
          width: width,
          height: kDesktopFileTransferHeaderHeight,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: headerTextStyle,
                  overflow: TextOverflow.ellipsis,
                ).marginOnly(left: 4),
              ),
              ascending.value != null
                  ? Icon(
                      ascending.value!
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                    )
                  : SizedBox(),
            ],
          ),
        ),
      ),
      () {
        if (controller.sortBy.value == sortBy) {
          return controller.sortAscending.obs;
        } else {
          return Rx<bool?>(null);
        }
      }(),
    );
  }

  Widget buildBread() {
    final items = getPathBreadCrumbItems(isLocal, (list) {
      var path = "";
      for (var item in list) {
        path = PathUtil.join(path, item, controller.options.value.isWindows);
      }
      controller.openDirectory(path);
    });

    return items.isEmpty
        ? Offstage()
        : Row(
            key: _locationBarKey,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Listener(
                  // handle mouse wheel
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      final sc = _breadCrumbScroller;
                      final scale = isWindows ? 2 : 4;
                      sc.jumpTo(sc.offset + e.scrollDelta.dy / scale);
                    }
                  },
                  child: BreadCrumb(
                    items: items,
                    divider: const Icon(Icons.keyboard_arrow_right_rounded),
                    overflow: ScrollableOverflow(
                      controller: _breadCrumbScroller,
                    ),
                  ),
                ),
              ),
              ActionIcon(
                message: "",
                icon: Icons.keyboard_arrow_down_rounded,
                onTap: () async {
                  final renderBox =
                      _locationBarKey.currentContext?.findRenderObject()
                          as RenderBox;
                  _locationBarKey.currentContext?.size;

                  final size = renderBox.size;
                  final offset = renderBox.localToGlobal(Offset.zero);

                  final x = offset.dx;
                  final y = offset.dy + size.height + 1;

                  final isPeerWindows = controller.options.value.isWindows;
                  final List<MenuEntryBase> menuItems = [
                    MenuEntryButton(
                      childBuilder: (TextStyle? style) => isPeerWindows
                          ? buildWindowsThisPC(context, style)
                          : Text('/', style: style),
                      proc: () {
                        controller.openDirectory('/');
                      },
                      dismissOnClicked: true,
                    ),
                    MenuEntryDivider(),
                  ];
                  if (isPeerWindows) {
                    var loadingTag = "";
                    if (!isLocal) {
                      loadingTag =
                          _ffi.dialogManager.showLoading(translate("Waiting"));
                    }
                    try {
                      final showHidden = controller.options.value.showHidden;
                      final fd = await controller.fileFetcher.fetchDirectory(
                        "/",
                        isLocal,
                        showHidden,
                      );
                      for (var entry in fd.entries) {
                        menuItems.add(
                          MenuEntryButton(
                            childBuilder: (TextStyle? style) => Row(
                              children: [
                                Image(
                                  image: iconHardDrive,
                                  fit: BoxFit.scaleDown,
                                  color: Theme.of(
                                    context,
                                  ).iconTheme.color?.withValues(alpha: 0.7),
                                ),
                                SizedBox(width: 10),
                                Text(entry.name, style: style),
                              ],
                            ),
                            proc: () {
                              controller.openDirectory('${entry.name}\\');
                            },
                            dismissOnClicked: true,
                          ),
                        );
                      }
                      menuItems.add(MenuEntryDivider());
                    } catch (e) {
                      debugPrint("buildBread fetchDirectory err=$e");
                    } finally {
                      if (!isLocal) {
                        _ffi.dialogManager.dismissByTag(loadingTag);
                      }
                    }
                  }
                  mod_menu.showMenu(
                    context: context,
                    position: RelativeRect.fromLTRB(x, y, x, y),
                    elevation: 4,
                    items: menuItems
                        .map(
                          (e) => e.build(
                            context,
                            MenuConfig(
                              commonColor: CustomPopupMenuTheme.commonColor,
                              height: CustomPopupMenuTheme.height,
                              dividerHeight: CustomPopupMenuTheme.dividerHeight,
                              boxWidth: size.width,
                            ),
                          ),
                        )
                        .expand((i) => i)
                        .toList(),
                  );
                },
                iconSize: 20,
              ),
            ],
          );
  }

  List<BreadCrumbItem> getPathBreadCrumbItems(
    bool isLocal,
    void Function(List<String>) onPressed,
  ) {
    final path = controller.directory.value.path;
    final breadCrumbList = List<BreadCrumbItem>.empty(growable: true);
    final isWindows = controller.options.value.isWindows;
    if (isWindows && path == '/') {
      breadCrumbList.add(
        BreadCrumbItem(
          content: TextButton(
            child: buildWindowsThisPC(context),
            style: ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(0, 0)),
            ),
            onPressed: () => onPressed(['/']),
          ).marginSymmetric(horizontal: 4),
        ),
      );
    } else {
      final list = PathUtil.split(path, isWindows);
      breadCrumbList.addAll(
        list.asMap().entries.map(
          (e) => BreadCrumbItem(
            content: TextButton(
              child: Text(e.value),
              style: ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(0, 0)),
              ),
              onPressed: () => onPressed(list.sublist(0, e.key + 1)),
            ).marginSymmetric(horizontal: 4),
          ),
        ),
      );
    }
    return breadCrumbList;
  }

  breadCrumbScrollToEnd() {
    Future.delayed(Duration(milliseconds: 200), () {
      if (_breadCrumbScroller.hasClients) {
        _breadCrumbScroller.animateTo(
          _breadCrumbScroller.position.maxScrollExtent,
          duration: Duration(milliseconds: 200),
          curve: Curves.fastLinearToSlowEaseIn,
        );
      }
    });
  }

  Widget buildPathLocation() {
    final text = _locationStatus.value == LocationStatus.pathLocation
        ? controller.directory.value.path
        : _searchText.value;
    if (_pathInputController.text != text) {
      _pathInputController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    return Row(
      children: [
        Icon(
          _locationStatus.value == LocationStatus.pathLocation
              ? Icons.folder_outlined
              : CamelliaIcons.search,
          size: 17,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: TextField(
            focusNode: _locationNode,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 6),
            ),
            controller: _pathInputController,
            onSubmitted: (path) {
              controller.openDirectory(path);
            },
            onChanged: _locationStatus.value == LocationStatus.fileSearchBar
                ? (searchText) => onSearchText(searchText, isLocal)
                : null,
          ).workaroundFreezeLinuxMint(),
        ),
      ],
    );
  }

  // openDirectory(String path, {bool isLocal = false}) {
  //   model.openDirectory(path, isLocal: isLocal);
  // }
}

Widget buildWindowsThisPC(BuildContext context, [TextStyle? textStyle]) {
  final color = Theme.of(context).iconTheme.color?.withValues(alpha: 0.7);
  return Row(
    children: [
      Icon(Icons.computer, size: 20, color: color),
      SizedBox(width: 10),
      Text(translate('This PC'), style: textStyle),
    ],
  );
}

class ThroughputSparkline extends StatelessWidget {
  const ThroughputSparkline({
    super.key,
    required this.speeds,
    required this.color,
    this.width = 44,
    this.height = 14,
  });

  final List<double> speeds;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _SparklinePainter(speeds: speeds, color: color),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.speeds, required this.color});

  final List<double> speeds;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (speeds.length < 2) return;
    double maxSpeed = 0.0;
    for (final s in speeds) {
      if (s > maxSpeed) maxSpeed = s;
    }
    if (maxSpeed <= 0) return;

    final path = Path();
    final fillPath = Path();
    final stepX = size.width / (speeds.length - 1);

    for (int i = 0; i < speeds.length; i++) {
      final x = i * stepX;
      final y = size.height - (speeds[i] / maxSpeed * (size.height - 2)) - 1;
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.28),
          color.withValues(alpha: 0.02),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) => true;
}
