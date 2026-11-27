import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:camellia_remote_app/models/file_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/widgets/dialog.dart';

class FileManagerPage extends StatefulWidget {
  const FileManagerPage({
    super.key,
    required this.id,
    this.password,
    this.isSharedPassword,
    this.forceRelay,
  });

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;

  @override
  State<StatefulWidget> createState() => _FileManagerPageState();
}

enum SelectMode { local, remote, none }

extension SelectModeEq on SelectMode {
  bool eq(bool? currentIsLocal) {
    if (currentIsLocal == null) {
      return false;
    }
    if (currentIsLocal) {
      return this == SelectMode.local;
    } else {
      return this == SelectMode.remote;
    }
  }
}

extension SelectModeExt on Rx<SelectMode> {
  void toggle(bool currentIsLocal) {
    switch (value) {
      case SelectMode.local:
        value = SelectMode.none;
        break;
      case SelectMode.remote:
        value = SelectMode.none;
        break;
      case SelectMode.none:
        value = currentIsLocal ? SelectMode.local : SelectMode.remote;
        break;
    }
  }
}

class _FileManagerPageState extends State<FileManagerPage> {
  final model = gFFI.fileModel;
  final selectMode = SelectMode.none.obs;

  var showLocal = true;

  FileController get currentFileController =>
      showLocal ? model.localController : model.remoteController;
  FileDirectory get currentDir => currentFileController.directory.value;
  DirectoryOptions get currentOptions => currentFileController.options.value;
  final _uniqueKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    gFFI.start(
      widget.id,
      isFileTransfer: true,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gFFI.dialogManager.showLoading(
        translate('Connecting...'),
        onCancel: closeConnection,
      );
    });
    gFFI.ffiModel.updateEventListener(gFFI.sessionId, widget.id);
    WakelockManager.enable(_uniqueKey);
  }

  @override
  void dispose() {
    model.close().whenComplete(() {
      gFFI.close();
      gFFI.dialogManager.dismissAll();
      WakelockManager.disable(_uniqueKey);
    });
    model.jobController.clear();
    super.dispose();
  }

  Future<void> _showCreateFolderDialog() async {
    if (currentDir.path == "/") return;
    final name = TextEditingController();
    String? errorText;
    void onTextChanged() {
      if (errorText != null) {
        errorText = null;
      }
    }

    name.addListener(onTextChanged);
    try {
      await gFFI.dialogManager.show((setState, close, context) {
        void submit() {
          final folderName = name.text.trim();
          if (folderName.isEmpty) return;
          if (!PathUtil.validName(
            folderName,
            currentFileController.options.value.isWindows,
          )) {
            setState(() {
              errorText = translate("Invalid folder name");
            });
            return;
          }
          currentFileController.createDir(
            PathUtil.join(
              currentDir.path,
              folderName,
              currentOptions.isWindows,
            ),
          );
          close();
        }

        return CustomAlertDialog(
          title: ModernDialogHeader(
            icon: CamelliaIcons.folderNew,
            title: translate("Create Folder"),
            onClose: () => close(false),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 280, maxWidth: 400),
            child: GlassInput(
              controller: name,
              autofocus: true,
              labelText: translate("Please enter the folder name"),
              errorText: errorText,
              prefixIcon: Icons.folder_outlined,
              onSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            GlassButton(
              variant: GlassButtonVariant.secondary,
              onPressed: () => close(false),
              child: Text(translate("Cancel")),
            ),
            GlassButton(
              variant: GlassButtonVariant.primary,
              onPressed: submit,
              child: Text(translate("OK")),
            ),
          ],
          onSubmit: submit,
          onCancel: () => close(false),
        );
      });
    } finally {
      name.removeListener(onTextChanged);
      name.dispose();
    }
  }

  Future<void> _showMoreOptionsSheet() async {
    final canModifyDir = currentDir.path != "/";
    await showGlassBottomSheet<void>(
      context: context,
      title: translate('File Transfer'),
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        final dark = theme.brightness == Brightness.dark;
        final accent = dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(CamelliaIcons.refresh, color: accent),
                title: Text(translate("Refresh File")),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  currentFileController.refresh();
                },
              ),
              ListTile(
                enabled: canModifyDir,
                leading: const Icon(Icons.checklist_rounded),
                title: Text(translate("Multi Select")),
                onTap: !canModifyDir
                    ? null
                    : () {
                        Navigator.of(sheetCtx).pop();
                        model.localController.selectedItems.clear();
                        model.remoteController.selectedItems.clear();
                        selectMode.toggle(showLocal);
                        setState(() {});
                      },
              ),
              ListTile(
                enabled: canModifyDir,
                leading: const Icon(CamelliaIcons.folderNew),
                title: Text(translate("Create Folder")),
                onTap: !canModifyDir
                    ? null
                    : () {
                        Navigator.of(sheetCtx).pop();
                        _showCreateFolderDialog();
                      },
              ),
              ListTile(
                enabled: canModifyDir,
                leading: Icon(
                  currentOptions.showHidden
                      ? CamelliaIcons.eye
                      : CamelliaIcons.eyeOff,
                  color: currentOptions.showHidden ? accent : null,
                ),
                title: Text(translate("Show Hidden Files")),
                trailing: currentOptions.showHidden
                    ? Icon(CamelliaIcons.check, size: 18, color: accent)
                    : null,
                onTap: !canModifyDir
                    ? null
                    : () {
                        Navigator.of(sheetCtx).pop();
                        currentFileController.toggleShowHidden();
                      },
              ),
              Obx(() {
                final jobs = model.jobController.jobTable;
                if (jobs.isEmpty) return const SizedBox.shrink();
                return ListTile(
                  leading: Icon(CamelliaIcons.transfer, color: accent),
                  title: Text(translate("Transfer Queue")),
                  trailing: GlassBadge(
                    label: '${jobs.length}',
                    tone: GlassBadgeTone.brand,
                    tabularNums: true,
                    compact: true,
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _showTransferQueueSheet();
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showTransferQueueSheet() async {
    await showGlassBottomSheet<void>(
      context: context,
      title: translate('Transfer Queue'),
      actions: [
        GlassButton(
          variant: GlassButtonVariant.ghost,
          minHeight: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          onPressed: () async {
            final snapshot = List<JobProgress>.from(
              model.jobController.jobTable,
            );
            for (final job in snapshot) {
              if (job.state == JobState.inProgress ||
                  job.state == JobState.paused ||
                  job.state == JobState.none) {
                await model.jobController.cancelJob(job.id);
              }
            }
            model.jobController.jobTable.clear();
            if (mounted) {
              Navigator.of(context).maybePop();
            }
          },
          child: Text(translate('Clear')),
        ),
      ],
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        final dark = theme.brightness == Brightness.dark;
        final tokens =
            theme.extension<AppDesignTokens>() ?? MyTheme.tokens(sheetCtx);
        final glass = CamelliaGlassTokens.of(sheetCtx);

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.68,
          ),
          child: Obx(() {
            final jobs = model.jobController.jobTable;
            if (jobs.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CamelliaStateIllustration(
                      glyph: CamelliaGlyph.fileTransfer,
                      size: 52,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      translate('Idle'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
              shrinkWrap: true,
              itemCount: jobs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (ctx, index) {
                final job = jobs[index];
                final (statusColor, statusLabel) = switch (job.state) {
                  JobState.inProgress => (
                    glass.statusConnecting,
                    '${readableFileSize(job.speed)}/s',
                  ),
                  JobState.done => (glass.statusOnline, translate('Successful')),
                  JobState.error => (glass.statusAlert, job.getStatus()),
                  JobState.paused => (
                    glass.statusHighLatency,
                    translate('Paused'),
                  ),
                  JobState.none => (tokens.muted, translate('Waiting')),
                };

                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surfaceContainer.withValues(
                      alpha: dark ? 0.65 : 0.80,
                    ),
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    border: Border.all(
                      color: tokens.border.withValues(alpha: 0.85),
                      width: 0.85,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              job.isRemoteToLocal
                                  ? CamelliaIcons.download
                                  : CamelliaIcons.upload,
                              size: 17,
                              color: statusColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                job.jobName.isEmpty
                                    ? job.display()
                                    : job.jobName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (job.state == JobState.paused)
                              GlassIconButton(
                                icon: CamelliaIcons.refresh,
                                size: 30,
                                iconSize: 15,
                                tooltip: translate('Resume'),
                                onPressed: () =>
                                    model.jobController.resumeJob(job.id),
                              ),
                            if (job.state == JobState.inProgress ||
                                job.state == JobState.paused) ...[
                              const SizedBox(width: 4),
                              GlassIconButton(
                                icon: CamelliaIcons.close,
                                size: 30,
                                iconSize: 15,
                                tooltip: translate('Cancel'),
                                onPressed: () =>
                                    model.jobController.cancelJob(job.id),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          statusLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CamelliaTypography.tabular(
                            theme.textTheme.labelSmall?.copyWith(
                              color: statusColor,
                            ),
                          ),
                        ),
                        if (job.state == JobState.inProgress) ...[
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              value: job.effectiveTotalSize > 0
                                  ? job.percent.clamp(0.0, 1.0)
                                  : null,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            );
          }),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (selectMode.value != SelectMode.none) {
          selectMode.value = SelectMode.none;
          setState(() {});
          return;
        }
        if (currentFileController.canGoBack) {
          currentFileController.goBack();
          return;
        }
        if (gFFI.closed) {
          Navigator.of(context).maybePop();
        } else {
          clientClose(gFFI.sessionId, gFFI);
        }
      },
      child: AppAmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 56,
          leadingWidth: 52,
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
          leading: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Center(
              child: GlassIconButton(
                icon: CamelliaIcons.close,
                size: 36,
                iconSize: 18,
                tooltip: translate('Close'),
                onPressed: () => clientClose(gFFI.sessionId, gFFI),
              ),
            ),
          ),
          centerTitle: true,
          title: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: GlassSegmentedControl<bool>(
              compact: true,
              expand: true,
              selected: showLocal,
              items: [
                GlassSegmentItem<bool>(
                  value: true,
                  icon: Icons.phone_android_rounded,
                  label: translate('Local'),
                ),
                GlassSegmentItem<bool>(
                  value: false,
                  icon: CamelliaIcons.screen,
                  label: translate('Remote'),
                ),
              ],
              onChanged: (next) {
                if (next != showLocal) {
                  setState(() => showLocal = next);
                }
              },
            ),
          ),
          actions: [
            Obx(() {
              final jobs = model.jobController.jobTable;
              if (jobs.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GlassBadge(
                  label: '${jobs.length}',
                  icon: CamelliaIcons.transfer,
                  tone: GlassBadgeTone.brand,
                  tabularNums: true,
                  compact: true,
                  onTap: _showTransferQueueSheet,
                ),
              );
            }),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: GlassIconButton(
                icon: CamelliaIcons.more,
                size: 36,
                iconSize: 18,
                tooltip: translate('More'),
                onPressed: _showMoreOptionsSheet,
              ),
            ),
          ],
        ),
          body: Column(
            children: [
              Expanded(
                child: FileManagerView(
                  key: ValueKey<bool>(showLocal),
                  controller: showLocal
                      ? model.localController
                      : model.remoteController,
                  selectMode: selectMode,
                  onCreateFolder: _showCreateFolderDialog,
                ),
              ),
            ],
          ),
          bottomSheet: bottomSheet(),
        ),
      ),
    );
  }

  Widget? bottomSheet() {
    return Obx(() {
      final selectedItems = getActiveSelectedItems();
      final jobTable = model.jobController.jobTable;

      final localLabel = selectedItems?.isLocal == null
          ? ""
          : " · ${selectedItems!.isLocal ? translate("Local") : translate("Remote")}";
      if (selectMode.value != SelectMode.none) {
        final selectedItemsLen =
            "${selectedItems?.items.length ?? 0} ${translate("items")}";
        if (selectedItems == null ||
            selectedItems.items.isEmpty ||
            selectMode.value.eq(showLocal)) {
          return BottomSheetBody(
            leading: Icon(
              CamelliaIcons.check,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: translate("Selected"),
            text: selectedItemsLen + localLabel,
            onCanceled: () {
              selectedItems?.items.clear();
              selectMode.value = SelectMode.none;
              setState(() {});
            },
            actions: [
              GlassIconButton(
                icon: CamelliaIcons.transfer,
                size: 34,
                iconSize: 17,
                tooltip: showLocal ? translate('Remote') : translate('Local'),
                onPressed: () => setState(() => showLocal = !showLocal),
              ),
              const SizedBox(width: 6),
              GlassIconButton(
                icon: CamelliaIcons.trash,
                size: 34,
                iconSize: 17,
                accentColor: CamelliaGlassTokens.of(context).statusAlert,
                tooltip: translate('Delete'),
                onPressed: selectedItems != null && selectedItems.items.isNotEmpty
                    ? () async {
                        await currentFileController.removeAction(selectedItems);
                        selectedItems.items.clear();
                        selectMode.value = SelectMode.none;
                      }
                    : null,
              ),
            ],
          );
        } else {
          return BottomSheetBody(
            leading: Icon(
              CamelliaIcons.paste,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: translate("Paste here?"),
            text: selectedItemsLen + localLabel,
            onCanceled: () {
              selectedItems.items.clear();
              selectMode.value = SelectMode.none;
              setState(() {});
            },
            actions: [
              GlassIconButton(
                icon: CamelliaIcons.transfer,
                size: 34,
                iconSize: 17,
                tooltip: showLocal ? translate('Remote') : translate('Local'),
                onPressed: () => setState(() => showLocal = !showLocal),
              ),
              const SizedBox(width: 6),
              GlassButton(
                variant: GlassButtonVariant.primary,
                minHeight: 34,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                icon: const Icon(CamelliaIcons.paste, size: 15),
                onPressed: () {
                  selectMode.value = SelectMode.none;
                  final otherSide = showLocal
                      ? model.remoteController
                      : model.localController;
                  final thisSideData = DirectoryData(
                    currentDir,
                    currentOptions,
                  );
                  otherSide.sendFiles(selectedItems, thisSideData);
                  selectedItems.items.clear();
                  selectMode.value = SelectMode.none;
                },
                child: Text(translate('Paste')),
              ),
            ],
          );
        }
      }

      if (jobTable.isEmpty) {
        return const Offstage();
      }

      final activeJob =
          jobTable.firstWhereOrNull(
            (job) => job.state == JobState.inProgress,
          ) ??
          jobTable.last;

      switch (activeJob.state) {
        case JobState.inProgress:
          return BottomSheetBody(
            leading: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                value: activeJob.effectiveTotalSize > 0
                    ? activeJob.percent.clamp(0.0, 1.0)
                    : null,
              ),
            ),
            title: translate("Transfer Queue"),
            text:
                "${translate("Speed")}: ${readableFileSize(activeJob.speed)}/s",
            progress: activeJob.effectiveTotalSize > 0
                ? activeJob.percent.clamp(0.0, 1.0)
                : null,
            onTap: _showTransferQueueSheet,
            onCanceled: () {
              model.jobController.cancelJob(activeJob.id);
              jobTable.clear();
            },
          );
        case JobState.done:
          return BottomSheetBody(
            leading: Icon(
              CamelliaIcons.check,
              color: CamelliaGlassTokens.of(context).statusOnline,
            ),
            title: "${translate("Successful")}!",
            text: activeJob.display(),
            onTap: _showTransferQueueSheet,
            onCanceled: () => jobTable.clear(),
          );
        case JobState.error:
          return BottomSheetBody(
            leading: Icon(
              Icons.error_outline_rounded,
              color: CamelliaGlassTokens.of(context).statusAlert,
            ),
            title: "${translate("Error")}!",
            text: activeJob.getStatus(),
            onTap: _showTransferQueueSheet,
            onCanceled: () => jobTable.clear(),
          );
        case JobState.paused:
          return BottomSheetBody(
            leading: Icon(
              Icons.pause_circle_outline_rounded,
              color: CamelliaGlassTokens.of(context).statusHighLatency,
            ),
            title: translate("Paused"),
            text: activeJob.jobName,
            onTap: _showTransferQueueSheet,
            actions: [
              GlassIconButton(
                tooltip: translate("Resume"),
                icon: CamelliaIcons.refresh,
                size: 34,
                iconSize: 17,
                onPressed: () => model.jobController.resumeJob(activeJob.id),
              ),
            ],
            onCanceled: () {
              model.jobController.cancelJob(activeJob.id);
              jobTable.clear();
            },
          );
        case JobState.none:
          break;
      }
      return const Offstage();
    });
  }

  SelectedItems? getActiveSelectedItems() {
    final localSelectedItems = model.localController.selectedItems;
    final remoteSelectedItems = model.remoteController.selectedItems;

    if (localSelectedItems.items.isNotEmpty &&
        remoteSelectedItems.items.isNotEmpty) {
      debugPrint("Wrong SelectedItems state, reset");
      localSelectedItems.clear();
      remoteSelectedItems.clear();
    }

    if (localSelectedItems.items.isEmpty && remoteSelectedItems.items.isEmpty) {
      return null;
    }

    if (localSelectedItems.items.length > remoteSelectedItems.items.length) {
      return localSelectedItems;
    } else {
      return remoteSelectedItems;
    }
  }
}

class FileManagerView extends StatefulWidget {
  final FileController controller;
  final Rx<SelectMode> selectMode;
  final VoidCallback? onCreateFolder;

  const FileManagerView({
    super.key,
    required this.controller,
    required this.selectMode,
    this.onCreateFolder,
  });

  @override
  State<StatefulWidget> createState() => _FileManagerViewState();
}

class _FileManagerViewState extends State<FileManagerView> {
  final _listScrollController = ScrollController();
  final _breadCrumbScroller = ScrollController();
  late final ascending = Rx<bool>(controller.sortAscending);

  bool get isLocal => widget.controller.isLocal;
  FileController get controller => widget.controller;
  SelectedItems get _selectedItems => widget.controller.selectedItems;

  StreamSubscription<FileDirectory>? _directorySubscription;

  @override
  void initState() {
    super.initState();
    _directorySubscription = controller.directory.listen(
      (_) => breadCrumbScrollToEnd(),
    );
  }

  @override
  void dispose() {
    _directorySubscription?.cancel();
    _directorySubscription = null;
    _breadCrumbScroller.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  Future<void> _showSortSheet() async {
    await showGlassBottomSheet<void>(
      context: context,
      title: translate('Sort by'),
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        final dark = theme.brightness == Brightness.dark;
        final accent = dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
          child: Obx(
            () => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final sortOption in SortBy.values)
                  ListTile(
                    dense: true,
                    title: Text(
                      translate(sortOption.toString()),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: controller.sortBy.value == sortOption
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: controller.sortBy.value == sortOption
                            ? accent
                            : null,
                      ),
                    ),
                    trailing: controller.sortBy.value == sortOption
                        ? Icon(
                            ascending.value
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded,
                            size: 18,
                            color: accent,
                          )
                        : null,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      if (controller.sortBy.value == sortOption) {
                        ascending.value = !controller.sortAscending;
                      } else {
                        ascending.value = true;
                      }
                      controller.changeSortStyle(
                        sortOption,
                        ascending: ascending.value,
                      );
                      Navigator.of(sheetCtx).pop();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showEntryActionsSheet(Entry entry) async {
    final canRename =
        !entry.isDrive && versionCmp(gFFI.ffiModel.pi.version, "1.3.0") >= 0;
    await showGlassBottomSheet<void>(
      context: context,
      title: entry.name,
      builder: (sheetCtx) {
        final glass = CamelliaGlassTokens.of(sheetCtx);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.checklist_rounded),
                title: Text(translate("Multi Select")),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _selectedItems.clear();
                  widget.selectMode.toggle(isLocal);
                  if (widget.selectMode.value != SelectMode.none) {
                    _selectedItems.add(entry);
                  }
                  setState(() {});
                },
              ),
              if (canRename)
                ListTile(
                  leading: const Icon(CamelliaIcons.edit),
                  title: Text(translate("Rename")),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    controller.renameAction(entry, isLocal);
                  },
                ),
              ListTile(
                leading: Icon(CamelliaIcons.trash, color: glass.statusAlert),
                title: Text(
                  translate("Delete"),
                  style: TextStyle(
                    color: glass.statusAlert,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  final items = SelectedItems(isLocal: isLocal)..add(entry);
                  controller.removeAction(items);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: headTools(),
        ),
        Expanded(
          child: Obx(() {
            final entries = controller.directory.value.entries;
            if (entries.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CamelliaStateIllustration(
                        glyph: CamelliaGlyph.emptyFiles,
                        size: 58,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        translate('Empty Directory'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        controller.directory.value.path,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: CamelliaTypography.tabular(
                          theme.textTheme.bodySmall?.copyWith(
                            color: tokens.muted,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          GlassButton(
                            variant: GlassButtonVariant.secondary,
                            minHeight: 36,
                            icon: const Icon(CamelliaIcons.refresh, size: 16),
                            onPressed: controller.refresh,
                            child: Text(translate('Refresh File')),
                          ),
                          if (controller.directory.value.path != "/" &&
                              widget.onCreateFolder != null)
                            GlassButton(
                              variant: GlassButtonVariant.secondary,
                              minHeight: 36,
                              icon: const Icon(
                                CamelliaIcons.folderNew,
                                size: 16,
                              ),
                              onPressed: widget.onCreateFolder,
                              child: Text(translate('Create Folder')),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }

            return ListView.builder(
              controller: _listScrollController,
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 24),
              itemCount: entries.length + 1,
              itemBuilder: (context, index) {
                if (index >= entries.length) {
                  return listTail();
                }
                final entry = entries[index];
                var selected = false;
                if (widget.selectMode.value != SelectMode.none) {
                  selected = _selectedItems.items.contains(entry);
                }

                final sizeStr = entry.isFile
                    ? readableFileSize(entry.size.toDouble())
                    : "";
                final showCheckBox =
                    widget.selectMode.value != SelectMode.none &&
                    widget.selectMode.value.eq(
                      controller.selectedItems.isLocal,
                    );
                final iconColor = CamelliaIcons.fileTypeColor(
                  context,
                  entry.name,
                  isDirectory: !entry.isFile,
                  isDrive: entry.isDrive,
                );

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected
                          ? accent.withValues(alpha: dark ? 0.18 : 0.10)
                          : tokens.surface.withValues(
                              alpha: dark ? 0.78 : 0.88,
                            ),
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.control,
                      ),
                      border: Border.all(
                        color: selected
                            ? accent.withValues(alpha: 0.65)
                            : tokens.border.withValues(alpha: 0.85),
                        width: 0.85,
                      ),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        dense: true,
                        minTileHeight: 54,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: iconColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            CamelliaIcons.fileTypeIcon(
                              entry.name,
                              isDirectory: !entry.isFile,
                              isDrive: entry.isDrive,
                            ),
                            size: 19,
                            color: iconColor,
                          ),
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        selected: selected,
                        subtitle: entry.isDrive
                            ? null
                            : Text(
                                "${entry.lastModified().toString().replaceAll(".000", "")}${sizeStr.isEmpty ? "" : "  ·  $sizeStr"}",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CamelliaTypography.tabular(
                                  theme.textTheme.bodySmall?.copyWith(
                                    color: tokens.muted,
                                  ),
                                ),
                              ),
                        trailing: entry.isDrive
                            ? Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                                color: tokens.muted,
                              )
                            : showCheckBox
                            ? Checkbox(
                                value: selected,
                                onChanged: (v) {
                                  if (v == null) return;
                                  HapticFeedback.selectionClick();
                                  if (v && !selected) {
                                    _selectedItems.add(entry);
                                  } else if (!v && selected) {
                                    _selectedItems.remove(entry);
                                  }
                                  setState(() {});
                                },
                              )
                            : GlassIconButton(
                                icon: CamelliaIcons.more,
                                size: 32,
                                iconSize: 16,
                                tooltip: translate('More'),
                                onPressed: () => _showEntryActionsSheet(entry),
                              ),
                        onTap: () {
                          if (showCheckBox) {
                            HapticFeedback.selectionClick();
                            if (selected) {
                              _selectedItems.remove(entry);
                            } else {
                              _selectedItems.add(entry);
                            }
                            setState(() {});
                            return;
                          }
                          if (entry.isDirectory || entry.isDrive) {
                            controller.openDirectory(entry.path);
                          }
                        },
                        onLongPress: entry.isDrive
                            ? null
                            : () {
                                HapticFeedback.mediumImpact();
                                _selectedItems.clear();
                                widget.selectMode.toggle(isLocal);
                                if (widget.selectMode.value !=
                                    SelectMode.none) {
                                  _selectedItems.add(entry);
                                }
                                setState(() {});
                              },
                      ),
                    ),
                  ),
                );
              },
            );
          }),
        ),
      ],
    );
  }

  void breadCrumbScrollToEnd() {
    Future.delayed(const Duration(milliseconds: 200), () {
      if (_breadCrumbScroller.hasClients) {
        _breadCrumbScroller.animateTo(
          _breadCrumbScroller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.fastLinearToSlowEaseIn,
        );
      }
    });
  }

  Widget headTools() {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return GlassSurface(
      layer: CamelliaGlassLayer.floating,
      showShadow: false,
      enableBlur: false,
      borderRadius: BorderRadius.circular(CamelliaRadius.surface),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Obx(() {
              final home = controller.options.value.home;
              final isWindows = controller.options.value.isWindows;
              return BreadCrumb(
                items: getPathBreadCrumbItems(
                  controller.shortPath,
                  isWindows,
                  () => controller.goToHomeDirectory(),
                  (list) {
                    var path = "";
                    if (home.startsWith(list[0])) {
                      for (var item in list) {
                        path = PathUtil.join(path, item, isWindows);
                      }
                    } else {
                      path += home;
                      for (var item in list) {
                        path = PathUtil.join(path, item, isWindows);
                      }
                    }
                    controller.openDirectory(path);
                  },
                ),
                divider: Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: tokens.muted,
                ),
                overflow: ScrollableOverflow(controller: _breadCrumbScroller),
              );
            }),
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: CamelliaIcons.arrowBack,
            size: 32,
            iconSize: 16,
            tooltip: translate('Back'),
            onPressed: () {
              controller.goBack();
            },
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: CamelliaIcons.arrowUp,
            size: 32,
            iconSize: 16,
            tooltip: translate('Up'),
            onPressed: controller.goToParentDirectory,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: Icons.sort_rounded,
            size: 32,
            iconSize: 16,
            tooltip: translate('Sort by'),
            onPressed: _showSortSheet,
          ),
        ],
      ),
    );
  }

  Widget listTail() => Obx(() {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 68),
      child: Column(
        children: [
          Text(
            controller.directory.value.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CamelliaTypography.tabular(
              theme.textTheme.labelSmall?.copyWith(color: tokens.muted),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            "${translate("Total")}: ${controller.directory.value.entries.length} ${translate("items")}",
            style: CamelliaTypography.tabular(
              theme.textTheme.labelSmall?.copyWith(color: tokens.muted),
            ),
          ),
        ],
      ),
    );
  });

  List<BreadCrumbItem> getPathBreadCrumbItems(
    String shortPath,
    bool isWindows,
    void Function() onHome,
    void Function(List<String>) onPressed,
  ) {
    final theme = Theme.of(context);
    final list = PathUtil.split(shortPath, isWindows);
    final breadCrumbList = <BreadCrumbItem>[
      BreadCrumbItem(
        content: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onHome,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              CamelliaIcons.home,
              size: 17,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    ];
    breadCrumbList.addAll(
      list.asMap().entries.map(
        (e) => BreadCrumbItem(
          content: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => onPressed(list.sublist(0, e.key + 1)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                e.value,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: e.key == list.length - 1
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return breadCrumbList;
  }
}

class BottomSheetBody extends StatelessWidget {
  const BottomSheetBody({
    super.key,
    required this.leading,
    required this.title,
    required this.text,
    this.progress,
    this.onTap,
    this.onCanceled,
    this.actions,
  });

  final Widget leading;
  final String title;
  final String text;
  final double? progress;
  final VoidCallback? onTap;
  final VoidCallback? onCanceled;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionButtons = <Widget>[
      ...?actions,
      if (actions != null && actions!.isNotEmpty) const SizedBox(width: 6),
      GlassIconButton(
        icon: CamelliaIcons.close,
        size: 34,
        iconSize: 17,
        tooltip: translate('Cancel'),
        onPressed: onCanceled,
      ),
    ];

    Widget card = GlassSurface(
      layer: CamelliaGlassLayer.modal,
      elevated: true,
      borderRadius: BorderRadius.circular(CamelliaRadius.sheet),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (text.isNotEmpty)
                      Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CamelliaTypography.tabular(
                          theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ...actionButtons,
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(minHeight: 3, value: progress),
            ),
          ],
        ],
      ),
    );

    if (onTap != null) {
      card = GestureDetector(onTap: onTap, child: card);
    }

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: card,
    );
  }
}
