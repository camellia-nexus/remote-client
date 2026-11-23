import 'dart:core';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../ui/camellia_design.dart';
import '../../ui/glass_components.dart';
import './material_mod_popup_menu.dart' as mod_menu;

// https://stackoverflow.com/questions/68318314/flutter-popup-menu-inside-popup-menu
class PopupMenuChildrenItem<T> extends mod_menu.PopupMenuEntry<T> {
  const PopupMenuChildrenItem({
    key,
    this.height = kMinInteractiveDimension,
    this.padding,
    this.enabled,
    this.textStyle,
    this.onTap,
    this.position = mod_menu.PopupMenuPosition.overSide,
    this.offset = Offset.zero,
    required this.itemBuilder,
    required this.child,
  }) : super(key: key);

  final mod_menu.PopupMenuPosition position;
  final Offset offset;
  final TextStyle? textStyle;
  final EdgeInsets? padding;
  final RxBool? enabled;
  final void Function()? onTap;
  final List<mod_menu.PopupMenuEntry<T>> Function(BuildContext) itemBuilder;
  final Widget child;

  @override
  final double height;

  @override
  bool represents(T? value) => false;

  @override
  MyPopupMenuItemState<T, PopupMenuChildrenItem<T>> createState() =>
      MyPopupMenuItemState<T, PopupMenuChildrenItem<T>>(enabled?.value);
}

class MyPopupMenuItemState<T, W extends PopupMenuChildrenItem<T>>
    extends State<W> {
  RxBool enabled = true.obs;

  MyPopupMenuItemState(bool? e) {
    if (e != null) {
      enabled.value = e;
    }
  }

  @protected
  void handleTap(T value) {
    widget.onTap?.call();
    Navigator.pop<T>(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PopupMenuThemeData popupMenuTheme = PopupMenuTheme.of(context);
    TextStyle style =
        widget.textStyle ??
        popupMenuTheme.textStyle ??
        theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
        ) ??
        TextStyle(color: theme.colorScheme.onSurface);
    return Obx(
      () => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: mod_menu.PopupMenuButton<T>(
          enabled: enabled.value,
          position: widget.position,
          offset: widget.offset,
          onSelected: handleTap,
          itemBuilder: widget.itemBuilder,
          padding: EdgeInsets.zero,
          child: AnimatedDefaultTextStyle(
            style: style,
            duration: kThemeChangeDuration,
            child: Container(
              alignment: AlignmentDirectional.centerStart,
              constraints: BoxConstraints(
                minHeight: widget.height,
                maxHeight: widget.height,
              ),
              padding:
                  widget.padding ?? const EdgeInsets.symmetric(horizontal: 12),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class MenuConfig {
  // adapt to the screen height
  static const fontSize = 14.0;
  static const midPadding = 10.0;
  static const iconScale = 0.8;
  static const iconWidth = 12.0;
  static const iconHeight = 12.0;

  final double height;
  final double dividerHeight;
  final double? boxWidth;
  final Color? commonColor;

  const MenuConfig({
    this.commonColor,
    this.height = kMinInteractiveDimension,
    this.dividerHeight = 16.0,
    this.boxWidth,
  });

  Color resolveAccent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (commonColor == null || commonColor == CamelliaColors.coral) {
      return scheme.primary;
    }
    return commonColor!;
  }
}

typedef DismissCallback = Function();

abstract class MenuEntryBase<T> {
  bool dismissOnClicked;
  DismissCallback? dismissCallback;
  RxBool? enabled;

  MenuEntryBase({
    this.dismissOnClicked = false,
    this.enabled,
    this.dismissCallback,
  });
  List<mod_menu.PopupMenuEntry<T>> build(BuildContext context, MenuConfig conf);

  TextStyle enabledStyle(BuildContext context, {bool destructive = false}) {
    final scheme = Theme.of(context).colorScheme;
    final glass = CamelliaGlassTokens.of(context);
    return (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          color: destructive ? glass.statusAlert : scheme.onSurface,
          fontSize: MenuConfig.fontSize,
          fontWeight: FontWeight.w500,
        );
  }

  TextStyle disabledStyle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          fontSize: MenuConfig.fontSize,
          fontWeight: FontWeight.normal,
        );
  }
}

class MenuEntryDivider<T> extends MenuEntryBase<T> {
  @override
  List<mod_menu.PopupMenuEntry<T>> build(
    BuildContext context,
    MenuConfig conf,
  ) {
    return [mod_menu.PopupMenuDivider(height: conf.dividerHeight)];
  }
}

class MenuEntryRadioOption {
  String text;
  String value;
  bool dismissOnClicked;
  RxBool? enabled;
  DismissCallback? dismissCallback;

  MenuEntryRadioOption({
    required this.text,
    required this.value,
    this.dismissOnClicked = false,
    this.enabled,
    this.dismissCallback,
  });
}

typedef RadioOptionsGetter = List<MenuEntryRadioOption> Function();
typedef RadioCurOptionGetter = Future<String> Function();
typedef RadioOptionSetter =
    Future<void> Function(String oldValue, String newValue);

class MenuEntryRadioUtils<T> {}

class MenuEntryRadios<T> extends MenuEntryBase<T> {
  final String text;
  final RadioOptionsGetter optionsGetter;
  final RadioCurOptionGetter curOptionGetter;
  final RadioOptionSetter optionSetter;
  final RxString _curOption = "".obs;
  final EdgeInsets? padding;

  MenuEntryRadios({
    required this.text,
    required this.optionsGetter,
    required this.curOptionGetter,
    required this.optionSetter,
    this.padding,
    dismissOnClicked = false,
    dismissCallback,
    RxBool? enabled,
  }) : super(
         dismissOnClicked: dismissOnClicked,
         enabled: enabled,
         dismissCallback: dismissCallback,
       ) {
    () async {
      _curOption.value = await curOptionGetter();
    }();
  }

  List<MenuEntryRadioOption> get options => optionsGetter();
  RxString get curOption => _curOption;
  setOption(String option) async {
    await optionSetter(_curOption.value, option);
    if (_curOption.value != option) {
      final opt = await curOptionGetter();
      if (_curOption.value != opt) {
        _curOption.value = opt;
      }
    }
  }

  mod_menu.PopupMenuEntry<T> _buildMenuItem(
    BuildContext context,
    MenuConfig conf,
    MenuEntryRadioOption opt,
  ) {
    final isOptEnabled = opt.enabled?.value ?? true;
    final accent = conf.resolveAccent(context);
    final muted = Theme.of(
      context,
    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.45);

    Widget buildLabel() {
      if (opt.enabled == null) {
        return Text(
          opt.text,
          style: enabledStyle(context),
          overflow: TextOverflow.ellipsis,
        );
      }
      return Obx(
        () => Text(
          opt.text,
          style: opt.enabled!.isTrue
              ? enabledStyle(context)
              : disabledStyle(context),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return mod_menu.PopupMenuItem<T>(
      padding: EdgeInsets.zero,
      height: conf.height,
      enabled: isOptEnabled,
      closeOnTap: opt.dismissOnClicked,
      onTap: isOptEnabled
          ? () {
              if (opt.dismissOnClicked) {
                opt.dismissCallback?.call();
              }
              setOption(opt.value);
            }
          : null,
      child: Container(
        width: conf.boxWidth,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 12),
        alignment: AlignmentDirectional.centerStart,
        constraints: BoxConstraints(
          minHeight: conf.height,
          maxHeight: conf.height,
        ),
        child: Row(
          children: [
            Expanded(child: buildLabel()),
            const SizedBox(width: 8),
            Obx(() {
              final selected = opt.value == curOption.value;
              final active = opt.enabled?.value ?? true;
              if (!selected) return const SizedBox(width: 18);
              return Icon(
                CamelliaIcons.check,
                size: 18,
                color: active ? accent : muted,
              );
            }),
          ],
        ),
      ),
    );
  }

  @override
  List<mod_menu.PopupMenuEntry<T>> build(
    BuildContext context,
    MenuConfig conf,
  ) {
    return options.map((opt) => _buildMenuItem(context, conf, opt)).toList();
  }
}

class MenuEntrySubRadios<T> extends MenuEntryBase<T> {
  final String text;
  final RadioOptionsGetter optionsGetter;
  final RadioCurOptionGetter curOptionGetter;
  final RadioOptionSetter optionSetter;
  final RxString _curOption = "".obs;
  final EdgeInsets? padding;

  MenuEntrySubRadios({
    required this.text,
    required this.optionsGetter,
    required this.curOptionGetter,
    required this.optionSetter,
    this.padding,
    dismissOnClicked = false,
    RxBool? enabled,
  }) : super(dismissOnClicked: dismissOnClicked, enabled: enabled) {
    () async {
      _curOption.value = await curOptionGetter();
    }();
  }

  List<MenuEntryRadioOption> get options => optionsGetter();
  RxString get curOption => _curOption;
  setOption(String option) async {
    await optionSetter(_curOption.value, option);
    if (_curOption.value != option) {
      final opt = await curOptionGetter();
      if (_curOption.value != opt) {
        _curOption.value = opt;
      }
    }
  }

  mod_menu.PopupMenuEntry<T> _buildSecondMenu(
    BuildContext context,
    MenuConfig conf,
    MenuEntryRadioOption opt,
  ) {
    final isOptEnabled = opt.enabled?.value ?? true;
    final accent = conf.resolveAccent(context);
    final muted = Theme.of(
      context,
    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.45);
    return mod_menu.PopupMenuItem<T>(
      padding: EdgeInsets.zero,
      height: conf.height,
      enabled: isOptEnabled,
      closeOnTap: opt.dismissOnClicked,
      onTap: isOptEnabled
          ? () {
              if (opt.dismissOnClicked) {
                opt.dismissCallback?.call();
              }
              setOption(opt.value);
            }
          : null,
      child: Container(
        width: conf.boxWidth,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 12),
        alignment: AlignmentDirectional.centerStart,
        constraints: BoxConstraints(
          minHeight: conf.height,
          maxHeight: conf.height,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                opt.text,
                style: isOptEnabled
                    ? enabledStyle(context)
                    : disabledStyle(context),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Obx(
              () => opt.value == curOption.value
                  ? Icon(
                      CamelliaIcons.check,
                      size: 18,
                      color: isOptEnabled ? accent : muted,
                    )
                  : const SizedBox(width: 18),
            ),
          ],
        ),
      ),
    );
  }

  @override
  List<mod_menu.PopupMenuEntry<T>> build(
    BuildContext context,
    MenuConfig conf,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return [
      PopupMenuChildrenItem(
        enabled: super.enabled,
        padding: padding,
        height: conf.height,
        itemBuilder: (BuildContext context) =>
            options.map((opt) => _buildSecondMenu(context, conf, opt)).toList(),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: enabledStyle(context),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    ];
  }
}

enum SwitchType { sswitch, scheckbox }

typedef SwitchGetter = Future<bool> Function();
typedef SwitchSetter = Future<void> Function(bool);

abstract class MenuEntrySwitchBase<T> extends MenuEntryBase<T> {
  final SwitchType switchType;
  final String text;
  final EdgeInsets? padding;
  Rx<TextStyle>? textStyle;

  MenuEntrySwitchBase({
    required this.switchType,
    required this.text,
    required dismissOnClicked,
    this.textStyle,
    this.padding,
    RxBool? enabled,
    dismissCallback,
  }) : super(
         dismissOnClicked: dismissOnClicked,
         enabled: enabled,
         dismissCallback: dismissCallback,
       );

  bool get isEnabled => enabled?.value ?? true;

  RxBool get curOption;
  Future<void> setOption(bool? option);

  tryPop(BuildContext context) {
    if (dismissOnClicked && Navigator.canPop(context)) {
      Navigator.pop(context);
      super.dismissCallback?.call();
    }
  }

  @override
  List<mod_menu.PopupMenuEntry<T>> build(
    BuildContext context,
    MenuConfig conf,
  ) {
    final scheme = Theme.of(context).colorScheme;
    textStyle ??=
        (isEnabled ? enabledStyle(context) : disabledStyle(context)).obs;
    return [
      mod_menu.PopupMenuItem<T>(
        padding: EdgeInsets.zero,
        height: conf.height,
        enabled: isEnabled,
        closeOnTap: dismissOnClicked,
        onTap: isEnabled
            ? () {
                if (dismissOnClicked) dismissCallback?.call();
                setOption(!curOption.value);
              }
            : null,
        child: SizedBox(
          width: conf.boxWidth,
          height: conf.height,
          child: Padding(
            padding: padding ?? const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Obx(
                    () => Text(
                      text,
                      style: textStyle!.value,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IgnorePointer(
                  child: Transform.scale(
                    scale: MenuConfig.iconScale,
                    child: Obx(() {
                      if (switchType == SwitchType.sswitch) {
                        return Switch.adaptive(
                          value: curOption.value,
                          activeTrackColor: scheme.primary,
                          onChanged: isEnabled ? (_) {} : null,
                        );
                      }
                      return Checkbox(
                        value: curOption.value,
                        onChanged: isEnabled ? (_) {} : null,
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

class MenuEntrySwitch<T> extends MenuEntrySwitchBase<T> {
  final SwitchGetter getter;
  final SwitchSetter setter;
  final RxBool _curOption = false.obs;

  MenuEntrySwitch({
    required SwitchType switchType,
    required String text,
    required this.getter,
    required this.setter,
    Rx<TextStyle>? textStyle,
    EdgeInsets? padding,
    dismissOnClicked = false,
    RxBool? enabled,
    dismissCallback,
  }) : super(
         switchType: switchType,
         text: text,
         textStyle: textStyle,
         padding: padding,
         dismissOnClicked: dismissOnClicked,
         enabled: enabled,
         dismissCallback: dismissCallback,
       ) {
    () async {
      _curOption.value = await getter();
    }();
  }

  @override
  RxBool get curOption => _curOption;
  @override
  setOption(bool? option) async {
    if (option != null) {
      await setter(option);
      final opt = await getter();
      if (_curOption.value != opt) {
        _curOption.value = opt;
      }
    }
  }
}

// Compatible with MenuEntrySwitch, it uses value instead of getter
class MenuEntrySwitchSync<T> extends MenuEntrySwitchBase<T> {
  final SwitchSetter setter;
  final RxBool _curOption = false.obs;

  MenuEntrySwitchSync({
    required SwitchType switchType,
    required String text,
    required bool currentValue,
    required this.setter,
    Rx<TextStyle>? textStyle,
    EdgeInsets? padding,
    dismissOnClicked = false,
    RxBool? enabled,
    dismissCallback,
  }) : super(
         switchType: switchType,
         text: text,
         textStyle: textStyle,
         padding: padding,
         dismissOnClicked: dismissOnClicked,
         enabled: enabled,
         dismissCallback: dismissCallback,
       ) {
    _curOption.value = currentValue;
  }

  @override
  RxBool get curOption => _curOption;
  @override
  setOption(bool? option) async {
    if (option != null) {
      await setter(option);
      // Notice: no ensure with getter, best used on menus that are destroyed on click
      if (_curOption.value != option) {
        _curOption.value = option;
      }
    }
  }
}

typedef Switch2Getter = RxBool Function();
typedef Switch2Setter = Future<void> Function(bool);

class MenuEntrySwitch2<T> extends MenuEntrySwitchBase<T> {
  final Switch2Getter getter;
  final SwitchSetter setter;

  MenuEntrySwitch2({
    required SwitchType switchType,
    required String text,
    required this.getter,
    required this.setter,
    Rx<TextStyle>? textStyle,
    EdgeInsets? padding,
    dismissOnClicked = false,
    RxBool? enabled,
    dismissCallback,
  }) : super(
         switchType: switchType,
         text: text,
         textStyle: textStyle,
         padding: padding,
         dismissOnClicked: dismissOnClicked,
         enabled: enabled,
         dismissCallback: dismissCallback,
       );

  @override
  RxBool get curOption => getter();
  @override
  setOption(bool? option) async {
    if (option != null) {
      await setter(option);
    }
  }
}

class MenuEntrySubMenu<T> extends MenuEntryBase<T> {
  final String text;
  final List<MenuEntryBase<T>> entries;
  final EdgeInsets? padding;

  MenuEntrySubMenu({
    required this.text,
    required this.entries,
    this.padding,
    RxBool? enabled,
  }) : super(enabled: enabled);

  @override
  List<mod_menu.PopupMenuEntry<T>> build(
    BuildContext context,
    MenuConfig conf,
  ) {
    final scheme = Theme.of(context).colorScheme;
    super.enabled ??= true.obs;
    return [
      PopupMenuChildrenItem(
        enabled: super.enabled,
        height: conf.height,
        padding: padding,
        position: mod_menu.PopupMenuPosition.overSide,
        itemBuilder: (BuildContext context) => entries
            .map((entry) => entry.build(context, conf))
            .expand((i) => i)
            .toList(),
        child: Row(
          children: [
            Expanded(
              child: Obx(
                () => Text(
                  text,
                  style: super.enabled!.value
                      ? enabledStyle(context)
                      : disabledStyle(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Obx(
              () => Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: super.enabled!.value
                    ? scheme.onSurfaceVariant
                    : scheme.onSurfaceVariant.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    ];
  }
}

class MenuEntryButton<T> extends MenuEntryBase<T> {
  final Widget Function(TextStyle? style) childBuilder;
  final bool isDestructive;
  Function() proc;
  final EdgeInsets? padding;

  MenuEntryButton({
    required this.childBuilder,
    required this.proc,
    this.padding,
    this.isDestructive = false,
    dismissOnClicked = false,
    RxBool? enabled,
    dismissCallback,
  }) : super(
         dismissOnClicked: dismissOnClicked,
         enabled: enabled,
         dismissCallback: dismissCallback,
       );

  Widget _buildChild(BuildContext context, MenuConfig conf) {
    super.enabled ??= true.obs;
    return Obx(
      () => SizedBox(
        width: conf.boxWidth,
        height: conf.height,
        child: Padding(
          padding: padding ?? const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: childBuilder(
              super.enabled!.value
                  ? enabledStyle(context, destructive: isDestructive)
                  : disabledStyle(context),
            ),
          ),
        ),
      ),
    );
  }

  @override
  List<mod_menu.PopupMenuEntry<T>> build(
    BuildContext context,
    MenuConfig conf,
  ) {
    return [
      mod_menu.PopupMenuItem<T>(
        padding: EdgeInsets.zero,
        height: conf.height,
        enabled: super.enabled?.value ?? true,
        closeOnTap: super.dismissOnClicked,
        onTap: () {
          if (super.dismissOnClicked) super.dismissCallback?.call();
          proc();
        },
        child: _buildChild(context, conf),
      ),
    ];
  }
}

class CustomPopupMenuTheme {
  static const Color commonColor = CamelliaColors.indigo;
  static Color accentColor(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  static Color dangerColor(BuildContext context) =>
      CamelliaGlassTokens.of(context).statusAlert;
  static const double height = 40.0;
  static const double dividerHeight = 8.0;
}
