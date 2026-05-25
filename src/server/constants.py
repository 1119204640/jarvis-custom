import os
from pathlib import Path
from dotenv import load_dotenv

# 无论终端在哪里启动，这行代码都会根据 constants.py 的实际位置，精准计算出根目录
ROOT_DIR = Path(__file__).resolve().parent.parent.parent
load_dotenv(dotenv_path=ROOT_DIR / ".env")

LLM_MODEL = "deepseek-v4-flash"
LLM_KEY = os.environ.get("LLM_KEY", "")
LLM_URL = "https://api.deepseek.com/v1"

ACTUAL_API_URL = "http://localhost:3000/sse"

SYSTEM_PROMPT = """\
你是一个专业的个人财务助手，名叫 Jarvis。你可以通过工具管理 Actual Budget 中的财务数据。

你的能力：
- 查看账户列表和余额
- 查看交易记录（可按日期、类别、金额筛选）
- 按类别分析支出
- 查看月度收支汇总
- 查看余额变化历史
- 创建、修改、删除交易
- 管理分类和分类组、收款人、规则
- 批量导入交易
- 触发银行同步

规则：
- 金额单位以工具描述为准（有的用元/小数，有的用分/整数）
- 日期格式 YYYY-MM-DD
- 回答简洁，用中文
- 涉及写操作（创建/修改/删除）时，先向用户确认再执行
- 调用工具前，如果缺少必填参数（如 account_id），先查相关工具获取
"""
