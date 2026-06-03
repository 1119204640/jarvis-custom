/// 日程数据模型 — 统一本地和 Google 日程
class CalendarEvent {
  final String id;
  final String title;
  final String description;
  final DateTime startTime;
  final DateTime endTime;
  final bool isAllDay;
  final String source;
  final String? externalId;
  final String? recurrence;
  final String status;
  final String? color;
  final String type; // 'record' = 记录每日所做, 'plan' = 计划未来安排
  final String? parentId; // 母节点 ID（由文档库资产派生时非空）
  final String? parentTitle; // 母节点标题
  final String? sourceFile;
  final String? sourceFormat;
  final String? sourceStatus; // native / linked / source_deleted / association_lost
  final DateTime createdAt;
  final DateTime updatedAt;

  const CalendarEvent({
    required this.id,
    required this.title,
    this.description = '',
    required this.startTime,
    required this.endTime,
    this.isAllDay = false,
    this.source = 'local',
    this.externalId,
    this.recurrence,
    this.status = 'confirmed',
    this.color,
    this.type = 'plan',
    this.parentId,
    this.parentTitle,
    this.sourceFile,
    this.sourceFormat,
    this.sourceStatus,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isGoogleEvent => source == 'google';
  bool get hasParent => parentId != null && parentId!.isNotEmpty;

  factory CalendarEvent.fromJson(Map<String, dynamic> json) {
    return CalendarEvent(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      startTime: DateTime.parse(json['start_time'] as String),
      endTime: DateTime.parse(json['end_time'] as String),
      isAllDay: json['is_all_day'] as bool? ?? false,
      source: json['source'] as String? ?? 'local',
      externalId: json['external_id'] as String?,
      recurrence: json['recurrence'] as String?,
      status: json['status'] as String? ?? 'confirmed',
      color: json['color'] as String?,
      type: json['type'] as String? ?? 'plan',
      parentId: json['parent_id'] as String?,
      parentTitle: json['parent_title'] as String?,
      sourceFile: json['source_file'] as String?,
      sourceFormat: json['source_format'] as String?,
      sourceStatus: json['source_status'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'start_time': startTime.toIso8601String(),
        'end_time': endTime.toIso8601String(),
        'is_all_day': isAllDay,
        'color': color,
        'type': type,
        'source': source,
      };

  CalendarEvent copyWith({
    String? id,
    String? title,
    String? description,
    DateTime? startTime,
    DateTime? endTime,
    bool? isAllDay,
    String? source,
    String? externalId,
    String? recurrence,
    String? status,
    String? color,
    String? type,
    String? parentId,
    String? parentTitle,
    String? sourceFile,
    String? sourceFormat,
    String? sourceStatus,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CalendarEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      isAllDay: isAllDay ?? this.isAllDay,
      source: source ?? this.source,
      externalId: externalId ?? this.externalId,
      recurrence: recurrence ?? this.recurrence,
      status: status ?? this.status,
      color: color ?? this.color,
      type: type ?? this.type,
      parentId: parentId ?? this.parentId,
      parentTitle: parentTitle ?? this.parentTitle,
      sourceFile: sourceFile ?? this.sourceFile,
      sourceFormat: sourceFormat ?? this.sourceFormat,
      sourceStatus: sourceStatus ?? this.sourceStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
