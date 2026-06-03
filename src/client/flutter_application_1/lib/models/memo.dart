/// 备忘录数据模型 — 不可变，copyWith 更新
class Memo {
  final String id;
  final String title;
  final String content;
  final String? summary;     // LLM 一句话概括（有值 = LLM 生成）
  final String? rawContent;  // 完整 .md 原文，仅 get_memo 返回
  final String? sourceFile;  // 来源文件路径
  final String? sourceFormat;
  final String? sourceStatus; // native / linked / source_deleted / association_lost
  final List<String> tags;
  final bool pinned;
  final String createdAt;
  final String updatedAt;

  const Memo({
    required this.id,
    required this.title,
    required this.content,
    this.summary,
    this.rawContent,
    this.sourceFile,
    this.sourceFormat,
    this.sourceStatus,
    this.tags = const [],
    this.pinned = false,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isFromLLM => sourceFile != null && sourceFile!.isNotEmpty;

  factory Memo.fromJson(Map<String, dynamic> json) {
    return Memo(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      summary: json['summary'] as String?,
      rawContent: json['raw_content'] as String?,
      sourceFile: json['source_file'] as String?,
      sourceFormat: json['source_format'] as String?,
      sourceStatus: json['source_status'] as String?,
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

  Memo copyWith({
    String? id,
    String? title,
    String? content,
    String? summary,
    String? rawContent,
    String? sourceFile,
    String? sourceFormat,
    String? sourceStatus,
    List<String>? tags,
    bool? pinned,
    String? createdAt,
    String? updatedAt,
  }) {
    return Memo(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      summary: summary ?? this.summary,
      rawContent: rawContent ?? this.rawContent,
      sourceFile: sourceFile ?? this.sourceFile,
      sourceFormat: sourceFormat ?? this.sourceFormat,
      sourceStatus: sourceStatus ?? this.sourceStatus,
      tags: tags ?? this.tags,
      pinned: pinned ?? this.pinned,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 正文预览（用于列表卡片，最多显示约两行）。
  /// LLM 生成的备忘录使用 summary 作为预览，用户创建的去除 Markdown 标记。
  String get preview {
    if (content.isEmpty && (summary == null || summary!.isEmpty)) return '';

    // LLM 生成的：直接用 summary
    if (summary != null && summary!.isNotEmpty) return summary!;

    // 用户创建的：去除 Markdown 标记
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
