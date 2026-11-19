import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var petWindow: NSWindow?

    /// 宠物窗要能成为 key window，否则输入框拿不到键盘焦点
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var hiddenByUser = false
    private var dragOffset: NSPoint?
    private var dragMoved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ChatConfig.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        setupPanel()
        setupStatusItem()
        installDragMonitor()

        // 开机自启：默认开启，除非用户手动关过
        if !UserDefaults.standard.bool(forKey: "AutoLaunchDisabled") {
            installLaunchAgent()
        }

        Task { await CorosClient.shared.sync() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PetBrain.shared.save(force: true)
    }

    // MARK: - 浮窗

    private func setupPanel() {
        let size = NSSize(width: 210, height: 380)
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PetView())
        panel.setFrameOrigin(defaultOrigin(for: size))
        panel.orderFrontRegardless()
        self.panel = panel
        AppDelegate.petWindow = panel
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: "PetWindowOrigin") {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                let origin = NSPoint(x: parts[0], y: parts[1])
                let rect = NSRect(origin: origin, size: size)
                if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                    return origin
                }
            }
        }
        guard let screen = NSScreen.main else { return .zero }
        let frame = screen.visibleFrame
        return NSPoint(x: frame.maxX - size.width - 20, y: frame.minY + 20)
    }

    // MARK: - 原生拖拽（比 SwiftUI 手势跟手）

    private func installDragMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self,
                  let panel = self.panel,
                  event.window === panel else { return event }

            // 底部信息条留给按钮，其余区域都能拖
            if event.locationInWindow.y < 75 { return event }

            // 鼠标靠近时顶部是聊天输入区，点击要透传给输入框
            if PetUIModel.shared.near && event.locationInWindow.y > 210 {
                if event.type == .leftMouseDown {
                    panel.makeKey()
                }
                return event
            }

            switch event.type {
            case .leftMouseDown:
                self.dragOffset = NSPoint(
                    x: NSEvent.mouseLocation.x - panel.frame.origin.x,
                    y: NSEvent.mouseLocation.y - panel.frame.origin.y
                )
                self.dragMoved = false
                return nil

            case .leftMouseDragged:
                guard let offset = self.dragOffset else { return event }
                let location = NSEvent.mouseLocation
                panel.setFrameOrigin(NSPoint(x: location.x - offset.x,
                                             y: location.y - offset.y))
                self.dragMoved = true
                return nil

            case .leftMouseUp:
                if self.dragMoved {
                    self.savePosition()
                }
                self.dragOffset = nil
                return nil

            default:
                return event
            }
        }
    }

    private func savePosition() {
        guard let panel = panel else { return }
        UserDefaults.standard.set("\(panel.frame.origin.x),\(panel.frame.origin.y)",
                                  forKey: "PetWindowOrigin")
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🌱"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = PetBrain.shared.state

        let status = NSMenuItem(
            title: state.session.running ? "专注中 · \(state.timeText)" : "休息中 · \(state.timeText)",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        let sys = NSMenuItem(title: systemStatusText(), action: nil, keyEquivalent: "")
        sys.isEnabled = false
        menu.addItem(sys)
        menu.addItem(.separator())

        addItem(to: menu, title: state.session.running ? "暂停专注" : "开始专注", action: #selector(toggleSession))
        addItem(to: menu, title: "重置计时", action: #selector(resetSession))
        addItem(to: menu, title: "喂一个饭团（\(state.rice)）", action: #selector(feed))
        addItem(to: menu, title: "饭团图鉴", action: #selector(showRecipe))

        // 心情打卡
        let week = NSMenuItem(
            title: "本周心情  \(PetBrain.moodWeekText())",
            action: nil,
            keyEquivalent: ""
        )
        week.isEnabled = false
        menu.addItem(week)

        let moodMenu = NSMenu()
        for (index, mood) in PetBrain.moodCatalog.enumerated() {
            let item = NSMenuItem(title: "\(mood.emoji) \(mood.name)",
                                  action: #selector(logMood(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = index
            moodMenu.addItem(item)
        }
        let moodItem = NSMenuItem(title: "今天心情打卡", action: nil, keyEquivalent: "")
        moodItem.submenu = moodMenu
        menu.addItem(moodItem)

        // 跑步面板
        let runs = CorosCache.shared.runs
        if CorosClient.shared.connected {
            if runs.isEmpty {
                let runInfo = NSMenuItem(
                    title: "跑步 · 暂无记录，点「同步高驰数据」试试",
                    action: nil,
                    keyEquivalent: ""
                )
                runInfo.isEnabled = false
                menu.addItem(runInfo)
            } else {
                let weekAgo = Date().addingTimeInterval(-7 * 86400)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let weekly = runs.filter { run in
                    formatter.date(from: run.day).map { $0 >= weekAgo } ?? false
                }.reduce(0.0) { $0 + $1.distanceKm }
                let runInfo = NSMenuItem(
                    title: String(format: "跑步 · 近7天 %.1f km · 最近 %@ %.1f km",
                                  weekly, Self.shortDay(runs[0].day), runs[0].distanceKm),
                    action: nil,
                    keyEquivalent: ""
                )
                runInfo.isEnabled = false
                menu.addItem(runInfo)
                addItem(to: menu, title: "查看最近跑步", action: #selector(showRuns))
            }
        } else {
            let runInfo = NSMenuItem(
                title: "跑步 · 连接高驰后显示",
                action: nil,
                keyEquivalent: ""
            )
            runInfo.isEnabled = false
            menu.addItem(runInfo)
        }

        addItem(to: menu, title: "聊天设置…", action: #selector(showChatSettings))
        menu.addItem(.separator())

        if CorosClient.shared.connected {
            if let snapshot = CorosClient.shared.snapshot {
                let recovery = snapshot.recoveryPercent.map { "\($0)%" } ?? "—"
                let info = NSMenuItem(title: "高驰 · 睡眠 \(snapshot.sleepText) · 恢复 \(recovery)",
                                      action: nil,
                                      keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
            }
            addItem(to: menu, title: "同步高驰数据", action: #selector(syncCoros))
            addItem(to: menu, title: "断开高驰", action: #selector(disconnectCoros))
        } else {
            addItem(to: menu, title: "连接高驰…", action: #selector(connectCoros))
        }

        let login = NSMenuItem(
            title: isLoginItem ? "开机自启 ✓" : "开机自启",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        addItem(to: menu, title: hiddenByUser ? "显示麻薯" : "隐藏麻薯", action: #selector(toggleVisibility))
        addItem(to: menu, title: "退出", action: #selector(quit))
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - 系统状态

    private func systemStatusText() -> String {
        let brain = PetBrain.shared
        let cpuText: String
        if brain.cpuPercent > 0 {
            let tag = brain.loadLevel == 2 ? " · 我冒汗了" : (brain.loadLevel == 1 ? " · 有点忙" : "")
            cpuText = "CPU \(brain.cpuPercent)%\(tag)"
        } else {
            cpuText = "CPU —"
        }

        let memText: String
        if brain.memUsedGB > 0 {
            memText = String(format: "内存 %.1f / %.1f GB", brain.memUsedGB, brain.memTotalGB)
        } else {
            memText = "内存 —"
        }

        return "系统 · \(cpuText) · \(memText)"
    }

    private func memoryUsedGB() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<natural_t>.size)
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        return Double(used) / 1e9
    }

    @objc private func toggleSession() {
        PetBrain.shared.toggleSession()
    }

    @objc private func resetSession() {
        PetBrain.shared.reset()
    }

    @objc private func feed() {
        PetBrain.shared.feed()
    }

    // MARK: - 心情打卡

    @objc private func logMood(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        PetBrain.shared.logMood(index)
    }

    // MARK: - 跑步

    private static func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "\(parts[1])-\(parts[2])"
    }

    @objc private func showRuns() {
        let runs = CorosCache.shared.runs.prefix(5)
        let lines = runs.map { run in
            "\(Self.shortDay(run.day))  ·  \(String(format: "%.1f", run.distanceKm)) km  ·  \(run.durationText)  ·  配速 \(run.paceText)"
        }
        let alert = NSAlert()
        alert.messageText = "最近的跑步"
        alert.informativeText = lines.isEmpty ? "还没有跑步记录" : lines.joined(separator: "\n")
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 聊天

    @objc private func showChatSettings() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 98))
        let baseField = NSTextField(frame: NSRect(x: 76, y: 70, width: 310, height: 24))
        baseField.stringValue = ChatConfig.baseURL
        baseField.placeholderString = "https://api.deepseek.com/v1"

        let keyField = NSSecureTextField(frame: NSRect(x: 76, y: 38, width: 310, height: 24))
        keyField.stringValue = ChatConfig.apiKey
        keyField.placeholderString = "本地模型可以留空"

        let modelField = NSTextField(frame: NSRect(x: 76, y: 6, width: 310, height: 24))
        modelField.stringValue = ChatConfig.model
        modelField.placeholderString = "例如 deepseek-chat"

        for field in [baseField, keyField, modelField] {
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            container.addSubview(field)
        }

        let rows: [(String, CGFloat)] = [("接口地址", 70), ("API Key", 38), ("模型", 6)]
        for (title, y) in rows {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 3, width: 68, height: 18)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            container.addSubview(label)
        }

        let alert = NSAlert()
        alert.messageText = "麻薯的聊天设置"
        alert.informativeText = "填任意 OpenAI 兼容接口就行。\n本地 Ollama：地址 http://localhost:11434/v1，Key 留空。"
        alert.accessoryView = container
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        ChatConfig.baseURL = baseField.stringValue
        ChatConfig.apiKey = keyField.stringValue
        ChatConfig.model = modelField.stringValue
        PetBrain.shared.say(ChatConfig.isConfigured ? "记住了，随时找我" : "地址和模型都要填哦")
    }

    // MARK: - 高驰

    @objc private func connectCoros() {
        Task { @MainActor in
            do {
                let url = try await CorosClient.shared.beginAuthorization()
                NSWorkspace.shared.open(url)

                let alert = NSAlert()
                alert.messageText = "请在高驰页面完成授权"
                alert.informativeText = "浏览器已经打开了，登录后点「同意」。完成后麻薯会自己连上。"
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()

                try await CorosClient.shared.waitForCallback()
                await CorosClient.shared.sync()
                PetBrain.shared.say("连上高驰了")
            } catch {
                let alert = NSAlert()
                alert.messageText = "连接高驰失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func syncCoros() {
        Task { @MainActor in
            await CorosClient.shared.sync()
            PetBrain.shared.say("高驰数据更新了")
        }
    }

    @objc private func disconnectCoros() {
        Task { @MainActor in
            CorosClient.shared.disconnect()
            PetBrain.shared.say("先不看高驰了")
        }
    }

    @objc private func showRecipe() {
        let state = PetBrain.shared.state
        let owned = state.flavors ?? [:]
        let lines = PetBrain.catalog.map { flavor -> String in
            let count = owned[flavor.key] ?? 0
            return count > 0
                ? "\(flavor.emoji)  \(flavor.name)  ×\(count)"
                : "·  \(flavor.name)  还没尝过"
        }
        let alert = NSAlert()
        alert.messageText = "麻薯食谱图鉴"
        alert.informativeText = lines.joined(separator: "\n") + "\n\n现有饭团 \(state.rice) 个"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 开机自启（LaunchAgent，不依赖代码签名，重编译不失效）

    private var launchAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/com.likai.focuspet.plist")
    }

    private var isLoginItem: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private func runLaunchctl(_ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        try? proc.run()
        proc.waitUntilExit()
    }

    private func installLaunchAgent() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let appPath = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.likai.focuspet</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
            runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        } catch {
            NSLog("FocusPet launch agent error: \(error.localizedDescription)")
        }
    }

    private func removeLaunchAgent() {
        runLaunchctl(["bootout", "gui/\(getuid())/com.likai.focuspet"])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    @objc private func toggleLoginItem() {
        if isLoginItem {
            removeLaunchAgent()
            UserDefaults.standard.set(true, forKey: "AutoLaunchDisabled")
            PetBrain.shared.say("那下次记得叫我")
        } else {
            UserDefaults.standard.set(false, forKey: "AutoLaunchDisabled")
            installLaunchAgent()
            if isLoginItem {
                PetBrain.shared.say("开机我就在啦")
            } else {
                PetBrain.shared.say("唔……没装上，再试一次？")
            }
        }
    }

    @objc private func toggleVisibility() {
        guard let panel = panel else { return }
        hiddenByUser.toggle()
        if hiddenByUser {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func quit() {
        PetBrain.shared.save(force: true)
        NSApp.terminate(nil)
    }
}
