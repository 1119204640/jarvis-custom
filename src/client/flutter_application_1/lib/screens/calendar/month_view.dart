import 'package:flutter/material.dart';
import 'package:lunar/lunar.dart';
import '../../models/event.dart';
import '../../widgets/source_status_indicator.dart';
import 'year_month_picker.dart';

/// 仿苹果日历月视图
///
/// - 顶部：◀ 2026年5月 ▶，点击中间弹出年月快速选择器
/// - 7列 × 5-6 行日历网格
/// - 每格显示日期数字 + 事件圆点
/// - 今天红色圆点高亮，选中日期蓝色边框高亮
/// - 底部显示选中日期的日程列表
class MonthView extends StatefulWidget {
  final DateTime selectedDate;
  final List<CalendarEvent> events;
  final ValueChanged<DateTime> onDaySelected;
  final ValueChanged<DateTime> onMonthChanged;
  final VoidCallback? onEnterDayView;
  final ValueChanged<CalendarEvent>? onEventTap;

  const MonthView({
    super.key,
    required this.selectedDate,
    required this.events,
    required this.onDaySelected,
    required this.onMonthChanged,
    this.onEnterDayView,
    this.onEventTap,
  });

  @override
  State<MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<MonthView> {
  late DateTime _currentMonth; // always the 1st of the displayed month

  static const _weekDays = ['日', '一', '二', '三', '四', '五', '六'];

  @override
  void initState() {
    super.initState();
    _currentMonth = DateTime(widget.selectedDate.year, widget.selectedDate.month, 1);
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MonthView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedDate.year != widget.selectedDate.year ||
        oldWidget.selectedDate.month != widget.selectedDate.month) {
      _currentMonth = DateTime(widget.selectedDate.year, widget.selectedDate.month, 1);
    }
  }

  void _goToPreviousMonth() {
    _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1, 1);
    widget.onMonthChanged(_currentMonth);
    setState(() {});
  }

  void _goToNextMonth() {
    _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 1);
    widget.onMonthChanged(_currentMonth);
    setState(() {});
  }

  Future<void> _openPicker() async {
    final result = await YearMonthPicker.show(
      context,
      year: _currentMonth.year,
      month: _currentMonth.month,
    );
    if (result != null) {
      _currentMonth = result;
      widget.onMonthChanged(_currentMonth);
      setState(() {});
    }
  }

  List<List<DateTime?>> _buildCalendarGrid() {
    final firstDay = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final lastDay = DateTime(_currentMonth.year, _currentMonth.month + 1, 0);
    final totalDays = lastDay.day;

    // Monday=1 ... Sunday=7; Sunday is column 0
    final firstWeekday = firstDay.weekday;

    final rows = <List<DateTime?>>[];
    var currentRow = <DateTime?>[];
    final blanks = firstWeekday == 7 ? 0 : firstWeekday;
    for (var i = 0; i < blanks; i++) {
      currentRow.add(null);
    }

    for (var d = 1; d <= totalDays; d++) {
      currentRow.add(DateTime(_currentMonth.year, _currentMonth.month, d));
      if (currentRow.length == 7) {
        rows.add(currentRow);
        currentRow = [];
      }
    }
    if (currentRow.isNotEmpty) {
      while (currentRow.length < 7) {
        currentRow.add(null);
      }
      rows.add(currentRow);
    }
    // Ensure at least 5 rows for consistent height
    while (rows.length < 5) {
      rows.add(List.filled(7, null));
    }
    return rows;
  }

  Map<DateTime, List<CalendarEvent>> _groupEventsByDay() {
    final map = <DateTime, List<CalendarEvent>>{};
    for (final e in widget.events) {
      final day = DateTime(e.startTime.year, e.startTime.month, e.startTime.day);
      map.putIfAbsent(day, () => []).add(e);
    }
    return map;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isToday(DateTime day) {
    final now = DateTime.now();
    return _isSameDay(day, now);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final grid = _buildCalendarGrid();
    // 只计算一次，避免每个格子重复遍历所有事件
    final eventsByDay = _groupEventsByDay();
    final selectedEvents = eventsByDay[widget.selectedDate] ?? [];

    return Column(
      children: [
        // ── 顶部月份切换栏 ──
        _buildHeader(cs),

        // ── 星期标题行 ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: _weekDays.map((d) {
              final isWeekend = d == '六' || d == '日';
              return Expanded(
                child: Center(
                  child: Text(
                    d,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isWeekend
                          ? cs.error.withAlpha(180)
                          : cs.onSurface.withAlpha(150),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),

        // ── 日历网格 ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            children: grid.map((row) {
              return SizedBox(
                height: (_isDesktop() ? 70 : 58),
                child: Row(
                  children: row.map((day) {
                    return Expanded(
                      child: day == null
                          ? const SizedBox()
                          : _buildDayCell(cs, day, eventsByDay),
                    );
                  }).toList(),
                ),
              );
            }).toList(),
          ),
        ),

        // ── 底部选中日期的日程列表 ──
        const Divider(height: 1),
        Expanded(
          child: _buildEventList(cs, selectedEvents),
        ),
      ],
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _goToPreviousMonth,
            tooltip: '上个月',
          ),
          Expanded(
            child: GestureDetector(
              onTap: _openPicker,
              child: Text(
                '${_currentMonth.year}年${_currentMonth.month}月',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _goToNextMonth,
            tooltip: '下个月',
          ),
        ],
      ),
    );
  }

  Widget _buildDayCell(ColorScheme cs, DateTime day,
      Map<DateTime, List<CalendarEvent>> eventsByDay) {
    final isSelected = _isSameDay(day, widget.selectedDate);
    final isTodayFlag = _isToday(day);
    final dayEvents = eventsByDay[day] ?? [];
    final lunarDay = Lunar.fromDate(day).getDayInChinese();

    return GestureDetector(
      onTap: () => widget.onDaySelected(day),
      child: Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: isSelected ? cs.primaryContainer : null,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: cs.primary, width: 1.5)
              : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 日期数字
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isTodayFlag ? cs.primary : null,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${day.day}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          isTodayFlag ? FontWeight.bold : FontWeight.normal,
                      color: isTodayFlag
                          ? cs.onPrimary
                          : (day.weekday == 6 || day.weekday == 7)
                              ? cs.error.withAlpha(180)
                              : cs.onSurface,
                    ),
                  ),
                ),
                // 农历文字
                Text(
                  lunarDay,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurface.withAlpha(130),
                  ),
                ),
                // 事件圆点（最多3个）
                if (dayEvents.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: dayEvents.take(3).map((e) {
                        final dotColor = _eventColor(e, cs);
                        return Container(
                          width: 5,
                          height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ),
            // 进入日视图按钮（右上角，仅选中时显示）
            if (isSelected && widget.onEnterDayView != null)
              Positioned(
                top: 0,
                right: 0,
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 13,
                    icon: Icon(Icons.open_in_full,
                        color: cs.onSurface.withAlpha(70)),
                    tooltip: '进入日视图',
                    onPressed: () {
                      widget.onDaySelected(day);
                      widget.onEnterDayView?.call();
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEventList(ColorScheme cs, List<CalendarEvent> events) {
    if (events.isEmpty) {
      return Center(
        child: Text(
          '当天无日程',
          style: TextStyle(
            color: cs.onSurface.withAlpha(100),
            fontSize: 14,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: events.length,
      itemBuilder: (_, i) {
        final e = events[i];
        final localStart = e.startTime.toLocal();
        final startStr = e.isAllDay
            ? '全天'
            : '${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}';
        final color = _eventColor(e, cs);

        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            onTap: widget.onEventTap != null ? () => widget.onEventTap!(e) : null,
            leading: Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            title: Text(
              e.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              '${e.type == 'record' ? '📝 记录' : '📋 计划'}  $startStr${e.description.isNotEmpty ? ' — ${e.description}' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(150)),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SourceStatusIndicator(
                  sourceStatus: e.sourceStatus,
                  nodeId: e.id,
                ),
                if (e.isGoogleEvent)
                  Icon(Icons.cloud_outlined, size: 16, color: cs.onSurface.withAlpha(120)),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _eventColor(CalendarEvent e, ColorScheme cs) {
    if (e.color != null) {
      return Color(int.parse(e.color!.replaceFirst('#', '0xFF')));
    }
    return e.isGoogleEvent ? const Color(0xFF4285F4) : cs.primary;
  }

  bool _isDesktop() {
    final width = MediaQuery.of(context).size.width;
    return width >= 600;
  }
}
