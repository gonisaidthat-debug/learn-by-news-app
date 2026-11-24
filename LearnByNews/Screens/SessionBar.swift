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
    /// 공책이 방금 닫은 세션의 ✂ 줄+총평을 본문에 그리고 있다 → StudyDot 아래 패널에는 겹쳐 쓰지 않는다 (NotebookView가 켜고 끈다)
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
        // 직접 보내는 중인 채점은 세지 않는다(그건 곧 응답이 온다). 큐에서 기다리는 것만
        var queued = Cache.shared.pendingUnclaimed(kind: "attempt").count + Cache.shared.pendingUnclaimed(kind: "drill_answer").count
        if Connectivity.shared.isOnline, queued > 0 {
            // 온라인인데 채점 대기가 남아 있으면(막 연결됨) 먼저 보내고 닫아야 세션에 들어간다
            msg = "채점 대기 \(queued)개를 먼저 보낸다…"
            await SyncManager.shared.flushAndWait()
            queued = Cache.shared.pendingUnclaimed(kind: "attempt").count + Cache.shared.pendingUnclaimed(kind: "drill_answer").count
        }
        var s: StudySession?
        var opId: String?
        if Connectivity.shared.isOnline, queued == 0 {
            // 보내기 전에 큐(디스크)에 먼저 (goni 2026-11-18): 총평 10~20초 사이 앱이 죽어도 다음 실행 때 다시 보낸다(서버는 같은 started_at에 멱등)
            opId = Cache.shared.enqueue("session_close", SessionStartState(startedAt: start), claimed: true).id
            do { s = try await API.shared.closeSession(startedAt: start); Cache.shared.removePending(id: opId!) }
            catch let e as APIError where e.isNetwork {
                // 응답만 잃었을 수 있다(2026-11-17 13:12 iPhone: POST /api/sessions "The network connection was lost."인데 서버엔 기록됨 → 시작점이 남아 "11시간 48분").
                // 큐 항목을 풀어 연결되면 다시 보낸다(서버가 저장된 세션을 duplicate로 돌려준다)
                AppLog.shared.warn("session", "close network failure, left in queue: \(e.localizedDescription)")
                Cache.shared.releasePending(id: opId!)
            }
            catch { Cache.shared.removePending(id: opId!); msg = error.localizedDescription; busy = false; return }
        }
        if s == nil {
            // 오프라인(또는 아직 못 보낸 채점 대기가 있음, 또는 방금 연결이 끊김): 캐시+대기분을 세어 임시 세션, 연결되면 서버에 기록(총평 포함)
            guard let local = Cache.shared.closeSessionLocally(startedAt: start) else {
                if let opId { Cache.shared.removePending(id: opId) }
                msg = "시작 이후 쓴 문장이 없습니다"; busy = false; return
            }
            if opId == nil { Cache.shared.enqueue("session_close", SessionStartState(startedAt: start)) }
            s = local
        }
        guard let s else { busy = false; return }
        SessionStore.start = nil; self.start = nil
        await SyncManager.shared.deleteSessionStart()
        msg = "기록했다 · \(s.line)" + (s.id.hasPrefix("local-") && queued > 0 ? " · 채점 대기 \(queued)개" : "")
        closed = s
        sessions.insert(s, at: 0)
        AppLog.shared.info("session", "closed", ["id": s.id, "attempts": "\(s.attempts)", "drills": "\(s.drills ?? 0)"])
        busy = false
    }
    /// 내 메모 한 줄 (2026-11-24). 목록의 세션도 맞춘다. 총평 다시 받기는 메모를 건드리지 않는다
    func setMemo(_ id: String, _ memo: String) async throws -> String? {
        let r = try await SyncManager.shared.setSessionMemo(id: id, memo: memo)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].memo = r }
        if closed?.id == id { closed?.memo = r }
        return r
    }
    func remove(_ s: StudySession) async {
        do { try await API.shared.deleteSession(s.id); sessions.removeAll { $0.id == s.id } }
        catch { msg = error.localizedDescription }
    }
}

/// 모든 화면 아래(탭 바 위)에 늘 보이는 공부 상태 (웹 SessionDot, d63c702 → ca1191f). 시작점은 SessionModel.shared 하나를 모두 구독.
/// 공부 중: 숨 쉬는 빨간 점 + "22:03부터 · 1시간 12분"(30초마다 갱신, 오늘 시작이 아니면 "11/12 10:51부터 …"를 빨갛게, 누르면 기사 목록) + "오늘 여기까지 ✂" + "버리기".
/// 아니면: 빈 빨간 점 + "공부 시작 ▶" → 어느 탭에서든 바로 시작.
/// goni 2026-11-18 "상단에 공부 시작이 있으면 종료도 돼야": ✂·버리기를 여기로 옮기고 기사 목록·공책 바닥의 세션 줄은 뺐다. 채점 중(직접 보내는 중)이면 ✂ 잠김("채점이 끝나면").
/// 닫은 결과("기록했다 · …" + 총평)는 공책이 ✂ 줄로 그리거나 홈이 공부 기록에 보여 주면 생략, 아니면 이 줄 위 작은 패널(× 닫기, 총평 실패면 다시 시도).
struct StudyDot: View {
    @ObservedObject private var model = SessionModel.shared
    @ObservedObject private var sync = SyncManager.shared
    @EnvironmentObject var router: Router
    @State private var dim = false
    @State private var confirmDiscard = false

    /// 패널에 보여 줄 메시지. 닫기 결과("기록했다 · …" + 총평 전체)는 어느 화면이든 이 패널 하나로, × 닫기 전까지(goni 2026-11-20 총평 자리 규칙 — 공책 ✂ 줄·홈 기록이 있어도 생략하지 않는다)
    private var panelMsg: String? { model.msg }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let msg = panelMsg {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(msg).font(Theme.hand(19)).foregroundStyle(Theme.red)
                        Spacer(minLength: 0)
                        Button { model.msg = nil } label: { Text("×").font(.system(size: 16)).foregroundStyle(Theme.pencil).padding(.horizontal, 4) }
                            .buttonStyle(.plain).accessibilityLabel("닫기")
                    }
                    if let c = model.closed, msg.hasPrefix("기록했다") {
                        SessionReviewLines(session: c, size: 17, retrying: model.retrying) { Task { await model.retryReview(c) } }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.tab.opacity(0.35))
                .overlay(alignment: .leading) { Rectangle().fill(Theme.red).frame(width: 3) }
            }
            HStack(spacing: 14) {
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
                                    .font(Theme.hand(17)).foregroundStyle(d.isToday ? Theme.ink : Theme.red).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("공부 중 · 기사 목록으로")
                    .onAppear { dim = true }
                    .onDisappear { dim = false }
                    // 채점 중(직접 보내는 중)이면 잠근다. 채점 대기(큐)는 막지 않는다(닫을 때 먼저 보낸다)
                    let locked = model.busy || sync.grading > 0
                    Tiny(title: model.busy ? "총평 쓰는 중… ✎\u{FE0E}" : sync.grading > 0 ? "채점이 끝나면 ✂\u{FE0E}" : "오늘 여기까지 ✂\u{FE0E}", color: locked ? Theme.pencil : Theme.red, size: 17) { Task { await model.close() } }
                        .disabled(locked).opacity(locked ? 0.6 : 1).lineLimit(1)
                    Tiny(title: "버리기", size: 17) { confirmDiscard = true }.disabled(model.busy)
                } else {
                    HStack(spacing: 7) {
                        Circle().strokeBorder(Theme.red, lineWidth: 1.5).frame(width: 8, height: 8)
                        Tiny(title: "공부 시작 ▶\u{FE0E}", color: Theme.red, size: 17) { model.begin() }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: 24)
        }
        .background(Theme.desk)
        .confirmationDialog("시작점을 버릴까요? 그동안 채점한 건 기록 없이 남습니다.", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("버리기", role: .destructive) { model.discard() }
        }
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

/// 세션 총평 세 줄: summary(빨간 펜) · "✓ keep"(초록) · "→ next"(연필). 없으면 실패 이유 + 다시 시도 / 연결되면 받는다
/// 공부 시작 전 입력란 자리 (goni 2026-11-20 "응용 문장 덧붙였는데 원래 공부 시작돼야 가능한 거 아니었나"):
/// 세션에 세는 쓰기(번역·써 보기 상자·응용 탭 답·표현장 시험 고급)는 시작 전엔 이 줄. 누르면 바로 시작하고 입력란으로 바뀐다.
/// 시험지·표현장 시험 기본/뜻 쓰기(스스로 채점, 세션에 안 셈)는 막지 않는다
struct StartGate: View {
    var onStart: (() -> Void)? = nil
    var body: some View {
        Button { SessionModel.shared.begin(); onStart?() } label: {
            Text("공부 시작 ▶\u{FE0E} 을 누르면 여기에 쓸 수 있다").redpen()
        }.buttonStyle(.plain)
    }
}

/// 세션 총평 줄. articleTitle이 있으면(공책 ✂ 줄) 그 기사 몫(by_article)을 빨간 펜으로 앞세우고 전체는 "이 시간 전체: …" 한 줄로 접는다.
/// 없으면(홈 기록·기록 탭·StudyDot 패널) 전체 summary → 기사별 줄(제목 점선 밑줄 + summary + → next) → ✓ keep → → next (goni 2026-11-20)
struct SessionReviewLines: View {
    var session: StudySession
    var size: CGFloat = 17
    var retrying = false
    var articleTitle: String? = nil
    var onRetry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let r = session.review {
                if let mine = r.forArticle(articleTitle) {
                    if !mine.summary.isEmpty { Text(mine.summary).font(Theme.hand(size + 1)).foregroundStyle(Theme.red) }
                    if !mine.next.isEmpty { Text("→\u{FE0E} \(mine.next)").font(Theme.hand(size)).foregroundStyle(Theme.pencil) }
                    let whole = [r.summary, r.keep.isEmpty ? "" : "✓\u{FE0E} \(r.keep)", r.next.isEmpty ? "" : "→\u{FE0E} \(r.next)"].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !whole.isEmpty { Text("이 시간 전체: \(whole)").font(Theme.hand(size - 2)).foregroundStyle(Theme.pencil).padding(.top, 2) }
                } else {
                    if !r.summary.isEmpty { Text(r.summary).font(Theme.hand(size + 1)).foregroundStyle(Theme.red) }
                    ForEach(Array((r.byArticle ?? []).enumerated()), id: \.offset) { _, a in
                        (Text(a.title).underline(true, pattern: .dot, color: Theme.pencil).foregroundColor(Theme.ink) + Text(" \(a.summary)").foregroundColor(Theme.red) + Text(a.next.isEmpty ? "" : " →\u{FE0E} \(a.next)").foregroundColor(Theme.pencil))
                            .font(Theme.hand(size))
                    }
                    if !r.keep.isEmpty { Text("✓\u{FE0E} \(r.keep)").font(Theme.hand(size)).foregroundStyle(Theme.grade(.A)) }
                    if !r.next.isEmpty { Text("→\u{FE0E} \(r.next)").font(Theme.hand(size)).foregroundStyle(Theme.pencil) }
                }
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
