import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/widgets/popup_menu.dart';
import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import 'package:get/get.dart';
import 'package:flex_color_picker/flex_color_picker.dart';

import '../../common.dart';
import 'dialog.dart';
import 'login.dart';
import 'address_book_operation_panel.dart';

final hideAbTagsPanel = false.obs;

class AddressBook extends StatefulWidget {
  final EdgeInsets? menuPadding;
  const AddressBook({Key? key, this.menuPadding}) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _AddressBookState();
  }
}

class _AddressBookState extends State<AddressBook> {
  Offset _lastPointerPos = Offset.zero;
  final _tagsMenuController = MenuController();
  final _abSearchController = TextEditingController();

  RelativeRect _resolveMenuRect(Offset globalPos) {
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    final overlaySize = overlay?.size ?? MediaQuery.sizeOf(context);
    final local = overlay != null
        ? overlay.globalToLocal(globalPos)
        : globalPos;
    return RelativeRect.fromRect(
      Rect.fromLTWH(local.dx, local.dy, 0, 0),
      Offset.zero & overlaySize,
    );
  }

  @override
  void dispose() {
    _abSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    if (!gFFI.userModel.isLogin) {
      final state = gFFI.userModel.accountState.value;
      return AppStatePane(
        state: state == UserAccountState.loading
            ? AppContentState.loading
            : state == UserAccountState.disabled
            ? AppContentState.disabled
            : state == UserAccountState.error
            ? AppContentState.error
            : AppContentState.empty,
        title: state == UserAccountState.disabled
            ? translate('Account disabled')
            : translate('Sign in to address book'),
        message: state == UserAccountState.error
            ? translate('Account information is unavailable')
            : translate('Your shared devices and contacts appear here'),
        actionLabel: state == UserAccountState.disabled
            ? null
            : translate('Login'),
        onAction: state == UserAccountState.disabled ? null : loginDialog,
      );
    } else {
      return Column(
        children: [
          AddressBookOperationPanel(
            ready: gFFI.abModel.mutationJournalReady.value,
            busy: gFFI.abModel.mutationBusy.value,
            storageError: gFFI.abModel.mutationJournalError.value,
            status: gFFI.abModel.mutationStatus.value,
            pending: gFFI.abModel.pendingMutations.toList(),
            onRefresh: gFFI.abModel.refreshMutationJournal,
            onRecover: gFFI.abModel.recoverMutation,
            onReconcile: (operation, confirmedId) =>
                gFFI.abModel.reconcileMutation(
                  operation,
                  confirmedId: confirmedId,
                  verifiedOriginalState: true,
                ),
          ),
          if (gFFI.userModel.accountState.value == UserAccountState.offline)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: AppVisual.toneContainer(context, AppTone.warning),
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_off_rounded,
                    size: 17,
                    color: AppVisual.tone(context, AppTone.warning),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      translate('Offline - showing saved address book'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (gFFI.abModel.currentAbLoading.value &&
              gFFI.abModel.currentAbEmpty)
            const LinearProgressIndicator(),
          buildErrorBanner(
            context,
            loading: gFFI.abModel.currentAbLoading,
            err: gFFI.abModel.abPullError,
            retry: null,
            close: gFFI.abModel.clearPullErrors,
          ),
          buildErrorBanner(
            context,
            loading: gFFI.abModel.currentAbLoading,
            err: gFFI.abModel.currentAbPushError,
            retry: null, // remove retry
            close: () => gFFI.abModel.currentAbPushError.value = '',
          ),
          Expanded(child: _buildAddressBookContent()),
        ],
      );
    }
  });

  Widget _buildAddressBookContent() {
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: GlassSurface(
            layer: CamelliaGlassLayer.floating,
            showShadow: false,
            enableBlur: false,
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
            borderTopColor: glass.specularTop,
            borderBottomColor: tokens.border,
            strokeWidth: 0.85,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compactToolbar = constraints.maxWidth < 520;
                return SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 230),
                          child: _buildAbDropdown(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Spacer(),
                      Obx(() {
                        final canWrite = gFFI.abModel.current.canWrite();
                        if (!canWrite) return const SizedBox.shrink();
                        if (compactToolbar) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: GlassIconButton(
                              icon: CamelliaIcons.add,
                              size: 32,
                              iconSize: 17,
                              tooltip: translate('Add ID'),
                              onPressed: addIdToCurrentAb,
                            ),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GlassButton(
                            variant: GlassButtonVariant.secondary,
                            minHeight: 32,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 5,
                            ),
                            icon: const Icon(CamelliaIcons.add, size: 16),
                            onPressed: addIdToCurrentAb,
                            child: Text(translate('Add ID')),
                          ),
                        );
                      }),
                      if (!hideAbTagsPanel.value) _buildTagsMenuButton(),
                      const SizedBox(width: 4),
                      Listener(
                        onPointerDown: (event) {
                          _lastPointerPos = event.position;
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) =>
                              _showMenu(_resolveMenuRect(details.globalPosition)),
                          child: Tooltip(
                            message: translate('More'),
                            child: build_more(context),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      _buildAbPermission(),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildPeersViews(),
      ],
    );
  }

  Widget _buildTagsMenuButton() => Obx(() {
    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    final selectedCount = gFFI.abModel.selectedTags.length;
    final canWrite = gFFI.abModel.current.canWrite();
    final mediaSize = MediaQuery.sizeOf(context);
    final popoverWidth = (mediaSize.width - 24).clamp(0.0, 296.0).toDouble();
    final popoverHeight = (mediaSize.height - 24).clamp(0.0, 400.0).toDouble();
    return MenuAnchor(
      controller: _tagsMenuController,
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(tokens.surfaceElevated),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        minimumSize: WidgetStatePropertyAll(Size(popoverWidth, 0)),
        maximumSize: WidgetStatePropertyAll(Size(popoverWidth, popoverHeight)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CamelliaRadius.surface),
            side: BorderSide(color: tokens.border, width: 0.85),
          ),
        ),
      ),
      menuChildren: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: popoverWidth,
            maxHeight: popoverHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        translate('Tags'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (canWrite)
                      GlassIconButton(
                        icon: CamelliaIcons.add,
                        size: 28,
                        iconSize: 15,
                        tooltip: translate('Add Tag'),
                        onPressed: () {
                          _tagsMenuController.close();
                          abAddTag();
                        },
                      ),
                    const SizedBox(width: 4),
                    Listener(
                      onPointerDown: (event) {
                        _lastPointerPos = event.position;
                      },
                      onPointerUp: (_) {
                        _tagsMenuController.close();
                        _showMenu(_resolveMenuRect(_lastPointerPos));
                      },
                      child: build_more(context, invert: true),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final tag in _addressBookTags()) _tagBuilder(tag),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => GlassButton(
        variant: selectedCount > 0
            ? GlassButtonVariant.primary
            : GlassButtonVariant.subtle,
        minHeight: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        tooltip: translate('Tags'),
        icon: const Icon(Icons.sell_outlined, size: 15),
        onPressed: controller.isOpen ? controller.close : controller.open,
        child: Text(
          selectedCount > 0
              ? '${translate('Tags')} ($selectedCount)'
              : translate('Tags'),
          style: CamelliaTypography.tabular(
            theme.textTheme.labelMedium?.copyWith(
              color: selectedCount > 0 ? Colors.white : null,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  });

  List<String> _addressBookTags() {
    final tags = gFFI.abModel.currentAbTags
        .map((tag) => tag.toString())
        .toList(growable: true);
    if (gFFI.abModel.sortTags.value) {
      tags.sort(
        (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
      );
    }
    return [kUntagged, ...tags];
  }

  Widget _tagBuilder(String tag) {
    return AddressBookTag(
      name: tag,
      tags: gFFI.abModel.selectedTags,
      onTap: () {
        if (gFFI.abModel.selectedTags.contains(tag)) {
          gFFI.abModel.selectedTags.remove(tag);
        } else {
          gFFI.abModel.selectedTags.add(tag);
        }
      },
      showActionMenu: gFFI.abModel.current.canWrite(),
    );
  }

  Widget _buildAbPermission() {
    icon(IconData data, String tooltip) {
      return Tooltip(
        message: translate(tooltip),
        waitDuration: Duration.zero,
        child: SizedBox.square(
          dimension: 32,
          child: Center(
            child: Icon(
              data,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Obx(() {
      if (gFFI.abModel.current.isPersonal()) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [icon(Icons.cloud_off, "Personal")],
        );
      } else {
        List<Widget> children = [];
        final rule = gFFI.abModel.current.sharedProfile()?.rule;
        if (rule == ShareRule.read.value) {
          children.add(
            icon(Icons.visibility, ShareRule.desc(ShareRule.read.value)),
          );
        } else if (rule == ShareRule.readWrite.value) {
          children.add(
            icon(Icons.edit, ShareRule.desc(ShareRule.readWrite.value)),
          );
        } else if (rule == ShareRule.fullControl.value) {
          children.add(
            icon(Icons.security, ShareRule.desc(ShareRule.fullControl.value)),
          );
        }
        final owner = gFFI.abModel.current.sharedProfile()?.owner;
        if (owner != null) {
          children.add(icon(Icons.person, "${translate("Owner")}: $owner"));
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: children,
        );
      }
    });
  }

  Widget _buildAbDropdown() {
    final names = gFFI.abModel.addressBookNames();
    if (!names.contains(gFFI.abModel.currentName.value)) {
      return Offstage();
    }
    // order: personal, divider, character order
    // https://pub.dev/packages/dropdown_button2#3-dropdownbutton2-with-items-of-different-heights-like-dividers
    final personalAddressBookName = gFFI.abModel.personalAddressBookName();
    bool contains = names.remove(personalAddressBookName);
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (contains) {
      names.insert(0, personalAddressBookName);
    }

    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    Row buildItem(String e, {bool button = false}) {
      return Row(
        children: [
          if (button) ...[
            Icon(
              CamelliaIcons.addressBook,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Tooltip(
              waitDuration: const Duration(milliseconds: 500),
              message: gFFI.abModel.translatedName(e),
              child: Text(
                gFFI.abModel.translatedName(e),
                style: button
                    ? theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      )
                    : theme.textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.start,
              ),
            ),
          ),
        ],
      );
    }

    final items = names
        .map((e) => DropdownItem(value: e, height: 36, child: buildItem(e)))
        .toList();
    final TextEditingController textEditingController = _abSearchController;

    final isOptFixed = isOptionFixed(kOptionCurrentAbName);
    return DropdownButtonHideUnderline(
      child: DropdownButton2<String>(
        valueListenable: ValueNotifier(gFFI.abModel.currentName.value),
        onChanged: isOptFixed
            ? null
            : (value) {
                if (value != null) {
                  gFFI.abModel.setCurrentName(value);
                  bind.setLocalFlutterOption(k: kOptionCurrentAbName, v: value);
                }
              },
        customButton: Obx(
          () => MouseRegion(
            cursor: isOptFixed
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  Expanded(
                    child: buildItem(
                      gFFI.abModel.currentName.value,
                      button: true,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        dropdownStyleData: DropdownStyleData(
          maxHeight: 320,
          offset: const Offset(0, -4),
          decoration: BoxDecoration(
            color: tokens.surfaceElevated,
            borderRadius: BorderRadius.circular(CamelliaRadius.surface),
            border: Border.all(color: tokens.border, width: 0.85),
            boxShadow: [
              BoxShadow(
                color: tokens.shadowStrong,
                blurRadius: 18,
                spreadRadius: -2,
                offset: const Offset(0, 8),
              ),
            ],
          ),
        ),
        menuItemStyleData: const MenuItemStyleData(
          padding: EdgeInsets.symmetric(horizontal: 12),
        ),
        dropdownSeparator: contains && items.length > 1
            ? DropdownSeparator(
                height: 8,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Center(
                    child: Container(height: 0.85, color: tokens.border),
                  ),
                ),
              )
            : null,
        items: items,
        isExpanded: true,
        isDense: true,
        dropdownSearchData: DropdownSearchData(
          searchController: textEditingController,
          searchBarWidgetHeight: 48,
          searchBarWidget: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: GlassInput(
              controller: textEditingController,
              minHeight: 36,
              prefixIcon: CamelliaIcons.search,
              hintText: translate('Search'),
              showClearButton: true,
            ).workaroundFreezeLinuxMint(),
          ),
          searchMatchFn: (item, searchValue) {
            final q = searchValue.toLowerCase();
            final raw = item.value.toString().toLowerCase();
            final translated = gFFI.abModel
                .translatedName(item.value.toString())
                .toLowerCase();
            return raw.contains(q) || translated.contains(q);
          },
        ),
      ),
    );
  }

  Widget _buildPeersViews() {
    return Expanded(
      child: Align(
        alignment: Alignment.topLeft,
        child: AddressBookPeersView(menuPadding: widget.menuPadding),
      ),
    );
  }

  @protected
  MenuEntryBase<String> syncMenuItem() {
    final isOptFixed = isOptionFixed(syncAbOption);
    return MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate('Sync with recent sessions'),
      getter: () async {
        return shouldSyncAb();
      },
      setter: (bool v) async {
        gFFI.abModel.setShouldAsync(v);
      },
      dismissOnClicked: true,
      enabled: (!isOptFixed).obs,
    );
  }

  @protected
  MenuEntryBase<String> sortMenuItem() {
    final isOptFixed = isOptionFixed(sortAbTagsOption);
    return MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate('Sort tags'),
      getter: () async {
        return shouldSortTags();
      },
      setter: (bool v) async {
        bind.mainSetLocalOption(
          key: sortAbTagsOption,
          value: v ? 'Y' : defaultOptionNo,
        );
        gFFI.abModel.sortTags.value = v;
      },
      dismissOnClicked: true,
      enabled: (!isOptFixed).obs,
    );
  }

  @protected
  MenuEntryBase<String> filterMenuItem() {
    final isOptFixed = isOptionFixed(filterAbTagOption);
    return MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate('Filter by intersection'),
      getter: () async {
        return filterAbTagByIntersection();
      },
      setter: (bool v) async {
        bind.mainSetLocalOption(
          key: filterAbTagOption,
          value: v ? 'Y' : defaultOptionNo,
        );
        gFFI.abModel.filterByIntersection.value = v;
      },
      dismissOnClicked: true,
      enabled: (!isOptFixed).obs,
    );
  }

  void _showMenu(RelativeRect pos) {
    final canWrite = gFFI.abModel.current.canWrite();
    final items = [
      if (canWrite) getEntry(translate("Add ID"), addIdToCurrentAb),
      if (canWrite) getEntry(translate("Add Tag"), abAddTag),
      getEntry(translate("Unselect all tags"), gFFI.abModel.unsetSelectedTags),
      sortMenuItem(),
      if (canWrite) syncMenuItem(),
      filterMenuItem(),
      if (canWrite) MenuEntryDivider<String>(),
      if (canWrite)
        getEntry(translate("ab_web_console_tip"), () async {
          final url = await bind.mainGetApiServer();
          if (await canLaunchUrlString(url)) {
            launchUrlString(url);
          }
        }),
    ];

    mod_menu.showMenu(
      context: context,
      position: pos,
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
    );
  }

  void addIdToCurrentAb() async {
    if (gFFI.abModel.isCurrentAbFull(true)) {
      return;
    }
    var isInProgress = false;
    var passwordVisible = false;
    final idController = IDTextEditingController(text: '');
    final aliasController = TextEditingController(text: '');
    final passwordController = TextEditingController(text: '');
    final noteController = TextEditingController(text: '');
    final tags = List.of(gFFI.abModel.currentAbTags);
    final selectedTag = List<dynamic>.empty(growable: true).obs;
    String? errorMsg;
    final isCurrentAbShared = !gFFI.abModel.current.isPersonal();
    var disposed = false;

    void cleanup() {
      if (disposed) return;
      disposed = true;
      idController.dispose();
      aliasController.dispose();
      passwordController.clear();
      passwordController.dispose();
      noteController.dispose();
      selectedTag.close();
    }

    try {
      await gFFI.dialogManager.show((setState, close, context) {
        void handleClose() {
          cleanup();
          close();
        }

        Future<void> submit() async {
          if (isInProgress) return;
          final String id = idController.id.trim();
          if (id.isEmpty) {
            setState(() => errorMsg = translate('Can not be empty'));
            return;
          }
          setState(() {
            isInProgress = true;
            errorMsg = null;
          });
          if (gFFI.abModel.idContainByCurrent(id)) {
            setState(() {
              isInProgress = false;
              errorMsg = translate('ID already exists');
            });
            return;
          }
          final password = isCurrentAbShared ? passwordController.text : '';
          final String? errMsg2 = await gFFI.abModel.addIdToCurrent(
            id,
            aliasController.text.trim(),
            password,
            selectedTag,
            noteController.text,
          );
          if (errMsg2 != null) {
            setState(() {
              isInProgress = false;
              errorMsg = formatUserFriendlyError(errMsg2);
            });
            return;
          }
          handleClose();
        }

        final theme = Theme.of(context);
        final tokens = AppVisual.tokens(context);
        final glass = CamelliaGlassTokens.of(context);

        return CustomAlertDialog(
          title: ModernDialogHeader(
            icon: CamelliaIcons.addressBook,
            title: translate("Add ID"),
            subtitle: gFFI.abModel.translatedName(
              gFFI.abModel.currentName.value,
            ),
            onClose: isInProgress ? null : handleClose,
          ),
          contentBoxConstraints: const BoxConstraints(maxWidth: 460),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlassInput(
                  controller: idController,
                  autofocus: true,
                  tabularNums: true,
                  labelText: '${translate('ID')} *',
                  hintText: translate('Enter Remote ID'),
                  errorText: errorMsg,
                  showPasteButton: true,
                  inputFormatters: [IDTextInputFormatter()],
                  onChanged: (_) {
                    if (errorMsg != null) {
                      setState(() => errorMsg = null);
                    }
                  },
                ).workaroundFreezeLinuxMint(),
                const SizedBox(height: 12),
                GlassInput(
                  controller: aliasController,
                  labelText: translate('Alias'),
                  hintText: translate('Alias'),
                ).workaroundFreezeLinuxMint(),
                if (isCurrentAbShared) ...[
                  const SizedBox(height: 12),
                  GlassInput(
                    controller: passwordController,
                    obscureText: !passwordVisible,
                    showClearButton: false,
                    labelText: translate('Password'),
                    hintText: translate('Password'),
                    trailing: IconButton(
                      tooltip: passwordVisible
                          ? translate('Hide Password')
                          : translate('Show Password'),
                      icon: Icon(
                        passwordVisible
                            ? CamelliaIcons.eyeOff
                            : CamelliaIcons.eye,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () {
                        setState(() => passwordVisible = !passwordVisible);
                      },
                    ),
                  ).workaroundFreezeLinuxMint(),
                ],
                const SizedBox(height: 12),
                GlassInput(
                  controller: noteController,
                  maxLines: 3,
                  labelText: translate('Note'),
                  hintText: translate('Note'),
                ).workaroundFreezeLinuxMint(),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    translate('Tags'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: tags
                        .map(
                          (e) => AddressBookTag(
                            name: e,
                            tags: selectedTag,
                            onTap: () {
                              if (selectedTag.contains(e)) {
                                selectedTag.remove(e);
                              } else {
                                selectedTag.add(e);
                              }
                            },
                            showActionMenu: false,
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
                if (isCurrentAbShared) ...[
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: glass.statusHighLatency.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.control,
                      ),
                      border: Border.all(color: tokens.border, width: 0.85),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: glass.statusHighLatency,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              translate('share_warning_tip'),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                // NOT use Offstage to wrap LinearProgressIndicator
                if (isInProgress) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
          actions: [
            GlassButton(
              variant: GlassButtonVariant.secondary,
              onPressed: isInProgress ? null : handleClose,
              icon: const Icon(CamelliaIcons.close, size: 17),
              child: Text(translate('Cancel')),
            ),
            GlassButton(
              variant: GlassButtonVariant.primary,
              loading: isInProgress,
              onPressed: isInProgress ? null : submit,
              icon: const Icon(CamelliaIcons.check, size: 17),
              child: Text(translate('OK')),
            ),
          ],
          onSubmit: isInProgress ? null : submit,
          onCancel: isInProgress ? null : handleClose,
        );
      });
    } finally {
      cleanup();
    }
  }

  void abAddTag() async {
    var field = "";
    var msg = "";
    var isInProgress = false;
    final controller = TextEditingController(text: field);
    var disposed = false;

    void cleanup() {
      if (disposed) return;
      disposed = true;
      controller.dispose();
    }

    try {
      await gFFI.dialogManager.show((setState, close, context) {
        void handleClose() {
          cleanup();
          close();
        }

        Future<void> submit() async {
          if (isInProgress) return;
          field = controller.text.trim();
          if (field.isEmpty) {
            handleClose();
            return;
          }
          setState(() {
            msg = "";
            isInProgress = true;
          });
          final tags = field
              .split(RegExp(r"[\s,;\n]+"))
              .map((t) => t.trim())
              .where((t) => t.isNotEmpty)
              .toList();
          for (final t in [kUntagged, translate(kUntagged)]) {
            if (tags.contains(t)) {
              showToast(translate('Tag name cannot be empty'));
              setState(() => isInProgress = false);
              return;
            }
          }
          gFFI.abModel.addTags(tags);
          handleClose();
        }

        return CustomAlertDialog(
          title: ModernDialogHeader(
            icon: Icons.sell_outlined,
            title: translate("Add Tag"),
            subtitle: translate("whitelist_sep"),
            onClose: isInProgress ? null : handleClose,
          ),
          contentBoxConstraints: const BoxConstraints(maxWidth: 440),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlassInput(
                  controller: controller,
                  autofocus: true,
                  maxLines: 2,
                  labelText: translate('Tags'),
                  hintText: translate('Tags'),
                  errorText: msg.isEmpty ? null : translate(msg),
                ).workaroundFreezeLinuxMint(),
                // NOT use Offstage to wrap LinearProgressIndicator
                if (isInProgress) ...[
                  const SizedBox(height: 10),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
          actions: [
            GlassButton(
              variant: GlassButtonVariant.secondary,
              onPressed: isInProgress ? null : handleClose,
              icon: const Icon(CamelliaIcons.close, size: 17),
              child: Text(translate('Cancel')),
            ),
            GlassButton(
              variant: GlassButtonVariant.primary,
              loading: isInProgress,
              onPressed: isInProgress ? null : submit,
              icon: const Icon(CamelliaIcons.check, size: 17),
              child: Text(translate('OK')),
            ),
          ],
          onSubmit: isInProgress ? null : submit,
          onCancel: isInProgress ? null : handleClose,
        );
      });
    } finally {
      cleanup();
    }
  }
}

class AddressBookTag extends StatelessWidget {
  final String name;
  final RxList<dynamic> tags;
  final Function()? onTap;
  final bool showActionMenu;

  const AddressBookTag({
    super.key,
    required this.name,
    required this.tags,
    this.onTap,
    this.showActionMenu = true,
  });

  RelativeRect _resolveRect(BuildContext context, Offset globalPos) {
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    final overlaySize = overlay?.size ?? MediaQuery.sizeOf(context);
    final local = overlay != null
        ? overlay.globalToLocal(globalPos)
        : globalPos;
    return RelativeRect.fromRect(
      Rect.fromLTWH(local.dx, local.dy, 0, 0),
      Offset.zero & overlaySize,
    );
  }

  @override
  Widget build(BuildContext context) {
    Offset tapPos = Offset.zero;

    void setPosition(TapDownDetails e) {
      tapPos = e.globalPosition;
    }

    final isUnTagged = name == kUntagged;
    final showAction = showActionMenu && !isUnTagged;
    return GestureDetector(
      onTapDown: showAction ? setPosition : null,
      onSecondaryTapDown: showAction ? setPosition : null,
      onSecondaryTap: showAction
          ? () => _showMenu(context, _resolveRect(context, tapPos))
          : null,
      onLongPress: showAction
          ? () => _showMenu(context, _resolveRect(context, tapPos))
          : null,
      child: Obx(() {
        final theme = Theme.of(context);
        final tokens = AppVisual.tokens(context);
        final selected = tags.contains(name);
        final tagColor = gFFI.abModel.getCurrentAbTagColor(name);
        final selectedForeground =
            ThemeData.estimateBrightnessForColor(tagColor) == Brightness.dark
            ? Colors.white
            : const Color(0xFF0F172A);
        return Semantics(
          selected: selected,
          button: true,
          label: isUnTagged ? translate(name) : name,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Material(
              color: selected
                  ? tagColor
                  : tokens.surfaceContainer.withValues(alpha: 0.78),
              shape: StadiumBorder(
                side: BorderSide(
                  color: selected ? tagColor : tokens.border,
                  width: 0.85,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                customBorder: const StadiumBorder(),
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.transparent,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: 32,
                    maxWidth: 180,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isUnTagged) ...[
                          Container(
                            width: 7.5,
                            height: 7.5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected ? selectedForeground : tagColor,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            isUnTagged ? translate(name) : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: selected
                                  ? selectedForeground
                                  : theme.colorScheme.onSurface,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
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
      }),
    );
  }

  void _showMenu(BuildContext context, RelativeRect pos) {
    final items = <MenuEntryBase<String>>[
      getEntry(translate("Rename"), () {
        renameDialog(
          oldName: name,
          validator: (String? newName) {
            if (newName == null || newName.isEmpty) {
              return translate('Can not be empty');
            }
            if (newName != name &&
                gFFI.abModel.currentAbTags.contains(newName)) {
              return translate('Already exists');
            }
            return null;
          },
          onSubmit: (String newName) async {
            if (name != newName) {
              final ok = await gFFI.abModel.renameTag(name, newName);
              if (ok) {
                showToast(translate('Successful'));
                return true;
              } else {
                showToast(translate('Failed'));
                return false;
              }
            }
            return true;
          },
        );
      }),
      getEntry(translate('Change Color'), () async {
        final model = gFFI.abModel;
        final Color oldColor = model.getCurrentAbTagColor(name);
        final Color newColor = await showColorPickerDialog(
          context,
          oldColor,
          pickersEnabled: {
            ColorPickerType.accent: false,
            ColorPickerType.wheel: true,
          },
          pickerTypeLabels: {
            ColorPickerType.primary: translate("Primary Color"),
            ColorPickerType.wheel: translate("HSV Color"),
          },
          actionButtons: ColorPickerActionButtons(
            dialogOkButtonLabel: translate("OK"),
            dialogCancelButtonLabel: translate("Cancel"),
          ),
          showColorCode: true,
        );
        if (oldColor != newColor) {
          model.setTagColor(name, newColor);
        }
      }),
      MenuEntryDivider<String>(),
      MenuEntryButton<String>(
        isDestructive: true,
        dismissOnClicked: true,
        childBuilder: (TextStyle? style) => Text(translate("Delete"), style: style),
        proc: () {
          deleteConfirmDialog(
            () async {
              final ok = await gFFI.abModel.deleteTag(name);
              if (ok) {
                showToast(translate('Successful'));
                return true;
              } else {
                showToast(translate('Failed'));
                return false;
              }
            },
            '${translate('Delete')} "$name"?',
          );
        },
      ),
    ];

    mod_menu.showMenu(
      context: context,
      position: pos,
      items: items
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
          .toList(),
      elevation: 8,
    );
  }
}

MenuEntryButton<String> getEntry(String title, VoidCallback proc) {
  return MenuEntryButton<String>(
    childBuilder: (TextStyle? style) => Text(title, style: style),
    proc: proc,
    dismissOnClicked: true,
  );
}
