/// 待办事项数据模型 — 不可变，copyWith 更新
class TodoItem {
  final String id;
  final String title;
  final String description;
  final String? dueDate;
  final String priority; // low / medium / high
  final String status; // pending / completed
  final String? parentId; // 母节点 ID（由文档库资产派生时非空）
  final String? parentTitle; // 母节点标题
  final String? sourceFile;
  final String? sourceFormat;
  final String? sourceStatus; // native / linked / source_deleted / association_lost
  final String createdAt;
  final String updatedAt;

  const TodoItem({
    required this.id,
    required this.title,
    this.description = '',
    this.dueDate,
    this.priority = 'medium',
    this.status = 'pending',
    this.parentId,
    this.parentTitle,
    this.sourceFile,
    this.sourceFormat,
    this.sourceStatus,
    required this.createdAt,
    required this.updatedAt,
  });

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    return TodoItem(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      dueDate: json['due_date'] as String?,
      priority: json['priority'] as String? ?? 'medium',
      status: json['status'] as String? ?? 'pending',
      parentId: json['parent_id'] as String?,
      parentTitle: json['parent_title'] as String?,
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

  TodoItem copyWith({
    String? id,
    String? title,
    String? description,
    String? dueDate,
    String? priority,
    String? status,
    String? parentId,
    String? parentTitle,
    String? sourceFile,
    String? sourceFormat,
    String? sourceStatus,
    String? createdAt,
    String? updatedAt,
  }) {
    return TodoItem(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      dueDate: dueDate ?? this.dueDate,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      parentId: parentId ?? this.parentId,
      parentTitle: parentTitle ?? this.parentTitle,
      sourceFile: sourceFile ?? this.sourceFile,
      sourceFormat: sourceFormat ?? this.sourceFormat,
      sourceStatus: sourceStatus ?? this.sourceStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  bool get isCompleted => status == 'completed';
  bool get isPending => status == 'pending';
  bool get hasParent => parentId != null && parentId!.isNotEmpty;
}
