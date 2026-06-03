import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/settings_api.dart';
import '../services/directory_picker_io.dart'
    if (dart.library.html) '../services/directory_picker_web.dart';

// ---------------------------------------------------------------------------
// Data helpers
// ---------------------------------------------------------------------------

/// Human-readable labels for TaskType enum values.
const _taskTypeLabels = {
  'TEXT': '文本处理',
  'MULTIMODAL': '多模态处理',
};

const _taskTypeDescs = {
  'TEXT': '纯文本文件分类摘要、日常对话。文本模型即可，成本低。',
  'MULTIMODAL': '图片/PDF/Office 视觉理解、Agent 复杂推理。需要多模态模型，兼具文本分析能力。',
};

// Local storage keys
const _keyLlmProviders = 'llm_providers'; // JSON list of {host, base_url, api_key}

// ---------------------------------------------------------------------------
// SettingsScreen
// ---------------------------------------------------------------------------

/// 设置页面 — LLM 提供商池、任务模型分配、文件管理目录、监控状态
class SettingsScreen extends StatefulWidget {
  final VoidCallback? onBack;

  const SettingsScreen({super.key, this.onBack});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsApi _api = SettingsApi();

  // ---- LLM provider pool ----
  String _selectedModel = '';
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  bool _keyVisible = false;
  bool _testingLlm = false;
  bool _showAddForm = false;
  String? _llmStatusMessage;

  // Providers from server (host → {base_url, models})
  List<Map<String, dynamic>> _availableProviders = [];

  // ---- file management ----
  final _pathCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _watchDir;
  bool _watching = false;
  String? _statusMessage;

  // ---- multimodal availability (from server) ----
  bool _multimodalAvailable = true;

  // ---- model profiles ----
  Map<String, dynamic> _profiles = {};
  Map<String, dynamic> _models = {};
  bool _loadingProfiles = true;
  final Set<String> _savingProfiles = {};
  String? _expandedTaskType;

  // ---- from server ----
  Set<String> _verifiedModels = {};
  Map<String, List<String>> _profileWarnings = {};

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    await _loadProfiles();
    await _loadLlmConfig();
    await _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // LLM provider pool — local storage + server sync
  // -----------------------------------------------------------------------

  Future<void> _loadLlmConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getString(_keyLlmProviders);
    List<dynamic> savedProviders = [];
    if (savedJson != null && savedJson.isNotEmpty) {
      try {
        savedProviders = json.decode(savedJson) as List<dynamic>;
      } catch (_) {}
    }

    // Sync all saved providers to server
    for (final p in savedProviders) {
      if (p is Map) {
        final key = p['api_key'] as String? ?? '';
        final url = p['base_url'] as String? ?? '';
        if (key.isNotEmpty && url.isNotEmpty) {
          await _api.setLlmConfig(apiKey: key, baseUrl: url);
        }
      }
    }

    // Restore last-used model + URL from the first saved provider
    if (savedProviders.isNotEmpty) {
      final first = savedProviders.first as Map;
      final url = first['base_url'] as String? ?? '';
      final key = first['api_key'] as String? ?? '';
      // Find a model matching the saved base URL
      String matchedModel = '';
      for (final entry in _models.entries) {
        final meta = entry.value as Map<String, dynamic>;
        if (meta['api_base'] == url) {
          matchedModel = entry.key;
          break;
        }
      }
      setState(() {
        _urlCtrl.text = url;
        _keyCtrl.text = key;
        _selectedModel = matchedModel;
      });
    } else {
      final serverModel = _profiles['TEXT']?['model'] as String?;
      final firstModel = _models.isNotEmpty ? _models.keys.first : '';
      setState(() {
        _selectedModel = serverModel ?? firstModel;
      });
    }

    // Refresh to get the updated provider pool from server
    _loadProfiles();
  }

  /// Save all current providers to local storage.
  Future<void> _saveProvidersToLocal() async {
    final prefs = await SharedPreferences.getInstance();

    // Merge with already-saved providers (keep their keys)
    final savedJson = prefs.getString(_keyLlmProviders);
    List<dynamic> existing = [];
    if (savedJson != null && savedJson.isNotEmpty) {
      try {
        existing = json.decode(savedJson) as List<dynamic>;
      } catch (_) {}
    }

    // Update or add the current provider
    final currentHost = Uri.tryParse(_urlCtrl.text.trim())?.host ?? '';
    final currentKey = _keyCtrl.text.trim();
    if (currentHost.isNotEmpty && currentKey.isNotEmpty) {
      bool found = false;
      for (int i = 0; i < existing.length; i++) {
        if (existing[i] is Map && existing[i]['host'] == currentHost) {
          existing[i] = {
            'host': currentHost,
            'base_url': _urlCtrl.text.trim(),
            'api_key': currentKey,
          };
          found = true;
          break;
        }
      }
      if (!found) {
        existing.add({
          'host': currentHost,
          'base_url': _urlCtrl.text.trim(),
          'api_key': currentKey,
        });
      }
    }

    await prefs.setString(_keyLlmProviders, json.encode(existing));
  }

  /// Remove a saved provider from local storage.
  Future<void> _removeProviderFromLocal(String host) async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getString(_keyLlmProviders);
    if (savedJson == null || savedJson.isEmpty) return;
    try {
      List<dynamic> existing = json.decode(savedJson) as List<dynamic>;
      existing.removeWhere((e) => e is Map && e['host'] == host);
      await prefs.setString(_keyLlmProviders, json.encode(existing));
    } catch (_) {}
  }

  void _showLlmMessage(String msg) {
    setState(() => _llmStatusMessage = msg);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _llmStatusMessage = null);
    });
  }

  Future<void> _testLlmConnection() async {
    final url = _urlCtrl.text.trim();
    final key = _keyCtrl.text.trim();

    if (url.isEmpty) {
      _showLlmMessage('请输入 API 地址');
      return;
    }
    if (key.isEmpty) {
      _showLlmMessage('请输入 API Key');
      return;
    }

    setState(() => _testingLlm = true);

    final result = await _api.testLlmConnection(apiKey: key, baseUrl: url);

    if (!mounted) return;
    setState(() => _testingLlm = false);

    if (result.containsKey('error')) {
      _showLlmMessage('测试失败: ${result['error']}');
    } else {
      final verified = (result['verified_models'] as List<dynamic>?) ?? [];
      final msg = result['message'] as String? ?? '连接成功';
      _showLlmMessage(msg);
      setState(() {
        _verifiedModels = verified.map((e) => e.toString()).toSet();
      });
      // Save to local storage
      await _saveProvidersToLocal();
      // Refresh profiles to get updated provider pool
      _loadProfiles();
    }
  }

  Future<void> _removeProvider(String host) async {
    final result = await _api.removeLlmProvider(host);
    if (result.containsKey('error')) {
      _showLlmMessage('移除失败: ${result['error']}');
    } else {
      _showLlmMessage('已移除 $host');
      await _removeProviderFromLocal(host);
      _loadProfiles();
    }
  }

  void _onModelChanged(String model) async {
    setState(() => _selectedModel = model);

    // Auto-fill URL from model metadata
    final meta = _models[model] as Map<String, dynamic>?;
    if (meta != null) {
      final apiBase = meta['api_base'] as String? ?? '';
      if (apiBase.isNotEmpty) {
        _urlCtrl.text = apiBase;
      }
    }

    // Fetch model-specific API key from server
    final creds = await _api.getModelCredentials(model);
    if (creds != null && mounted) {
      _keyCtrl.text = creds['api_key'] as String? ?? '';
    }
  }

  // -----------------------------------------------------------------------
  // File management
  // -----------------------------------------------------------------------

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _api.getWatchDir();
      if (!mounted) return;
      if (data != null) {
        _watchDir = data['watch_dir'] as String?;
        _watching = data['watching'] as bool? ?? false;
        if (_watchDir != null) _pathCtrl.text = _watchDir!;
      }
    } catch (_) {
      // Network error — server may not be running
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveWatchDir() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) {
      _showMessage('请输入有效的目录路径');
      return;
    }
    setState(() => _saving = true);
    final result = await _api.setWatchDir(path);
    if (!mounted) return;
    if (result.containsKey('error')) {
      _showMessage(result['error'] as String);
    } else {
      _watchDir = result['watch_dir'] as String?;
      _watching = result['watching'] as bool? ?? false;
      final warnings = result['warnings'] as List<dynamic>?;
      if (warnings != null && warnings.isNotEmpty) {
        _showMessage(warnings.first.toString());
      } else {
        _showMessage('文件管理目录已更新，监控已启动');
      }
    }
    setState(() => _saving = false);
  }

  Future<void> _scanFiles() async {
    if (_watchDir == null) {
      _showMessage('请先设置文件管理目录');
      return;
    }
    setState(() => _saving = true);
    final result = await _api.scanFiles();
    if (!mounted) return;
    if (result.containsKey('error')) {
      _showMessage(result['error'] as String);
    } else {
      final scanned = result['scanned'] ?? 0;
      _showMessage('已扫描 $scanned 个文件');
    }
    setState(() => _saving = false);
  }

  void _showMessage(String msg) {
    setState(() => _statusMessage = msg);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _statusMessage = null);
    });
  }

  // -----------------------------------------------------------------------
  // Model profiles
  // -----------------------------------------------------------------------

  Future<void> _loadProfiles() async {
    try {
      final data = await _api.getProfiles();
      if (!mounted) return;
      if (data != null) {
        setState(() {
          _profiles = (data['profiles'] as Map<String, dynamic>?) ?? {};
          _models = (data['models'] as Map<String, dynamic>?) ?? {};
          _verifiedModels = ((data['verified_models'] as List<dynamic>?) ?? [])
              .map((e) => e.toString())
              .toSet();
          _availableProviders = ((data['available_providers'] as List<dynamic>?) ?? [])
              .map((e) => e as Map<String, dynamic>)
              .toList();
          _profileWarnings = (data['profile_warnings'] as Map<String, dynamic>?)?.map(
                (k, v) => MapEntry(k, (v as List<dynamic>).cast<String>()),
              ) ?? {};
          final mmInfo = data['multimodal'] as Map<String, dynamic>?;
          _multimodalAvailable = mmInfo?['available'] as bool? ?? true;
          _loadingProfiles = false;
        });
      } else {
        setState(() => _loadingProfiles = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingProfiles = false);
    }
  }

  Future<void> _updateProfile(String taskType, Map<String, dynamic> updates) async {
    setState(() => _savingProfiles.add(taskType));
    final result = await _api.updateProfile(
      taskType,
      model: updates['model'] as String?,
      thinkingEnabled: updates['thinking_enabled'] as bool?,
      thinkingEffort: updates['thinking_effort'] as String?,
      temperature: updates['temperature'] as double?,
    );
    if (!mounted) return;
    setState(() => _savingProfiles.remove(taskType));
    if (result.containsKey('error')) {
      _showMessage('${_taskTypeLabels[taskType] ?? taskType}: ${result['error']}');
    } else {
      if (result.containsKey('profiles')) {
        setState(() => _profiles = (result['profiles'] as Map<String, dynamic>?) ?? {});
      }
      // Update profile warnings for this task type from the server response.
      // The warnings key may not exist (no warnings) or be an empty list.
      if (result.containsKey('warnings')) {
        final warnings = (result['warnings'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ?? [];
        setState(() => _profileWarnings[taskType] = warnings);
      } else {
        setState(() => _profileWarnings.remove(taskType));
      }
    }
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack != null
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack)
            : null,
        title: const Text('设置'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: _loading || _loadingProfiles
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ---- Multimodal unavailable warning ----
                  if (_llmConfigured && !_multimodalAvailable)
                    _buildMultimodalWarningBanner(theme),

                  _buildLlmConnectionSection(theme),
                  const SizedBox(height: 32),
                  _buildModelSection(theme),
                  const SizedBox(height: 32),
                  _buildFileSection(theme),
                  const SizedBox(height: 32),
                  _buildStatusSection(theme),
                  const SizedBox(height: 32),
                  _buildHelpSection(theme),
                ],
              ),
            ),
    );
  }

  // -----------------------------------------------------------------------
  // Multimodal unavailable banner
  // -----------------------------------------------------------------------

  Widget _buildMultimodalWarningBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.shade300, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 24, color: Colors.orange.shade700),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '多模态视觉功能未启用',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '当前「多模态处理」槽位的模型缺少 API Key 配置，'
                  '图片/PDF/Office 文件的视觉识别将不可用。\n'
                  '纯文本文件（.md/.txt/.json/.csv/.html/.docx）仍可正常处理。\n'
                  '请在「模型连接配置」中为该模型添加 API Key 并测试连接。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.orange.shade800,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Section: LLM connection — 测试后自动加入可用 LLM 池
  // -----------------------------------------------------------------------

  Widget _buildLlmConnectionSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('模型连接配置',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          '通过验证的提供商将加入可用 LLM 池，供下方各任务分配使用。凭据保存在服务器 data/credentials.yaml 中，重启后自动恢复。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 16),

        // ---- Provider pool ----
        if (_availableProviders.isNotEmpty) ...[
          _buildProviderPoolList(theme),
          const SizedBox(height: 16),
        ],

        // ---- Add form (collapsed by default) ----
        if (_showAddForm) ...[
          // ---- Model selector ----
          Text('选择模型', style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          )),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _models.containsKey(_selectedModel) ? _selectedModel : null,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              helperText: '选择模型以自动填充 API 地址和凭据',
            ),
            items: _models.entries.map((entry) {
              final meta = entry.value as Map<String, dynamic>;
              final isVerified = _verifiedModels.contains(entry.key);
              final hasCred = meta['has_credential'] as bool? ?? false;
              return DropdownMenuItem(
                value: entry.key,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      fit: FlexFit.loose,
                      child: Text(
                        meta['name'] as String? ?? entry.key,
                        style: TextStyle(
                          color: isVerified
                              ? Colors.green.shade700
                              : hasCred
                                  ? Colors.blue.shade700
                                  : Colors.grey.shade500,
                          fontWeight: isVerified ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (isVerified) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.verified, size: 14, color: Colors.green.shade600),
                    ] else if (hasCred) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.check_circle_outline, size: 14, color: Colors.blue.shade600),
                    ] else ...[
                      const SizedBox(width: 4),
                      Text('(未添加)',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                    ],
                  ],
                ),
              );
            }).toList(),
            onChanged: (val) {
              if (val != null) _onModelChanged(val);
            },
          ),

          // ---- Model info card ----
          if (_selectedModel.isNotEmpty && _models.containsKey(_selectedModel))
            _buildModelInfoCard(_selectedModel, theme),

          const SizedBox(height: 12),

          // ---- API URL ----
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'API 地址 (Base URL)',
              hintText: '',
              border: OutlineInputBorder(),
              helperText: 'OpenAI 兼容的 API 端点地址',
            ),
          ),
          const SizedBox(height: 12),

          // ---- API Key ----
          TextField(
            controller: _keyCtrl,
            obscureText: !_keyVisible,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: '',
              border: const OutlineInputBorder(),
              helperText: '密钥保存在服务器 data/credentials.yaml，重启后自动恢复',
              suffixIcon: IconButton(
                icon: Icon(_keyVisible ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _keyVisible = !_keyVisible),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ---- Action buttons ----
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testingLlm ? null : _testLlmConnection,
                icon: _testingLlm
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_find, size: 18),
                label: const Text('测试并添加'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => setState(() => _showAddForm = false),
                child: const Text('取消'),
              ),
            ],
          ),
        ] else ...[
          OutlinedButton.icon(
            onPressed: () => setState(() => _showAddForm = true),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加提供商'),
          ),
        ],

        // ---- Status messages ----
        if (_llmStatusMessage != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _llmStatusMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Show the pool of added LLM providers.
  Widget _buildProviderPoolList(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: Colors.green.shade700),
              const SizedBox(width: 8),
              Text(
                '已添加的 LLM 提供商 (${_availableProviders.length})',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.green.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._availableProviders.map((provider) {
            final host = provider['host'] as String? ?? '';
            final models = (provider['models'] as List<dynamic>?)
                    ?.map((e) => e.toString())
                    .toList() ??
                [];
            final modelNames = models
                .map((k) => (_models[k]?['name'] as String?) ?? k)
                .join('、');
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (modelNames.isNotEmpty)
                          Text(
                            modelNames,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade900,
                            ),
                          ),
                        Text(
                          host,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.green.shade700,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _removeProvider(host),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.delete_outline,
                          size: 18, color: Colors.red.shade400),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Section: model settings (per task type)
  // -----------------------------------------------------------------------

  bool get _llmConfigured => _availableProviders.isNotEmpty;

  Widget _buildModelSection(ThemeData theme) {
    final taskTypes = ['TEXT', 'MULTIMODAL'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('任务模型分配',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            if (!_llmConfigured) ...[
              const SizedBox(width: 8),
              Icon(Icons.error, size: 20, color: Colors.red.shade400),
              const SizedBox(width: 4),
              Text(
                '请先添加 LLM 提供商',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.red.shade400,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '为不同任务类型分配合适的模型和推理策略。修改立即生效，无需重启。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 16),
        ...taskTypes.map((tt) => _buildTaskCard(tt, theme)),
      ],
    );
  }

  Widget _buildTaskCard(String taskType, ThemeData theme) {
    final profile = _profiles[taskType] as Map<String, dynamic>?;
    if (profile == null) return const SizedBox.shrink();

    final currentModel = profile['model'] as String? ?? '';
    final thinkingEnabled = profile['thinking_enabled'] as bool? ?? false;
    final thinkingEffort = profile['thinking_effort'] as String? ?? 'high';
    final isSaving = _savingProfiles.contains(taskType);
    final isExpanded = _expandedTaskType == taskType;
    final credentialMatch = (profile['credential_match'] as bool?) ?? true;

    final modelMeta = _models[currentModel] as Map<String, dynamic>? ?? {};
    final supportsThinking = modelMeta['supports_thinking'] as bool? ?? true;
    final hasCredential = modelMeta['has_credential'] as bool? ?? false;

    // Capability warnings for this task
    final warnings = _profileWarnings[taskType] ?? <String>[];
    final modelName = modelMeta['name'] as String? ?? currentModel;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          // Header row — always visible
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(
                () => _expandedTaskType = isExpanded ? null : taskType),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    _taskIcon(taskType),
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _taskTypeLabels[taskType] ?? taskType,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              modelName,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: (_llmConfigured && credentialMatch)
                                    ? theme.colorScheme.primary
                                    : Colors.red.shade400,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (!_llmConfigured)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Tooltip(
                                  message: '尚未添加任何 LLM 提供商，此任务类型暂不可用',
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    size: 18,
                                    color: Colors.red.shade400,
                                  ),
                                ),
                              )
                            else if (!credentialMatch && !hasCredential)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Tooltip(
                                  message: '模型 $modelName 的提供商尚未添加到可用 LLM 池中',
                                  child: Icon(
                                    Icons.link_off,
                                    size: 18,
                                    color: Colors.red.shade400,
                                  ),
                                ),
                              )
                            else if (warnings.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Tooltip(
                                  message: warnings.join('\n'),
                                  child: Icon(
                                    Icons.info_outline,
                                    size: 18,
                                    color: Colors.orange.shade600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _taskTypeDescs[taskType] ?? '',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isSaving)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                    ),
                ],
              ),
            ),
          ),

          // Expandable details
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  const SizedBox(height: 8),

                  // ---- capability warnings ----
                  if (warnings.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  size: 18, color: Colors.orange.shade800),
                              const SizedBox(width: 8),
                              Text(
                                '能力提醒',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.orange.shade900,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ...warnings.map((w) => Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  w,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.orange.shade800,
                                  ),
                                ),
                              )),
                        ],
                      ),
                    ),

                  // ---- credential mismatch warning ----
                  if (_llmConfigured && !credentialMatch && !hasCredential)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.gpp_bad_outlined,
                              size: 18, color: Colors.red.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${modelMeta['name'] ?? currentModel} 的提供商'
                              '（${modelMeta['provider'] ?? "未知"}）尚未添加到可用 LLM 池。'
                              '请在模型连接配置中填写 API Key 并点击"测试并添加"。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.red.shade900,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ---- model selector ----
                  Text('模型选择', style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  )),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: _models.containsKey(currentModel) ? currentModel : null,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                    items: _models.entries.map((entry) {
                      final key = entry.key;
                      final meta = entry.value as Map<String, dynamic>;
                      final modelVision = meta['supports_vision'] as bool? ?? true;
                      final hasCred = meta['has_credential'] as bool? ?? false;
                      final isVerified = _verifiedModels.contains(key);
                      return DropdownMenuItem(
                        value: key,
                        enabled: hasCred,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              fit: FlexFit.loose,
                              child: Text(
                                meta['name'] as String? ?? key,
                                style: TextStyle(
                                  color: hasCred ? null : Colors.grey,
                                ),
                              ),
                            ),
                            if (taskType == 'MULTIMODAL' && !modelVision) ...[
                              const SizedBox(width: 4),
                              Tooltip(
                                message: '不支持视觉识别，将降级为 macOS 本地 OCR',
                                child: Text('(OCR降级)',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.orange.shade600)),
                              ),
                            ] else if (isVerified) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.verified, size: 14, color: Colors.green.shade600),
                            ] else if (_llmConfigured && !hasCred)
                              Text('(未添加)',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade600)),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val == null || val == currentModel) return;
                      final newMeta = _models[val] as Map<String, dynamic>? ?? {};
                      final updates = <String, dynamic>{'model': val};
                      if (!(newMeta['supports_thinking'] as bool? ?? false)) {
                        updates['thinking_enabled'] = false;
                      }
                      _updateProfile(taskType, updates);
                    },
                  ),
                  const SizedBox(height: 12),

                  // ---- thinking toggle ----
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('深度推理 (Thinking)'),
                    subtitle: Text(
                      thinkingEnabled
                          ? '已开启 — 模型会输出推理链，回答更缜密'
                          : '已关闭 — 直接输出答案，响应更快',
                      style: theme.textTheme.bodySmall,
                    ),
                    value: thinkingEnabled,
                    onChanged: supportsThinking
                        ? (val) => _updateProfile(taskType, {'thinking_enabled': val})
                        : null,
                  ),

                  // ---- effort selector (only when thinking enabled) ----
                  if (thinkingEnabled) ...[
                    const SizedBox(height: 4),
                    Text('推理强度', style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    )),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                            value: 'high',
                            label: Text('标准'),
                            tooltip: 'reasoning_effort=high，常规推理深度'),
                        ButtonSegment(
                            value: 'max',
                            label: Text('最大化'),
                            tooltip: 'reasoning_effort=max，最深推理'),
                      ],
                      selected: {thinkingEffort},
                      onSelectionChanged: (val) {
                        _updateProfile(taskType, {'thinking_effort': val.first});
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '标准(high)适合大多数任务；最大化(max)推理更深但耗时更长。仅对 DeepSeek 模型生效。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  ],

                  // ---- temperature ----
                  const SizedBox(height: 12),
                  Text(
                      'Temperature: ${profile['temperature']?.toStringAsFixed(1) ?? '0.0'}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      )),
                  Slider(
                    value: (profile['temperature'] as num?)?.toDouble() ?? 0.0,
                    min: 0.0,
                    max: 1.5,
                    divisions: 15,
                    label: profile['temperature']?.toStringAsFixed(1) ?? '0.0',
                    onChanged: thinkingEnabled
                        ? null
                        : (val) => _updateProfile(taskType, {'temperature': val}),
                  ),
                  if (thinkingEnabled)
                    Text(
                      '深度推理模式下 temperature 不生效，由模型内部控制',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.orange.shade600,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildModelInfoCard(String model, ThemeData theme) {
    final meta = _models[model] as Map<String, dynamic>?;
    if (meta == null) return const SizedBox.shrink();

    final supportsVision = meta['supports_vision'] as bool? ?? false;
    final supportsThinking = meta['supports_thinking'] as bool? ?? false;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            meta['desc'] as String? ?? '',
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _capChip(supportsVision ? '支持视觉' : '不支持视觉', supportsVision, theme),
              _capChip(supportsThinking ? '支持推理' : '不支持推理', supportsThinking, theme),
            ],
          ),
        ],
      ),
    );
  }

  Widget _capChip(String label, bool active, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: active
            ? Colors.green.shade50
            : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: active ? Colors.green.shade300 : Colors.orange.shade300,
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: active ? Colors.green.shade800 : Colors.orange.shade800,
          fontSize: 11,
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Section: file management
  // -----------------------------------------------------------------------

  Widget _buildFileSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('文件管理',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          '设置一个本地目录，将 .docx / .pdf / .md / .ics 等文件放入该目录后，'
          '系统会自动解析文件内容并归类到备忘录、提醒事项或日程中。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 16),

        // ---- No LLM warning ----
        if (!_llmConfigured)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 20, color: Colors.red.shade600),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '需要先添加 LLM 提供商',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Colors.red.shade800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '文件处理需要 LLM 分析文件内容（分类、生成摘要）。请先在「模型连接配置」中添加至少一个提供商后，才能设置文件监控目录。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.red.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

        // ---- Multimodal unavailable warning (don't block, text files still work) ----
        if (_llmConfigured && !_multimodalAvailable)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 20, color: Colors.orange.shade600),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '图片/PDF 视觉处理不可用',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Colors.orange.shade800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '多模态槽位模型缺少 API Key 配置。纯文本文件仍可正常处理，但图片/PDF/Office 文件的视觉识别将降级为本地 OCR。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.orange.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

        TextField(
          enabled: _llmConfigured,
          controller: _pathCtrl,
          decoration: InputDecoration(
            labelText: '文件管理目录路径',
            hintText: '/Users/xxx/Documents/jarvis-files',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.folder_open, size: 20),
              onPressed: _llmConfigured
                  ? () async {
                      final result = await pickDirectory();
                      if (result != null && mounted) {
                        _pathCtrl.text = result;
                        if (kIsWeb) {
                          _showMessage('已选择目录 "$result"，请补全为完整路径（如 /Users/xxx/$result）');
                        }
                      }
                    }
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: (_saving || !_llmConfigured) ? null : _saveWatchDir,
              icon: _saving
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 18),
              label: const Text('保存并启动监控'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: (_saving || _watchDir == null || !_llmConfigured) ? null : _scanFiles,
              icon: const Icon(Icons.playlist_play, size: 18),
              label: const Text('手动扫描'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_statusMessage != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _statusMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Section: status
  // -----------------------------------------------------------------------

  Widget _buildStatusSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('监控状态',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        _StatusRow(
            label: '监控目录', value: _watchDir ?? '未设置', theme: theme),
        const SizedBox(height: 8),
        _StatusRow(
          label: '监控状态',
          value: _watching ? '运行中' : '已停止',
          valueColor: _watching ? Colors.green : Colors.grey,
          theme: theme,
        ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Section: help
  // -----------------------------------------------------------------------

  Widget _buildHelpSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('使用说明',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        _HelpItem(
            icon: Icons.upload_file,
            title: '放入文件',
            description: '将 .md / .docx / .pdf / .ics 等文件拖入或复制到上述监控目录。',
            theme: theme),
        const SizedBox(height: 10),
        _HelpItem(
            icon: Icons.auto_awesome,
            title: '自动识别',
            description: '系统监控到新文件后，会自动调用 AI 分析内容，判断属于备忘录、提醒还是日程。',
            theme: theme),
        const SizedBox(height: 10),
        _HelpItem(
            icon: Icons.category,
            title: '分类呈现',
            description: '识别结果会自动出现在 Flutter 客户端对应的页面中（备忘录 / 提醒事项 / 日程）。',
            theme: theme),
        const SizedBox(height: 10),
        _HelpItem(
            icon: Icons.description,
            title: '格式转换',
            description:
                '非 md 格式的源文件会自动生成一份同内容的 .md 副本，与源文件保存在同一目录中（.ics 文件除外，仅保留源文件）。',
            theme: theme),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  IconData _taskIcon(String taskType) {
    switch (taskType) {
      case 'TEXT':
        return Icons.text_fields;
      case 'MULTIMODAL':
        return Icons.visibility_outlined;
      default:
        return Icons.settings;
    }
  }

}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final ThemeData theme;

  const _StatusRow({
    required this.label,
    required this.value,
    this.valueColor,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              )),
        ),
        Expanded(
          child: Text(value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: valueColor ?? theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              )),
        ),
      ],
    );
  }
}

class _HelpItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final ThemeData theme;

  const _HelpItem({
    required this.icon,
    required this.title,
    required this.description,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  )),
            ],
          ),
        ),
      ],
    );
  }
}
