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
            var queued = Cache.shared.pending(kind: "attempt").count + Cache.shared.pending(kind: "drill_answer").count
            if Connectivity.shared.isOnline, queued > 0 {
                // 온라인인데 채점 대기가 남아 있으면(막 연결됨) 먼저 보내고 닫아야 세션에 들어간다
                msg = "채점 대기 \(queued)개를 먼저 보낸다…"
                await SyncManager.shared.flushAndWait()
                queued = Cache.shared.pending(kind: "attempt").count + Cache.shared.pending(kind: "drill_answer").count
            }
            if Connectivity.shared.isOnline, queued == 0 {
                s = try await API.shared.closeSession(startedAt: start)
            } else {
                // 오프라인(또는 아직 못 보낸 채점 대기가 있음): 캐시+대기분을 세어 임시 세션, 연결되면 서버에 기록(총평 포함)
                guard let local = Cache.shared.closeSessionLocally(startedAt: start) else { msg = "시작 이후 쓴 문장이 없습니다"; busy = false; return }
                Cache.shared.enqueue("session_close", SessionStartState(startedAt: start)); s = local
            }
            SessionStore.start = nil; self.start = nil
            await SyncManager.shared.deleteSessionStart()
            msg = "기록했다 · \(s.line)" + (s.id.hasPrefix("local-") && queued > 0 ? " · 채점 대기 \(queued)개" : "")
            closed = s
            sessions.insert(s, at: 0)
            AppLog.shared.info("session", "closed", ["id": s.id, "attempts": "\(s.attempts)", "drills": "\(s.drills ?? 0)"])
        } catch let e as APIError where e.isNetwork {
            // 응답만 잃었을 수 있다 (2026-11-17 13:12 iPhone: POST /api/sessions "The network connection was lost."인데 서버엔 기록됨 → 로컬 시작점이 남아 "11시간 48분"으로 보였다).
            // 목록을 다시 읽어 그 시작점의 세션이 있으면 닫힌 것으로 마무리한다. 같은 started_at으로 다시 보내면 세션이 겹치므로 재전송은 하지 않는다
            if let list = try? await API.shared.sessions(), let s = list.first(where: { $0.startedAt == start }) {
                sessions = list
                SessionStore.start = nil; self.start = nil
                await SyncManager.shared.deleteSessionStart()
                msg = "기록했다 · \(s.line)"; closed = s
                AppLog.shared.warn("session", "close response lost but server has the session; finishing locally", ["id": s.id])
            } else {
                msg = e.localizedDescription
                AppLog.shared.warn("session", "close failed (network), start kept: \(e.localizedDescription)")
            }
        } catch { msg = error.localizedDescription }
        busy = false
    }
    func remove(_ s: StudySession) async {
        do { try await API.shared.deleteSession(s.id); sessions.removeAll { $0.id == s.id } }
        catch { msg = error.localizedDescription }
    }
}

/// 모든 화면 아래(탭 바 위)에 늘 보이는 공부 상태 (웹 SessionDot, d63c702). 시작점은 SessionModel.shared 하나를 모두 구독.
/// 공부 중: 숨 쉬는 빨간 점 + "22:03부터 · 1시간 12분"(30초마다 갱신, 오늘 시작이 아니면 "11/12 10:51부터 …"를 빨갛게) → 누르면 기사 목록.
/// 아니면: 빈 빨간 점 + "공부 시작 ▶" → 어느 탭에서든 바로 시작(세션을 닫은 뒤 응용만 하면 어느 세션에도 안 들어가는데 알 길이 없었다).
/// 끝내기 ✂는 총평이 붙어서 기존 세션 줄(목록·공책)에 그대로. 여기엔 두지 않는다.
struct StudyDot: View {
    @ObservedObject private var model = SessionModel.shared
    @EnvironmentObject var router: Router
    @State private var dim = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let start = model.start {
                let d = Date(ms: start)
                Button { router.tab = .shelf; router.shelfPath = [] } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.red).frame(width: 8, height: 8)
                            .opacity(dim ? 0.45 : 1).scaleEffect(dim ? 0.8 : 1)
                            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dim)
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text((d.isToday ? "" : d.monthDay + " ") + d.hm + "부터 · " + Self.elapsed(from: d, to: ctx.date))
                                .font(Theme.hand(17)).foregroundStyle(d.isToday ? Theme.ink : Theme.red)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("공부 중 · 기사 목록으로")
                .onAppear { dim = true }
                .onDisappear { dim = false }
            } else {
                HStack(spacing: 7) {
                    Circle().strokeBorder(Theme.red, lineWidth: 1.5).frame(width: 8, height: 8)
                    Tiny(title: "공부 시작 ▶\u{FE0E}", color: Theme.red, size: 17) { model.begin() }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 24)
        .background(Theme.desk)
    }

    /// 웹과 같은 형식: 60분 미만 "12분", 그 이상 "1시간 12분"
    static func elapsed(from: Date, to: Date) -> String {
        let m = max(0, Int((to.timeIntervalSince(from) / 60).rounded()))
        return m < 60 ? "\(m)분" : "\(m / 60)시간 \(m % 60)분"
    }
}

extension View {
    /// 탭의 뿌리에 붙여 그 탭의 모든 화면(밀어 넣은 공책·마지막 장 포함) 아래에 공부 상태를 둔다
    func studyDot() -> some View { safeAreaInset(edge: .bottom, spacing: 0) { StudyDot() } }
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
                        if waiting > 0 { MutedText(text: "채점이 끝나면 누를 수 있다") }   // 지금 채점 중(온라인)인 것만. 채점 대기(큐)는 막지 않는다
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
