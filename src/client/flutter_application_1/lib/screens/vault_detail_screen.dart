import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';

import '../models/asset.dart';
import '../models/todo.dart';
import '../services/app_config.dart';
import '../services/vault_api.dart';
import '../widgets/source_status_indicator.dart';

/// 文档库资产详情／编辑页 — 统一使用原始 Markdown 文本
///
/// asset == null → 新建，asset != null → 编辑已有。
/// LLM 生成的资产（isFromLLM）为只读，用户创建的可编辑。
/// 所有资产都支持"预览模式"切换，渲染 Markdown。
/// 底部显示关联的子待办和子日程。
///
/// 不再需要单独的标题输入框。标题从正文自动提取：
/// - 正文以 # 开头 → 取第一行 # 标题
/// - 否则 → 取正文前 50 个字符作为标题
class VaultDetailScreen extends StatefulWidget {
  final VaultAsset? asset;

  const VaultDetailScreen({super.key, this.asset});

  @override
  State<VaultDetailScreen> createState() => _VaultDetailScreenState();
}

class _VaultDetailScreenState extends State<VaultDetailScreen> {
  final VaultApi _api = VaultApi();
  final ImagePicker _picker = ImagePicker();

  late TextEditingController _tagCtrl;
  late TextEditingController _contentCtrl;
  final FocusNode _contentFocus = FocusNode();

  VaultAsset? _fullAsset;
  bool _saving = false;
  bool _modified = false;
  bool _deleted = false;
  bool _uploading = false;
  bool _isPreviewMode = true;

  List<TodoItem> _childTodos = [];
  List<Map<String, dynamic>> _childSchedules = [];
  bool _childrenLoaded = false;

  bool get _isNew => widget.asset == null;

  VaultAsset? get _asset => _fullAsset ?? widget.asset;
  bool get _isReadOnly => _asset?.isFromLLM ?? false;
  bool get _canEdit => !_isReadOnly && !_isPreviewMode;

  @override
  void initState() {
    super.initState();

    _tagCtrl = TextEditingController(
      text: widget.asset?.tags.join(', ') ?? '',
    );
    // 编辑已有资产时，用 rawContent（含 # 标题）作为初始值；
    // 新建时 content 为空
    _contentCtrl = TextEditingController(
      text: widget.asset?.rawContent ?? widget.asset?.content ?? '',
    );

    _tagCtrl.addListener(_markModified);
    _contentCtrl.addListener(_markModified);

    if (!_isNew) {
      _fetchFullAsset();
      _fetchChildren();
    }
  }

  Future<void> _fetchFullAsset() async {
    final full = await _api.get(widget.asset!.id);
    if (full != null && mounted) {
      setState(() {
        _fullAsset = full;
        _tagCtrl.text = full.tags.join(', ');
        _contentCtrl.text =
            full.rawContent?.isNotEmpty == true ? full.rawContent! : full.content;
        _modified = false;
      });
    }
  }

  Future<void> _fetchChildren() async {
    final children = await _api.getChildren(widget.asset!.id);
    if (!mounted) return;
    setState(() {
      _childTodos = (children['todos'] ?? [])
          .map((e) => TodoItem.fromJson(e as Map<String, dynamic>))
          .toList();
      _childSchedules = (children['schedules'] ?? [])
          .map((e) => e as Map<String, dynamic>)
          .toList();
      _childrenLoaded = true;
    });
  }

  Future<void> _reclassifyChild(String childId, String newCategory) async {
    final error = await VaultApi.reclassify(childId, newCategory);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重新分类失败: $error')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('重新分类成功')),
      );
      _fetchChildren();
    }
  }

  void _showChildItemDetail(String childId, String type) {
    // Find the child item in loaded data
    if (type == 'todo') {
      final todo = _childTodos.where((t) => t.id == childId).firstOrNull;
      if (todo != null && mounted) {
        _showChildDetailDialog(todo.title, todo.dueDate ?? '', '待办事项');
      }
    } else if (type == 'schedule') {
      final schedule = _childSchedules.where((s) => s['id'] == childId).firstOrNull;
      if (schedule != null && mounted) {
        _showChildDetailDialog(
          schedule['title']?.toString() ?? '',
          schedule['start_time']?.toString() ?? '',
          '日程',
        );
      }
    }
  }

  void _showChildDetailDialog(String title, String date, String typeLabel) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(typeLabel == '待办事项' ? Icons.check_circle_outline : Icons.event,
                size: 20),
            const SizedBox(width: 8),
            Text(typeLabel),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            if (date.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('时间: $date',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.outline)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _markModified() {
    if (mounted && !_modified) setState(() => _modified = true);
  }

  String _formatDueDate(String due) {
    final now = DateTime.now();
    final today = now.toIso8601String().substring(0, 10);
    final datePart = due.length >= 10 ? due.substring(0, 10) : due;
    final hasTime = due.length >= 16;
    final timeStr = hasTime ? due.substring(11, 16) : null;

    String dateLabel;
    if (datePart == today) {
      dateLabel = '今天';
    } else {
      final parts = datePart.split('-');
      dateLabel = parts.length >= 3 ? '${parts[1]}/${parts[2]}' : datePart;
    }

    if (timeStr != null) {
      return '$dateLabel $timeStr';
    }
    return dateLabel;
  }

  @override
  void dispose() {
    _tagCtrl.dispose();
    _contentCtrl.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 正文内容（用于预览渲染和保存）
  // ---------------------------------------------------------------------------

  String get _markdownForPreview {
    return _contentCtrl.text;
  }

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  List<String> _parseTags() {
    return _tagCtrl.text
        .split(RegExp(r'[,，\s]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
  }

  Future<void> _handleBack() async {
    if (_deleted) {
      if (mounted) Navigator.pop(context, true);
      return;
    }
    if (_modified && _canEdit && _contentCtrl.text.trim().isNotEmpty) {
      await _save();
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    if (_isReadOnly) return;

    final content = _contentCtrl.text;

    setState(() => _saving = true);

    try {
      if (_isNew) {
        await _api.create(
          content: content,
          tags: _parseTags(),
        );
      } else {
        await _api.update(
          id: widget.asset!.id,
          content: content,
          tags: _parseTags(),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _saveAndAnalyze() async {
    if (_isReadOnly) return;

    final content = _contentCtrl.text;

    setState(() => _saving = true);

    try {
      if (_isNew) {
        await _api.create(
          content: content,
          tags: _parseTags(),
          processAsync: true,
        );
      } else {
        await _api.update(
          id: widget.asset!.id,
          content: content,
          tags: _parseTags(),
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文档已保存，正在后台分析...')),
      );
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_isNew) {
      Navigator.pop(context);
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除资产'),
        content: const Text('确定要删除这条资产吗？此操作不可撤销。'),
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
      await _api.delete(widget.asset!.id);
      _deleted = true;
      if (mounted) Navigator.pop(context, true);
    }
  }

  // ---------------------------------------------------------------------------
  // 格式化工具栏 — 插入 Markdown 语法
  // ---------------------------------------------------------------------------

  void _wrapSelection(String open, String close) {
    final text = _contentCtrl.text;
    final sel = _contentCtrl.selection;
    final start = sel.start;
    final end = sel.end;

    setState(() {
      if (start < 0) return;
      if (start == end) {
        const placeholder = 'text';
        final newText = text.substring(0, start) +
            '$open$placeholder$close' +
            text.substring(end);
        _contentCtrl.text = newText;
        _contentCtrl.selection = TextSelection(
          baseOffset: start + open.length,
          extentOffset: start + open.length + placeholder.length,
        );
      } else {
        final selected = text.substring(start, end);
        final newText = text.substring(0, start) +
            '$open$selected$close' +
            text.substring(end);
        _contentCtrl.text = newText;
        _contentCtrl.selection = TextSelection(
          baseOffset: start,
          extentOffset: start + open.length + selected.length + close.length,
        );
      }
      _modified = true;
    });
    _contentFocus.requestFocus();
  }

  void _insertLinePrefix(String prefix) {
    final text = _contentCtrl.text;
    final sel = _contentCtrl.selection;
    var lineStart = sel.start;
    while (lineStart > 0 && text[lineStart - 1] != '\n') {
      lineStart--;
    }
    setState(() {
      final newText =
          text.substring(0, lineStart) + prefix + text.substring(lineStart);
      _contentCtrl.text = newText;
      _contentCtrl.selection = TextSelection.collapsed(
        offset: sel.start + prefix.length,
      );
      _modified = true;
    });
    _contentFocus.requestFocus();
  }

  void _insertBlock(String syntax) {
    final text = _contentCtrl.text;
    final sel = _contentCtrl.selection;
    final start = sel.isValid ? sel.start : text.length;
    final prefix = text.isEmpty || text.endsWith('\n') ? '' : '\n';
    setState(() {
      final newText = text.substring(0, start) +
          '$prefix$syntax' +
          text.substring(sel.isValid ? sel.end : text.length);
      _contentCtrl.text = newText;
      final pos = start + prefix.length + syntax.length;
      _contentCtrl.selection = TextSelection.collapsed(offset: pos);
      _modified = true;
    });
    _contentFocus.requestFocus();
  }

  void _insertTable() {
    const table = '\n| 列1 | 列2 |\n| --- | --- |\n| | |\n';
    _insertBlock(table);
  }

  // ---------------------------------------------------------------------------
  // 图片上传
  // ---------------------------------------------------------------------------

  Future<void> _pickAndInsertImage() async {
    final xfile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (xfile == null) return;
    final bytes = await xfile.readAsBytes();
    await _uploadAndInsertImage(bytes, xfile.name);
  }

  Future<void> _uploadAndInsertImage(List<int> bytes, String fileName) async {
    if (!mounted) return;
    setState(() => _uploading = true);

    String? url;
    try {
      url = await VaultApi.uploadImage(
        'pasted',
        bytes: bytes,
        fileName: fileName,
      );
    } catch (_) {
      url = null;
    }

    if (!mounted) return;
    setState(() => _uploading = false);

    if (url != null) {
      final fullUrl = '${AppConfig.serverBaseUrl}$url';
      final md = '![$fileName]($fullUrl)';
      final text = _contentCtrl.text;
      final sel = _contentCtrl.selection;
      final pos = sel.isValid ? sel.start : text.length;
      setState(() {
        _contentCtrl.text =
            text.substring(0, pos) + md + text.substring(sel.isValid ? sel.end : text.length);
        _contentCtrl.selection = TextSelection.collapsed(offset: pos + md.length);
        _modified = true;
      });
      _contentFocus.requestFocus();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图片上传失败')),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 格式化菜单（overlay）
  // ---------------------------------------------------------------------------

  void _showFormatMenu() {
    if (!_canEdit) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            GestureDetector(
              onTap: () => entry.remove(),
              behavior: HitTestBehavior.translucent,
              child: Container(color: Colors.transparent),
            ),
            Positioned(
              top: kToolbarHeight + MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 280,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _FmtBtn(
                            label: 'B',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            tooltip: '加粗',
                            onTap: () { _wrapSelection('**', '**'); entry.remove(); },
                          ),
                          _FmtBtn(
                            label: 'I',
                            style: const TextStyle(fontStyle: FontStyle.italic),
                            tooltip: '斜体',
                            onTap: () { _wrapSelection('*', '*'); entry.remove(); },
                          ),
                          _FmtBtn(
                            label: 'S',
                            style: const TextStyle(decoration: TextDecoration.lineThrough),
                            tooltip: '删除线',
                            onTap: () { _wrapSelection('~~', '~~'); entry.remove(); },
                          ),
                          _FmtBtn(
                            label: '`',
                            style: const TextStyle(fontFamily: 'monospace'),
                            tooltip: '行内代码',
                            onTap: () { _wrapSelection('`', '`'); entry.remove(); },
                          ),
                        ],
                      ),
                      const Divider(),
                      _FmtMenuItem(label: '标题', onTap: () {
                        _insertLinePrefix('# ');
                        entry.remove();
                      }),
                      _FmtMenuItem(label: '小标题', onTap: () {
                        _insertLinePrefix('## ');
                        entry.remove();
                      }),
                      _FmtMenuItem(label: '副标题', onTap: () {
                        _insertLinePrefix('### ');
                        entry.remove();
                      }),
                      const Divider(height: 8),
                      _FmtMenuItem(label: '项目符号列表', icon: Icons.format_list_bulleted, onTap: () {
                        _insertLinePrefix('- ');
                        entry.remove();
                      }),
                      _FmtMenuItem(label: '编号列表', icon: Icons.format_list_numbered, onTap: () {
                        _insertLinePrefix('1. ');
                        entry.remove();
                      }),
                      _FmtMenuItem(label: '块引用', icon: Icons.format_quote, onTap: () {
                        _insertLinePrefix('> ');
                        entry.remove();
                      }),
                      _FmtMenuItem(label: '核对清单', icon: Icons.checklist, onTap: () {
                        _insertLinePrefix('- [ ] ');
                        entry.remove();
                      }),
                      _FmtMenuItem(label: '表格', icon: Icons.table_chart, onTap: () {
                        _insertTable();
                        entry.remove();
                      }),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(entry);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          backgroundColor: theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _handleBack,
          ),
          actions: [
            if (_asset != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: SourceStatusIndicator(
                  sourceStatus: _asset!.sourceStatus,
                  nodeId: _asset!.id,
                ),
              ),
            IconButton(
              icon: Icon(_isPreviewMode ? Icons.edit : Icons.visibility),
              tooltip: _isPreviewMode ? '编辑' : '预览',
              onPressed: () => setState(() => _isPreviewMode = !_isPreviewMode),
            ),
            if (_canEdit) ...[
              IconButton(
                icon: const Icon(Icons.format_size),
                tooltip: '格式',
                onPressed: _isPreviewMode ? null : _showFormatMenu,
              ),
              IconButton(
                icon: _uploading
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_outlined),
                tooltip: '插入图片',
                onPressed: (_uploading || _isPreviewMode) ? null : _pickAndInsertImage,
              ),
            ],
            if (!_isNew)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete,
              ),
          ],
        ),
        body: _isPreviewMode ? _buildPreview(theme) : _buildEditor(theme),
        persistentFooterButtons: (_isNew && _canEdit)
            ? [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: Text(_saving ? '保存中...' : '保存'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: _saving ? null : _saveAndAnalyze,
                        child: Text(_saving ? '保存中...' : '保存并分析'),
                      ),
                    ),
                  ],
                ),
              ]
            : null,
      ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标签
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _tagCtrl,
                readOnly: _isReadOnly,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                decoration: InputDecoration(
                  hintText: '标签（用逗号分隔）',
                  border: InputBorder.none,
                  hintStyle: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        // Markdown 正文
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _contentCtrl,
              focusNode: _contentFocus,
              readOnly: _isReadOnly || _isPreviewMode,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 15,
                height: 1.6,
                color: theme.colorScheme.onSurface,
              ),
              decoration: const InputDecoration(
                hintText: 'Markdown 正文...',
                border: InputBorder.none,
              ),
            ),
          ),
        ),
        // 子节点区域
        if (_childrenLoaded && (_childTodos.isNotEmpty || _childSchedules.isNotEmpty))
          _buildChildrenSection(theme),
      ],
    );
  }

  Widget _buildChildrenSection(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '关联内容',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          if (_childTodos.isNotEmpty) ...[
            ..._childTodos.map((todo) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    todo.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 16,
                    color: todo.isCompleted
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      todo.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        decoration: todo.isCompleted ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                  if (todo.dueDate != null)
                    Text(
                      _formatDueDate(todo.dueDate!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.calendar_today, size: 16),
                    tooltip: '转换为日程',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                    onPressed: () => _reclassifyChild(todo.id, 'schedule (plan)'),
                  ),
                ],
              ),
            )),
          ],
          if (_childSchedules.isNotEmpty) ...[
            if (_childTodos.isNotEmpty) const SizedBox(height: 8),
            ..._childSchedules.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.event, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s['title'] as String? ?? '',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    s['target_date'] as String? ?? '',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    tooltip: '转换为待办',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                    onPressed: () => _reclassifyChild(s['id'] as String, 'todo'),
                  ),
                ],
              ),
            )),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              if (_tagCtrl.text.isNotEmpty)
                Text(
                  _tagCtrl.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              if (_tagCtrl.text.isNotEmpty) const SizedBox(height: 12),
              if (_tagCtrl.text.isNotEmpty)
                Divider(color: theme.colorScheme.outlineVariant),
            ],
          ),
        ),
        Expanded(
          child: Markdown(
            data: _markdownForPreview,
            selectable: true,
            paddingBuilders: const {},
            onTapLink: (text, href, title) {
              if (href == null) return;
              if (href.startsWith('jarvis://todo/')) {
                final todoId = href.substring('jarvis://todo/'.length);
                // Navigate to todo detail — push to TodoScreen's detail or scroll to item
                _showChildItemDetail(todoId, 'todo');
              } else if (href.startsWith('jarvis://schedule/')) {
                final scheduleId = href.substring('jarvis://schedule/'.length);
                _showChildItemDetail(scheduleId, 'schedule');
              }
            },
            styleSheet: MarkdownStyleSheet(
              p: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              h1: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              h2: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              h3: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              code: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
              codeblockDecoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.4),
                    width: 3,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 格式菜单小组件
// ---------------------------------------------------------------------------

class _FmtBtn extends StatelessWidget {
  const _FmtBtn({
    required this.label,
    required this.style,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final TextStyle style;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 40,
        height: 36,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: Text(label, style: style.copyWith(fontSize: 14)),
        ),
      ),
    );
  }
}

class _FmtMenuItem extends StatelessWidget {
  const _FmtMenuItem({
    required this.label,
    this.icon,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurface),
              const SizedBox(width: 8),
            ],
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
