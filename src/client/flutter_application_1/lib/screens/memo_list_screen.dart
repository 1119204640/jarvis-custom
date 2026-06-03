import 'package:flutter/material.dart';
import '../models/memo.dart';
import '../services/memo_api.dart';
import '../widgets/source_status_indicator.dart';
import 'memo_detail_screen.dart';

/// 备忘录列表 — Apple Notes 风格（body-only，由 HomeScreen Scaffold 包裹）
///
/// 卡片式列表：每张卡片显示标题（粗体）、正文预览（灰色2行截断）、
/// 日期 + 彩色标签 chip。顶部搜索框。
class MemoListScreen extends StatefulWidget {
  final VoidCallback? onFabTap;

  const MemoListScreen({super.key, this.onFabTap});

  @override
  State<MemoListScreen> createState() => _MemoListScreenState();
}

class _MemoListScreenState extends State<MemoListScreen> {
  final MemoApi _api = MemoApi();
  List<Memo> _memos = [];
  bool _loading = true;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final memos = await _api.list(
      query: _searchQuery.isNotEmpty ? _searchQuery : null,
    );
    if (!mounted) return;
    setState(() {
      _memos = memos;
      _loading = false;
    });
  }

  void _openDetail([Memo? memo]) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MemoDetailScreen(memo: memo),
      ),
    );
    if (result == true) _load();
  }

  Future<void> _deleteMemo(Memo memo) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除备忘录'),
        content: const Text('确定要删除这条备忘录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      final ok = await _api.delete(memo.id);
      if (ok) _load();
    }
  }

  Future<void> _togglePin(Memo memo) async {
    await _api.togglePin(memo.id, !memo.pinned);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // 搜索栏 — iOS 风格
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: '搜索',
              prefixIcon: const Icon(Icons.search, size: 20),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        _searchQuery = '';
                        _load();
                      },
                    )
                  : null,
            ),
            onChanged: (v) {
              _searchQuery = v;
              _load();
            },
          ),
        ),

        // 列表
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _memos.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isNotEmpty ? '无匹配结果' : '暂无备忘录',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.4),
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        itemCount: _memos.length,
                        itemBuilder: (context, index) {
                          final memo = _memos[index];
                          return _MemoCard(
                            memo: memo,
                            onTap: () => _openDetail(memo),
                            onDelete: () => _deleteMemo(memo),
                            onTogglePin: () => _togglePin(memo),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}

/// 单张备忘录卡片
class _MemoCard extends StatelessWidget {
  final Memo memo;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;

  const _MemoCard({
    required this.memo,
    required this.onTap,
    required this.onDelete,
    required this.onTogglePin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0.5,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: theme.colorScheme.surface,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (memo.pinned)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.push_pin, size: 14,
                          color: theme.colorScheme.primary),
                    ),
                  Expanded(
                    child: Text(
                      memo.title.isEmpty ? '无标题' : memo.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (memo.preview.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  memo.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    height: 1.3,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    memo.updatedAt.substring(0, 10),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                      fontSize: 12,
                    ),
                  ),
                  if (memo.tags.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: memo.tags
                              .map((tag) => Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primaryContainer
                                            .withValues(alpha: 0.65),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        tag,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: theme.colorScheme.primary,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  SourceStatusIndicator(
                    sourceStatus: memo.sourceStatus,
                    nodeId: memo.id,
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_horiz,
                      size: 17,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.35),
                    ),
                    padding: EdgeInsets.zero,
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(memo.pinned ? '取消置顶' : '置顶'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'pin') {
                        onTogglePin();
                      } else if (value == 'delete') {
                        onDelete();
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
