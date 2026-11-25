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
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../common/shared_state.dart';

class _FilePaneDragData {
  const _FilePaneDragData({required this.isLocal, required this.entries});

  final bool isLocal;
  final List<Entry> entries;
}

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

  final _localDropMaskVisible = false.obs;
  final _remoteDropMaskVisible = false.obs;
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
                                      maskVisible: _localDropMaskVisible,
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
                                    maskVisible: _remoteDropMaskVisible,
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

  Widget dropArea(
    FileManagerView fileView, {
    required RxBool maskVisible,
  }) {
    final isLocalPane = fileView.controller.isLocal;
    return DropTarget(
      enable: !isLocalPane,
      onDragDone: (detail) {
        maskVisible.value = false;
        handleDragDone(detail, isLocalPane);
      },
      onDragEntered: (enter) {
        if (!isLocalPane) {
          maskVisible.value = true;
        }
      },
      onDragExited: (exit) {
        maskVisible.value = false;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          fileView,
          Obx(() {
            if (!maskVisible.value) return const SizedBox.shrink();
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
                strokeWidth: 1.4,
                borderRadius: BorderRadius.circular(CamelliaRadius.surface),
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
      final activeJobs = jobs
          .where(
            (j) => j.state == JobState.inProgress || j.state == JobState.paused,
          )
          .toList(growable: false);
      final activeCount = activeJobs.length;
      final completedCount = jobs
          .where((j) => j.state == JobState.done || j.state == JobState.error)
          .length;
      double totalSpeedBytes = 0.0;
      int aggregateTotalBytes = 0;
      int aggregateFinishedBytes = 0;
      for (final j in activeJobs) {
        if (j.state == JobState.inProgress && j.speed > 0 && j.speed.isFinite) {
          totalSpeedBytes += j.speed;
        }
        if (j.effectiveTotalSize > 0) {
          aggregateTotalBytes += j.effectiveTotalSize;
          aggregateFinishedBytes += j.effectiveFinishedSize;
        }
      }
      final double? aggregatePercent = aggregateTotalBytes > 0
          ? (aggregateFinishedBytes / aggregateTotalBytes).clamp(0.0, 1.0)
          : (activeCount > 0 ? null : 0.0);
      final liveSpeedLabel = totalSpeedBytes > 0
          ? '${readableFileSize(totalSpeedBytes)}/s'
          : '';
      final expanded = _transferDrawerExpanded.value;

      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: GlassSurface(
          layer: CamelliaGlassLayer.modal,
          elevated: expanded,
          strokeWidth: 0.85,
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
                        if (activeCount > 0) ...[
                          const SizedBox(width: 14),
                          SizedBox(
                            width: 140,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                CamelliaRadius.pill,
                              ),
                              child: LinearProgressIndicator(
                                value: aggregatePercent,
                                minHeight: 5,
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  accent,
                                ),
                              ),
                            ),
                          ),
                          if (aggregatePercent != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              '${(aggregatePercent * 100).round()}%',
                              style: CamelliaTypography.tabular(
                                theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                          if (liveSpeedLabel.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Text(
                              liveSpeedLabel,
                              style: CamelliaTypography.tabular(
                                theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ],
                        const Spacer(),
                        if (completedCount > 0) ...[
                          GlassButton(
                            variant: GlassButtonVariant.ghost,
                            minHeight: 28,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            onPressed: () {
                              jobController.jobTable.removeWhere(
                                (j) =>
                                    j.state == JobState.done ||
                                    j.state == JobState.error,
                              );
                            },
                            child: Text(translate('Clear Completed')),
                          ),
                          const SizedBox(width: 6),
                        ],
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
  final _modifiedColWidth = 152.0.obs;
  final _sizeColWidth = 92.0.obs;
  final _hoveredEntry = ValueNotifier<Entry?>(null);
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
    _hoveredEntry.dispose();
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
                    onExit: (evt) {
                      widget._mouseFocusScope.value = MouseFocusScope.none;
                      _hoveredEntry.value = null;
                    },
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
      _fileTransferMinimumWidth = 68.0;
      _modifiedColWidth.value = max(136.0, min(180.0, windowWidthNow * 0.12));
      _sizeColWidth.value = max(84.0, min(116.0, windowWidthNow * 0.075));
    } else if (_windowWidthPrev != windowWidthNow) {
      _windowWidthPrev = windowWidthNow;
    }
  }

  Future<void> _showCreateFolderDialog() async {
    final name = TextEditingController();
    String? errorText;
    void onTextChanged() {
      if (errorText != null) {
        errorText = null;
      }
    }

    name.addListener(onTextChanged);
    try {
      await _ffi.dialogManager.show((setState, close, context) {
        void submit() {
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

        void cancel() => close(false);
        return CustomAlertDialog(
          title: ModernDialogHeader(
            icon: CamelliaIcons.folderNew,
            title: translate("Create Folder"),
            onClose: cancel,
          ),
          contentBoxConstraints: const BoxConstraints(
            minWidth: 360,
            maxWidth: 400,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlassInput(
                controller: name,
                labelText: translate("Please enter the folder name"),
                errorText: errorText,
                autofocus: true,
                onSubmitted: (_) => submit(),
              ),
            ],
          ),
          actions: [
            GlassButton(
              variant: GlassButtonVariant.secondary,
              onPressed: cancel,
              child: Text(translate("Cancel")),
            ),
            GlassButton(
              variant: GlassButtonVariant.primary,
              onPressed: submit,
              child: Text(translate("OK")),
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
  }

  void _transferSelected() {
    if (!SelectedItems.valid(selectedItems.items)) return;
    final otherSideData = controller.getOtherSideDirectoryData();
    controller.sendFiles(selectedItems, otherSideData);
    selectedItems.clear();
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
    var uploadButtonTapGlobal = Offset.zero;
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
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
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
                        size: 20,
                        color: accent,
                      );
                    }
                    return SizedBox(
                      width: 16,
                      height: 16,
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
                strokeWidth: 0.85,
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
        // Action row (clean standard LTR alignment on both Local and Remote panes)
        Row(
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
              onPressed: _showCreateFolderDialog,
            ),
            const SizedBox(width: 4),
            Obx(() {
              final showHidden = controller.options.value.showHidden;
              return GlassIconButton(
                icon: showHidden ? CamelliaIcons.eye : CamelliaIcons.eyeOff,
                size: 34,
                iconSize: 17,
                selected: showHidden,
                tooltip: translate('Show Hidden Files'),
                onPressed: () {
                  controller.toggleShowHidden();
                  controller.options.refresh();
                },
              );
            }),
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
            const Spacer(),
            if (isWeb)
              Padding(
                padding: const EdgeInsets.only(right: 6),
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
                          uploadButtonTapGlobal = e.globalPosition;
                        },
                        child: GlassIconButton(
                          icon: Icons.keyboard_arrow_down_rounded,
                          size: 32,
                          iconSize: 17,
                          tooltip: translate('Upload options'),
                          onPressed: () {
                            showFrostedContextMenu(
                              context: context,
                              globalPosition: uploadButtonTapGlobal,
                              itemsBuilder: (closeMenu) => [
                                FrostedMenuItem(
                                  label: translate('Upload files'),
                                  icon: CamelliaIcons.upload,
                                  onTap: () {
                                    closeMenu();
                                    isUploadFolder.value = false;
                                    bind.mainSetLocalOption(
                                      key: 'upload-folder-button',
                                      value: '',
                                    );
                                    webselectFiles(is_folder: false);
                                  },
                                ),
                                FrostedMenuItem(
                                  label: translate('Upload folder'),
                                  icon: Icons.folder_rounded,
                                  onTap: () {
                                    closeMenu();
                                    isUploadFolder.value = true;
                                    bind.mainSetLocalOption(
                                      key: 'upload-folder-button',
                                      value: 'Y',
                                    );
                                    webselectFiles(is_folder: true);
                                  },
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
                    ? _transferSelected
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
    var menuGlobalPos = Offset.zero;
    return Listener(
      onPointerDown: (e) {
        menuGlobalPos = e.position;
      },
      child: GlassIconButton(
        icon: CamelliaIcons.more,
        size: 34,
        iconSize: 17,
        tooltip: translate('More'),
        onPressed: () {
          showFrostedContextMenu(
            context: context,
            globalPosition: menuGlobalPos,
            itemsBuilder: (closeMenu) => [
              FrostedMenuToggleItem(
                label: translate('Show Hidden Files'),
                icon: CamelliaIcons.eye,
                value: controller.options.value.showHidden,
                onChanged: (_) {
                  closeMenu();
                  controller.toggleShowHidden();
                  controller.options.refresh();
                },
              ),
              const FrostedMenuDivider(),
              FrostedMenuItem(
                label: translate('Select All'),
                icon: Icons.select_all_rounded,
                onTap: () {
                  closeMenu();
                  setState(
                    () => selectedItems.selectAll(
                      controller.directory.value.entries,
                    ),
                  );
                },
              ),
              FrostedMenuItem(
                label: translate('Unselect All'),
                icon: Icons.deselect_rounded,
                onTap: () {
                  closeMenu();
                  selectedItems.clear();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  void _showPaneContextMenu(Offset globalPos, {Entry? targetEntry}) {
    final canRename =
        targetEntry != null &&
        !targetEntry.isDrive &&
        versionCmp(_ffi.ffiModel.pi.version, "1.3.0") >= 0;
    final hasValidSelection = SelectedItems.valid(selectedItems.items);
    final transferLabel = isLocal
        ? translate('Send')
        : translate(isWeb ? 'Download' : 'Receive');
    showFrostedContextMenu(
      context: context,
      globalPosition: globalPos,
      itemsBuilder: (closeMenu) => [
        if (targetEntry != null && !targetEntry.isFile) ...[
          FrostedMenuItem(
            label: translate('Open'),
            icon: Icons.folder_rounded,
            onTap: () {
              closeMenu();
              selectedItems.clear();
              controller.openDirectory(targetEntry.path);
            },
          ),
        ],
        if (hasValidSelection)
          FrostedMenuItem(
            label: transferLabel,
            icon: isLocal
                ? CamelliaIcons.arrowForward
                : (isWeb ? CamelliaIcons.download : CamelliaIcons.arrowBack),
            onTap: () {
              closeMenu();
              _transferSelected();
            },
          ),
        if (hasValidSelection || (targetEntry != null && !targetEntry.isFile))
          const FrostedMenuDivider(),
        FrostedMenuItem(
          label: translate('Create Folder'),
          icon: CamelliaIcons.folderNew,
          onTap: () {
            closeMenu();
            _showCreateFolderDialog();
          },
        ),
        if (canRename)
          FrostedMenuItem(
            label: translate('Rename'),
            icon: Icons.drive_file_rename_outline_rounded,
            onTap: () {
              closeMenu();
              controller.renameAction(targetEntry, isLocal);
            },
          ),
        if (hasValidSelection)
          FrostedMenuItem(
            label: translate('Delete'),
            icon: CamelliaIcons.trash,
            destructive: true,
            onTap: () async {
              closeMenu();
              await controller.removeAction(selectedItems);
              selectedItems.clear();
            },
          ),
        const FrostedMenuDivider(),
        FrostedMenuItem(
          label: translate('Select All'),
          icon: Icons.select_all_rounded,
          onTap: () {
            closeMenu();
            setState(
              () => selectedItems.selectAll(controller.directory.value.entries),
            );
          },
        ),
        FrostedMenuToggleItem(
          label: translate('Show Hidden Files'),
          icon: CamelliaIcons.eye,
          value: controller.options.value.showHidden,
          onChanged: (_) {
            closeMenu();
            controller.toggleShowHidden();
            controller.options.refresh();
          },
        ),
        FrostedMenuItem(
          label: translate('Refresh File'),
          icon: CamelliaIcons.refresh,
          onTap: () {
            closeMenu();
            controller.refresh();
          },
        ),
      ],
    );
  }

  Widget _buildFileList(
    BuildContext context,
    ScrollController scrollController,
  ) {
    final fd = controller.directory.value;
    final entries = fd.entries;

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
      child: DragTarget<_FilePaneDragData>(
        onWillAcceptWithDetails: (details) =>
            details.data.isLocal != isLocal && details.data.entries.isNotEmpty,
        onAcceptWithDetails: (details) {
          final data = details.data;
          final sourceController = data.isLocal
              ? _ffi.fileModel.localController
              : _ffi.fileModel.remoteController;
          final tempSelected = SelectedItems(isLocal: data.isLocal);
          for (final e in data.entries) {
            tempSelected.add(e);
          }
          sourceController.sendFiles(tempSelected, controller.directoryData());
          sourceController.selectedItems.clear();
        },
        builder: (context, candidateData, rejectedData) {
          final isCrossPaneHover = candidateData.isNotEmpty;
          final theme = Theme.of(context);
          final glass = CamelliaGlassTokens.of(context);
          final accent = theme.brightness == Brightness.dark
              ? theme.colorScheme.secondary
              : theme.colorScheme.primary;
          return AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
            decoration: BoxDecoration(
              color: isCrossPaneHover
                  ? accent.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              border: isCrossPaneHover
                  ? Border.all(color: accent.withValues(alpha: 0.7), width: 1.2)
                  : null,
            ),
            child: Obx(() {
              final entries = controller.directory.value.entries;
              final filteredEntries = _searchText.isNotEmpty
                  ? entries
                        .where((element) {
                          return element.name
                              .toLowerCase()
                              .contains(_searchText.value.toLowerCase());
                        })
                        .toList(growable: false)
                  : entries;

              Widget buildRow(Entry entry) {
                final sizeStr = entry.isFile
                    ? readableFileSize(entry.size.toDouble())
                    : "";
                final lastModifiedStr = entry.isDrive
                    ? ""
                    : entry.lastModified().toString().replaceAll(".000", "");
                Offset secondaryGlobalPos = Offset.zero;

                void onTap() {
                  final items = selectedItems;
                  if (_checkDoubleClick(entry)) {
                    controller.openDirectory(entry.path);
                    items.clear();
                    return;
                  }
                  _onSelectedChanged(items, filteredEntries, entry, isLocal);
                }

                void onSecondaryTapDown(TapDownDetails details) {
                  secondaryGlobalPos = details.globalPosition;
                }

                void onSecondaryTap() {
                  if (!selectedItems.items.contains(entry)) {
                    selectedItems.clear();
                    selectedItems.add(entry);
                  }
                  _showPaneContextMenu(secondaryGlobalPos, targetEntry: entry);
                }

                final rowContent = Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Obx(() {
                    final isSelected = selectedItems.items.contains(entry);
                    return ValueListenableBuilder<Entry?>(
                      valueListenable: _hoveredEntry,
                      builder: (context, hovered, _) {
                        final isHovered = identical(hovered, entry);
                        return MouseRegion(
                          onEnter: (_) => _hoveredEntry.value = entry,
                          onExit: (_) {
                            if (identical(_hoveredEntry.value, entry)) {
                              _hoveredEntry.value = null;
                            }
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onTap,
                            onSecondaryTapDown: onSecondaryTapDown,
                            onSecondaryTap: onSecondaryTap,
                            child: AnimatedContainer(
                              key: ValueKey(entry.name),
                              duration: CamelliaMotion.resolve(
                                context,
                                CamelliaMotion.hover,
                              ),
                              height: kDesktopFileTransferRowHeight - 2,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? accent.withValues(alpha: 0.14)
                                    : isHovered
                                    ? glass.hoverOverlay
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: isSelected
                                      ? accent.withValues(alpha: 0.48)
                                      : Colors.transparent,
                                  width: 0.85,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      waitDuration: const Duration(
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
                                              size: 18,
                                              color: isSelected
                                                  ? accent
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
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    fontSize: 13,
                                                    fontWeight: isSelected
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                    color: theme
                                                        .colorScheme
                                                        .onSurface,
                                                  ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Obx(
                                    () => SizedBox(
                                      width: _modifiedColWidth.value,
                                      child: Text(
                                        lastModifiedStr,
                                        textAlign: TextAlign.right,
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
                                  ),
                                  const SizedBox(width: 8),
                                  Obx(
                                    () => SizedBox(
                                      width: _sizeColWidth.value,
                                      child: Text(
                                        sizeStr,
                                        textAlign: TextAlign.right,
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
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  }),
                );

                if (entry.isDrive) return rowContent;
                final dragItems = selectedItems.items.contains(entry)
                    ? selectedItems.items.toList(growable: false)
                    : <Entry>[entry];
                return Draggable<_FilePaneDragData>(
                  data: _FilePaneDragData(
                    isLocal: isLocal,
                    entries: dragItems,
                  ),
                  feedback: Material(
                    type: MaterialType.transparency,
                    child: GlassSurface(
                      layer: CamelliaGlassLayer.modal,
                      elevated: true,
                      strokeWidth: 0.85,
                      borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CamelliaVectorIcon(
                            CamelliaGlyph.folder,
                            size: 16,
                            color: accent,
                          ),
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (dragItems.length > 1) ...[
                            const SizedBox(width: 8),
                            GlassBadge(
                              label: '${dragItems.length}',
                              tone: GlassBadgeTone.brand,
                              tabularNums: true,
                              compact: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  child: rowContent,
                );
              }

              Offset emptyTapPos = Offset.zero;
              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _buildFileBrowserHeader(context)),
                    ],
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => selectedItems.clear(),
                      onSecondaryTapDown: (d) => emptyTapPos = d.globalPosition,
                      onSecondaryTap: () => _showPaneContextMenu(emptyTapPos),
                      child: filteredEntries.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CamelliaStateIllustration(
                                    glyph: CamelliaGlyph.emptyFiles,
                                    accentColor: accent,
                                    size: 54,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    translate('This folder is empty'),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemExtent: kDesktopFileTransferRowHeight,
                              itemCount: filteredEntries.length,
                              itemBuilder: (context, index) =>
                                  buildRow(filteredEntries[index]),
                            ),
                    ),
                  ),
                ],
              );
            }),
          );
        },
      ),
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
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        AppVisual.tokens(context);
    const padding = EdgeInsets.all(1.0);
    return Container(
      key: _globalHeaderKey,
      height: kDesktopFileTransferHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: tokens.border, width: 0.85),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: headerItemFunc(
              null,
              SortBy.name,
              translate("Name"),
              alignRight: false,
            ),
          ),
          DraggableDivider(
            axis: Axis.vertical,
            onPointerMove: (dx) {
              final next = (_modifiedColWidth.value - dx).clamp(96.0, 260.0);
              _modifiedColWidth.value = next;
            },
            padding: padding,
          ),
          Obx(
            () => headerItemFunc(
              _modifiedColWidth.value,
              SortBy.modified,
              translate("Modified"),
              alignRight: true,
            ),
          ),
          DraggableDivider(
            axis: Axis.vertical,
            onPointerMove: (dx) =>
                _onDrag(dx, _modifiedColWidth, _sizeColWidth),
            padding: padding,
          ),
          Obx(
            () => headerItemFunc(
              _sizeColWidth.value,
              SortBy.size,
              translate("Size"),
              alignRight: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget headerItemFunc(
    double? width,
    SortBy sortBy,
    String name, {
    bool alignRight = false,
  }) {
    final theme = Theme.of(context);
    final headerTextStyle =
        theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ) ??
        const TextStyle();
    return ObxValue<Rx<bool?>>(
      (ascending) => InkWell(
        borderRadius: BorderRadius.circular(5),
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
            mainAxisAlignment: alignRight
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              if (!alignRight)
                Expanded(
                  child: Text(
                    name,
                    style: headerTextStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (ascending.value != null)
                Icon(
                  ascending.value!
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurface,
                ),
              if (alignRight)
                Flexible(
                  child: Text(
                    name,
                    textAlign: TextAlign.right,
                    style: headerTextStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
        ? const Offstage()
        : Row(
            key: _locationBarKey,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Listener(
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      final sc = _breadCrumbScroller;
                      final scale = isWindows ? 2 : 4;
                      sc.jumpTo(sc.offset + e.scrollDelta.dy / scale);
                    }
                  },
                  child: BreadCrumb(
                    items: items,
                    divider: const Icon(
                      Icons.keyboard_arrow_right_rounded,
                      size: 16,
                    ),
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
                          as RenderBox?;
                  if (renderBox == null) return;
                  final size = renderBox.size;
                  final offset = renderBox.localToGlobal(Offset.zero);
                  final globalPos = Offset(offset.dx, offset.dy + size.height + 2);

                  final isPeerWindows = controller.options.value.isWindows;
                  final List<Entry> driveEntries = [];
                  if (isPeerWindows) {
                    var loadingTag = "";
                    if (!isLocal) {
                      loadingTag = _ffi.dialogManager.showLoading(
                        translate("Waiting"),
                      );
                    }
                    try {
                      final showHidden = controller.options.value.showHidden;
                      final fd = await controller.fileFetcher.fetchDirectory(
                        "/",
                        isLocal,
                        showHidden,
                      );
                      driveEntries.addAll(fd.entries);
                    } catch (e) {
                      debugPrint("buildBread fetchDirectory err=$e");
                    } finally {
                      if (!isLocal) {
                        _ffi.dialogManager.dismissByTag(loadingTag);
                      }
                    }
                  }
                  if (!mounted) return;
                  showFrostedContextMenu(
                    context: context,
                    globalPosition: globalPos,
                    minWidth: max(180, min(280, size.width)),
                    itemsBuilder: (closeMenu) => [
                      FrostedMenuItem(
                        label: isPeerWindows ? translate('This PC') : '/',
                        icon: isPeerWindows
                            ? Icons.computer_rounded
                            : Icons.folder_rounded,
                        onTap: () {
                          closeMenu();
                          controller.openDirectory('/');
                        },
                      ),
                      if (driveEntries.isNotEmpty) ...[
                        const FrostedMenuDivider(),
                        for (final entry in driveEntries)
                          FrostedMenuItem(
                            label: entry.name,
                            icon: Icons.storage_rounded,
                            onTap: () {
                              closeMenu();
                              controller.openDirectory('${entry.name}\\');
                            },
                          ),
                      ],
                    ],
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
