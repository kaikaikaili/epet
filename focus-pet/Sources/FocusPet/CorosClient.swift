import Foundation
import CryptoKit
import Network

struct CorosTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

struct CorosSnapshot: Codable {
    var updatedAt: Date
    var sleepScore: Int?
    var sleepMinutes: Int?
    var recoveryPercent: Int?
    var recoveryLevel: String?

    var sleepText: String {
        guard let minutes = sleepMinutes else { return "—" }
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
    }
}

enum CorosError: LocalizedError {
    case oauth(String)
    case http(Int, String)
    case protocolError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .oauth(let message): return message
        case .http(let code, let body): return "HTTP \(code) \(body.prefix(120))"
        case .protocolError(let message): return message
        case .timeout: return "授权超时"
        }
    }
}

struct CorosRun: Codable {
    var day: String
    var distanceKm: Double
    var durationSec: Int?
    var paceSec: Int?

    var durationText: String {
        guard let sec = durationSec, sec > 0 else { return "—" }
        return String(format: "%d:%02d:%02d", sec / 3600, sec % 3600 / 60, sec % 60)
    }

    var paceText: String {
        guard let sec = paceSec, sec > 0 else { return "—" }
        return "\(sec / 60)'\(String(format: "%02d", sec % 60))\""
    }
}

final class CorosCache {
    static let shared = CorosCache()
    private let lock = NSLock()
    private var value: CorosSnapshot?
    private var runsValue: [CorosRun] = []

    var snapshot: CorosSnapshot? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }

    var runs: [CorosRun] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return runsValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            runsValue = newValue
        }
    }
}

@MainActor
final class CorosClient: ObservableObject {
    static let shared = CorosClient()

    @Published private(set) var connected = false
    @Published private(set) var snapshot: CorosSnapshot?

    private let base = "https://mcpcn.coros.com"
    private let redirectURI = "http://127.0.0.1:8765/callback"
    private let clientKey = "CorosClientID"
    private let tokenKey = "CorosTokens"
    private let snapshotKey = "CorosSnapshot"
    private let runsKey = "CorosRuns"

    private var clientId: String
    private var verifier = ""
    private var expectedState = ""
    private var tokens: CorosTokens?
    private var sessionId: String?
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<Void, Error>?

    private init() {
        clientId = UserDefaults.standard.string(forKey: clientKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: tokenKey),
           let saved = try? JSONDecoder().decode(CorosTokens.self, from: data) {
            tokens = saved
            connected = true
        }
        if let data = UserDefaults.standard.data(forKey: snapshotKey),
           let saved = try? JSONDecoder().decode(CorosSnapshot.self, from: data) {
            snapshot = saved
            CorosCache.shared.snapshot = saved
        }
        if let data = UserDefaults.standard.data(forKey: runsKey),
           let saved = try? JSONDecoder().decode([CorosRun].self, from: data) {
            CorosCache.shared.runs = saved
        }
    }

    // MARK: - 授权

    func beginAuthorization() async throws -> URL {
        if clientId.isEmpty {
            try await register()
        }

        verifier = Self.randomString(64)
        expectedState = Self.randomString(24)

        var components = URLComponents(string: base + "/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid mcp.tools offline_access"),
            URLQueryItem(name: "state", value: expectedState),
            URLQueryItem(name: "code_challenge", value: Self.s256(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        try startListener()
        return components.url!
    }

    func waitForCallback() async throws {
        try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                if self.callbackContinuation != nil {
                    self.finishCallback(.failure(CorosError.timeout))
                }
            }
        }
    }

    private func finishCallback(_ result: Result<Void, Error>) {
        guard let continuation = callbackContinuation else { return }
        callbackContinuation = nil
        listener?.cancel()
        listener = nil

        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func register() async throws {
        let payload: [String: Any] = [
            "client_name": "FocusPet",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "token_endpoint_auth_method": "none",
            "scope": "openid mcp.tools offline_access"
        ]
        var request = URLRequest(url: URL(string: base + "/connect/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CorosError.http((response as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["client_id"] as? String else {
            throw CorosError.protocolError("注册响应缺少 client_id")
        }
        clientId = id
        UserDefaults.standard.set(id, forKey: clientKey)
    }

    // MARK: - 回调监听

    private func startListener() throws {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: 8765)!
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let body = "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:120px;color:#333\"><h2>麻薯已经收到啦</h2><p>可以关掉这个页面了</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: response.data(using: .utf8),
                                completion: .contentProcessed { _ in connection.cancel() })

                guard let data = data, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    await self?.handleCallback(text)
                }
            }
        }
        listener.start(queue: .main)
    }

    private func handleCallback(_ request: String) async {
        guard let firstLine = request.split(separator: "\r\n").first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1" + target) else { return }

        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            finishCallback(.failure(CorosError.oauth(error)))
            return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { return }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            finishCallback(.failure(CorosError.oauth("state 校验失败")))
            return
        }

        do {
            try await exchange(code: code)
            connected = true
            finishCallback(.success(()))
        } catch {
            finishCallback(.failure(error))
        }
    }

    private func exchange(code: String) async throws {
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        let json = try await postForm(path: "/oauth2/token", form: form)
        try applyToken(json)
    }

    private func refreshIfNeeded() async throws {
        guard let tokens = tokens else { throw CorosError.oauth("未授权") }
        guard Date() >= tokens.expiresAt.addingTimeInterval(-120) else { return }
        guard let refreshToken = tokens.refreshToken else { throw CorosError.oauth("登录已过期，请重新连接") }

        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ]
        let json = try await postForm(path: "/oauth2/token", form: form)
        try applyToken(json)
    }

    private func applyToken(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String else {
            throw CorosError.oauth((json["error"] as? String) ?? "获取 token 失败")
        }
        let expires = (json["expires_in"] as? Double) ?? 3600
        let refreshed = CorosTokens(accessToken: access,
                                    refreshToken: (json["refresh_token"] as? String) ?? tokens?.refreshToken,
                                    expiresAt: Date().addingTimeInterval(expires))
        tokens = refreshed
        sessionId = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(refreshed), forKey: tokenKey)
    }

    func disconnect() {
        tokens = nil
        sessionId = nil
        connected = false
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    private func postForm(path: String, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = form.map { key, value in
            "\(Self.escape(key))=\(Self.escape(value))"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200 else {
            throw CorosError.oauth((object["error"] as? String) ?? "HTTP \(status)")
        }
        return object
    }

    // MARK: - MCP

    func sync() async {
        guard connected else { return }
        do {
            let sleepText = try await callTool("querySleepOverview", arguments: ["days": 1])
            let recoveryText = try await callTool("queryRecoveryStatus", arguments: [:])

            let sleepMinutesValue = Self.minutes(from: sleepText)
            let snapshot = CorosSnapshot(
                updatedAt: Date(),
                sleepScore: Self.intValue("Sleep Score: ([0-9]+)", in: sleepText),
                sleepMinutes: sleepMinutesValue,
                recoveryPercent: Self.intValue("Recovery: ([0-9]+)%", in: recoveryText),
                recoveryLevel: Self.textValue("Level: ([A-Za-z]+)", in: recoveryText)
            )
            self.snapshot = snapshot
            CorosCache.shared.snapshot = snapshot
            UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
        } catch {
            print("COROS sync failed: \(error.localizedDescription)")
        }

        // 跑步记录，参数格式不确定，先按 days 7 试，再退到无参数
        let sportText: String?
        if let text = try? await callTool("querySportRecords", arguments: ["days": 7]) {
            sportText = text
        } else if let text = try? await callTool("querySportRecords", arguments: [:]) {
            sportText = text
        } else {
            sportText = nil
        }
        if let text = sportText {
            let runs = Self.parseRuns(text)
            CorosCache.shared.runs = runs
            UserDefaults.standard.set(try? JSONEncoder().encode(runs), forKey: runsKey)
        }
    }

    /// 解析高驰 MCP 返回的多行文本。
    /// 真实格式：日期在记录标题行（`1. Track Run — 2026-11-18`），距离/时长/配速在下方字段行。
    static func parseRuns(_ text: String) -> [CorosRun] {
        var runs: [CorosRun] = []
        var pending: CorosRun?

        func flush() {
            if var run = pending {
                // 必须有距离才算一条记录
                if run.distanceKm > 0.2 { runs.append(run) }
                pending = nil
            }
        }

        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)

            // 新记录标题行：编号 + 类型名 + 日期
            if let day = Self.textValue("—\\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", in: line)
                    ?? Self.textValue("^\\s*[0-9]+\\.\\s*.*([0-9]{4}-[0-9]{2}-[0-9]{2})", in: line) {
                flush()
                pending = CorosRun(day: day, distanceKm: 0, durationSec: nil, paceSec: nil)
                continue
            }
            guard pending != nil else { continue }

            // Distance: 3.19 km
            if let km = Self.textValue("Distance:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*km", in: line) {
                pending?.distanceKm = Double(km) ?? 0
            }
            // Duration: 51:29 或 1:02:30
            if let hms = Self.textValue("Duration:\\s*([0-9:]+)", in: line) {
                let parts = hms.split(separator: ":").compactMap { Int($0) }
                if parts.count == 3 {
                    pending?.durationSec = parts[0] * 3600 + parts[1] * 60 + parts[2]
                } else if parts.count == 2 {
                    pending?.durationSec = parts[0] * 60 + parts[1]
                }
            }
            // Average Pace: 4:17 /km
            if let pace = Self.textValue("Pace:\\s*([0-9]{1,2}:[0-9]{2})", in: line) {
                let parts = pace.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 {
                    pending?.paceSec = parts[0] * 60 + parts[1]
                }
            }
        }
        flush()
        return runs.sorted { $0.day > $1.day }
    }

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        let response = try await rpc(method: "tools/call",
                                     params: ["name": name, "arguments": arguments],
                                     id: 2)
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              var text = content.first?["text"] as? String else {
            throw CorosError.protocolError("返回格式异常")
        }

        // 服务端返回的是「被 JSON 再包了一层」的字符串
        if text.hasPrefix("\""), let data = text.data(using: .utf8),
           let unwrapped = try? JSONDecoder().decode(String.self, from: data) {
            text = unwrapped
        }
        return text
    }

    private func rpc(method: String, params: [String: Any], id: Int, retry: Bool = true) async throws -> [String: Any] {
        try await refreshIfNeeded()
        if sessionId == nil {
            try await initializeSession()
        }
        return try await send(method: method, params: params, id: id, retry: retry)
    }

    private func initializeSession() async throws {
        _ = try await send(method: "initialize",
                           params: [
                               "protocolVersion": "2025-06-18",
                               "capabilities": [:],
                               "clientInfo": ["name": "FocusPet", "version": "1.0"]
                           ],
                           id: 1,
                           retry: false)
        _ = try await send(method: "notifications/initialized", params: [:], id: nil, retry: false)
    }

    private func send(method: String, params: [String: Any], id: Int?, retry: Bool) async throws -> [String: Any] {
        guard let tokens = tokens else { throw CorosError.oauth("未授权") }

        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id = id { body["id"] = id }
        if !params.isEmpty { body["params"] = params }

        var request = URLRequest(url: URL(string: base + "/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId = sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        if let newSession = http?.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionId = newSession
        }

        if status == 401, retry {
            sessionId = nil
            var expired = tokens
            expired.expiresAt = .distantPast
            self.tokens = expired
            try await refreshIfNeeded()
            return try await send(method: method, params: params, id: id, retry: false)
        }

        guard status == 200 || status == 202 else {
            throw CorosError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        if id == nil { return [:] }

        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let object = parse(data: data, contentType: contentType) else {
            throw CorosError.protocolError("无法解析 MCP 响应")
        }
        if let error = object["error"] as? [String: Any] {
            throw CorosError.protocolError((error["message"] as? String) ?? "MCP 错误")
        }
        return object
    }

    private func parse(data: Data, contentType: String) -> [String: Any]? {
        if contentType.contains("event-stream"), let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let payloadData = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { continue }
                if object["result"] != nil || object["error"] != nil { return object }
            }
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - 工具

    private static func randomString(_ length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func s256(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func intValue(_ pattern: String, in text: String) -> Int? {
        textValue(pattern, in: text).flatMap { Int($0) }
    }

    private static func textValue(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func minutes(from text: String) -> Int? {
        if let hours = intValue("Main Sleep \\(asleep\\): ([0-9]+)h", in: text) {
            let mins = intValue("Main Sleep \\(asleep\\): [0-9]+h ([0-9]+)min", in: text) ?? 0
            return hours * 60 + mins
        }
        return intValue("Main Sleep \\(asleep\\): ([0-9]+)min", in: text)
    }
}
