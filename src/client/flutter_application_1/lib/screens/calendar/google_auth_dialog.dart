import 'package:flutter/material.dart';
import '../../services/app_config.dart';
import '../../services/calendar_api.dart';

/// Google 日历 OAuth 授权对话框
///
/// - 检查当前连接状态
/// - 未连接时：生成授权 URL，引导用户去浏览器授权
/// - 已连接时：显示状态，可断开
class GoogleAuthDialog extends StatefulWidget {
  final VoidCallback? onConnected;

  const GoogleAuthDialog({super.key, this.onConnected});

  @override
  State<GoogleAuthDialog> createState() => _GoogleAuthDialogState();
}

class _GoogleAuthDialogState extends State<GoogleAuthDialog> {
  final CalendarApi _api = CalendarApi();
  bool _loading = true;
  bool _connected = false;
  String? _expiry;
  String? _authUrl;
  String? _fetchError;
  bool _fetchingUrl = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    setState(() => _loading = true);
    final status = await _api.checkOAuthStatus();
    if (mounted) {
      setState(() {
        _loading = false;
        _connected = status?['connected'] == true;
        _expiry = status?['expiry'] as String?;
      });
    }
  }

  Future<void> _fetchAuthUrl() async {
    setState(() {
      _fetchingUrl = true;
      _fetchError = null;
    });
    final result = await _api.getAuthUrl();
    if (mounted) {
      setState(() {
        _fetchingUrl = false;
        final error = result['error'] as String?;
        if (error != null) {
          _fetchError = error;
        } else {
          _authUrl = result['auth_url'] as String?;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Image.asset(
            // Material doesn't have Google icon; use text fallback
            'assets/icons/google_calendar.png',
            width: 24,
            height: 24,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.calendar_month, color: Colors.blue),
          ),
          const SizedBox(width: 8),
          const Text('Google 日历绑定'),
        ],
      ),
      content: _loading
          ? const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            )
          : _buildContent(),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_connected) {
      return SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 20),
                const SizedBox(width: 8),
                const Text('已连接 Google 日历',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            if (_expiry != null) ...[
              const SizedBox(height: 8),
              Text('Token 过期时间: $_expiry',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            const Text(
              '你可以点击日程页的同步按钮来拉取 Google 日历中的日程。',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.cloud_off, color: Colors.orange, size: 32),
            const SizedBox(height: 12),
            const Text('尚未绑定 Google 账户',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),

            // ── 前提条件：服务端配置 ──
            _buildSectionTitle('前提：配置 Google OAuth 凭据（只需做一次）'),
            const SizedBox(height: 6),
            _buildStep('1', '打开 Google Cloud Console', [
              '浏览器访问 https://console.cloud.google.com/apis/credentials',
              '登录你的 Google 账户',
              '如果还没有项目，先创建一个新项目（例如取名 "Jarvis"）',
            ]),
            _buildStep('2', '启用 Google Calendar API', [
              '左侧菜单 → "库"（Library）',
              '搜索 "Google Calendar API"',
              '点击进入后选择 "启用"（Enable）',
            ]),
            _buildStep('3', '创建 OAuth 2.0 客户端 ID', [
              '回到 凭据 页面，点击 "+ 创建凭据" → "OAuth 客户端 ID"',
              '应用类型选 "Web 应用"，名称随意（如 "Jarvis Desktop"）',
              '在 "已获授权的重定向 URI" 中添加：',
              '  ${AppConfig.serverBaseUrl}/api/events/google/callback',
              '点击"创建"，弹出窗口中会显示 Client ID 和 Client Secret',
            ]),
            _buildStep('4', '将凭据填入 .env 文件', [
              '在项目目录下找到或新建 .env 文件',
              '添加以下三行（等号右侧填入你刚才获取的值）：',
              '  GOOGLE_CLIENT_ID=你的ClientID.apps.googleusercontent.com',
              '  GOOGLE_CLIENT_SECRET=你的ClientSecret',
              '  GOOGLE_REDIRECT_URI=${AppConfig.serverBaseUrl}/api/events/google/callback',
              '保存文件，然后**重启服务器**使配置生效',
            ]),
            const Divider(height: 24),

            // ── 授权操作 ──
            _buildSectionTitle('授权操作（每次绑定/重新授权时执行）'),
            const SizedBox(height: 6),
            _buildStep('5', '点击下方按钮获取授权链接并打开浏览器完成授权', [
              '点击"获取授权链接"按钮',
              '复制生成的链接到浏览器中打开',
              '在 Google 授权页面上点击"继续"授权',
              '授权成功后回到此页面，点击"已完成授权"确认',
            ]),
            const SizedBox(height: 16),

            // 错误提示
            if (_fetchError != null)
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
                  children: [
                    Icon(Icons.error_outline, size: 18, color: Colors.red.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _fetchError!,
                        style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                      ),
                    ),
                  ],
                ),
              ),

            // 获取授权 URL 按钮
            if (_authUrl == null)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _fetchingUrl ? null : _fetchAuthUrl,
                  icon: _fetchingUrl
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: const Text('获取授权链接'),
                ),
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _authUrl!,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '👆 全选上方链接，复制后在浏览器中打开，登录 Google 并授权。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  _checkStatus();
                  widget.onConnected?.call();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('已完成授权，刷新状态'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  Widget _buildStep(String num, String title, List<String> details) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              num,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
                ...details.map((d) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: SelectableText(
                        d,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                          fontFamily: d.startsWith('  ') ? 'monospace' : null,
                        ),
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
