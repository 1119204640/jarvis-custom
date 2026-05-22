import asyncio
from mcp import ClientSession
from mcp.client.sse import sse_client

# 在 Docker 里把验证设为了 none，所以不需要 Bearer Token
MCP_SERVER_URL = "http://localhost:3000/mcp"

async def test_connect():
    print("🔄 正在尝试连接本地 MCP 服务器...")
    try:
        # 连接到 MCP 服务器的 SSE 终点
        async with sse_client(url=MCP_SERVER_URL) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                # 初始化会话（握手）
                await session.initialize()
                print("✅ 握手成功！已成功连接到 Actual Budget MCP 服务器。\n")
                
                # 索要服务器支持的所有工具
                print("📦 正在获取可用的财务管理工具...")
                mcp_tools = await session.list_tools()
                
                print(f"🎉 成功拉取到 {len(mcp_tools.tools)} 个工具：\n")
                for tool in mcp_tools.tools:
                    print(f"🛠️  工具名称: {tool.name}")
                    print(f"📝 功能描述: {tool.description}")
                    print(f"🔌 输入参数规范: {tool.inputSchema}")
                    print("-" * 50)
                    
    except Exception as e:
        print(f"❌ 连接失败。报错信息: {e}")
        print("请检查：1. Docker 容器是否在正常运行？ 2. 浏览器打开 http://localhost:3000/mcp 是否有响应？")

# 运行异步测试
if __name__ == "__main__":
    asyncio.run(test_connect())