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

## 框架

### 前端

#### web 交互：[chainlit](https://github.com/chainlit/chainlit)

### 后端

#### 日志打印：[loguru](https://github.com/Delgan/loguru)

---

## 财务记账：Actual Budget + MCP

使用 [Actual Budget](https://actualbudget.org/) 作为记账后端，通过 MCP Server 让 LLM（Claude Desktop / Codex 等）用自然语言读写财务数据。

### 架构

```
┌─────────────┐   HTTP/5006    ┌──────────────────┐   MCP/stdio/SSE   ┌──────────────┐
│ actual-server │ ◄──────────── │   actual-mcp      │ ◄─────────────── │  Claude       │
│ (Docker)     │               │  (Node.js)        │                  │  Desktop      │
│ SQLite 存储   │               │  @actual-app/api  │                  │  / Codex      │
│ Web UI       │               │  25 个 MCP tools   │                  │              │
└─────────────┘               └──────────────────┘                  └──────────────┘
```

- **actual-server**（`/modules/actual-server`）：官方同步服务器，内置 Web 前端。存放预算文件（SQLite），提供 HTTP API。
- **actual-mcp**（`/modules/actual-mcp`）：社区 MCP Server，把 Actual API 包装成 MCP 协议，暴露 25 个工具（读写交易、分类、收款人、规则、银行同步等）。

### 初次部署

从零开始在一台新机器（或云服务器）上部署整个项目。

#### 环境要求

- **Docker** — 运行 actual-server
- **Node.js 22+** — 运行 actual-mcp（推荐 [fnm](https://github.com/Schniz/fnm) 管理版本）
- **Python 3.12+** — 运行 Jarvis REPL
- **uv** — Python 包管理器

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

#### 3. 启动 MCP 基础设施

```bash
./start-mcp.sh
```

这个脚本会自动完成：
1. 将 `patches/` 中的修复补丁应用到 submodule（无需手动改 submodule 代码）
2. 安装 npm 依赖 + 编译 TypeScript
3. 启动 actual-server Docker 容器
4. 启动 actual-mcp SSE 服务（端口 3000，Node 22）

#### 4. 创建预算文件

浏览器打开 `http://localhost:5006`，设置登录密码，**创建服务器端文件**（Server File），不能是仅浏览器本地存储的文件，否则 MCP 读不到。

#### 5. 启动 Jarvis

```bash
uv run src/main.py
```

### 日常启动

第二次及以后启动，只需两步：

```bash
# 终端 1：启动 MCP 基础设施（Docker + MCP SSE）
./start-mcp.sh

# 终端 2：启动 Jarvis REPL
uv run src/main.py
```

停止：

```bash
./stop-mcp.sh          # 停止 MCP 和 Docker
# Jarvis 终端按 Ctrl+C 退出
```

### 部署架构细节

#### actual-server

```bash
cd modules/actual-server
docker compose up -d
```

服务跑在 `http://localhost:5006`。

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

`start-mcp.sh` 启动时会自动将 `patches/` 目录下的 `.patch` 文件应用到对应 submodule。这解决了两个问题：

- submodule 的第三方仓库我们没有推送权限，无法提交修复
- `git clone` 后 submodule 是干净的官方代码，需要补丁才能正常运行

补丁文件（`patches/actual-mcp.patch`）包含：
- `@actual-app/api` 版本升级（26.3.0 → 26.5.2）
- v25 → v26 import 路径迁移
- `downloadBudget` groupId 修复
- 其他工具函数的类型修正

重启时如果补丁已应用，脚本会自动跳过。

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

**解决**：创建 polyfill 文件 `modules/actual-mcp/polyfill.cjs`，用 `NODE_OPTIONS="--require"` 在模块加载前注入：

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

`start-mcp.sh` 中通过环境变量加载：
```bash
NODE_OPTIONS="--require $MCP_DIR/polyfill.cjs" \
node build/index.js --sse --port 3000 --enable-write
```

#### 6. `require() of ES Module not supported` — polyfill 文件后缀

**现象**：`Error [ERR_REQUIRE_ESM]: require() of ES Module polyfill.js not supported`。

**原因**：`actual-mcp/package.json` 中声明了 `"type": "module"`，所有 `.js` 文件被当作 ESM 处理。而 `--require` 使用 CommonJS `require()` 加载，无法加载 ESM 模块。

**解决**：将 polyfill 文件改名为 `.cjs`（CommonJS 后缀），强制以 CJS 方式加载。

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

**解决**：`start-mcp.sh` 中使用 `fnm exec --using=22` 强制用 Node 22 启动 MCP：
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

### 验证连接

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
