/// 资产条目（文档库）数据模型 — 不可变，copyWith 更新
class VaultAsset {
  final String id;
  final String title;
  final String content;
  final String? summary;     // LLM 摘要
  final String? rawContent;  // 完整 .md 原文
  final String? parentId;    // 母节点 ID（子节点时非空）
  final String? sourceFile;
  final String? sourceFormat;
  final String? sourceStatus;
  final Map<String, int>? childrenCount; // {"todos": N, "schedules": M}
  final List<String> tags;
  final bool pinned;
  final String createdAt;
  final String updatedAt;

  const VaultAsset({
    required this.id,
    required this.title,
    required this.content,
    this.summary,
    this.rawContent,
    this.parentId,
    this.sourceFile,
    this.sourceFormat,
    this.sourceStatus,
    this.childrenCount,
    this.tags = const [],
    this.pinned = false,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isFromLLM => sourceFile != null && sourceFile!.isNotEmpty;
  bool get hasChildren {
    if (childrenCount == null) return false;
    return (childrenCount!['todos'] ?? 0) + (childrenCount!['schedules'] ?? 0) > 0;
  }

  factory VaultAsset.fromJson(Map<String, dynamic> json) {
    Map<String, int>? cc;
    if (json['children_count'] is Map) {
      cc = {
        'todos': (json['children_count']['todos'] as num?)?.toInt() ?? 0,
        'schedules': (json['children_count']['schedules'] as num?)?.toInt() ?? 0,
      };
    }
    return VaultAsset(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      summary: json['summary'] as String?,
      rawContent: json['raw_content'] as String?,
      parentId: json['parent_id'] as String?,
      sourceFile: json['source_file'] as String?,
      sourceFormat: json['source_format'] as String?,
      sourceStatus: json['source_status'] as String?,
      childrenCount: cc,
      tags: (json['tags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      pinned: json['pinned'] as bool? ?? false,
      createdAt: json['created_at'] as String? ?? '',
      updatedAt: json['updated_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'content': content,
        'tags': tags,
      };

  VaultAsset copyWith({
    String? id,
    String? title,
    String? content,
    String? summary,
    String? rawContent,
    String? parentId,
    String? sourceFile,
    String? sourceFormat,
    String? sourceStatus,
    Map<String, int>? childrenCount,
    List<String>? tags,
    bool? pinned,
    String? createdAt,
    String? updatedAt,
  }) {
    return VaultAsset(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      summary: summary ?? this.summary,
      rawContent: rawContent ?? this.rawContent,
      parentId: parentId ?? this.parentId,
      sourceFile: sourceFile ?? this.sourceFile,
      sourceFormat: sourceFormat ?? this.sourceFormat,
      sourceStatus: sourceStatus ?? this.sourceStatus,
      childrenCount: childrenCount ?? this.childrenCount,
      tags: tags ?? this.tags,
      pinned: pinned ?? this.pinned,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  String get preview {
    if (content.isEmpty && (summary == null || summary!.isEmpty)) return '';
    if (summary != null && summary!.isNotEmpty) return summary!;
    var text = content;
    text = text.replaceAll(RegExp(r'!\[.*?\]\(.*?\)'), '');
    text = text.replaceAll(RegExp(r'\[(.*?)\]\(.*?\)'), r'$1');
    text = text.replaceAll('**', '');
    text = text.replaceAll('__', '');
    text = text.replaceAll('~~', '');
    text = text.replaceAll('`', '');
    text = text.replaceAll('*', '');
    text = text.replaceAll('_', '');
    text = text.replaceAll('#', '');
    text = text.replaceAll('>', '');
    text = text.replaceAll('|', ' ');
    text = text.replaceAll('-', ' ');
    text = text.replaceAll('\n', ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 80) return text;
    return '${text.substring(0, 80)}...';
  }
}
