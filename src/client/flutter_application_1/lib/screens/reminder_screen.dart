import 'package:flutter/material.dart';
import '../models/reminder.dart';
import '../services/reminder_api.dart';
import '../widgets/source_status_indicator.dart';

/// 提醒事项 — Apple Reminders 风格（body-only，由 HomeScreen Scaffold 包裹）
///
/// 分组列表：今天 / 计划中 / 无日期 / 已完成
/// 圆形复选框 + 标题 + 日期标签 + 优先级标识
class ReminderScreen extends StatefulWidget {
  final bool showAddForm;
  final VoidCallback? onToggleAddForm;

  const ReminderScreen({super.key, this.showAddForm = false, this.onToggleAddForm});

  @override
  State<ReminderScreen> createState() => _ReminderScreenState();
}

class _ReminderScreenState extends State<ReminderScreen> {
  final ReminderApi _api = ReminderApi();
  List<Reminder> _allReminders = [];
  bool _loading = true;
  final _newTitleCtrl = TextEditingController();
  final _newDueCtrl = TextEditingController();
  final _newDescCtrl = TextEditingController();
  String _newPriority = 'medium';
  bool _showAddForm = false;

  static String _today() =>
      DateTime.now().toIso8601String().substring(0, 10);

  @override
  void initState() {
    super.initState();
    _showAddForm = widget.showAddForm;
    _load();
  }

  @override
  void didUpdateWidget(ReminderScreen old) {
    super.didUpdateWidget(old);
    if (widget.showAddForm != old.showAddForm) {
      _showAddForm = widget.showAddForm;
    }
  }

  @override
  void dispose() {
    _newTitleCtrl.dispose();
    _newDueCtrl.dispose();
    _newDescCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final all = await _api.list();
    if (!mounted) return;
    setState(() {
      _allReminders = all;
      _loading = false;
    });
  }

  Future<void> _toggleComplete(Reminder r) async {
    if (r.isCompleted) {
      await _api.update(id: r.id, status: 'pending');
    } else {
      await _api.complete(r.id);
    }
    _load();
  }

  Future<void> _deleteReminder(Reminder r) async {
    await _api.delete(r.id);
    _load();
  }

  Future<void> _addReminder() async {
    final title = _newTitleCtrl.text.trim();
    if (title.isEmpty) return;
    final due =
        _newDueCtrl.text.trim().isNotEmpty ? _newDueCtrl.text.trim() : null;
    final desc =
        _newDescCtrl.text.trim().isNotEmpty ? _newDescCtrl.text.trim() : null;
    await _api.create(title: title, dueDate: due, priority: _newPriority, description: desc);
    _newTitleCtrl.clear();
    _newDueCtrl.clear();
    _newDescCtrl.clear();
    _newPriority = 'medium';
    setState(() => _showAddForm = false);
    widget.onToggleAddForm?.call();
    _load();
  }

  Future<void> _showEditDialog(Reminder r) async {
    final titleCtrl = TextEditingController(text: r.title);
    final descCtrl = TextEditingController(text: r.description);
    final dueCtrl = TextEditingController(text: r.dueDate ?? '');
    String priority = r.priority;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            Future<void> pickDateTime() async {
              final now = DateTime.now();
              final initial = DateTime.tryParse(dueCtrl.text) ?? now;
              final picked = await showDatePicker(
                context: ctx,
                initialDate: initial.isBefore(now) ? now : initial,
                firstDate: now,
                lastDate: DateTime(now.year + 10, 12, 31),
              );
              if (picked == null || !ctx.mounted) return;
              final time = await showTimePicker(
                context: ctx,
                initialTime: TimeOfDay.fromDateTime(initial),
              );
              if (!ctx.mounted) return;
              if (time != null) {
                final h = time.hour.toString().padLeft(2, '0');
                final m = time.minute.toString().padLeft(2, '0');
                dueCtrl.text = '${picked.toIso8601String().substring(0, 10)} $h:$m:00';
              } else {
                dueCtrl.text = picked.toIso8601String().substring(0, 10);
              }
              setDialogState(() {});
            }

            return AlertDialog(
              title: const Text('编辑提醒事项'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(
                        labelText: '标题',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtrl,
                      decoration: const InputDecoration(
                        labelText: '备注',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: () async {
                        await pickDateTime();
                        setDialogState(() {});
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_today, size: 18, color: Colors.grey),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                dueCtrl.text.isNotEmpty
                                    ? dueCtrl.text
                                    : '到期日（可选）',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: dueCtrl.text.isNotEmpty
                                      ? theme.colorScheme.onSurface
                                      : theme.colorScheme.onSurface.withValues(alpha: 0.4),
                                ),
                              ),
                            ),
                            if (dueCtrl.text.isNotEmpty)
                              GestureDetector(
                                onTap: () {
                                  dueCtrl.clear();
                                  setDialogState(() {});
                                },
                                child: const Icon(Icons.close, size: 18, color: Colors.grey),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.flag, size: 18, color: Colors.grey),
                        const SizedBox(width: 8),
                        ...['low', 'medium', 'high'].map((p) {
                          const labels = {'low': '低', 'medium': '中', 'high': '高'};
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(labels[p]!, style: const TextStyle(fontSize: 12)),
                              selected: priority == p,
                              onSelected: (_) {
                                setDialogState(() => priority = p);
                              },
                              visualDensity: VisualDensity.compact,
                            ),
                          );
                        }),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'cancel'),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () async {
                    final del = await showDialog<bool>(
                      context: ctx,
                      builder: (c) => AlertDialog(
                        title: const Text('删除提醒事项'),
                        content: const Text('确定要删除这条提醒事项吗？此操作不可撤销。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                          TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('删除', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    );
                    if (del == true && ctx.mounted) {
                      Navigator.pop(ctx, 'delete');
                    }
                  },
                  child: const Text('删除', style: TextStyle(color: Colors.red)),
                ),
                FilledButton(
                  onPressed: titleCtrl.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(ctx, 'save'),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == 'save') {
      await _api.update(
        id: r.id,
        title: titleCtrl.text.trim(),
        description: descCtrl.text.trim(),
        dueDate: dueCtrl.text.trim().isNotEmpty ? dueCtrl.text.trim() : null,
        priority: priority,
      );
      _load();
    } else if (result == 'delete') {
      await _api.delete(r.id);
      _load();
    }
  }

  // --- Groups ---

  List<Reminder> get _todayItems => _allReminders.where((r) {
        if (r.isCompleted || r.dueDate == null) return false;
        return r.dueDate!.substring(0, 10) == _today();
      }).toList();

  List<Reminder> get _scheduledItems => _allReminders.where((r) {
        if (r.isCompleted || r.dueDate == null) return false;
        return r.dueDate!.substring(0, 10) != _today();
      }).toList();

  List<Reminder> get _noDateItems => _allReminders.where((r) {
        if (r.isCompleted) return false;
        return r.dueDate == null;
      }).toList();

  List<Reminder> get _completedItems =>
      _allReminders.where((r) => r.isCompleted).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                if (_todayItems.isNotEmpty) ...[
                  _SectionHeader(
                      title: '今天', count: _todayItems.length, theme: theme),
                  ..._todayItems.map((r) => _ReminderRow(
                        reminder: r,
                        onToggle: () => _toggleComplete(r),
                        onDelete: () => _deleteReminder(r),
                        onEdit: () => _showEditDialog(r),
                      )),
                  const SizedBox(height: 16),
                ],
                if (_scheduledItems.isNotEmpty) ...[
                  _SectionHeader(
                      title: '计划中',
                      count: _scheduledItems.length,
                      theme: theme),
                  ..._scheduledItems.map((r) => _ReminderRow(
                        reminder: r,
                        onToggle: () => _toggleComplete(r),
                        onDelete: () => _deleteReminder(r),
                        onEdit: () => _showEditDialog(r),
                      )),
                  const SizedBox(height: 16),
                ],
                if (_noDateItems.isNotEmpty) ...[
                  _SectionHeader(
                      title: '无日期',
                      count: _noDateItems.length,
                      theme: theme),
                  ..._noDateItems.map((r) => _ReminderRow(
                        reminder: r,
                        onToggle: () => _toggleComplete(r),
                        onDelete: () => _deleteReminder(r),
                        onEdit: () => _showEditDialog(r),
                      )),
                  const SizedBox(height: 16),
                ],
                if (_completedItems.isNotEmpty) ...[
                  _SectionHeader(
                      title: '已完成',
                      count: _completedItems.length,
                      theme: theme),
                  ..._completedItems.map((r) => _ReminderRow(
                        reminder: r,
                        onToggle: () => _toggleComplete(r),
                        onDelete: () => _deleteReminder(r),
                        onEdit: () => _showEditDialog(r),
                      )),
                ],
                // 快速添加入口 — 表单模式优先显示在顶部
                if (_showAddForm)
                  _AddReminderForm(
                    titleCtrl: _newTitleCtrl,
                    dueCtrl: _newDueCtrl,
                    descCtrl: _newDescCtrl,
                    priority: _newPriority,
                    onPriorityChanged: (v) => setState(() => _newPriority = v),
                    onSubmit: _addReminder,
                    onCancel: () {
                        setState(() => _showAddForm = false);
                        widget.onToggleAddForm?.call();
                      },
                    theme: theme,
                  ),
                if (_allReminders.isEmpty && !_showAddForm)
                  Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: Center(
                      child: Text(
                        '暂无提醒事项',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ),
                if (_allReminders.isEmpty && _showAddForm)
                  const SizedBox(height: 12),
                // 底部添加入口
                if (!_showAddForm) ...[
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () => setState(() => _showAddForm = true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                      child: Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            margin: const EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: theme.colorScheme.primary.withValues(alpha: 0.5),
                                width: 2,
                              ),
                            ),
                            child: Icon(Icons.add, size: 14,
                                color: theme.colorScheme.primary),
                          ),
                          Text(
                            '新提醒事项',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final ThemeData theme;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(
        '$title ($count)',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _ReminderRow extends StatelessWidget {
  final Reminder reminder;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  const _ReminderRow({
    required this.reminder,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCompleted = reminder.isCompleted;

    return Dismissible(
      key: Key(reminder.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.red.withValues(alpha: 0.15),
        child: const Icon(Icons.delete, color: Colors.red, size: 20),
      ),
      onDismissed: (_) => onDelete(),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          child: Row(
            children: [
              // 圆形复选框
              Container(
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isCompleted ? theme.colorScheme.primary : Colors.transparent,
                  border: Border.all(
                    color: isCompleted
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                    width: 2,
                  ),
                ),
                child: isCompleted
                    ? Icon(Icons.check, size: 14, color: theme.colorScheme.onPrimary)
                    : null,
              ),
              // 标题 + 描述
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reminder.title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        decoration: isCompleted ? TextDecoration.lineThrough : null,
                        color: isCompleted
                            ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (reminder.description.isNotEmpty)
                      Text(
                        reminder.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                  ],
                ),
              ),
              // 优先级
              if (!isCompleted && reminder.priority == 'high')
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text('❗❗❗',
                      style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
                )
              else if (!isCompleted && reminder.priority == 'medium')
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text('❗',
                      style: TextStyle(fontSize: 12, color: Colors.orange.shade400)),
                ),
              // 日期标签
              if (reminder.dueDate != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: _dueDateColor(reminder.dueDate!)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _formatDueDate(reminder.dueDate!),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: _dueDateColor(reminder.dueDate!),
                      fontSize: 11,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              SourceStatusIndicator(
                sourceStatus: reminder.sourceStatus,
                nodeId: reminder.id,
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: onEdit,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.more_horiz,
                    size: 20,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _dueDateColor(String due) {
    final now = DateTime.now();
    final today = now.toIso8601String().substring(0, 10);
    if (due.substring(0, 10) == today) {
      return Colors.blue;
    }
    final d = DateTime.tryParse(due);
    if (d != null && d.isBefore(now)) {
      return Colors.red;
    }
    return Colors.grey;
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
}

class _AddReminderForm extends StatefulWidget {
  final TextEditingController titleCtrl;
  final TextEditingController dueCtrl;
  final TextEditingController descCtrl;
  final String priority;
  final ValueChanged<String> onPriorityChanged;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;
  final ThemeData theme;

  const _AddReminderForm({
    required this.titleCtrl,
    required this.dueCtrl,
    required this.descCtrl,
    required this.priority,
    required this.onPriorityChanged,
    required this.onSubmit,
    required this.onCancel,
    required this.theme,
  });

  @override
  State<_AddReminderForm> createState() => _AddReminderFormState();
}

class _AddReminderFormState extends State<_AddReminderForm> {
  @override
  void initState() {
    super.initState();
    widget.titleCtrl.addListener(_onFieldChanged);
    widget.dueCtrl.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    widget.titleCtrl.removeListener(_onFieldChanged);
    widget.dueCtrl.removeListener(_onFieldChanged);
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(widget.dueCtrl.text) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: DateTime(now.year + 10, 12, 31),
    );
    if (picked != null && mounted) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(initial),
      );
      if (time != null && mounted) {
        final h = time.hour.toString().padLeft(2, '0');
        final m = time.minute.toString().padLeft(2, '0');
        widget.dueCtrl.text = '${picked.toIso8601String().substring(0, 10)} $h:$m:00';
      } else {
        widget.dueCtrl.text = picked.toIso8601String().substring(0, 10);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasTitle = widget.titleCtrl.text.trim().isNotEmpty;
    final hasDate = widget.dueCtrl.text.isNotEmpty;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: widget.theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: widget.titleCtrl,
              autofocus: true,
              style: widget.theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: '标题',
                border: InputBorder.none,
                hintStyle: widget.theme.textTheme.bodyLarge?.copyWith(
                  color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 到期日 — 可点击弹出日历，右侧 X 清空
            InkWell(
              onTap: _pickDateTime,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 16, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hasDate ? widget.dueCtrl.text : '到期日（可选）',
                        style: widget.theme.textTheme.bodySmall?.copyWith(
                          color: hasDate
                              ? widget.theme.colorScheme.onSurface
                              : widget.theme.colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                    if (hasDate)
                      GestureDetector(
                        onTap: () {
                          widget.dueCtrl.clear();
                        },
                        child: const Icon(Icons.close, size: 16, color: Colors.grey),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: widget.descCtrl,
              style: widget.theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: '备注',
                border: InputBorder.none,
                hintStyle: widget.theme.textTheme.bodyMedium?.copyWith(
                  color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
              maxLines: 2,
              minLines: 1,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.flag, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                ...['low', 'medium', 'high'].map((p) {
                  const labels = {'low': '低', 'medium': '中', 'high': '高'};
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(labels[p]!, style: const TextStyle(fontSize: 12)),
                      selected: widget.priority == p,
                      onSelected: (_) => widget.onPriorityChanged(p),
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: hasTitle ? widget.onSubmit : null,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('取消'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
