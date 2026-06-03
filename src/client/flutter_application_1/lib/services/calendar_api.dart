import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/event.dart';
import 'app_config.dart';

/// 日程 REST API 服务
class CalendarApi {
  static final _base = '${AppConfig.serverBaseUrl}/api/events';

  /// 按时间范围获取日程列表
  Future<List<CalendarEvent>> fetchEvents(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final params = {
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
      };
      final uri = Uri.parse(_base).replace(queryParameters: params);
      final res = await http.get(uri);
      if (res.statusCode != 200) return [];
      final body = json.decode(res.body) as Map<String, dynamic>;
      final list = body['data'] as List<dynamic>? ?? [];
      return list
          .map((e) => CalendarEvent.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 创建日程（本地或 Google）
  Future<CalendarEvent?> create({
    required String title,
    required DateTime startTime,
    required DateTime endTime,
    String description = '',
    bool isAllDay = false,
    String? color,
    String type = 'plan',
    String source = 'local',
  }) async {
    try {
      final uri = Uri.parse(_base);
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'title': title,
          'description': description,
          'start_time': startTime.toIso8601String(),
          'end_time': endTime.toIso8601String(),
          'is_all_day': isAllDay,
          'type': type,
          'source': source,
          if (color != null) 'color': color,
        }),
      );
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return CalendarEvent.fromJson(body['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 更新日程
  Future<CalendarEvent?> update({
    required String id,
    String? title,
    String? description,
    DateTime? startTime,
    DateTime? endTime,
    bool? isAllDay,
    String? color,
    String? type,
    String? source,
  }) async {
    try {
      final uri = Uri.parse('$_base/$id');
      final res = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          if (title != null) 'title': title,
          if (description != null) 'description': description,
          if (startTime != null) 'start_time': startTime.toIso8601String(),
          if (endTime != null) 'end_time': endTime.toIso8601String(),
          if (isAllDay != null) 'is_all_day': isAllDay,
          if (color != null) 'color': color,
          if (type != null) 'type': type,
          if (source != null) 'source': source,
        }),
      );
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return CalendarEvent.fromJson(body['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 删除日程
  Future<bool> delete(String id) async {
    try {
      final uri = Uri.parse('$_base/$id');
      final res = await http.delete(uri);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 触发 Google Calendar 同步
  Future<Map<String, dynamic>> triggerSync() async {
    try {
      final uri = Uri.parse('$_base/sync');
      final res = await http.post(uri);
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        return {'error': body['error'] ?? '同步失败 (${res.statusCode})'};
      }
      return body['data'] as Map<String, dynamic>? ?? {};
    } catch (_) {
      return {'error': '无法连接服务器，请检查服务器是否运行 (localhost:8000)'};
    }
  }

  /// 检查 Google OAuth 连接状态
  Future<Map<String, dynamic>?> checkOAuthStatus() async {
    try {
      final uri = Uri.parse('$_base/google/oauth/status');
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return body['data'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
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

  /// 获取 Google OAuth 授权 URL
  /// 返回 `{'auth_url': '...'}` 成功，`{'error': '...'}` 失败
  Future<Map<String, dynamic>> getAuthUrl() async {
    try {
      final uri = Uri.parse('$_base/google/auth-url');
      final res = await http.get(uri);
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        return {'error': body['error'] ?? '获取授权链接失败 (${res.statusCode})'};
      }
      return body['data'] as Map<String, dynamic>? ?? {};
    } catch (_) {
      return {'error': '无法连接服务器，请检查服务器是否运行 (localhost:8000)'};
    }
  }
}
