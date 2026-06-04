# Jarvis Ⅱ

## 快速开始（新机器）

### 前置要求

- Python 3.12+
- [uv](https://docs.astral.sh/uv/getting-started/installation/)
- Git
- Flutter SDK（只在你要跑 Flutter 客户端时需要）
- CocoaPods（只在你要跑 Flutter macOS 客户端时需要）

### 1. 克隆仓库

```bash
git clone <repo-url>
cd jarvis-custom
```

普通 `git clone` 即可。`./start-server.sh` 和 `./start-client.sh -repl/-chainlit` 会在首次运行时自动补 `git submodule update --init --recursive`，避免 `uv` 工作区因为 submodule 未初始化而直接报错。

### 2. 可选环境变量

```bash
cp .env.example .env
```

- LLM 凭据不再要求手动写进 `.env`，启动后可在设置页录入，系统会保存到 `data/credentials.yaml`
- `.env` 目前主要给 Google Calendar OAuth 使用

### 3. 启动服务端

```bash
./start-server.sh
```

### 4. 启动客户端

```bash
# Flutter Web（默认）
./start-client.sh

# Flutter macOS
./start-client.sh -macos

# 终端 REPL
./start-client.sh -repl

# Chainlit Web
./start-client.sh -chainlit
```

### 5. 验证后端

```bash
uv run python .claude/skills/run-jarvis/run_jarvis_smoke.py
```

这是主 smoke test，会启动服务端并验证健康检查、备忘录、提醒事项和上传接口。

## 工程可用性修复记录

### 42. 普通 clone 后 uv 工作区会因为 submodule 未初始化而启动失败

**现象**：新机器只执行 `git clone`，随后直接运行 `uv run ...` 或启动脚本时，`chainlit` / `loguru` 工作区依赖可能因为本地 submodule 目录为空而失败。

**解决**：在 `start-server.sh` 和 `start-client.sh` 中增加 submodule 自检与自动初始化逻辑。首次运行发现 `modules/chainlit` 或 `modules/loguru` 缺失时，会自动执行 `git submodule update --init --recursive`。

### 43. 新环境首次安装后会缺少显式依赖

**现象**：本地旧环境可能因为装过其他包而“看起来没问题”，但新同学首次安装依赖时，容易在以下位置报错：

- `python-dotenv` 缺失，服务端/终端客户端在 `load_dotenv()` 处导入失败
- `httpx` 缺失，Google Calendar 同步相关接口不可用
- `python-multipart` 缺失，FastAPI 上传接口无法接收文件

**解决**：在 `pyproject.toml` 中将这些运行时依赖显式声明，避免依赖旧虚拟环境里的隐式残留包。

### 44. smoke test 仍在调用旧的 memos/reminders 接口

**现象**：`uv run python .claude/skills/run-jarvis/run_jarvis_smoke.py` 能把服务启动起来，但在 CRUD 阶段会因为 `POST /api/memos` 返回 404 而失败。

**原因**：服务端 REST API 已经统一重命名为 `assets` / `todos`，而 smoke 脚本还停留在旧的 `memos` / `reminders` 路由。

**解决**：将 smoke 脚本全部切换为当前真实接口：`/api/assets`、`/api/todos` 和 `/api/todos/{id}/complete`，让仓库 README 中推荐的验证命令重新可用。

### 45. smoke test 在 /stop 后误判服务没有退出

**现象**：主流程已经全部通过，但 `proc.wait(timeout=10)` 仍可能超时，导致 smoke 在最后一步失败。

**原因**：测试脚本启动的是 `uv run python -m src.server.server`。在部分环境里，真正监听 8000 端口的服务进程已经停掉了，但外层 `uv` 包装进程回收得比子进程更慢，直接 `wait()` 容易误报。

**解决**：在 smoke 最后一段先轮询 `/health`，确认服务端已经真正下线，再等待并回收外层进程；若包装进程仍然滞留，则由 smoke 主动 `terminate()`/`kill()` 完成清理。

### 46. 服务端退出兜底线程缺少 `time` 导入

**现象**：`/stop` 后 Uvicorn 日志已经显示应用关闭，但 Python 外层进程仍可能卡住不退出。

**原因**：`server.py` 的 `finally` 里启了一个 `time.sleep(3)` 后 `os._exit(0)` 的兜底线程，但文件顶部漏了 `import time`，导致这个兜底路径根本跑不起来。

**解决**：在 `src/server/server.py` 补上 `import time`，确保强制退出兜底线程在极端情况下可用。

这份更新后的技术架构设计规范已经完全重构。它移除了“强行让 DeepSeek 读图”的错误假设，全面升级为**基于标准 OpenAI 规范的多模型动态路由与 macOS 本地双轨制清洗/OCR 降级闭环系统**。

你可以将以下内容直接完整地复制并交付给 **Codex 或其他 AI 编码代理**，作为其构建核心底层代码的绝对准则。

---

## 🧭 核心架构：ModelGateway 统一大模型路由网关

`src/server/gateway.py` 作为一个模块级单例，接收上游传入的统一标准参数（`api_key`, `base_url`），基于标准 `openai` 客户端规范进行全局调度。它不亲自解析文件，而是作为”分诊台”，根据**任务类型（TaskType）**和**文件特征**进行动态路由分发。

### 🔄 TaskType → 模型智能流转矩阵：

| TaskType | 推荐模型 | 原生视觉 | thinking | 用途 |
| --- | --- | --- | --- | --- |
| **TEXT** | `deepseek-v4-flash` | 否 | 关闭 | 纯文本分类摘要、管道A/B + 管道D纯文字分支、Agent对话。成本低。 |
| **MULTIMODAL** | `gemini-2.5-flash` | **是** | 关闭 | 管道C视觉识别、管道D图文/扫描件处理。多模态模型，兼具文本分析能力。 |

---

## 🛠️ 第一部分：系统级依赖与环境声明

在工程的 `requirements.txt` 或 `setup.py` 中，AI 编码代理需要配置以下依赖。所有核心解析库均采用纯 Python 库或 macOS 原生动态库的 Python 桥接：

```text
# 核心大模型客户端（全线收拢至标准 OpenAI 接口协议规范）
openai>=1.0.0

# macOS 底层图形与视觉内核桥接（打包时零体积压力，完全免除 poppler/LibreOffice 依赖）
pyobjc-framework-Quartz
pyobjc-framework-Vision
pyobjc-core

# 本地轻量化结构提取与基础预处理库
pypdf>=4.0.0
python-pptx>=0.6.21
pandas>=2.0.0
openpyxl>=3.1.0
pillow>=10.0.0
beautifulsoup4>=4.12.0
markdownify>=0.11.0

```

---

## 📊 第二部分：不同文件管道（Pipeline）的数据清洗规范

Codex 在实现 `src/server/file_watcher.py` 的文件扫描监控时，应严格执行以下四种数据清洗管道，将 21 种后缀收敛至 **“纯文本/Markdown 块”** 或 **“静态图片文件路径列表”** 两个终点：

### 管道 A：纯文本直通车

* **涵盖格式**：`.md`, `.markdown`, `.txt`, `.json`, `.xml`, `.csv`, `.ics`
* **清洗策略**：直接读取底层字符流，过滤 UTF-8 炸弹头（BOM），不做任何多余的视觉转换。
* **格式规整**：为了增强大模型的图谱注意力，对结构化文本进行 Markdown 包裹：
* `.json` $\rightarrow$ 增加 ````json` 代码块包裹。
* `.csv` $\rightarrow$ 优先读取前两行，若数据量极小维持原样，否则转为 Markdown 表格语法。
* `.ics` $\rightarrow$ 纯文本直读，保持 iCalendar 结构原样投喂。



### 管道 B：结构化文本清洗（白嫖 Mac 内置内核）

* **涵盖格式**：`.html`, `.htm`, `.docx`, `.doc`
* **清洗策略**：剔除样式、噪点和多余的 DOM 标签，精简为线性文本。
* **工程实现**：
* **HTML 系列**：使用 `BeautifulSoup` 强制剔除 `<script>`, `<style>`, `<meta>` 标签，随后使用 `markdownify` 将其余 DOM 树转换为干净的 Markdown 文本。
* **Word 系列 (`.doc / .docx`)**：彻底拒绝 LibreOffice。直接利用 macOS 系统自带的命令行工具 `textutil` 执行静默转换：`textutil -convert txt -output {temp_path} {file_path}`。**实现毫秒级无依赖读取**。



### 管道 C：原生多模态视觉预处理

* **涵盖格式**：`.jpg`, `.jpeg`, `.png`, `.webp`, `.gif`
* **清洗策略**：将图像像素矩阵规整为标准的 Base64 编码流。
* **工程实现**：
* **GIF 动图防报错机制**：利用 `Pillow` 库读取图片，若检测为动画（`is_animated`），则提取其 **第一帧** 或 **核心帧** 并将其转为静态 PNG 再输出 Base64，彻底规避 OpenAI 规范接口接收动图时崩溃的隐患。



### 管道 D：复杂排版与多模态双轨渲染（高级核心）

* **涵盖格式**：`.pdf`, `.pptx`, `.ppt`, `.xlsx`, `.xls`
* **清洗策略**：分离文档中的“原生文本”与“视觉图表”，为网关决策提供数据支撑。
* **工程实现**：
* **PDF 文本抽取**：通过 `pyobjc` 调用 Mac 的 `Quartz` 内核，循环 `PDFDocument` 对象的 `page.string()`，直接提取无错别字的原生文本。
* **PPTX 文本抽取**：使用 `python-pptx` 遍历每页 Slide 的 `shapes`，提取 `has_text_frame` 的实体文字，按幻灯片序号拼接。
* **Excel 结构提取**：使用 `pandas` 的 `read_excel` 批量加载所有 Sheets，并调用 `.to_markdown(index=False)` 动态转化为标准的 Markdown 数据表格。



---

## 🧠 第三部分：智能网关（Gateway）分配与路由决策树

网关在接收到清洗后的中间数据时，需要结合 **模型视觉能力（Vision Support）** 和 **文件视觉元素探测（Visual Element Detection）** 进行动态编排。

### 1. 模型视觉能力判定（模糊匹配规则）

网关通过字符串检索自动推断用户的模型能力：

* 只要模型名字包含 `gpt-4o`, `vision`, `-vl`, `gemini`, `claude-3-5`，则默认 `supports_vision = True`。
* 遇到强文本特例（如 `deepseek` 关键字），强制重置 `supports_vision = False`。

### 2. 视觉元素探测（Visual Element Detection）

在处理 PDF 和 PPTX 时，毫秒级扫描其内部是否含有内嵌图片、统计图表或不可直接提取的视觉区：

* **PDF**：检查 `page.images` 字典数量是否大于 0。
* **PPTX**：检查 `shape.has_chart` 是否为 True，或 `shape.shape_type == 13`（图片类型）。

---

### 🔀 3. 终极网关分配矩阵与思考程度（Thinking Mode）配置

网关根据矩阵结果，拼装不同的 OpenAI 请求 Payload，并动态管理 **DeepSeek 的推理模式（Thinking Mode）** 门槛。同时处理长对话历史中的 `reasoning_content` 清洗防御，避免 400 报错。

| 文件特征 | 模型能力 | 网关分发路径 | 思考程度配置 (`thinking`) | 业务逻辑设计（防信息丢失与幻觉控制） |
| --- | --- | --- | --- | --- |
| **纯文本/常规文本**<br>

<br>(管道 A/B/D 有字无图) | **任意模型** | **纯文本通道**<br>

<br>(`invoke_text_llm`) | **关闭 (`disabled`)** | **极速省 Token 模式**：直接投喂提取文本，模型不做无谓的脑内打草稿，直接进行核心内容摘要。 |
| **图文混排文档**<br>

<br>(管道 D 有字且有图表) | **多模态模型**<br>

<br>(如 GPT-4o, Gemini) | 🔥 **图文双轨混合投喂**<br>

<br>(`invoke_hybrid_payload`) | **关闭 或 默认 (`disabled`)** | **满血不将就模式**：将高质量原生纯文本作为 Prompt 主体（保证文字 0 幻觉），将 Mac Quartz 渲染的各页高清截图作为 `image_url` 数组作为附件并列发送。文字看细节，图片看图表趋势。 |
| **图文混排文档**<br>

<br>(管道 D 有字且有图表) | **纯文本模型**<br>

<br>(如 DeepSeek) | 🛡️ **文本+本地 OCR 融合**<br>

<br>(`invoke_text_llm`) | 🚀 **强力开启 (`enabled` / max)** | **无多模态降级兜底**：为了防止研报/季报中的柱状图等关键信息丢失，调用 Mac 原生 Vision 框架对整页进行离线 OCR，把图表里的数字文字做成“补丁”追加在原生正文后。**必须全开推理模式**，让 DeepSeek 深度对齐这两股混杂文本的内在关联。 |
| **纯扫描件/纯图片**<br>

<br>(无任何原生文本) | **多模态模型**<br>

<br>(如 GPT-4o, Gemini) | **原生多图视觉通道**<br>

<br>(`invoke_vision_llm`) | **关闭 (`disabled`)** | 直接把多张页面长图转化为标准 Base64 数组，完全依赖高阶模型的原生视觉 OCR 算力直接解构。 |
| **纯扫描件/纯图片**<br>

<br>(无任何原生文本) | **纯文本模型**<br>

<br>(如 DeepSeek) | 🛡️ **本地全量 OCR 串行流**<br>

<br>(`invoke_text_llm`) | 🚀 **强力开启 (`enabled` / max)** | **终极兜底**：利用 Mac 离线 Vision 引擎把整书 OCR 拼接成大字符串。由于纯 OCR 文本带有不可避免的识别噪点，**必须全开推理模式**，让模型通过 `<think>` 自动纠错、猜测、并梳理出连贯的逻辑线。 |

---

## 💻 第四部分：生产环境代码蓝图（可直接交付 Codex 扩写）

你可以将以下结构化代码直接丢给 Codex，让其在此骨架基础上实现完整的业务功能：

```python
import os
import base64
import subprocess
from openai import OpenAI
from pptx import Presentation
from pypdf import PdfReader

# 导入 macOS 原生桥接内核 (需确保在 Mac 环境打包，免去所有重型第三方二进制依赖)
try:
    from Quartz import PDFDocument, NSURL, CGColorSpaceCreateDeviceRGB
    from Vision import VNRecognizeTextRequest, VNImageRequestHandler
    from Foundation import list as objc_list
    HAS_MAC_NATIVE = True
except ImportError:
    HAS_MAC_NATIVE = False

class MacAgentGatewayOrchestrator:
    def __init__(self, api_key: str, base_url: str):
        # 严格限定：一切大模型（含中转站、本地 Ollama）均收拢至标准 OpenAI 客户端
        self.client = OpenAI(api_key=api_key, base_url=base_url)

    def detect_visual_elements(self, file_path: str) -> bool:
        """轻量级视觉探测器：毫秒级判断 PDF/PPTX 是否含有核心图表或内嵌图"""
        _, suffix = os.path.splitext(file_path.lower())
        if suffix in [".pptx", ".ppt"]:
            try:
                prs = Presentation(file_path)
                for slide in prs.slides:
                    for shape in slide.shapes:
                        if shape.has_chart or shape.shape_type == 13: 
                            return True
            except: pass
        elif suffix == ".pdf":
            try:
                reader = PdfReader(file_path)
                for page in reader.pages:
                    if page.images and len(page.images.keys()) > 0: 
                        return True
            except: pass
        return False

    def check_vision_support(self, model_name: str) -> bool:
        """根据标准 OpenAI 命名默契，动态推断模型是否具备原生多模态视觉"""
        model_lower = model_name.lower()
        if "deepseek" in model_lower: 
            return False
        return any(k in model_lower for k in ["gpt-4o", "vision", "-vl", "gemini", "claude-3-5"])

    def sanitize_history(self, history_messages: list, enable_thinking: bool) -> list:
        """
        核心防御机制：在多轮对话上下文中，根据当前的 thinking 状态清洗历史记录
        防止由于开关切换或遗漏 reasoning_content 导致 DeepSeek 抛出 400 报错
        """
        sanitized = []
        for msg in history_messages:
            new_msg = msg.copy()
            # 如果关闭了推理模式，必须彻底剥离历史消息中的推理痕迹
            if not enable_thinking and "reasoning_content" in new_msg:
                del new_msg["reasoning_content"]
            sanitized.append(new_msg)
        return sanitized

    def route_and_process(self, file_path: str, model_name: str, history: list = None):
        """统一中央路由网关入口"""
        if history is None:
            history = []
            
        _, suffix = os.path.splitext(file_path.lower())
        supports_vision = self.check_vision_support(model_name)
        
        # 1. 纯文本与基础线性清洗管道 (管道 A & B)
        if suffix in [".md", ".markdown", ".txt", ".json", ".xml", ".csv", ".ics", ".html", ".htm", ".docx", ".doc"]:
            text_content = self.clean_and_extract_text(file_path, suffix)
            return self.invoke_text_llm(model_name, text_content, history, enable_thinking=False)

        # 2. 强视觉/复杂排版大文件管道 (管道 D)
        elif suffix in [".pdf", ".pptx", ".ppt", ".xlsx", ".xls"]:
            # 调用 Mac 内核抽取原生文字
            native_text = self.extract_native_text_via_mac(file_path, suffix)
            has_visuals = self.detect_visual_elements(file_path)
            
            # --- 决策分支 1：有字无图 -> 走高效纯文本通道 ---
            if native_text.strip() and not has_visuals:
                return self.invoke_text_llm(model_name, native_text, history, enable_thinking=False)
                
            # --- 决策分支 2：满血图文混排 + 视觉模型 -> 启动图文双轨混合投喂 (不将就) ---
            elif native_text.strip() and has_visuals and supports_vision:
                image_list = self.render_document_to_images(file_path, suffix)
                return self.invoke_hybrid_payload(model_name, native_text, image_list, history)
                
            # --- 决策分支 3：图文混排 + 纯文本模型 (如DeepSeek) -> 本地 OCR 增量补丁 + 强推理开启 ---
            elif native_text.strip() and has_visuals and not supports_vision:
                image_list = self.render_document_to_images(file_path, suffix)
                ocr_appendix = self.extract_batch_ocr_via_mac(image_list)
                combined_payload = f"{native_text}\n\n[本地图表视觉区 OCR 增量补丁]:\n{ocr_appendix}"
                return self.invoke_text_llm(model_name, combined_payload, history, enable_thinking=True)
                
            # --- 决策分支 4：纯扫描件文档 (完全抓不到原生文字) ---
            else:
                image_list = self.render_document_to_images(file_path, suffix)
                if supports_vision:
                    # 模型能看图，直传多图视觉流
                    return self.invoke_vision_llm(model_name, image_list, history)
                else:
                    # 模型是文盲，本地全量大长图离线 OCR 串行流拼接 + 强推理纠错
                    combined_ocr = self.extract_batch_ocr_via_mac(image_list)
                    return self.invoke_text_llm(model_name, combined_ocr, history, enable_thinking=True)

    # ==========================================
    # 底层 OpenAI 标准规范 API 发送封装
    # ==========================================
    def invoke_text_llm(self, model_name: str, content: str, history: list, enable_thinking: bool):
        """统一纯文本与本地 OCR 文本拼接发送管道"""
        sanitized_history = self.sanitize_history(history, enable_thinking)
        
        # 动态组装 DeepSeek 推理开关
        extra_body = {}
        if "deepseek" in model_name.lower():
            extra_body = {"thinking": {"type": "enabled" if enable_thinking else "disabled"}}
            if enable_thinking:
                extra_body["reasoning_effort"] = "max"

        current_message = {"role": "user", "content": content}
        
        response = self.client.chat.completions.create(
            model=model_name,
            messages=sanitized_history + [current_message],
            extra_body=extra_body if extra_body else None,
            temperature=0.2
        )
        return response.choices[0].message.content

    def invoke_hybrid_payload(self, model_name: str, text: str, image_paths: list, history: list):
        """满血图文双轨混合投喂通道（完全对齐 OpenAI 多模态规范结构）"""
        # 注意：多模态模型不支持 deepseek 的 extra_body 推理开关，需清洗历史
        sanitized_history = self.sanitize_history(history, enable_thinking=False)
        
        prompt_guideline = (
            "你收到了一个复杂的图文混排文档。\n"
            "系统已为你提取了该文档内部极其精确的原生纯文本，请直接作为事实依据引用。\n"
            "同时，为了防止文档中的【核心图表、折线图、架构排版】丢失，下方一并附带了该文档各页面的视觉截图。\n"
            "请结合文字和图片中展现的趋势、结构，进行最全面的深度总结和关联分析：\n\n"
            f"--- 原生纯文本开始 ---\n{text}\n--- 原生纯文本结束 ---"
        )
        
        content_list = [{"type": "text", "text": prompt_guideline}]
        
        # 串行追加各页 Base64 像素流
        for img_path in image_paths:
            with open(img_path, "rb") as img_file:
                b64_data = base64.b64encode(img_file.read()).decode("utf-8")
            content_list.append({
                "type": "image_url",
                "image_url": {"url": f"data:image/png;base64,{b64_data}"}
            })

        current_message = {"role": "user", "content": content_list}
        
        response = self.client.chat.completions.create(
            model=model_name,
            messages=sanitized_history + [current_message],
            max_tokens=2000
        )
        return response.choices[0].message.content

    def invoke_vision_llm(self, model_name: str, image_paths: list, history: list):
        """原生纯扫描件/纯图片多图视觉通道"""
        sanitized_history = self.sanitize_history(history, enable_thinking=False)
        content_list = [{"type": "text", "text": "请利用你强大的多模态 OCR 与视觉感知能力，深度解构这组文档截图并做核心摘要。"}]
        
        for img_path in image_paths:
            with open(img_path, "rb") as img_file:
                b64_data = base64.b64encode(img_file.read()).decode("utf-8")
            content_list.append({
                "type": "image_url",
                "image_url": {"url": f"data:image/png;base64,{b64_data}"}
            })
            
        current_message = {"role": "user", "content": content_list}
        response = self.client.chat.completions.create(
            model=model_name,
            messages=sanitized_history + [current_message],
            max_tokens=2000
        )
        return response.choices[0].message.content

    # ==========================================
    # 后续具体转换函数：留给 Codex 按照清洗规范完成具体业务扩写
    # ==========================================
    def clean_and_extract_text(self, path: str, suffix: str) -> str:
        """管道 A/B：本地基础清洗实现（如 textutil 命令行、BeautifulSoup 过滤）"""
        pass

    def extract_native_text_via_mac(self, path: str, suffix: str) -> str:
        """管道 D：基于 macOS Quartz 原生内核或 python-pptx / pandas 的零成本纯文本提取"""
        pass

    def render_document_to_images(self, path: str, suffix: str) -> list:
        """管道 D：基于 macOS Quartz (PDFKit) 的离线高清切图，返回图片临时路径列表"""
        pass

    def extract_batch_ocr_via_mac(self, image_paths: list) -> str:
        """本地兜底：利用 macOS 原生 Vision 框架进行串行批量高精度 OCR 离线转码"""
        pass

```


## 功能

1. 用户使用前要设立一个文件管理路径（而不是像现在一样全部存在服务端），用户可以将不同格式的文件放入该目录，使用 watchdog 库监听该目录。当用户放入新文件时，自动触发解析
2. 要求 Agent 通读文件内容，并严格返回以下 JSON 格式进行分流

```json
{
  "category": "memo" | "reminder" | "schedule (record)"| "schedule (plan)", 
  "title": "任务或文档标题",
  "target_date": "YYYY-MM-DD HH:MM:SS (如果是提醒或日程)",
  "summary": "一句话核心内容摘要",
  "tags": ["标签1", "标签2"]
}
```

3. 由 fastAPI 服务端去识别这些JSON，将它们归类到备忘录、提醒事项、日程（记录 or 计划），最终用户可以在 flutter 客户端对应页面看见。
4. 也支持用户自己在界面中用已有功能去新建备忘录、提醒事项、日程，然后把元数据以 SQLite 保存在服务端，但是创建的 md 文件要保存在用户本地操作系统内的路径
5. 备忘录支持源文件格式为 docx、pdf、md 等主流文档格式，假如源文件格式不是 md，会创建一个内容完全一致的md 文件以及更新对应的 SQLite 元数据，与源文件一起保存在用户本地文件管理区


### 日程管理
- Google Calendar
  - **时区处理**：Google Calendar API 返回带时区偏移的时间（如 `14:00:00+08:00`），Dart `DateTime.parse()` 会将其解析为 UTC DateTime（`.isUtc=true`），导致 `.hour` 返回 UTC 小时而非本地小时。解决方法：服务端 `_parse_event_datetime()` 用 `replace(tzinfo=None)` 去掉时区偏移，Flutter 端所有 `.hour`/`.minute` 访问前先调 `.toLocal()`。

### 待办提醒
- 自然语言创建 / 管理提醒（Agent 工具）
- Apple Reminders 风格 Flutter UI（分组列表、圆形复选框、优先级标识）
- FNode 存储：markdown 文件 + SQLite 元数据索引

### 备忘记录
- 自然语言创建 / 管理备忘录（Agent 工具）
- Apple Notes 风格 Flutter UI（卡片式列表、搜索、标签分类）
- FNode 存储：markdown 文件 + SQLite 元数据索引

### 工时统计
- wakatime + 主动汇报

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

## 日程管理

### 架构

```
┌─────────────────────────┐     ┌──────────────────────────────────┐
│     Flutter Client       │────▶│     FastAPI Server (port 8000)    │
│  - MonthView (手写)      │     │  - /api/events CRUD              │
│  - DayView (手写拖拽)    │     │  - CalendarService (SQLite)      │
│  - CalendarApi service   │     │  - GoogleCalendarClient (MCP)    │
└─────────────────────────┘     │  - events + sync_state + oauth   │
                                  └──────────┬───────────────────────┘
                                             │ MCP SSE
                                  ┌──────────▼───────────────────────┐
                                  │  Google Calendar MCP API         │
                                  │  calendarmcp.googleapis.com/mcp  │
                                  │  (OAuth 2.0 Bearer Token)        │
                                  └──────────────────────────────────┘
```

### 统一日程表设计

本地日程和 Google 日历日程共存在同一张 `events` 表中。通过 `source`（来源）和 `external_id`（外部 ID）区分本地数据和 Google 缓存。

**表结构 (`data/index.db` → `events`)**:

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | UUID（本地生成） |
| title | TEXT | 日程标题 |
| description | TEXT | 日程描述 |
| start_time | TEXT | 开始时间 (ISO 8601) |
| end_time | TEXT | 结束时间 (ISO 8601) |
| is_all_day | INTEGER | 是否全天日程 |
| source | TEXT | 'local' 或 'google' |
| external_id | TEXT | Google Calendar event ID（unique per Google event） |
| etag | TEXT | Google event version（并发控制） |
| recurrence | TEXT | RRULE 字符串（重复规则） |
| status | TEXT | confirmed / tentative / cancelled |
| color | TEXT | 颜色标记 (#RRGGBB) |
| created_at | TEXT | 创建时间 |
| updated_at | TEXT | 更新时间 |

**`sync_state` 表** — 同步状态:

| 字段 | 类型 | 说明 |
|------|------|------|
| source | TEXT PK | 'google' |
| next_sync_token | TEXT | Google nextSyncToken |
| last_synced_at | TEXT | 上次同步时间 |

**`oauth_tokens` 表** — OAuth 令牌:

| 字段 | 类型 | 说明 |
|------|------|------|
| source | TEXT PK | 'google' |
| access_token | TEXT | OAuth access token |
| refresh_token | TEXT | OAuth refresh token |
| token_expiry | TEXT | token 过期时间 |
| updated_at | TEXT | 更新时间 |

### 增量同步机制

1. **首次同步**：后端带 access_token 连接 Google Calendar MCP → 调用 `events.list`（不带 syncToken）→ 全量拉取 → upsert 到 `events` 表 → 保存 `nextSyncToken`
2. **增量同步**：后端带 `syncToken` 调用 `events.list` → Google 只返回变更数据 → 增量 upsert 到 `events` 表 → 保存新的 `nextSyncToken`
3. **清理**：全量同步后删除 `source='google'` 且 `external_id` 不在返回列表中的旧日程

### Google Calendar MCP 集成

使用官方 Google Calendar MCP API (`https://calendarmcp.googleapis.com/mcp/v1`)，通过 OAuth 2.0 Bearer Token 鉴权。

`google_calendar_client.py` 参考 `actual_api.py` 的 MCP SSE 模式：
- `sse_client(url, headers={"Authorization": f"Bearer {token}"})` 建立连接
- `list_tools_raw()` 动态发现工具
- `call_tool(name, args)` 通用调用
- `sync_google_calendar(service, access_token)` 编排全量/增量同步

### OAuth 配置

1. 用户需在 [Google Cloud Console](https://console.cloud.google.com) 创建项目并启用 Calendar API
2. 创建 OAuth 2.0 客户端 ID（Web 应用类型）
3. 在 `.env` 中配置：
   ```
   GOOGLE_CLIENT_ID=xxx.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=GOCSPX-xxx
   GOOGLE_REDIRECT_URI=http://localhost:8000/api/events/google/callback
   ```
4. 访问 `/api/events/google/auth-url` 获取授权 URL，浏览器授权后自动回调保存 token

### REST API

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/events?start=...&end=...` | 按时间范围查询日程 |
| GET | `/api/events/{id}` | 获取单条 |
| POST | `/api/events` | 创建本地日程 |
| PUT | `/api/events/{id}` | 更新日程 |
| DELETE | `/api/events/{id}` | 删除日程 |
| POST | `/api/events/sync` | 触发 Google Calendar 同步 |
| GET | `/api/events/sync/status` | 查询同步状态 |
| GET | `/api/events/google/oauth/status` | 检查 Google 连接状态 |
| GET | `/api/events/google/auth-url` | 获取 OAuth 授权 URL |
| GET | `/api/events/google/callback` | OAuth 回调 |
| POST | `/api/events/google/oauth` | 手动保存 OAuth token |

### Agent 工具（4个）

`create_calendar_tools(service)` 创建 LangChain tools，Jarvis AI 可通过对话管理日程：
- `list_events` — 按时间范围查看
- `create_event` — 创建本地日程
- `update_event` — 更新日程
- `delete_event` — 删除日程

### Flutter UI

**月视图 (`month_view.dart`)** — 仿苹果日历：
- 手写 7×5-6 日历网格（`GridView` 替代）
- 顶部 ◀ 年月 ▶ 导航，点击中间弹出年月快速选择器
- 日期格显示数字 + 最多 3 个事件圆点（不同颜色区分 local/google）
- 今日红色圆点高亮，选中日期蓝色边框
- 底部显示选中日期的日程卡片列表

**日视图 (`day_view.dart`)** — 仿苹果日历：
- 左侧时间轴 00:00-23:00，当前时间红色横线
- 日程卡片按 startTime/endTime 定位，左侧色块标识
- 拖拽创建：桌面端按住空白时间区域拖动 → 松手弹窗确认
- 全天日程顶部条状显示
- 前后天切换箭头

### 文件清单

| 文件 | 说明 |
|------|------|
| `src/server/calendar_service.py` | CalendarService + 表迁移 + Agent 工具 |
| `src/server/google_calendar_client.py` | Google Calendar MCP SSE 客户端 + 同步逻辑 |
| `lib/models/event.dart` | CalendarEvent 数据模型 |
| `lib/services/calendar_api.dart` | REST API 调用服务 |
| `lib/screens/calendar/calendar_screen.dart` | 日程主容器（月/日视图切换） |
| `lib/screens/calendar/month_view.dart` | 月视图 |
| `lib/screens/calendar/day_view.dart` | 日视图（含拖拽） |
| `lib/screens/calendar/event_edit_dialog.dart` | 编辑弹窗 |
| `lib/screens/calendar/year_month_picker.dart` | 年月快速选择器 |

## 备忘录与提醒事项

自然语言驱动的备忘录和提醒事项管理。用户可在聊天中说"帮我记个备忘录"或"提醒我明天开会"，Agent 自动调用对应工具。

### 存储架构：FNode 模式

```
data/
├── memos/                  # 每条备忘录 = 一个 .md 文件
├── reminders/              # 每条提醒 = 一个 .md 文件
└── index.db                # SQLite FNode 元数据索引（不存正文）
```

**设计理念**：类似文件系统的 inode。SQLite 只存元数据指针（文件路径、标签、时间戳、到期日、优先级），实际内容在 markdown 文件中。好处：
- 文件可直接用任何编辑器打开修改
- 可加入 Git 版本管理（需要时去掉 .gitignore）
- SQLite 做索引查询快，markdown 文件做内容存储灵活

### 工具清单（13个）

**备忘录（6）**：`create_memo`, `list_memos`, `search_memos`, `get_memo`, `update_memo`, `delete_memo`
**提醒（7）**：`create_reminder`, `list_reminders`, `get_upcoming_reminders`, `get_reminder`, `update_reminder`, `delete_reminder`, `complete_reminder`

### 数据流：双通道

```
用户自然语言 ──→ 聊天界面 ──→ Socket.IO ──→ Agent (ReAct)
                                              │
                                        调用 memo_tools
                                              │
用户手动操作 ──→ Flutter UI ──→ REST API ──→ MemoService 单例
                                              │
                                    ┌─────────┴──────────┐
                                    │  SQLite (元数据)    │
                                    │  .md files (内容)   │
                                    └────────────────────┘
```

### REST API

| 端点 | 方法 | 说明 |
|------|------|------|
| `/api/memos` | GET/POST | 列表/创建备忘录 |
| `/api/memos/{id}` | GET/PUT/DELETE | 详情/更新/删除 |
| `/api/reminders` | GET/POST | 列表/创建提醒 |
| `/api/reminders/{id}` | GET/PUT/DELETE | 详情/更新/删除 |
| `/api/reminders/{id}/complete` | PUT | 标记完成 |
| `/api/reminders/upcoming` | GET | 即将到期 (?days=7) |

### 踩坑记录

#### 20. `get_upcoming_reminders` 日期计算用 `replace(day=...)` 跨月报错

**现象**：5月26日调用 `get_upcoming_reminders(7)` 时，`now.day + 7 = 33`，`datetime.replace(day=33)` 抛出 `ValueError`，被 catch 后 `end_date` 回退到今天，导致只返回今天到期的提醒。

**原因**：`datetime.replace(day=...)` 不会做日期进位，day 超出当月天数就报错。

**解决**：用 `datetime.timedelta(days=7)` 替代 `replace(day=...)`，timedelta 会自动处理月份和年份的进位：
```python
from datetime import timedelta
end_date = (now + timedelta(days=days)).strftime("%Y-%m-%d")
```

#### 21. SQLite 单例 + WAL 模式防锁

多客户端同时连接时，每个 Agent 实例通过 `asyncio.to_thread()` 调用 MemoService。SQLite 默认 journal_mode=DELETE 下写操作会锁住整个数据库。

**解决**：`MemoService` 在模块级别创建单例（`server.py` 中 `_get_memo_tools()`），所有 Agent 和 REST handler 共享同一个实例。`__init__` 中开启 `PRAGMA journal_mode=WAL`，WAL 模式下读写互不阻塞。

#### 22. 提醒事项 UI 没有创建按钮

**现象**：提醒事项页面有完整的添加表单组件（`_AddReminderForm`），但没有任何 UI 入口可以触发显示，用户无法通过 Flutter UI 创建提醒事项。

**原因**：`_showAddForm` 状态默认为 `false`，页面内部缺少按钮将其设为 `true`。HomeScreen 也只传了 `key`，未传 `showAddForm` 参数。

**解决**：
- `HomeScreen` 新增 `_reminderShowAddForm` 状态 + `FloatingActionButton`（加号/关闭切换）
- `ReminderScreen` 新增 `showAddForm` + `onToggleAddForm` 参数，`didUpdateWidget` 中同步外部状态
- 列表底部新增 Apple Reminders 风格"新提醒事项"占位行（空心圆 + 加号图标），点击展开添加表单

#### 23. `search_memos` 不搜索标签

**现象**：搜索备忘录时输入标签名称（如"生活"）无匹配结果，只能匹配标题。

**原因**：SQL 查询 `WHERE title LIKE ? OR file_path IN (SELECT file_path FROM nodes WHERE type='memo')` 中，子查询条件始终为真，实际上只搜索了标题。`tags` 字段完全未参与搜索。

**解决**：改为 `WHERE type='memo' AND (title LIKE ? OR tags LIKE ?)`，同时搜索标题和标签 JSON 字段。Python 侧对文件正文做二次过滤，用 `set` 去重。

#### 24. 备忘录不支持插入图片

**现象**：备忘录编辑页只有纯文本输入，无法添加图片附件。

**解决**：
- 后端新增 `POST /api/upload`（multipart 图片上传，返回 `/uploads/xxx.png` URL），通过 `StaticFiles` 挂载静态目录
- Flutter 添加 `image_picker` 依赖，`MemoDetailScreen` AppBar 增加图片按钮，选择图片 → 上传 → 在光标处插入 `![alt](url)` Markdown 语法
- `MemoApi.uploadImage()` 用 `MultipartFile.fromBytes()` 确保 Web 和移动端均可使用

#### 25. 提醒事项优先级选择没反应

**现象**：点击添加表单中的优先级 ChoiceChip（低/中/高），选中状态不变化。

**原因**：`_AddReminderForm` 的 `onPriorityChanged` 回调只有赋值没有 `setState()`，UI 不重绘。

**解决**：改为 `onPriorityChanged: (v) => setState(() => _newPriority = v)`。

#### 26. 提醒事项到期日缺少日期选择器

**现象**：添加提醒时到期日只能手动输入 YYYY-MM-DD 格式，体验差，且无法留空。

**原因**：到期日用的是普通 `TextField`，`_AddReminderForm` 是 `StatelessWidget`。

**解决**：将 `_AddReminderForm` 改为 `StatefulWidget`，到期日输入改为 `InkWell` + `showDatePicker()` 弹出系统日历选择器，选中后右侧显示 X 按钮可清空。添加按钮根据标题是否为空动态启用/禁用。

#### 27. 提醒事项缺少编辑入口

**现象**：单条提醒事项只有完成/取消和左滑删除两种操作，无法修改标题、到期日、优先级。

**原因**：`_ReminderRow` 只有 `onToggle` 和 `onDelete` 回调，没有编辑功能。

**解决**：每行右侧添加 `Icons.more_horiz` 省略号按钮，点击弹出 `showDialog` + `StatefulBuilder` 编辑弹窗（标题、备注、到期日选择器、优先级 ChoiceChip），保存时调用 `ReminderApi.update()`。

#### 28. 图片上传因 content-type 校验失败

**现象**：在备忘录详情页选择图片后上传失败，提示"图片上传失败"。

**原因**：`MultipartFile.fromBytes()` 默认 content-type 是 `application/octet-stream`，服务端 `POST /api/upload` 校验 `content_type.startswith("image/")` 拒绝。

**解决**：服务端在上传端点中增加文件扩展名回退校验（png/jpg/jpeg/gif/webp/bmp/svg），当 content-type 不满足 `image/*` 时根据扩展名判断，避免因客户端未传 content-type 而拒绝合法图片。

#### 29. 备忘录不支持图片内联显示和粘贴

**现象**：图片插入后只显示 Markdown 语法文本，不能在备忘录中直接看到图片；也无法 Ctrl+V 粘贴剪贴板图片。

**原因**：编辑页用纯 `TextField`，图片要回到列表页用 `MarkdownBody` 渲染才能看到。没有粘贴事件监听。

**解决**：
- AppBar 增加编辑/预览切换按钮，预览模式用 `MarkdownBody` 渲染正文（图片内联显示）
- 新建 `clipboard_image_web.dart`（web 端用 `dart:html` 监听 paste 事件检测剪贴板图片）+ `clipboard_image_stub.dart`（非 web 打桩），通过条件导入切换
- 提取 `_uploadAndInsert()` 公共方法，图片按钮和粘贴共用同一上传流程

	#### 30. 备忘录编辑/预览模式割裂

	**现象**：编辑和预览通过 AppBar 眼睛图标按钮切换，两种模式完全分离，体验不连贯，不像 Apple Notes 那样所见即所得。

	**原因**：`_isPreviewing` 布尔值控制两种互斥的 UI 状态，需要手动点击按钮切换。

	**解决**：
	- 移除编辑/预览切换按钮，将两种模式融为一体（Apple Notes 风格）
	- 正文默认渲染为 `MarkdownBody`（图片内联、Markdown 完整渲染），点击进入编辑
	- 失去焦点自动切回预览；新/空备忘录默认编辑状态
	- 粘贴图片时自动切到编辑模式再插入 Markdown 图片语法

	#### 31. 提醒事项编辑弹窗缺少删除按钮

	**现象**：点击省略号按钮进入编辑弹窗后只能修改或取消，无法删除。左滑删除不够直观。

	**原因**：`_showEditDialog()` 的 `AlertDialog.actions` 只有"取消"和"保存"。

	**解决**：新增红色"删除"按钮 → 二次确认 → 调用 `ReminderApi.delete()`。`showDialog` 泛型改为 `String`（`'save'` / `'delete'` / `'cancel'`）。

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
| `src/server/agent.py` | `from server.constants import ...` | `from .constants import ...` |
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

## 文件管理 — 自动解析与分流

### 架构

```
用户文件系统 (~/jarvis-files/)
  │
  │  放入 docx / pdf / md / ics 文件
  ▼
watchdog FileWatcher  ──检测新文件──▶ .ics? ──Yes──▶ _parse_ics() ──▶ CalendarService
                                            │
                                            No
                                            │
                                      FileParser (markitdown)
                                            │
                                       markdown 文本
                                            │
                                      FileClassifier (LLM)
                                            │
                                    分类 JSON ──▶ FastAPI 分流
                                                   │
                                    ┌──────────────┼──────────────┐
                                    ▼              ▼              ▼
                                 MemoService   MemoService   CalendarService
                                 (memo)        (reminder)    (schedule)
                                    │              │              │
                                    ▼              ▼              ▼
                              SQLite 索引 + 本地 .md 文件
```

### 新增文件

| 文件 | 说明 |
|------|------|
| `src/server/file_watcher.py` | watchdog 目录监控 + markitdown 解析 + LLM 分类 + 实体创建 |
| `lib/screens/settings_screen.dart` | Flutter 设置页面（配置文件管理目录） |
| `lib/services/settings_api.dart` | 设置 REST API 服务 |

### REST API

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/settings/watch-dir` | 设置文件管理目录，启动监控 |
| GET | `/api/settings/watch-dir` | 获取当前目录和监控状态 |
| POST | `/api/files/scan` | 手动扫描目录中所有文件 |
| GET | `/api/files/watcher-status` | 获取监控运行状态 |

### 处理流程

1. 用户在 Flutter 设置页配置本地目录路径
2. 服务端启动 watchdog 监听该目录
3. 用户放入 docx/pdf/md/ics 等文件 → watchdog 检测到 `on_created` 事件
4. **ICS 文件特殊处理**：`.ics` 文件不经过 markitdown 和 LLM，直接解析 VEVENT 块，每条事件写入 CalendarService，仅保留源文件和 SQLite 元数据
5. 其他文件由 `FileParser` 用 Microsoft markitdown 转为 markdown 文本
6. `FileClassifier` 调用 LLM（DeepSeek）分析内容，返回分类 JSON：
   ```json
   {"category": "memo|reminder|schedule (record)|schedule (plan)", "title": "...", "target_date": "...", "summary": "...", "tags": [...]}
   ```
6. 根据 category 创建对应实体（备忘录/提醒事项/日程）
7. 非 .md 源文件自动创建同内容 .md 副本（.ics 除外），元数据写入 SQLite
8. Flutter 客户端对应页面立即可见

### 数据库变更

`nodes` 表新增字段：
- `source_file TEXT` — 原始文件路径（如 `report.docx`）
- `source_format TEXT` — 原始格式（`docx`、`pdf`、`md`）

`events` 表新增字段：
- `file_path TEXT` — 关联的 .md 文件路径
- `source_file TEXT` — 原始源文件路径
- `source_format TEXT` — 原始格式

### 踩坑记录

#### 32. markitdown 可选依赖未安装时静默回退

**现象**：如果 `markitdown` 未安装或解析失败，`FileParser.parse()` 会抛出异常，导致整个文件处理流水线中断。

**解决**：加 `try/except` 兜底，未安装 markitdown 或解析失败时自动回退为原始文本读取（`file_path.read_text()`），确保系统在各种环境下都能工作。

#### 33. watchdog on_created 重复触发

**现象**：某些文件系统（如 macOS）在文件复制时可能触发多次 `on_created` 事件，导致同一文件被重复处理。

**解决**：在 `FileWatchHandler` 中实现 debounce 机制——用 `_debounce` set 记录已处理的文件路径，2 秒后自动清除，避免重复处理。

#### 34. ICS 日历文件导入不走 LLM 分类

**现象**：用户放入 `.ics` 日历文件后，系统按普通文件流程走 markitdown + LLM 分类，ICS 的 VEVENT 结构化数据被当作普通文本处理，丢失时间、多事件等关键信息。

**原因**：`.ics` 是标准日历格式（RFC 5545），包含 `BEGIN:VEVENT`...`END:VEVENT` 结构化块，不需要 markitdown 转换或 LLM 理解。直接用正则解析即可提取 SUMMARY/DTSTART/DTEND/DESCRIPTION。

**解决**：在 `_process_file()` 中增加 `.ics` 专属路径——检测后缀为 `.ics` 后直接调用 `_parse_ics()` 解析 VEVENT 块，每条事件调用 `CalendarService.create_event_from_file()`，不创建 .md 副本，不经过 LLM 分类。iCalendar 时间格式（`YYYYMMDDTHHMMSS`）自动转换为 ISO 8601。

#### 35. 设置页面无返回按钮

**现象**：Flutter 设置页通过侧边栏切换嵌入显示，AppBar 没有返回按钮，用户只能通过侧边栏切回其他页面，操作不便。

**原因**：`SettingsScreen` 直接嵌入 `home_screen.dart` 的 switch 分支中，没有导航栈概念，`Navigator.pop()` 无法使用。

**解决**：`SettingsScreen` 新增 `onBack` 回调参数，`home_screen.dart` 传入 `() => setState(() => _selectedFeature = 0)`，AppBar 的 `leading` 根据回调是否存在显示返回箭头。

#### 36. DeepSeek API 不支持 `response_format` json_schema 导致 LLM 分类失败

**现象**：服务端日志出现 warning — `LLM classification failed: Error code: 400 - {'error': {'message': 'This response_format type is unavailable now'}}`，文件分类降级为默认值（category=memo，tags 为空）。

**原因**：LangChain 的 `ChatOpenAI.with_structured_output()` 对非 OpenAI 官方模型（如 `deepseek-v4-flash`）默认使用 `response_format` + `json_schema` 方式实现结构化输出。但 DeepSeek API 不支持 `response_format` 中的 `json_schema` 类型。

**解决**：显式指定 `method="function_calling"`，让 LangChain 改用 tool calling 方式实现结构化输出（DeepSeek 支持 tool calling）：

```python
# file_watcher.py line 128 — 修复前
structured_llm = self.llm.with_structured_output(ClassifyResult)

# 修复后
structured_llm = self.llm.with_structured_output(ClassifyResult, method="function_calling")
```

#### 37. 重启服务器未设置路径仍显示上次导入的文件

**现象**：重启服务器和客户端后，在设置页面未设置任何文件管理目录，但 Flutter 应用中仍然能看见上一次通过 watch directory 导入的文件记录。点击进去内容为空。

**原因**：`MemoService` 使用 SQLite（`data/index.db`）持久化所有 memo/reminder 的元数据。重启后 `list_memos()` / `list_reminders()` 无条件返回数据库中所有行，不管对应的物理 `.md` 文件是否存在。通过 watch directory 导入的文件，其 `file_path` 是相对于该外部目录的路径；服务器重启后 `_watched_dir` 重置为 `None`，`_resolve_path()` 回退到 `data/` 目录，找不到实际文件，导致显示空内容的幽灵记录。

**解决**：在所有读操作中增加物理文件存在性检查：
- `list_memos()` / `search_memos()` — 跳过 `_resolve_path()` 后文件不存在的行
- `list_reminders()` / `get_upcoming_reminders()` — 同上
- `get_memo()` / `get_reminder()` — 文件不存在时返回 `None`
- `update_memo()` / `update_reminder()` — 文件不存在时返回 `None`，防止在错误路径创建新文件"复活"幽灵记录

同时 `main()` 启动时自动调用 `cleanup_stale_nodes()`，清理所有物理文件已不存在的 SQLite 孤儿记录。

#### 38. PDF 文件处理连环报错：deepseek-v4-flash 不支持 image_url

**现象**：放入 PDF 文件后，服务端连环报错：
1. `Error code: 400 - messages[1]: unknown variant 'image_url', expected 'text'`
2. `FileNotFoundError: [Errno 2] No such file or directory: '灵光一闪.pdf'`

**原因**：
- `deepseek-v4-flash` 是纯文本模型，不支持 `image_url` 类型的多模态消息块。当 PDF 通过管道 D 渲染为图片后，`_submit_multipage_vision()` 将每页作为 `image_url` 块提交给 LLM，DeepSeek API 拒绝该请求返回 400。
- `_invoke_llm()` 的异常处理 fallback 中，`FileParser.parse(Path(filename))` 只拿到了文件名（如 `灵光一闪.pdf`），没有完整的文件路径，导致二次 FileNotFoundError。

**解决**：
- `_invoke_llm()` 参数从 `filename: str` 改为 `file_path: Path`，fallback 时使用完整路径。
- `_pipeline_visual_render()` 在 `_submit_multipage_vision()` 调用外层增加 try/except，LLM 调用失败时自动回退到 `_summarize_via_markitdown()` 进行纯文本提取 + 摘要。

#### 39. Flutter macOS 启动报 "Failed to foreground app; open returned 1"

**现象**：`flutter run -d macos` 构建完成后 app 无法启动，控制台输出 `Failed to foreground app; open returned 1`。

**原因**：
1. 上一个 `flutter_application_1` 进程仍在后台运行，`open` 命令检测到同名 app 已在运行返回 exit code 1
2. `DebugProfile.entitlements` 中 `com.apple.security.app-sandbox = true` 阻止调试器附加

**解决**：
1. `killall flutter_application_1` 杀掉残留进程
2. 将 `DebugProfile.entitlements` 中 `app-sandbox` 改为 `false`（仅关闭 Debug 模式的 sandbox，Release 保持不变）

#### 40. 用户无法判断分配的模型是否已配置凭据

**现象**：用户只能配置一套 API 凭据（api_key + base_url），但 `models.yaml` 中定义了来自不同提供商（OpenAI、DeepSeek、Google）的多个模型。任务模型分配页面可以为每个任务类型选择任意模型，但用户无法知道所选模型的提供商是否与已配置的凭据匹配，只有在实际调用失败时才发现问题。

**原因**：`ModelGateway` 使用单套凭据（`self._api_key` + `self._base_url`）为所有模型创建 `ChatOpenAI` 实例，不管该模型在 `models.yaml` 中声明的 `api_base` 是哪个提供商。Gateway 也不对外暴露凭据与模型的匹配关系。

**解决**：在 Gateway 层增加提供商匹配检查，前后端联动展示凭据兼容状态：

1. **Gateway** (`gateway.py`) 新增 `get_model_provider_match(model_key)` 和 `get_compatible_models()` 方法 — 通过比较 `urlparse(base_url).netloc` 判断模型 `api_base` 与配置凭据是否匹配。

2. **`GET /api/settings/profiles`** — 每个 profile 新增 `credential_match` 字段；根级新增 `has_credentials`、`configured_base_url`、`compatible_models`。

3. **`PUT /api/settings/profiles/{task_type}`** — 分配模型后若凭据不匹配，返回 `warning` 字段提醒用户（不阻止分配，用户可能后续更换凭据或手动配置多套）。

4. **`GET /api/settings/llm`** — 新增 `compatible_models` 列表。

5. **Flutter 设置页** — LLM 连接区域新增「提供商兼容性摘要」卡片，展示当前凭据覆盖了哪些模型，以及哪些任务分配了不兼容的模型。每个任务卡片头部对不匹配模型显示 `link_off` 图标 + tooltip。展开区域显示橙色警告条，下拉框中给未配置提供商的模型标注「(未配置)」标签。

#### 41. LLM 连接连通性测试与模型验证机制

**需求**：用户配置好 LLM API Key 后，需要测试连通性确认凭据有效；已验证的模型显示打勾标识，只有通过测试的模型才能用于任务分配。

**实现**：

1. **Gateway** (`gateway.py`) 新增：
   - `_verified_models: set[str]` — 跟踪已通过连通性测试的模型
   - `verify_credentials(api_key, base_url)` — 用 OpenAI 客户端先调用 `/models` 端点（零 token 消耗），失败时回退到最小 chat completion。成功后标记所有 `api_base` 主机匹配的模型为已验证
   - `is_model_verified(model_key)` / `get_verified_models()` — 查询验证状态
   - `update_credentials()` 切换凭据时自动清空 `_verified_models`

2. **`POST /api/settings/llm/test`** — 接收 `{api_key, base_url}`，调用 `verify_credentials()`，返回 `{success, message, verified_models}`。失败时返回 400 + 具体错误信息。

3. **`GET /api/settings/profiles`** — 新增 `verified_models` 字段，前端据此显示验证状态。

4. **Flutter 设置页**：
   - LLM 连接区域新增「测试连接」按钮（`OutlinedButton`），测试中显示 loading 动画
   - 模型下拉选择器中已验证模型旁显示绿色 ✅ 图标
   - 测试成功后显示绿色提示条，列出已验证模型名称
   - 任务模型分配区域：一旦有模型通过验证，下拉框只允许选择已验证的模型，未验证模型标注「(未验证)」并置灰
   - 未验证模型的任务卡片显示红色警告图标 + tooltip"尚未通过连通性验证"
   - 展开区域红色警告条提示用户先测试连接

5. **`constants.py`** — `MODEL_META` 加载时补充 `api_base` 和 `provider` 字段（此前缺失，导致主机匹配失败始终返回 0 个兼容模型）。

6. **BUG 修复** — `gateway.py` 的 `update_credentials()` 每次被调用时都会 `_verified_models.clear()`，而 `verify_credentials()` 内部也调用了 `update_credentials()`。这导致测试第二个提供商时，之前已测试通过的模型全部被清空。修复：移除 `update_credentials()` 中的 `self._verified_models.clear()`，已验证模型应跨测试累积保留，仅在服务器重启时自然重置。
