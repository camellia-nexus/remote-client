import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';

import '../../common.dart';

class MyGroup extends StatefulWidget {
  final EdgeInsets? menuPadding;
  const MyGroup({super.key, this.menuPadding});

  @override
  State<StatefulWidget> createState() {
    return _MyGroupState();
  }
}

class _MyGroupState extends State<MyGroup> {
  RxBool get isSelectedDeviceGroup => gFFI.groupModel.isSelectedDeviceGroup;
  RxString get selectedAccessibleItemName =>
      gFFI.groupModel.selectedAccessibleItemName;
  RxString get searchAccessibleItemNameText =>
      gFFI.groupModel.searchAccessibleItemNameText;
  final TextEditingController searchUserController = TextEditingController();

  @override
  void dispose() {
    searchUserController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
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
              : translate('Sign in to view accessible devices'),
          message: state == UserAccountState.error
              ? translate('Account information is unavailable')
              : translate('Devices shared with your group or account appear here'),
          actionLabel: state == UserAccountState.disabled
              ? null
              : translate('Login'),
          onAction: state == UserAccountState.disabled ? null : loginDialog,
        );
      } else if (gFFI.userModel.networkError.isNotEmpty) {
        return AppStatePane(
          state: AppContentState.error,
          title: translate('network_error_tip'),
          message: formatUserFriendlyError(gFFI.userModel.networkError.value),
          actionLabel: translate('Retry'),
          onAction: gFFI.userModel.refreshCurrentUser,
        );
      } else if (gFFI.groupModel.groupLoading.value && gFFI.groupModel.emtpy) {
        return AppStatePane(
          state: AppContentState.loading,
          title: translate('Loading...'),
          message: translate('Please wait'),
        );
      }
      return Column(
        children: [
          buildErrorBanner(
            context,
            loading: gFFI.groupModel.groupLoading,
            err: gFFI.groupModel.groupLoadError,
            retry: null,
            close: () => gFFI.groupModel.groupLoadError.value = '',
          ),
          Expanded(
            child: Obx(
              () => stateGlobal.isPortrait.isTrue
                  ? _buildPortrait()
                  : _buildLandscape(),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildLandscape() {
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 210,
          child: GlassSurface(
            layer: CamelliaGlassLayer.floating,
            showShadow: false,
            enableBlur: false,
            borderRadius: BorderRadius.circular(CamelliaRadius.surface),
            borderTopColor: glass.specularTop,
            borderBottomColor: tokens.border,
            strokeWidth: 0.85,
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildLeftHeader(),
                const SizedBox(height: 8),
                Expanded(child: _buildLeftList()),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: MyGroupPeerView(menuPadding: widget.menuPadding),
          ),
        ),
      ],
    );
  }

  Widget _buildPortrait() {
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassSurface(
          layer: CamelliaGlassLayer.floating,
          showShadow: false,
          enableBlur: false,
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
          borderTopColor: glass.specularTop,
          borderBottomColor: tokens.border,
          strokeWidth: 0.85,
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildLeftHeader(),
              const SizedBox(height: 8),
              _buildLeftList(),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: MyGroupPeerView(menuPadding: widget.menuPadding),
          ),
        ),
      ],
    );
  }

  Widget _buildLeftHeader() {
    return GlassInput(
      controller: searchUserController,
      minHeight: 36,
      prefixIcon: CamelliaIcons.search,
      hintText: translate('Search'),
      showClearButton: true,
      onChanged: (value) {
        searchAccessibleItemNameText.value = value;
        selectedAccessibleItemName.value = '';
      },
      onClear: () {
        searchAccessibleItemNameText.value = '';
        selectedAccessibleItemName.value = '';
      },
    ).workaroundFreezeLinuxMint();
  }

  Widget _buildLeftList() {
    final theme = Theme.of(context);
    return Obx(() {
      final userItems = gFFI.groupModel.users.where((p0) {
        if (searchAccessibleItemNameText.isNotEmpty) {
          final search = searchAccessibleItemNameText.value.toLowerCase();
          return p0.name.toLowerCase().contains(search) ||
              p0.displayNameOrName.toLowerCase().contains(search);
        }
        return true;
      }).toList();

      final displayNameCount = <String, int>{};
      for (final u in userItems) {
        final dn = u.displayNameOrName;
        displayNameCount[dn] = (displayNameCount[dn] ?? 0) + 1;
      }

      final deviceGroupItems = gFFI.groupModel.deviceGroups.where((p0) {
        if (searchAccessibleItemNameText.isNotEmpty) {
          return p0.name.toLowerCase().contains(
            searchAccessibleItemNameText.value.toLowerCase(),
          );
        }
        return true;
      }).toList();

      if (deviceGroupItems.isEmpty && userItems.isEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CamelliaStateIllustration(
                glyph: CamelliaGlyph.emptyGroups,
                size: 40,
              ),
              const SizedBox(height: 8),
              Text(
                translate('Empty'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        );
      }

      final entries = <Widget>[
        _buildAllFilterTile(),
        if (deviceGroupItems.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Text(
              translate('Device Groups'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final g in deviceGroupItems) _buildDeviceGroupItem(g),
        ],
        if (userItems.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Text(
              translate('Users'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final u in userItems) _buildUserItem(u, displayNameCount),
        ],
      ];

      Widget listView(bool isPortrait) => ListView.separated(
        shrinkWrap: isPortrait,
        padding: const EdgeInsets.symmetric(vertical: 2),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (context, index) => entries[index],
      );

      final maxHeight = math.max(
        MediaQuery.sizeOf(context).height / 5.2,
        120.0,
      );
      return Obx(
        () => stateGlobal.isPortrait.isFalse
            ? listView(false)
            : LimitedBox(maxHeight: maxHeight, child: listView(true)),
      );
    });
  }

  Widget _buildAllFilterTile() {
    return Obx(() {
      final selected = selectedAccessibleItemName.value.isEmpty;
      return _GroupFilterTile(
        selected: selected,
        leading: Icon(
          CamelliaIcons.deviceGroup,
          size: 16,
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        label: translate('Accessible devices'),
        onTap: () {
          selectedAccessibleItemName.value = '';
        },
      );
    });
  }

  Widget _buildUserItem(UserPayload user, Map<String, int> displayNameCount) {
    final username = user.name;
    final dn = user.displayNameOrName;
    final isDuplicate = (displayNameCount[dn] ?? 0) > 1;
    final displayName = isDuplicate && user.displayName.trim().isNotEmpty
        ? '${user.displayName} (@$username)'
        : dn;

    return Obx(() {
      final selected =
          !isSelectedDeviceGroup.value &&
          selectedAccessibleItemName.value == username;
      final isMe = username == gFFI.userModel.userName.value;
      final initial = displayName.isNotEmpty
          ? displayName.characters.first.toUpperCase()
          : '?';

      return _GroupFilterTile(
        selected: selected,
        leading: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: str2color(username, 0xCC),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
        ),
        label: displayName,
        trailing: isMe
            ? GlassBadge(
                label: translate('Me'),
                tone: GlassBadgeTone.online,
                compact: true,
              )
            : null,
        onTap: () {
          isSelectedDeviceGroup.value = false;
          if (selectedAccessibleItemName.value != username) {
            selectedAccessibleItemName.value = username;
          } else {
            selectedAccessibleItemName.value = '';
          }
        },
      );
    });
  }

  Widget _buildDeviceGroupItem(DeviceGroupPayload deviceGroup) {
    final name = deviceGroup.name;
    return Obx(() {
      final selected =
          isSelectedDeviceGroup.value &&
          selectedAccessibleItemName.value == name;
      final theme = Theme.of(context);
      final accent = theme.brightness == Brightness.dark
          ? theme.colorScheme.secondary
          : theme.colorScheme.primary;

      return _GroupFilterTile(
        selected: selected,
        leading: Icon(
          selected
              ? CamelliaIcons.deviceGroup
              : CamelliaIcons.deviceGroupOutlined,
          size: 16,
          color: selected ? accent : theme.colorScheme.onSurfaceVariant,
        ),
        label: name,
        onTap: () {
          isSelectedDeviceGroup.value = true;
          if (selectedAccessibleItemName.value != name) {
            selectedAccessibleItemName.value = name;
          } else {
            selectedAccessibleItemName.value = '';
          }
        },
      );
    });
  }
}

class _GroupFilterTile extends StatefulWidget {
  const _GroupFilterTile({
    required this.selected,
    required this.leading,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  final bool selected;
  final Widget leading;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  State<_GroupFilterTile> createState() => _GroupFilterTileState();
}

class _GroupFilterTileState extends State<_GroupFilterTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final radius = BorderRadius.circular(CamelliaRadius.control);

    final bg = widget.selected
        ? accent.withValues(alpha: dark ? 0.18 : 0.12)
        : (_hovered ? glass.hoverOverlay : Colors.transparent);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) {
          if (mounted && _hovered != v) {
            setState(() => _hovered = v);
          }
        },
        borderRadius: radius,
        hoverColor: glass.hoverOverlay,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        child: AnimatedContainer(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
            border: widget.selected
                ? Border.all(
                    color: accent.withValues(alpha: dark ? 0.35 : 0.25),
                    width: 0.85,
                  )
                : Border.all(color: tokens.border.withValues(alpha: 0.0), width: 0.85),
          ),
          child: Row(
            children: [
              widget.leading,
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: widget.selected
                        ? (dark ? theme.colorScheme.onSurface : accent)
                        : theme.colorScheme.onSurface,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 6),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
