// ignore_for_file: avoid_web_libraries_in_flutter, avoid_dynamic_calls

import 'dart:html' as html;

/// Web 端：通过 window.showDirectoryPicker() 打开系统原生目录选择器。
///
/// 注意：浏览器的 File System Access API 出于安全限制，不返回目录的完整文件系统路径，
/// 只返回目录名称。选中后目录名会填入输入框供用户参考/修正。
Future<String?> pickDirectory() async {
  try {
    final window = html.window;
    // showDirectoryPicker 未包含在 dart:html 的类型定义中，通过 dynamic 调用
    final promise = (window as dynamic).showDirectoryPicker();
    final handle = await (promise as Future<dynamic>);
    // FileSystemDirectoryHandle.name 只返回目录名，不是完整路径
    return handle.name as String?;
  } catch (_) {
    return null;
  }
}
