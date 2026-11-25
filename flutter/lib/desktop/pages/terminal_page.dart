import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/terminal_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:xterm/xterm.dart';
import 'terminal_connection_manager.dart';

class TerminalPage extends StatefulWidget {
  TerminalPage({
    Key? key,
    required this.id,
    required this.password,
    required this.tabController,
    required this.isSharedPassword,
    required this.terminalId,
    required this.tabKey,
    this.forceRelay,
    this.connToken,
    this.isTerminalRunAsAdmin = false,
  }) : super(key: key);
  final String id;
  final String? password;
  final DesktopTabController tabController;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final int terminalId;
  final bool isTerminalRunAsAdmin;

  /// Tab key for focus management, passed from parent to avoid duplicate construction
  final String tabKey;
  final SimpleWrapper<State<TerminalPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _TerminalPageState)._ffi;

  @override
  State<TerminalPage> createState() {
    final state = _TerminalPageState();
    _lastState.value = state;
    return state;
  }
}

class _TerminalPageState extends State<TerminalPage>
    with AutomaticKeepAliveClientMixin {
  static const EdgeInsets _defaultTerminalPadding = EdgeInsets.symmetric(
    horizontal: 5.0,
    vertical: 2.0,
  );

  late FFI _ffi;
  late TerminalModel _terminalModel;
  double? _cellHeight;
  double _fontSize = 14.0;
  final _overlayKeyState = OverlayKeyState();
  final FocusNode _terminalFocusNode = FocusNode(canRequestFocus: false);
  StreamSubscription<DesktopTabState>? _tabStateSubscription;

  @override
  void initState() {
    super.initState();

    // Listen for tab selection changes to request focus
    _tabStateSubscription = widget.tabController.state.listen(
      _onTabStateChanged,
    );

    // Use shared FFI instance from connection manager
    _ffi = TerminalConnectionManager.getConnection(
      peerId: widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
      connToken: widget.connToken,
      isTerminalRunAsAdmin: widget.isTerminalRunAsAdmin,
    );
    _ffi.dialogManager.setOverlayState(_overlayKeyState);

    // Create terminal model with specific terminal ID
    _terminalModel = TerminalModel(_ffi, widget.terminalId);
    debugPrint(
      '[TerminalPage] Terminal model created for terminal ${widget.terminalId}',
    );

    _terminalModel.onResizeExternal = (w, h, pw, ph) {
      _cellHeight = ph * 1.0;

      // Enable focus once terminal has valid dimensions (first valid resize)
      if (!_terminalFocusNode.canRequestFocus && w > 0 && h > 0) {
        _terminalFocusNode.canRequestFocus = true;
        // Auto-focus if this tab is currently selected
        _requestFocusIfSelected();
      }

      // Schedule the setState for the next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
    };

    // Register this terminal model with FFI for event routing
    _ffi.registerTerminalModel(widget.terminalId, _terminalModel);

    // Auto-close tab when shell exits
    _terminalModel.onClosed = () {
      if (mounted) {
        widget.tabController.closeBy(widget.tabKey);
      }
    };

    // Initialize terminal connection
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController.onSelected?.call(widget.id);

      // Check if this is a new connection or additional terminal
      // Note: When a connection exists, the ref count will be > 1 after this terminal is added
      final isExistingConnection =
          TerminalConnectionManager.hasConnection(
            widget.id,
            isTerminalRunAsAdmin: widget.isTerminalRunAsAdmin,
          ) &&
          TerminalConnectionManager.getTerminalCount(
                widget.id,
                isTerminalRunAsAdmin: widget.isTerminalRunAsAdmin,
              ) >
              1;

      if (!isExistingConnection) {
        // First terminal - show loading dialog, wait for onReady
        _ffi.dialogManager.showLoading(
          translate('Connecting...'),
          onCancel: closeConnection,
        );
      } else {
        // Additional terminal - connection already established
        // Open the terminal directly
        _terminalModel.openTerminal();
      }
    });
  }

  @override
  void dispose() {
    // Cancel tab state subscription to prevent memory leak
    _tabStateSubscription?.cancel();
    // Unregister terminal model from FFI
    _ffi.unregisterTerminalModel(widget.terminalId);
    _terminalModel.dispose();
    _terminalFocusNode.dispose();
    // Release connection reference instead of closing directly
    TerminalConnectionManager.releaseConnection(
      widget.id,
      isTerminalRunAsAdmin: widget.isTerminalRunAsAdmin,
    );
    super.dispose();
  }

  void _onTabStateChanged(DesktopTabState state) {
    // Check if this tab is now selected and request focus
    if (state.selected >= 0 && state.selected < state.tabs.length) {
      final selectedTab = state.tabs[state.selected];
      if (selectedTab.key == widget.tabKey && mounted) {
        _ffi.dialogManager.setOverlayState(_overlayKeyState);
        _requestFocusIfSelected();
      }
    }
  }

  void _requestFocusIfSelected() {
    if (!mounted || !_terminalFocusNode.canRequestFocus) return;
    // Use post-frame callback to ensure widget is fully laid out in focus tree
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Re-check conditions after frame: mounted, focusable, still selected, not already focused
      if (!mounted ||
          !_terminalFocusNode.canRequestFocus ||
          _terminalFocusNode.hasFocus)
        return;
      final state = widget.tabController.state.value;
      if (state.selected >= 0 && state.selected < state.tabs.length) {
        if (state.tabs[state.selected].key == widget.tabKey) {
          _terminalFocusNode.requestFocus();
        }
      }
    });
  }

  // This method ensures that the number of visible rows is an integer by computing the
  // extra space left after dividing the available height by the height of a single
  // terminal row (`_cellHeight`) and distributing it evenly as top and bottom padding.
  EdgeInsets _calculatePadding(double heightPx) {
    final cellHeight = _cellHeight;
    if (!heightPx.isFinite ||
        heightPx <= 0 ||
        cellHeight == null ||
        !cellHeight.isFinite ||
        cellHeight <= 0) {
      return _defaultTerminalPadding;
    }
    final rows = (heightPx / cellHeight).floor();
    if (rows <= 0) {
      return _defaultTerminalPadding;
    }
    final extraSpace = heightPx - rows * cellHeight;
    if (!extraSpace.isFinite || extraSpace < 0) {
      return _defaultTerminalPadding;
    }
    final topBottom = extraSpace / 2.0;
    return EdgeInsets.symmetric(
      horizontal: _defaultTerminalPadding.horizontal / 2,
      vertical: topBottom,
    );
  }

  Future<void> _copySelection() async {
    final selection = _terminalModel.terminalController.selection;
    if (selection == null) return;
    final text = _terminalModel.terminal.buffer.getText(selection);
    _terminalModel.terminalController.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
    showToast(translate('Copied'), tone: AppTone.info);
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _terminalModel.terminal.paste(text);
    }
    _requestFocusIfSelected();
  }

  void _clearTerminal() {
    _terminalModel.terminal.buffer.clear();
    _terminalModel.terminal.setCursor(0, 0);
    _requestFocusIfSelected();
  }

  void _adjustFontSize(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(10.0, 28.0);
    });
    _requestFocusIfSelected();
  }

  Widget _buildUtilityBar(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: tokens.surfaceContainer.withValues(alpha: 0.9),
        border: Border(
          bottom: BorderSide(color: tokens.border, width: 0.85),
        ),
      ),
      child: Row(
        children: [
          ListenableBuilder(
            listenable: _terminalModel,
            builder: (context, _) {
              final opened = _terminalModel.terminalOpened;
              final dotColor = opened
                  ? glass.statusOnline
                  : glass.statusConnecting;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    opened ? translate('Connected') : translate('Connecting...'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 10),
          GlassBadge(
            label: widget.isTerminalRunAsAdmin
                ? translate('Admin')
                : translate('Standard'),
            tone: widget.isTerminalRunAsAdmin
                ? GlassBadgeTone.warning
                : GlassBadgeTone.neutral,
            compact: true,
          ),
          const Spacer(),
          GlassIconButton(
            icon: CamelliaIcons.copy,
            size: 26,
            iconSize: 14,
            tooltip: translate('Copy'),
            onPressed: _copySelection,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: Icons.content_paste_rounded,
            size: 26,
            iconSize: 14,
            tooltip: translate('Paste'),
            onPressed: _pasteClipboard,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: Icons.cleaning_services_outlined,
            size: 26,
            iconSize: 14,
            tooltip: translate('Clear Terminal'),
            onPressed: _clearTerminal,
          ),
          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: tokens.border,
          ),
          GlassIconButton(
            icon: CamelliaIcons.minimize,
            size: 24,
            iconSize: 13,
            tooltip: translate('Decrease'),
            onPressed: _fontSize > 10 ? () => _adjustFontSize(-1) : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '${_fontSize.toInt()}px',
              style: CamelliaTypography.tabular(
                theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          GlassIconButton(
            icon: CamelliaIcons.add,
            size: 24,
            iconSize: 13,
            tooltip: translate('Increase'),
            onPressed: _fontSize < 28 ? () => _adjustFontSize(1) : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Overlay(
      key: _overlayKeyState.key,
      initialEntries: [
        OverlayEntry(
          builder: (_) => Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: Column(
              children: [
                _buildUtilityBar(context),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final heightPx = constraints.maxHeight;
                      return TerminalView(
                        _terminalModel.terminal,
                        controller: _terminalModel.terminalController,
                        focusNode: _terminalFocusNode,
                        textStyle: TerminalStyle(fontSize: _fontSize),
                        backgroundOpacity: 0.85,
                        padding: _calculatePadding(heightPx),
                        onSecondaryTapDown: (details, offset) {
                          final hasSelection =
                              _terminalModel.terminalController.selection !=
                              null;
                          showFrostedContextMenu(
                            context: context,
                            globalPosition: details.globalPosition,
                            itemsBuilder: (closeMenu) => [
                              FrostedMenuItem(
                                label: translate('Copy'),
                                icon: CamelliaIcons.copy,
                                onTap: hasSelection
                                    ? () {
                                        closeMenu();
                                        _copySelection();
                                      }
                                    : null,
                              ),
                              FrostedMenuItem(
                                label: translate('Paste'),
                                icon: Icons.content_paste_rounded,
                                onTap: () {
                                  closeMenu();
                                  _pasteClipboard();
                                },
                              ),
                              const FrostedMenuDivider(),
                              FrostedMenuItem(
                                label: translate('Clear Terminal'),
                                icon: Icons.cleaning_services_outlined,
                                onTap: () {
                                  closeMenu();
                                  _clearTerminal();
                                },
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  bool get wantKeepAlive => true;
}
