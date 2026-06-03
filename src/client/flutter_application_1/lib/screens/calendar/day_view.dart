import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/event.dart';
import '../../widgets/source_status_indicator.dart';
import 'event_edit_dialog.dart';

/// 仿苹果日历日视图
///
/// - 顶部：日期导航 + 返回月视图 + 全天日程区
/// - 左侧时间轴 (00:00-23:00)
/// - 中间日程卡片（按时间定位，可拖拽移动/调整时间）
/// - 右侧边栏：月视图缩略图 + 当日日程概览（桌面端）
/// - 当前时间红色横线
/// - 拖拽创建日程
class DayView extends StatefulWidget {
  final DateTime selectedDate;
  final List<CalendarEvent> dayEvents;
  final List<CalendarEvent> monthEvents; // 用于右侧边栏月视图缩略图
  final ValueChanged<DateTime> onDateChanged;
  final VoidCallback onBackToMonth;
  final Future<void> Function(Map<String, dynamic> eventData) onCreateEvent;
  final ValueChanged<CalendarEvent>? onEventTap;
  final Future<void> Function(CalendarEvent event)? onEventUpdated;
  final ValueChanged<String>? onEventDelete;

  const DayView({
    super.key,
    required this.selectedDate,
    required this.dayEvents,
    required this.monthEvents,
    required this.onDateChanged,
    required this.onBackToMonth,
    required this.onCreateEvent,
    this.onEventTap,
    this.onEventUpdated,
    this.onEventDelete,
  });

  @override
  State<DayView> createState() => _DayViewState();
}

// ── 拖拽类型 ──
enum _DragType { move, resizeTop, resizeBottom }

class _DayViewState extends State<DayView> {
  final ScrollController _scrollController = ScrollController();
  Timer? _timer;

  // ── 创建拖拽状态 ──
  bool _isDragging = false;
  double _dragStartY = 0;
  double _dragCurrentY = 0;

  // ── 迷你月历显示月份 ──
  late DateTime _miniMonthDisplay;

  // ── 事件卡拖拽状态 ──
  String? _dragEventId;
  _DragType _dragEventType = _DragType.move;
  double _dragEventStartY = 0;
  double _dragEventOffsetY = 0;

  static const _hourHeight = 60.0;
  static const _timeColWidth = 52.0;
  static const _hourCount = 24;
  static const _sidebarWidth = 220.0;

  @override
  void initState() {
    super.initState();
    _miniMonthDisplay = DateTime(widget.selectedDate.year, widget.selectedDate.month, 1);
    _scrollToCurrentTime();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant DayView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedDate.year != widget.selectedDate.year ||
        oldWidget.selectedDate.month != widget.selectedDate.month) {
      _miniMonthDisplay = DateTime(widget.selectedDate.year, widget.selectedDate.month, 1);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  double _timeToY(DateTime dt) {
    final local = dt.toLocal();
    final hour = local.hour + local.minute / 60.0;
    return hour * _hourHeight;
  }

  double get _scrollOffset =>
      _scrollController.hasClients ? _scrollController.offset : 0;

  DateTime _yToTime(double viewportY) {
    final contentY = viewportY + _scrollOffset;
    final totalMinutes = (contentY / _hourHeight * 60).round();
    final hour = totalMinutes ~/ 60;
    final minute = totalMinutes % 60;
    return DateTime(
      widget.selectedDate.year,
      widget.selectedDate.month,
      widget.selectedDate.day,
      hour.clamp(0, 23),
      minute.clamp(0, 59),
    );
  }

  void _scrollToCurrentTime() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = DateTime.now();
      final y = _timeToY(now) - 150;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(y.clamp(0, _scrollController.position.maxScrollExtent));
      }
    });
  }

  List<CalendarEvent> get _timedEvents =>
      widget.dayEvents.where((e) => !e.isAllDay).toList();

  List<CalendarEvent> get _allDayEvents =>
      widget.dayEvents.where((e) => e.isAllDay).toList();

  /// Compute column layout for overlapping events.
  /// Returns a map from event id to (column, totalColumns).
  Map<String, _EventColumnInfo> _computeEventColumns() {
    final events = _timedEvents;
    if (events.isEmpty) return {};

    final sorted = [...events]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    final columns = <List<CalendarEvent>>[];

    for (final event in sorted) {
      bool placed = false;
      for (final column in columns) {
        final lastInColumn = column.last;
        if (!event.startTime.isBefore(lastInColumn.endTime)) {
          column.add(event);
          placed = true;
          break;
        }
      }
      if (!placed) {
        columns.add([event]);
      }
    }

    final result = <String, _EventColumnInfo>{};
    final totalCols = columns.length;
    for (var colIdx = 0; colIdx < totalCols; colIdx++) {
      for (final event in columns[colIdx]) {
        result[event.id] = _EventColumnInfo(
          column: colIdx,
          totalColumns: totalCols,
        );
      }
    }
    return result;
  }

  void _goToPreviousDay() {
    widget.onDateChanged(
      widget.selectedDate.subtract(const Duration(days: 1)),
    );
  }

  void _goToNextDay() {
    widget.onDateChanged(
      widget.selectedDate.add(const Duration(days: 1)),
    );
  }

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '今天';
    }
    const week = ['周一','周二','周三','周四','周五','周六','周日'];
    return '${d.month}月${d.day}日 ${week[d.weekday - 1]}';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final isToday = widget.selectedDate.year == now.year &&
        widget.selectedDate.month == now.month &&
        widget.selectedDate.day == now.day;
    final showSidebar = _isDesktop();

    return Column(
      children: [
        _buildHeader(cs),
        if (_allDayEvents.isNotEmpty) _buildAllDayBar(cs),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 时间轴 + 日程（主区域）──
              Expanded(child: _buildTimeline(cs, isToday, now)),
              // ── 右侧边栏（仅桌面端）──
              if (showSidebar)
                SizedBox(
                  width: _sidebarWidth,
                  child: _buildSidebar(cs),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Timeline
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildTimeline(ColorScheme cs, bool isToday, DateTime now) {
    final eventColumns = _computeEventColumns();
    return Stack(
      children: [
        GestureDetector(
          onPanStart: _isDesktop()
              ? (d) {
                  final x = d.localPosition.dx;
                  if (x < _timeColWidth) return;
                  setState(() {
                    _isDragging = true;
                    _dragStartY = d.localPosition.dy;
                    _dragCurrentY = d.localPosition.dy;
                  });
                }
              : null,
          onPanUpdate: _isDesktop()
              ? (d) {
                  if (!_isDragging) return;
                  setState(() => _dragCurrentY = d.localPosition.dy);
                }
              : null,
          onPanEnd: _isDesktop()
              ? (d) async {
                  if (!_isDragging) return;
                  setState(() => _isDragging = false);
                  final minY = _dragStartY < _dragCurrentY ? _dragStartY : _dragCurrentY;
                  final maxY = _dragStartY > _dragCurrentY ? _dragStartY : _dragCurrentY;
                  if ((maxY - minY).abs() < 15) return;
                  final start = _yToTime(minY);
                  final end = _yToTime(maxY);
                  final result = await EventEditDialog.show(
                    context,
                    initialStart: start,
                    initialEnd: end,
                  );
                  if (result != null && mounted) {
                    if (result['_action'] == 'delete') return;
                    await widget.onCreateEvent(result);
                  }
                }
              : null,
          child: SingleChildScrollView(
            controller: _scrollController,
            child: SizedBox(
              height: _hourHeight * _hourCount,
              child: Stack(
                children: [
                  // 时间网格线
                  ...List.generate(_hourCount, (h) {
                    return Positioned(
                      left: 0,
                      right: 0,
                      top: h * _hourHeight,
                      child: Row(
                        children: [
                          SizedBox(
                            width: _timeColWidth,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '${h.toString().padLeft(2, '0')}:00',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurface.withAlpha(130),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Container(
                              height: 0.5,
                              color: cs.outlineVariant.withAlpha(80),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  // 事件卡片
                  ..._timedEvents.map((e) => _buildEventCard(cs, e, eventColumns)),
                  // 当前时间红线
                  if (isToday)
                    Positioned(
                      left: _timeColWidth,
                      right: 0,
                      top: _timeToY(now),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: cs.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Container(height: 1.5, color: cs.error),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        // 创建拖拽覆盖层
        if (_isDragging && _isDesktop())
          Positioned(
            left: _timeColWidth + 4,
            right: 4,
            top: _dragStartY < _dragCurrentY ? _dragStartY : _dragCurrentY,
            child: Container(
              height: (_dragCurrentY - _dragStartY).abs(),
              decoration: BoxDecoration(
                color: cs.primary.withAlpha(50),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: cs.primary.withAlpha(150)),
              ),
            ),
          ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sidebar
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildSidebar(ColorScheme cs) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: cs.outlineVariant.withAlpha(60)),
        ),
      ),
      child: Column(
        children: [
          // ── 月视图缩略图 ──
          _buildMiniMonth(cs),
          const Divider(height: 1),
          // ── 当日日程概览 ──
          Expanded(child: _buildDayEventList(cs)),
        ],
      ),
    );
  }

  /// 迷你月视图 (7列 × 5-6行)，带月份切换箭头
  Widget _buildMiniMonth(ColorScheme cs) {
    final now = DateTime.now();
    final firstDay = DateTime(_miniMonthDisplay.year, _miniMonthDisplay.month, 1);
    final lastDay = DateTime(_miniMonthDisplay.year, _miniMonthDisplay.month + 1, 0);
    final firstWeekday = firstDay.weekday; // 1=Mon

    // 按日期分组事件（用于圆点）
    final eventsByDay = <DateTime, List<CalendarEvent>>{};
    for (final e in widget.monthEvents) {
      final day = DateTime(e.startTime.year, e.startTime.month, e.startTime.day);
      eventsByDay.putIfAbsent(day, () => []).add(e);
    }

    final cells = <Widget>[];
    // 星期标题
    for (final d in ['日','一','二','三','四','五','六']) {
      cells.add(
        Center(
          child: Text(d, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w500,
              color: cs.onSurface.withAlpha(120))),
        ),
      );
    }
    // 空白填充
    final blanks = firstWeekday == 7 ? 0 : firstWeekday;
    for (var i = 0; i < blanks; i++) {
      cells.add(const SizedBox());
    }
    // 日期
    for (var d = 1; d <= lastDay.day; d++) {
      final day = DateTime(_miniMonthDisplay.year, _miniMonthDisplay.month, d);
      final isSelected = _isSameDay(day, widget.selectedDate);
      final isToday = _isSameDay(day, now);
      final hasEvents = eventsByDay.containsKey(day);

      cells.add(
        GestureDetector(
          onTap: () => widget.onDateChanged(day),
          child: Container(
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              color: isSelected ? cs.primaryContainer : null,
              borderRadius: BorderRadius.circular(4),
              border: isSelected ? Border.all(color: cs.primary, width: 1) : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: isToday ? cs.primary : null,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$d',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                      color: isToday
                          ? cs.onPrimary
                          : (day.weekday == 6 || day.weekday == 7)
                              ? cs.error.withAlpha(150)
                              : cs.onSurface,
                    ),
                  ),
                ),
                if (hasEvents)
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.only(top: 1),
                    decoration: BoxDecoration(
                      color: cs.primary.withAlpha(180),
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 月份标题 + 切换箭头
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () {
                    setState(() {
                      _miniMonthDisplay = DateTime(
                        _miniMonthDisplay.year,
                        _miniMonthDisplay.month - 1,
                        1,
                      );
                    });
                  },
                ),
              ),
              GestureDetector(
                onTap: widget.onBackToMonth,
                child: Text(
                  '${_miniMonthDisplay.year}年${_miniMonthDisplay.month}月',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary),
                ),
              ),
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () {
                    setState(() {
                      _miniMonthDisplay = DateTime(
                        _miniMonthDisplay.year,
                        _miniMonthDisplay.month + 1,
                        1,
                      );
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            mainAxisSpacing: 0,
            crossAxisSpacing: 0,
            childAspectRatio: 0.9,
            physics: const NeverScrollableScrollPhysics(),
            children: cells,
          ),
        ],
      ),
    );
  }

  /// 侧边栏：当日日程列表
  Widget _buildDayEventList(ColorScheme cs) {
    final allEvents = [..._allDayEvents, ..._timedEvents];
    if (allEvents.isEmpty) {
      return Center(
        child: Text('当天无日程',
            style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(100))),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: allEvents.length,
      itemBuilder: (_, i) {
        final e = allEvents[i];
        final localStart = e.startTime.toLocal();
        final localEnd = e.endTime.toLocal();
        final timeStr = e.isAllDay
            ? '全天'
            : '${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}'
              ' - '
              '${localEnd.hour.toString().padLeft(2, '0')}:${localEnd.minute.toString().padLeft(2, '0')}';
        final color = _eventColor(e, cs);

        return GestureDetector(
          onTap: widget.onEventTap != null ? () => widget.onEventTap!(e) : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.only(left: 6, top: 4, bottom: 4, right: 2),
              decoration: BoxDecoration(
                color: color.withAlpha(20),
                border: Border(left: BorderSide(color: color, width: 3)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
                        Text(timeStr,
                            style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(120))),
                      ],
                    ),
                  ),
                  SourceStatusIndicator(
                    sourceStatus: e.sourceStatus,
                    nodeId: e.id,
                  ),
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 14,
                      icon: Icon(Icons.close, size: 14, color: cs.onSurface.withAlpha(100)),
                      onPressed: () => widget.onEventDelete?.call(e.id),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Header
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildHeader(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: widget.onBackToMonth,
            tooltip: '返回月视图',
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _goToPreviousDay,
            tooltip: '前一天',
          ),
          Expanded(
            child: GestureDetector(
              onTap: widget.onBackToMonth,
              child: Text(
                _dayLabel(widget.selectedDate),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _goToNextDay,
            tooltip: '后一天',
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildAllDayBar(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.only(left: _timeColWidth + 4, right: 8, bottom: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
      ),
      child: Wrap(
        spacing: 6,
        children: _allDayEvents.map((e) {
          final color = _eventColor(e, cs);
          return Chip(
            avatar: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            label: Text(e.title, style: const TextStyle(fontSize: 12)),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          );
        }).toList(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Event card (with drag support)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildEventCard(
    ColorScheme cs,
    CalendarEvent e,
    Map<String, _EventColumnInfo> columnLayout,
  ) {
    final startY = _timeToY(e.startTime);
    final endY = _timeToY(e.endTime);
    final height = (endY - startY).clamp(20.0, _hourHeight * _hourCount);
    final color = _eventColor(e, cs);
    final duration = e.endTime.difference(e.startTime);
    final isShort = duration.inMinutes < 30;
    final isDraggingThis = _dragEventId == e.id;

    // 拖拽偏移（仅在拖拽此卡片时生效）
    double offsetY = 0;
    double heightDelta = 0;
    if (isDraggingThis && _isDesktop()) {
      if (_dragEventType == _DragType.move) {
        offsetY = _dragEventOffsetY;
      } else if (_dragEventType == _DragType.resizeTop) {
        offsetY = _dragEventOffsetY;
        heightDelta = -_dragEventOffsetY;
      } else if (_dragEventType == _DragType.resizeBottom) {
        heightDelta = _dragEventOffsetY;
      }
    }

    final cardTop = startY + offsetY;
    final cardHeight = (height + heightDelta).clamp(20.0, _hourHeight * _hourCount);

    // Compute horizontal position from column layout (overlap handling)
    final colInfo = columnLayout[e.id];
    final int col = colInfo?.column ?? 0;
    final int total = colInfo?.totalColumns ?? 1;
    final stackWidth = MediaQuery.of(context).size.width
        - (_isDesktop() ? _sidebarWidth : 0);
    final availableWidth = stackWidth - _timeColWidth - 8;
    final colWidth = availableWidth / total;
    final leftOffset = _timeColWidth + 4 + col * colWidth;
    final rightOffset = 4 + (total - col - 1) * colWidth;

    return Positioned(
      left: leftOffset,
      right: rightOffset,
      top: cardTop,
      height: cardHeight,
      child: _isDesktop()
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部拖拽手柄（调整开始时间）
                _buildResizeHandle(cs, color, e, _DragType.resizeTop),
                // 卡片主体（可拖拽移动）
                Expanded(
                  child: GestureDetector(
                    onTap: widget.onEventTap != null ? () => widget.onEventTap!(e) : null,
                    onPanStart: (d) {
                      _dragEventId = e.id;
                      _dragEventType = _DragType.move;
                      _dragEventStartY = d.globalPosition.dy;
                      _dragEventOffsetY = 0;
                      setState(() {});
                    },
                    onPanUpdate: (d) {
                      _dragEventOffsetY = d.globalPosition.dy - _dragEventStartY;
                      setState(() {});
                    },
                    onPanEnd: (_) async {
                      if (_dragEventOffsetY.abs() > 10) {
                        final deltaMins = (_dragEventOffsetY / _hourHeight * 60).round();
                        final newStart = e.startTime.add(Duration(minutes: deltaMins));
                        final newEnd = e.endTime.add(Duration(minutes: deltaMins));
                        final updated = e.copyWith(startTime: newStart, endTime: newEnd);
                        widget.onEventUpdated?.call(updated);
                      }
                      _dragEventId = null;
                      _dragEventOffsetY = 0;
                      if (mounted) setState(() {});
                    },
                    child: _buildCardContent(cs, e, isShort, color, isDraggingThis),
                  ),
                ),
                // 底部拖拽手柄（调整结束时间）
                _buildResizeHandle(cs, color, e, _DragType.resizeBottom),
              ],
            )
          : GestureDetector(
              onTap: widget.onEventTap != null ? () => widget.onEventTap!(e) : null,
              child: _buildCardContent(cs, e, isShort, color, false),
            ),
    );
  }

  Widget _buildResizeHandle(ColorScheme cs, Color color, CalendarEvent e, _DragType type) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) {
        _dragEventId = e.id;
        _dragEventType = type;
        _dragEventStartY = 0;
        _dragEventOffsetY = 0;
        setState(() {});
      },
      onPanUpdate: (d) {
        _dragEventOffsetY += d.delta.dy;
        setState(() {});
      },
      onPanEnd: (_) async {
        if (_dragEventOffsetY.abs() > 5) {
          final deltaMins = (_dragEventOffsetY / _hourHeight * 60).round();
          if (type == _DragType.resizeTop) {
            final newStart = e.startTime.add(Duration(minutes: deltaMins));
            if (newStart.isBefore(e.endTime)) {
              final updated = e.copyWith(startTime: newStart);
              widget.onEventUpdated?.call(updated);
            }
          } else {
            final newEnd = e.endTime.add(Duration(minutes: deltaMins));
            if (newEnd.isAfter(e.startTime)) {
              final updated = e.copyWith(endTime: newEnd);
              widget.onEventUpdated?.call(updated);
            }
          }
        }
        _dragEventId = null;
        _dragEventOffsetY = 0;
        if (mounted) setState(() {});
      },
      child: Container(
        height: 8,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _dragEventId == e.id && _dragEventType == type
              ? color.withAlpha(60)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(2),
        ),
        child: Center(
          child: Container(
            width: 20,
            height: 3,
            decoration: BoxDecoration(
              color: _dragEventId == e.id && _dragEventType == type
                  ? color
                  : color.withAlpha(80),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardContent(ColorScheme cs, CalendarEvent e, bool isShort,
      Color color, bool isDragging) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        decoration: BoxDecoration(
          color: isDragging
              ? color.withAlpha(60)
              : color.withAlpha(30),
          border: Border(
            left: BorderSide(color: color, width: 3),
            top: isDragging ? BorderSide(color: color.withAlpha(120)) : BorderSide.none,
            bottom: isDragging ? BorderSide(color: color.withAlpha(120)) : BorderSide.none,
            right: isDragging ? BorderSide(color: color.withAlpha(120)) : BorderSide.none,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: isShort
          ? Row(
              children: [
                Expanded(
                  child: Text(
                    '${e.startTime.toLocal().hour.toString().padLeft(2, '0')}:${e.startTime.toLocal().minute.toString().padLeft(2, '0')}'
                    ' ${e.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(180)),
                  ),
                ),
                SourceStatusIndicator(
                  sourceStatus: e.sourceStatus,
                  nodeId: e.id,
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ),
                    SourceStatusIndicator(
                      sourceStatus: e.sourceStatus,
                      nodeId: e.id,
                    ),
                  ],
                ),
                Text(
                  '${e.startTime.toLocal().hour.toString().padLeft(2, '0')}:${e.startTime.toLocal().minute.toString().padLeft(2, '0')}'
                  ' - '
                  '${e.endTime.toLocal().hour.toString().padLeft(2, '0')}:${e.endTime.toLocal().minute.toString().padLeft(2, '0')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(150)),
                ),
              ],
            ),
      ),
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

class _EventColumnInfo {
  final int column;
  final int totalColumns;
  const _EventColumnInfo({required this.column, required this.totalColumns});
}
