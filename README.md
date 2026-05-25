# Jarvis Ⅱ

## 功能

### 日程管理
- Google Calendar

### 待办提醒
- md 文件

### 备忘记录
- md 文件

### 工时统计
- wakatime + 主动汇报

### 财务记账
- Actual Budget

### 邮件通知

## 框架

### 前端

#### Web 交互：[chainlit](https://github.com/chainlit/chainlit)（可选）

Chainlit 降级为可选 Web 客户端。核心后端是独立 FastAPI + Socket.IO 服务端（`src/server/server.py`），所有客户端（终端 REPL / Flutter / Chainlit）都可选择使用。

服务端端口 8000，Socket.IO 路径 `/ws/socket.io`。

**客户端选项**：

| 客户端 | 入口 | 说明 |
|--------|------|------|
| 终端 REPL | `uv run python src/client/terminal_client.py` | Socket.IO 客户端，流式输出到终端 |
| Flutter | `src/client/flutter_application_1/` | 移动/桌面/Web App |
| Chainlit Web | `uv run chainlit run src/client/chainlit_web.py` | 浏览器访问 `http://localhost:8000` |

`src/client/chainlit_web.py` 使用 Chainlit 装饰器（`@cl.on_chat_start` / `@cl.on_message`），直接调用 Agent（不经过 Socket.IO，与独立服务端并行）。

### 后端

#### 日志打印：[loguru](https://github.com/Delgan/loguru)

---

## 财务记账：Actual Budget + MCP

使用 [Actual Budget](https://actualbudget.org/) 作为记账后端，通过 MCP Server 让 LLM（Claude Desktop / Codex 等）用自然语言读写财务数据。

### 架构


- **actual-server**（`/modules/actual-server`）：官方同步服务器，内置 Web 前端。存放预算文件（SQLite），提供 HTTP API。
- **actual-mcp**（`/modules/actual-mcp`）：社区 MCP Server，把 Actual API 包装成 MCP 协议，暴露 25 个工具（读写交易、分类、收款人、规则、银行同步等）。

### 初次部署

从零开始在一台新机器（或云服务器）上部署整个项目。

#### 环境要求

- **Node.js 22+** — 运行 actual-server 和 actual-mcp（推荐 [fnm](https://github.com/Schniz/fnm) 管理版本）
- **Python 3.12+** — 运行 Jarvis REPL
- **uv** — Python 包管理器
- **Docker**（可选）— 如果安装了 Docker，启动脚本优先使用容器化 actual-server；否则自动切换为原生 Node.js 运行

#### 1. 克隆项目

```bash
git clone --recurse-submodules <repo-url>
cd jarvis-custom
```

#### 2. 配置环境变量

```bash
cp .env.example .env
# 编辑 .env，填入 DeepSeek API Key
```

#### 3. 启动 MCP 基础设施 + Jarvis 服务端

```bash
./start-server.sh
```

这个脚本会自动完成：
1. 将 `patches/` 中的修复补丁应用到 submodule（无需手动改 submodule 代码）
2. 安装 npm 依赖 + 编译 TypeScript
3. 启动 actual-server（有 Docker 用容器，否则自动切换原生 Node.js）
4. 启动 actual-mcp SSE 服务（端口 3000，Node 22）
5. 启动 Jarvis 服务端（端口 8000）

服务端启动后，在服务端终端输入 `/stop` 即可优雅关机（保护数据库）。客户端直接 Ctrl+C 退出即可。

#### 4. 创建预算文件

浏览器打开 `http://localhost:5006`，设置登录密码，**创建服务器端文件**（Server File），不能是仅浏览器本地存储的文件，否则 MCP 读不到。

#### 5. 启动客户端

```bash
# Flutter web（默认，需要 Flutter SDK）
./start-client.sh

# 终端 REPL
./start-client.sh -repl

# Chainlit Web UI（可选）
./start-client.sh -chainlit
```

### 日常启动

第二次及以后启动：

**方式 A：一体化启动（推荐 — 同时启动 MCP 基础设施 + Jarvis 服务端）**

```bash
./start-server.sh
```

这会自动完成：启动 actual-server → 编译 actual-mcp → 启动 MCP SSE（端口 3000）→ 启动 Jarvis 服务端（端口 8000）。

然后任选一个客户端：
- Flutter web：`./start-client.sh`（默认）
- 终端 REPL：`./start-client.sh -repl`
- Chainlit Web：`./start-client.sh -chainlit`

**停止服务端**：
- 在服务端终端输入 `/stop` 优雅关机（推荐，保护数据库）
- 或 `curl -X POST http://localhost:8000/stop`
- 客户端直接 Ctrl+C 退出即可

浏览器打开 `http://localhost:8000` 即可交互。

停止后端：

```bash
# 服务端终端输入 /stop 优雅关机
# 客户端 Ctrl+C 退出

# 如果进程卡住不释放端口：
lsof -ti :8000 | xargs kill
lsof -ti :5006 | xargs kill   # 停止 actual-server
lsof -ti :3000 | xargs kill   # 停止 actual-mcp
```

### 部署架构细节

#### actual-server

```bash
cd modules/actual-server

# 首次运行需安装依赖（使用内置 Yarn Berry，无需全局安装 yarn）
node .yarn/releases/yarn-4.3.1.cjs install

# 启动（端口 5006）
ACTUAL_DATA_DIR=./actual-data fnm exec --using=22 node app.js
```

服务跑在 `http://localhost:5006`。

Docker 可选——有则用容器，无则自动切换原生 Node.js。实际启动由 `start-server.sh` 自动完成。

数据存放在 `modules/actual-server/actual-data/`：
- `server-files/account.sqlite` — 账户/会话/文件元信息
- `user-files/file-*.blob` — 预算文件（加密 zip）
- `user-files/group-*.sqlite` — 同步消息数据库

#### 验证预算文件

```bash
TOKEN=$(curl -s -X POST http://localhost:5006/account/login \
  -H 'Content-Type: application/json' \
  -d '{"password":"你的密码"}' | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
curl -s http://localhost:5006/sync/list-user-files -H "X-ACTUAL-TOKEN: $TOKEN"
# 应返回非空 data 数组
```

#### actual-mcp 其他启动方式

##### 方式 A：Claude Desktop stdio 配置

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "actualBudget": {
      "command": "node",
      "args": [
        "/path/to/modules/actual-mcp/build/index.js",
        "--enable-write"
      ],
      "env": {
        "ACTUAL_SERVER_URL": "http://localhost:5006",
        "ACTUAL_PASSWORD": "你的密码"
      }
    }
  }
}
```

Claude Desktop 会自动管理进程启停。

##### 方式 B：手动 SSE 服务

```bash
cd modules/actual-mcp
npm install && npm run build
ACTUAL_SERVER_URL=http://localhost:5006 \
ACTUAL_PASSWORD=你的密码 \
fnm exec --using=22 node build/index.js --sse --port 3000 --enable-write
```

然后用 Python MCP 客户端连接 `http://localhost:3000/sse`（SSE）或 `http://localhost:3000/mcp`（Streamable HTTP）。

#### patch 机制

`start-server.sh` 启动时会自动将 `patches/` 目录下的 `.patch` 文件应用到对应 submodule。

**原理**：`.patch` 文件是 `git diff` 的输出快照（unified diff 格式，纯文本，不是二进制）。生成方式：

```bash
cd modules/actual-mcp
git diff > ../../patches/actual-mcp.patch
cd modules/actual-server
git diff > ../../patches/actual-server.patch
```

由于 `actual-mcp` 和 `actual-server` 是第三方开源项目的 submodule，我们没有推送权限，无法直接提交修改。用 patch 文件保存差异，`git clone --recurse-submodules` 后 submodule 是干净的官方代码，启动脚本自动 apply 补丁。

**`patches/actual-mcp.patch` 包含的修改**：
- `@actual-app/api` 版本升级（26.3.0 → 26.5.2）
- v25 → v26 import 路径迁移（`@actual-app/api/@types/...` → `@actual-app/core/...`）
- `downloadBudget` 按 groupId 匹配而非 cloudFileId
- `BudgetFile` 接口增加 `groupId`、`encryptKeyId` 字段
- 其他工具函数的类型修正（`TransactionEntity` 路径变更等）

**`patches/actual-server.patch`** 包含相同的 API 适配改动（`actual-server` 中也有调用 Actual API 的 TypeScript 代码）。

**格式解读**（unified diff）：

```diff
--- a/package.json        # 原始文件（a）
+++ b/package.json        # 修改后（b）
@@ -33,7 +33,7 @@          # 改动在原始文件第33行起，涉及7行
-    "@actual-app/api": "^26.3.0",   # - 删掉的行
+    "@actual-app/api": "^26.5.2",   # + 新增的行
```

不带 `-`/`+` 前缀的行是上下文（用于 Git 定位行号）。`package-lock.json` 的差异太大，Git 自动切换为 binary patch（压缩格式），所以打开看起来是乱码，但 `git apply` 能正确还原。

启动脚本中的 apply 逻辑是幂等的——已应用则自动跳过：

```bash
if git apply --check "$PATCHES_DIR/actual-mcp.patch" 2>/dev/null; then
  git apply "$PATCHES_DIR/actual-mcp.patch"
else
  echo "    Patch already applied or not needed."
fi
```

#### polyfill.cjs — Node.js 中注入浏览器 API

根目录的 `polyfill.cjs`（248 字节），在 Node.js 启动时通过 `--require` 预加载，注入 `@actual-app/api` 需要的浏览器全局对象：

```javascript
// polyfill.cjs
if (typeof globalThis.navigator === "undefined") {
  globalThis.navigator = {
    platform: process.platform,
    userAgent: "node",
    language: "en",
    languages: ["en"],
  };
}
```

**为什么用 `.cjs` 后缀**：`actual-mcp/package.json` 声明了 `"type": "module"`，所有 `.js` 文件被当作 ESM。但 `--require` 使用 CommonJS `require()` 加载，无法加载 ESM。`.cjs` 强制以 CommonJS 方式处理。

启动脚本中通过绝对路径加载（`fnm exec` 可能改变工作目录，必须用绝对路径）：

```bash
NODE_OPTIONS="--require $SCRIPT_DIR/polyfill.cjs" \
fnm exec --using=22 node build/index.js --sse --port 3000 --enable-write
```

#### custom-sw.js — 自毁式 Service Worker

根目录的 `custom-sw.js`（551 字节），替换 Actual Budget 自带的 Workbox Service Worker。

**问题**：Actual 原版 SW 使用 Workbox 激进缓存策略，导致浏览器强制刷新（Cmd+Shift+R）都加载不出新内容，开发时必须手动进 DevTools 删除 SW 和缓存。

**解决**：自毁式 SW，一次激活后自动清除所有缓存并永久注销自身：

```javascript
self.addEventListener('install', () => {
  self.skipWaiting();         // 立即接管，不等旧 SW 释放
});
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then(cacheNames => {
      return Promise.all(cacheNames.map(name => caches.delete(name)));
    }).then(() => self.registration.unregister())  // 永久注销
  );
});
```

启动脚本自动部署：

- **Docker 模式**：通过 `sed` 向 `docker-compose.yml` 注入 volume mount，挂载到容器内覆盖原版 `sw.js`
- **原生模式**：在 `yarn install` 后直接 `cp` 到 `node_modules/@actual-app/web/build/sw.js`

### 环境变量

| 变量 | 说明 | 示例 |
|---|---|---|
| `ACTUAL_SERVER_URL` | actual-server 地址 | `http://localhost:5006` |
| `ACTUAL_PASSWORD` | 登录密码 | `leon0930` |
| `ACTUAL_BUDGET_SYNC_ID` | 指定预算文件 groupId（不设则用第一个） | `6e7e4c43-...` |
| `ACTUAL_BUDGET_ENCRYPTION_PASSWORD` | 预算加密密码（仅当与登录密码不同时） | - |
| `--enable-write` | 开启写操作工具（否则只有 8 个只读） | - |
| `--enable-bearer` | 公网部署时开启 Bearer Token 认证 | - |
| `BEARER_TOKEN` | Bearer Token 值（公网必设） | 随机长字符串 |

### 踩坑记录

#### 1. 版本不匹配导致 out-of-sync-migrations

**现象**：`download-budget` 报 `Budget not found` 或 `out-of-sync-migrations`。

**原因**：Docker 镜像 `actualbudget/actual-server:latest` 实际是 v26.5.2，而 `@actual-app/api` 默认 v26.3.0。Web 前端写入的 SQLite 数据库包含 API 不认识的 migration 记录（`1768872504000`、`1769000000000`）。

**解决**：将 `@actual-app/api` 升级到与服务器镜像一致的版本：
```bash
npm install @actual-app/api@26.5.2
```

#### 2. downloadBudget 用错参数：cloudFileId vs groupId

**现象**：`getBudgets()` 返回了预算列表，但 `downloadBudget()` 报 `Budget not found`。

**原因**：`getBudgets()` 返回 `cloudFileId`（文件 ID）和 `groupId`（同步组 ID）两个字段。但 `downloadBudget()` 内部按 `groupId` 匹配，而 MCP 代码只取了 `cloudFileId` 或 `id`。

源码分析（`@actual-app/api` bundle）：
```javascript
// get-budgets handler 合并本地 + 远程文件
handlers["api/get-budgets"] = async function () {
    const budgets = await handlers["get-budgets"]();       // 本地
    const files = await handlers["get-remote-files"]();     // 服务器
    return [...budgets.map(budgetModel.toExternal), ...files.map(remoteFileModel.toExternal)];
};

// remoteFileModel.toExternal 字段映射
// fileId    → cloudFileId
// groupId   → groupId

// download-budget handler 按 groupId 查
handlers["api/download-budget"] = async function ({ syncId, password }) {
    const localBudget = budgets.find((b) => b.groupId === syncId);    // ← 用 groupId
    if (!localBudget) {
        const file = files.find((f) => f.groupId === syncId);         // ← 用 groupId
    }
};
```

**修复**（`src/actual-api.ts`）：
```typescript
// 修复前
const budgetId = budgets[0].cloudFileId || budgets[0].id || '';
// 修复后
const budgetId = budgets[0].groupId || budgets[0].cloudFileId || budgets[0].id || '';
```

#### 3. 预算文件只存在浏览器 IndexedDB，服务器不知道

**现象**：Web UI 能看到预算和交易，但 MCP 连不上（`No budgets found`）。

**原因**：预算文件分两种——本地文件（浏览器 IndexedDB）和服务器文件（同步到 actual-server）。只有服务器文件才能被 MCP 读取。

**解决**：在 Web UI 中创建服务器文件（Server File），或把本地文件上传到服务器。

验证方法：
```bash
sqlite3 actual-data/server-files/account.sqlite "SELECT * FROM files;"
# 有行 → 服务器有文件；空 → 浏览器本地文件
```

#### 4. v25.x 和 v26.x 的 API 类型路径完全不同

**v25.x**：类型在 `@actual-app/api/@types/loot-core/` 下，路径深且分散。

**v26.x**：类型重构到 `@actual-app/core` 独立包中。

| 想导入的类型 | v25.x 路径 | v26.5.x 路径 |
|---|---|---|
| APIAccountEntity | `@actual-app/api/@types/loot-core/server/api-models` | `@actual-app/core/server/api-models` |
| TransactionEntity | `@actual-app/api/@types/loot-core/types/models` | `@actual-app/core/types/models/transaction` |
| RuleEntity | 同上 | `@actual-app/core/types/models/rule` |
| ImportTransactionEntity | `@actual-app/api/@types/loot-core/src/types/models/import-transaction` | `@actual-app/core/types/models/import-transaction` |

#### 5. `navigator is not defined` — @actual-app/api 含浏览器专用代码

**现象**：启动 MCP 服务器时报 `ReferenceError: navigator is not defined`。

**原因**：`@actual-app/api` v26.5.2 打包时混入了 Actual 前端代码，模块顶层直接引用了 `navigator.platform`、`navigator.userAgent` 等浏览器 API，Node.js 中没有这些全局对象。

**解决**：创建 polyfill 文件（现位于项目根目录 `polyfill.cjs`），用 `NODE_OPTIONS="--require"` 在模块加载前注入。详见上方「polyfill.cjs」章节。

#### 6. `require() of ES Module not supported` — polyfill 文件后缀

**现象**：`Error [ERR_REQUIRE_ESM]: require() of ES Module polyfill.js not supported`。

**原因**：`actual-mcp/package.json` 中声明了 `"type": "module"`，所有 `.js` 文件被当作 ESM 处理。而 `--require` 使用 CommonJS `require()` 加载，无法加载 ESM 模块。

**解决**：将 polyfill 文件改名为 `.cjs`（CommonJS 后缀），强制以 CJS 方式加载。详见上方「polyfill.cjs」章节。

#### 7. SSE 端点和 Streamable HTTP 端点混淆

**现象**：Python 客户端连 `http://localhost:3000/mcp` 时报 `httpx.ConnectError: All connection attempts failed`，或卡住无响应。

**原因**：actual-mcp 暴露了两套传输协议：
- **Legacy SSE**：`GET /sse` 建立 SSE 长连接，POST `/messages?connectionId=xxx` 发送请求
- **Streamable HTTP**：`/` 和 `/mcp` 路径，用 `mcp-session-id` header 管理会话

Python 代码使用 `mcp.client.sse.sse_client`（SSE 传输），但 `ACTUAL_API_URL` 错误地指向了 `/mcp`（Streamable HTTP 端点）。`/mcp` 不是 SSE 端点，无法建立 SSE 连接。

**解决**：`constants.py` 中将 URL 改为 SSE 端点：
```python
ACTUAL_API_URL = "http://localhost:3000/sse"  # 不是 /mcp
```

#### 8. `session.initialize()` 卡死 — 未启动 `_receive_loop`

**现象**：SSE 连接建立成功（收到 endpoint 事件），但 `await self._session.initialize()` 永久挂起，无任何报错。

**原因**：`ClientSession` 继承自 `BaseSession`，其 `__aenter__()` 方法负责启动 `_receive_loop`（消息接收循环）。`_receive_loop` 持续从 `_read_stream` 读取服务器响应并路由给对应请求。如果不进入 context manager，`_receive_loop` 永远不启动，`initialize()` 发出去的 `InitializeRequest` 收不到响应，无限等待。

源码（`mcp/shared/session.py:221-225`）：
```python
async def __aenter__(self) -> Self:
    self._task_group = anyio.create_task_group()
    await self._task_group.__aenter__()
    self._task_group.start_soon(self._receive_loop)  # ← 关键行
    return self
```

**解决**：`actual_api.py` 中手动调用 `__aenter__` 和 `__aexit__`：
```python
# connect()
self._session = ClientSession(self._read, self._write)
await self._session.__aenter__()  # 手动启动 _receive_loop

# disconnect()
await self._session.__aexit__(None, None, None)
```

#### 9. SSE transport 被 GC 回收导致写入失败

**现象**：`session.initialize()` 成功后，调用 `list_tools()` 时报 `asyncio.exceptions.CancelledError` 或 `WouldBlock`。

**原因**：`sse_client()` 返回一个 async generator（`@asynccontextmanager`），其内部 `anyio.create_task_group()` 管理着 `sse_reader` 和 `post_writer` 两个后台任务。如果 transport 对象在 `connect()` 返回后被 Python GC 回收，会触发 `GeneratorExit`，导致 task group 被取消，后台任务停止，后续消息无法收发。

**解决**：将 transport 存为实例属性，生命周期与会话一致：
```python
self._transport = sse_client(url=self.mcp_url)  # 存为实例属性，防 GC
self._read, self._write = await self._transport.__aenter__()
```

#### 10. JSON Schema `type: ["string", "null"]` 转换失败

**现象**：`create-rule` 和 `update-rule` 两个工具转换失败，报 `TypeError: unhashable type: 'list'`。

**原因**：`_json_type_to_python()` 中 `t = schema.get("type", "string")` 拿到的值可能是 `["string", "null"]` 这种数组（JSON Schema union 类型），直接把这个 list 当字典 key 用 `_JSON_TYPE_MAP.get(t, str)` 就报错了。

**解决**：添加数组类型的处理，取第一个非 `"null"` 的类型：
```python
if isinstance(t, list):
    for item in t:
        if item != "null":
            t = item
            break
    else:
        t = "string"
```

#### 11. Node.js 版本不兼容 — 需要 v20+

**现象**：MCP 连接和工具发现正常，但实际调用工具时报 Node.js 版本相关错误（Actual API 初始化失败）。

**原因**：`@actual-app/api` v26.x 要求 Node.js 20 或更高版本。本机通过 fnm 安装了 v18.14.0 和 v22.22.3 两个版本，终端默认使用 v18。

**解决**：启动脚本中使用 `fnm exec --using=22` 强制用 Node 22 启动 MCP：
```bash
fnm exec --using=22 node build/index.js --sse --port 3000 --enable-write
```

#### 12. DeepSeek thinking 模式 + LangChain 不兼容

**现象**：使用 `deepseek-v4-flash` 等支持 thinking 模式的模型时，ReAct agent 内部多轮工具调用中报错：

```
Error code: 400 - {'error': {'message': 'The `reasoning_content` in the thinking mode
must be passed back to the API.', 'type': 'invalid_request_error'}}
```

**原因**：DeepSeek thinking 模式下，模型响应中包含 `reasoning_content` 字段（推理过程），且要求后续请求中必须回传该字段。LangChain 的 `ChatOpenAI` 在序列化 `AIMessage` 时不会保留 `reasoning_content`，导致 ReAct agent 在第二轮 LLM 调用时被 DeepSeek 拒绝。

错误发生在 agent 内部的工具调用循环中：LLM 第一次返回 tool call → 执行工具 → 将结果和之前的消息一起发给 LLM → DeepSeek 发现上一条 assistant 消息缺了 `reasoning_content` → 报错。

**解决**：通过 `extra_body` 参数禁用 thinking 模式（非思维链模型的关键参数用 `extra_body`，不能用 `model_kwargs`）：

```python
self.llm = ChatOpenAI(
    model="deepseek-v4-flash",
    base_url=LLM_URL,
    api_key=LLM_KEY,
    temperature=0,
    extra_body={"thinking": {"type": "disabled"}},  # ← 关键
)
```

**注意**：`langchain-openai` 中 `extra_body` 和 `model_kwargs` 的区别：
- `model_kwargs` — 传给底层 openai SDK `create()` 方法的**函数参数**（如 `stream_options`）
- `extra_body` — 放入 HTTP 请求体的**自定义字段**（如 DeepSeek 的 `thinking`）

如果用 `model_kwargs={"thinking": ...}` 会报 `AsyncCompletions.create() got an unexpected keyword argument 'thinking'`。

#### 13. Ctrl+C 退出混乱 — `CancelledError` 未捕获

**现象**：REPL 中按 Ctrl+C 退出时，出现大量异常堆栈（`CancelledError` → `KeyboardInterrupt`），需要按两次才能退出，且最后仍有残留的 `KeyboardInterrupt`。

**原因**：Python 3.12 的 `asyncio.to_thread` 在收到 `KeyboardInterrupt` 后，向正在运行的任务抛出 `asyncio.CancelledError`（而非 `KeyboardInterrupt`）。原来的 `except` 只捕获了 `EOFError, KeyboardInterrupt`，`CancelledError` 向上传播导致 `asyncio.run` 在 shutdown 阶段再次收到 `KeyboardInterrupt`。

**解决**：在 REPL 内层 `try/except` 中增加 `asyncio.CancelledError` 的捕获：

```python
try:
    user_input = (await ainput("你：")).strip()
except (EOFError, KeyboardInterrupt, asyncio.CancelledError):
    print("\n👋 再见！")
    return
```

此外，`repl()` return 后，`asyncio.run()` 在 `Runner.close()` 阶段做事件循环清理时仍可能收到第二次 `KeyboardInterrupt`。需要在 `main()` 最外层兜底：

```python
try:
    asyncio.run(repl())
except KeyboardInterrupt:
    pass
```

#### 14. 去掉 Docker 依赖 — actual-server 双模式兼容运行

**问题**：Docker Desktop 空跑就占 8GB 内存，16GB 机器上经常爆黄导致其他应用闪退。而项目实际只有 `actual-server` 一个组件在用 Docker。

**分析**：`actual-server` 本质是标准 Node.js 应用（Express + better-sqlite3），`app.js` → `src/app.js`，完全可以直接跑。Docker 镜像做的事无非是 `yarn install` + `node app.js`。

**改造方案**：保留两种运行模式，自动检测。`start-server.sh` 启动时先 `docker info` 检测 Docker 是否可用，有则用容器（不动已有环境），无则自动降级为原生 Node.js。数据目录 `actual-data/` 两种模式完全兼容，随时切换。

**原生模式的改造要点**：

1. **依赖安装**：项目自带 Yarn Berry vendored（`.yarn/releases/yarn-4.3.1.cjs`），无需全局安装任何工具。`node .yarn/releases/yarn-4.3.1.cjs install` 即可。

2. **数据目录**：原 Docker 通过 volume `./actual-data:/data` 挂载，`load-config.js` 检测 `/data` 目录存在则用它。原生运行时 `/data` 不存在，自动回退到项目根目录，但实际数据在 `actual-data/`。通过 `ACTUAL_DATA_DIR=./actual-data` 环境变量指定即可兼容已有数据。

3. **自定义 Service Worker**：
   - Docker 模式：通过 `sed` 向 `docker-compose.yml` 注入 volume mount
   - 原生模式：`yarn install` 后直接 `cp` 到 `node_modules`

4. **缺失的 migration 文件**：`actual-server` git 仓库已归档，Docker 镜像实际来自新的 `actual/actual` monorepo，比 submodule 多出两个 migration：
   - `1763873568237-server-global-prefs.js`
   - `1763873600000-backfill-files-owner.js`
   
   从 Docker 镜像提取后放入 `patches/actual-server.patch`，启动脚本自动 apply。同时修复了文件中的 import 问题（新 migration 用 named import `{ getAccountDb }`，但旧版代码是 default export）。

5. **原生启动命令**：
   ```bash
   cd modules/actual-server
   ACTUAL_DATA_DIR=./actual-data fnm exec --using=22 node app.js
   ```

**效果**：Docker Desktop 可以关闭节省 8GB 内存，`actual-server` 原生运行时内存不到 100MB。如果之后想用回 Docker，只需启动 Docker Desktop，脚本自动切回容器模式。

```bash
# MCP 内部连通性测试
cd modules/actual-mcp
ACTUAL_SERVER_URL=http://localhost:5006 ACTUAL_PASSWORD=你的密码 node build/index.js --test-resources
# 期望输出: Found X account(s)

# Python MCP 客户端测试
uv run python src/server/test_mcp.py
# 期望输出: 成功拉取到 25 个工具
```

### 搬到云服务器

改动很少，主要是环境变量调整：

| 项目 | 本地值 | 云部署值 |
|---|---|---|
| `ACTUAL_SERVER_URL` | `http://localhost:5006` | `https://your-domain.com` |
| `ACTUAL_PORT` | 5006 | 5006（或自定义） |
| `BEARER_TOKEN` | 不设 | **必须设置**（随机长字符串） |
| `--enable-bearer` | 不加 | **必须加** |

额外的部署工作：
1. actual-server 前面挂 nginx/Caddy 做 HTTPS 反向代理
2. actual-mcp 开启 `--enable-bearer` + `BEARER_TOKEN`
3. 持久化 `actual-data/` 目录到云盘（SQLite 都在里面）

#### 15. Flutter 客户端不支持 Markdown 渲染

**现象**：LLM 返回的 Markdown 内容（标题、代码块、列表、加粗等）在 Flutter 客户端中显示为原始文本，所有格式语法肉眼可见。

**原因**：AI 回复通过 `ChatBubble` 组件渲染，内部使用 Flutter 原生 `Text` widget 直接展示 `message.content`，没有任何 Markdown 解析。

**解决**：添加 `flutter_markdown` 依赖，创建 `AiMessage` 组件，用 `MarkdownBody` 替代 `Text` 渲染 AI 回复：

```dart
// pubspec.yaml 新增
flutter_markdown: ^0.7.6

// ai_message.dart — AI 回复专用组件
MarkdownBody(
  data: message.content,
  selectable: true,
  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
)
```

#### 16. Flutter 客户端用户消息发送后不显示

**现象**：用户在输入框发送消息后，消息凭空消失，对话列表中只能看到 AI 的回复，看不到自己发了什么。

**原因**：`_sendMessage` 中只调用了 `_chatService.sendMessage(text)` 将消息发往 Socket.IO 服务端，但没有创建 `ChatMessage` 对象加入本地的 `_messages` 列表。消息发出去了，但 UI 不知道它的存在。

**解决**：在发送前先将用户消息作为 `ChatMessage` 加入 `_messages`，再调用 `setState` 触发重绘：

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

#### 17. Flutter 客户端消息布局改造 — 用户气泡 + AI 整块显示

**需求**：用户消息用气泡形式回显（右对齐、彩色背景），AI 回复不用气泡，直接在下方整块区域显示 Markdown 内容（类似 Gemini / ChatGPT 的交互方式）。

**改动**：

- `ChatBubble` 简化为仅处理用户消息（右对齐 + 紫色背景气泡）
- 新建 `AiMessage` 组件：无气泡包裹，全宽 `MarkdownBody` 渲染，流式传输时尾部显示闪烁光标
- `HomeScreen` 的 `ListView.builder` 按 `message.role` 分流——`user` 用 `ChatBubble`，`assistant` 用 `AiMessage`

#### 18. Python 导入层级错误 — `ModuleNotFoundError: No module named 'server'`

**现象**：`./start-server.sh` 启动时报 `ModuleNotFoundError: No module named 'server'`。

**原因**：项目结构为 `src/server/`（server 包在 src 目录下），但 `src/server/` 内部所有文件使用绝对导入 `from server.xxx import ...`，Python 无法在顶层找到 `server` 包。

**解决**：`src/server/` 包内部改用相对导入，外部引用改用全路径：

| 文件 | 修复前 | 修复后 |
|------|--------|--------|
| `src/server/server.py` | `from server.agent import Agent` | `from .agent import Agent` |
| `src/server/agent.py` | `from server.actual_api import ...` | `from .actual_api import ...` |
| `src/server/actual_api.py` | `from server.constants import ...` | `from .constants import ...` |
| `src/client/chainlit_web.py` | `from server.agent import Agent` | `from src.server.agent import Agent` |

#### 19. 服务端 Ctrl+C 退出报 traceback

**现象**：`./start-server.sh` 运行后按 Ctrl+C，出现 `CancelledError` → `KeyboardInterrupt` 异常堆栈，看起来像崩溃。

**原因**：`uvicorn.Server.run()` 内部用 `asyncio.run()` 运行，收到 SIGINT 后抛出 `KeyboardInterrupt`，而 `main()` 函数没有捕获。

**解决**：在 `_server_instance.run()` 外层加 `try/except KeyboardInterrupt`：

```python
try:
    _server_instance.run()
except KeyboardInterrupt:
    logger.info("Server stopped.")
```
