import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 消息发送回调 — 文本 + 待上传的附件路径列表
typedef MessageSendCallback = void Function(String text, List<File> attachments);

/// 消息输入区域
///
/// 包含文本输入框、附件按钮和发送按钮。回车发送，Shift+回车换行。
/// 支持从相册拍照、选择图片、选择文件作为附件。
class MessageInput extends StatefulWidget {
  final MessageSendCallback onSend;
  final bool enabled;

  const MessageInput({
    super.key,
    required this.onSend,
    this.enabled = true,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _imagePicker = ImagePicker();
  final List<File> _attachments = [];

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    widget.onSend(text, List.from(_attachments));
    _controller.clear();
    setState(() => _attachments.clear());
  }

  Future<void> _pickImage(ImageSource source) async {
    final xfile = await _imagePicker.pickImage(source: source, imageQuality: 85);
    if (xfile != null && mounted) {
      setState(() => _attachments.add(File(xfile.path)));
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null && result.paths.isNotEmpty && mounted) {
      setState(() {
        for (final path in result.paths) {
          if (path != null) _attachments.add(File(path));
        }
      });
    }
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择图片'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('选择文件'),
              subtitle: const Text('PDF、Office 文档、文本文件等'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFiles();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 附件预览 chips
          if (_attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: List.generate(_attachments.length, (i) {
                  final file = _attachments[i];
                  final name = file.path.split('/').last;
                  return Chip(
                    label: Text(
                      name,
                      style: const TextStyle(fontSize: 12),
                    ),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () {
                      setState(() => _attachments.removeAt(i));
                    },
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                }),
              ),
            ),

          // 输入行
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 附件按钮
              IconButton(
                onPressed: widget.enabled ? _showAttachmentSheet : null,
                icon: const Icon(Icons.attach_file),
                tooltip: '添加附件',
                visualDensity: VisualDensity.compact,
              ),

              // 文本输入框
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  enabled: widget.enabled,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: '输入消息...',
                    hintStyle: TextStyle(fontSize: 13, color: Color(0x8A000000)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                      borderSide: BorderSide(width: 0.5, color: Color(0x61000000)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                      borderSide: BorderSide(width: 0.5, color: Color(0x61000000)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                      borderSide: BorderSide(width: 0.5),
                    ),
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _send(),
                  textInputAction: TextInputAction.send,
                ),
              ),
              const SizedBox(width: 8),
              // 发送按钮
              IconButton.filled(
                onPressed: widget.enabled ? _send : null,
                icon: const Icon(Icons.send),
                tooltip: '发送',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
