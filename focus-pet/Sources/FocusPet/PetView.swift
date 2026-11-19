import SwiftUI
import Combine
import AppKit

final class PetUIModel: ObservableObject {
    static let shared = PetUIModel()

    @Published var breathe = false
    @Published var blink = false
    @Published var near = false
    @Published var look = CGPoint.zero

    private var blinkTimer: Timer?
    private var proximityTimer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            breathe = true
        }

        let timer = Timer(timeInterval: 4.5, repeats: true) { [weak self] _ in
            self?.blinkOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer

        let proximity = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateProximity()
        }
        RunLoop.main.add(proximity, forMode: .common)
        proximityTimer = proximity
    }

    /// 鼠标靠近时，眼睛和身体跟着转过去
    private func updateProximity() {
        guard let window = AppDelegate.petWindow else { return }
        let mouse = NSEvent.mouseLocation
        let center = NSPoint(x: window.frame.midX,
                             y: window.frame.maxY - 235)
        let dx = mouse.x - center.x
        let dy = mouse.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        let isNear = distance < 165
        if isNear != near {
            withAnimation(.easeOut(duration: 0.28)) { near = isNear }
        }

        guard isNear else {
            if look != .zero {
                withAnimation(.easeOut(duration: 0.45)) { look = .zero }
            }
            return
        }

        let next = CGPoint(x: max(-1, min(1, dx / 110)),
                           y: max(-1, min(1, dy / 110)))
        if abs(next.x - look.x) > 0.05 || abs(next.y - look.y) > 0.05 {
            withAnimation(.easeOut(duration: 0.16)) { look = next }
        }
    }

    private func blinkOnce() {
        withAnimation(.easeOut(duration: 0.08)) { blink = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            withAnimation(.easeIn(duration: 0.10)) { self?.blink = false }
        }
    }
}

struct PetView: View {
    @ObservedObject private var brain = PetBrain.shared
    @ObservedObject private var ui = PetUIModel.shared
    @ObservedObject private var chat = ChatStore.shared

    private var state: PetState { brain.state }

    /// 鼠标靠近宠物时浮现输入框
    private var inputVisible: Bool {
        ui.near && !brain.isAway
    }

    private var bodyW: CGFloat { 100 + CGFloat(state.stage) * 7 }
    private var bodyH: CGFloat { 99 + CGFloat(state.stage) * 6 }
    private var corner: CGFloat { bodyW * 0.47 }

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var bodyColor: Color {
        if state.hunger < 22 {
            return Color(red: 0.62, green: 0.82, blue: 0.71)
        }
        if state.session.running {
            return Color(red: 0.38, green: 0.90, blue: 0.71)
        }
        return Color(red: 0.47, green: 0.86, blue: 0.69)
    }

    private var accent: Color {
        if state.hunger < 22 { return Color(red: 0.91, green: 0.55, blue: 0.42) }
        if state.hunger < 45 { return Color(red: 0.93, green: 0.62, blue: 0.20) }
        return Color(red: 0.05, green: 0.55, blue: 0.34)
    }

    private var panelColor: Color {
        isDark ? Color(white: 0.13).opacity(0.96) : Color.white.opacity(0.96)
    }

    private var primaryText: Color {
        isDark ? Color(white: 0.92) : Color(white: 0.10)
    }

    private var secondaryText: Color {
        isDark ? Color(white: 0.92).opacity(0.62) : Color(white: 0.10).opacity(0.55)
    }

    private var bubbleText: String? {
        if !chat.bubbles.isEmpty || chat.pending || inputVisible { return nil }
        if let text = brain.bubbleText { return text }
        if brain.wokeRecently { return "唔……你回来啦" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 150pt 是聊天区，内容贴底、往上生长，不压到脸
            ZStack {
                if let text = bubbleText {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 190)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(panelColor)
                                .shadow(color: Color.black.opacity(0.10), radius: 4, y: 1)
                        )
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                chatLayer
            }
            .frame(height: 150, alignment: .bottom)

            VStack(spacing: 4) {
                pet
                hud
            }
            .overlay(alignment: .bottomLeading) {
                loadMeter
            }
        }
        .frame(width: 210, height: 380, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: bubbleText)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: chat.bubbles)
        .animation(.easeOut(duration: 0.25), value: inputVisible)
        .animation(.easeInOut(duration: 0.45), value: brain.isAway)
        .onAppear { ui.start() }
    }

    // MARK: - 悬浮聊天

    private var chatLayer: some View {
        VStack(spacing: 5) {
            ForEach(chat.bubbles) { bubble in
                chatBubble(bubble)
            }

            if chat.pending {
                Text("…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(chatBubbleShape(panelColor))
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if inputVisible {
                inputPill
            }
        }
        .padding(.top, 2)
    }

    private func chatBubble(_ bubble: ChatStore.Bubble) -> some View {
        Text(bubble.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(bubble.isUser ? Color.white : primaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 190)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(chatBubbleShape(bubble.isUser ? accent : panelColor))
            .opacity(bubble.fading ? 0 : 1)
            .offset(y: bubble.fading ? -12 : 0)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .animation(.easeOut(duration: 1.2), value: bubble.fading)
    }

    private func chatBubbleShape(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color)
            .shadow(color: Color.black.opacity(0.10), radius: 4, y: 1)
    }

    private var inputPill: some View {
        HStack(spacing: 6) {
            TextField("说点什么…", text: Binding(
                get: { chat.draft },
                set: { chat.draft = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .onSubmit(sendChat)

            if !chat.draft.isEmpty {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(accent)
                    .onTapGesture { sendChat() }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(panelColor)
                .shadow(color: Color.black.opacity(0.12), radius: 5, y: 2)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
    }

    private func sendChat() {
        let text = chat.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !chat.pending else { return }
        chat.draft = ""
        chat.send(text)
    }

    // MARK: - 宠物

    private var pet: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.16))
                .frame(width: bodyW * 0.72, height: 12)
                .offset(y: 68)
                .blur(radius: 2)

            if !brain.isAway {
                sprout
                    .rotationEffect(.degrees(ui.near ? Double(ui.look.x) * 9 : 0), anchor: .bottom)
                    .offset(y: -(bodyH / 2 + 13))
            }

            bodyShape

            if state.stage >= 1 && !brain.isAway {
                powder
            }

            if state.stage == 4 {
                strawberry.offset(y: -(bodyH / 2 - 6))
            }

            if brain.loadLevel >= 2 && !brain.isAway {
                sweat
            }

            eyes.offset(x: ui.look.x * 3.5, y: -bodyH * 0.09 - ui.look.y * 3)
            cheeks.offset(y: bodyH * 0.13)
            mouth.offset(y: bodyH * 0.20)

            if brain.isAway {
                blanket
                Text("z z")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondaryText)
                    .offset(x: bodyW * 0.55, y: -bodyH * 0.52)
            }
        }
        .frame(width: 170, height: 170)
        .rotationEffect(.degrees(brain.isAway ? -9 : 0), anchor: .bottom)
    }

    private var bodyShape: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(bodyColor)

            if state.stage >= 3 {
                Ellipse()
                    .fill(Color(red: 0.72, green: 0.36, blue: 0.32).opacity(0.55))
                    .frame(width: bodyW * 0.82, height: bodyH * 0.48)
                    .offset(y: bodyH * 0.30)
            }
        }
        .frame(width: bodyW, height: bodyH)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: Color.black.opacity(0.10), radius: 8, y: 5)
        .rotationEffect(.degrees(ui.near ? Double(ui.look.x) * 2.5 : 0), anchor: .bottom)
        .scaleEffect(x: ui.breathe ? 1.02 : 0.99,
                     y: ui.breathe ? 1.04 : 0.97,
                     anchor: .bottom)
    }

    private var eyes: some View {
        HStack(spacing: bodyW * 0.20) {
            eye
            eye
        }
    }

    private var eye: some View {
        Capsule()
            .fill(Color(red: 0.10, green: 0.20, blue: 0.17))
            .frame(width: 12, height: brain.isAway ? 2.5 : 16)
            .overlay(
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3.5, height: 3.5)
                    .offset(x: 2.5 + ui.look.x * 1.8,
                            y: -4.5 - ui.look.y * 1.8)
                    .opacity(brain.isAway ? 0 : 1)
            )
            .scaleEffect(y: ui.blink && !brain.isAway ? 0.08 : 1)
    }

    private var mouth: some View {
        Capsule()
            .fill(Color(red: 0.10, green: 0.20, blue: 0.17).opacity(0.7))
            .frame(width: brain.isAway ? 9 : 15, height: 3.5)
    }

    private var cheeks: some View {
        HStack(spacing: bodyW * 0.62) {
            cheek
            cheek
        }
    }

    private var cheek: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.55, blue: 0.60).opacity(state.hunger < 22 ? 0.22 : 0.38))
            .frame(width: 15, height: 15)
    }

    private var powder: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.85)).frame(width: 3, height: 3)
                .offset(x: -bodyW * 0.24, y: -bodyH * 0.30)
            Circle().fill(Color.white.opacity(0.75)).frame(width: 2, height: 2)
                .offset(x: -bodyW * 0.10, y: -bodyH * 0.36)
            Circle().fill(Color.white.opacity(0.80)).frame(width: 2.5, height: 2.5)
                .offset(x: bodyW * 0.22, y: -bodyH * 0.26)
        }
    }

    private var strawberry: some View {
        VStack(spacing: -1) {
            Capsule()
                .fill(Color(red: 0.30, green: 0.68, blue: 0.40))
                .frame(width: 8, height: 4)
            Circle()
                .fill(Color(red: 0.88, green: 0.28, blue: 0.30))
                .frame(width: 11, height: 11)
        }
    }

    private var sweat: some View {
        ZStack {
            Capsule()
                .fill(Color(red: 0.45, green: 0.75, blue: 0.95).opacity(0.8))
                .frame(width: 4.5, height: 9)
                .rotationEffect(.degrees(14))
                .offset(x: bodyW * 0.44, y: -bodyH * 0.52)
            Capsule()
                .fill(Color(red: 0.45, green: 0.75, blue: 0.95).opacity(0.6))
                .frame(width: 3.5, height: 7)
                .rotationEffect(.degrees(20))
                .offset(x: bodyW * 0.32, y: -bodyH * 0.60)
        }
        .transition(.opacity)
    }

    private var sprout: some View {        VStack(spacing: -4) {
            ZStack {
                Capsule()
                    .fill(Color(red: 0.36, green: 0.78, blue: 0.45))
                    .frame(width: 17, height: 8)
                    .rotationEffect(.degrees(-26))
                    .offset(x: -8, y: 1)
                Capsule()
                    .fill(Color(red: 0.36, green: 0.78, blue: 0.45))
                    .frame(width: 17, height: 8)
                    .rotationEffect(.degrees(26))
                    .offset(x: 8, y: 1)
            }
            .frame(width: 40, height: 18)

            Capsule()
                .fill(Color(red: 0.30, green: 0.68, blue: 0.40))
                .frame(width: 4, height: 10)
        }
    }

    private var blanket: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(red: 0.50, green: 0.80, blue: 0.60))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
            .frame(width: bodyW * 0.98, height: bodyH * 0.46)
            .offset(y: bodyH * 0.27)
    }

    // MARK: - 侧边均衡器 + 精确数值

    private var memPercent: Int {
        guard brain.memTotalGB > 0 else { return 0 }
        return Int(brain.memUsedGB / brain.memTotalGB * 100)
    }

    private var loadMeter: some View {
        HStack(alignment: .center, spacing: 3) {
            // CPU 三根均衡器（纯视觉）
            HStack(alignment: .bottom, spacing: 2) {
                eqBar(offset: 0.00, pct: brain.cpuPercent)
                eqBar(offset: 0.08, pct: brain.cpuPercent)
                eqBar(offset: 0.14, pct: brain.cpuPercent)
            }
            .frame(height: 16)
            .animation(.easeOut(duration: 0.55), value: brain.cpuPercent)

            // 精确数值
            VStack(alignment: .leading, spacing: 1) {
                Text("C \(brain.cpuPercent)%")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(levelColor(brain.cpuPercent))
                Text("M \(memPercent)%")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(levelColor(memPercent))
            }
        }
        .opacity(brain.isAway ? 0.35 : 0.95)
        .offset(x: -6, y: -70)
    }

    private func eqBar(offset: CGFloat, pct: Int) -> some View {
        let base = CGFloat(max(3, min(100, pct))) / 100.0 + offset
        let height = max(2, min(14, base * 14))
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(levelColor(pct))
            .frame(width: 3.5, height: height, alignment: .bottom)
    }

    private func levelColor(_ percent: Int) -> Color {
        if percent < 25 { return Color(red: 0.30, green: 0.78, blue: 0.53) }
        if percent < 50 { return Color(red: 0.95, green: 0.72, blue: 0.20) }
        if percent < 80 { return Color(red: 0.95, green: 0.49, blue: 0.25) }
        return Color(red: 0.90, green: 0.32, blue: 0.30)
    }

    // MARK: - 底部信息条

    private var hud: some View {
        HStack(spacing: 8) {
            Text(state.timeText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(primaryText)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.stageName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryText)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(secondaryText.opacity(0.22))
                        .frame(width: 46, height: 3)
                    Capsule()
                        .fill(accent)
                        .frame(width: 46 * state.progress, height: 3)
                }
            }

            Button {
                brain.toggleSession()
            } label: {
                Image(systemName: state.session.running ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(accent.opacity(0.14)))
            }
            .buttonStyle(.plain)

            Button {
                brain.feed()
            } label: {
                HStack(spacing: 2) {
                    Text("🍙").font(.system(size: 12))
                    Text("\(state.rice)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(secondaryText)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(secondaryText.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(panelColor)
                .shadow(color: Color.black.opacity(0.10), radius: 6, y: 2)
        )
    }
}
