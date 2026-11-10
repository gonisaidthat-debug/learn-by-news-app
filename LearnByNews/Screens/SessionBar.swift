import SwiftUI

/// 공부 세션 상태. 시작점은 UserDefaults에.
@MainActor
final class SessionModel: ObservableObject {
    static let shared = SessionModel()
    @Published var start: Int64? = SessionStore.start
    @Published var sessions: [StudySession] = []
    @Published var msg: String?
    @Published var busy = false

    var inSession: Bool { start != nil }

    func begin() {
        let t = Date().ms
        SessionStore.start = t; start = t; msg = nil
        AppLog.shared.info("session", "begin", ["at": "\(t)"])
    }
    func discard() {
        SessionStore.start = nil; start = nil; msg = nil
        AppLog.shared.info("session", "discard")
    }
    func load() async {
        if sessions.isEmpty, let c = Cache.shared.sessions() { sessions = c }
        do { sessions = try await API.shared.sessions() } catch { AppLog.shared.warn("session", "list failed: \(error.localizedDescription)") }
    }
    func close() async {
        guard let start, !busy else { return }
        busy = true; msg = nil
        do {
            let s = try await API.shared.closeSession(startedAt: start)
            SessionStore.start = nil; self.start = nil
            msg = "기록했다 · \(s.line)"
            sessions.insert(s, at: 0)
            AppLog.shared.info("session", "closed", ["id": s.id, "attempts": "\(s.attempts)"])
        } catch { msg = error.localizedDescription }
        busy = false
    }
    func remove(_ s: StudySession) async {
        do { try await API.shared.deleteSession(s.id); sessions.removeAll { $0.id == s.id } }
        catch { msg = error.localizedDescription }
    }
}

/// 공부 세션 줄: "공부 시작 ▶\u{FE0E}" →\u{FE0E} "HH:MM부터 · 오늘 여기까지 ✂\u{FE0E} · 버리기"
struct SessionBar: View {
    @ObservedObject var model: SessionModel
    var waiting = 0
    var hideStart = false
    @State private var confirmDiscard = false

    var body: some View {
        if model.start == nil && hideStart && model.msg == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    if let start = model.start {
                        let d = Date(ms: start)
                        Text((d.isToday ? "" : d.monthDay + " ") + d.hm + "부터")
                            .font(Theme.hand(20)).foregroundStyle(d.isToday ? Theme.ink : Theme.red)
                        Tiny(title: model.busy ? "기록 중…" : "오늘 여기까지 ✂\u{FE0E}", color: Theme.red) { Task { await model.close() } }
                            .disabled(model.busy || waiting > 0)
                            .opacity(model.busy || waiting > 0 ? 0.45 : 1)
                        if waiting > 0 { MutedText(text: "채점이 끝나면 누를 수 있다") }
                        Tiny(title: "버리기") { confirmDiscard = true }
                    } else if !hideStart {
                        Tiny(title: "공부 시작 ▶\u{FE0E}", color: Theme.red) { model.begin() }
                    }
                }
                if let msg = model.msg {
                    Text(msg).font(Theme.hand(20)).foregroundStyle(Theme.red)
                }
            }
            .frame(minHeight: Theme.lh)
            .confirmationDialog("시작점을 버릴까요? 그동안 채점한 건 기록 없이 남습니다.", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("버리기", role: .destructive) { model.discard() }
            }
        }
    }
}
