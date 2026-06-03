import 'package:flutter/material.dart';
import '../services/memo_api.dart';

/// 源文件状态指示器，内联在卡片／行中使用
///
/// - native: 不显示
/// - linked: 绿色链接图标，点击在文件管理器中打开源文件
/// - source_deleted: 黄色警告图标（源文件已删除）
/// - association_lost: 红色断开图标（监控目录不存在）
class SourceStatusIndicator extends StatelessWidget {
  final String? sourceStatus;
  final String nodeId;

  const SourceStatusIndicator({
    super.key,
    required this.sourceStatus,
    required this.nodeId,
  });

  @override
  Widget build(BuildContext context) {
    final status = sourceStatus;
    if (status == null || status == 'native') return const SizedBox.shrink();

    if (status == 'linked') {
      return Tooltip(
        message: '在文件管理器中查看源文件',
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final error = await MemoApi.openSourceFile(nodeId);
            if (error != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(error)),
              );
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.open_in_new, size: 16, color: Colors.green.shade600),
          ),
        ),
      );
    }

    if (status == 'source_deleted') {
      return Tooltip(
        message: '源文件已删除，但 LLM 生成内容仍可用',
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade600),
        ),
      );
    }

    if (status == 'association_lost') {
      return Tooltip(
        message: '监控目录已断开，无法定位源文件',
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.link_off, size: 16, color: Colors.red.shade400),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
