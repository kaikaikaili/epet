import Foundation
import CoreGraphics

struct Flavor {
    let key: String
    let name: String
    let emoji: String
    let weight: Int
}

final class PetBrain: ObservableObject {
    static let shared = PetBrain()

    static let catalog: [Flavor] = [
        Flavor(key: "seaweed", name: "海苔", emoji: "🍙", weight: 30),
        Flavor(key: "redbean", name: "红豆", emoji: "🫘", weight: 25),
        Flavor(key: "matcha", name: "抹茶", emoji: "🍵", weight: 20),
        Flavor(key: "sesame", name: "芝麻", emoji: "🌰", weight: 15),
        Flavor(key: "pudding", name: "焦糖布丁", emoji: "🍮", weight: 8)
    ]

    static let moodCatalog: [(name: String, emoji: String, reply: String)] = [
        ("开心", "🤩", "好耶，这股劲儿我也蹭到了"),
        ("平静", "🙂", "平平淡淡刚刚好"),
        ("疲惫", "😴", "那今晚早点休息，我守着"),
        ("烦躁", "😣", "先深呼吸，我陪你待一会儿")
    ]

    @Published private(set) var state: PetState
    @Published private(set) var bubbleText: String?
    @Published private(set) var isAway = false
    @Published private(set) var wokeRecently = false
    @Published private(set) var loadLevel = 0
    @Published private(set) var cpuPercent = 0
    @Published private(set) var memUsedGB: Double = 0
    @Published private(set) var memTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1e9

    /// 上一次 CPU tick 采样（idle / total）
    private var lastCpuIdle: UInt64 = 0
    private var lastCpuTotal: UInt64 = 0

    private let storeKey = "FocusPetState"
    private var lastSave = Date.distantPast
    private var timer: Timer?
    private var bubbleWork: DispatchWorkItem?
    private var lastLevel = 1
    private var wasHungry = false
    private var lastGreetedKey: String?
    private var sitSeconds = 0
    private var tickCount = 0
    private var lastLoadLevel = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode(PetState.self, from: data) {
            state = decoded
        } else {
            state = PetState()
        }
        lastLevel = state.level
        wasHungry = state.hunger < 22
        lastGreetedKey = UserDefaults.standard.string(forKey: "LastGreetedKey")
        startTimer()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.greetIfNeeded()
        }
    }

    // MARK: - 计时

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let away = systemIdleSeconds() > 180

        if away != isAway {
            isAway = away
            if away {
                if state.session.running {
                    state.session.running = false
                    save(force: true)
                }
                sitSeconds = 0
            } else {
                wokeRecently = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                    self?.wokeRecently = false
                }
            }
        }

        guard !isAway else { return }

        // 久坐提醒：连续坐 45 分钟推一把
        sitSeconds += 1
        if sitSeconds >= 45 * 60 {
            sitSeconds = 0
            bubble("坐了 45 分钟啦，起来晃两下再回来", duration: 4.5)
        }

        // 负载拟态：每 5 秒采一次样
        tickCount += 1
        // CPU 百分比每 tick 刷（~1s），loadLevel 继续 5s 一档
        updateCpuPercent()
        if tickCount % 5 == 0 {
            updateLoadLevel()
        }

        if state.session.running {
            state.session.remaining -= 1
            state.xp += 1.0 / 60.0
            state.hunger = max(0, state.hunger - 20.0 / 3600.0)
            if state.session.remaining <= 0 {
                completeSession()
            }
        } else {
            state.hunger = max(0, state.hunger - 10.0 / 3600.0)
        }

        if state.level > lastLevel {
            lastLevel = state.level
            bubble("我好像长大了一点")
        }

        if !wasHungry && state.hunger < 22 {
            wasHungry = true
            bubble("肚子有点空空的……你忙完再说")
        } else if wasHungry && state.hunger > 35 {
            wasHungry = false
        }

        greetIfNeeded()
        save()
    }

    // MARK: - 心情

    func logMood(_ index: Int) {
        guard PetBrain.moodCatalog.indices.contains(index) else { return }
        var dict = state.moods ?? [:]
        dict[dayString()] = index
        state.moods = dict
        bubble(PetBrain.moodCatalog[index].reply)
        save(force: true)
    }

    /// 最近 7 天心情表情，未打卡用 · 占位
    static func moodWeekText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let moods = shared.state.moods ?? [:]
        var text = ""
        for offset in stride(from: -6, through: 0, by: 1) {
            let day = formatter.string(from: Date().addingTimeInterval(Double(offset) * 86400))
            if let index = moods[day], moodCatalog.indices.contains(index) {
                text += moodCatalog[index].emoji
            } else {
                text += "·"
            }
        }
        return text
    }

    // MARK: - 负载

    private func updateCpuPercent() {
        // 真实 CPU 使用率：Mach API 采样每颗核心的 tick 计数差
        let current = sampleCpuTicks()
        defer { lastCpuIdle = current.idle; lastCpuTotal = current.total }

        // 第一次采样（启动后第一秒）没有基线，跳过
        guard lastCpuTotal > 0, current.total > lastCpuTotal else {
            cpuPercent = 0
            memUsedGB = memoryUsedGB()
            return
        }
        let idleDelta = current.idle - lastCpuIdle
        let totalDelta = current.total - lastCpuTotal
        let busyFraction = 1.0 - Double(idleDelta) / Double(totalDelta)
        cpuPercent = max(0, min(100, Int(busyFraction * 100)))
        memUsedGB = memoryUsedGB()
    }

    /// 采样所有核心的 idle / total tick 总数
    private func sampleCpuTicks() -> (idle: UInt64, total: UInt64) {
        var cpuCount: natural_t = 0
        var rawInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = withUnsafeMutablePointer(to: &rawInfo) { ptr in
            ptr.withMemoryRebound(to: processor_info_array_t?.self, capacity: 1) { rebound in
                host_processor_info(mach_host_self(),
                                    PROCESSOR_CPU_LOAD_INFO,
                                    &cpuCount,
                                    rebound,
                                    &infoCount)
            }
        }
        guard result == KERN_SUCCESS, let raw = rawInfo else { return (0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: raw), vm_size_t(infoCount)) }

        // processor_cpu_load_info 每个槽占 CPU_STATE_MAX (4) 个 Int32
        let cpuStateMax = 4
        var totalIdle: UInt64 = 0
        var totalAll: UInt64 = 0
        for i in 0..<Int(cpuCount) {
            let base = i * cpuStateMax
            let user   = UInt64(raw.advanced(by: base + 0).pointee) // STATE_USER
            let system = UInt64(raw.advanced(by: base + 1).pointee) // STATE_SYSTEM
            let idle   = UInt64(raw.advanced(by: base + 2).pointee) // STATE_IDLE
            let nice   = UInt64(raw.advanced(by: base + 3).pointee) // STATE_NICE
            totalAll += user + system + idle + nice
            totalIdle += idle
        }
        return (totalIdle, totalAll)
    }

    private func updateLoadLevel() {
        let level: Int
        if cpuPercent >= 50 { level = 2 }
        else if cpuPercent >= 25 { level = 1 }
        else { level = 0 }

        if level != lastLoadLevel {
            if level == 2, lastLoadLevel < 2 {
                bubble("机器都要冒烟了，歇口气吧", duration: 3.5)
            }
            lastLoadLevel = level
        }
        loadLevel = level
    }

    /// 已用内存（active + wire + 压缩），单位 GB
    private func memoryUsedGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return memUsedGB }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        return Double(used) / 1e9
    }

    // MARK: - 时间感

    private func greetIfNeeded() {
        let hour = Calendar.current.component(.hour, from: Date())
        let key = "\(dayString())-\(periodKey(hour))"
        guard key != lastGreetedKey else { return }
        lastGreetedKey = key
        UserDefaults.standard.set(key, forKey: "LastGreetedKey")
        bubble(greeting(hour), duration: 3.8)
    }

    private func periodKey(_ hour: Int) -> String {
        switch hour {
        case 5..<9: return "morning"
        case 9..<12: return "forenoon"
        case 12..<14: return "noon"
        case 14..<18: return "afternoon"
        case 18..<22: return "evening"
        default: return "night"
        }
    }

    private func greeting(_ hour: Int) -> String {
        if hour >= 5 && hour < 12,
           let snapshot = CorosCache.shared.snapshot,
           Date().timeIntervalSince(snapshot.updatedAt) < 20 * 3600,
           let minutes = snapshot.sleepMinutes {
            var text = "早上好，昨晚睡了 \(minutes / 60) 小时 \(minutes % 60) 分"
            if let recovery = snapshot.recoveryPercent {
                text += recovery < 50 ? "，恢复一般，今天别硬练" : "，状态不错"
            }
            return text
        }

        switch hour {
        case 5..<9: return "早上好，今天也一起加油"
        case 9..<12: return "上午好，先挑一件最重要的事？"
        case 12..<14: return "中午啦，别忘了吃饭"
        case 14..<18: return "下午好，慢慢来就好"
        case 18..<22: return "晚上好，还要忙一会儿吗"
        default: return "夜深了，我陪你一会儿，但别太晚"
        }
    }

    private func completeSession() {
        let flavor = rollFlavor()
        state.xp += 5
        state.rice += 1
        state.totalFocusMinutes += state.session.total / 60
        var dict = state.flavors ?? [:]
        dict[flavor.key, default: 0] += 1
        state.flavors = dict
        state.session.remaining = state.session.total
        state.session.running = false
        bumpStreak()
        bubble("\(flavor.emoji) \(flavor.name)，攒到一个")
        save(force: true)
    }

    private func rollFlavor() -> Flavor {
        let total = Self.catalog.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<total)
        for flavor in Self.catalog {
            if roll < flavor.weight { return flavor }
            roll -= flavor.weight
        }
        return Self.catalog[0]
    }

    private func bumpStreak() {
        let today = dayString()
        guard state.lastActiveDay != today else { return }
        if let last = state.lastActiveDay,
           let date = dayFormatter.date(from: last),
           Calendar.current.isDateInYesterday(date) {
            state.streakDays += 1
        } else {
            state.streakDays = 1
        }
        state.lastActiveDay = today
    }

    // MARK: - 操作

    func toggleSession() {
        if state.session.running {
            state.session.running = false
        } else {
            if state.session.remaining <= 0 {
                state.session.remaining = state.session.total
            }
            state.session.running = true
            bubble("我坐好了")
        }
        save(force: true)
    }

    func reset() {
        state.session.running = false
        state.session.remaining = state.session.total
        save(force: true)
    }

    func feed() {
        guard state.rice > 0, state.hunger < 99 else { return }

        var dict = state.flavors ?? [:]
        let key = dict.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
        let flavor = Self.catalog.first { $0.key == key } ?? Self.catalog[0]
        if let key = key {
            dict[key] = max(0, (dict[key] ?? 0) - 1)
        }
        state.flavors = dict
        state.rice -= 1
        state.hunger = min(100, state.hunger + 25)
        bubble("唔……\(flavor.name)味的")
        save(force: true)
    }

    func say(_ text: String) {
        bubble(text, duration: 2.8)
    }

    func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSave) > 5 else { return }
        lastSave = Date()
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    // MARK: - 气泡

    private func bubble(_ text: String, duration: Double = 2.4) {
        bubbleWork?.cancel()
        bubbleText = text
        let work = DispatchWorkItem { [weak self] in
            self?.bubbleText = nil
        }
        bubbleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - 工具

    private func systemIdleSeconds() -> Double {
        guard let anyEvent = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func dayString() -> String {
        dayFormatter.string(from: Date())
    }
}
