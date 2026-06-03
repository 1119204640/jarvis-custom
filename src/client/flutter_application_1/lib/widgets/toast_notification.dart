import 'dart:async';
import 'package:flutter/material.dart';

/// 服务端推送的日志飘窗数据
class ToastItem {
  final String id;
  final String level; // "warning" | "error"
  final String message;

  const ToastItem({
    required this.id,
    required this.level,
    required this.message,
  });
}

/// 全局飘窗通知组件
///
/// 放在 [Stack] 顶层，从服务端接收 warning / error 日志事件，
/// 以飘窗形式纵向堆叠显示。
/// - warning：黄色飘窗，3 秒后自动消失
/// - error：红色飘窗，需手动点击关闭按钮
class ToastNotification extends StatefulWidget {
  const ToastNotification({super.key});

  @override
  State<ToastNotification> createState() => ToastNotificationState();
}

class ToastNotificationState extends State<ToastNotification> {
  final List<ToastItem> _toasts = [];
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final Map<String, Timer> _autoDismissTimers = {};

  /// 添加一条飘窗
  void addToast(ToastItem toast) {
    if (!mounted) return;
    setState(() {
      _toasts.insert(0, toast);
    });
    _listKey.currentState?.insertItem(
      0,
      duration: const Duration(milliseconds: 300),
    );

    if (toast.level == 'warning') {
      _autoDismissTimers[toast.id] = Timer(const Duration(seconds: 3), () {
        _removeToast(toast.id);
      });
    }
  }

  void _removeToast(String id) {
    _autoDismissTimers.remove(id)?.cancel();
    if (!mounted) return;
    final index = _toasts.indexWhere((t) => t.id == id);
    if (index < 0) return;

    final removed = _toasts.removeAt(index);
    _listKey.currentState?.removeItem(
      index,
      (context, animation) => _buildToastItem(removed, animation),
      duration: const Duration(milliseconds: 250),
    );
    setState(() {});
  }

  @override
  void dispose() {
    for (final t in _autoDismissTimers.values) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: AnimatedList(
        key: _listKey,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        initialItemCount: _toasts.length,
        itemBuilder: (context, index, animation) {
          if (index >= _toasts.length) {
            return const SizedBox.shrink();
          }
          return _buildToastItem(_toasts[index], animation);
        },
      ),
    );
  }

  Widget _buildToastItem(ToastItem toast, Animation<double> animation) {
    final isWarning = toast.level == 'warning';
    final color = isWarning ? Colors.orange : Colors.red;
    final icon = isWarning ? Icons.warning_amber_rounded : Icons.error_outline;

    return SizeTransition(
      sizeFactor: animation,
      child: FadeTransition(
        opacity: animation,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border(
                  left: BorderSide(color: color, width: 4),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 10, top: 10),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        toast.message,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  if (!isWarning)
                    GestureDetector(
                      onTap: () => _removeToast(toast.id),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.close, size: 18, color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
