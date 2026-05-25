import 'dart:async';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/chat_service.dart';
import '../widgets/sidebar.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/message_input.dart';

/// 应用主页面
///
/// 布局结构：
/// - 桌面端：左侧固定侧边栏 + 右侧聊天区（抽屉可收起）
/// - 移动端：汉堡菜单抽屉 + 聊天区
///
/// 管理消息列表、流式接收、与服务端通信。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ChatService _chatService;
  final List<ChatMessage> _messages = [];
  int _selectedFeature = 0;
  bool _isConnected = false;
  bool _isStreaming = false;

  // 流式合并：服务端发来的增量 token 拼到一起
  String _streamingContent = '';
  String _streamingMessageId = '';

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _chatService = ChatService();

    // 注册回调
    _chatService.onConnectionChange = (connected) {
      if (mounted) {
        setState(() => _isConnected = connected);
      }
    };

    _chatService.onMessage = (message) {
      if (mounted) {
        setState(() {
          // 如果流式消息完成了，替换为完整消息
          if (_streamingMessageId.isNotEmpty) {
            // 找到流式消息并替换或追加
            final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
            if (idx >= 0) {
              _messages[idx] = _messages[idx].copyWith(
                content: message.content,
                isStreaming: false,
              );
            }
            // 如果流式内容比完整消息长（不太可能），保留完整消息
            _streamingContent = '';
            _streamingMessageId = '';
          }
          // 避免重复添加
          if (!_messages.any((m) => m.id == message.id)) {
            _messages.add(message);
          }
          _isStreaming = false;
        });
        _scrollToBottom();
      }
    };

    _chatService.onStreamUpdate = (messageId, token) {
      if (!mounted) return;
      setState(() {
        // 特殊标记：流式结束
        if (messageId.endsWith('_done')) {
          final realId = messageId.replaceAll('_done', '');
          final idx = _messages.indexWhere((m) => m.id == realId);
          if (idx >= 0) {
            _messages[idx] = _messages[idx].copyWith(isStreaming: false);
          }
          _isStreaming = false;
          return;
        }

        _isStreaming = true;

        if (messageId != _streamingMessageId) {
          // 新的流式消息开始
          _streamingMessageId = messageId;
          _streamingContent = token;
          _messages.add(ChatMessage(
            id: messageId,
            role: 'assistant',
            content: token,
            createdAt: DateTime.now(),
            isStreaming: true,
          ));
        } else {
          // 追加到已有流式消息
          _streamingContent += token;
          final idx = _messages.indexWhere((m) => m.id == messageId);
          if (idx >= 0) {
            _messages[idx] = _messages[idx].copyWith(content: _streamingContent);
          }
        }
      });
      _scrollToBottom();
    };

    // 启动连接
    _connect();
  }

  Future<void> _connect() async {
    await _chatService.connect();
  }

  void _sendMessage(String text) {
    if (!_isConnected) return;
    _chatService.sendMessage(text);
  }

  void _scrollToBottom() {
    // 下一帧滚动到底部
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _chatService.disconnect();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppSidebar.items[_selectedFeature].title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // 连接状态指示
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: _isConnected ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 4),
                Text(
                  _isConnected ? '已连接' : '未连接',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          // 停止生成按钮
          if (_isStreaming)
            IconButton(
              icon: const Icon(Icons.stop),
              tooltip: '停止生成',
              onPressed: () {
                _chatService.stopGeneration();
                setState(() => _isStreaming = false);
              },
            ),
        ],
      ),
      drawer: AppSidebar(
        selectedIndex: _selectedFeature,
        onItemSelected: (index) {
          setState(() => _selectedFeature = index);
          Navigator.pop(context); // 关闭抽屉
        },
      ),
      body: Column(
        children: [
          // 聊天消息列表
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppSidebar.items[_selectedFeature].enabled
                              ? '向 Jarvis 发送消息开始对话'
                              : '该功能尚未接入服务端',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return ChatBubble(message: _messages[index]);
                    },
                  ),
          ),

          // 底部输入区
          MessageInput(
            enabled: _isConnected && !_isStreaming,
            onSend: _sendMessage,
          ),
        ],
      ),
    );
  }
}
