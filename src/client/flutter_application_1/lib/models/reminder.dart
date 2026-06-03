/// 提醒事项数据模型 — 不可变，copyWith 更新
class Reminder {
  final String id;
  final String title;
  final String description;
  final String? dueDate;
  final String priority; // low / medium / high
  final String status; // pending / completed
  final String? sourceFile;
  final String? sourceFormat;
  final String? sourceStatus; // native / linked / source_deleted / association_lost
  final String createdAt;
  final String updatedAt;

  const Reminder({
    required this.id,
    required this.title,
    this.description = '',
    this.dueDate,
    this.priority = 'medium',
    this.status = 'pending',
    this.sourceFile,
    this.sourceFormat,
    this.sourceStatus,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Reminder.fromJson(Map<String, dynamic> json) {
    return Reminder(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      dueDate: json['due_date'] as String?,
      priority: json['priority'] as String? ?? 'medium',
      status: json['status'] as String? ?? 'pending',
      sourceFile: json['source_file'] as String?,
      sourceFormat: json['source_format'] as String?,
      sourceStatus: json['source_status'] as String?,
      createdAt: json['created_at'] as String? ?? '',
      updatedAt: json['updated_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'due_date': dueDate,
        'priority': priority,
        'status': status,
      };

  Reminder copyWith({
    String? id,
    String? title,
    String? description,
    String? dueDate,
    String? priority,
    String? status,
    String? sourceFile,
    String? sourceFormat,
    String? sourceStatus,
    String? createdAt,
    String? updatedAt,
  }) {
    return Reminder(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      dueDate: dueDate ?? this.dueDate,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      sourceFile: sourceFile ?? this.sourceFile,
      sourceFormat: sourceFormat ?? this.sourceFormat,
      sourceStatus: sourceStatus ?? this.sourceStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  bool get isCompleted => status == 'completed';
  bool get isPending => status == 'pending';
}
