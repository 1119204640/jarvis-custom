import 'package:flutter/material.dart';
import '../../models/event.dart';
import '../../services/calendar_api.dart';
import 'month_view.dart';
import 'day_view.dart';
import 'event_edit_dialog.dart';
import 'google_auth_dialog.dart';

/// 日程功能主容器 — 切换月视图和日视图
class CalendarScreen extends StatefulWidget {
  final Widget? drawer;

  const CalendarScreen({super.key, this.drawer});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

enum _ViewMode { month, day }

class _CalendarScreenState extends State<CalendarScreen> {
  final CalendarApi _api = CalendarApi();
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey<ScaffoldMessengerState>();
  List<CalendarEvent> _events = [];
  bool _loading = false;
  String? _error;

  late DateTime _selectedDate;
  _ViewMode _viewMode = _ViewMode.month;
  DateTime _displayMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Load events for the current month + surrounding weeks
      final start = DateTime(_displayMonth.year, _displayMonth.month - 1, 20);
      final end = DateTime(_displayMonth.year, _displayMonth.month + 1, 10);
      final events = await _api.fetchEvents(start, end);
      if (mounted) {
        setState(() {
          _events = events;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _createEvent(Map<String, dynamic> eventData) async {
    final event = await _api.create(
      title: eventData['title'] ?? '',
      startTime: DateTime.parse(eventData['start_time']),
      endTime: DateTime.parse(eventData['end_time']),
      description: eventData['description'] ?? '',
      isAllDay: eventData['is_all_day'] ?? false,
      color: eventData['color'],
      type: eventData['type'] ?? 'plan',
      source: eventData['source'] ?? 'local',
    );
    if (event != null) {
      await _loadEvents();
    }
  }

  Future<void> _updateEventTimes(CalendarEvent event) async {
    // Called from DayView after drag-to-resize or drag-to-move
    final updated = await _api.update(
      id: event.id,
      startTime: event.startTime,
      endTime: event.endTime,
    );
    if (updated != null && mounted) {
      await _loadEvents();
    }
  }

  void _onDaySelected(DateTime day) {
    setState(() {
      _selectedDate = day;
    });
  }

  void _enterDayView() {
    setState(() {
      _viewMode = _ViewMode.day;
    });
  }

  Future<void> _onEventDelete(String eventId) async {
    final ok = await _api.delete(eventId);
    if (ok && mounted) {
      await _loadEvents();
    }
  }

  Future<void> _onEventTap(CalendarEvent event) async {
    final result = await EventEditDialog.show(context, event: event);
    if (result == null) return;

    if (result['_action'] == 'delete') {
      final ok = await _api.delete(event.id);
      if (ok && mounted) {
        await _loadEvents();
      }
      return;
    }

    if (result['_action'] == 'reclassify_to_todo') {
      final error = await CalendarApi.reclassify(event.id, 'todo');
      if (mounted) {
        if (error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('重新分类失败: $error')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已转换为待办')),
          );
          await _loadEvents();
        }
      }
      return;
    }

    final updated = await _api.update(
      id: event.id,
      title: result['title'] ?? '',
      description: result['description'] ?? '',
      startTime: DateTime.parse(result['start_time']),
      endTime: DateTime.parse(result['end_time']),
      isAllDay: result['is_all_day'] ?? false,
      color: result['color'],
      type: result['type'],
      source: result['source'],
    );
    if (updated != null && mounted) {
      await _loadEvents();
    }
  }

  void _onMonthChanged(DateTime month) {
    setState(() {
      _displayMonth = DateTime(month.year, month.month, 1);
    });
    _loadEvents();
  }

  void _onDateChanged(DateTime date) {
    setState(() {
      _selectedDate = date;
    });
  }

  Future<void> _syncGoogle() async {
    final result = await _api.triggerSync();
    if (!mounted) return;

    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final error = result['error'];
    if (error == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('已同步 ${result['synced_count'] ?? 0} 条日程'),
        ),
      );
      await _loadEvents();
    } else {
      final isNotConnected = '$error'.contains('not connected');
      messenger.showSnackBar(
        SnackBar(
          content: Text('同步失败: $error'),
          duration: Duration(seconds: isNotConnected ? 4 : 3),
          action: isNotConnected
              ? SnackBarAction(
                  label: '去绑定',
                  onPressed: () {
                    if (mounted) _showGoogleAuthDialog();
                  },
                )
              : null,
        ),
      );
    }
  }

  void _showGoogleAuthDialog() {
    showDialog(
      context: context,
      builder: (_) => GoogleAuthDialog(
        onConnected: _loadEvents,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
      drawer: widget.drawer,
      appBar: AppBar(
        title: const Text('日程'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // 日视图按钮 (仅月视图时显示)
          if (_viewMode == _ViewMode.month)
            IconButton(
              icon: const Icon(Icons.view_day),
              tooltip: '日视图',
              onPressed: _enterDayView,
            ),
          // Google 账户绑定入口
          IconButton(
            icon: const Icon(Icons.cloud_outlined),
            tooltip: '绑定 Google 日历',
            onPressed: _showGoogleAuthDialog,
          ),
          // 同步按钮
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: '同步 Google 日历',
            onPressed: _syncGoogle,
          ),
          // 新增按钮
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建日程',
            onPressed: () async {
              final result = await EventEditDialog.show(context);
              if (result == null) return;
              if (result['_action'] == 'delete') return;
              final event = await _api.create(
                title: result['title'] ?? '',
                startTime: DateTime.parse(result['start_time']),
                endTime: DateTime.parse(result['end_time']),
                description: result['description'] ?? '',
                isAllDay: result['is_all_day'] ?? false,
                color: result['color'],
                type: result['type'] ?? 'plan',
                source: result['source'] ?? 'local',
              );
              if (event != null && mounted) {
                await _loadEvents();
              }
            },
          ),
        ],
      ),
      body: _loading && _events.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _events.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _loadEvents,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _viewMode == _ViewMode.month
                  ? MonthView(
                      selectedDate: _selectedDate,
                      events: _events,
                      onDaySelected: _onDaySelected,
                      onMonthChanged: _onMonthChanged,
                      onEnterDayView: _enterDayView,
                      onEventTap: _onEventTap,
                    )
                  : DayView(
                      selectedDate: _selectedDate,
                      dayEvents: _events
                          .where((e) =>
                              e.startTime.year == _selectedDate.year &&
                              e.startTime.month == _selectedDate.month &&
                              e.startTime.day == _selectedDate.day)
                          .toList(),
                      monthEvents: _events,
                      onDateChanged: _onDateChanged,
                      onEventTap: _onEventTap,
                      onBackToMonth: () {
                        setState(() {
                          _viewMode = _ViewMode.month;
                          _displayMonth = DateTime(
                            _selectedDate.year,
                            _selectedDate.month,
                            1,
                          );
                        });
                        _loadEvents();
                      },
                      onCreateEvent: _createEvent,
                      onEventUpdated: _updateEventTimes,
                      onEventDelete: _onEventDelete,
                    ),
      ),
    );
  }

  @override
  void dispose() {
    _messengerKey.currentState?.hideCurrentSnackBar();
    super.dispose();
  }
}
