/// 消息附件文件的数据模型
class AttachedFile {
  final String fileName;
  final String fileUrl; // 服务端上传后的 URL，如 /uploads/xxx.png
  final String? fileType; // MIME 类型

  const AttachedFile({
    required this.fileName,
    required this.fileUrl,
    this.fileType,
  });

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'url': fileUrl,
        if (fileType != null) 'type': fileType,
      };
}
