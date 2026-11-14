import SwiftUI

/// 공부 세션 상태. 시작점은 UserDefaults에.
@MainActor
final class SessionModel: ObservableObject {
    static let shared = SessionModel()
    @Published var start: Int64? = SessionStore.start
    @Published var sessions: [StudySession] = []
    @Published var msg: String?
    @Published var busy = false
    @Published var closed: StudySession?       // 방금 기록한 세션 (총평 표시용)
    @Published var retrying = false
    private var observer: NSObjectProtocol?

    init() {
        // 오프라인에서 닫은 세션이 서버에 기록되면 총평을 붙인다
        observer = NotificationCenter.default.addObserver(forName: .lbnSessionClosed, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in
                guard let self, let s = n.userInfo?["session"] as? StudySession, let st = n.userInfo?["startedAt"] as? Int64 else { return }
                if let i = self.sessions.firstIndex(where: { $0.startedAt == st }) { self.sessions[i] = s } else { self.sessions.insert(s, at: 0) }
                if self.closed?.startedAt == st { self.closed = s; self.msg = "기록했다 · \(s.line)" }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// 총평 없는 세션에 다시 시도
    func retryReview(_ s: StudySession) async {
        guard Connectivity.shared.isOnline, !retrying else { return }
        retrying = true
        do {
            let r = try await API.shared.sessionReview(s.id)
            var u = s; u.review = r; u.reviewError = r == nil ? "총평이 비어 있다" : nil
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = u }
            if closed?.id == s.id { closed = u }
        } catch {
            var u = s; u.reviewError = error.localizedDescription
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = u }
            if closed?.id == s.id { closed = u }
        }
        retrying = false
    }

    var inSession: Bool { start != nil }

    /// 시작점은 서버(/api/session-start)가 진실, UserDefaults는 캐시. 다른 기기에서 시작한 세션도 보인다
    func begin() {
        let t = Date().ms
        SessionStore.start = t; start = t; msg = nil
        AppLog.shared.info("session", "begin", ["at": "\(t)"])
        Task { await SyncManager.shared.putSessionStart(t) }
    }
    func discard() {
        SessionStore.start = nil; start = nil; msg = nil
        AppLog.shared.info("session", "discard")
        Task { await SyncManager.shared.deleteSessionStart() }
    }
    func load() async {
        if sessions.isEmpty, let c = Cache.shared.sessions() { sessions = c }
        do { sessions = try await API.shared.sessions() } catch { AppLog.shared.warn("session", "list failed: \(error.localizedDescription)") }
        await loadStart()
    }
    /// 서버 시작점을 읽어 로컬과 맞춘다. 서버가 null이면 기기 캐시도 지운다(캐시를 서버로 이관하지 않는다 — 다른 기기에서 닫은 세션의 옛 시작점이 되살아나는 사고, 2026-11-13)
    func loadStart() async {
        guard Connectivity.shared.isOnline else { start = SessionStore.start; return }
        do {
            if let s = try await API.shared.sessionStart() { SessionStore.start = s.startedAt; start = s.startedAt }
            else {
                if SessionStore.start != nil { AppLog.shared.info("session", "server start is null; dropping local cache") }
                SessionStore.start = nil; start = nil
            }
        } catch { start = SessionStore.start }
    }
    /// 서버가 PUT /api/session-start 를 거절(400)했을 때: 로컬 시작점을 지우고 이유를 보여준다
    func serverRejectedStart(_ reason: String) {
        SessionStore.start = nil; start = nil; msg = reason
        AppLog.shared.warn("session", "start rejected", ["error": reason])
    }
    func close() async {
        guard let start, !busy else { return }
        busy = true; msg = nil
        do {
            let s: StudySession
            if Connectivity.shared.isOnline {
                s = try await API.shared.closeSession(startedAt: start)
            } else {
                // 오프라인: 캐시로 번역+응용을 세어 임시 세션, 연결되면 서버에 기록
                guard let local = Cache.shared.closeSessionLocally(startedAt: start) else { msg = "시작 이후 채점한 문장이 없습니다"; busy = false; return }
                Cache.shared.enqueue("session_close", SessionStartState(startedAt: start)); s = local
            }
            SessionStore.start = nil; self.start = nil
            await SyncManager.shared.deleteSessionStart()
            msg = "기록했다 · \(s.line)"
            closed = s
            sessions.insert(s, at: 0)
            AppLog.shared.info("session", "closed", ["id": s.id, "attempts": "\(s.attempts)", "drills": "\(s.drills ?? 0)"])
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
                        Tiny(title: model.busy ? "총평 쓰는 중… ✎\u{FE0E}" : "오늘 여기까지 ✂\u{FE0E}", color: Theme.red) { Task { await model.close() } }
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
                if let c = model.closed, model.msg != nil {
                    SessionReviewLines(session: c, size: 19, retrying: model.retrying) { Task { await model.retryReview(c) } }
                }
            }
            .frame(minHeight: Theme.lh)
            .confirmationDialog("시작점을 버릴까요? 그동안 채점한 건 기록 없이 남습니다.", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("버리기", role: .destructive) { model.discard() }
            }
        }
    }
}


/// 세션 총평 세 줄: summary(빨간 펜) · "✓ keep"(초록) · "→ next"(연필). 없으면 실패 이유 + 다시 시도 / 연결되면 받는다
struct SessionReviewLines: View {
    var session: StudySession
    var size: CGFloat = 17
    var retrying = false
    var onRetry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let r = session.review {
                if !r.summary.isEmpty { Text(r.summary).font(Theme.hand(size + 1)).foregroundStyle(Theme.red) }
                if !r.keep.isEmpty { Text("✓\u{FE0E} \(r.keep)").font(Theme.hand(size)).foregroundStyle(Theme.grade(.A)) }
                if !r.next.isEmpty { Text("→\u{FE0E} \(r.next)").font(Theme.hand(size)).foregroundStyle(Theme.pencil) }
            } else if session.id.hasPrefix("local-") {
                Text("총평은 연결되면 받는다").font(Theme.hand(size)).foregroundStyle(Theme.pencil)
            } else if let onRetry {
                HStack(spacing: 10) {
                    Text("총평을 못 받았다" + (session.reviewError.map { " (\($0))" } ?? "")).font(Theme.hand(size)).foregroundStyle(Theme.pencil)
                    Tiny(title: retrying ? "받는 중…" : "다시 시도", color: Theme.red, size: size) { onRetry() }.disabled(retrying)
                }
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.red.opacity(0.6)).frame(width: 2) }
    }
}
