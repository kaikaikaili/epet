import Foundation

struct FocusSession: Codable {
    var running: Bool = false
    var remaining: Int = 25 * 60
    var total: Int = 25 * 60
}

struct PetState: Codable {
    var xp: Double = 0
    var hunger: Double = 80
    var rice: Int = 3
    var flavors: [String: Int]? = nil
    var streakDays: Int = 0
    var lastActiveDay: String?
    var moods: [String: Int]? = nil
    var totalFocusMinutes: Int = 0
    var session: FocusSession = FocusSession()

    var level: Int {
        var level = 1
        while xp >= 25.0 * Double(level) * Double(level + 1) {
            level += 1
        }
        return level
    }

    /// 0 小团子 · 1 撒粉 · 2 微胖 · 3 带馅 · 4 大福
    var stage: Int {
        switch level {
        case 25...: return 4
        case 15...: return 3
        case 10...: return 2
        case 5...: return 1
        default: return 0
        }
    }

    var stageName: String {
        ["小团子", "撒粉团子", "微胖麻薯", "带馅麻薯", "大福"][stage]
    }

    var xpIntoLevel: Double {
        let base = 25.0 * Double(level - 1) * Double(level)
        return max(0, xp - base)
    }

    var xpForLevel: Double {
        25.0 * Double(level) * Double(level + 1) - 25.0 * Double(level - 1) * Double(level)
    }

    var progress: Double {
        min(1, max(0, xpIntoLevel / max(1, xpForLevel)))
    }

    var timeText: String {
        let m = max(0, session.remaining) / 60
        let s = max(0, session.remaining) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
