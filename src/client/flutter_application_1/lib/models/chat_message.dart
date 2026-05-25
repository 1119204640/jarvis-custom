/// 聊天消息数据模型
class ChatMessage {
  final String id;
  final String role; // 'user' 或 'assistant'
  final String content;
  final DateTime createdAt;
  final bool isStreaming; // 是否正在流式接收中

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.isStreaming = false,
  });

  /// 复制并修改部分字段（不可变数据模式）
  ChatMessage copyWith({
    String? content,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
}
