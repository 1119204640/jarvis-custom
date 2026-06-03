import 'package:flutter/material.dart';

/// 侧边栏菜单项数据
class SidebarItem {
  final String title;
  final IconData icon;
  final bool enabled; // false 表示功能暂未实现
  final String tooltip;

  const SidebarItem({
    required this.title,
    required this.icon,
    this.enabled = true,
    this.tooltip = '',
  });
}

/// 应用侧边栏 — 功能导航
///
/// 列出所有功能模块。
class AppSidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;

  const AppSidebar({
    super.key,
    required this.selectedIndex,
    required this.onItemSelected,
  });

  static const List<SidebarItem> items = [
    SidebarItem(title: '文档库', icon: Icons.archive_outlined, enabled: true, tooltip: '创建和管理文档资产'),
    SidebarItem(title: '待办事项', icon: Icons.check_circle_outline, enabled: true, tooltip: '创建和管理待办事项'),
    SidebarItem(title: '日程', icon: Icons.calendar_today, enabled: true, tooltip: '管理日程和日历视图'),
    SidebarItem(title: '邮件', icon: Icons.email_outlined, enabled: false, tooltip: '邮件功能尚未接入服务端'),
    SidebarItem(title: '设置', icon: Icons.settings, enabled: true, tooltip: '配置文件管理目录等'),
  ];

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.assistant, size: 36, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 8),
                  Text(
                    'Jarvis',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'AI 个人秘书',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // 菜单项
            ...List.generate(items.length, (index) {
              final item = items[index];
              return ListTile(
                leading: Icon(item.icon),
                title: Text(item.title),
                selected: selectedIndex == index,
                enabled: item.enabled,
                // 禁用项显示提示
                onTap: item.enabled
                    ? () => onItemSelected(index)
                    : () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(item.tooltip),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                // 禁用项视觉提示
                trailing: item.enabled
                    ? null
                    : const Icon(Icons.lock_outline, size: 16, color: Colors.grey),
              );
            }),
          ],
        ),
      ),
    );
  }
}
