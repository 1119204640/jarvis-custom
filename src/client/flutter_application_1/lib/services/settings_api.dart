import 'dart:convert';
import 'package:http/http.dart' as http;
import 'app_config.dart';

/// 设置 REST API 服务 — 文件管理目录配置、监控状态
class SettingsApi {
  static final _base = '${AppConfig.serverBaseUrl}/api/settings';
  static final _filesBase = '${AppConfig.serverBaseUrl}/api/files';

  /// 设置文件管理目录路径
  Future<Map<String, dynamic>> setWatchDir(String path) async {
    try {
      final uri = Uri.parse('$_base/watch-dir');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'path': path}),
      );
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        return {'error': body['error'] ?? '设置失败 (${res.statusCode})'};
      }
      return body['data'] as Map<String, dynamic>? ?? {};
    } catch (e) {
      return {'error': '无法连接服务器，请检查服务器是否运行 (localhost:8000)'};
    }
  }

  /// 获取当前文件管理目录和监控状态
  Future<Map<String, dynamic>?> getWatchDir() async {
    try {
      final uri = Uri.parse('$_base/watch-dir');
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return body['data'] as Map<String, dynamic>?;
    } catch (e) {
      return null;
    }
  }

  /// 获取所有 TaskType 的模型配置及模型元数据
  Future<Map<String, dynamic>?> getProfiles() async {
    try {
      final uri = Uri.parse('$_base/profiles');
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return body['data'] as Map<String, dynamic>?;
    } catch (e) {
      return null;
    }
  }

  /// 更新某个 TaskType 的模型配置
  Future<Map<String, dynamic>> updateProfile(
    String taskType, {
    String? model,
    bool? thinkingEnabled,
    String? thinkingEffort,
    double? temperature,
  }) async {
    try {
      final uri = Uri.parse('$_base/profiles/$taskType');
      final payload = <String, dynamic>{};
      if (model != null) payload['model'] = model;
      if (thinkingEnabled != null) payload['thinking_enabled'] = thinkingEnabled;
      if (thinkingEffort != null) payload['thinking_effort'] = thinkingEffort;
      if (temperature != null) payload['temperature'] = temperature;

      final res = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      );
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        return {'error': body['error'] ?? '更新失败 (${res.statusCode})'};
      }
      final result = (body['data'] as Map<String, dynamic>?) ?? {};
      if (body.containsKey('warnings')) {
        result['warnings'] = body['warnings'];
      }
      return result;
    } catch (e) {
      return {'error': '无法连接服务器，请检查服务器是否运行 (localhost:8000)'};
    }
  }

  /// 手动触发扫描文件管理目录
  Future<Map<String, dynamic>> scanFiles() async {
    try {
      final uri = Uri.parse('$_filesBase/scan');
      final res = await http.post(uri);
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        return {'error': body['error'] ?? '扫描失败 (${res.statusCode})'};
      }
      return body['data'] as Map<String, dynamic>? ?? {};
    } catch (e) {
      return {'error': '无法连接服务器，请检查服务器是否运行 (localhost:8000)'};
    }
  }

  /// 获取文件监控状态
  Future<Map<String, dynamic>?> watcherStatus() async {
    try {
      final uri = Uri.parse('$_filesBase/watcher-status');
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return body['data'] as Map<String, dynamic>?;
    } catch (e) {
      return null;
    }
  }

  /// 获取当前 LLM 连接配置（base_url，不包含 key）
  Future<Map<String, dynamic>?> getLlmConfig() async {
    try {
      final uri = Uri.parse('$_base/llm');
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return body['data'] as Map<String, dynamic>?;
    } catch (e) {
      return null;
    }
  }

  /// 获取单个模型的 api_key 和 api_base（用于切换模型时自动填充）
  Future<Map<String, dynamic>?> getModelCredentials(String modelKey) async {
    try {
      final uri = Uri.parse('$_base/models/$modelKey');
      final res = await http.get(uri);
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) return null;
      return body['data'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// 更新 LLM 连接配置（api_key + base_url）
  Future<Map<String, dynamic>> setLlmConfig({
    required String apiKey,
    required String baseUrl,
  }) async {
    try {
      final uri = Uri.parse('$_base/llm');
      final res = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'api_key': apiKey, 'base_url': baseUrl}),
      );
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        return {'error': body['error'] ?? '配置失败 (${res.statusCode})'};
      }
      return body['data'] as Map<String, dynamic>? ?? {};
    } catch (e) {
      return {'error': '无法连接服务器，请检查服务器是否运行 (localhost:8000)'};
    }
  }

  /// 测试 LLM 连接连通性（测试通过后自动加入可用 LLM 池）
  Future<Map<String, dynamic>> testLlmConnection({
    required String apiKey,
    required String baseUrl,
  }) async {
    try {
      final uri = Uri.parse('$_base/llm/test');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'api_key': apiKey, 'base_url': baseUrl}),
      );
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200) {
        return body['data'] as Map<String, dynamic>? ?? {};
      }
      return {
        'error': body['error'] ?? '测试失败 (${res.statusCode})',
        'success': false,
      };
    } catch (e) {
      return {'error': '无法连接服务器，请检查服务器是否运行 (localhost:8000)'};
    }
  }

  /// 从可用 LLM 池中移除一个提供商
  Future<Map<String, dynamic>> removeLlmProvider(String host) async {
    try {
      final uri = Uri.parse('$_base/llm');
      final res = await http.delete(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'host': host}),
      );
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        return {'error': body['error'] ?? '移除失败 (${res.statusCode})'};
      }
      return body['data'] as Map<String, dynamic>? ?? {};
    } catch (e) {
      return {'error': '无法连接服务器，请检查服务器是否运行 (localhost:8000)'};
    }
  }
}
