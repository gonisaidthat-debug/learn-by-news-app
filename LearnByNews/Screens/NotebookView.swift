import SwiftUI

struct Inflight: Hashable {
    var translation: String
    var attemptId: String
    var wasRedo: Bool          // 다시 쓰기 중이던 문장이면 멈출 때 그 자리로 돌아간다
    var error: String?
    var pending = false        // 오프라인: 큐에 있고 연결되면 채점된다 (대기 도장)
    var opId: String? = nil    // 큐 항목 id (제출 즉시 큐에 넣는다, 2026-11-18)
}

@MainActor
final class NotebookModel: ObservableObject {
    private(set) var id: String        // 오프라인에서 만든 임시 공책이면 전송 뒤 서버 id로 바뀐다
    let focusId: String?
    let restartAfter: Int?
    let browseAll: Bool
    let round: Int?           // 회차 열람: n번째 총평 시각까지의 마지막 시도로 보여준다
    @Published var roundShown: Int?
    @Published var offline = false        // 서버에 못 닿아 캐시를 보여주는 중 (입력 불가)
    @Published var bookmark: Bookmark?
    /// 이 화면에서 뺀 문장들 (화면을 떠나기 전까지 되살릴 수 있다). 마지막 것이 맨 앞
    struct Removed: Identifiable { var id: String { sentence.id }; var sentence: Sentence; var trashId: String?; var afterId: String? }   // afterId: 바로 앞 문장(없으면 맨 위)
    @Published var removed: [Removed] = []
    @Published var data: ArticleDetail?
    /// 처음부터 다시 쓰기: 순서대로 다시 쓸 문장 id 목록. 기존 기록은 history로 남는다
    @Published var pass: [String]?
    @Published var finishingPass = false  // 마지막 문장을 제출했다 → 채점이 다 끝나면 마지막 장으로 (새 총평)
    /// 이번 다시 쓰기에서 새로 제출한 문장 id. 화면은 처음 하는 것처럼 비우고 이것만 쌓는다
    @Published var passSubmitted: Set<String> = []
    var passMode: Bool { pass != nil || finishingPass }
    /// 다시 쓰기 모드에서 보이는 시도: 이번에 새로 제출한 문장만. 나머지는 없는 것처럼
    func visibleAttempt(_ s: Sentence) -> Attempt? { passMode && !passSubmitted.contains(s.id) ? nil : s.attempt }
    @Published var input = ""
    @Published var inflight: [String: Inflight] = [:]
    @Published var redo: String?         // 다시 쓰는 중인 문장 id
    @Published var open: String? { didSet { scheduleAutoBookmark() } }
    @Published var refOpen: [String: Bool] = [:]
    private var autoBookmarkTask: Task<Void, Never>?
    private var openingFromLink = false

    /// 책갈피·시험지·기록 링크로 들어오며 자동 펼침: 이건 "내가 본 곳"이 아니므로 자동 책갈피를 걸지 않는다
    private func openFromLink(_ sid: String?) {
        openingFromLink = true; open = sid; openingFromLink = false
    }
    /// 찾기로 펼치기: 책갈피를 옮기지 않는다 (goni 2026-11-24 공책 안에서 찾기)
    func openForFind(_ sid: String) { openingFromLink = true; open = sid; openingFromLink = false }

    /// 펼쳐 본 문장이 책갈피가 된다 ("마지막까지 본 곳"). 직접 탭해 펼쳤거나 방금 채점돼 펼쳐진 문장에만. 0.5초 디바운스
    private func scheduleAutoBookmark() {
        autoBookmarkTask?.cancel()
        guard !openingFromLink, let sid = open, bookmark?.sentenceId != sid else { return }
        autoBookmarkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.open == sid, self.bookmark?.sentenceId != sid else { return }
            let s = self.data?.sentences.first { $0.id == sid }
            self.bookmark = Bookmark(articleId: self.id, sentenceId: sid, round: self.bookmarkRound, currentRound: self.currentRound, createdAt: Date().ms, articleTitle: self.data?.title, sentenceIdx: s?.idx, sentenceText: s?.text)
            Cache.shared.setBookmark(self.bookmark)
            await SyncManager.shared.setBookmark(articleId: self.id, sentenceId: sid, round: self.bookmarkRound)
        }
    }
    @Published var lastGraded: String?
    @Published var err: String?
    @Published var scrollTo: String?     // 스크롤 목표 ("bottom" 또는 문장 id)
    @Published var revokedNotes: [String: [RevokedPhrase]] = [:]   // 이번에 채점하며 습득 완료가 취소된 표현 (문장 id별, 화면에 있는 동안만)
    @Published var focusRequest = 0      // 입력란에 포커스를 달라는 신호
    var browse: Bool { focusId != nil || browseAll }
    /// 열람(링크 따라가기·책갈피·기록에서 열기·전체 열람)에서 다음에 쓸 문장 자리에 "이어서 쓰기 →"를 둔다(goni 2026-11-18, 웹과 같은 규칙).
    /// 입력란은 열지 않는다(처음엔 열었다가 "버튼이 바로 보이니 열람에서 안 열어도 된다"로 정리). 회차 열람(round)과 다시 쓰기 진행 중(RedoProgress)은 빼고 — 그때는 보기만
    var continueInBrowse: Bool { browse && round == nil && RedoProgress.load(id) == nil }
    private var tasks: [String: Task<Void, Never>] = [:]   // 채점 요청. 멈추기 때 cancel
    private var stopped: Set<String> = []                   // 멈춘 attempt_id. 뒤늦은 오류를 무시한다

    private var observers: [NSObjectProtocol] = []

    init(id: String, focusId: String?, restartAfter: Int?, browseAll: Bool, round: Int?) {
        self.id = id; self.focusId = focusId; self.restartAfter = restartAfter; self.browseAll = browseAll; self.round = round
        observeDrillGraded()
        // 오프라인 큐의 채점이 돌아오면 그 문장을 교체한다
        observers.append(NotificationCenter.default.addObserver(forName: .lbnAttemptGraded, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.graded(n.userInfo ?? [:]) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .lbnArticleRenamed, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in
                guard let self, let from = n.userInfo?["from"] as? String, let to = n.userInfo?["to"] as? String, from == self.id else { return }
                self.id = to
                self.inflight = Dictionary(uniqueKeysWithValues: self.inflight.map { (SyncManager.shared.real($0.key), $0.value) })
                await self.reload()
            }
        })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// 오프라인 큐로 나중에 채점된 자유 작문이 이 공책 문장의 것이면 횟수 +1
    func observeDrillGraded() {
        observers.append(NotificationCenter.default.addObserver(forName: .lbnDrillGraded, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in
                guard let self, let d = n.userInfo?["drill"] as? Drill, d.answeredAt != nil else { return }
                if let sid = d.sentenceId, self.data?.sentences.contains(where: { $0.id == sid }) == true { self.bumpDrillCount(d.phrase) }
            }
        })
    }

    private func graded(_ info: [AnyHashable: Any]) {
        guard let aid = info["attemptId"] as? String, let (sid, f) = inflight.first(where: { $0.value.attemptId == aid }) else { return }
        if let r = info["result"] as? AttemptResult { applyResult(sid, r) }
        else if let e = info["error"] as? String { inflight[sid] = Inflight(translation: f.translation, attemptId: aid, wasRedo: f.wasRedo, error: e) }
    }

    /// 큐에 남아 있는 이 공책의 채점을 "대기" 상태로 그린다
    private func mergePendingAttempts(_ d: ArticleDetail) {
        for op in SyncManager.shared.pendingAttempts(for: id) {
            let sid = SyncManager.shared.real(op.sentenceId)
            guard d.sentences.contains(where: { $0.id == sid }), inflight[sid] == nil else { continue }
            let has = d.sentences.first { $0.id == sid }?.attempt != nil
            inflight[sid] = Inflight(translation: op.translation, attemptId: op.attemptId, wasRedo: has, pending: true)
        }
    }

    /// 회차 열람용 변환: n번째 총평(오래된 순) 시각까지의 시도만 남긴다. 총평도 n번째까지
    static func asOfRound(_ d: ArticleDetail, _ n: Int) -> ArticleDetail? {
        let asc = d.reviews.sorted { $0.createdAt < $1.createdAt }
        guard n >= 1, n <= asc.count else { return nil }
        let asOf = asc[n - 1].createdAt
        var out = d
        out.sentences = d.sentences.map { x in
            var s = x
            let all = (x.history + [x.attempt].compactMap { $0 }).filter { $0.createdAt <= asOf }.sorted { $0.createdAt < $1.createdAt }
            s.attempt = all.last
            s.history = Array(all.dropLast())
            return s
        }
        out.reviews = Array(asc.prefix(n)).reversed()
        return out
    }

    var frontIdx: Int? {
        guard let d = data else { return nil }
        return d.sentences.firstIndex { $0.attempt == nil && inflight[$0.id] == nil }
    }
    var current: Sentence? {
        guard let d = data else { return nil }
        if let redo { return d.sentences.first { $0.id == redo } }
        return frontIdx.map { d.sentences[$0] }
    }
    var allDone: Bool { data?.sentences.allSatisfy { $0.attempt != nil } ?? false }

    /// onDone(newReview): 열자마자 전부 채점돼 있으면 마지막 장으로(다시 쓰기 회차를 끝낸 채 다시 열었으면 새 총평까지)
    func load(onDone: @escaping (Bool) -> Void) async {
        // 열람은 캐시를 먼저 그린다
        if browse, data == nil, let c = Cache.shared.article(id) {
            if let round, let r = Self.asOfRound(c, round) { data = r; roundShown = round } else { data = c }
            openFromLink(focusId)
        }
        do {
            let d: ArticleDetail
            do { d = try await API.shared.article(id); offline = false }
            catch let e as APIError where e.isNetwork {
                // 오프라인: 캐시로 보여준다. 쓰기는 막힌다
                guard let c = Cache.shared.article(id) else { throw e }
                d = c; offline = true
            }
            if browse {
                if let round, let r = Self.asOfRound(d, round) { data = r; roundShown = round } else { data = d }
                openFromLink(focusId); if let focusId { requestScroll(focusId) }
                return
            }
            let ids = d.sentences.map(\.id)
            if let n = restartAfter, !d.sentences.isEmpty {
                // 처음부터(또는 앞 n문장 다음부터) 다시 쓰기 시작. 서버에 올리고 로컬에도 캐시
                let prog = RedoProgress(ids: ids, done: Array(ids.prefix(min(n, ids.count - 1))))
                prog.save(id)
                await SyncManager.shared.putPass(id, done: prog.done)
                AppLog.shared.info("notebook", "restart pass", ["article": id, "count": "\(ids.count)", "after": "\(n)"])
                data = d; beginPass(prog)
                return
            }
            // 진행 상태: 서버가 진실. 서버가 null이면 로컬(RedoProgress)도 지운다 — 이관하지 않는다(다른 기기에서 끝낸 진행이 되살아나는 사고, 2026-11-15).
            // 서버에 못 닿을 때만 로컬 진행을 쓰고, 그때도 올리지 않는다
            var prog: RedoProgress? = nil
            if !offline {
                do {
                    if let server = try await API.shared.pass(id) {
                        prog = RedoProgress.from(serverDone: server.done, sentenceIds: ids); prog?.save(id)
                    } else {
                        if RedoProgress.load(id) != nil { AppLog.shared.info("notebook", "server pass is null; dropping local progress", ["article": id]) }
                        RedoProgress.clear(id)
                    }
                } catch {
                    AppLog.shared.warn("notebook", "pass unreachable, using local: \(error.localizedDescription)", ["article": id])
                    prog = RedoProgress.load(id)
                }
            } else { prog = RedoProgress.load(id) }
            if let prog, !ids.isEmpty {
                let alive = prog.ids.filter(ids.contains)
                let p = RedoProgress(ids: alive, done: prog.done.filter(alive.contains))
                if p.remaining.isEmpty {
                    // 모든 문장을 덮는 진행은 끝난 회차: 서버 값일 때만 DELETE. 오프라인의 로컬 캐시만으로는 지우지 않는다
                    // (2026-11-24: 웹에서 3회차 75/150 진행이 사라진 사고 뒤 점검 — 문장 0개·캐시만 있는 상태에서 "모두 덮음"으로 오판해 DELETE를 큐에 넣지 않게)
                    AppLog.shared.warn("notebook", "pass covers all sentences", ["article": id, "done": "\(p.done.count)", "count": "\(alive.count)", "offline": "\(offline)"])
                    RedoProgress.clear(id)
                    if !offline { await SyncManager.shared.deletePass(id) }
                    data = d; finishingPass = true; passSubmitted = Set(p.done); onDone(true); return
                }
                AppLog.shared.info("notebook", "resume pass", ["article": id, "done": "\(p.done.count)", "count": "\(p.ids.count)"])
                data = d; beginPass(p)
                return
            }
            mergePendingAttempts(d)
            if let r = Self.pendingRedo.removeValue(forKey: id), d.sentences.contains(where: { $0.id == r }) {
                data = d; redo = r; input = ""; requestScroll(r); focusRequest += 1; return
            }
            if inflight.isEmpty, d.sentences.allSatisfy({ $0.attempt != nil }) { data = d; onDone(false); return }
            data = d; requestScroll("bottom")
        } catch { err = error.localizedDescription }
    }

    /// 레이아웃이 끝난 뒤 스크롤하도록 한 박자 늦게 목표를 올린다
    func requestScroll(_ target: String) {
        Task { try? await Task.sleep(for: .milliseconds(250)); scrollTo = target }
    }

    func loadBookmark() async {
        bookmark = Cache.shared.bookmark()
        do { bookmark = try await API.shared.bookmark(); Cache.shared.setBookmark(bookmark) } catch { /* 오프라인: 캐시 */ }
    }

    /// 지금 회차 = 총평 수 + 다시 쓰기 진행 중이면 1 (최소 1)
    var currentRound: Int { max((data?.reviews.count ?? 0) + (passMode ? 1 : 0), 1) }
    /// 꽂을 때 적는 회차(항상): 회차 열람 중 그 회차, 다시 쓰기 중 총평 수+1, 1회차 공부 중 1, 끝난 공책 열람은 총평 수
    var bookmarkRound: Int { roundShown ?? currentRound }

    /// 책갈피 꽂기/빼기 (서버에 하나). round는 항상 적는다
    func toggleBookmark(_ sid: String) async {
        if bookmark?.sentenceId == sid {
            bookmark = nil; Cache.shared.setBookmark(nil)
            await SyncManager.shared.clearBookmark()
            AppLog.shared.info("bookmark", "cleared")
        } else {
            let s = data?.sentences.first { $0.id == sid }
            bookmark = Bookmark(articleId: id, sentenceId: sid, round: bookmarkRound, currentRound: currentRound, createdAt: Date().ms, articleTitle: data?.title, sentenceIdx: s?.idx, sentenceText: s?.text)
            Cache.shared.setBookmark(bookmark)
            await SyncManager.shared.setBookmark(articleId: id, sentenceId: sid, round: bookmarkRound)
            AppLog.shared.info("bookmark", "set", ["sentence": sid, "round": "\(bookmarkRound)"])
        }
    }

    func reload() async {
        do { data = try await API.shared.article(id); offline = false }
        catch let e as APIError where e.isNetwork { if let c = Cache.shared.article(id) { data = c; offline = true } else { err = e.localizedDescription } }
        catch { err = error.localizedDescription }
    }

    func applyResult(_ sid: String, _ r: AttemptResult) {
        guard var d = data, let i = d.sentences.firstIndex(where: { $0.id == sid }) else { inflight[sid] = nil; return }
        var s = d.sentences[i]
        if let prev = s.attempt { s.history.append(prev) }
        s.attempt = r.asAttempt
        d.sentences[i] = s
        // 서버가 이번에 표현장에 저장한 포스트잇 → 처음부터 "붙은" 상태로
        let have = Set(d.phrases.map(\.id))
        d.phrases.append(contentsOf: r.phrases.filter { !have.contains($0.id) })
        // 지적과 겹쳐 습득 완료가 자동 취소된 표현(goni 2026-11-18): 캐시·이 공책의 도장을 떼고 첨삭 위에 한 줄
        for rv in r.revoked {
            Cache.shared.setPhraseMastered(id: rv.id, at: nil)
            if let j = d.phrases.firstIndex(where: { $0.id == rv.id }) { d.phrases[j].masteredAt = nil }
        }
        if !r.revoked.isEmpty { revokedNotes[sid] = r.revoked; AppLog.shared.info("notebook", "mastered revoked", ["sentence": sid, "phrases": r.revoked.map(\.phrase).joined(separator: ", ")]) }
        data = d
        inflight[sid] = nil
        if pass != nil, passSubmitted.contains(sid) { savePassProgress() }   // 채점이 도착한 문장만 done에 (2026-11-25)
        if r.grade != .skip { open = sid; lastGraded = sid; requestScroll("bottom") }
    }

    func send(_ sid: String, _ translation: String, wasRedo: Bool? = nil) {
        let attemptId = UUID().uuidString.lowercased()
        let redoing = wasRedo ?? (data?.sentences.first { $0.id == sid }?.attempt != nil)
        AppLog.shared.info("notebook", translation.isEmpty ? "skip" : "submit", ["sentence": sid, "attempt": attemptId, "chars": "\(translation.count)", "online": "\(Connectivity.shared.isOnline)"])
        // 오프라인(또는 아직 서버에 없는 임시 공책): 큐에 넣고 "채점 대기"로. 연결되면 순서대로 채점된다
        if !Connectivity.shared.isOnline || SyncManager.isTemp(sid) {
            queue(sid, translation, attemptId: attemptId, redoing: redoing); return
        }
        // 보내기 전에 큐(디스크)에 먼저 넣는다 (goni 2026-11-18): 앱이 정지 중 iOS에 죽어도 쓴 번역이 남아 다음 실행 때 보내지고, 서버에 이미 있으면 duplicate로 붙는다.
        // 응답이 오면 큐 항목을 지우고, 끊기면 풀어 큐가 보낸다. 큐 전송은 "보내는 중" 항목을 건너뛰어 겹쳐 보내지 않는다
        let opId = SyncManager.shared.queueAttempt(attemptId: attemptId, sentenceId: sid, articleId: id, translation: translation, claimed: true)
        inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing, opId: opId)
        tasks[sid] = Task {
            defer { tasks[sid] = nil }
            do {
                let r = try await API.shared.attempt(sid, translation: translation, attemptId: attemptId)
                SyncManager.shared.finishDirect(opId: opId)
                if !stopped.contains(attemptId) {
                    applyResult(sid, r)
                    NotificationCenter.default.post(name: .lbnAttemptGraded, object: nil, userInfo: ["attemptId": attemptId, "sentenceId": sid, "result": r])   // 같은 공책을 다시 연 모델도 받는다
                }
            }
            catch let e as APIError where e.isNetwork {
                // 보내는 중 끊김: 큐에 남겨 연결되면 보낸다 (같은 attempt_id라 서버에 중복되지 않는다). 멈추기는 큐 항목을 이미 뺐다
                if stopped.contains(attemptId) { return }
                SyncManager.shared.releaseDirect(opId: opId)
                inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing, pending: true, opId: opId)
            }
            catch {
                // 멈춘 요청의 오류(취소, 409 cancelled)는 보여주지 않는다
                if stopped.contains(attemptId) { return }
                // 멈추기가 아닌데 취소됐다(시스템이 끊음) → "채점 중"으로 남기지 말고 큐로 (2026-11-18)
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    SyncManager.shared.releaseDirect(opId: opId)
                    inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing, pending: true, opId: opId); return
                }
                SyncManager.shared.finishDirect(opId: opId)   // 서버 거절: 큐에서 빼고 오류 표시
                inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing, error: error.localizedDescription)
            }
        }
    }
    /// 포그라운드 복귀 안전망(2026-11-18): "채점 중"으로 보이는데 요청 Task가 없으면(앱이 정지되는 사이 끝나 버림) 큐로 보내 다시 전송한다.
    /// 같은 attempt_id라 서버에 이미 저장돼 있으면 그 결과를 duplicate로 받는다
    func recoverInflight() {
        var n = 0
        for (sid, f) in inflight where !f.pending && f.error == nil && tasks[sid] == nil && !stopped.contains(f.attemptId) {
            if let o = f.opId { SyncManager.shared.releaseDirect(opId: o); var g = f; g.pending = true; inflight[sid] = g }   // 큐에 이미 있다 → 풀어서 보내게
            else { queue(sid, f.translation, attemptId: f.attemptId, redoing: f.wasRedo) }
            n += 1
        }
        if n > 0 {
            AppLog.shared.warn("notebook", "inflight without task after foreground → queued", ["count": "\(n)"])
            Task { await SyncManager.shared.flushQueue() }
        }
    }
    private func queue(_ sid: String, _ translation: String, attemptId: String, redoing: Bool) {
        let opId = SyncManager.shared.queueAttempt(attemptId: attemptId, sentenceId: sid, articleId: id, translation: translation)
        inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing, pending: true, opId: opId)
    }

    /// 멈추기: 요청 취소 → 서버에 DELETE → 그 문장을 다시 입력란으로, 쓰던 번역은 그대로
    /// 다시 쓰기 진행(done)에는 **채점이 도착한 문장만** (goni 2026-11-25 "3회차 때 내가 쓴 문장이 아닌 거 같은데" — 제출 즉시 done에 넣어 PUT 하니
    /// 채점이 안 도착한(멈춤·실패·닫음) 문장이 '쓴 것'으로 남아 지난 회차 번역이 이번 회차 것처럼 보였다, 웹 0ef4de1과 같은 규칙).
    /// 화면(passSubmitted)은 전처럼 제출 즉시 넘어가고, 서버·로컬 저장은 채점 대기·실패 중(inflight)인 문장을 뺀다. 제출할 때와 채점이 도착할 때 PUT
    private func passDoneForServer(excluding: String? = nil) -> [String] {
        guard let pass else { return [] }
        return pass.filter { passSubmitted.contains($0) && inflight[$0] == nil && $0 != excluding }
    }
    private func savePassProgress(excluding: String? = nil) {
        guard let pass else { return }
        let done = passDoneForServer(excluding: excluding)
        RedoProgress(ids: pass, done: done).save(id)
        AppLog.shared.info("notebook", "pass progress", ["article": id, "done": "\(done.count)", "submitted": "\(passSubmitted.count)", "count": "\(pass.count)"])
        Task { await SyncManager.shared.putPass(id, done: done) }
    }
    func stop(_ sid: String) {
        guard let f = inflight[sid] else { return }
        stopped.insert(f.attemptId)
        tasks[sid]?.cancel(); tasks[sid] = nil
        inflight[sid] = nil
        AppLog.shared.info("notebook", "stop", ["sentence": sid, "attempt": f.attemptId])
        if pass != nil, passSubmitted.contains(sid) { passSubmitted.remove(sid); savePassProgress() }   // 멈춘 문장은 화면·저장 모두 done에서 뺀다
        if f.wasRedo { redo = sid } else { redo = nil }
        input = f.translation
        focusRequest += 1
        Task { await SyncManager.shared.stopAttempt(attemptId: f.attemptId, sentenceId: sid, articleId: id) }
    }

    /// 현재 문장을 제출(또는 건너뛰기)하고 즉시 다음 문장으로
    func submit(skip: Bool) {
        guard let cur = current else { return }
        let t = skip ? "" : input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !skip && t.isEmpty { return }
        err = nil
        let wasRedo = redo != nil
        input = ""
        send(cur.id, t, wasRedo: wasRedo)
        if let pass {
            // 처음부터 다시: 다음 문장으로 이어서, 끝나면 새 총평을 받으러 마지막 장으로
            passSubmitted.insert(cur.id)
            let i = pass.firstIndex(of: cur.id) ?? -1
            // 그 뒤에서 아직 안 쓴 첫 문장으로(합치기로 되돌아가 썼으면 이미 쓴 문장은 건너뛴다, 2026-11-16)
            if i >= 0, let next = pass[(i + 1)...].first(where: { !passSubmitted.contains($0) }) {
                savePassProgress(excluding: cur.id)   // 지금 문장은 채점이 도착하면(applyResult) 그때 done에 든다
                redo = next; requestScroll(next); focusRequest += 1
            } else {
                // 마지막 문장: PUT 없이 DELETE만 (2026-11-23 규칙). 앞 문장의 PUT이 아직 가는 중이면 SyncManager가 순서를 지킨다
                RedoProgress.clear(id)
                Task { await SyncManager.shared.deletePass(id) }
                self.pass = nil; redo = nil; finishingPass = true
                requestScroll("bottom")
            }
            return
        }
        redo = nil
        requestScroll("bottom")
    }

    func startRedo(_ s: Sentence) { redo = s.id; open = nil; input = "" }
    private func beginPass(_ p: RedoProgress) {
        pass = p.ids; passSubmitted = Set(p.done); redo = p.remaining.first; input = ""; open = nil
        if let r = redo { requestScroll(r) }
        focusRequest += 1
    }

    /// "취소" 버튼(한 문장 다시 쓰기에만): 다시 쓰기를 접는다. pass 진행 중엔 버튼이 없고 Esc도 없다.
    /// 진행은 완주했을 때만 지운다 — 중간 취소로 진행을 지우는 개념은 없다 (goni 2026-11-24 "왜 지우는거야?", 웹에서 Esc 한 번에 3회차 75문장 진행이 지워진 사고 뒤).
    /// 새로 시작하고 싶으면 마지막 장의 "처음부터 다시 쓰기"가 덮어쓴다
    func cancelRedo() {
        input = ""
        if pass == nil { redo = nil }
    }
    var passLabel: String? {
        guard let pass, let redo, let i = pass.firstIndex(of: redo) else { return nil }
        return "다시 \(i + 1) / \(pass.count)"
    }

    func merge(_ sid: String, dir: String) async {
        do {
            let kept = try await SyncManager.shared.mergeSentence(sid, dir: dir); AppLog.shared.info("notebook", "merge \(dir)", ["sentence": sid, "kept": kept ?? ""])
            await reload(); input = ""
            if let kept { passAfterMerge(kept: kept) }
        }
        catch { err = error.localizedDescription }
    }

    /// "잘못 눌렀다 ✗"(goni 2026-11-16): 지금 번역(가장 최근 시도)을 무효로 표시(PUT /api/attempts/:id/void) → 공책 다시 읽기 → 그 문장을 바로 다시 쓴다.
    /// 유효 시도가 하나도 안 남으면 평소 흐름(앞에서부터 안 쓴 첫 문장)이 그 문장부터 이어 쓴다. 다시 쓰기 진행 중이면 done에서 빼고 PUT pass
    func voidAttempt(_ s: Sentence) async {
        guard let aid = s.attempt?.id else { err = "아직 서버에 없는 시도라 표시할 수 없다 (연결되면 다시)"; return }
        err = nil
        do { try await SyncManager.shared.voidAttempt(aid, void: true) } catch { err = error.localizedDescription; return }
        AppLog.shared.info("notebook", "void attempt", ["sentence": s.id, "attempt": aid])
        await reload()
        if pass != nil {
            passSubmitted.remove(s.id)
            savePassProgress()
            redo = s.id
        } else {
            redo = data?.sentences.first { $0.id == s.id }?.attempt != nil ? s.id : nil
        }
        open = nil; input = ""; requestScroll(s.id); focusRequest += 1
    }
    /// 무효 시도 되살리기 (void:false). 서버가 다시 집계하고 공책을 다시 읽는다
    func restoreAttempt(_ a: Attempt) async {
        guard let aid = a.id else { return }
        err = nil
        do { try await SyncManager.shared.voidAttempt(aid, void: false) } catch { err = error.localizedDescription; return }
        AppLog.shared.info("notebook", "restore attempt", ["attempt": aid])
        await reload()
    }

    /// 다시 쓰기 진행 중에 합친 뒤(goni 2026-11-16): 없어진 문장은 진행 목록에서 빼고, 합쳐진(kept) 문장은 이번 회차에 다시 쓴다(done에서 제거, 바로 입력란). PUT /api/articles/:id/pass
    private func passAfterMerge(kept: String) {
        guard pass != nil, let d = data else { return }
        let ids = d.sentences.map(\.id)
        let submitted = ids.filter { passSubmitted.contains($0) && $0 != kept }
        pass = ids; passSubmitted = Set(submitted)
        savePassProgress()   // 채점 도착한 것만 PUT
        AppLog.shared.info("notebook", "pass after merge", ["article": id, "kept": kept, "submitted": "\(submitted.count)", "count": "\(ids.count)"])
        redo = kept; open = nil; input = ""; requestScroll(kept); focusRequest += 1
    }

    /// 열람 화면에서 합친 뒤 공책(쓰기)으로 넘어올 때 바로 다시 쓰기 모드로 열 문장
    static var pendingRedo: [String: String] = [:]

    /// 채점된 문장끼리 합치기: 기록은 남고, kept 문장에 채점이 있으면 바로 다시 쓰기 모드로 열고 가운데로
    func mergeGraded(_ sid: String, dir: String) async -> String? {
        do {
            let kept = try await SyncManager.shared.mergeSentence(sid, dir: dir)
            AppLog.shared.info("notebook", "merge graded \(dir)", ["sentence": sid, "kept": kept ?? ""])
            await reload()
            if let kept, pass != nil { passAfterMerge(kept: kept); return kept }
            if let kept, data?.sentences.first(where: { $0.id == kept })?.attempt != nil {
                if browse { Self.pendingRedo[id] = kept; return kept }
                redo = kept; open = nil; input = ""; requestScroll(kept); focusRequest += 1
            }
            return kept
        } catch { err = error.localizedDescription; return nil }
    }

    /// 문장을 공책에서 뺀다. 빈 공책이 되면 true
    func remove(_ sid: String) async -> Bool {
        do {
            let snapshot = data?.sentences.first { $0.id == sid }
            let idx = data?.sentences.firstIndex { $0.id == sid } ?? 0
            let afterId: String? = idx > 0 ? data?.sentences[idx - 1].id : nil
            let trashId = try await SyncManager.shared.deleteSentence(sid)
            AppLog.shared.info("notebook", "remove sentence", ["sentence": sid, "trash": trashId ?? "queued"])
            if let snapshot { removed.insert(Removed(sentence: snapshot, trashId: trashId, afterId: afterId), at: 0) }
            guard var d = data else { return false }
            d.sentences.removeAll { $0.id == sid }
            if d.sentences.isEmpty { return true }
            data = d
            if redo == sid { redo = nil }
            if current?.id == sid { input = "" }
        } catch { err = error.localizedDescription }
        return false
    }

    /// 되살리기: 서버 휴지통에서 복구(온라인) 또는 큐의 삭제 취소(오프라인). 끝나면 공책을 다시 읽는다
    func restore(_ r: Removed) async {
        do {
            if let t = r.trashId {
                _ = try await API.shared.restoreTrash(t)
                Cache.shared.needsFull = true
            } else if !SyncManager.shared.undoQueuedDelete(r.sentence, articleId: id) {
                err = "이미 서버로 보내져 여기서는 되살릴 수 없다"; return
            }
            removed.removeAll { $0.id == r.id }
            AppLog.shared.info("notebook", "restored sentence", ["sentence": r.sentence.id])
            await reload()
        } catch { err = error.localizedDescription }
    }

    /// 중요도 별 (goni 2026-11-19 "여기서 바로 중요도를 더해 줄 수 있게"): 그 문장의 같은 글자 표현(없으면 같은 글자 아무 표현)에. 표현장에 없으면 붙이고 나서 별
    func setWeight(_ sid: String, _ e: Expression, _ w: Int) async {
        guard var d = data else { return }
        var p = d.phrases.first { $0.sentenceId == sid && $0.phrase == e.phrase } ?? d.phrases.first { $0.phrase == e.phrase }
        if p == nil {
            do { let np = try await SyncManager.shared.savePhrase(e, sentenceId: sid, articleId: d.id, articleTitle: d.title, sentenceText: d.sentences.first { $0.id == sid }?.text); d.phrases.append(np); p = np }
            catch { err = error.localizedDescription; return }
        }
        guard let pid = p?.id else { return }
        do {
            let saved = try await SyncManager.shared.setWeight(pid, weight: w)
            if let i = d.phrases.firstIndex(where: { $0.id == pid }) { d.phrases[i].weight = saved }
            data = d
            AppLog.shared.info("notebook", "weight", ["phrase": pid, "weight": "\(saved)"])
        } catch { data = d; err = error.localizedDescription }
    }
    /// 표현 내 메모 (goni 2026-11-19 "breakout 도약이라고 해석됨"): 그 문장의 같은 글자 표현(없으면 같은 글자 아무 표현)에. 표현장에 없으면 붙이면서 쓴다
    func setPhraseNote(_ sid: String, _ e: Expression, _ note: String) async {
        guard var d = data else { return }
        var p = d.phrases.first { $0.sentenceId == sid && $0.phrase == e.phrase } ?? d.phrases.first { $0.phrase == e.phrase }
        if p == nil {
            guard !note.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            do { let np = try await SyncManager.shared.savePhrase(e, sentenceId: sid, articleId: d.id, articleTitle: d.title, sentenceText: d.sentences.first { $0.id == sid }?.text); d.phrases.append(np); p = np }
            catch { err = error.localizedDescription; return }
        }
        guard let pid = p?.id else { return }
        do {
            let saved = try await SyncManager.shared.setPhraseNote(pid, note: note)
            if let i = d.phrases.firstIndex(where: { $0.id == pid }) { d.phrases[i].note = saved }
            data = d
        } catch { data = d; err = error.localizedDescription }
    }
    func togglePhrase(_ sid: String, _ e: Expression) async {
        guard var d = data else { return }
        do {
            if let ex = d.phrases.first(where: { $0.sentenceId == sid && $0.phrase == e.phrase }), let i = d.phrases.firstIndex(where: { $0.id == ex.id }) {
                // 붙은 포스트잇을 다시 누르면 떼는 게 아니라 습득 완료 토글 (goni 2026-11-18 "포스트잇 떼기 자체를 습득 완료로"). 지우는 건 표현장의 ×뿐
                let on = !ex.isMastered
                d.phrases[i].masteredAt = try await SyncManager.shared.setMastered(ex.id, on: on)
                AppLog.shared.info("notebook", on ? "phrase mastered" : "phrase unmastered", ["id": ex.id])
            } else {
                let p = try await SyncManager.shared.savePhrase(e, sentenceId: sid, articleId: d.id, articleTitle: d.title, sentenceText: d.sentences.first { $0.id == sid }?.text)
                d.phrases.append(p)
            }
            data = d
        } catch { err = error.localizedDescription }
    }

    func setSource(_ url: String) async {
        do { try await SyncManager.shared.setSource(id, url); data?.source = url } catch { err = error.localizedDescription }
    }

    /// 형광펜 묻기: 메모를 붙이고, 서버가 표현장에 붙인 포스트잇도 합친다 (온라인 전용, 폴백 없음)
    func ask(_ sid: String, start: Int, end: Int, span: String) async throws {
        guard Connectivity.shared.isOnline else { throw APIError.server(onlineOnlyMessage) }
        let r = try await API.shared.ask(sid, startWord: start, endWord: end, span: span)
        AppLog.shared.info("marker", "asked", ["sentence": sid, "words": "\(start)-\(end)"])
        data?.highlights.append(r.highlight)
        Cache.shared.upsertHighlight(r.highlight)
        if let p = r.phrase, !(data?.phrases.contains { $0.id == p.id } ?? true) { data?.phrases.append(p); Cache.shared.upsertPhrase(p) }
    }
    /// 형광펜 내 메모 (Claude 없음, 오프라인 큐 가능). links = 메모와 함께 엮을 것
    func memo(_ sid: String, start: Int, end: Int, span: String, note: String, links: [Related] = []) async throws {
        let targets = links.map { LinkTarget(toKind: $0.kind, toId: $0.id) }
        if let r = try await SyncManager.shared.memo(sentenceId: sid, articleId: id, startWord: start, endWord: end, span: span, note: note, links: targets) {
            data?.highlights.append(r.highlight)
            for l in r.highlight.links { addBacklinkLocally(from: r.highlight, link: l) }
            if let p = r.phrase, !(data?.phrases.contains { $0.id == p.id } ?? true) { data?.phrases.append(p) }
        } else if var h = Cache.shared.article(id)?.highlights.last(where: { $0.sentenceId == sid && $0.note == note }) {
            h.links = links.map { HighlightLink(id: "local-" + UUID().uuidString.lowercased(), fromHighlight: h.id, toKind: $0.kind, toId: $0.id, createdAt: Date().ms, text: $0.text, sentenceId: $0.sentenceId, articleId: $0.articleId, title: $0.title) }
            data?.highlights.append(h)
            for l in h.links { addBacklinkLocally(from: h, link: l) }
        }
    }

    // MARK: 엮기
    func related(span: String?, q: String?, excludeSentence: String?, exclude: String?) async -> [Related] {
        await SyncManager.shared.related(span: span, q: q, excludeSentence: excludeSentence, exclude: exclude)
    }
    func addLink(_ h: Highlight, _ r: Related) async {
        guard let i = data?.highlights.firstIndex(where: { $0.id == h.id }) else { return }
        if data!.highlights[i].links.contains(where: { $0.key == r.key }) { return }
        do {
            let l = try await SyncManager.shared.addLink(h.id, to: LinkTarget(toKind: r.kind, toId: r.id), candidate: r)
            data?.highlights[i].links.append(l)
            addBacklinkLocally(from: data!.highlights[i], link: l)
        } catch { err = error.localizedDescription }
    }
    func removeLink(_ h: Highlight, _ l: HighlightLink) async {
        guard let i = data?.highlights.firstIndex(where: { $0.id == h.id }) else { return }
        data?.highlights[i].links.removeAll { $0.id == l.id }
        removeBacklinkLocally(linkId: l.id, toKind: l.toKind, toId: l.toId)
        await SyncManager.shared.deleteLink(l, from: h.id)
    }
    /// 붙여 둔 표현에서 엮기 (goni 2026-11-18). 형광펜 엮기와 같은 경로(SyncManager.addLink from "phrase")
    func addPhraseLink(_ p: Phrase, _ r: Related) async {
        guard let i = data?.phrases.firstIndex(where: { $0.id == p.id }) else { return }
        if (data!.phrases[i].links ?? []).contains(where: { $0.key == r.key }) { return }
        do {
            let l = try await SyncManager.shared.addLink(from: "phrase", id: p.id, to: LinkTarget(toKind: r.kind, toId: r.id), candidate: r)
            data?.phrases[i].links = (data?.phrases[i].links ?? []) + [l]
            let sp = data!.phrases[i]
            insertBacklink(Backlink(id: l.id, fromKind: "phrase", toKind: l.toKind, toId: l.toId, createdAt: l.createdAt, fromId: sp.id, text: sp.phrase, note: sp.meaning, sentenceId: sp.sentenceId, articleId: sp.articleId, title: data?.title), toKind: l.toKind, toId: l.toId)
        } catch { err = error.localizedDescription }
    }
    func removePhraseLink(_ p: Phrase, _ l: HighlightLink) async {
        guard let i = data?.phrases.firstIndex(where: { $0.id == p.id }) else { return }
        data?.phrases[i].links?.removeAll { $0.id == l.id }
        removeBacklinkLocally(linkId: l.id, toKind: l.toKind, toId: l.toId)
        await SyncManager.shared.deleteLink(l, from: p.id)
    }
    /// 대상이 같은 공책의 형광펜/표현이면 그쪽 backlinks도 바로 넣는다
    private func addBacklinkLocally(from h: Highlight, link l: HighlightLink) {
        insertBacklink(Backlink(id: l.id, fromKind: "highlight", toKind: l.toKind, toId: l.toId, createdAt: l.createdAt, fromId: h.id, text: h.span, note: h.note, sentenceId: h.sentenceId, articleId: h.articleId, title: data?.title), toKind: l.toKind, toId: l.toId)
    }
    private func insertBacklink(_ b: Backlink, toKind: String, toId: String) {
        if toKind == "highlight", let j = data?.highlights.firstIndex(where: { $0.id == toId }) { data?.highlights[j].backlinks.append(b) }
        if toKind == "phrase", let j = data?.phrases.firstIndex(where: { $0.id == toId }) { data?.phrases[j].backlinks = (data?.phrases[j].backlinks ?? []) + [b] }
    }
    private func removeBacklinkLocally(linkId: String, toKind: String, toId: String) {
        if toKind == "highlight", let j = data?.highlights.firstIndex(where: { $0.id == toId }) { data?.highlights[j].backlinks.removeAll { $0.id == linkId } }
        if toKind == "phrase", let j = data?.phrases.firstIndex(where: { $0.id == toId }) { data?.phrases[j].backlinks?.removeAll { $0.id == linkId } }
    }
    func setNote(_ h: Highlight, _ note: String) async {
        if let i = data?.highlights.firstIndex(where: { $0.id == h.id }) { data?.highlights[i].note = note.isEmpty ? nil : note }
        await SyncManager.shared.setHighlightNote(h.id, note: note)
    }
    /// 포스트잇에서 바로 써 보기 (자유 작문). 오프라인이면 큐 → nil
    func freeDrill(_ sid: String, _ e: Expression, answer: String, drillId: String) async throws -> Drill? {
        let pid = data?.phrases.first { $0.sentenceId == sid && $0.phrase == e.phrase }?.id
        return try await SyncManager.shared.freeDrill(API.DrillFreeBody(phrase: e.phrase, meaning: e.meaning, phraseId: pid, sentenceId: sid, answer: answer, drillId: drillId))
    }
    /// "문제 내줘": 표현장에 붙어 있으면 그 표현으로 한국어 문장을 받는다. 없으면 nil
    func drillFor(_ sid: String, _ e: Expression) async throws -> Drill? {
        guard let pid = data?.phrases.first(where: { $0.sentenceId == sid && $0.phrase == e.phrase })?.id, !SyncManager.isTemp(pid) else { return nil }
        guard Connectivity.shared.isOnline else { throw APIError.server(onlineOnlyMessage) }
        return try await API.shared.nextDrill(phraseId: pid)
    }
    /// 출제형 답: 큐에 먼저 넣고 보낸다. 오프라인이거나 끊기면 nil("연결되면 채점")
    func answerDrill(_ d: Drill, _ answer: String) async throws -> Drill? {
        try await SyncManager.shared.answerDrill(d, answer: answer)
    }
    /// 써 보기 횟수 +1 (상자에서 채점이 끝났거나, 오프라인 큐의 결과가 돌아왔을 때)
    func bumpDrillCount(_ phrase: String) { data?.drillCounts[phrase, default: 0] += 1 }
    func deleteHighlight(_ h: Highlight) async {
        guard Connectivity.shared.isOnline else { err = onlineOnlyMessage; return }
        do { try await API.shared.deleteHighlight(h.id); data?.highlights.removeAll { $0.id == h.id }; Cache.shared.removeHighlight(id: h.id) }
        catch { err = error.localizedDescription }
    }

    /// 세션마다 이 공책에서 마지막으로 채점한 문장 뒤에 "여기까지" 줄.
    /// 채점 대기·진행 중(inflight, 큐 포함)인 문장과 다시 쓰기 중 이번 회차에 제출하지 않은 문장은 뺀다 — 그 문장이 들고 있는 attempt는 아직 옛 번역이라
    /// 옛 세션의 "마지막 문장"으로 잡혀 옛 ✂ 줄·총평이 떴다 사라진다 (goni 2026-11-23 "엔터쳤는데 옛날 총평이 잠깐", 웹 f9e04ec과 같은 규칙)
    func markers(_ sessions: [StudySession]) -> [String: StudySession] {
        guard let d = data else { return [:] }
        var m: [String: StudySession] = [:]
        for s in sessions {
            var best: Sentence?
            for x in d.sentences where inflight[x.id] == nil {
                guard let t = visibleAttempt(x)?.createdAt, t >= s.startedAt, t <= s.endedAt else { continue }
                if best == nil || t > best!.attempt!.createdAt { best = x }
            }
            if let best { m[best.id] = s }
        }
        return m
    }
}

/// 공책 (웹 Read.tsx)
struct NotebookView: View {
    var articleId: String
    var focusId: String? = nil
    var restartAfter: Int? = nil
    var browseAll: Bool = false
    var round: Int? = nil
    @EnvironmentObject var router: Router
    @Environment(\.scenePhase) private var phase
    @State private var phrasesSheet: String?   // "표현장 ↗": 그 표현으로 표현장을 시트로 (공책은 그대로)
    @ObservedObject private var session = SessionModel.shared
    @StateObject private var m: NotebookModel
    @FocusState private var focused: Bool
    @State private var toRemove: Sentence?
    @State private var readingIndex = 0          // 화면 40% 지점의 문장 idx
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var lastProgressTick = Date.distantPast
    // 공책 안에서 찾기 (goni 2026-11-24 "특정 표현들 썼던 거 검색이 되면", 웹 find.ts와 같은 규칙). 서버 호출 없이 받은 공책 데이터에서
    @State private var findOpen = false
    @State private var findText = ""
    @State private var findCursor: Int?          // 지금 보는 히트 번호 (nil이면 아직 이동 전: "n문장"만)
    @State private var findHit: String?          // 찾기로 펼친 문장 (노란 띠)
    @FocusState private var findFocused: Bool
    /// 두 글자부터. 비교는 normalizeForFind
    private var findTerm: String? {
        guard findOpen else { return nil }
        let t = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizeForFind(t).count >= 2 ? t : nil
    }
    private struct FindHit { var id: String; var pos: Int; var places: [String] }
    /// 지금 화면에 있는 문장(upto까지)에서: 원문 / 내 번역 / 참고 / 첨삭 / 표현 / 형광펜. 지금 쓰는 문장·채점 중 문장은 원문만, 다시 쓰기에서 가려 둔 지난 회차 번역은 안 본다
    private func findHits(_ d: ArticleDetail, upto: Int) -> [FindHit] {
        guard let term = findTerm else { return [] }
        let t = normalizeForFind(term)
        func has(_ s: String?) -> Bool { guard let s, !s.isEmpty else { return false }; return normalizeForFind(s).contains(t) }
        var out: [FindHit] = []
        for (pos, x) in d.sentences.prefix(upto).enumerated() {
            var places: [String] = []
            if has(x.text) { places.append("원문") }
            let writing = m.redo == x.id || (!m.browse && x.id == m.current?.id) || m.inflight[x.id] != nil
            if !writing, let a = m.visibleAttempt(x) {
                let fb = a.feedback
                if has(a.translation) { places.append("내 번역") }
                if has(fb.reference) { places.append("참고") }
                if fb.issues.contains(where: { has($0.source) || has($0.mine) || has($0.meaning) || has($0.why) }) { places.append("첨삭") }
                let saved = d.phrases.filter { $0.sentenceId == x.id }
                if fb.expressions.contains(where: { has($0.phrase) || has($0.meaning) }) || saved.contains(where: { has($0.phrase) || has($0.meaning) || has($0.note) }) { places.append("표현") }
                if d.highlights.filter({ $0.sentenceId == x.id }).contains(where: { has($0.note) || has($0.answer.meaning) || has($0.answer.why) || has($0.answer.similar) }) { places.append("형광펜") }
            }
            if !places.isEmpty { out.append(FindHit(id: x.id, pos: pos, places: places)) }
        }
        return out
    }
    /// 다음(+1)/이전(-1): 처음엔 지금 보는 자리(readingIndex)에서 가까운 쪽, 끝에서 처음으로 돈다. 그 문장을 펼치고(책갈피는 안 옮김) 가운데로
    private func findStep(_ hits: [FindHit], _ dir: Int) {
        guard !hits.isEmpty else { return }
        let n = hits.count
        let i: Int
        if let c = findCursor, c < n { i = (c + dir + n) % n }
        else if dir > 0 { i = hits.firstIndex { $0.pos >= readingIndex } ?? 0 }
        else { i = hits.lastIndex { $0.pos <= readingIndex } ?? (n - 1) }
        findCursor = i; findHit = hits[i].id
        m.openForFind(hits[i].id); m.requestScroll(hits[i].id)
    }
    private func findStatus(_ hits: [FindHit]) -> String {
        if let c = findCursor, c < hits.count { return "\(c + 1) / \(hits.count) · " + hits[c].places.joined(separator: " · ") }
        return findTerm == nil ? "" : "\(hits.count)문장"
    }
    private func closeFind() { findOpen = false; findText = ""; findCursor = nil; findHit = nil; findFocused = false }
    @ViewBuilder private func findBar(_ d: ArticleDetail, upto: Int) -> some View {
        let hits = findHits(d, upto: upto)
        HStack(spacing: 10) {
            TextField("공책 안에서 찾기", text: $findText).font(Theme.hand(20)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                .focused($findFocused).submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                .onSubmit { findStep(hits, +1) }
            Text(findStatus(hits)).font(Theme.hand(16)).foregroundStyle(Theme.pencil).lineLimit(1).fixedSize()
            Tiny(title: "↑\u{FE0E}", size: 18) { findStep(hits, -1) }
            Tiny(title: "↓\u{FE0E}", size: 18) { findStep(hits, +1) }
            Tiny(title: "×", size: 20) { closeFind() }.keyboardShortcut(.escape, modifiers: []).accessibilityLabel("찾기 닫기")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .onChange(of: findText) { _, _ in findCursor = nil; findHit = nil }
    }

    init(articleId: String, focusId: String? = nil, restartAfter: Int? = nil, browseAll: Bool = false, round: Int? = nil) {
        self.articleId = articleId; self.focusId = focusId; self.restartAfter = restartAfter; self.browseAll = browseAll; self.round = round
        _m = StateObject(wrappedValue: NotebookModel(id: articleId, focusId: focusId, restartAfter: restartAfter, browseAll: browseAll, round: round))
    }

    var body: some View {
        ZStack {
            Theme.desk.ignoresSafeArea()
            if let d = m.data { content(d) }
            else if let e = m.err { ErrorText(message: e).padding() }
            else {
                // 서버 응답을 기다리는 동안 빈 화면이 아니라 "불러오는 중"을 보인다(연결은 있어도 느린 망에서 빈 화면으로 보이던 사고, 2026-11-15)
                VStack(spacing: 12) {
                    ProgressView().tint(Theme.pencil)
                    Text("공책을 불러오는 중…").font(Theme.hand(20)).foregroundStyle(Theme.pencil)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.desk, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { Text(m.data?.title ?? Cache.shared.articleTitle(articleId) ?? "").font(Theme.hand(22)).lineLimit(1) }
            // "찾기"는 늘 보이는 상단 바 오른쪽에 (goni 2026-11-24 "찾기 버튼이 어딨지?" — 머리줄에 두니 스크롤에 밀려 안 보였다)
            ToolbarItem(placement: .topBarTrailing) {
                if m.data != nil, !findOpen { Tiny(title: "찾기", color: Theme.red, size: 19) { findOpen = true; findFocused = true } }
            }
        }
        // 하드웨어 키보드 Esc는 작은 상자(써 보기·메모·엮기 검색)만 닫는다 — "Esc = 참고 번역 토글"·"Esc = 다시 쓰기 취소"는 뺐다 (goni 2026-11-24 "esc는 작은 상자 닫기만", 웹 9452d90)
        .task {
            await m.load { newReview in router.shelfPath = [.done(id: articleId, newReview: newReview)] }
            await m.loadBookmark()
            await session.load()
            if !m.browse { focused = true }
            #if DEBUG
            // 화면 확인용: LBN_AUTOREMOVE=<문장 id> 이면 그 문장을 빼서 되살리기 줄을 보여준다
            if let sid = ProcessInfo.processInfo.environment["LBN_AUTOREMOVE"], m.data?.sentences.contains(where: { $0.id == sid }) == true { _ = await m.remove(sid) }
            // 화면 확인용: LBN_AUTOOPEN=<문장 id> 이면 그 항목을 펼친다. LBN_AUTOVOID=<문장 id> 이면 그 문장의 지금 번역을 "잘못 눌렀다"로 표시한 뒤 입력을 접고 항목을 펼친다
            if let sid = ProcessInfo.processInfo.environment["LBN_AUTOOPEN"] { m.open = sid; m.requestScroll(sid) }
            // 화면 확인용: LBN_FIND=<말> 이면 찾기 칸을 열고 그 말로 한 번 이동한다
            if let q = ProcessInfo.processInfo.environment["LBN_FIND"], let d = m.data { findOpen = true; findText = q; try? await Task.sleep(for: .seconds(3)); let total = d.sentences.count; findStep(findHits(d, upto: m.browse ? total : (m.frontIdx ?? total)), +1) }
            // 화면 확인용: LBN_AUTOPIN=<문장 id> 이면 그 문장의 첫 지적 표현을 표현장에 붙인다("붙여 둠 ✓"·"써 보기" 확인용)
            if let sid = ProcessInfo.processInfo.environment["LBN_AUTOPIN"], let i = m.data?.sentences.first(where: { $0.id == sid })?.attempt?.feedback.issues.first {
                await m.togglePhrase(sid, Expression(phrase: i.source.trimmingCharacters(in: .whitespacesAndNewlines), meaning: i.meaning))
                // LBN_AUTOPIN2=1: 한 번 더 눌러 습득 완료까지 ("습득 완료 ✓" 확인용)
                if ProcessInfo.processInfo.environment["LBN_AUTOPIN2"] == "1" { await m.togglePhrase(sid, Expression(phrase: i.source.trimmingCharacters(in: .whitespacesAndNewlines), meaning: i.meaning)) }
            }
            if let sid = ProcessInfo.processInfo.environment["LBN_AUTOVOID"], let x = m.data?.sentences.first(where: { $0.id == sid }) { await m.voidAttempt(x); m.redo = nil; m.open = sid; m.requestScroll(sid) }
            // 화면 확인용: LBN_AUTOPHRASES=<표현 id> 이면 그 표현으로 표현장 시트를 연다("표현장 ↗" 확인용)
            if let pid = ProcessInfo.processInfo.environment["LBN_AUTOPHRASES"] { Task { try? await Task.sleep(for: .seconds(1)); phrasesSheet = pid } }
            // 화면 확인용: LBN_AUTOSPEAK=<문장 id> 이면 그 문장을 읽기 시작한다("멈춤 ■" 확인용)
            if let sid = ProcessInfo.processInfo.environment["LBN_AUTOSPEAK"], let x = m.data?.sentences.first(where: { $0.id == sid }) { Task { try? await Task.sleep(for: .seconds(1)); TapePlayer.shared.speakOnce(phrase: x.text) } }
            // 화면 확인용: LBN_AUTOSENTPIN=<문장 id> 이면 그 문장 전체를 표현장에 붙인다("문장 붙여 둠 ✓" 확인용)
            if let sid = ProcessInfo.processInfo.environment["LBN_AUTOSENTPIN"], let x = m.data?.sentences.first(where: { $0.id == sid }), let a = x.attempt { await m.togglePhrase(sid, Expression(phrase: x.text, meaning: a.feedback.reference.isEmpty ? a.translation : a.feedback.reference)) }
            // 화면 확인용: LBN_AUTOSTRUCT=<문장 id> 이면 구조 분석 상자가 보이도록 받은 뒤 맨 아래로 스크롤
            if ProcessInfo.processInfo.environment["LBN_AUTOSTRUCT"] != nil { Task { try? await Task.sleep(for: .seconds(4.5)); m.requestScroll("bottom") } }
            // 화면 확인용: LBN_AUTOTRY=<문장 id> 이면 써 보기 상자(EntryView가 연다)가 보이도록 잠시 뒤 맨 아래로 스크롤
            if ProcessInfo.processInfo.environment["LBN_AUTOTRY"] != nil || ProcessInfo.processInfo.environment["LBN_AUTOLINK"] != nil { Task { try? await Task.sleep(for: .seconds(3.5)); m.requestScroll("bottom") } }
            // 화면 확인용: LBN_AUTOMERGE=prev|next 이면 현재 문장을 그 방향으로 합친다 (다시 쓰기 중 합치기 확인)
            if let dir = ProcessInfo.processInfo.environment["LBN_AUTOMERGE"], let cur = m.current { await m.merge(cur.id, dir: dir) }
            // 화면 확인용: LBN_AUTOSUBMIT=1 이면 현재 문장에 번역을 넣고 바로 제출한다 (채점 중 상태)
            if let v = ProcessInfo.processInfo.environment["LBN_AUTOSUBMIT"], session.inSession, let cur = m.current {
                m.input = "분석가들은 노동 시장이 더 약해지면 12월 15일까지 인하를 예상한다."; m.submit(skip: false)
                if v == "stop" { Task { try? await Task.sleep(for: .seconds(2)); m.stop(cur.id) } }   // 2초 뒤 멈추기까지
                // LBN_AUTOCLOSE=1: 그 채점이 끝나면 "오늘 여기까지"까지 누른다 (✂ 줄 아래 총평 한 번만 보이는지 확인용)
                if ProcessInfo.processInfo.environment["LBN_AUTOCLOSE"] == "1" {
                    for _ in 0..<60 where !m.inflight.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                    await session.close()
                }
            }
            #endif
        }
        .onChange(of: m.allDone) { _, _ in checkFinish() }
        .onChange(of: phase) { _, p in
            if p == .active { m.recoverInflight() }   // 백그라운드에서 돌아왔을 때 안전망
            // 백그라운드로 갈 때 입력란 포커스를 내린다: 돌아올 때 키보드가 다시 뜨면서 입력란(지금 문장)으로 스크롤돼 읽던 자리가 사라졌다
            // (goni 2026-11-24 "중간에 있는 다른 부분들을 보다가 백그라운드 전환하고 다시 보면 그 위치가 기억되지 않는"). 쓰려면 입력란을 다시 누른다
            if p == .background { focused = false }
        }
        .sheet(item: Binding(get: { phrasesSheet.map { PhraseRef(id: $0) } }, set: { phrasesSheet = $0?.id })) { r in
            PhrasesView(focusPhraseId: r.id, onClose: { phrasesSheet = nil }).environmentObject(router).keyboardDismissBar()
        }
        .onChange(of: m.inflight.isEmpty) { _, _ in checkFinish() }
        .onChange(of: m.finishingPass) { _, _ in checkFinish() }
        .onChange(of: m.focusRequest) { _, _ in focused = true }
    }

    /// 채점된 문장 합치기 버튼을 보일지: 같은 문단의 앞/뒤 문장이 있고, 회차 열람이 아닐 때(다시 쓰기 진행 중에도 보인다, goni 2026-11-16)
    private func mergeTarget(_ x: Sentence, d: ArticleDetail, dir: String) -> (() -> Void)? {
        guard m.roundShown == nil, let i = d.sentences.firstIndex(where: { $0.id == x.id }) else { return nil }
        let j = dir == "prev" ? i - 1 : i + 1
        guard d.sentences.indices.contains(j), d.sentences[j].paragraph == x.paragraph else { return nil }
        return {
            Task {
                let kept = await m.mergeGraded(x.id, dir: dir)
                if m.browse, kept != nil { router.shelfPath = [.notebook(id: m.id)] }   // 열람이었으면 공책(쓰기)으로 가서 바로 다시 쓰기
                else { focused = true }
            }
        }
    }

    /// 엮은 문장으로 이동: 같은 공책이면 그 문장을 펼치고 가운데로, 아니면 그 공책의 열람 화면으로
    private func openSentence(_ aid: String, _ sid: String) {
        if aid == m.id, m.data?.sentences.contains(where: { $0.id == sid }) == true {
            m.open = sid; m.requestScroll(sid)
        } else {
            router.shelfPath.append(.notebook(id: aid, focus: sid, browse: true))
        }
    }

    /// 화면 세로 40% 지점에 걸린 문장(없으면 가장 가까운 문장)의 idx
    private func updateReadingIndex(_ d: ArticleDetail) {
        let h = UIScreen.main.bounds.height
        let y = h * 0.4
        // 분자는 DB idx가 아니라 "지금 공책에 남아 있는 문장 배열에서의 순서" (문장을 지우면 idx가 띄엄띄엄이라 어긋난다)
        var best: (pos: Int, dist: CGFloat)? = nil
        for (pos, s) in d.sentences.enumerated() {
            guard let f = rowFrames[s.id] else { continue }
            let dist: CGFloat = f.minY <= y && f.maxY >= y ? 0 : min(abs(f.minY - y), abs(f.maxY - y))
            if best == nil || dist < best!.dist { best = (pos, dist) }
            if dist == 0 { break }
        }
        if let b = best, b.pos != readingIndex { readingIndex = b.pos }
    }

    /// 모든 문장이 채점됐고 진행 중·오류 상태가 없으면 마지막 문장의 첨삭을 펼쳐 보여 주고 공책에 머문다.
    /// 마지막 장은 발의 "마지막 장 →"(다시 쓰기 회차를 끝냈으면 "마지막 장 · 새 총평 받기 →")으로 직접 넘어간다.
    /// 예전엔 바로 넘겨서 마지막 문장 채점을 못 보고 지나갔다(goni 2026-11-16). 열자마자 전부 채점돼 있는 경우는 load()의 onDone이 그대로 넘긴다
    private func checkFinish() {
        guard !m.browse, m.redo == nil, m.inflight.isEmpty, m.allDone, let last = m.data?.sentences.last else { return }
        if m.open == nil { m.open = last.id }
        m.requestScroll(last.id)
    }

    private func content(_ d: ArticleDetail) -> some View {
        let total = d.sentences.count
        let doneCount = d.sentences.filter { $0.attempt != nil }.count
        let redoIdx = m.redo.flatMap { r in d.sentences.firstIndex { $0.id == r } }
        let upto = m.browse ? total : m.passMode ? (redoIdx.map { $0 + 1 } ?? total) : (m.frontIdx ?? total)
        let waiting = m.inflight.count
        // ✂ 줄은 다시 쓰기(pass) 진행 중에도 그 회차에 쓴 마지막 문장 뒤에 (goni 2026-11-20). 화면에 있는 문장(upto까지)에 걸린 것만
        let shownIds = Set(d.sentences.prefix(upto).map(\.id))
        let markers = m.markers(session.sessions).filter { shownIds.contains($0.key) }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookHead(tab: m.browse ? (m.roundShown.map { "\($0)회차 열람" } ?? "열람") : (m.passLabel ?? "\(doneCount) / \(total)")) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(d.title).lineLimit(2)
                            SourceLink(source: d.source ?? "") { await m.setSource($0) }
                        }
                    }
                    Paper {
                        ForEach(m.removed.filter { $0.afterId == nil }) { r in removedRow(r) }
                        ForEach(Array(d.sentences.prefix(upto).enumerated()), id: \.element.id) { i, x in
                            if i > 0, d.sentences[i - 1].paragraph != x.paragraph { BlankLine() }
                            row(x, d: d)
                                .background(GeometryReader { g in Color.clear.preference(key: RowFrames.self, value: [x.id: g.frame(in: .named("scroll"))]) })
                            if let s = markers[x.id] {
                                SessionMark(session: s)
                                if s.review != nil || s.id.hasPrefix("local-") {
                                    SessionReviewLines(session: s, size: 16, articleTitle: d.title) { Task { await session.retryReview(s) } }
                                        .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight).padding(.bottom, 4)
                                }
                            }
                            ForEach(m.removed.filter { $0.afterId == x.id }) { r in removedRow(r) }
                        }
                        if m.redo == nil, !m.browse, let cur = m.current {
                            if let f = m.frontIdx, f > 0, d.sentences[f - 1].paragraph != cur.paragraph { BlankLine() }
                            inputBlock(cur)
                        }
                        foot(d, waiting: waiting)
                    }
                    // 세션 줄(오늘 여기까지·버리기)은 StudyDot으로 옮겼다. 닫는 순간의 "기록했다 · 총평"은 어느 화면이든 StudyDot 패널 하나로, ✂ 줄을 그렸어도 생략하지 않는다(goni 2026-11-20 총평 자리 규칙)
                }
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 40, trailing: 10))
                .readableWidth()
                Color.clear.frame(height: 1).id("bottom")
            }
            .scrollDismissesKeyboard(.interactively)
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(RowFrames.self) { frames in
                // 스크롤 중에만 들어오는 변화. 60ms로 묶어 가볍게
                rowFrames = frames
                let now = Date()
                guard now.timeIntervalSince(lastProgressTick) > 0.06 else { return }
                lastProgressTick = now
                updateReadingIndex(d)
            }
            .overlay(alignment: .top) {
                if total > 1 {
                    ReadingProgressBar(index: readingIndex, total: total,
                                       paragraphStarts: d.sentences.indices.filter { $0 > 0 && d.sentences[$0].paragraph != d.sentences[$0 - 1].paragraph },
                                       onSeek: { i in
                                           if i < upto { withAnimation { proxy.scrollTo(d.sentences[i].id, anchor: .center) } }
                                           else { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }   // 아직 안 그려진 뒤쪽이면 맨 아래로
                                       })
                }
            }
            .onChange(of: m.scrollTo) { _, t in
                guard let t else { return }
                withAnimation { proxy.scrollTo(t, anchor: t == "bottom" ? .bottom : .center) }
                m.scrollTo = nil
            }
            .environment(\.searchTerm, findTerm)
            // 찾기 칸은 스크롤과 상관없이 위에 고정 (이동해도 칸이 보이게)
            .safeAreaInset(edge: .top, spacing: 0) { if findOpen { findBar(d, upto: upto).background(Theme.desk) } }
        }
        .confirmationDialog("이 문장을 공책에서 뺄까요?", isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }), titleVisibility: .visible) {
            Button("빼기", role: .destructive) {
                if let s = toRemove { Task { if await m.remove(s.id) { router.shelfPath = [] } } }
            }
        }
    }

    /// 지운 문장이 있던 자리: "뺀 문장: "…"(취소선) · 되살리기 ↩ · ×" 한 줄(빗금 배경). 이 화면을 떠나기 전까지
    private func removedRow(_ r: NotebookModel.Removed) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            (Text("뺀 문장: ").foregroundColor(Theme.pencil) + Text(r.sentence.text).strikethrough(true, color: Theme.pencil))
                .font(Theme.hand(19)).foregroundStyle(Theme.pencil).lineLimit(2)
            Spacer(minLength: 0)
            Tiny(title: "되살리기 ↩\u{FE0E}", color: Theme.red, size: 19) { Task { await m.restore(r) } }
            Button { m.removed.removeAll { $0.id == r.id } } label: { Text("×").font(.system(size: 16)).foregroundStyle(Theme.pencil).padding(.horizontal, 4) }
                .buttonStyle(.plain).accessibilityLabel("되살리기 줄 닫기")
        }
        .padding(.vertical, 4)
        .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
        .frame(minHeight: Theme.lh)
        .background(Hatch().foregroundStyle(Theme.pencil.opacity(0.12)))
    }

    @ViewBuilder
    private func row(_ x: Sentence, d: ArticleDetail) -> some View {
        if m.continueInBrowse, m.redo == nil, x.id == m.current?.id {
            // 열람: 다음에 쓸 문장 자리에 원문 + "이어서 쓰기 →"(쓰기 화면으로, 그 문장부터). 입력란은 열지 않는다. 그 뒤 문장만 "(아직)" (goni 2026-11-18)
            Entry {
                Text(x.text).enLine()
                Tiny(title: "이어서 쓰기 →\u{FE0E}", color: Theme.red) { router.shelfPath = [.notebook(id: articleId)] }.frame(height: Theme.lh)
            }
            .id(x.id)
        } else if m.redo == x.id {
            inputBlock(x)
        } else if let f = m.inflight[x.id] {
            Entry(stamp: AnyView(Stamp(kind: f.error != nil ? .error : f.pending ? .waiting : .busy))) {
                Text(x.text).enLine()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if f.translation.isEmpty { Text("건너뜀").handLine(size: 21, color: Theme.pencil) } else { Text(f.translation).koLine() }
                    if f.pending { Text("연결되면 채점").font(Theme.hand(17)).foregroundStyle(Theme.pencil) }
                    if f.error == nil { Tiny(title: "멈추기 ↩\u{FE0E}") { m.stop(x.id); focused = true } }
                }
                if let e = f.error {
                    HStack(spacing: 10) {
                        Text(e).redpen()
                        Tiny(title: "다시 시도") { m.send(x.id, f.translation, wasRedo: f.wasRedo) }
                    }
                }
            }
            .id(x.id)
        } else if m.visibleAttempt(x) != nil {
            EntryView(
                s: x, expanded: m.open == x.id,
                onToggle: { m.open = m.open == x.id ? nil : x.id },
                showRef: m.refOpen[x.id] ?? true,
                onToggleRef: { m.refOpen[x.id] = !(m.refOpen[x.id] ?? true) },
                savedPhrases: d.phrases.filter { $0.sentenceId == x.id },
                onTogglePhrase: { e in Task { await m.togglePhrase(x.id, e) } },
                onRemove: m.browse ? nil : { toRemove = x },
                onRedo: m.browse ? nil : { m.startRedo(x); focused = true },
                onVoid: m.browse || x.attempt?.id == nil ? nil : { Task { await m.voidAttempt(x) } },
                onRestore: m.browse ? nil : { a in Task { await m.restoreAttempt(a) } },
                onMergePrev: mergeTarget(x, d: d, dir: "prev"),
                onMergeNext: mergeTarget(x, d: d, dir: "next"),
                highlight: focusId == x.id || findHit == x.id,
                bookmarked: m.bookmark?.sentenceId == x.id,
                onBookmark: { Task { await m.toggleBookmark(x.id) } },
                highlights: d.highlights.filter { $0.sentenceId == x.id },
                onAsk: { st, en, sp in try await m.ask(x.id, start: st, end: en, span: sp) },
                onDeleteHighlight: { h in await m.deleteHighlight(h) },
                onMemo: { st, en, sp, n, ls in try await m.memo(x.id, start: st, end: en, span: sp, note: n, links: ls) },
                onNote: { h, n in await m.setNote(h, n) },
                onRelated: { sp, q, es, ex in await m.related(span: sp, q: q, excludeSentence: es, exclude: ex) },
                onAddLink: { h, r in await m.addLink(h, r) },
                onRemoveLink: { h, l in await m.removeLink(h, l) },
                onAddPhraseLink: { p, r in await m.addPhraseLink(p, r) },
                onRemovePhraseLink: { p, l in await m.removePhraseLink(p, l) },
                onOpenSentence: { aid, sid in openSentence(aid, sid) },
                onFree: { e, a, did in try await m.freeDrill(x.id, e, answer: a, drillId: did) },
                onDrillFor: { e in try await m.drillFor(x.id, e) },
                onAnswerDrill: { d, a in try await m.answerDrill(d, a) },
                drillCounts: d.drillCounts,
                onDrillGraded: { ph in m.bumpDrillCount(ph) },
                revoked: m.revokedNotes[x.id] ?? [],
                weightOf: { e in (d.phrases.first { $0.sentenceId == x.id && $0.phrase == e.phrase } ?? d.phrases.first { $0.phrase == e.phrase })?.stars ?? 0 },
                onWeight: { e, w in await m.setWeight(x.id, e, w) },
                noteOf: { e in (d.phrases.first { $0.sentenceId == x.id && $0.phrase == e.phrase } ?? d.phrases.first { $0.phrase == e.phrase })?.note },
                onPhraseNote: { e, t in await m.setPhraseNote(x.id, e, t) },
                onOpenPhrases: { pid in phrasesSheet = pid },
                onStructure: { f in try await SyncManager.shared.structure(sentenceId: x.id, force: f) },
                onAskSentence: { q in try await SyncManager.shared.askSentence(sentenceId: x.id, question: q) },
                onDeleteQA: { qid in try await SyncManager.shared.deleteSentenceQA(sentenceId: x.id, qid: qid) }
            )
            .id(x.id)
        } else {
            Entry { Text(x.text).enLine(); Text("(아직)").handLine(size: 21, color: Theme.pencil) }.id(x.id)
        }
    }

    private func inputBlock(_ s: Sentence) -> some View {
        let redo = m.redo != nil
        return Entry(stamp: redo ? AnyView(Stamp(kind: .redo)) : nil) {
            Text(s.text).font(Theme.print(16)).foregroundStyle(redo ? Theme.pencil : Theme.ink).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
                .padding(.trailing, 58)
                .overlay(alignment: .topTrailing) {   // 지금 쓰는 문장의 원문 듣기 🔊 · 복사 ⎘
                    HStack(spacing: 8) { SpeakButton(text: s.text, label: "🔊\u{FE0E}", stopLabel: "■\u{FE0E}", size: 16); CopyButton(text: s.text, label: "⎘\u{FE0E}", size: 18) }.frame(height: Theme.lh)
                }
            if !session.inSession {
                Button { session.begin(); focused = true } label: {
                    Text("공부 시작 ▶\u{FE0E} 을 누르면 여기에 쓸 수 있다").redpen()
                }.buttonStyle(.plain)
            } else {
                TextField(redo ? "다시 쓴다" : "여기에 번역을 쓴다", text: $m.input, axis: .vertical)
                    .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                    .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                    .focused($focused)
                    .submitLabel(.send)
                    .onChange(of: m.input) { _, v in
                        // 한글 조합 중 Enter는 글자 확정이지 제출이 아니다 →\u{FE0E} 조합이 끝나 줄바꿈이 실제로 들어온 뒤에만 제출
                        if v.contains("\n") { m.input = v.replacingOccurrences(of: "\n", with: " "); m.submit(skip: false) }
                    }
            }
        }
        .id(s.id)
    }

    @ViewBuilder
    private func foot(_ d: ArticleDetail, waiting: Int) -> some View {
        let cur = m.current
        VStack(alignment: .leading, spacing: 4) {
            if let e = m.err { ErrorText(message: e) }
            FlowLayout(spacing: 18) {
                if m.browse {
                    Tiny(title: "←\u{FE0E} 돌아가기") { if router.shelfPath.count > 1 { router.shelfPath.removeLast() } else { router.shelfPath = [] } }
                    if RedoProgress.load(articleId) != nil {
                        Tiny(title: "다시 쓰기 이어서 →\u{FE0E}", color: Theme.red) { router.shelfPath = [.notebook(id: articleId)] }
                    } else if cur != nil, m.continueInBrowse {
                        // "이어서 쓰기 →"는 본문의 다음 문장 자리에 있다
                    } else if cur != nil {
                        Tiny(title: "이어서 쓰기 →\u{FE0E}", color: Theme.red) { router.shelfPath = [.notebook(id: articleId)] }
                    } else {
                        Tiny(title: "마지막 장 →\u{FE0E}") { router.shelfPath = [.done(id: articleId)] }
                    }
                } else if let cur {
                    if session.inSession { Tiny(title: "건너뛰기") { m.submit(skip: true) } }
                    Tiny(title: "제거") { toRemove = cur }
                    if m.redo != nil {
                        if m.pass == nil { Tiny(title: "취소") { m.cancelRedo() } }   // 다시 쓰기(pass) 중엔 그만두기 버튼이 없다 — 진행은 완주할 때만 지운다 (2026-11-24)
                        if m.pass != nil { Tiny(title: "이전 회차 열람") { router.shelfPath.append(.notebook(id: articleId, browse: true)) } }
                    }
                    // 합치기: 1회차는 아직 안 쓴 다음 문장과만, 다시 쓰기 진행 중에는 같은 문단의 앞/뒤와(합친 문장은 이번 회차에 다시 쓴다, goni 2026-11-16)
                    if m.redo == nil || m.pass != nil {
                        let ci = d.sentences.firstIndex { $0.id == cur.id } ?? -1
                        let prev = ci > 0 ? d.sentences[ci - 1] : nil
                        let next = ci >= 0 && ci + 1 < d.sentences.count ? d.sentences[ci + 1] : nil
                        if let prev, prev.paragraph == cur.paragraph { Tiny(title: "↑\u{FE0E} 앞에 붙이기") { Task { await m.merge(cur.id, dir: "prev") } } }
                        if let next, next.attempt == nil || m.pass != nil, next.paragraph == cur.paragraph { Tiny(title: "↓\u{FE0E} 뒤와 합치기") { Task { await m.merge(cur.id, dir: "next") } } }
                    }
                    if waiting > 0 { MutedText(text: m.inflight.values.contains { $0.pending } ? "채점 대기 \(waiting)개 · 연결되면 보낸다" : "채점 \(waiting)개 기다리는 중…") }
                } else if waiting > 0 {
                    MutedText(text: m.inflight.values.contains { $0.pending } ? "채점 대기 \(waiting)개 · 연결되면 보낸다" : "채점 \(waiting)개 기다리는 중…")
                } else {
                    // 다 썼다: 마지막 장은 직접 넘어간다(다시 쓰기 회차를 끝냈으면 거기서 새 총평을 받는다)
                    MutedText(text: "다 썼다")
                    Tiny(title: m.finishingPass ? "마지막 장 · 새 총평 받기 →\u{FE0E}" : "마지막 장 →\u{FE0E}", color: Theme.red) { router.shelfPath = [.done(id: articleId, newReview: m.finishingPass)] }
                }
            }
        }
        .frame(minHeight: Theme.lh)
        .padding(.top, Theme.lh)
        .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
    }
}

/// 시트로 열 표현 id (Identifiable 포장)
struct PhraseRef: Identifiable { var id: String }

/// "✂\u{FE0E} 여기까지 · 11/6 14:03–14:40 · 37분 · 12문장" 점선
struct SessionMark: View {
    var session: StudySession
    var compact = false     // 응용 탭 최근 응용 목록용: 공책 여백 없이, 조금 작게
    var onLog: (() -> Void)? = nil   // 있으면 줄 끝에 "기록 ↗"(기록 탭으로; 총평은 거기서) — 웹 70ff71a와 같음
    var body: some View {
        ZStack(alignment: .trailing) {
            Line().stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4])).foregroundStyle(Theme.red.opacity(0.55)).frame(height: 2)
            HStack(spacing: 8) {
                Text("✂\u{FE0E} 여기까지 · \(session.line)")
                    .font(Theme.hand(compact ? 17 : 19)).foregroundStyle(Theme.red).lineLimit(1).minimumScaleFactor(onLog == nil ? 1 : 0.7)   // "기록 ↗" 자리만큼 줄여 점수까지 한 줄에
                if let onLog { Tiny(title: "기록 ↗\u{FE0E}", size: compact ? 16 : 18, action: onLog) }
            }
            .padding(.horizontal, 8).background(Theme.paper)
        }
        .frame(height: compact ? 28 : Theme.lh)
        .padding(.leading, compact ? 0 : Theme.paperLeft).padding(.trailing, compact ? 0 : Theme.paperRight)
    }
}

/// 문장 행의 프레임(스크롤 좌표계) 수집
struct RowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
}

/// 읽는 위치 진행 줄: 채움 폭 = (idx+1)/전체, 문단 경계 눈금, 탭·드래그로 그 비율의 문장으로
struct ReadingProgressBar: View {
    var index: Int            // 화면 40% 지점에 걸린 문장 idx
    var total: Int
    var paragraphStarts: [Int] // 문단이 시작하는 문장 idx(첫 문단 제외)
    var onSeek: (Int) -> Void

    var body: some View {
        let ratio = total > 0 ? Double(index + 1) / Double(total) : 0
        VStack(alignment: .trailing, spacing: 2) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.ink.opacity(0.08))
                    Rectangle().fill(Theme.red.opacity(0.85)).frame(width: g.size.width * ratio)
                    ForEach(paragraphStarts, id: \.self) { p in
                        Rectangle().fill(Theme.ink.opacity(0.25)).frame(width: 1)
                            .offset(x: g.size.width * Double(p) / Double(max(total, 1)))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(v.location.x, g.size.width) }.onEnded { v in seek(v.location.x, g.size.width) })
            }
            .frame(height: 10)
            Text("\(index + 1) / \(total) · \(Int((ratio * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.pencil)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4)
        .background(.ultraThinMaterial.opacity(0.9))
        .accessibilityLabel("읽는 위치 \(index + 1) / \(total)")
    }
    private func seek(_ x: CGFloat, _ w: CGFloat) {
        guard total > 0, w > 0 else { return }
        onSeek(max(0, min(total - 1, Int((x / w) * CGFloat(total)))))
    }
}

/// 빗금 배경
struct Hatch: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY)); p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 8
        }
        return p.strokedPath(StrokeStyle(lineWidth: 1))
    }
}

struct Line: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p }
}
