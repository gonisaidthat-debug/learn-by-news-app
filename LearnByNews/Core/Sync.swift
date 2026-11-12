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
}

/// 오프라인 캐시 동기화 (GET /api/export) + 오프라인 큐 전송
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncAt: Int64? = Cache.shared.exportedAt
    @Published private(set) var pendingCount = Cache.shared.pendingCount
    @Published private(set) var pendingAttempts = Cache.shared.pending(kind: "attempt").count
    private var flushing = false

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

    private func refreshCounts() { pendingCount = Cache.shared.pendingCount; pendingAttempts = Cache.shared.pending(kind: "attempt").count }

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

    /// 오프라인 큐를 순서대로 보낸다. 네트워크 오류면 멈추고 다음 기회에, 서버 오류(4xx/5xx)면 그 항목은 버린다
    func flushQueue() async {
        guard !flushing, Connectivity.shared.isOnline else { return }
        flushing = true
        var sentAttempts = false
        defer { flushing = false; refreshCounts() }
        for op in Cache.shared.pending() {
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
                    let r = try await API.shared.attempt(sid, translation: b.skip ? "" : b.translation, attemptId: b.attemptId)
                    for p in r.phrases { Cache.shared.upsertPhrase(p) }
                    sentAttempts = true
                    NotificationCenter.default.post(name: .lbnAttemptGraded, object: nil, userInfo: ["attemptId": b.attemptId, "sentenceId": b.sentenceId, "result": r])
                case "attempt_cancel":
                    let b = try JSONDecoder.api.decode(AttemptOp.self, from: op.payload)
                    _ = try await API.shared.cancelAttempt(b.attemptId)
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
                    let r = try await API.shared.memo(real(b.sentenceId), startWord: b.startWord, endWord: b.endWord, span: b.span, note: b.note)
                    Cache.shared.removeHighlight(id: b.tempId); Cache.shared.upsertHighlight(r.highlight)
                    if let p = r.phrase { Cache.shared.upsertPhrase(p) }
                    var map = idMap; map[b.tempId] = r.highlight.id; idMap = map
                case "highlight_note":
                    let b = try JSONDecoder.api.decode(NoteOp.self, from: op.payload)
                    try await API.shared.setHighlightNote(real(b.highlightId), note: b.note)
                case "drill_answer":
                    let b = try JSONDecoder.api.decode(DrillAnswerOp.self, from: op.payload)
                    let d = try await API.shared.answerDrill(b.id, answer: b.answer)
                    DrillStore.shared.didGrade(d)
                    NotificationCenter.default.post(name: .lbnDrillGraded, object: nil, userInfo: ["drill": d])
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
    struct ArticleCreateOp: Codable {
        struct S: Codable { var paragraph: Int; var text: String }
        var tempId: String; var title: String; var source: String; var sentences: [S]
    }
    struct AttemptOp: Codable { var attemptId: String; var sentenceId: String; var articleId: String; var translation: String; var skip: Bool; var createdAt: Int64 }
    struct SentenceOp: Codable { var sentenceId: String; var dir: String? }
    struct ArticlePatchOp: Codable { var articleId: String; var source: String? }
    struct BookmarkOp: Codable { var articleId: String; var sentenceId: String; var round: Int? }
    struct DrillAnswerOp: Codable { var id: String; var answer: String; var answeredAtLocal: Int64; var phrase: String?; var korean: String? }
    struct MemoOp: Codable { var tempId: String; var sentenceId: String; var articleId: String; var startWord: Int; var endWord: Int; var span: String; var note: String }
    struct NoteOp: Codable { var highlightId: String; var note: String }

    /// 형광펜 내 메모 (Claude 없음): 온라인이면 서버, 아니면 임시 id로 캐시 + 큐
    func memo(sentenceId: String, articleId: String, startWord: Int, endWord: Int, span: String, note: String) async throws -> AskResult? {
        if Connectivity.shared.isOnline, !Self.isTemp(sentenceId) {
            do { let r = try await API.shared.memo(sentenceId, startWord: startWord, endWord: endWord, span: span, note: note); Cache.shared.upsertHighlight(r.highlight); if let p = r.phrase { Cache.shared.upsertPhrase(p) }; return r }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        let temp = "local-" + UUID().uuidString.lowercased()
        let h = Highlight(id: temp, sentenceId: sentenceId, articleId: articleId, startWord: startWord, endWord: endWord, span: span, answer: HighlightAnswer(meaning: "", why: "", similar: ""), createdAt: Date().ms, note: note)
        Cache.shared.upsertHighlight(h)
        Cache.shared.enqueue("memo", MemoOp(tempId: temp, sentenceId: sentenceId, articleId: articleId, startWord: startWord, endWord: endWord, span: span, note: note)); refreshCounts()
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
    func queueAttempt(attemptId: String, sentenceId: String, articleId: String, translation: String) {
        Cache.shared.enqueue("attempt", AttemptOp(attemptId: attemptId, sentenceId: sentenceId, articleId: articleId, translation: translation, skip: translation.isEmpty, createdAt: Date().ms))
        refreshCounts()
    }
    /// 이 공책에서 아직 못 보낸 채점들
    func pendingAttempts(for articleId: String) -> [AttemptOp] {
        Cache.shared.pending(kind: "attempt").compactMap { try? JSONDecoder.api.decode(AttemptOp.self, from: $0.payload) }.filter { $0.articleId == articleId }
    }
    /// 멈추기: 큐에 있으면 빼고 끝. 이미 보냈으면 서버에 취소(오프라인이면 그것도 큐)
    func stopAttempt(attemptId: String, sentenceId: String, articleId: String) async {
        for op in Cache.shared.pending(kind: "attempt") {
            if let b = try? JSONDecoder.api.decode(AttemptOp.self, from: op.payload), b.attemptId == attemptId { Cache.shared.remove(op); refreshCounts(); return }
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
    func mergeSentence(_ sid: String, dir: String) async throws {
        if Connectivity.shared.isOnline, !Self.isTemp(sid) {
            do { _ = try await API.shared.merge(sid, dir: dir); Cache.shared.needsFull = true; return }
            catch let e as APIError where e.isNetwork { /* 큐로 */ }
        }
        Cache.shared.mergeLocal(sid, dir: dir)
        Cache.shared.enqueue("sentence_merge", SentenceOp(sentenceId: sid, dir: dir)); refreshCounts()
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

    // MARK: 다시 쓰기 진행 (서버가 진실, RedoProgress는 캐시)
    func putPass(_ articleId: String, done: [String]) async {
        await sendOrQueue("pass_put", PassOp(articleId: articleId, done: done)) { try await API.shared.putPass(articleId, done: done) }
    }
    func deletePass(_ articleId: String) async {
        await sendOrQueue("pass_delete", PassOp(articleId: articleId, done: nil)) { try await API.shared.deletePass(articleId) }
    }
    // MARK: 공부 시작점
    func putSessionStart(_ t: Int64) async {
        await sendOrQueue("session_start_put", SessionStartState(startedAt: t)) { try await API.shared.putSessionStart(t) }
    }
    func deleteSessionStart() async {
        await sendOrQueue("session_start_delete", SessionStartState(startedAt: 0)) { try await API.shared.deleteSessionStart() }
    }
    struct PhraseDeleteOp: Codable { var id: String }

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
