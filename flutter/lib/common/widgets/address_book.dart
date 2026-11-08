import 'package:bot_toast/bot_toast.dart';
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
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';
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
  var menuPos = RelativeRect.fill;
  final _tagsMenuController = MenuController();

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
    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Row(
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 208),
                  child: _buildAbDropdown(),
                ),
              ),
              const Spacer(),
              if (!hideAbTagsPanel.value) _buildTagsMenuButton(),
              const SizedBox(width: 4),
              _buildAbPermission(),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _buildPeersViews(),
      ],
    );
  }

  Widget _buildTagsMenuButton() => Obx(() {
    final selectedCount = gFFI.abModel.selectedTags.length;
    final mediaSize = MediaQuery.sizeOf(context);
    final popoverWidth = (mediaSize.width - 24).clamp(0.0, 280.0).toDouble();
    final popoverHeight = (mediaSize.height - 24).clamp(0.0, 400.0).toDouble();
    return MenuAnchor(
      controller: _tagsMenuController,
      alignmentOffset: const Offset(0, 4),
      style: MenuStyle(
        minimumSize: WidgetStatePropertyAll(Size(popoverWidth, 0)),
        maximumSize: WidgetStatePropertyAll(Size(popoverWidth, popoverHeight)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: AppVisual.border(context)),
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
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        translate('Tags'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Listener(
                      onPointerDown: (event) {
                        final x = event.position.dx;
                        final y = event.position.dy;
                        menuPos = RelativeRect.fromLTRB(x, y, x, y);
                      },
                      onPointerUp: (_) {
                        _tagsMenuController.close();
                        _showMenu(menuPos);
                      },
                      child: build_more(context, invert: true),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 2,
                      runSpacing: 2,
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
      builder: (context, controller, child) => Tooltip(
        message: translate('Tags'),
        child: IconButton(
          onPressed: controller.isOpen ? controller.close : controller.open,
          icon: Badge.count(
            count: selectedCount,
            isLabelVisible: selectedCount > 0,
            child: const Icon(Icons.sell_outlined, size: 19),
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

    Row buildItem(String e, {bool button = false}) {
      return Row(
        children: [
          if (button) ...[
            Icon(
              Icons.menu_book_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Tooltip(
              waitDuration: Duration(milliseconds: 500),
              message: gFFI.abModel.translatedName(e),
              child: Text(
                gFFI.abModel.translatedName(e),
                style: button ? null : TextStyle(fontSize: 14.0),
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
    final TextEditingController textEditingController = TextEditingController();

    final isOptFixed = isOptionFixed(kOptionCurrentAbName);
    return DropdownButton2<String>(
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
        () => SizedBox(
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: buildItem(gFFI.abModel.currentName.value, button: true),
              ),
              const Icon(Icons.arrow_drop_down, size: 20),
            ],
          ),
        ),
      ),
      underline: Container(
        height: 0.7,
        color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
      ),
      menuItemStyleData: const MenuItemStyleData(),
      dropdownSeparator: contains && items.length > 1
          ? const DropdownSeparator(height: 4, child: Divider())
          : null,
      items: items,
      isExpanded: true,
      isDense: true,
      dropdownSearchData: DropdownSearchData(
        searchController: textEditingController,
        searchBarWidgetHeight: 50,
        searchBarWidget: Container(
          height: 50,
          padding: const EdgeInsets.only(top: 8, bottom: 4, right: 8, left: 8),
          child: TextFormField(
            expands: true,
            maxLines: null,
            controller: textEditingController,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              hintText: translate('Search'),
              hintStyle: const TextStyle(fontSize: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ).workaroundFreezeLinuxMint(),
        ),
        searchMatchFn: (item, searchValue) {
          return item.value.toString().toLowerCase().contains(
            searchValue.toLowerCase(),
          );
        },
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
    IDTextEditingController idController = IDTextEditingController(text: '');
    TextEditingController aliasController = TextEditingController(text: '');
    TextEditingController passwordController = TextEditingController(text: '');
    TextEditingController noteController = TextEditingController(text: '');
    final tags = List.of(gFFI.abModel.currentAbTags);
    var selectedTag = List<dynamic>.empty(growable: true).obs;
    final style = TextStyle(fontSize: 14.0);
    String? errorMsg;
    final isCurrentAbShared = !gFFI.abModel.current.isPersonal();

    gFFI.dialogManager.show((setState, close, context) {
      submit() async {
        setState(() {
          isInProgress = true;
          errorMsg = null;
        });
        String id = idController.id;
        if (id.isEmpty) {
          // pass
        } else {
          if (gFFI.abModel.idContainByCurrent(id)) {
            setState(() {
              isInProgress = false;
              errorMsg = translate('ID already exists');
            });
            return;
          }
          var password = '';
          if (isCurrentAbShared) {
            password = passwordController.text;
          }
          String? errMsg2 = await gFFI.abModel.addIdToCurrent(
            id,
            aliasController.text.trim(),
            password,
            selectedTag,
            noteController.text,
          );
          if (errMsg2 != null) {
            setState(() {
              isInProgress = false;
              errorMsg = errMsg2;
            });
            return;
          }
          // final currentPeers
        }
        close();
      }

      double marginBottom = 4;

      row({required Widget label, required Widget input}) {
        makeChild(bool isPortrait) => Row(
          children: [
            !isPortrait
                ? ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 100),
                    child: label.marginOnly(right: 10),
                  )
                : SizedBox.shrink(),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 200),
                child: input,
              ),
            ),
          ],
        ).marginOnly(bottom: !isPortrait ? 8 : 0);
        return Obx(() => makeChild(stateGlobal.isPortrait.isTrue));
      }

      return CustomAlertDialog(
        title: Text(translate("Add ID")),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                row(
                  label: Row(
                    children: [
                      Text(
                        '*',
                        style: TextStyle(color: Colors.red, fontSize: 14),
                      ),
                      Text('ID', style: style),
                    ],
                  ),
                  input: Obx(
                    () => TextField(
                      controller: idController,
                      inputFormatters: [IDTextInputFormatter()],
                      decoration: InputDecoration(
                        labelText: stateGlobal.isPortrait.isFalse
                            ? null
                            : translate('ID'),
                        errorText: errorMsg,
                        errorMaxLines: 5,
                      ),
                    ).workaroundFreezeLinuxMint(),
                  ),
                ),
                row(
                  label: Text(translate('Alias'), style: style),
                  input: Obx(
                    () => TextField(
                      controller: aliasController,
                      decoration: InputDecoration(
                        labelText: stateGlobal.isPortrait.isFalse
                            ? null
                            : translate('Alias'),
                      ),
                    ).workaroundFreezeLinuxMint(),
                  ),
                ),
                if (isCurrentAbShared)
                  row(
                    label: Text(translate('Password'), style: style),
                    input: Obx(
                      () => TextField(
                        controller: passwordController,
                        obscureText: !passwordVisible,
                        decoration: InputDecoration(
                          labelText: stateGlobal.isPortrait.isFalse
                              ? null
                              : translate('Password'),
                          suffixIcon: IconButton(
                            icon: Icon(
                              passwordVisible
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              color: MyTheme.lightTheme.primaryColor,
                            ),
                            onPressed: () {
                              setState(() {
                                passwordVisible = !passwordVisible;
                              });
                            },
                          ),
                        ),
                      ).workaroundFreezeLinuxMint(),
                    ),
                  ),
                row(
                  label: Text(translate('Note'), style: style),
                  input: Obx(
                    () => TextField(
                      controller: noteController,
                      maxLines: 3,
                      minLines: 1,
                      maxLength: 300,
                      decoration: InputDecoration(
                        labelText: stateGlobal.isPortrait.isFalse
                            ? null
                            : translate('Note'),
                      ),
                    ).workaroundFreezeLinuxMint(),
                  ),
                ),
                if (gFFI.abModel.currentAbTags.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(translate('Tags'), style: style),
                  ).marginOnly(top: 8, bottom: marginBottom),
                if (gFFI.abModel.currentAbTags.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
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
                  ),
              ],
            ),
            const SizedBox(height: 4.0),
            if (!gFFI.abModel.current.isPersonal())
              Row(
                children: [
                  Icon(Icons.info, color: Colors.amber).marginOnly(right: 4),
                  Text(
                    translate('share_warning_tip'),
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ).marginSymmetric(vertical: 10),
            // NOT use Offstage to wrap LinearProgressIndicator
            if (isInProgress) const LinearProgressIndicator(),
          ],
        ),
        actions: [
          dialogButton("Cancel", onPressed: close, isOutline: true),
          dialogButton("OK", onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    });
  }

  void abAddTag() async {
    var field = "";
    var msg = "";
    var isInProgress = false;
    TextEditingController controller = TextEditingController(text: field);
    gFFI.dialogManager.show((setState, close, context) {
      submit() async {
        setState(() {
          msg = "";
          isInProgress = true;
        });
        field = controller.text.trim();
        if (field.isEmpty) {
          // pass
        } else {
          final tags = field.trim().split(RegExp(r"[\s,;\n]+"));
          field = tags.join(',');
          for (var t in [kUntagged, translate(kUntagged)]) {
            if (tags.contains(t)) {
              BotToast.showText(
                contentColor: Colors.red,
                text: 'Tag name cannot be "$t"',
              );
              isInProgress = false;
              return;
            }
          }
          gFFI.abModel.addTags(tags);
          // final currentPeers
        }
        close();
      }

      return CustomAlertDialog(
        title: Text(translate("Add Tag")),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate("whitelist_sep")),
            const SizedBox(height: 8.0),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    maxLines: null,
                    decoration: InputDecoration(
                      errorText: msg.isEmpty ? null : translate(msg),
                    ),
                    controller: controller,
                    autofocus: true,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ),
            const SizedBox(height: 4.0),
            // NOT use Offstage to wrap LinearProgressIndicator
            if (isInProgress) const LinearProgressIndicator(),
          ],
        ),
        actions: [
          dialogButton("Cancel", onPressed: close, isOutline: true),
          dialogButton("OK", onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    });
  }
}

class AddressBookTag extends StatelessWidget {
  final String name;
  final RxList<dynamic> tags;
  final Function()? onTap;
  final bool showActionMenu;

  const AddressBookTag({
    Key? key,
    required this.name,
    required this.tags,
    this.onTap,
    this.showActionMenu = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var pos = RelativeRect.fill;

    void setPosition(TapDownDetails e) {
      final x = e.globalPosition.dx;
      final y = e.globalPosition.dy;
      pos = RelativeRect.fromLTRB(x, y, x, y);
    }

    final isUnTagged = name == kUntagged;
    final showAction = showActionMenu && !isUnTagged;
    return GestureDetector(
      onTapDown: showAction ? setPosition : null,
      onSecondaryTapDown: showAction ? setPosition : null,
      onSecondaryTap: showAction ? () => _showMenu(context, pos) : null,
      onLongPress: showAction ? () => _showMenu(context, pos) : null,
      child: Obx(() {
        final theme = Theme.of(context);
        final selected = tags.contains(name);
        final tagColor = gFFI.abModel.getCurrentAbTagColor(name);
        final selectedForeground =
            ThemeData.estimateBrightnessForColor(tagColor) == Brightness.dark
            ? Colors.white
            : const Color(0xFF171A21);
        return Semantics(
          selected: selected,
          button: true,
          label: isUnTagged ? translate(name) : name,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
            child: Material(
              color: selected ? tagColor : theme.colorScheme.surfaceContainer,
              shape: StadiumBorder(
                side: BorderSide(
                  color: selected ? tagColor : theme.colorScheme.outlineVariant,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                customBorder: const StadiumBorder(),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: 34,
                    maxWidth: 180,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isUnTagged) ...[
                          Container(
                            width: 8,
                            height: 8,
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
    final items = [
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
                Future.delayed(Duration.zero, () => Get.back());
                return true;
              } else {
                showToast(translate('Failed'));
                return false;
              }
            }
            Future.delayed(Duration.zero, () => Get.back());
            return true;
          },
          onCancel: () {
            Future.delayed(Duration.zero, () => Get.back());
          },
        );
      }),
      getEntry(translate(translate('Change Color')), () async {
        final model = gFFI.abModel;
        Color oldColor = model.getCurrentAbTagColor(name);
        Color newColor = await showColorPickerDialog(
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
      getEntry(translate("Delete"), () async {
        final ok = await gFFI.abModel.deleteTag(name);
        if (ok) {
          showToast(translate('Successful'));
        } else {
          showToast(translate('Failed'));
        }
        Future.delayed(Duration.zero, () => Get.back());
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
}

MenuEntryButton<String> getEntry(String title, VoidCallback proc) {
  return MenuEntryButton<String>(
    childBuilder: (TextStyle? style) => Text(title, style: style),
    proc: proc,
    dismissOnClicked: true,
  );
}
