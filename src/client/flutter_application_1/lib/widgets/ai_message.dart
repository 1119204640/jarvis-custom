import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/chat_message.dart';

/// AI 回复 — 全宽 Markdown 渲染，无气泡包裹
class AiMessage extends StatelessWidget {
  final ChatMessage message;

  const AiMessage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Jarvis',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: MarkdownBody(
                  data: message.content,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                    p: Theme.of(context).textTheme.bodyMedium,
                    code: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              if (message.isStreaming)
                const Padding(
                  padding: EdgeInsets.only(left: 2, top: 2),
                  child: _StreamingCursor(),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 流式传输时的闪烁光标
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 2,
        height: 16,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}
