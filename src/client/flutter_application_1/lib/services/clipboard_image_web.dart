// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use, avoid_dynamic_calls

import 'dart:html' as html;
import 'dart:typed_data';

void Function(List<int> bytes, String fileName)? _handler;
html.EventListener? _listener;

void registerPasteHandler(void Function(List<int> bytes, String fileName) onPaste) {
  _handler = onPaste;
  _listener = (html.Event e) {
    try {
      final de = e as dynamic;
      final data = de.clipboardData;
      if (data == null) return;
      final items = data.items;
      if (items == null || items.length == 0) return;

      for (var i = 0; i < items.length; i++) {
        final item = items.item(i);
        if (item == null) continue;
        final type = item.type;
        if (type != null && type is String && type.startsWith('image/')) {
          e.preventDefault();
          final blob = item.getAsFile();
          if (blob == null) continue;
          final reader = html.FileReader();
          reader.readAsArrayBuffer(blob);
          reader.onLoad.first.then((_) {
            final result = reader.result;
            if (result is ByteBuffer && _handler != null) {
              _handler!(Uint8List.view(result), blob.name);
            }
          });
          break;
        }
      }
    } catch (_) {
      // Silently ignore paste events we can't handle
    }
  };
  html.document.addEventListener('paste', _listener);
}

void unregisterPasteHandler() {
  if (_listener != null) {
    html.document.removeEventListener('paste', _listener);
    _listener = null;
  }
  _handler = null;
}
