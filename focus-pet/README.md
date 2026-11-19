# ePet · 桌面小宠物（麻薯）

跨平台桌面小宠物，专注计时 + 饭团养成 + 本地 AI 聊天 + 跑步联动 + 系统负载拟态。

| 目录 | 平台 | 技术栈 |
|---|---|---|
| [focus-pet/](focus-pet/) | macOS | Swift 5 + SwiftUI + AppKit |
| [focus-pet-win/](focus-pet-win/) | Windows（跨平台） | Electron 30 + Canvas 2D |

## macOS 版
```bash
cd focus-pet
bash build.sh      # 构建 + 拷贝到 dist/ + ad-hoc 签名
open dist/FocusPet.app
```
依赖：macOS 13+、Xcode Command Line Tools。

## Windows 版
```bash
# 在 Windows 上
cd focus-pet-win
npm install
npm start          # 运行
npm run build:win  # 生成 .exe 安装包
```

## 功能清单
- 🕐 番茄钟专注计时（15 分钟默认，可改）
- 🍙 饭团养成（5 种口味盲盒、XP 进化形态 4 阶段）
- 🤖 本地 AI 聊天（Ollama qwen2.5:0.5b，也支持云端 OpenAI 兼容）
- 📊 系统负载拟态（CPU 真实采样，负载变高 → 身体变色 + 冒汗 + 均衡器跳动）
- 🏃 高驰 MCP 联动（睡眠 / 恢复 / 跑步记录）
- 😊 心情打卡 + 本周日历
- 💤 离开检测（3 分钟无操作 → 宠物睡觉）
- 🚀 开机自启（LaunchAgent / app.setLoginItemSettings）

## 许可证
MIT
