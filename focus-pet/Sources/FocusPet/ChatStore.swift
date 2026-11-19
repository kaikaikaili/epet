import Foundation

/// 悬浮气泡聊天：消息不打断对话流，以气泡形式显示在宠物头顶，自动上浮消散
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    struct Bubble: Identifiable, Equatable {
        let id = UUID()
        var text: String
        let isUser: Bool
        var fading = false
    }

    @Published private(set) var bubbles: [Bubble] = []
    @Published private(set) var pending = false
    @Published var draft = ""

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !pending else { return }
        append(Bubble(text: text, isUser: true))
        pending = true

        Task {
            do {
                let reply = try await ChatClient.shared.reply(to: text)
                await MainActor.run {
                    self.pending = false
                    self.append(Bubble(text: reply, isUser: false))
                }
            } catch {
                await MainActor.run {
                    self.pending = false
                    self.append(Bubble(text: error.localizedDescription, isUser: false))
                }
            }
        }
    }

    private func append(_ bubble: Bubble) {
        bubbles.append(bubble)
        if bubbles.count > 3 {
            bubbles.removeFirst(bubbles.count - 3)
        }

        let id = bubble.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  let index = self.bubbles.firstIndex(where: { $0.id == id }) else { return }
            self.bubbles[index].fading = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.bubbles.removeAll { $0.id == id }
            }
        }
    }
}
