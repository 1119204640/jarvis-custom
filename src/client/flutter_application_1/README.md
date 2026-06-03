# Jarvis Client
一个 Agent 秘书的 flutter 客户端

## 首次启动

### 前置要求

- Flutter SDK
- Chrome（跑 Web 时）
- CocoaPods（跑 macOS 时）
- 服务端已通过仓库根目录的 `./start-server.sh` 启动

### 推荐启动方式

在仓库根目录直接运行：

```bash
# Flutter Web（默认）
./start-client.sh

# Flutter macOS
./start-client.sh -macos
```

如果你想手动进入 Flutter 工程目录，也可以这样：

```bash
cd src/client/flutter_application_1
flutter pub get
flutter run -d chrome
```

### 注意

- `-macos` 模式依赖 CocoaPods；如果本机没装，启动脚本会直接给出提示
- Web 和 macOS 共用同一套 Dart 代码，优先建议先在 Web 上验证功能
- LLM API Key 不需要写进 Flutter 工程里，统一在应用设置页配置

## 功能
- 这是纯客户端实现，只要管怎么跟 Python 那边的服务端交互和接入就好了
- 服务端功能代码在 /src/server
- 类似 Gemini 那样对话框界面，可以和用户进行自然语言对答
- 流式传输
- 有侧边栏可以选择备忘录、提醒事项、日程、邮件（记账入口暂时关闭，待升级优化；备忘录、提醒事项已接入服务端）
- 备忘录和提醒事项有专用的 Apple 风格 UI 界面（卡片式列表 + 分组提醒列表）
- 先实现在 web 运行，最终实现在 iOS、macOS、watchOS、Android、Windows 上运行

## 架构设计

### 三层架构

```
┌─────────────────────────────────────────────────┐
│  UI 层 (screens/ + widgets/)                     │
│  只管画界面、收事件，不碰网络                     │
├─────────────────────────────────────────────────┤
│  服务层 (services/chat_service.dart)              │
│  封装 Socket.IO + REST，暴露回调                  │
├─────────────────────────────────────────────────┤
│  模型层 (models/chat_message.dart)                │
│  纯数据，不可变，copyWith 模式更新                │
└─────────────────────────────────────────────────┘
```

- **UI 层不知道数据怎么来的**，只通过回调收数据
- **服务层不知道界面长什么样**，只负责收发
- **模型层不包含任何逻辑**，纯数据容器

### 文件结构

```
lib/
├── main.dart                    # 入口 + MaterialApp 配置（亮/暗双主题）
├── models/
│   └── chat_message.dart        # 消息数据模型（id/role/content/isStreaming）
├── services/
│   └── chat_service.dart        # Socket.IO 通信 + REST 线程管理
├── screens/
│   └── home_screen.dart         # 主页面：管理全部状态，组合子组件
└── widgets/
    ├── sidebar.dart              # 功能导航侧边栏（4个入口，记账暂时关闭待升级）
    ├── chat_bubble.dart          # 聊天气泡（用户/AI 双色 + 流式闪烁光标）
    └── message_input.dart        # 消息输入框 + 发送按钮
```

### 数据流向

```
用户打字 → MessageInput.onSend
  → HomeScreen._sendMessage()
    → ChatService.sendMessage()          // Socket.IO emit "client_message"
      ↓
服务端处理（DeepSeek + LangGraph + MCP 工具调用）
      ↓
ChatService 收到事件回调:
  ├── onStreamUpdate(msgId, token)       // 每个字都触发，UI 拼到消息尾部
  ├── onMessage(fullMsg)                 // 完整消息到达，兜底替换流式内容
  └── onConnectionChange(bool)          // 连接断开/恢复
      ↓
HomeScreen.setState() → Flutter rebuild → 界面更新
```

### 流式消息状态机

```
1. 用户发送 → 立即显示用户气泡
2. 首个 stream_token → 新建 AI 气泡（isStreaming: true，尾部显示闪烁光标）
3. 后续 stream_token → 同一气泡内拼接内容，光标持续闪烁
4. stream_end → 光标消失（isStreaming: false）
5. new_message → 用完整消息替换，兜底防止丢字
```

**同时监听 `stream_token` 和 `new_message`**，确保不同协议模式下都不丢数据。

### 通信层

| 协议 | 地址 | 用途 |
|------|------|------|
| Socket.IO | `ws://localhost:8000/ws/socket.io` | 实时聊天（发消息、收流式响应） |
| REST | `http://localhost:8000/project/threads` | 获取线程列表 |

**连接参数**：`sessionId`（客户端 UUID）+ `clientType: "flutter"`

**Socket.IO 事件**：
- 发送：`client_message`（包含 id/name/type/output/threadId）
- 接收：`stream_start` → `stream_token`（× N）→ `stream_end` → `new_message`

### 侧边栏禁用设计

4 个功能入口（记账入口暂时关闭，待升级优化）：

```dart
class SidebarItem {
  bool enabled;    // false = 服务端未实现
  String tooltip;  // 点击时 SnackBar 提示
}
```

- 禁用项：灰色文字 + 🔒图标 + 点击弹出"XXX功能尚未接入服务端"
- 以后接入新功能只需把 `enabled: false` 改成 `true`，无需改逻辑

### 关键设计决策

1. **`copyWith` 不可变模式**：ChatMessage 更新时返回新对象而非修改内部字段，Flutter 能正确识别"同一 ID、内容变化"以避免不必要重绘

2. **回调而非状态管理库**：ChatService 暴露 `onMessage` / `onStreamUpdate` / `onConnectionChange` 回调，HomeScreen 全权决定何时 `setState`，无隐式依赖

3. **ID 匹配而非索引匹配**：流式消息通过 `messageId` 匹配更新，即使事件顺序乱了也能正确落到对应气泡

4. **延迟滚动**：新消息到达后 `Future.delayed(100ms)` 等一帧再滚到底，确保新消息高度已计算完成

5. **连接状态驱动 UI**：未连接时输入框和发送按钮自动禁用，防止无效操作


## 知识点笔记

### Flutter 工程目录结构

```
flutter_application_1/
├── pubspec.yaml          # 项目的"身份证"——包名、依赖、SDK 版本
├── analysis_options.yaml # 代码静态分析 / Lint 规则
├── lib/                  # ⭐ 你写 Dart 代码的地方（核心）
│   └── main.dart         # 入口文件
├── test/                 # 单元测试 / Widget 测试
│   └── widget_test.dart
├── android/              # Android 原生壳（一般不用手动改）
├── ios/                  # iOS 原生壳
├── macos/                # macOS 桌面壳
├── linux/                # Linux 桌面壳
├── windows/              # Windows 桌面壳
├── web/                  # Web 壳
└── build/                # 构建产物（自动生成，忽略）
```

**核心概念**：Flutter 是一套代码，编译到 6 个平台（Android / iOS / Web / macOS / Windows / Linux）。`lib/` 里的 Dart 代码是跨平台共享的，各平台目录只是"壳"。

### pubspec.yaml —— 项目配置文件

相当于 Python 的 `pyproject.toml`：

- **dependencies** = 打包进 App 的库
- **dev_dependencies** = 只在开发时用的库（测试框架、lint）
- `flutter:` 块下面可以声明图片资源 (`assets`)、字体等

### main.dart —— 代码入口

`main()` 是 Dart 的程序入口（就像 C 的 `main`、Python 的 `if __name__ == '__main__'`）。`runApp()` 接收一个 Widget，把它撑满整个屏幕。

### 两种 Widget 类型

| 类型 | 特点 | 何时用 |
|------|------|--------|
| `StatelessWidget` | 属性不可变，只 build 一次 | 纯展示：图标、文字、静态布局 |
| `StatefulWidget` | 有配套的 State 对象，可更新 | 需要交互：计数器、表单、动画 |

### setState() 机制

1. 你修改了状态变量（如 `_counter`）
2. 调用 `setState()` 告诉 Flutter "这个 State 变了"
3. Flutter 重新调用 `build()`，界面更新

**不调用 `setState()` 的话，数据变了但界面不会刷新。**

### MaterialApp 和 Scaffold

- **`MaterialApp`**：Material Design 风格的"应用壳"，提供路由、主题、导航等基础设施
- **`Scaffold`**：页面骨架，提供 appBar（顶部栏）、body（主体）、floatingActionButton（悬浮按钮）等标准布局

### 常用布局 Widget 速查

| Widget | 作用 |
|--------|------|
| `Center` | 把子元素居中 |
| `Column` | 子元素纵向排列 |
| `Row` | 子元素横向排列 |
| `Container` | 万能盒子（可设宽高、边距、颜色、装饰） |
| `Padding` | 加内边距 |
| `SizedBox` | 固定宽/高的空白 |
| `Expanded` | 撑满剩余空间（在 Column/Row 里用） |
| `ListView` | 可滚动列表 |

### 运行命令

```bash
cd src/client/flutter_application_1
flutter run           # 启动 App（需要连设备或开模拟器）
flutter run -d chrome # 在 Chrome 浏览器中运行
flutter run -d macos  # 作为 macOS 桌面应用运行
flutter test          # 运行测试
```

**热重载（Hot Reload）**：代码改了保存，App 瞬间更新，不用重启，状态保留。

## 踩坑及解决记录

### 1. AI 返回的 Markdown 不渲染

**现象**：LLM 返回的 Markdown 内容（标题、代码块、列表、加粗等）在 Flutter 中显示为原始文本，`###`、`**` 等语法字符肉眼可见。

**原因**：消息通过 `ChatBubble` 渲染，内部使用 Flutter 原生 `Text` widget 直接展示 `message.content`，没有任何 Markdown 解析。

**解决**：添加 `flutter_markdown` 依赖（`pubspec.yaml`），新建 `AiMessage` 组件，用 `MarkdownBody` 替代 `Text` 渲染 AI 回复：

```dart
MarkdownBody(
  data: message.content,
  selectable: true,
  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
)
```

`MarkdownBody` 不需要自己的 `ScrollController`，放在 `ListView` 里不会产生滚动冲突。

### 2. 用户消息发送后不显示

**现象**：输入框发送消息后，对话列表中看不到自己发的消息，只能看到 AI 的回复。

**原因**：`HomeScreen._sendMessage()` 中只调用了 `_chatService.sendMessage(text)` 将消息通过 Socket.IO 发往服务端，但没有创建 `ChatMessage` 对象加入本地 `_messages` 列表。数据发出去了，UI 不知道它的存在。

**解决**：发送前先将用户消息加入 `_messages`，`setState` 触发重绘：

```dart
void _sendMessage(String text) {
  if (!_isConnected) return;
  final userMessage = ChatMessage(
    id: const Uuid().v4(),
    role: 'user',
    content: text,
    createdAt: DateTime.now(),
  );
  setState(() => _messages.add(userMessage));
  _scrollToBottom();
  _chatService.sendMessage(text);
}
```

### 3. 消息布局改造：用户气泡 + AI 全宽块

**现象**：用户消息和 AI 回复都用同一种气泡样式，不符合主流 AI 聊天应用的交互习惯。

**需求**：用户消息用气泡、AI 回复无气泡全宽显示 Markdown（类似 Gemini / ChatGPT）。

**改动**：

- `ChatBubble` 简化为仅处理 `role == 'user'` 的消息（右对齐 + 紫色背景气泡，去掉角色标签和 AI 分支）
- 新建 `AiMessage` 组件：全宽 `MarkdownBody`，无气泡包裹，流式传输时尾部显示闪烁光标
- `HomeScreen` 的 `ListView.builder` 按 `message.role` 分流：

```dart
itemBuilder: (context, index) {
  final message = _messages[index];
  if (message.role == 'user') {
    return ChatBubble(message: message);
  } else {
    return AiMessage(message: message);
  }
},
```

## 备忘录与提醒事项 UI

### 新增文件

| 文件 | 用途 |
|------|------|
| `lib/models/memo.dart` | 备忘录数据模型（不可变、copyWith） |
| `lib/models/reminder.dart` | 提醒事项数据模型（不可变、copyWith） |
| `lib/services/memo_api.dart` | 备忘录 REST API 服务 |
| `lib/services/reminder_api.dart` | 提醒 REST API 服务 |
| `lib/screens/memo_list_screen.dart` | 备忘录列表页（Apple Notes 风格） |
| `lib/screens/memo_detail_screen.dart` | 备忘录编辑/查看页 |
| `lib/screens/reminder_screen.dart` | 提醒事项页（Apple Reminders 风格） |

### 导航架构

```
HomeScreen (_selectedFeature)
  ├── index 0 → MemoListScreen（Apple Notes 卡片式列表 + 搜索）
  │               └── Navigator.push → MemoDetailScreen（编辑/查看）
  ├── index 1 → ReminderScreen（Apple Reminders 分组列表 + 快速添加）
  └── index 2 → CalendarScreen（月/日视图）
  （记账入口暂时关闭，待升级优化）
```

所有屏幕通过 `HomeScreen` 的 `_selectedFeature` 切换，共享同一个 `AppSidebar` 抽屉导航。

### 数据流

```
MemoListScreen ──GET /api/memos──→ Python 服务端 ──→ MemoService ──→ SQLite + .md
MemoDetailScreen ──POST/PUT/DELETE /api/memos──→

ReminderScreen ──GET/POST/PUT/DELETE /api/reminders──→
                ──PUT /api/reminders/{id}/complete──→
```

### 设计要点

1. **Apple Notes 风格备忘录**：卡片式列表（标题 + 正文预览 + 日期 + 彩色标签 chip）、顶部搜索框、FAB 新建、点击卡片进入详情编辑
2. **Apple Reminders 风格提醒**：分组列表（今天/计划中/无日期/已完成）、圆形复选框、过期日期红色标识、优先级标志、底部快速添加表单、左滑删除
3. **双通道一致性**：Flutter UI 通过 REST API 直接操作数据，Agent 通过 LangChain 工具操作同一 `MemoService` 单例，两边数据实时同步

### 踩坑记录

#### 4. 内嵌 Scaffold 导致的 AppBar 嵌套问题

**现象**：备忘录和提醒事项页面有自己的 Scaffold + AppBar，但被 HomeScreen 包装在另一个 Scaffold 中时，内层 AppBar 不能固定在屏幕顶部。

**原因**：Flutter 中嵌套 Scaffold 时，内层 Scaffold 渲染在外层 Scaffold 的 body 区域内，其 AppBar 随内容滚动而非固定在屏幕顶部。

**解决**：将 `MemoListScreen` 和 `ReminderScreen` 从完整 Scaffold 改为 body-only 组件（只返回 Column/RefreshIndicator），由 HomeScreen 统一提供外层 Scaffold 和 AppBar。FAB 也从内部移到 HomeScreen 的条件渲染中：

```dart
// HomeScreen build() 中按 _selectedFeature 返回不同 body + AppBar
if (_selectedFeature == 1) {
  return Scaffold(
    appBar: AppBar(title: const Text('备忘录'), ...),
    body: MemoListScreen(key: ValueKey('memo_$_memoRefreshKey')),
    floatingActionButton: FloatingActionButton.extended(...),
  );
}
```

#### 5. 跨 Tab 切换后列表数据不刷新

**现象**：用户通过 FAB 新建备忘录后返回列表，或切换 Tab 后切回来，列表仍显示旧数据。

**原因**：`MemoListScreen` 和 `ReminderScreen` 是 StatefulWidget，数据在 `initState` 中加载一次。如果 widget 未被重建（例如用 IndexedStack 或条件渲染时 key 相同），`initState` 不会重新调用。

**解决**：HomeScreen 维护 `_memoRefreshKey` 和 `_reminderRefreshKey` 计数器，创建子页面时传入 `ValueKey`。需要在外部触发刷新时递增计数，迫使 Flutter 重建 widget（重新调用 initState）：

```dart
body: MemoListScreen(key: ValueKey('memo_$_memoRefreshKey')),

// FAB 回调中
onPressed: () async {
  final result = await Navigator.push(...);
  if (result == true && mounted) {
    setState(() => _memoRefreshKey++);  // 触发重建
  }
},
```

#### 6. 提醒事项没有创建按钮

**现象**：提醒事项页面（`ReminderScreen`）有 `_showAddForm` 状态和 `_AddReminderForm` 表单组件，但没有任何入口可以触发显示表单，用户无法创建提醒。

**原因**：`_showAddForm` 默认为 `false`，且页面内没有按钮、FAB 或行项目可以将其设为 `true`。快速添加表单被完全隐藏。

**解决**：

1. 在 `home_screen.dart` 中为提醒事项页添加 `FloatingActionButton`，通过 `_reminderShowAddForm` 状态控制显示
2. `ReminderScreen` 新增 `showAddForm` 参数 + `onToggleAddForm` 回调，接收父组件的状态
3. 列表底部添加"新提醒事项"占位行（Apple Reminders 风格），点击后显示添加表单：

```dart
// 新增占位行（_showAddForm 为 false 时显示）
if (!_showAddForm)
  InkWell(
    onTap: () => setState(() => _showAddForm = true),
    child: Row(children: [
      Container(/* 空心圆 + 加号图标 */),
      Text('新提醒事项', style: ...),
    ]),
  ),
```

#### 7. 备忘录搜索不支持标签检索

**现象**：在搜索框中输入标签名称（如"生活"、"工作"）无法检索到带有该标签的备忘录，只能搜索标题和正文内容。

**原因**：`MemoService.search_memos()` 的 SQL 查询只匹配 `title LIKE ?`，标签字段（`tags`）完全没有参与搜索。SQL 中的子查询 `file_path IN (SELECT file_path FROM nodes WHERE type='memo')` 也始终为真，属于无效条件。

**解决**：在 `memo_service.py` 中修复 SQL 查询，同时匹配 `title` 和 `tags` 字段：

```python
# 修复前（只搜标题）
WHERE type='memo' AND (title LIKE ? OR file_path IN (...))  # 子查询无效

# 修复后（搜标题 + 标签）
WHERE type='memo' AND (title LIKE ? OR tags LIKE ?)
```

同时在 Python 侧对文件内容做二次过滤，并用 `set` 去重避免同一条记录被返回多次。

#### 8. 备忘录不支持插入图片

**现象**：备忘录编辑页面是纯文本输入，无法插入图片附件。

**解决**：

- **后端**：新增 `POST /api/upload` 端点，接受 multipart 图片上传，保存到 `data/uploads/`，返回 URL；通过 FastAPI `StaticFiles` 将 `/uploads/` 挂载为静态资源
- **Flutter**：添加 `image_picker` 依赖，在 `MemoDetailScreen` 的 AppBar 增加图片按钮，选择图片后上传至服务器，在正文光标位置插入 `![filename](http://localhost:8000/uploads/xxx.png)` 的 Markdown 图片语法
- `MarkdownBody`（`flutter_markdown`）原生支持图片渲染，无需额外配置
- 上传方法用 `MultipartFile.fromBytes()` 而非 `fromPath()`，确保 Web 和移动端均可使用

#### 9. 提醒事项优先级选择没反应

**现象**：点击添加表单中的优先级 ChoiceChip（低/中/高），选中状态不变化。

**原因**：`_AddReminderForm` 的 `onPriorityChanged` 回调只有赋值 `_newPriority = v`，没有调用 `setState()`，UI 不重绘。

**解决**：改为 `onPriorityChanged: (v) => setState(() => _newPriority = v)`。

#### 10. 提醒事项到期日缺少日期选择器

**现象**：添加提醒时到期日只能手动输入 YYYY-MM-DD 格式，体验差，且无法留空。

**原因**：到期日输入用的是普通 `TextField`，`_AddReminderForm` 是 `StatelessWidget`，无法响应用户交互更新 UI。

**解决**：
- 将 `_AddReminderForm` 改为 `StatefulWidget`，监听 controller 变化自动 `setState`
- 用 `InkWell` + `showDatePicker()` 替代文本输入框，点击弹出系统日历组件
- 选中的日期右侧显示 X 按钮可清空到期日
- 添加按钮的 `onPressed` 根据标题是否为空动态启用/禁用

#### 11. 提醒事项缺少编辑入口

**现象**：单条提醒事项只有点击复选框（完成/取消）和左滑删除两种操作，无法修改标题、到期日、优先级等内容。

**原因**：`_ReminderRow` 只有 `onToggle` 和 `onDelete` 两个回调，没有编辑功能。

**解决**：
- 在 `_ReminderRow` 每行右侧添加 `Icons.more_horiz`（省略号）按钮
- 新增 `onEdit` 回调和 `_showEditDialog()` 方法
- 编辑弹窗用 `showDialog` + `StatefulBuilder` 实现局部状态管理，包含：标题输入框、备注输入框（多行）、到期日选择器（同添加表单）、优先级 ChoiceChip
- 保存时调用 `ReminderApi.update()`

#### 12. 备忘录入图片上传失败

**现象**：在备忘录详情页点击图片按钮能弹出图片选择器，但选择图片后上传失败，提示"图片上传失败"。

**原因**：`MemoApi.uploadImage()` 使用 `MultipartFile.fromBytes()` 发送文件时未指定 `contentType` 参数，默认是 `application/octet-stream`。服务端 `POST /api/upload` 校验了 `content_type.startswith("image/")`，`application/octet-stream` 不匹配，返回 400。

**解决**：修改服务端 `upload_image` 端点，当 content_type 不满足 `image/*` 时，改为根据文件扩展名判断（允许 png/jpg/jpeg/gif/webp/bmp/svg），避免因客户端未传 content_type 而拒绝合法图片上传。

#### 13. 备忘录不支持图片内联显示和粘贴

**现象**：图片插入后只显示 Markdown 语法文本 `![name](url)`，不能在备忘录中直接看到图片；也无法通过 Ctrl+V / Cmd+V 粘贴剪贴板中的图片。

**原因**：备忘录编辑页用的是纯 `TextField`，只处理文本。图片要等到回到列表页用 `MarkdownBody` 渲染才能看到。也没有粘贴事件监听。

**解决**：

- **编辑/预览切换**：AppBar 新增眼睛图标按钮，切换 `_isPreviewing` 状态。编辑模式显示原有 TextField，预览模式用 `MarkdownBody` 渲染正文（图片内联显示、Markdown 格式全部渲染）
- **粘贴图片**：新建 `clipboard_image_web.dart` / `clipboard_image_stub.dart`，通过条件导入 `if (dart.library.html)` 实现 web 端粘贴支持
  - Web：用 `dart:html` 监听 `document.addEventListener('paste', ...)`，检测剪贴板中 image 类型数据，读取为 bytes 后走同一套上传 + 插入流程
  - 非 Web：打桩（`registerPasteHandler` 空函数），用户仍可用图片按钮
- 提取 `_uploadAndInsert(bytes, fileName)` 公共方法，图片按钮和粘贴共用

	#### 14. 备忘录编辑/预览模式割裂

	**现象**：编辑和预览通过 AppBar 眼睛图标按钮切换，两种模式完全分离，体验不连贯，不像 Apple Notes 那样所见即所得。

	**原因**：`_isPreviewing` 布尔值控制两种互斥的 UI 状态（TextField vs MarkdownBody），需要手动点击按钮来回切换。

	**解决**：

	- 移除编辑/预览切换按钮，将两种模式融为一体（Apple Notes 风格）
	- 新增 `_editingContent` 状态 + `_contentFocus` FocusNode
	- **默认预览**：正文渲染为 `MarkdownBody`（图片内联显示、Markdown 完整渲染），点击正文区域进入编辑
	- **点击编辑**：`GestureDetector` 包裹 MarkdownBody，`onTap` 切换到 TextField 并自动获取焦点
	- **失焦预览**：监听 `_contentFocus.hasFocus`，失去焦点时自动切回 MarkdownBody
	- 新增/空备忘录默认进入编辑状态
	- 粘贴图片时自动切到编辑模式再插入 Markdown 图片语法

	#### 15. 提醒事项编辑弹窗缺少删除按钮

	**现象**：点击提醒事项的省略号按钮进入编辑弹窗后，只能修改或取消，无法删除该条提醒。虽然支持左滑删除，但不够直观，用户不易发现。

	**原因**：`_showEditDialog()` 的 `AlertDialog.actions` 只有"取消"和"保存"两个按钮，缺少删除操作。

	**解决**：

	- 在编辑弹窗 actions 中新增红色"删除"按钮
	- 点击删除按钮先弹出二次确认对话框（`showDialog<bool>` + 确认/取消）
	- 确认后返回 `'delete'` 结果，外层 `_showEditDialog` 捕获后调用 `ReminderApi.delete()`
	- `showDialog` 泛型从 `bool` 改为 `String`，统一用 `'save'` / `'delete'` / `'cancel'` 三种返回值

#### 16. 表格编辑器撤销后无法删除内容（Unexpected null value）

**现象**：备忘录编辑页中，在表格单元格随便写几个字 → 删除整个表格 → 按 Ctrl+Z 撤销，表格虽然恢复了，但后续无法删除任何位置的内容（回车、退格均无效），Flutter 控制台反复报 `Another exception was thrown: Unexpected null value.`

**原因**：

1. **`JarvisTableNode` 构造函数未深拷贝 `cells` 参数** — 直接将调用方传入的 `List<List<AttributedText>>` 引用赋给 `_cells` 字段。虽然 `Final` 阻止了字段本身的重新赋值，但外部调用方如果后续修改了传入的 `cells` 列表，会间接改变 `JarvisTableNode` 的内部状态，破坏不可变性。

2. **`MutableDocument._latestNodesSnapshot` 是浅拷贝** — super_editor 的 `Editor.undo()` 实现机制是：先调用 `MutableDocument.reset()` 将 `_nodes` 回退到构造函数时保存的 `_latestNodesSnapshot`（浅拷贝），然后按序回放历史中除最后一个事务外的所有命令。如果 `_latestNodesSnapshot` 保存的节点引用被意外修改（原因 1），回退状态就会不一致。回放 `ReplaceNodeCommand` 时，`document.getNodeById(existingNodeId)!` 的强制解包如果拿到 null，就会抛出 `Unexpected null value`。

3. **`build()` 方法中 `table.cells` 重复调用** — 原代码在渲染每个单元格时分别调用 `table.cells[r][c]`（getter 每次都返回新的深拷贝），造成不必要的对象创建，也放大了浅拷贝不一致的风险。

**解决**（[table_node_component.dart](lib/editors/components/table_node_component.dart)）：

1. **构造函数深拷贝** — 初始化列表改为 `_cells = cells.map((r) => List<AttributedText>.from(r)).toList()`，杜绝外部引用共享。
2. **缓存 `_rows` / `_cols`** — 新增 `final int _rows` / `final int _cols` 字段，在构造函数初始化列表中计算一次，`rows` / `cols` getter 直接返回缓存值，避免依赖 `_cells.length`。
3. **`addRow()` 使用 `_cells` 直接深拷贝** — `_cells.map((r) => List<AttributedText>.from(r)).toList()`，与构造函数保持一致。
4. **`build()` 中缓存 cells** — 在 `build()` 方法开头调用一次 `final cells = table.cells`，后续单元格渲染使用 `cells[r][c]`，避免每个单元格都创建一次深拷贝。

## 日程管理 UI

### 新增文件

| 文件 | 用途 |
|------|------|
| `lib/models/event.dart` | 日程数据模型（不可变、copyWith） |
| `lib/services/calendar_api.dart` | 日程 REST API 服务 |
| `lib/screens/calendar/calendar_screen.dart` | 日程主容器（月/日视图切换 + 数据加载） |
| `lib/screens/calendar/month_view.dart` | 月视图（仿苹果日历，手写 7×5-6 网格） |
| `lib/screens/calendar/day_view.dart` | 日视图（手写时间轴 + 拖拽创建） |
| `lib/screens/calendar/event_edit_dialog.dart` | 日程编辑弹窗（含颜色选择） |
| `lib/screens/calendar/year_month_picker.dart` | 年月快速选择器（年份滚动 + 12 月宫格） |

### 导航架构

```
HomeScreen (_selectedFeature)
  ├── index 0 → MemoListScreen
  ├── index 1 → ReminderScreen
  └── index 2 → CalendarScreen
                    ├── MonthView（默认月视图）
                    │     └── 点击日期 → DayView
                    │     └── 点击年月标题 → YearMonthPicker
                    └── DayView（日视图）
                          └── 返回按钮 → MonthView
                          └── 拖拽创建 → EventEditDialog
                          └── 点击日程卡片 → EventEditDialog
  （记账入口暂时关闭，待升级优化）
```

### 设计要点

1. **手写日历组件**：不引入第三方库，用 Flutter 原生 widget（`Row`/`Column`/`GestureDetector`/`Stack`/`Positioned`）手写月视图和日视图
2. **月视图**：7列×5-6行网格，每格日期+最多3个事件圆点。今日红色填充圆，选中日浅蓝高亮。底部日程列表实时跟随选中日期
3. **日视图**：左侧时间轴 00:00-23:00，全天日程顶部条状，当前时间红色横线。日程卡片按 startTime/endTime 像素定位。桌面端拖拽创建
4. **年月选择器**：Dialog弹窗，年份左右箭头，12个月3×4宫格，当前月份主题色高亮

### 踩坑记录

#### 17. FastAPI 路由顺序 — 具体路径必须在参数路径前注册

**现象**：`GET /api/events/sync/status` 返回 404，因为 `sync` 被 `GET /api/events/{event_id}` 作为 event_id 捕获。

**解决**：将具体路径（`/api/events/sync/status`、`/api/events/google/...`）注册在 `/{event_id}` 前面。

#### 18. 月视图 Grid 计算

```dart
final firstDay = DateTime(year, month, 1);
final lastDay = DateTime(year, month + 1, 0);
final firstWeekday = firstDay.weekday; // 1=Mon, 7=Sun
final weeks = ((firstWeekday - 1 + lastDay.day) / 7).ceil();
```

网格前填充null（空白格），不足7格补充null，最少5行保持视觉一致。

#### 19. 日视图像素定位

```dart
double _timeToY(DateTime dt) => (dt.hour + dt.minute / 60.0) * _hourHeight;
```

卡片height = `(_timeToY(end) - _timeToY(start)).clamp(20, max)`。

#### 20. 拖拽与滚动手势冲突

桌面端用 `_isDesktop()` 判断才启用 `onPanStart/Update/End`，移动端只保留 ScrollView。

#### 21. macOS 启动报 "Failed to foreground app; open returned 1"

**现象**：`flutter run -d macos` 构建成功后，app 无法启动或闪退，控制台输出：
```
✓ Built build/macos/Build/Products/Debug/flutter_application_1.app
Failed to foreground app; open returned 1
```

**原因**：

1. **上一个实例未退出**（最常见）— 之前用 `flutter run` 启动的 `flutter_application_1` 进程仍在后台运行，macOS 的 `open` 命令检测到同名 bundle identifier 已在运行，返回 exit code 1。

2. **Debug entitlements 开启了 App Sandbox** — `DebugProfile.entitlements` 中 `com.apple.security.app-sandbox = true` 会阻止 Flutter 调试器正常附加到 app 进程，导致 `open` 命令失败。App Sandbox 仅用于 App Store 分发，开发调试阶段应关闭。

**解决**：

1. 先杀掉残留进程：
   ```bash
   killall flutter_application_1
   ```

2. 关闭 Debug 模式的 App Sandbox（[macos/Runner/DebugProfile.entitlements](macos/Runner/DebugProfile.entitlements)）：
   ```xml
   <key>com.apple.security.app-sandbox</key>
   <false/>
   ```
   
   保留 `DebugProfile.entitlements` 中 JIT 和网络权限（`com.apple.security.cs.allow-jit`、`com.apple.security.network.server`、`com.apple.security.network.client`），这些是 Flutter 调试和 Socket.IO 通信必需的。

3. 如果问题仍然存在，尝试清理构建产物后重新构建：
   ```bash
   flutter clean && flutter pub get && flutter run -d macos
   ```

---

## 已修复的 bugs

### 文档/备忘录编辑后点返回出现黑屏 (2026-06-02)

**问题**：在 `VaultDetailScreen` 或 `MemoDetailScreen` 中编辑文档/备忘录后点击返回按钮或使用系统返回手势，页面全黑屏。

**原因**：`_save()` 方法内部已经调用了 `Navigator.pop(context, true)` 关闭编辑页，但调用 `_save()` 的地方（`onPopInvokedWithResult` 回调和 AppBar 返回按钮的 `onPressed`）在 `_save()` 返回后又执行了第二次 `Navigator.pop()`。双重 pop 导致编辑页之下的列表页也被关闭，整个 app 只剩黑屏。

**修复**：在 `vault_detail_screen.dart` 和 `memo_detail_screen.dart` 中：
- `onPopInvokedWithResult` 中：`await _save()` 后加 `return`，阻止后续的 `Navigator.pop`
- AppBar 返回按钮中：`await _save()` 后移除 `if (mounted) Navigator.pop(context)`
