import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/asset.dart';
import 'app_config.dart';

/// 文档库 REST API 服务
class VaultApi {
  static final _base = '${AppConfig.serverBaseUrl}/api/assets';
  static final _uploadUrl = '${AppConfig.serverBaseUrl}/api/upload';

  /// Upload an image and return its URL path.
  static Future<String?> uploadImage(String filePath, {List<int>? bytes, String? fileName}) async {
    try {
      final uri = Uri.parse(_uploadUrl);
      final request = http.MultipartRequest('POST', uri);
      if (bytes != null) {
        request.files.add(http.MultipartFile.fromBytes(
          'file', bytes,
          filename: fileName ?? 'image.png',
        ));
      } else {
        request.files.add(await http.MultipartFile.fromPath('file', filePath));
      }
      final streamed = await request.send();
      if (streamed.statusCode != 200) return null;
      final body = json.decode(await streamed.stream.bytesToString());
      return body['data']['url'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<VaultAsset?> get(String id) async {
    try {
      final uri = Uri.parse('$_base/$id');
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return VaultAsset.fromJson(body['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<List<VaultAsset>> list({String? tag, String? query}) async {
    try {
      final params = <String, String>{};
      if (tag != null && tag.isNotEmpty) params['tag'] = tag;
      if (query != null && query.isNotEmpty) params['q'] = query;
      final uri = Uri.parse(_base).replace(queryParameters: params.isNotEmpty ? params : null);
      final res = await http.get(uri);
      if (res.statusCode != 200) return [];
      final body = json.decode(res.body) as Map<String, dynamic>;
      final list = body['data'] as List<dynamic>? ?? [];
      return list.map((e) => VaultAsset.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 获取某资产的所有子节点（待办 + 日程）
  Future<Map<String, List<dynamic>>> getChildren(String parentId) async {
    try {
      final uri = Uri.parse('$_base/$parentId/children');
      final res = await http.get(uri);
      if (res.statusCode != 200) return {};
      final body = json.decode(res.body) as Map<String, dynamic>;
      final data = body['data'] as Map<String, dynamic>? ?? {};
      return {
        'todos': data['todos'] as List<dynamic>? ?? [],
        'schedules': data['schedules'] as List<dynamic>? ?? [],
      };
    } catch (_) {
      return {};
    }
  }

  Future<VaultAsset?> create({
    String title = '',
    String content = '',
    List<String>? tags,
    bool processAsync = false,
  }) async {
    try {
      final uri = Uri.parse(_base);
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'title': title,
          'content': content,
          'tags': tags ?? [],
          'process_async': processAsync,
        }),
      );
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return VaultAsset.fromJson(body['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<VaultAsset?> update({
    required String id,
    String? title,
    String? content,
    List<String>? tags,
  }) async {
    try {
      final uri = Uri.parse('$_base/$id');
      final res = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          if (title != null) 'title': title,
          if (content != null) 'content': content,
          if (tags != null) 'tags': tags,
        }),
      );
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      return VaultAsset.fromJson(body['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<bool> togglePin(String id, bool pinned) async {
    try {
      final endpoint = pinned ? 'pin' : 'unpin';
      final uri = Uri.parse('$_base/$id/$endpoint');
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

  /// 重新分类节点（asset / todo / schedule (plan) / schedule (record)）
  /// 返回错误消息，成功时返回 null
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
