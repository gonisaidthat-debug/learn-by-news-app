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

/// 오프라인 캐시 동기화 (GET /api/export) + 오프라인 큐 전송
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncAt: Int64? = Cache.shared.exportedAt
    @Published private(set) var pendingCount = Cache.shared.pendingCount
    private var flushing = false

    private init() {}

    /// 앱 시작·포그라운드 복귀: 온라인이면 증분. 하루 한 번 또는 삭제 뒤엔 전체
    func autoSync() async {
        guard Connectivity.shared.isOnline, Keychain.get() != nil else { return }
        let c = Cache.shared
        let dayAgo = Date().ms - 86_400_000
        let full = c.exportedAt == nil || c.needsFull || (c.lastFullAt ?? 0) < dayAgo
        await sync(full: full)
        await flushQueue()
    }

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
        defer { flushing = false; pendingCount = Cache.shared.pendingCount }
        for op in Cache.shared.pending() {
            do {
                switch op.kind {
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
                default: break
                }
                Cache.shared.remove(op)
                AppLog.shared.info("queue", "sent \(op.kind)")
            } catch let e as APIError where e.isNetwork {
                AppLog.shared.info("queue", "paused (offline)")
                return
            } catch {
                AppLog.shared.error("queue", "dropped \(op.kind): \(error.localizedDescription)")
                Cache.shared.remove(op)
            }
        }
    }

    struct PhraseSaveOp: Codable { var tempId: String; var phrase: String; var meaning: String; var sentenceId: String; var articleId: String }
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
