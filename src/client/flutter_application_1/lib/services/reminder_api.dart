import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/reminder.dart';
import 'app_config.dart';

/// 提醒事项 REST API 服务
class ReminderApi {
  static final _base = '${AppConfig.serverBaseUrl}/api/reminders';

  Future<List<Reminder>> list({String? status}) async {
    try {
      final params = <String, String>{};
      if (status != null && status.isNotEmpty) params['status'] = status;
      final uri = Uri.parse(_base).replace(queryParameters: params.isNotEmpty ? params : null);
      final res = await http.get(uri);
      if (res.statusCode != 200) return [];
      final body = json.decode(res.body) as Map<String, dynamic>;
      final list = body['data'] as List<dynamic>? ?? [];
      return list.map((e) => Reminder.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Reminder>> upcoming({int days = 7}) async {
    try {
      final uri = Uri.parse('$_base/upcoming').replace(
        queryParameters: {'days': days.toString()},
      );
      final res = await http.get(uri);
      if (res.statusCode != 200) return [];
      final body = json.decode(res.body) as Map<String, dynamic>;
      final list = body['data'] as List<dynamic>? ?? [];
      return list.map((e) => Reminder.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<Reminder?> create({
    required String title,
    String? description,
    String? dueDate,
    String? priority,
  }) async {
    try {
      final uri = Uri.parse(_base);
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'title': title,
          'description': description ?? '',
          'due_date': dueDate,
          'priority': priority ?? 'medium',
        }),
      );
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return Reminder.fromJson(body['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<Reminder?> update({
    required String id,
    String? title,
    String? description,
    String? dueDate,
    String? priority,
    String? status,
  }) async {
    try {
      final uri = Uri.parse('$_base/$id');
      final res = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          if (title != null) 'title': title,
          if (description != null) 'description': description,
          if (dueDate != null) 'due_date': dueDate,
          if (priority != null) 'priority': priority,
          if (status != null) 'status': status,
        }),
      );
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return Reminder.fromJson(body['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<bool> complete(String id) async {
    try {
      final uri = Uri.parse('$_base/$id/complete');
      final res = await http.put(uri);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> delete(String id) async {
    try {
      final uri = Uri.parse('$_base/$id');
      final res = await http.delete(uri);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 在系统文件管理器中打开节点的源文件
  static Future<String?> openSourceFile(String nodeId) async {
    try {
      final uri = Uri.parse('${AppConfig.serverBaseUrl}/api/nodes/$nodeId/open-source');
      final res = await http.post(uri);
      if (res.statusCode == 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return body['error'] as String?;
    } catch (_) {
      return '无法连接服务器';
    }
  }

  /// 重新分类节点
  static Future<String?> reclassify(String nodeId, String category) async {
    try {
      final uri = Uri.parse('${AppConfig.serverBaseUrl}/api/nodes/$nodeId/category');
      final res = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'category': category}),
      );
      if (res.statusCode == 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return body['error'] as String? ?? '重新分类失败';
    } catch (_) {
      return '无法连接服务器';
    }
  }
}
