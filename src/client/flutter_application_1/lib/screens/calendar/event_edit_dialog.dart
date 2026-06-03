import 'package:flutter/material.dart';
import '../../models/event.dart';

/// 日程编辑弹窗
///
/// 用于创建或编辑日程。isNew=true 时为空表单，否则填充已有数据。
class EventEditDialog extends StatefulWidget {
  final CalendarEvent? event;
  final DateTime? initialDate;
  final DateTime? initialStart;
  final DateTime? initialEnd;

  const EventEditDialog({
    super.key,
    this.event,
    this.initialDate,
    this.initialStart,
    this.initialEnd,
  });

  /// 打开弹窗，返回 title/start/end/isAllDay/description/color 的 map
  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    CalendarEvent? event,
    DateTime? initialDate,
    DateTime? initialStart,
    DateTime? initialEnd,
  }) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => EventEditDialog(
        event: event,
        initialDate: initialDate,
        initialStart: initialStart,
        initialEnd: initialEnd,
      ),
    );
  }

  @override
  State<EventEditDialog> createState() => _EventEditDialogState();
}

class _EventEditDialogState extends State<EventEditDialog> {
  late TextEditingController _titleCtrl;
  late TextEditingController _descCtrl;
  late DateTime _start;
  late DateTime _end;
  late bool _isAllDay;
  late String? _color;
  late String _type;
  late String _source; // 'local' or 'google'
  bool get _isNew => widget.event == null;

  static const _colors = {
    '默认': null,
    '蓝色': '#4285F4',
    '红色': '#EA4335',
    '黄色': '#FBBC04',
    '绿色': '#34A853',
    '紫色': '#A142F4',
    '青色': '#24C1E0',
    '橙色': '#F4511E',
  };

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _titleCtrl = TextEditingController(text: e?.title ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _start = e?.startTime ?? widget.initialStart ?? DateTime.now();
    _end = e?.endTime ?? widget.initialEnd ?? DateTime.now().add(const Duration(hours: 1));
    _isAllDay = e?.isAllDay ?? false;
    _color = e?.color;
    _type = e?.type ?? 'plan';
    _source = e?.source ?? 'local';
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime(bool isStart) async {
    final current = isStart ? _start : _end;
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (date == null) return;

    if (_isAllDay) {
      setState(() {
        if (isStart) {
          _start = DateTime(date.year, date.month, date.day);
          _end = DateTime(date.year, date.month, date.day, 23, 59);
        } else {
          _end = DateTime(date.year, date.month, date.day, 23, 59);
        }
      });
      return;
    }

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null) return;

    setState(() {
      final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      if (isStart) {
        _start = dt;
      } else {
        _end = dt;
      }
    });
  }

  String _formatDT(DateTime dt) {
    final local = dt.toLocal();
    if (_isAllDay) {
      return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    }
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text(_isNew ? '新建日程' : '编辑日程'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 来源提示
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: _source == 'google' ? cs.primaryContainer : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _source == 'google' ? Icons.cloud : Icons.phone_android,
                    size: 14,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _source == 'google' ? 'Google 日历' : '本地日程',
                    style: TextStyle(fontSize: 12, color: cs.primary),
                  ),
                ],
              ),
            ),
            // 标题
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: '标题',
                border: OutlineInputBorder(),
              ),
            ),
            // 来源选择
            const SizedBox(height: 12),
            const Text('日程来源：', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('📌 本地'),
                  selected: _source == 'local',
                  onSelected: (_) => setState(() => _source = 'local'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('🔗 Google'),
                  selected: _source == 'google',
                  onSelected: (_) => setState(() => _source = 'google'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 全天开关
            SwitchListTile(
              title: const Text('全天'),
              value: _isAllDay,
              onChanged: (v) => setState(() => _isAllDay = v),
            ),
            // 开始时间
            ListTile(
              title: const Text('开始'),
              subtitle: Text(_formatDT(_start)),
              trailing: const Icon(Icons.edit_calendar),
              onTap: () => _pickDateTime(true),
            ),
            // 结束时间
            ListTile(
              title: const Text('结束'),
              subtitle: Text(_formatDT(_end)),
              trailing: const Icon(Icons.edit_calendar),
              onTap: () => _pickDateTime(false),
            ),
            // 描述
            TextField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: '描述',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            // 类型选择
            Row(
              children: [
                const Text('类型：', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('📋 计划'),
                  selected: _type == 'plan',
                  onSelected: (_) => setState(() => _type = 'plan'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('📝 记录'),
                  selected: _type == 'record',
                  onSelected: (_) => setState(() => _type = 'record'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 颜色选择
            Row(
              children: _colors.entries.map((entry) {
                final selected = _color == entry.value;
                return GestureDetector(
                  onTap: () => setState(() => _color = entry.value),
                  child: Container(
                    width: 28,
                    height: 28,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: selected ? Border.all(color: cs.primary, width: 2) : null,
                      color: entry.value != null
                          ? Color(int.parse(entry.value!.replaceFirst('#', '0xFF')))
                          : cs.outline.withAlpha(60),
                    ),
                    child: selected
                        ? Icon(Icons.check, size: 14, color: cs.onPrimary)
                        : null,
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        // 删除 (仅编辑已有日程)
        if (!_isNew)
          TextButton(
            onPressed: () => Navigator.pop(context, {'_action': 'delete'}),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        if (!_isNew && widget.event!.hasParent)
          TextButton(
            onPressed: () => Navigator.pop(context, {'_action': 'reclassify_to_todo'}),
            child: const Text('转换为待办', style: TextStyle(color: Colors.orange)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context, {
              'title': _titleCtrl.text,
              'start_time': _start.toIso8601String(),
              'end_time': _end.toIso8601String(),
              'is_all_day': _isAllDay,
              'description': _descCtrl.text,
              'color': _color,
              'type': _type,
              'source': _source,
            });
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
