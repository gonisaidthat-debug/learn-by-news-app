import Foundation
import Network
import Combine

/// 네트워크 연결 감시
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LBN_OFFLINE"] == "1" { isOnline = false; return }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let on = path.status == .satisfied
                if self?.isOnline != on { AppLog.shared.info("net", on ? "online" : "offline") }
                self?.isOnline = on
                if on { await SyncManager.shared.flushQueue() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "lbn.net"))
    }
}

extension Notification.Name {
    /// 오프라인 큐의 채점이 서버에서 돌아왔다. userInfo: attemptId, sentenceId, result(AttemptResult)
    static let lbnAttemptGraded = Notification.Name("lbn.attemptGraded")
    /// 임시 공책 id가 서버 id로 바뀌었다. userInfo: from, to
    static let lbnArticleRenamed = Notification.Name("lbn.articleRenamed")
    /// 오프라인에서 쓴 응용 답이 채점돼 돌아왔다. userInfo: drill(Drill)
    static let lbnDrillGraded = Notification.Name("lbn.drillGraded")
    /// 오프라인에서 닫은 세션이 서버에 기록됐다(총평 포함). userInfo: session(StudySession), startedAt
    static let lbnSessionClosed = Notification.Name("lbn.sessionClosed")
}

/// 오프라인 캐시 동기화 (GET /api/export) + 오프라인 큐 전송
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncAt: Int64? = Cache.shared.exportedAt
    @Published private(set) var pendingCount = Cache.shared.pendingCount
    @Published private(set) var pendingAttempts = Cache.shared.pendingUnclaimed(kind: "attempt").count
    private var flushing = false
    /// 진행 중인 큐 전송이 끝날 때까지 기다린 뒤, 남은 것도 보낸다(세션 닫기 전에 채점 대기분을 먼저 보내려고)
    func flushAndWait() async {
        while flushing { try? await Task.sleep(nanoseconds: 300_000_000) }
        await flushQueue()
    }

    /// 오프라인에서 만든 임시 id → 서버 id (공책·문장). 전송 도중 끊겨도 이어지도록 UserDefaults에
    private var idMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "lbn_idmap") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "lbn_idmap") }
    }
    func real(_ id: String) -> String { idMap[id] ?? id }
    static func isTemp(_ id: String) -> Bool { id.hasPrefix("local-") }

    private init() {}

    /// 앱 시작·포그라운드 복귀·연결 복구: 큐를 먼저 보내고(서버가 진실) 증분 동기화. 하루 한 번 또는 삭제 뒤엔 전체
    func autoSync() async {
        guard Connectivity.shared.isOnline, (API.token ?? Keychain.get()) != nil else { return }
        await flushQueue()
        let c = Cache.shared
        let dayAgo = Date().ms - 86_400_000
        let full = c.exportedAt == nil || c.needsFull || (c.lastFullAt ?? 0) < dayAgo
        await sync(full: full)
    }

    private func refreshCounts() { pendingCount = Cache.shared.pendingCount; pendingAttempts = Cache.shared.pendingUnclaimed(kind: "attempt").count }

    /// full: 전체 받아 교체. 아니면 ?since=exported_at 증분
    func sync(full: Bool) async {
        guard !syncing else { return }
        syncing = true; lastError = nil
        defer { syncing = false }
        do {
            let since = full ? nil : Cache.shared.exportedAt
            let x = try await API.shared.export(since: since)
            try Cache.shared.apply(x, full: full || since == nil)
            lastSyncAt = x.exportedAt
        } catch {
            lastError = error.localizedDescription
            AppLog.shared.warn("sync", "failed: \(error.localizedDescription)", ["full": "\(full)"])
        }
    }

    /// 오프라인 큐를 넣은 순서대로 보낸다(attempt들 → session_close 순이 지켜진다). 네트워크 오류면 멈추고 다음 기회에, 서버 오류(4xx/5xx)면 그 항목은 버린다
    func flushQueue() async {
        guard !flushing, Connectivity.shared.isOnline else { return }
        flushing = true
        var sentAttempts = false
        defer { flushing = false; refreshCounts() }
        for op in Cache.shared.pending() where !op.isClaimed {   // 직접 보내는 중인 항목은 건너뛴다(겹쳐 보내지 않는다)
            do {
                switch op.kind {
                case "article_create":
                    let b = try JSONDecoder.api.decode(ArticleCreateOp.self, from: op.payload)
                    let newId = try await API.shared.createArticle(title: b.title, sentences: b.sentences.map { SplitSentence(paragraph: $0.paragraph, text: $0.text) }, source: b.source)
                    let d = try await API.shared.article(newId)
                    var map = idMap; map[b.tempId] = newId
                    for (t, r) in Cache.shared.renameArticle(from: b.tempId, to: d) { map[t] = r }
                    idMap = map
                    NotificationCenter.default.post(name: .lbnArticleRenamed, object: nil, userInfo: ["from": b.tempId, "to": newId])
                case "attempt":
                    let b = try JSONDecoder.api.decode(AttemptOp.self, from: op.payload)
                    let sid = real(b.sentenceId)
                    let r = try await API.shared.attempt(sid, translation: b.skip ? "" : b.translation, attemptId: b.attemptId, writtenAt: b.createdAt)   // 쓴 시각이 created_at이 돼야 세션 범위·기록 날짜가 맞는다
                    for p in r.phrases { Cache.shared.upsertPhrase(p) }
                    sentAttempts = true
                    NotificationCenter.default.post(name: .lbnAttemptGraded, object: nil, userInfo: ["attemptId": b.attemptId, "sentenceId": b.sentenceId, "result": r])
                case "attempt_cancel":
                    let b = try JSONDecoder.api.decode(AttemptOp.self, from: op.payload)
                    _ = try await API.shared.cancelAttempt(b.attemptId)
                case "attempt_void":
                    let b = try JSONDecoder.api.decode(VoidOp.self, from: op.payload)
                    try await API.shared.voidAttempt(b.attemptId, void: b.void)
                case "sentence_merge":
                    let b = try JSONDecoder.api.decode(SentenceOp.self, from: op.payload)
                    _ = try await API.shared.merge(real(b.sentenceId), dir: b.dir ?? "prev")
                    Cache.shared.needsFull = true
                case "sentence_delete":
                    let b = try JSONDecoder.api.decode(SentenceOp.self, from: op.payload)
                    try await API.shared.deleteSentence(real(b.sentenceId))
                    Cache.shared.needsFull = true
                case "article_source":
                    let b = try JSONDecoder.api.decode(ArticlePatchOp.self, from: op.payload)
                    try await API.shared.setSource(real(b.articleId), b.source ?? "")
                case "article_delete":
                    let b = try JSONDecoder.api.decode(ArticlePatchOp.self, from: op.payload)
                    try await API.shared.deleteArticle(real(b.articleId))
                    Cache.shared.needsFull = true
                case "bookmark_put":
                    let b = try JSONDecoder.api.decode(BookmarkOp.self, from: op.payload)
                    try await API.shared.setBookmark(articleId: real(b.articleId), sentenceId: real(b.sentenceId), round: b.round)
                case "bookmark_delete":
                    try await API.shared.clearBookmark()
                case "memo":
                    let b = try JSONDecoder.api.decode(MemoOp.self, from: op.payload)
                    let r = try await API.shared.memo(real(b.sentenceId), startWord: b.startWord, endWord: b.endWord, span: b.span, note: b.note, links: (b.links ?? []).map { LinkTarget(toKind: $0.toKind, toId: real($0.toId)) })
                    Cache.shared.removeHighlight(id: b.tempId); Cache.shared.upsertHighlight(r.highlight)
                    if let p = r.phrase { Cache.shared.upsertPhrase(p) }
                    var map = idMap; map[b.tempId] = r.highlight.id; idMap = map
                case "link_add":
                    let b = try JSONDecoder.api.decode(LinkOp.self, from: op.payload)
                    let target = LinkTarget(toKind: b.toKind ?? "", toId: real(b.toId ?? ""))
                    if b.fromKind == "phrase" { _ = try await API.shared.addPhraseLink(real(b.highlightId), to: target) }
                    else { _ = try await API.shared.addLink(real(b.highlightId), to: target) }
                case "link_delete":
                    let b = try JSONDecoder.api.decode(LinkOp.self, from: op.payload)
                    if !Self.isTemp(b.linkId ?? "") { try await API.shared.deleteLink(b.linkId ?? "") }
                case "highlight_note":
                    let b = try JSONDecoder.api.decode(NoteOp.self, from: op.payload)
                    try await API.shared.setHighlightNote(real(b.highlightId), note: b.note)
                case "drill_free":
                    let b = try JSONDecoder.api.decode(API.DrillFreeBody.self, from: op.payload)
                    let d = try await API.shared.freeDrill(b)
                    DrillStore.shared.didGrade(d)
                    NotificationCenter.default.post(name: .lbnDrillGraded, object: nil, userInfo: ["drill": d])
                case "drill_answer":
                    let b = try JSONDecoder.api.decode(DrillAnswerOp.self, from: op.payload)
                    let d = try await API.shared.answerDrill(b.id, answer: b.answer, answeredAt: b.answeredAtLocal)
                    DrillStore.shared.didGrade(d)
                    NotificationCenter.default.post(name: .lbnDrillGraded, object: nil, userInfo: ["drill": d])
                case "drill_grading_cancel":
                    let b = try JSONDecoder.api.decode(DrillCancelOp.self, from: op.payload)
                    _ = try await API.shared.cancelDrillGrading(b.id)
                case "quiz_result":
                    let b = try JSONDecoder.api.decode(API.QuizResultBody.self, from: op.payload)
                    let _: API.OK = try await API.shared.send("POST", "/api/quiz/results", body: b)
                case "phrase_save":
                    let b = try JSONDecoder.api.decode(PhraseSaveOp.self, from: op.payload)
                    let p = try await API.shared.savePhrase(Expression(phrase: b.phrase, meaning: b.meaning), sentenceId: b.sentenceId, articleId: b.articleId)
                    Cache.shared.renamePhrase(from: b.tempId, to: p)
                case "phrase_delete":
                    let b = try JSONDecoder.api.decode(PhraseDeleteOp.self, from: op.payload)
                    try await API.shared.deletePhrase(b.id)
                case "phrase_mastered":
                    let b = try JSONDecoder.api.decode(PhraseMasteredOp.self, from: op.payload)
                    _ = try await API.shared.setMastered(b.id, on: b.on)
                case "pass_put":
                    let b = try JSONDecoder.api.decode(PassOp.self, from: op.payload)
                    try await API.shared.putPass(b.articleId, done: b.done ?? [])
                case "pass_delete":
                    let b = try JSONDecoder.api.decode(PassOp.self, from: op.payload)
                    try await API.shared.deletePass(b.articleId)
                case "session_start_put":
                    let b = try JSONDecoder.api.decode(SessionStartState.self, from: op.payload)
                    try await API.shared.putSessionStart(b.startedAt)
                case "session_start_delete":
                    try await API.shared.deleteSessionStart()
                case "session_close":
                    let b = try JSONDecoder.api.decode(SessionStartState.self, from: op.payload)
                    let s = try await API.shared.closeSession(startedAt: b.startedAt)
                    Cache.shared.replaceLocalSession(startedAt: b.startedAt, with: s)
                    NotificationCenter.default.post(name: .lbnSessionClosed, object: nil, userInfo: ["session": s, "startedAt": b.startedAt])
                default: break
                }
                Cache.shared.remove(op)
                AppLog.shared.info("queue", "sent \(op.kind)")
            } catch let e as APIError where e.isNetwork {
                AppLog.shared.info("queue", "paused (offline)")
                return
            } catch {
                AppLog.shared.error("queue", "dropped \(op.kind): \(error.localizedDescription)")
                if op.kind == "drill_answer", let b = try? JSONDecoder.api.decode(DrillAnswerOp.self, from: op.payload) { DrillStore.shared.dropPending(b.id) }
                if op.kind == "session_start_put", case APIError.server = error { SessionModel.shared.serverRejectedStart(error.localizedDescription) }  // 400 거절: 재시도 금지, 로컬 시작점도 지운다 (다른 오류는 로컬 유지)
                if op.kind == "attempt", let b = try? JSONDecoder.api.decode(AttemptOp.self, from: op.payload) {
                    NotificationCenter.default.post(name: .lbnAttemptGraded, object: nil, userInfo: ["attemptId": b.attemptId, "sentenceId": b.sentenceId, "error": error.localizedDescription])
                }
                Cache.shared.remove(op)
            }
        }
        // 채점이 서버에 들어갔으면 증분으로 받아 캐시(attempts)에 반영한다
        if sentAttempts { await sync(full: false) }
    }

    struct PhraseSaveOp: Codable { var tempId: String; var phrase: String; var meaning: String; var sentenceId: String; var articleId: String }
    struct PassOp: Codable { var articleId: String; var done: [String]? }
    struct VoidOp: Codable { var attemptId: String; var void: Bool }
    struct ArticleCreateOp: Codable {
        struct S: Codable { var paragraph: Int; var text: String }
        var tempId: String; var title: String; var source: String; var sentences: [S]
    }
    struct AttemptOp: Codable { var attemptId: String; var sentenceId: String; var articleId: String; var translation: String; var skip: Bool; var createdAt: Int64 }
    struct SentenceOp: Codable { var sentenceId: String; var dir: String? }
    struct ArticlePatchOp: Codable { var articleId: String; var source: String? }
    struct BookmarkOp: Codable { var articleId: String; var sentenceId: String; var round: Int? }
    struct DrillAnswerOp: Codable { var id: String; var answer: String; var answeredAtLocal: Int64; var phrase: String?; var korean: String? }
    struct MemoOp: Codable { var tempId: String; var sentenceId: String; var articleId: String; var startWord: Int; var endWord: Int; var span: String; var note: String; var links: [LinkTarget]? }
    /// highlightId = 출발점 id(형광펜 또는 표현). fromKind nil이면 형광펜(예전 큐 항목)
    struct LinkOp: Codable { var highlightId: String; var toKind: String?; var toId: String?; var linkId: String?; var fromKind: String? }

    /// 엮기: 온라인이면 서버, 아니면 임시 id 링크 + 큐. 출발점은 형광펜(from "highlight") 또는 붙여 둔 표현(from "phrase", 2026-11-18)
    func addLink(_ highlightId: String, to: LinkTarget, candidate: Related?) async throws -> HighlightLink {
        try await addLink(from: "highlight", id: highlightId, to: to, candidate: candidate)
    }
    func addLink(from kind: String, id fromId: String, to: LinkTarget, candidate: Related?) async throws -> HighlightLink {
        if Connectivity.shared.isOnline, !Self.isTemp(fromId), !Self.isTemp(to.toId) {
            do { return kind == "phrase" ? try await API.shared.addPhraseLink(fromId, to: to) : try await API.shared.addLink(fromId, to: to) }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        Cache.shared.enqueue("link_add", LinkOp(highlightId: fromId, toKind: to.toKind, toId: to.toId, linkId: nil, fromKind: kind)); refreshCounts()
        return HighlightLink(id: "local-" + UUID().uuidString.lowercased(), fromKind: kind, fromHighlight: fromId, toKind: to.toKind, toId: to.toId, createdAt: Date().ms,
                             text: candidate?.text, sentenceId: candidate?.sentenceId, articleId: candidate?.articleId, title: candidate?.title)
    }
    func deleteLink(_ link: HighlightLink, from highlightId: String) async {
        if Self.isTemp(link.id) {
            // 아직 안 보낸 엮기면 큐에서 빼면 끝
            for op in Cache.shared.pending(kind: "link_add") {
                if let b = try? JSONDecoder.api.decode(LinkOp.self, from: op.payload), b.highlightId == highlightId, b.toId == link.toId, b.toKind == link.toKind { Cache.shared.remove(op) }
            }
            refreshCounts(); return
        }
        await sendOrQueue("link_delete", LinkOp(highlightId: highlightId, toKind: nil, toId: nil, linkId: link.id)) { try await API.shared.deleteLink(link.id) }
    }

    /// 엮을 후보. 온라인이면 서버, 아니면 캐시된 형광펜·표현을 어근으로 비교
    func related(span: String?, q: String?, excludeSentence: String?, exclude: String?) async -> [Related] {
        if Connectivity.shared.isOnline {
            if let r = try? await API.shared.related(span: span, q: q, excludeSentence: excludeSentence, exclude: exclude) { return r }
        }
        return Cache.shared.related(span: span, q: q, excludeSentence: excludeSentence, exclude: exclude)
    }
    struct NoteOp: Codable { var highlightId: String; var note: String }

    /// 자유 작문: 온라인이면 바로 채점, 아니면 큐(drill_free) → nil("연결되면 채점"). 큐 항목에 drillId가 들어 있어 재전송이 중복 저장되지 않는다
    func freeDrill(_ b: API.DrillFreeBody) async throws -> Drill? {
        guard Connectivity.shared.isOnline else { Cache.shared.enqueue("drill_free", b); refreshCounts(); return nil }
        // 보내기 전에 큐(디스크)에 먼저 (goni 2026-11-18): 앱이 정지 중 죽어도 다음 실행 때 보내진다. 같은 drill_id라 서버에 있으면 duplicate로 받는다
        let opId = Cache.shared.enqueue("drill_free", b, claimed: true).id; refreshCounts()
        do { let d = try await API.shared.freeDrill(b); finishDirect(opId: opId); return d }
        catch let e as APIError where e.isNetwork {
            if Task.isCancelled { finishDirect(opId: opId); throw CancellationError() }   // 멈추기로 끊긴 요청은 큐에 남기지 않는다
            releaseDirect(opId: opId); return nil   // 끊김: 큐가 보낸다 → "연결되면 채점"
        }
        catch { finishDirect(opId: opId); throw error }   // 서버 거절: 큐에서 빼고 오류
    }
    /// 출제형 응용 답(응용 탭·써 보기 상자 공용): 오프라인이면 큐 drill_answer → nil("연결되면 채점"). 온라인이면 큐에 먼저 넣고 바로 보낸다
    func answerDrill(_ d: Drill, answer: String) async throws -> Drill? {
        guard Connectivity.shared.isOnline else { DrillStore.shared.answerOffline(d, answer: answer); refreshCounts(); return nil }
        let opId = Cache.shared.enqueue("drill_answer", DrillAnswerOp(id: d.id, answer: answer, answeredAtLocal: Date().ms, phrase: d.phrase, korean: d.korean), claimed: true).id; refreshCounts()
        do { let r = try await API.shared.answerDrill(d.id, answer: answer); finishDirect(opId: opId); return r }
        catch let e as APIError where e.isNetwork {
            if Task.isCancelled { finishDirect(opId: opId); throw CancellationError() }
            releaseDirect(opId: opId); DrillStore.shared.markPending(d.id, answer: answer); return nil
        }
        catch { finishDirect(opId: opId); throw error }
    }
    struct DrillCancelOp: Codable { var id: String }
    /// 응용 채점 멈추기: 큐에 있으면(자유 작문 drill_free·출제형 drill_answer) 빼고 끝. 이미 보냈으면 서버에 DELETE grading(오프라인이면 그것도 큐)
    func stopDrillGrading(id: String) async {
        var sent = false
        for op in Cache.shared.pending(kind: "drill_free") {
            if let b = try? JSONDecoder.api.decode(API.DrillFreeBody.self, from: op.payload), b.drillId == id { sent = op.isClaimed; Cache.shared.remove(op); refreshCounts(); if !sent { return } }
        }
        for op in Cache.shared.pending(kind: "drill_answer") {
            if let b = try? JSONDecoder.api.decode(DrillAnswerOp.self, from: op.payload), b.id == id { sent = op.isClaimed; Cache.shared.remove(op); DrillStore.shared.dropPending(id); refreshCounts(); if !sent { return } }
        }
        await sendOrQueue("drill_grading_cancel", DrillCancelOp(id: id)) {
            _ = try await API.shared.cancelDrillGrading(id)
        }
    }

    /// 형광펜 내 메모 (Claude 없음): 온라인이면 서버, 아니면 임시 id로 캐시 + 큐
    func memo(sentenceId: String, articleId: String, startWord: Int, endWord: Int, span: String, note: String, links: [LinkTarget] = []) async throws -> AskResult? {
        if Connectivity.shared.isOnline, !Self.isTemp(sentenceId) {
            do { let r = try await API.shared.memo(sentenceId, startWord: startWord, endWord: endWord, span: span, note: note, links: links); Cache.shared.upsertHighlight(r.highlight); if let p = r.phrase { Cache.shared.upsertPhrase(p) }; return r }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        let temp = "local-" + UUID().uuidString.lowercased()
        let h = Highlight(id: temp, sentenceId: sentenceId, articleId: articleId, startWord: startWord, endWord: endWord, span: span, answer: HighlightAnswer(meaning: "", why: "", similar: ""), createdAt: Date().ms, note: note)
        Cache.shared.upsertHighlight(h)
        Cache.shared.enqueue("memo", MemoOp(tempId: temp, sentenceId: sentenceId, articleId: articleId, startWord: startWord, endWord: endWord, span: span, note: note, links: links.isEmpty ? nil : links)); refreshCounts()
        return nil
    }
    func setHighlightNote(_ id: String, note: String) async {
        Cache.shared.setHighlightNote(id: id, note: note.isEmpty ? nil : note)
        await sendOrQueue("highlight_note", NoteOp(highlightId: id, note: note)) {
            guard !Self.isTemp(id) else { throw APIError.network("temp") }
            try await API.shared.setHighlightNote(id, note: note)
        }
    }

    // MARK: 핵심 루프의 오프라인 겸용 동작

    /// 번역 제출을 큐에 (오프라인이거나 전송이 네트워크 오류로 실패했을 때). 화면은 "채점 대기" 도장으로
    /// claimed: 제출 즉시 큐에 넣고 바로 보내는 경우(응답이 오면 Cache.removePending, 끊기면 releasePending). 돌려주는 값은 큐 항목 id
    @discardableResult
    func queueAttempt(attemptId: String, sentenceId: String, articleId: String, translation: String, claimed: Bool = false) -> String {
        let op = Cache.shared.enqueue("attempt", AttemptOp(attemptId: attemptId, sentenceId: sentenceId, articleId: articleId, translation: translation, skip: translation.isEmpty, createdAt: Date().ms), claimed: claimed)
        refreshCounts()
        return op.id
    }
    func finishDirect(opId: String) { Cache.shared.removePending(id: opId); refreshCounts() }
    func releaseDirect(opId: String) { Cache.shared.releasePending(id: opId); refreshCounts() }
    /// 이 공책에서 아직 못 보낸 채점들
    func pendingAttempts(for articleId: String) -> [AttemptOp] {
        Cache.shared.pending(kind: "attempt").compactMap { try? JSONDecoder.api.decode(AttemptOp.self, from: $0.payload) }.filter { $0.articleId == articleId }
    }
    /// 멈추기: 큐에 있으면 빼고 끝. 이미 보냈으면 서버에 취소(오프라인이면 그것도 큐)
    func stopAttempt(attemptId: String, sentenceId: String, articleId: String) async {
        for op in Cache.shared.pending(kind: "attempt") {
            if let b = try? JSONDecoder.api.decode(AttemptOp.self, from: op.payload), b.attemptId == attemptId {
                let sent = op.isClaimed   // 직접 보내는 중이었으면 서버에도 취소를 보내야 한다
                Cache.shared.remove(op); refreshCounts()
                if !sent { return }
                break
            }
        }
        await sendOrQueue("attempt_cancel", AttemptOp(attemptId: attemptId, sentenceId: sentenceId, articleId: articleId, translation: "", skip: false, createdAt: Date().ms)) {
            _ = try await API.shared.cancelAttempt(attemptId)
        }
    }
    /// 새 공책: 온라인이면 서버, 아니면 임시 id로 캐시에 만들고 큐에
    func createArticle(title: String, sentences: [SplitSentence], source: String) async throws -> String {
        if Connectivity.shared.isOnline {
            do { return try await API.shared.createArticle(title: title, sentences: sentences, source: source) }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        let temp = "local-" + UUID().uuidString.lowercased()
        Cache.shared.insertArticle(id: temp, title: title, source: source, sentences: sentences)
        Cache.shared.enqueue("article_create", ArticleCreateOp(tempId: temp, title: title, source: source, sentences: sentences.map { .init(paragraph: $0.paragraph, text: $0.text) }))
        refreshCounts()
        return temp
    }
    /// 합치기. 남은(kept) 문장 id를 돌려준다. 서버는 붙는 쪽의 채점·표현·형광펜을 kept로 옮긴다
    @discardableResult
    func mergeSentence(_ sid: String, dir: String) async throws -> String? {
        if Connectivity.shared.isOnline, !Self.isTemp(sid) {
            do { let r = try await API.shared.merge(sid, dir: dir); Cache.shared.needsFull = true; return r.kept }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        let kept = Cache.shared.mergeLocal(sid, dir: dir)
        Cache.shared.enqueue("sentence_merge", SentenceOp(sentenceId: sid, dir: dir)); refreshCounts()
        return kept
    }
    /// 문장 제거. 온라인이면 서버 휴지통 id를 돌려주고, 오프라인이면 큐에 넣고 nil
    func deleteSentence(_ sid: String) async throws -> String? {
        if Connectivity.shared.isOnline, !Self.isTemp(sid) {
            do { let t = try await API.shared.deleteSentence(sid); Cache.shared.needsFull = true; return t }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        Cache.shared.deleteSentenceLocal(sid)
        Cache.shared.enqueue("sentence_delete", SentenceOp(sentenceId: sid, dir: nil)); refreshCounts()
        return nil
    }
    /// 큐에 있는 삭제를 취소하고 캐시를 되돌린다. 큐에 없으면(이미 보냄) false
    func undoQueuedDelete(_ s: Sentence, articleId: String) -> Bool {
        for op in Cache.shared.pending(kind: "sentence_delete") {
            if let b = try? JSONDecoder.api.decode(SentenceOp.self, from: op.payload), b.sentenceId == s.id {
                Cache.shared.remove(op); Cache.shared.restoreSentenceLocal(s, articleId: articleId); refreshCounts(); return true
            }
        }
        return false
    }
    func setSource(_ articleId: String, _ source: String) async throws {
        Cache.shared.setSourceLocal(articleId, source)
        if Connectivity.shared.isOnline, !Self.isTemp(articleId) {
            do { try await API.shared.setSource(articleId, source); return }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        Cache.shared.enqueue("article_source", ArticlePatchOp(articleId: articleId, source: source)); refreshCounts()
    }
    func deleteArticle(_ articleId: String) async throws {
        Cache.shared.deleteArticleLocal(articleId)
        if Self.isTemp(articleId) {
            // 아직 안 보낸 공책이면 만들기 큐와 그 공책의 큐를 지우면 끝
            for op in Cache.shared.pending() {
                if op.kind == "article_create", let b = try? JSONDecoder.api.decode(ArticleCreateOp.self, from: op.payload), b.tempId == articleId { Cache.shared.remove(op) }
                if op.kind == "attempt", let b = try? JSONDecoder.api.decode(AttemptOp.self, from: op.payload), b.articleId == articleId { Cache.shared.remove(op) }
            }
            refreshCounts(); return
        }
        if Connectivity.shared.isOnline {
            do { try await API.shared.deleteArticle(articleId); Cache.shared.needsFull = true; return }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        Cache.shared.enqueue("article_delete", ArticlePatchOp(articleId: articleId, source: nil)); refreshCounts()
    }
    func setBookmark(articleId: String, sentenceId: String, round: Int?) async {
        await sendOrQueue("bookmark_put", BookmarkOp(articleId: articleId, sentenceId: sentenceId, round: round)) {
            guard !Self.isTemp(sentenceId) else { throw APIError.network("temp") }
            try await API.shared.setBookmark(articleId: articleId, sentenceId: sentenceId, round: round)
        }
    }
    func clearBookmark() async {
        await sendOrQueue("bookmark_delete", BookmarkOp(articleId: "", sentenceId: "", round: nil)) { try await API.shared.clearBookmark() }
    }

    /// 온라인이면 바로, 아니면(또는 네트워크 실패면) 큐에
    private func sendOrQueue(_ kind: String, _ payload: some Encodable, _ send: () async throws -> Void) async {
        if Connectivity.shared.isOnline {
            do { try await send(); return }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
            catch { AppLog.shared.warn("sync", "\(kind) failed: \(error.localizedDescription)"); return }
        }
        Cache.shared.enqueue(kind, payload); refreshCounts()
    }

    /// "잘못 눌렀다"(void) / 되살리기. 캐시에 먼저 반영하고 온라인이면 바로, 아니면 큐 attempt_void. 서버가 거절(400: 가장 최근 시도만)하면 캐시를 되돌리고 던진다
    func voidAttempt(_ attemptId: String, void: Bool) async throws {
        Cache.shared.setAttemptVoid(attemptId, void)
        if Connectivity.shared.isOnline {
            do { try await API.shared.voidAttempt(attemptId, void: void); return }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
            catch { Cache.shared.setAttemptVoid(attemptId, !void); throw error }
        }
        Cache.shared.enqueue("attempt_void", VoidOp(attemptId: attemptId, void: void)); refreshCounts()
    }

    // MARK: 다시 쓰기 진행 (서버가 진실, RedoProgress는 캐시)
    func putPass(_ articleId: String, done: [String]) async {
        await sendOrQueue("pass_put", PassOp(articleId: articleId, done: done)) { try await API.shared.putPass(articleId, done: done) }
    }
    func deletePass(_ articleId: String) async {
        await sendOrQueue("pass_delete", PassOp(articleId: articleId, done: nil)) { try await API.shared.deletePass(articleId) }
    }
    // MARK: 공부 시작점
    func putSessionStart(_ t: Int64) async {
        if Connectivity.shared.isOnline {
            do { try await API.shared.putSessionStart(t); return }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
            catch {
                // 400(서버 거절)일 때만 로컬 시작점을 지운다. 디코드 오류 등은 서버에 들어갔을 수 있으니 로컬은 둔다
                if case APIError.server = error { SessionModel.shared.serverRejectedStart(error.localizedDescription) }
                else { AppLog.shared.warn("sync", "session_start_put failed, keeping local: \(error.localizedDescription)") }
                return
            }
        }
        Cache.shared.enqueue("session_start_put", SessionStartState(startedAt: t)); refreshCounts()
    }
    func deleteSessionStart() async {
        await sendOrQueue("session_start_delete", SessionStartState(startedAt: 0)) { try await API.shared.deleteSessionStart() }
    }
    struct PhraseDeleteOp: Codable { var id: String }
    struct PhraseMasteredOp: Codable { var id: String; var on: Bool }
    /// 습득 완료 도장 찍기/떼기: 캐시에 먼저 반영하고 온라인이면 바로, 아니면 큐 phrase_mastered. 서버가 돌려준 mastered_at을 쓴다(없으면 지금 시각)
    func setMastered(_ id: String, on: Bool) async throws -> Int64? {
        guard !Self.isTemp(id) else { throw APIError.server("아직 서버에 붙지 않은 표현이다 · 연결되면 다시") }
        let local: Int64? = on ? Date().ms : nil
        Cache.shared.setPhraseMastered(id: id, at: local)
        if Connectivity.shared.isOnline {
            do { let r = try await API.shared.setMastered(id, on: on); Cache.shared.setPhraseMastered(id: id, at: r.masteredAt); return r.masteredAt }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
            catch { Cache.shared.setPhraseMastered(id: id, at: on ? nil : Date().ms); throw error }   // 서버 거절(404 등): 되돌린다
        }
        Cache.shared.enqueue("phrase_mastered", PhraseMasteredOp(id: id, on: on)); refreshCounts()
        return local
    }

    // MARK: 화면이 쓰는 오프라인 겸용 동작

    /// 시험 결과: 온라인이면 바로, 아니면 큐 (캐시에도 남겨 다음 순서 계산에 반영)
    func answerQuiz(_ it: QuizItem, correct: Bool) async throws {
        Cache.shared.addQuizResult(key: it.key, sentenceId: it.sentenceId, source: it.source, correct: correct)
        if Connectivity.shared.isOnline {
            do { try await API.shared.answerQuiz(it, correct: correct); return }
            catch let e as APIError where e.isNetwork { /* 아래 큐로 */ }
        }
        Cache.shared.enqueue("quiz_result", API.QuizResultBody(key: it.key, sentenceId: it.sentenceId, source: it.source, correct: correct))
        pendingCount = Cache.shared.pendingCount
    }

    /// 포스트잇 붙이기: 온라인이면 바로 서버 Phrase, 아니면 임시 id로 큐
    func savePhrase(_ e: Expression, sentenceId: String, articleId: String, articleTitle: String?, sentenceText: String?) async throws -> Phrase {
        if Connectivity.shared.isOnline {
            do { let p = try await API.shared.savePhrase(e, sentenceId: sentenceId, articleId: articleId); Cache.shared.upsertPhrase(p); return p }
            catch let err as APIError where err.isNetwork { /* 아래 큐로 */ }
        }
        let temp = Phrase(id: "local-" + UUID().uuidString, phrase: e.phrase, meaning: e.meaning, sentenceId: sentenceId, articleId: articleId, createdAt: Date().ms, sentenceText: sentenceText, articleTitle: articleTitle)
        Cache.shared.upsertPhrase(temp)
        Cache.shared.enqueue("phrase_save", PhraseSaveOp(tempId: temp.id, phrase: e.phrase, meaning: e.meaning, sentenceId: sentenceId, articleId: articleId))
        pendingCount = Cache.shared.pendingCount
        return temp
    }

    /// 포스트잇 떼기: 임시 id면 큐의 저장만 취소, 아니면 서버 삭제(오프라인이면 큐)
    func deletePhrase(id: String) async throws {
        Cache.shared.removePhrase(id: id)
        if id.hasPrefix("local-") {
            for op in Cache.shared.pending() where op.kind == "phrase_save" {
                if let b = try? JSONDecoder.api.decode(PhraseSaveOp.self, from: op.payload), b.tempId == id { Cache.shared.remove(op) }
            }
            pendingCount = Cache.shared.pendingCount
            return
        }
        if Connectivity.shared.isOnline {
            do { try await API.shared.deletePhrase(id); return }
            catch let e as APIError where e.isNetwork { /* 아래 큐로 */ }
        }
        Cache.shared.enqueue("phrase_delete", PhraseDeleteOp(id: id))
        pendingCount = Cache.shared.pendingCount
    }
}

/// 오프라인에서 온라인 전용 동작을 눌렀을 때 그 자리에 보여줄 문구 (폴백 없음)
let onlineOnlyMessage = "온라인에서만 된다"
