import 'package:file_picker/file_picker.dart';

/// 桌面端：通过 file_picker 包调用系统原生目录选择器，返回完整文件系统路径。
Future<String?> pickDirectory() async {
  return FilePicker.platform.getDirectoryPath();
}
