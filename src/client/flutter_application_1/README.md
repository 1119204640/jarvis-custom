# Jarvis Client
一个 Agent 秘书的 flutter 客户端

## 功能
- 这是纯客户端实现，只要管怎么跟 Python 那边的服务端交互和接入就好了
- 服务端功能代码在 /src/server
- 类似 Gemini 那样对话框界面，可以和用户进行自然语言对答
- 流式传输
- 有侧边栏可以选择记账、备忘录、提醒事项、日程、邮件（暂时 server 那边只做了记账）
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
    ├── sidebar.dart              # 功能导航侧边栏（5个入口，仅记账可用）
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

5 个功能入口中只有"记账"已对接服务端：

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