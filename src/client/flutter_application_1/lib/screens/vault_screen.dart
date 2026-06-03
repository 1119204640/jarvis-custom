import 'package:flutter/material.dart';
import '../models/asset.dart';
import '../services/vault_api.dart';
import '../widgets/source_status_indicator.dart';
import 'vault_detail_screen.dart';

/// 文档库列表 — Apple Notes 风格（body-only，由 HomeScreen Scaffold 包裹）
///
/// 卡片式列表：每张卡片显示标题（粗体）、正文预览（灰色2行截断）、
/// 日期 + 彩色标签 chip + 子节点计数。顶部搜索框。
class VaultScreen extends StatefulWidget {
  final VoidCallback? onFabTap;

  const VaultScreen({super.key, this.onFabTap});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final VaultApi _api = VaultApi();
  List<VaultAsset> _assets = [];
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
    final assets = await _api.list(
      query: _searchQuery.isNotEmpty ? _searchQuery : null,
    );
    if (!mounted) return;
    setState(() {
      _assets = assets;
      _loading = false;
    });
  }

  void _openDetail([VaultAsset? asset]) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => VaultDetailScreen(asset: asset),
      ),
    );
    if (result == true) _load();
  }

  Future<void> _deleteAsset(VaultAsset asset) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除资产'),
        content: const Text('确定要删除这条资产吗？'),
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
      final ok = await _api.delete(asset.id);
      if (ok) _load();
    }
  }

  Future<void> _togglePin(VaultAsset asset) async {
    await _api.togglePin(asset.id, !asset.pinned);
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
              : _assets.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isNotEmpty ? '无匹配结果' : '暂无资产',
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
                        itemCount: _assets.length,
                        itemBuilder: (context, index) {
                          final asset = _assets[index];
                          return _AssetCard(
                            asset: asset,
                            onTap: () => _openDetail(asset),
                            onDelete: () => _deleteAsset(asset),
                            onTogglePin: () => _togglePin(asset),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}

/// 单张资产卡片
class _AssetCard extends StatelessWidget {
  final VaultAsset asset;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;

  const _AssetCard({
    required this.asset,
    required this.onTap,
    required this.onDelete,
    required this.onTogglePin,
  });

  String get _childrenLabel {
    if (!asset.hasChildren) return '';
    final parts = <String>[];
    final todos = asset.childrenCount?['todos'] ?? 0;
    final schedules = asset.childrenCount?['schedules'] ?? 0;
    if (todos > 0) parts.add('$todos 项待办');
    if (schedules > 0) parts.add('$schedules 项日程');
    return parts.join('、');
  }

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
                  if (asset.pinned)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.push_pin, size: 14,
                          color: theme.colorScheme.primary),
                    ),
                  Expanded(
                    child: Text(
                      asset.title.isEmpty ? '无标题' : asset.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (asset.preview.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  asset.preview,
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
                    asset.updatedAt.substring(0, 10),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                      fontSize: 12,
                    ),
                  ),
                  if (asset.tags.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: asset.tags
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
                  if (_childrenLabel.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _childrenLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.secondary,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  SourceStatusIndicator(
                    sourceStatus: asset.sourceStatus,
                    nodeId: asset.id,
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
                        child: Text(asset.pinned ? '取消置顶' : '置顶'),
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
