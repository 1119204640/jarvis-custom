import 'package:flutter/material.dart';
import '../models/chat_message.dart';

/// 用户消息气泡 — 靠右对齐，彩色背景
class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12).copyWith(
            bottomRight: const Radius.circular(2),
          ),
        ),
        child: Text(
          message.content,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
