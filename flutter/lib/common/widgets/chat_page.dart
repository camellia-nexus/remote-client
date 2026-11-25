import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:camellia_remote_app/models/chat_types.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../mobile/pages/home_page.dart';

enum ChatPageType { mobileMain, desktopCM }

class ChatPage extends StatelessWidget implements PageShape {
  late final ChatModel chatModel;
  final ChatPageType? type;

  ChatPage({super.key, ChatModel? chatModel, this.type}) {
    this.chatModel = chatModel ?? gFFI.chatModel;
  }

  @override
  final title = translate("Chat");

  @override
  final icon = unreadTopRightBuilder(gFFI.chatModel.mobileUnreadSum);

  @override
  final appBarActions = [
    Builder(
      builder: (context) => unreadTopRightBuilder(
        gFFI.chatModel.mobileUnreadSum,
        icon: GlassIconButton(
          icon: Icons.forum_outlined,
          tooltip: translate('Chat'),
          size: 38,
          iconSize: 19,
          onPressed: () => showConversationSwitcher(context),
        ),
      ),
    ),
  ];

  /// Opens a physics-damped Liquid Glass bottom sheet listing all active and
  /// recent chat threads so mobile users can switch conversations effortlessly.
  static Future<void> showConversationSwitcher(BuildContext context) {
    final chatModel = gFFI.chatModel;
    final entries = chatModel.messages.entries.toList(growable: false);
    return showGlassBottomSheet<void>(
      context: context,
      title: translate('Conversations'),
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        final glass = CamelliaGlassTokens.of(sheetCtx);
        final accent = theme.brightness == Brightness.dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CamelliaIcons.chat,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 10),
                Text(
                  translate('No active conversations'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: entries.map((entry) {
            final key = entry.key;
            final user = entry.value.chatUser;
            final client = gFFI.serverModel.clients.firstWhereOrNull(
              (e) => e.id == key.connId,
            );
            final connected = client != null && !client.disconnected;
            final selected = key == chatModel.currentKey;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassSurface(
                layer: CamelliaGlassLayer.floating,
                showShadow: false,
                enableBlur: false,
                tintColor: selected ? accent.withValues(alpha: 0.14) : null,
                borderRadius: BorderRadius.circular(CamelliaRadius.control),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    key.isOut
                        ? Icons.call_made_rounded
                        : Icons.call_received_rounded,
                    color: selected
                        ? accent
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    (user.firstName?.isNotEmpty ?? false)
                        ? user.firstName!
                        : user.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    user.id,
                    style: CamelliaTypography.tabular(
                      theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (connected)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: glass.statusOnline,
                          ),
                        ),
                      if (client != null) ...[
                        const SizedBox(width: 6),
                        unreadMessageCountBuilder(
                          client.unreadChatMessageCount,
                        ),
                      ],
                    ],
                  ),
                  onTap: () {
                    chatModel.changeCurrentKey(key);
                    Navigator.of(sheetCtx).pop();
                  },
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: chatModel,
      child: Material(
        type: MaterialType.transparency,
        child: Consumer<ChatModel>(
          builder: (context, chatModel, child) {
            final readOnly =
                type == ChatPageType.mobileMain &&
                    (chatModel.currentKey.connId == ChatModel.clientModeID ||
                        gFFI.serverModel.clients.every(
                          (e) =>
                              e.id != chatModel.currentKey.connId ||
                              chatModel.currentUser == null,
                        )) ||
                type == ChatPageType.desktopCM &&
                    gFFI.serverModel.clients
                            .firstWhereOrNull(
                              (e) => e.id == chatModel.currentKey.connId,
                            )
                            ?.disconnected ==
                        true;
            return LayoutBuilder(
              builder: (context, constraints) {
                final messages =
                    chatModel.messages[chatModel.currentKey]?.chatMessages ??
                    [];
                final chat = Column(
                  children: [
                    Expanded(
                      child: messages.isEmpty
                          ? _ChatEmptyState(readOnly: readOnly)
                          : ListView.builder(
                              reverse: true,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                return _ChatMessageBubble(
                                  message: messages[index],
                                  isOwnMessage:
                                      messages[index].user.id ==
                                      chatModel.me.id,
                                  maxWidth: (constraints.maxWidth * 0.74).clamp(
                                    180.0,
                                    480.0,
                                  ),
                                );
                              },
                            ),
                    ),
                    if (!readOnly) _ChatInput(chatModel: chatModel),
                  ],
                ).workaroundFreezeLinuxMint();
                return SelectionArea(child: chat);
              },
            ).paddingOnly(bottom: 8);
          },
        ),
      ),
    );
  }
}

class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({required this.readOnly});

  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CamelliaStateIllustration(
              glyph: CamelliaGlyph.chat,
              accentColor: accent,
              size: 52,
            ),
            const SizedBox(height: 12),
            Text(
              translate('No messages yet'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              readOnly
                  ? translate(
                      'Start or accept a remote session to exchange messages.',
                    )
                  : translate('Send a message to communicate with the peer.'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatInput extends StatelessWidget {
  final ChatModel chatModel;

  const _ChatInput({required this.chatModel});

  void _send() {
    final text = chatModel.textController.text;
    if (text.trim().isEmpty) return;
    chatModel.sendText(text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: GlassInput(
        controller: chatModel.textController,
        focusNode: chatModel.inputNode,
        hintText: translate('Write a message'),
        showClearButton: false,
        minHeight: 42,
        borderRadius: BorderRadius.circular(CamelliaRadius.pill),
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _send(),
        trailing: GlassIconButton(
          icon: Icons.send_rounded,
          size: 32,
          iconSize: 16,
          selected: true,
          tooltip: translate('Send'),
          onPressed: _send,
        ),
      ),
    );
  }
}

class _ChatMessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isOwnMessage;
  final double maxWidth;

  const _ChatMessageBubble({
    required this.message,
    required this.isOwnMessage,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timestamp =
        "${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}";
    final bubbleRadius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomRight: Radius.circular(isOwnMessage ? 4 : 16),
      bottomLeft: Radius.circular(isOwnMessage ? 16 : 4),
    );

    final Widget content = Column(
      crossAxisAlignment: isOwnMessage
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          message.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: isOwnMessage ? Colors.white : theme.colorScheme.onSurface,
            height: 1.38,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          timestamp,
          style: CamelliaTypography.tabular(
            theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              color: isOwnMessage
                  ? Colors.white.withValues(alpha: 0.78)
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );

    return Align(
      alignment: isOwnMessage ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: isOwnMessage
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: bubbleRadius,
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.24,
                        ),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 9,
                    ),
                    child: content,
                  ),
                )
              : GlassSurface(
                  layer: CamelliaGlassLayer.floating,
                  enableBlur: false,
                  borderRadius: bubbleRadius,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 9,
                  ),
                  child: content,
                ),
        ),
      ),
    );
  }
}
