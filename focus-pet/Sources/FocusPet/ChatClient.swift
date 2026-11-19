import Foundation

enum ChatConfig {
    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "ChatBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "ChatBaseURL") }
    }

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: "ChatAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "ChatAPIKey") }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: "ChatModel") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "ChatModel") }
    }

    static var isConfigured: Bool {
        !baseURL.isEmpty && !model.isEmpty
    }

    /// 默认接本机 Ollama，开箱即用；用户填了别的地址就以用户为准
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "ChatBaseURL": "http://127.0.0.1:11434/v1",
            "ChatModel": "qwen2.5:0.5b",
            "ChatAPIKey": ""
        ])
    }

    static var isLocal: Bool {
        baseURL.contains("127.0.0.1") || baseURL.contains("localhost")
    }
}

enum ChatError: LocalizedError {
    case notConfigured
    case badURL
    case server(Int, String)
    case badResponse
    case localDown

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没设置聊天模型，先点菜单里的「聊天设置」"
        case .badURL:
            return "接口地址填得不对，看看设置里有没有漏 http"
        case let .server(code, detail):
            let brief = detail
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(60)
            return "模型没回话（\(code)）\(brief)"
        case .badResponse:
            return "它说的话我没看懂，再试一次？"
        case .localDown:
            return "本地模型没开着，先打开 Ollama 再来找我"
        }
    }
}

final class ChatClient {
    static let shared = ChatClient()

    private var history: [[String: String]] = []

    func reply(to text: String) async throws -> String {
        guard ChatConfig.isConfigured else { throw ChatError.notConfigured }
        guard let url = endpoint(from: ChatConfig.baseURL) else { throw ChatError.badURL }

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt()]]
        messages.append(contentsOf: history)
        messages.append(["role": "user", "content": text])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !ChatConfig.apiKey.isEmpty {
            request.setValue("Bearer \(ChatConfig.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": ChatConfig.model,
            "messages": messages,
            "temperature": 0.9,
            "max_tokens": 180,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await send(request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ChatError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ChatError.badResponse
        }

        let reply = clean(content)
        guard !reply.isEmpty else { throw ChatError.badResponse }

        history.append(["role": "user", "content": text])
        history.append(["role": "assistant", "content": reply])
        if history.count > 8 {
            history.removeFirst(history.count - 8)
        }
        return reply
    }

    // MARK: - 地址

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            if ChatConfig.isLocal, error is URLError {
                throw ChatError.localDown
            }
            throw error
        }
    }

    /// 兼容 base url、带 /v1 的地址，以及直接写全 /chat/completions 的情况
    private func endpoint(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.hasPrefix("http") else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/chat/completions") { return URL(string: text) }

        guard let parsed = URL(string: text) else { return nil }
        let path = parsed.path
        if path.isEmpty || path == "/" {
            text += "/v1"
        }
        return URL(string: text + "/chat/completions")
    }

    // MARK: - 人格

    private func systemPrompt() -> String {
        let state = PetBrain.shared.state
        let hour = Calendar.current.component(.hour, from: Date())

        var facts = [
            "现在是 \(hour) 点",
            "你的形态是\(state.stageName)",
            "饱腹 \(Int(state.hunger))/100",
            "兜里还有 \(state.rice) 个饭团"
        ]
        if state.session.running {
            facts.append("正在陪用户专注，还剩 \(max(0, state.session.remaining) / 60) 分钟")
        } else {
            facts.append("现在没在计时")
        }
        if state.streakDays > 0 {
            facts.append("连续专注 \(state.streakDays) 天")
        }
        if let snapshot = CorosCache.shared.snapshot,
           Date().timeIntervalSince(snapshot.updatedAt) < 20 * 3600 {
            if let minutes = snapshot.sleepMinutes {
                facts.append("用户昨晚睡了 \(minutes / 60) 小时 \(minutes % 60) 分")
            }
            if let recovery = snapshot.recoveryPercent {
                facts.append("身体恢复 \(recovery)%")
            }
        }

        return """
        你叫麻薯，是用户 Mac 桌面上的一只麻薯小宠物，平时陪着用户专注。
        你说话软软的、轻轻的，像懂事但不啰嗦的朋友，不要客气话堆砌。
        规则：用中文；每次最多两句、40 字以内；不用列表、markdown、引号包裹整段话；不要提自己是 AI、模型或程序；表情最多一个。
        你知道的情况：\(facts.joined(separator: "，"))。
        不知道的事就老实说不知道。
        """
    }

    private func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: "\n\n", with: "\n")
        result = result.replacingOccurrences(of: "**", with: "")
        for pair in [("\"", "\""), ("“", "”"), ("「", "」")] {
            if result.hasPrefix(pair.0), result.hasSuffix(pair.1), result.count > 2 {
                result = String(result.dropFirst().dropLast())
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
