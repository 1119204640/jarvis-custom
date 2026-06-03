import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';
import '../models/attached_file.dart';
import '../models/chat_message.dart';
import '../models/queue_job.dart';
import 'app_config.dart';

/// 与 Chainlit 服务端通信的聊天服务
///
/// 通过 Socket.IO 实时收发消息，支持流式响应和文件上传。
/// 服务端地址来自 AppConfig.serverBaseUrl，Socket.IO 路径 /ws/socket.io。
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

  /// 服务端错误回调（如 LLM API key 未配置）
  void Function(String message)? onError;

  /// 进度更新回调（文件处理、工具调用等阶段）
  void Function(String stage, String message)? onProgress;

  /// 服务端日志回调（warning / error 级别）
  void Function(String level, String message)? onLog;

  /// 数据变更回调（文件处理完成、文档分析完成等）
  void Function(String action, Map<String, dynamic> data)? onDataChanged;

  /// 队列状态回调（文件处理队列的快照更新）
  void Function(List<QueueJob> jobs)? onQueueStatus;

  ChatService({
    String? serverUrl,
    String? sessionId,
  })  : serverUrl = serverUrl ?? AppConfig.serverBaseUrl,
        sessionId = sessionId ?? const Uuid().v4();

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
      _syncLlmConfig();
    });

    _socket!.onDisconnect((_) {
      onConnectionChange?.call(false);
    });

    _socket!.onConnectError((error) {
      onConnectionChange?.call(false);
    });

    // 服务端发送的通用错误事件（如 LLM API key 未配置）
    _socket!.on('error', (data) {
      final msg = data is Map ? data['message']?.toString() ?? '' : '';
      onError?.call(msg);
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
      if (msgId.isNotEmpty) {
        onStreamUpdate?.call('${msgId}_done', '');
      }
    });

    // 服务端进度事件
    _socket!.on('progress', (data) {
      if (data is Map) {
        final stage = data['stage']?.toString() ?? '';
        final message = data['message']?.toString() ?? '';
        onProgress?.call(stage, message);
      }
    });

    // 服务端日志事件（warning / error 飘窗）
    _socket!.on('log', (data) {
      if (data is Map) {
        final level = data['level']?.toString() ?? '';
        final message = data['message']?.toString() ?? '';
        if (level.isNotEmpty && message.isNotEmpty) {
          onLog?.call(level, message);
        }
      }
    });

    // 服务端数据变更事件（驱动 UI 刷新）
    _socket!.on('data_changed', (data) {
      if (data is Map) {
        final action = data['action']?.toString() ?? '';
        final payload = data['data'] is Map<String, dynamic>
            ? data['data'] as Map<String, dynamic>
            : <String, dynamic>{};
        onDataChanged?.call(action, payload);
      }
    });

    // 服务端队列状态推送
    _socket!.on('queue_status', (data) {
      if (data is Map) {
        final rawJobs = data['jobs'] as List<dynamic>? ?? [];
        final jobs = rawJobs
            .whereType<Map<String, dynamic>>()
            .map((j) => QueueJob.fromJson(j))
            .toList();
        GlobalQueueState.notifier.value = jobs;
        onQueueStatus?.call(jobs);
      }
    });

    _socket!.connect();
  }

  /// 上传文件到服务端 /api/upload，返回 AttachedFile
  Future<AttachedFile?> uploadFile(File file) async {
    try {
      final uri = Uri.parse('$serverUrl/api/upload');
      final request = http.MultipartRequest('POST', uri);
      request.files.add(await http.MultipartFile.fromPath('file', file.path));
      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 200) {
        final body = json.decode(response.body) as Map<String, dynamic>;
        final data = body['data'] as Map<String, dynamic>?;
        if (data != null) {
          return AttachedFile(
            fileName: data['filename'] as String? ?? file.path.split('/').last,
            fileUrl: data['url'] as String? ?? '',
          );
        }
      }
    } catch (_) {
      // 上传失败静默处理，不影响消息发送
    }
    return null;
  }

  /// 发送消息到服务端，可附带文件引用
  void sendMessage(String text, {List<AttachedFile> files = const []}) {
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
      'fileReferences': files.map((f) => f.toJson()).toList(),
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

  /// 连接后同步所有本地保存的 LLM 提供商凭据到服务器
  Future<void> _syncLlmConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = prefs.getString('llm_providers');
      if (savedJson == null || savedJson.isEmpty) return;
      final providers = json.decode(savedJson) as List<dynamic>;
      for (final p in providers) {
        if (p is Map) {
          final key = p['api_key'] as String? ?? '';
          final url = p['base_url'] as String? ?? '';
          if (key.isNotEmpty && url.isNotEmpty) {
            await http.put(
              Uri.parse('$serverUrl/api/settings/llm'),
              headers: {'Content-Type': 'application/json'},
              body: json.encode({'api_key': key, 'base_url': url}),
            );
          }
        }
      }
    } catch (_) {
      // 非关键操作，静默失败
    }
  }
}
