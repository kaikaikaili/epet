# 麻薯（FocusPet）· Windows 版

Electron 跨平台版，宠物形态用 Canvas 画，逻辑和 macOS 版一致。

## 快速启动（在 Windows 上）

```bash
# 1. 装 Node.js 20+（https://nodejs.org/）

# 2. 拷贝整个 focus-pet-win 文件夹到 Windows

# 3. 安装依赖 + 跑
cd focus-pet-win
npm install
npm start
```

## 构建 Windows 安装包

```bash
npm run build:win
# 产物在 dist/ 下，.exe 安装包
```

## 和 macOS 版的对应关系

| 功能 | macOS 版 | Windows 版 |
|---|---|---|
| 宠物形态 | SwiftUI Shape | Canvas 2D |
| 悬浮窗 | NSPanel | Electron BrowserWindow (frame:false) |
| 拖拽 | NSEvent 监听 | mousedown/mousemove + Electron 坐标 |
| 菜单栏 | NSStatusItem + NSMenu | Electron Tray + Menu |
| 开机自启 | LaunchAgent plist | app.setLoginItemSettings()（自动处理 Win/Mac/Linux） |
| CPU 真实采样 | Mach API host_processor_info | Node os.cpus() 两次采样 |
| 内存 | vm_statistics64 | Node os.totalmem() - os.freemem() |
| 本地持久化 | UserDefaults | electron-store |
| Ollama 聊天 | URLSession | fetch |
| 高驰 MCP | URLSession | fetch（同理） |
| 饭团盲盒 / XP / 心情打卡 | PetBrain | PetBrain（同逻辑 TS 化） |

## 已知限制

1. 高驰 OAuth 回调：macOS 版用 127.0.0.1:8765 本地回调，Windows 版需要同理改一个端口，浏览器授权完手动填 token
2. `electron-builder --win` 在 Mac 上可以交叉编译，但需要装 wine 或指定 nsis 资源；最稳的是在 Windows 上直接构建
3. 托盘图标 assets/tray.png 和安装图标 assets/icon.ico 需要自己放（不影响运行，只影响打包）

## 聊天默认配置

首次启动自动指向本地 Ollama（`http://127.0.0.1:11434/v1`，模型 `qwen2.5:0.5b`）。没装 Ollama 时聊天会显示「麻薯还没醒」，也可以改 `localStorage.chatSettings` 切云端（DeepSeek / 通义都行）。
