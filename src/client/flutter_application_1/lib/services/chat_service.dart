import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';

/// 与 Chainlit 服务端通信的聊天服务
///
/// 通过 Socket.IO 实时收发消息，支持流式响应。
/// 服务端地址 http://localhost:8000，Socket.IO 路径 /ws/socket.io。
class ChatService {
  final String serverUrl;
  final String sessionId;
  io.Socket? _socket;
  String? _threadId;

  /// 收到完整消息时的回调
  void Function(ChatMessage message)? onMessage;

  /// 流式内容更新时的回调（同一消息 ID 会多次触发）
  void Function(String messageId, String fullContent)? onStreamUpdate;

  /// 连接状态变化回调
  void Function(bool connected)? onConnectionChange;

  ChatService({
    this.serverUrl = 'http://localhost:8000',
    String? sessionId,
  }) : sessionId = sessionId ?? const Uuid().v4();

  bool get isConnected => _socket?.connected ?? false;
  String? get threadId => _threadId;

  /// 连接到服务端并创建新会话线程
  Future<void> connect() async {
    // 先通过 REST API 创建线程
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/project/threads'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'pagination': {'first': 1},
          'filter': {},
        }),
      );
      // 获取已有线程或准备创建新的
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final threads = data['data'] as List? ?? [];
        if (threads.isNotEmpty) {
          _threadId = threads.first['id'];
        }
      }
    } catch (_) {
      // REST 获取线程失败不影响后续，Socket.IO 会自动创建
    }

    // 连接 Socket.IO
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setPath('/ws/socket.io')
          .setTransports(['websocket'])
          .setQuery({
            'sessionId': sessionId,
            'clientType': 'flutter',
          })
          .enableForceNew()
          .build(),
    );

    _socket!.onConnect((_) {
      onConnectionChange?.call(true);
    });

    _socket!.onDisconnect((_) {
      onConnectionChange?.call(false);
    });

    _socket!.onConnectError((error) {
      onConnectionChange?.call(false);
    });

    // 服务端发来的各种消息事件
    _socket!.on('new_message', (data) {
      _handleNewMessage(data);
    });

    _socket!.on('stream_start', (data) {
      // 标记开始流式传输，预留处理逻辑
    });

    _socket!.on('stream_token', (data) {
      _handleStreamToken(data);
    });

    _socket!.on('stream_end', (data) {
      final msgId = data is Map ? data['messageId']?.toString() ?? '' : '';
      // 流式结束，将 isStreaming 置为 false
      if (msgId.isNotEmpty) {
        onStreamUpdate?.call('${msgId}_done', '');
      }
    });

    _socket!.connect();
  }

  /// 发送消息到服务端
  void sendMessage(String text) {
    if (_socket == null || !_socket!.connected) return;

    final messageId = const Uuid().v4();
    final payload = {
      'message': {
        'id': messageId,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'name': 'user',
        'type': 'user_message',
        'output': text,
        'threadId': _threadId,
      },
      'fileReferences': [],
    };

    _socket!.emit('client_message', payload);
  }

  /// 停止当前正在生成的消息
  void stopGeneration() {
    _socket?.emit('stop');
  }

  /// 断开连接
  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }

  /// 处理服务端发来的完整消息
  void _handleNewMessage(dynamic data) {
    if (data is! Map) return;

    final message = data['message'] ?? data;
    if (message is! Map) return;

    final role = message['name'] == 'user' ? 'user' : 'assistant';
    final content = message['output']?.toString() ?? '';
    final msgId = message['id']?.toString() ?? const Uuid().v4();

    if (content.isEmpty) return;

    onMessage?.call(ChatMessage(
      id: msgId,
      role: role,
      content: content,
      createdAt: DateTime.now(),
    ));
  }

  /// 处理流式传输中的增量内容
  void _handleStreamToken(dynamic data) {
    if (data is! Map) return;

    final msgId = data['messageId']?.toString() ?? '';
    final token = data['token']?.toString() ?? '';

    if (msgId.isEmpty || token.isEmpty) return;

    onStreamUpdate?.call(msgId, token);
  }
}
