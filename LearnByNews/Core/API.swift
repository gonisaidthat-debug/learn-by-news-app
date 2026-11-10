import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(String)
    case network(String)

    /// 네트워크(오프라인) 때문인가. 서버가 돌려준 오류(4xx/5xx)는 아니다
    var isNetwork: Bool { if case .network = self { return true }; return false }

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "비밀번호가 필요합니다"
        case .server(let m): return m
        case .network(let m): return m
        }
    }
}

extension Notification.Name { static let lbnUnauthorized = Notification.Name("lbn.unauthorized") }

/// 웹 api.ts와 같은 호출. 모든 요청에 Bearer 비밀번호.
final class API {
    static let shared = API()
    static let base = URL(string: "https://learn-by-news.goni-said-that.workers.dev")!
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90   // 채점·총평은 수 초~수십 초
        c.waitsForConnectivity = false
        #if DEBUG
        if MockServer.enabled { c.protocolClasses = [MockServer.self] }
        #endif
        return URLSession(configuration: c)
    }()

    struct Empty: Encodable {}

    /// 이번 실행 동안의 비밀번호. 로그인 때 넣고, 시작 때 Keychain에서 읽는다. Keychain 저장이 실패해도 세션은 동작한다
    static var token: String? = Keychain.get()

    /// 모든 요청의 Authorization 값. 헤더는 ASCII만 실리므로 비밀번호(한글 가능)를 percent-encoding한다.
    /// 서버가 decodeURIComponent 해서 비교한다. Keychain에는 원문 그대로 둔다.
    static func authHeader() -> String {
        let raw = token ?? Keychain.get() ?? ""
        return "Bearer " + (raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: Self.base.absoluteString + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.authHeader(), forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try JSONEncoder.api.encode(body) }
        let t0 = Date()
        let data: Data, http: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: req)
            data = d; http = r as! HTTPURLResponse
        } catch {
            AppLog.shared.error("api", "\(method) \(path) 네트워크 실패", ["error": error.localizedDescription])
            throw APIError.network(error.localizedDescription)
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if http.statusCode == 401 {
            AppLog.shared.warn("api", "\(method) \(path) 401", ["tokenChars": "\((Self.token ?? Keychain.get() ?? "").count)"])
            Self.token = nil
            Keychain.delete()
            await MainActor.run { NotificationCenter.default.post(name: .lbnUnauthorized, object: nil) }
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            var msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = j["error"] as? String { msg = e }
            if msg.isEmpty { msg = "HTTP \(http.statusCode)" }
            AppLog.shared.error("api", "\(method) \(path) \(http.statusCode)", ["error": msg, "ms": "\(ms)"])
            throw APIError.server(msg)
        }
        AppLog.shared.debug("api", "\(method) \(path) \(http.statusCode)", ["ms": "\(ms)"])
        do { return try JSONDecoder.api.decode(T.self, from: data) }
        catch {
            AppLog.shared.error("api", "\(method) \(path) 응답 해석 실패", ["error": "\(error)"])
            throw APIError.server("응답을 읽을 수 없습니다: \(error.localizedDescription)")
        }
    }

    struct OK: Decodable { var ok: Bool }

    // MARK: auth
    func checkAuth() async throws { let _: OK = try await send("GET", "/api/auth") }

    // MARK: articles
    func articles() async throws -> [ArticleSummary] { try await send("GET", "/api/articles") }
    func article(_ id: String) async throws -> ArticleDetail { try await send("GET", "/api/articles/\(id)") }
    struct CreateArticle: Encodable { var title: String; var source: String; var sentences: [SentenceBody] }
    struct SentenceBody: Encodable { var paragraph: Int; var text: String }
    struct Created: Decodable { var id: String }
    func createArticle(title: String, sentences: [SplitSentence], source: String) async throws -> String {
        let r: Created = try await send("POST", "/api/articles", body: CreateArticle(title: title, source: source, sentences: sentences.map { .init(paragraph: $0.paragraph, text: $0.text) }))
        return r.id
    }
    struct SourceBody: Encodable { var source: String }
    func setSource(_ id: String, _ source: String) async throws { let _: OK = try await send("PATCH", "/api/articles/\(id)", body: SourceBody(source: source)) }
    func deleteArticle(_ id: String) async throws { let _: OK = try await send("DELETE", "/api/articles/\(id)") }
    struct ReviewBody: Encodable { var score: Int? }
    func review(_ id: String, score: Int?) async throws -> Review { try await send("POST", "/api/articles/\(id)/review", body: ReviewBody(score: score)) }

    // MARK: sentences
    struct TranslationBody: Encodable { var translation: String; var attemptId: String }
    struct SkipBody: Encodable { var skip = true; var attemptId: String }
    /// attemptId는 클라이언트 UUID. 멈추기(DELETE /api/attempts/:id)에 쓴다
    func attempt(_ sentenceId: String, translation: String, attemptId: String) async throws -> AttemptResult {
        try await send("POST", "/api/sentences/\(sentenceId)/attempts", body: translation.isEmpty ? SkipBody(attemptId: attemptId) as any Encodable : TranslationBody(translation: translation, attemptId: attemptId))
    }
    struct Cancelled: Decodable { var ok: Bool; var removed: Bool? }
    /// 멈추기: 채점이 끝났으면 삭제, 아직이면 결과 도착 시 버린다
    func cancelAttempt(_ attemptId: String) async throws -> Cancelled { try await send("DELETE", "/api/attempts/\(attemptId)") }
    struct MergeBody: Encodable { var dir: String }
    struct Merged: Decodable { var ok: Bool; var kept: String; var text: String }
    func merge(_ sentenceId: String, dir: String) async throws -> Merged { try await send("POST", "/api/sentences/\(sentenceId)/merge", body: MergeBody(dir: dir)) }
    func deleteSentence(_ id: String) async throws { let _: OK = try await send("DELETE", "/api/sentences/\(id)") }

    // MARK: phrases
    func phrases(q: String = "") async throws -> [Phrase] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? ""
        return try await send("GET", "/api/phrases?q=\(enc)")
    }
    struct PhraseBody: Encodable { var phrase: String; var meaning: String; var sentenceId: String; var articleId: String }
    func savePhrase(_ e: Expression, sentenceId: String, articleId: String) async throws -> Phrase {
        try await send("POST", "/api/phrases", body: PhraseBody(phrase: e.phrase, meaning: e.meaning, sentenceId: sentenceId, articleId: articleId))
    }
    func deletePhrase(_ id: String) async throws { let _: OK = try await send("DELETE", "/api/phrases/\(id)") }

    // MARK: quiz
    func quiz() async throws -> [QuizItem] { try await send("GET", "/api/quiz") }
    struct QuizResultBody: Codable { var key: String; var sentenceId: String; var source: String; var correct: Bool }
    func answerQuiz(_ it: QuizItem, correct: Bool) async throws {
        let _: OK = try await send("POST", "/api/quiz/results", body: QuizResultBody(key: it.key, sentenceId: it.sentenceId, source: it.source, correct: correct))
    }

    // MARK: sessions
    func sessions() async throws -> [StudySession] { try await send("GET", "/api/sessions") }
    struct SessionBody: Encodable { var startedAt: Int64 }
    func closeSession(startedAt: Int64) async throws -> StudySession { try await send("POST", "/api/sessions", body: SessionBody(startedAt: startedAt)) }
    func deleteSession(_ id: String) async throws { let _: OK = try await send("DELETE", "/api/sessions/\(id)") }

    // MARK: log
    func activityLog(days: Int) async throws -> ActivityLog { try await send("GET", "/api/log?days=\(days)") }

    // MARK: 기기 상태 → 서버 (다시 쓰기 진행, 공부 시작점). 서버가 진실, 로컬은 캐시
    func pass(_ articleId: String) async throws -> PassState? { let r: PassState? = try await send("GET", "/api/articles/\(articleId)/pass"); return r }
    struct PassBody: Codable { var done: [String] }
    func putPass(_ articleId: String, done: [String]) async throws { let _: OK = try await send("PUT", "/api/articles/\(articleId)/pass", body: PassBody(done: done)) }
    func deletePass(_ articleId: String) async throws { let _: OK = try await send("DELETE", "/api/articles/\(articleId)/pass") }
    func sessionStart() async throws -> SessionStartState? { let r: SessionStartState? = try await send("GET", "/api/session-start"); return r }
    func putSessionStart(_ startedAt: Int64) async throws { let _: OK = try await send("PUT", "/api/session-start", body: SessionStartState(startedAt: startedAt)) }
    func deleteSessionStart() async throws { let _: OK = try await send("DELETE", "/api/session-start") }

    // MARK: 응용
    struct DrillNextBody: Encodable { var phraseId: String? }
    func nextDrill(phraseId: String? = nil) async throws -> Drill { try await send("POST", "/api/drills/next", body: DrillNextBody(phraseId: phraseId)) }
    struct DrillAnswerBody: Encodable { var answer: String }
    func answerDrill(_ id: String, answer: String) async throws -> Drill { try await send("POST", "/api/drills/\(id)/answer", body: DrillAnswerBody(answer: answer)) }
    func deleteDrill(_ id: String) async throws { let _: OK = try await send("DELETE", "/api/drills/\(id)") }
    func drills(days: Int = 30) async throws -> [Drill] { try await send("GET", "/api/drills?days=\(days)") }

    // MARK: 형광펜
    struct AskBody: Encodable { var startWord: Int; var endWord: Int; var span: String }
    func ask(_ sentenceId: String, startWord: Int, endWord: Int, span: String) async throws -> AskResult {
        try await send("POST", "/api/sentences/\(sentenceId)/ask", body: AskBody(startWord: startWord, endWord: endWord, span: span))
    }
    func deleteHighlight(_ id: String) async throws { let _: OK = try await send("DELETE", "/api/highlights/\(id)") }

    // MARK: bookmark (서버에 하나)
    func bookmark() async throws -> Bookmark? {
        // 없으면 본문이 "null" → Optional로 해석
        let r: Bookmark? = try await send("GET", "/api/bookmark")
        return r
    }
    struct BookmarkBody: Encodable { var articleId: String; var sentenceId: String; var round: Int? }
    func setBookmark(articleId: String, sentenceId: String, round: Int?) async throws {
        let _: OK = try await send("PUT", "/api/bookmark", body: BookmarkBody(articleId: articleId, sentenceId: sentenceId, round: round))
    }
    func clearBookmark() async throws { let _: OK = try await send("DELETE", "/api/bookmark") }

    // MARK: export (오프라인 캐시)
    func export(since: Int64?) async throws -> ExportPayload {
        try await send("GET", since.map { "/api/export?since=\($0)" } ?? "/api/export")
    }
}
