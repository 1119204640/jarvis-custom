import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/chat_service.dart';
import '../widgets/sidebar.dart';
import '../widgets/toast_notification.dart';
import 'calendar/calendar_screen.dart';
import 'vault_detail_screen.dart';
import 'vault_screen.dart';
import 'todo_screen.dart';
import 'settings_screen.dart';

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
  int _vaultRefreshKey = 0;
  int _todoRefreshKey = 0;
  int _calendarRefreshKey = 0;
  bool _todoShowAddForm = false;

  final ScrollController _scrollController = ScrollController();

  final GlobalKey<ToastNotificationState> _toastKey =
      GlobalKey<ToastNotificationState>();

  @override
  void initState() {
    super.initState();
    _chatService = ChatService();

    _chatService.onConnectionChange = (connected) {};

    _chatService.onDataChanged = (action, data) {
      if (!mounted) return;
      setState(() {
        switch (action) {
          case 'file_processed':
          case 'document_processed':
            _vaultRefreshKey++;
            break;
          case 'todo_updated':
          case 'todo_created':
            _todoRefreshKey++;
            break;
          case 'calendar_updated':
            _calendarRefreshKey++;
            break;
        }
      });
    };

    _chatService.onMessage = (message) {
      if (mounted) {
        setState(() {
          if (!_messages.any((m) => m.id == message.id)) {
            _messages.add(message);
          }
        });
        _scrollToBottom();
      }
    };

    _chatService.onStreamUpdate = (messageId, token) {
      if (!mounted) return;
      setState(() {
        if (messageId.endsWith('_done')) {
          final realId = messageId.replaceAll('_done', '');
          final idx = _messages.indexWhere((m) => m.id == realId);
          if (idx >= 0) {
            _messages[idx] = _messages[idx].copyWith(isStreaming: false);
          }
          return;
        }

        final idx = _messages.indexWhere((m) => m.id == messageId);
        if (idx >= 0) {
          _messages[idx] = _messages[idx].copyWith(
            content: _messages[idx].content + token,
          );
        } else {
          _messages.add(ChatMessage(
            id: messageId,
            role: 'assistant',
            content: token,
            createdAt: DateTime.now(),
            isStreaming: true,
          ));
        }
      });
      _scrollToBottom();
    };

    _chatService.onProgress = (stage, message) {
      if (!mounted) return;
      // doc_done 时刷新文档库
      if (stage == 'doc_done') {
        setState(() => _vaultRefreshKey++);
      }
    };

    _chatService.onLog = (level, message) {
      if (!mounted) return;
      _toastKey.currentState?.addToast(ToastItem(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        level: level,
        message: message,
      ));
    };

    _connect();
  }

  Future<void> _connect() async {
    await _chatService.connect();
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

  void _onFeatureSelected(int index) {
    setState(() => _selectedFeature = index);
    Navigator.pop(context); // 关闭抽屉
  }

  @override
  Widget build(BuildContext context) {
    final sidebar = AppSidebar(
      selectedIndex: _selectedFeature,
      onItemSelected: _onFeatureSelected,
    );

    Widget content;

    // 文档库
    if (_selectedFeature == 0) {
      content = Scaffold(
        appBar: AppBar(
          title: const Text('文档库'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        drawer: sidebar,
        body: VaultScreen(key: ValueKey('vault_$_vaultRefreshKey')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final result = await Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => const VaultDetailScreen()),
            );
            if (result == true && mounted) {
              setState(() => _vaultRefreshKey++);
            }
          },
          icon: const Icon(Icons.edit),
          label: const Text('新建文档'),
        ),
      );
    } else if (_selectedFeature == 2) {
      // 日程
      content = CalendarScreen(
        key: ValueKey('calendar_$_calendarRefreshKey'),
        drawer: sidebar,
      );
    } else if (_selectedFeature == 1) {
      // 待办事项
      content = Scaffold(
        appBar: AppBar(
          title: const Text('待办事项'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        drawer: sidebar,
        body: TodoScreen(
          key: ValueKey('todo_$_todoRefreshKey'),
          showAddForm: _todoShowAddForm,
          onToggleAddForm: () {
            setState(() => _todoShowAddForm = !_todoShowAddForm);
          },
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            setState(() => _todoShowAddForm = !_todoShowAddForm);
          },
          child: Icon(_todoShowAddForm ? Icons.close : Icons.add),
        ),
      );
    } else if (_selectedFeature == 4) {
      // 设置
      content = Scaffold(
        drawer: sidebar,
        body: SettingsScreen(
          onBack: () => setState(() => _selectedFeature = 0),
        ),
      );
    } else {
      // 默认：文档库
      content = Scaffold(
        appBar: AppBar(
          title: const Text('文档库'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        drawer: sidebar,
        body: VaultScreen(key: ValueKey('vault_$_vaultRefreshKey')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final result = await Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => const VaultDetailScreen()),
            );
            if (result == true && mounted) {
              setState(() => _vaultRefreshKey++);
            }
          },
          icon: const Icon(Icons.edit),
          label: const Text('新建文档'),
        ),
      );
    }

    return Stack(
      children: [
        content,
        ToastNotification(key: _toastKey),
      ],
    );
  }
}
