import SwiftUI

struct Inflight: Hashable {
    var translation: String
    var attemptId: String
    var wasRedo: Bool          // 다시 쓰기 중이던 문장이면 멈출 때 그 자리로 돌아간다
    var error: String?
    var pending = false        // 오프라인: 큐에 있고 연결되면 채점된다 (대기 도장)
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

    /// 펼쳐 본 문장이 책갈피가 된다 ("마지막까지 본 곳"). 0.5초 디바운스, 이미 그 문장이면 생략
    private func scheduleAutoBookmark() {
        autoBookmarkTask?.cancel()
        guard let sid = open, bookmark?.sentenceId != sid else { return }
        autoBookmarkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.open == sid, self.bookmark?.sentenceId != sid else { return }
            let s = self.data?.sentences.first { $0.id == sid }
            self.bookmark = Bookmark(articleId: self.id, sentenceId: sid, round: self.roundShown, createdAt: Date().ms, articleTitle: self.data?.title, sentenceIdx: s?.idx, sentenceText: s?.text)
            Cache.shared.setBookmark(self.bookmark)
            await SyncManager.shared.setBookmark(articleId: self.id, sentenceId: sid, round: self.roundShown)
        }
    }
    @Published var lastGraded: String?
    @Published var err: String?
    @Published var scrollTo: String?     // 스크롤 목표 ("bottom" 또는 문장 id)
    @Published var focusRequest = 0      // 입력란에 포커스를 달라는 신호
    var browse: Bool { focusId != nil || browseAll }
    private var tasks: [String: Task<Void, Never>] = [:]   // 채점 요청. 멈추기 때 cancel
    private var stopped: Set<String> = []                   // 멈춘 attempt_id. 뒤늦은 오류를 무시한다

    private var observers: [NSObjectProtocol] = []

    init(id: String, focusId: String?, restartAfter: Int?, browseAll: Bool, round: Int?) {
        self.id = id; self.focusId = focusId; self.restartAfter = restartAfter; self.browseAll = browseAll; self.round = round
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

    func load(onDone: @escaping () -> Void) async {
        // 열람은 캐시를 먼저 그린다
        if browse, data == nil, let c = Cache.shared.article(id) {
            if let round, let r = Self.asOfRound(c, round) { data = r; roundShown = round } else { data = c }
            open = focusId
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
                open = focusId; if let focusId { requestScroll(focusId) }
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
            // 진행 상태: 서버가 진실. 서버가 null인데 로컬에만 있으면 한 번 올려 이관(오프라인이면 로컬 캐시 사용)
            var prog: RedoProgress? = nil
            if !offline {
                if let server = try? await API.shared.pass(id) {
                    prog = RedoProgress.from(serverDone: server.done, sentenceIds: ids); prog?.save(id)
                } else if let local = RedoProgress.load(id), Connectivity.shared.isOnline {
                    await SyncManager.shared.putPass(id, done: local.done); prog = local
                    AppLog.shared.info("notebook", "pass migrated to server", ["article": id])
                } else if Connectivity.shared.isOnline {
                    RedoProgress.clear(id)
                } else { prog = RedoProgress.load(id) }
            } else { prog = RedoProgress.load(id) }
            if let prog {
                let alive = prog.ids.filter(ids.contains)
                let p = RedoProgress(ids: alive, done: prog.done.filter(alive.contains))
                if p.remaining.isEmpty {
                    RedoProgress.clear(id); await SyncManager.shared.deletePass(id)
                    data = d; finishingPass = true; passSubmitted = Set(p.done); return
                }
                AppLog.shared.info("notebook", "resume pass", ["article": id, "done": "\(p.done.count)", "count": "\(p.ids.count)"])
                data = d; beginPass(p)
                return
            }
            mergePendingAttempts(d)
            if inflight.isEmpty, d.sentences.allSatisfy({ $0.attempt != nil }) { data = d; onDone(); return }
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

    /// 책갈피 꽂기/빼기 (서버에 하나). 회차 열람 중이면 round도
    func toggleBookmark(_ sid: String) async {
        if bookmark?.sentenceId == sid {
            bookmark = nil; Cache.shared.setBookmark(nil)
            await SyncManager.shared.clearBookmark()
            AppLog.shared.info("bookmark", "cleared")
        } else {
            let s = data?.sentences.first { $0.id == sid }
            bookmark = Bookmark(articleId: id, sentenceId: sid, round: roundShown, createdAt: Date().ms, articleTitle: data?.title, sentenceIdx: s?.idx, sentenceText: s?.text)
            Cache.shared.setBookmark(bookmark)
            await SyncManager.shared.setBookmark(articleId: id, sentenceId: sid, round: roundShown)
            AppLog.shared.info("bookmark", "set", ["sentence": sid, "round": "\(roundShown ?? 0)"])
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
        data = d
        inflight[sid] = nil
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
        inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing)
        tasks[sid] = Task {
            defer { tasks[sid] = nil }
            do { let r = try await API.shared.attempt(sid, translation: translation, attemptId: attemptId); if !stopped.contains(attemptId) { applyResult(sid, r) } }
            catch let e as APIError where e.isNetwork {
                // 보내는 중 끊김: 큐로 돌린다 (같은 attempt_id라 서버에 중복되지 않는다)
                if stopped.contains(attemptId) { return }
                queue(sid, translation, attemptId: attemptId, redoing: redoing)
            }
            catch {
                // 멈춘 요청의 오류(취소, 409 cancelled)는 보여주지 않는다
                if stopped.contains(attemptId) || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing, error: error.localizedDescription)
            }
        }
    }
    private func queue(_ sid: String, _ translation: String, attemptId: String, redoing: Bool) {
        SyncManager.shared.queueAttempt(attemptId: attemptId, sentenceId: sid, articleId: id, translation: translation)
        inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing, pending: true)
    }

    /// 멈추기: 요청 취소 → 서버에 DELETE → 그 문장을 다시 입력란으로, 쓰던 번역은 그대로
    func stop(_ sid: String) {
        guard let f = inflight[sid] else { return }
        stopped.insert(f.attemptId)
        tasks[sid]?.cancel(); tasks[sid] = nil
        inflight[sid] = nil
        AppLog.shared.info("notebook", "stop", ["sentence": sid, "attempt": f.attemptId])
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
            if i >= 0, i + 1 < pass.count {
                let next = pass[i + 1]
                let done = pass.filter(passSubmitted.contains)
                RedoProgress(ids: pass, done: done).save(id)
                Task { await SyncManager.shared.putPass(id, done: done) }
                redo = next; requestScroll(next); focusRequest += 1
            } else {
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

    func cancelRedo() {
        if pass != nil { RedoProgress.clear(id); Task { await SyncManager.shared.deletePass(id) } }
        redo = nil; pass = nil; passSubmitted = []; input = ""
    }
    var passLabel: String? {
        guard let pass, let redo, let i = pass.firstIndex(of: redo) else { return nil }
        return "다시 \(i + 1) / \(pass.count)"
    }

    func merge(_ sid: String, dir: String) async {
        do { try await SyncManager.shared.mergeSentence(sid, dir: dir); AppLog.shared.info("notebook", "merge \(dir)", ["sentence": sid]); await reload(); input = "" }
        catch { err = error.localizedDescription }
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

    func togglePhrase(_ sid: String, _ e: Expression) async {
        guard var d = data else { return }
        do {
            if let ex = d.phrases.first(where: { $0.sentenceId == sid && $0.phrase == e.phrase }) {
                try await SyncManager.shared.deletePhrase(id: ex.id); d.phrases.removeAll { $0.id == ex.id }
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
    /// 형광펜 내 메모 (Claude 없음, 오프라인 큐 가능)
    func memo(_ sid: String, start: Int, end: Int, span: String, note: String) async throws {
        if let r = try await SyncManager.shared.memo(sentenceId: sid, articleId: id, startWord: start, endWord: end, span: span, note: note) {
            data?.highlights.append(r.highlight)
            if let p = r.phrase, !(data?.phrases.contains { $0.id == p.id } ?? true) { data?.phrases.append(p) }
        } else if let h = Cache.shared.article(id)?.highlights.last(where: { $0.sentenceId == sid && $0.note == note }) {
            data?.highlights.append(h)
        }
    }
    func setNote(_ h: Highlight, _ note: String) async {
        if let i = data?.highlights.firstIndex(where: { $0.id == h.id }) { data?.highlights[i].note = note.isEmpty ? nil : note }
        await SyncManager.shared.setHighlightNote(h.id, note: note)
    }
    func deleteHighlight(_ h: Highlight) async {
        guard Connectivity.shared.isOnline else { err = onlineOnlyMessage; return }
        do { try await API.shared.deleteHighlight(h.id); data?.highlights.removeAll { $0.id == h.id }; Cache.shared.removeHighlight(id: h.id) }
        catch { err = error.localizedDescription }
    }

    /// 세션마다 이 공책에서 마지막으로 채점한 문장 뒤에 "여기까지" 줄
    func markers(_ sessions: [StudySession]) -> [String: StudySession] {
        guard let d = data else { return [:] }
        var m: [String: StudySession] = [:]
        for s in sessions {
            var best: Sentence?
            for x in d.sentences {
                guard let t = x.attempt?.createdAt, t >= s.startedAt, t <= s.endedAt else { continue }
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
    @ObservedObject private var session = SessionModel.shared
    @StateObject private var m: NotebookModel
    @FocusState private var focused: Bool
    @State private var toRemove: Sentence?
    @State private var readingIndex = 0          // 화면 40% 지점의 문장 idx
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var lastProgressTick = Date.distantPast

    init(articleId: String, focusId: String? = nil, restartAfter: Int? = nil, browseAll: Bool = false, round: Int? = nil) {
        self.articleId = articleId; self.focusId = focusId; self.restartAfter = restartAfter; self.browseAll = browseAll; self.round = round
        _m = StateObject(wrappedValue: NotebookModel(id: articleId, focusId: focusId, restartAfter: restartAfter, browseAll: browseAll, round: round))
    }

    var body: some View {
        ZStack {
            Theme.desk.ignoresSafeArea()
            if let d = m.data { content(d) }
            else if let e = m.err { ErrorText(message: e).padding() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.desk, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { Text(m.data?.title ?? "").font(Theme.hand(22)).lineLimit(1) }
        }
        .background {
            // 하드웨어 키보드 Esc: 다시 쓰기 취소, 아니면 마지막 채점 문장의 참고 번역 접기/펼치기 (웹과 동일)
            Button("") {
                if m.redo != nil { m.cancelRedo(); focused = true }
                else if let last = m.lastGraded { m.open = last; m.refOpen[last] = !(m.refOpen[last] ?? true) }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0).frame(width: 0, height: 0)
        }
        .task {
            await m.load { router.shelfPath = [.done(id: articleId)] }
            await m.loadBookmark()
            await session.load()
            if !m.browse { focused = true }
            #if DEBUG
            // 화면 확인용: LBN_AUTOREMOVE=<문장 id> 이면 그 문장을 빼서 되살리기 줄을 보여준다
            if let sid = ProcessInfo.processInfo.environment["LBN_AUTOREMOVE"], m.data?.sentences.contains(where: { $0.id == sid }) == true { _ = await m.remove(sid) }
            // 화면 확인용: LBN_AUTOSUBMIT=1 이면 현재 문장에 번역을 넣고 바로 제출한다 (채점 중 상태)
            if ProcessInfo.processInfo.environment["LBN_AUTOSUBMIT"] == "1", session.inSession, m.current != nil {
                m.input = "분석가들은 노동 시장이 더 약해지면 12월 15일까지 인하를 예상한다."; m.submit(skip: false)
            }
            #endif
        }
        .onChange(of: m.allDone) { _, _ in checkFinish() }
        .onChange(of: m.inflight.isEmpty) { _, _ in checkFinish() }
        .onChange(of: m.finishingPass) { _, _ in checkFinish() }
        .onChange(of: m.focusRequest) { _, _ in focused = true }
    }

    /// 화면 세로 40% 지점에 걸린 문장(없으면 가장 가까운 문장)의 idx
    private func updateReadingIndex(_ d: ArticleDetail) {
        let h = UIScreen.main.bounds.height
        let y = h * 0.4
        var best: (idx: Int, dist: CGFloat)? = nil
        for s in d.sentences {
            guard let f = rowFrames[s.id] else { continue }
            let dist: CGFloat = f.minY <= y && f.maxY >= y ? 0 : min(abs(f.minY - y), abs(f.maxY - y))
            if best == nil || dist < best!.dist { best = (s.idx, dist) }
            if dist == 0 { break }
        }
        if let b = best, b.idx != readingIndex { readingIndex = b.idx }
    }

    /// 모든 문장이 채점됐고 진행 중·오류 상태가 없으면 마지막 장으로.
    /// 처음부터 다시 쓰기를 마친 뒤라면 새 총평을 요청하게 한다 (채점이 전부 끝난 뒤라야 총평에 반영된다)
    private func checkFinish() {
        guard !m.browse, m.redo == nil, m.inflight.isEmpty, m.allDone else { return }
        router.shelfPath = [.done(id: articleId, newReview: m.finishingPass)]
    }

    private func content(_ d: ArticleDetail) -> some View {
        let total = d.sentences.count
        let doneCount = d.sentences.filter { $0.attempt != nil }.count
        let redoIdx = m.redo.flatMap { r in d.sentences.firstIndex { $0.id == r } }
        let upto = m.browse ? total : m.passMode ? (redoIdx.map { $0 + 1 } ?? total) : (m.frontIdx ?? total)
        let waiting = m.inflight.count
        let markers = m.passMode ? [:] : m.markers(session.sessions)
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
                            if let s = markers[x.id] { SessionMark(session: s) }
                            ForEach(m.removed.filter { $0.afterId == x.id }) { r in removedRow(r) }
                        }
                        if m.redo == nil, !m.browse, let cur = m.current {
                            if let f = m.frontIdx, f > 0, d.sentences[f - 1].paragraph != cur.paragraph { BlankLine() }
                            inputBlock(cur)
                        }
                        foot(d, waiting: waiting)
                        SessionBar(model: session, waiting: waiting, hideStart: true)
                            .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
                    }
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
        if m.redo == x.id {
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
                highlight: focusId == x.id,
                bookmarked: m.bookmark?.sentenceId == x.id,
                onBookmark: { Task { await m.toggleBookmark(x.id) } },
                highlights: d.highlights.filter { $0.sentenceId == x.id },
                onAsk: { st, en, sp in try await m.ask(x.id, start: st, end: en, span: sp) },
                onDeleteHighlight: { h in await m.deleteHighlight(h) },
                onMemo: { st, en, sp, n in try await m.memo(x.id, start: st, end: en, span: sp, note: n) },
                onNote: { h, n in await m.setNote(h, n) }
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
                    } else if cur != nil {
                        Tiny(title: "이어서 쓰기 →\u{FE0E}", color: Theme.red) { router.shelfPath = [.notebook(id: articleId)] }
                    } else {
                        Tiny(title: "마지막 장 →\u{FE0E}") { router.shelfPath = [.done(id: articleId)] }
                    }
                } else if let cur {
                    if session.inSession { Tiny(title: "건너뛰기") { m.submit(skip: true) } }
                    Tiny(title: "제거") { toRemove = cur }
                    if m.redo != nil {
                        Tiny(title: m.pass != nil ? "다시 쓰기 그만" : "취소") { m.cancelRedo() }
                        if m.pass != nil { Tiny(title: "이전 회차 열람") { router.shelfPath.append(.notebook(id: articleId, browse: true)) } }
                    } else {
                        let ci = d.sentences.firstIndex { $0.id == cur.id } ?? -1
                        let prev = ci > 0 ? d.sentences[ci - 1] : nil
                        let next = ci >= 0 && ci + 1 < d.sentences.count ? d.sentences[ci + 1] : nil
                        if let prev, prev.paragraph == cur.paragraph { Tiny(title: "↑\u{FE0E} 앞에 붙이기") { Task { await m.merge(cur.id, dir: "prev") } } }
                        if let next, next.attempt == nil, next.paragraph == cur.paragraph { Tiny(title: "↓\u{FE0E} 뒤와 합치기") { Task { await m.merge(cur.id, dir: "next") } } }
                    }
                    if waiting > 0 { MutedText(text: m.inflight.values.contains { $0.pending } ? "채점 대기 \(waiting)개 · 연결되면 보낸다" : "채점 \(waiting)개 기다리는 중…") }
                } else {
                    MutedText(text: waiting > 0 ? (m.inflight.values.contains { $0.pending } ? "채점 대기 \(waiting)개 · 연결되면 보낸다" : "채점 \(waiting)개 기다리는 중…") : "끝")
                }
            }
        }
        .frame(minHeight: Theme.lh)
        .padding(.top, Theme.lh)
        .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
    }
}

/// "✂\u{FE0E} 여기까지 · 11/6 14:03–14:40 · 37분 · 12문장" 점선
struct SessionMark: View {
    var session: StudySession
    var body: some View {
        ZStack(alignment: .trailing) {
            Line().stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4])).foregroundStyle(Theme.red.opacity(0.55)).frame(height: 2)
            Text("✂\u{FE0E} 여기까지 · \(session.line)")
                .font(Theme.hand(19)).foregroundStyle(Theme.red)
                .padding(.horizontal, 8).background(Theme.paper)
        }
        .frame(height: Theme.lh)
        .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
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
