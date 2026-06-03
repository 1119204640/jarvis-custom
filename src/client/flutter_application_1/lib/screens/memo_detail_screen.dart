import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';

import '../models/memo.dart';
import '../services/app_config.dart';
import '../services/memo_api.dart';
import '../widgets/source_status_indicator.dart';

/// 备忘录详情／编辑页 — 统一使用原始 Markdown 文本
///
/// memo == null → 新建，memo != null → 编辑已有。
/// LLM 生成的备忘录（isFromLLM）为只读，用户创建的可编辑。
/// 所有备忘录都支持"预览模式"切换，渲染 Markdown。
class MemoDetailScreen extends StatefulWidget {
  final Memo? memo;

  const MemoDetailScreen({super.key, this.memo});

  @override
  State<MemoDetailScreen> createState() => _MemoDetailScreenState();
}

class _MemoDetailScreenState extends State<MemoDetailScreen> {
  final MemoApi _api = MemoApi();
  final ImagePicker _picker = ImagePicker();

  late TextEditingController _titleCtrl;
  late TextEditingController _tagCtrl;
  late TextEditingController _contentCtrl;
  final FocusNode _contentFocus = FocusNode();

  Memo? _fullMemo; // 从 API 拉取的完整数据（含 raw_content）
  bool _saving = false;
  bool _modified = false;
  bool _deleted = false;
  bool _uploading = false;
  bool _isPreviewMode = false;

  bool get _isNew => widget.memo == null;

  Memo? get _memo => _fullMemo ?? widget.memo;
  bool get _isReadOnly => _memo?.isFromLLM ?? false;
  bool get _canEdit => !_isReadOnly && !_isPreviewMode;

  @override
  void initState() {
    super.initState();

    _titleCtrl = TextEditingController(text: widget.memo?.title ?? '');
    _tagCtrl = TextEditingController(
      text: widget.memo?.tags.join(', ') ?? '',
    );
    _contentCtrl = TextEditingController(text: widget.memo?.content ?? '');

    _titleCtrl.addListener(_markModified);
    _tagCtrl.addListener(_markModified);
    _contentCtrl.addListener(_markModified);

    if (!_isNew) {
      _fetchFullMemo();
    }
  }

  Future<void> _fetchFullMemo() async {
    final full = await _api.get(widget.memo!.id);
    if (full != null && mounted) {
      setState(() {
        _fullMemo = full;
        _titleCtrl.text = full.title;
        _tagCtrl.text = full.tags.join(', ');
        // LLM 备忘录用 raw_content（完整 .md），用户创建的用 content 正文
        _contentCtrl.text =
            full.rawContent?.isNotEmpty == true ? full.rawContent! : full.content;
        _modified = false;
      });
    }
  }

  void _markModified() {
    if (mounted && !_modified) setState(() => _modified = true);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _tagCtrl.dispose();
    _contentCtrl.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 正文内容（用于预览渲染和保存）
  // ---------------------------------------------------------------------------

  /// LLM 备忘录预览用 raw_content，用户创建的拼上标题
  String get _markdownForPreview {
    if (_isReadOnly) return _contentCtrl.text;
    return '# ${_titleCtrl.text.trim()}\n\n${_contentCtrl.text}';
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
    if (_modified && _canEdit) {
      if (_titleCtrl.text.trim().isEmpty) {
        final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('放弃更改'),
            content: const Text('标题为空，确定要放弃未保存的内容吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('继续编辑'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('放弃', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
        if (discard == true && mounted) {
          Navigator.pop(context);
        }
        return;
      }
      await _save(); // _save() already calls Navigator.pop
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入标题')),
        );
      }
      return;
    }
    if (_isReadOnly) return;

    setState(() => _saving = true);

    try {
      if (_isNew) {
        await _api.create(
          title: _titleCtrl.text.trim(),
          content: _contentCtrl.text,
          tags: _parseTags(),
        );
      } else {
        await _api.update(
          id: widget.memo!.id,
          title: _titleCtrl.text.trim(),
          content: _contentCtrl.text,
          tags: _parseTags(),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    if (_isNew) {
      Navigator.pop(context);
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除备忘录'),
        content: const Text('确定要删除这条备忘录吗？此操作不可撤销。'),
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
      await _api.delete(widget.memo!.id);
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
        // 无选中 → 插入占位文本并选中
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
        // 有选中 → 包裹
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
    // 查找光标所在行的行首
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
      url = await MemoApi.uploadImage(
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
            if (_memo != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: SourceStatusIndicator(
                  sourceStatus: _memo!.sourceStatus,
                  nodeId: _memo!.id,
                ),
              ),
            // 预览模式切换
            IconButton(
              icon: Icon(_isPreviewMode ? Icons.edit : Icons.visibility),
              tooltip: _isPreviewMode ? '编辑' : '预览',
              onPressed: () => setState(() => _isPreviewMode = !_isPreviewMode),
            ),
            if (_canEdit) ...[
              // 格式化菜单（仅编辑模式）
              IconButton(
                icon: const Icon(Icons.format_size),
                tooltip: '格式',
                onPressed: _isPreviewMode ? null : _showFormatMenu,
              ),
              // 插入图片
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
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '保存中...' : '保存'),
                  ),
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
        // 标题 + 标签
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _titleCtrl,
                readOnly: _isReadOnly,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                decoration: const InputDecoration(
                  hintText: '标题',
                  border: InputBorder.none,
                ),
                maxLines: null,
              ),
              const SizedBox(height: 4),
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
        // Markdown 正文 — 占满剩余空间，可滚动
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
      ],
    );
  }

  Widget _buildPreview(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题 + 标签（只读显示）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Text(
                _titleCtrl.text.isEmpty ? '无标题' : _titleCtrl.text,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              if (_tagCtrl.text.isNotEmpty)
                Text(
                  _tagCtrl.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              const SizedBox(height: 12),
              Divider(color: theme.colorScheme.outlineVariant),
            ],
          ),
        ),
        // 渲染后的 Markdown
        Expanded(
          child: Markdown(
            data: _markdownForPreview,
            selectable: true,
            paddingBuilders: const {},
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
