import Foundation
import SwiftData

// MARK: - SwiftData 모델 (서버 표의 사본. 서버가 진실, 여기는 캐시)

@Model final class CachedArticle {
    @Attribute(.unique) var id: String
    var title: String
    var source: String
    var createdAt: Int64
    init(id: String, title: String, source: String, createdAt: Int64) { self.id = id; self.title = title; self.source = source; self.createdAt = createdAt }
}

@Model final class CachedSentence {
    @Attribute(.unique) var id: String
    var articleId: String
    var idx: Int
    var paragraph: Int
    var text: String
    init(id: String, articleId: String, idx: Int, paragraph: Int, text: String) { self.id = id; self.articleId = articleId; self.idx = idx; self.paragraph = paragraph; self.text = text }
}

@Model final class CachedAttempt {
    @Attribute(.unique) var id: String
    var sentenceId: String
    var articleId: String
    var translation: String
    var grade: String
    var feedback: Data          // Feedback JSON
    var createdAt: Int64
    init(id: String, sentenceId: String, articleId: String, translation: String, grade: String, feedback: Data, createdAt: Int64) {
        self.id = id; self.sentenceId = sentenceId; self.articleId = articleId; self.translation = translation; self.grade = grade; self.feedback = feedback; self.createdAt = createdAt
    }
}

@Model final class CachedPhrase {
    @Attribute(.unique) var id: String
    var phrase: String
    var meaning: String
    var sentenceId: String
    var articleId: String
    var createdAt: Int64
    init(id: String, phrase: String, meaning: String, sentenceId: String, articleId: String, createdAt: Int64) {
        self.id = id; self.phrase = phrase; self.meaning = meaning; self.sentenceId = sentenceId; self.articleId = articleId; self.createdAt = createdAt
    }
}

@Model final class CachedReview {
    @Attribute(.unique) var id: String
    var articleId: String
    var score: Int?
    var summary: String
    var patterns: Data          // [ReviewPattern] JSON
    var praise: String
    var createdAt: Int64
    init(id: String, articleId: String, score: Int?, summary: String, patterns: Data, praise: String, createdAt: Int64) {
        self.id = id; self.articleId = articleId; self.score = score; self.summary = summary; self.patterns = patterns; self.praise = praise; self.createdAt = createdAt
    }
}

@Model final class CachedQuizResult {
    @Attribute(.unique) var id: String
    var key: String
    var sentenceId: String
    var source: String
    var correct: Bool
    var createdAt: Int64
    init(id: String, key: String, sentenceId: String, source: String, correct: Bool, createdAt: Int64) {
        self.id = id; self.key = key; self.sentenceId = sentenceId; self.source = source; self.correct = correct; self.createdAt = createdAt
    }
}

@Model final class CachedSession {
    @Attribute(.unique) var id: String
    var startedAt: Int64
    var endedAt: Int64
    var attempts: Int
    var score: Int?
    var articles: [String]
    var createdAt: Int64
    init(id: String, startedAt: Int64, endedAt: Int64, attempts: Int, score: Int?, articles: [String], createdAt: Int64) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.attempts = attempts; self.score = score; self.articles = articles; self.createdAt = createdAt
    }
}

/// 오프라인 큐. 연결되면 순서대로 보낸다
@Model final class PendingOp {
    @Attribute(.unique) var id: String
    var kind: String            // quiz_result | phrase_save | phrase_delete
    var payload: Data           // kind별 JSON
    var createdAt: Int64
    init(kind: String, payload: Data) { self.id = UUID().uuidString; self.kind = kind; self.payload = payload; self.createdAt = Date().ms }
}

// MARK: - 캐시 질의·저장

@MainActor
final class Cache {
    static let shared = Cache()
    let container: ModelContainer
    var ctx: ModelContext { container.mainContext }

    private static let exportedAtKey = "lbn_cache_exported_at"
    private static let lastFullKey = "lbn_cache_last_full"
    private static let needsFullKey = "lbn_cache_needs_full"

    private init() {
        let schema = Schema([CachedArticle.self, CachedSentence.self, CachedAttempt.self, CachedPhrase.self, CachedReview.self, CachedQuizResult.self, CachedSession.self, PendingOp.self])
        let url = URL.applicationSupportDirectory.appendingPathComponent("cache.store")
        do {
            container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        } catch {
            // 스키마가 바뀌어 못 열면 캐시를 버리고 새로 만든다 (서버가 진실)
            AppLog.shared.warn("cache", "store open failed, recreating: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            UserDefaults.standard.removeObject(forKey: Self.exportedAtKey)
        }
        ctx.autosaveEnabled = false
    }

    /// 마지막 동기화(exported_at). 없으면 한 번도 안 받은 것
    var exportedAt: Int64? {
        get { let v = UserDefaults.standard.object(forKey: Self.exportedAtKey) as? Int64; return v == 0 ? nil : v }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: Self.exportedAtKey) }
    }
    var lastFullAt: Int64? {
        get { let v = UserDefaults.standard.object(forKey: Self.lastFullKey) as? Int64; return v == 0 ? nil : v }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: Self.lastFullKey) }
    }
    /// 공책 삭제·문장 합치기 뒤: 다음엔 전체를 다시 받아 삭제를 반영한다
    var needsFull: Bool {
        get { UserDefaults.standard.bool(forKey: Self.needsFullKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.needsFullKey) }
    }
    var isEmpty: Bool { (try? ctx.fetchCount(FetchDescriptor<CachedArticle>())) ?? 0 == 0 }

    private func all<T: PersistentModel>(_ t: T.Type) -> [T] { (try? ctx.fetch(FetchDescriptor<T>())) ?? [] }
    private func deleteAll<T: PersistentModel>(_ t: T.Type) { try? ctx.delete(model: T.self) }

    // MARK: 내보내기 적용

    /// full: 전부 지우고 교체. 아니면 articles·sentences는 교체, 나머지는 id로 upsert(증분)
    func apply(_ x: ExportPayload, full: Bool) throws {
        if full {
            deleteAll(CachedArticle.self); deleteAll(CachedSentence.self); deleteAll(CachedAttempt.self)
            deleteAll(CachedPhrase.self); deleteAll(CachedReview.self); deleteAll(CachedQuizResult.self); deleteAll(CachedSession.self)
        } else {
            deleteAll(CachedArticle.self); deleteAll(CachedSentence.self)
            let aIds = Set(x.attempts.map(\.id)), pIds = Set(x.phrases.map(\.id)), rIds = Set(x.reviews.map(\.id)), qIds = Set(x.quizResults.map(\.id)), sIds = Set(x.sessions.map(\.id))
            if !aIds.isEmpty { try ctx.delete(model: CachedAttempt.self, where: #Predicate { aIds.contains($0.id) }) }
            if !pIds.isEmpty { try ctx.delete(model: CachedPhrase.self, where: #Predicate { pIds.contains($0.id) }) }
            if !rIds.isEmpty { try ctx.delete(model: CachedReview.self, where: #Predicate { rIds.contains($0.id) }) }
            if !qIds.isEmpty { try ctx.delete(model: CachedQuizResult.self, where: #Predicate { qIds.contains($0.id) }) }
            if !sIds.isEmpty { try ctx.delete(model: CachedSession.self, where: #Predicate { sIds.contains($0.id) }) }
        }
        for a in x.articles { ctx.insert(CachedArticle(id: a.id, title: a.title, source: a.source ?? "", createdAt: a.createdAt)) }
        for s in x.sentences { ctx.insert(CachedSentence(id: s.id, articleId: s.articleId, idx: s.idx, paragraph: s.paragraph ?? 0, text: s.text)) }
        for a in x.attempts {
            ctx.insert(CachedAttempt(id: a.id, sentenceId: a.sentenceId, articleId: a.articleId, translation: a.translation, grade: a.grade.rawValue, feedback: (try? JSONEncoder.api.encode(a.feedback)) ?? Data(), createdAt: a.createdAt))
        }
        for p in x.phrases { ctx.insert(CachedPhrase(id: p.id, phrase: p.phrase, meaning: p.meaning, sentenceId: p.sentenceId, articleId: p.articleId, createdAt: p.createdAt)) }
        for r in x.reviews {
            ctx.insert(CachedReview(id: r.id, articleId: r.articleId, score: r.score, summary: r.review.summary ?? "", patterns: (try? JSONEncoder.api.encode(r.review.patterns ?? [])) ?? Data(), praise: r.review.praise ?? "", createdAt: r.createdAt))
        }
        for q in x.quizResults { ctx.insert(CachedQuizResult(id: q.id, key: q.key, sentenceId: q.sentenceId, source: q.source, correct: q.correct, createdAt: q.createdAt)) }
        for s in x.sessions { ctx.insert(CachedSession(id: s.id, startedAt: s.startedAt, endedAt: s.endedAt, attempts: s.attempts, score: s.score, articles: s.articles, createdAt: s.createdAt)) }
        try ctx.save()
        exportedAt = x.exportedAt
        if full { lastFullAt = Date().ms; needsFull = false }
        AppLog.shared.info("cache", full ? "full applied" : "incremental applied", ["articles": "\(x.articles.count)", "attempts": "\(x.attempts.count)", "phrases": "\(x.phrases.count)"])
    }

    // MARK: 화면용 질의 (서버 핸들러와 같은 계산)

    private func attemptsBySentence() -> [String: [CachedAttempt]] {
        Dictionary(grouping: all(CachedAttempt.self), by: \.sentenceId).mapValues { $0.sorted { $0.createdAt < $1.createdAt } }
    }
    private func toAttempt(_ a: CachedAttempt) -> Attempt {
        let fb = (try? JSONDecoder.api.decode(Feedback.self, from: a.feedback)) ?? Feedback(grade: Grade(rawValue: a.grade) ?? .skip, issues: [], reference: "", expressions: [])
        return Attempt(translation: a.translation, grade: Grade(rawValue: a.grade) ?? .skip, feedback: fb, createdAt: a.createdAt)
    }
    private func toReview(_ r: CachedReview) -> Review {
        Review(id: r.id, score: r.score, createdAt: r.createdAt, summary: r.summary, patterns: (try? JSONDecoder.api.decode([ReviewPattern].self, from: r.patterns)) ?? [], praise: r.praise)
    }
    private func toSession(_ s: CachedSession) -> StudySession {
        StudySession(id: s.id, startedAt: s.startedAt, endedAt: s.endedAt, attempts: s.attempts, score: s.score, articles: s.articles, createdAt: s.createdAt)
    }

    func articles() -> [ArticleSummary]? {
        let arts = all(CachedArticle.self)
        guard !arts.isEmpty else { return nil }
        let sents = Dictionary(grouping: all(CachedSentence.self), by: \.articleId)
        let latest = attemptsBySentence().compactMapValues(\.last)
        let reviewCount = Dictionary(grouping: all(CachedReview.self), by: \.articleId).mapValues(\.count)
        return arts.sorted { $0.createdAt > $1.createdAt }.map { a in
            let ss = sents[a.id] ?? []
            var grades: [String: Int] = [:]
            for s in ss { if let l = latest[s.id] { grades[l.grade, default: 0] += 1 } }
            return ArticleSummary(id: a.id, title: a.title, source: a.source, createdAt: a.createdAt, sentenceCount: ss.count, doneCount: grades.values.reduce(0, +), grades: grades, reviewCount: reviewCount[a.id] ?? 0)
        }
    }

    func article(_ id: String) -> ArticleDetail? {
        guard let a = all(CachedArticle.self).first(where: { $0.id == id }) else { return nil }
        let bySentence = attemptsBySentence()
        let sentences = all(CachedSentence.self).filter { $0.articleId == id }.sorted { $0.idx < $1.idx }.map { s -> Sentence in
            let hist = (bySentence[s.id] ?? []).map(toAttempt)
            return Sentence(id: s.id, idx: s.idx, paragraph: s.paragraph, text: s.text, attempt: hist.last, history: Array(hist.dropLast()))
        }
        let phrases = all(CachedPhrase.self).filter { $0.articleId == id }.sorted { $0.createdAt < $1.createdAt }.map { p in
            Phrase(id: p.id, phrase: p.phrase, meaning: p.meaning, sentenceId: p.sentenceId, articleId: p.articleId, createdAt: p.createdAt, sentenceText: sentences.first { $0.id == p.sentenceId }?.text, articleTitle: a.title)
        }
        let reviews = all(CachedReview.self).filter { $0.articleId == id }.sorted { $0.createdAt > $1.createdAt }.map(toReview)
        return ArticleDetail(id: a.id, title: a.title, source: a.source, createdAt: a.createdAt, sentences: sentences, phrases: phrases, reviews: reviews)
    }

    func phrases(q: String) -> [Phrase]? {
        guard !isEmpty else { return nil }
        let sents = Dictionary(uniqueKeysWithValues: all(CachedSentence.self).map { ($0.id, $0) })
        let arts = Dictionary(uniqueKeysWithValues: all(CachedArticle.self).map { ($0.id, $0) })
        let needle = q.lowercased()
        return all(CachedPhrase.self)
            .filter { needle.isEmpty || $0.phrase.lowercased().contains(needle) || $0.meaning.lowercased().contains(needle) }
            .sorted { $0.createdAt > $1.createdAt }
            .map { Phrase(id: $0.id, phrase: $0.phrase, meaning: $0.meaning, sentenceId: $0.sentenceId, articleId: $0.articleId, createdAt: $0.createdAt, sentenceText: sents[$0.sentenceId]?.text, articleTitle: arts[$0.articleId]?.title) }
    }

    func quiz() -> [QuizItem]? {
        guard !isEmpty else { return nil }
        let sents = Dictionary(uniqueKeysWithValues: all(CachedSentence.self).map { ($0.id, $0) })
        let arts = Dictionary(uniqueKeysWithValues: all(CachedArticle.self).map { ($0.id, $0) })
        var last: [String: (correct: Bool, at: Int64, n: Int, wrong: Int)] = [:]
        for r in all(CachedQuizResult.self).sorted(by: { $0.createdAt < $1.createdAt }) {
            let p = last[r.key]
            last[r.key] = (r.correct, r.createdAt, (p?.n ?? 0) + 1, (p?.wrong ?? 0) + (r.correct ? 0 : 1))
        }
        var items: [String: QuizItem] = [:]
        var order: [String] = []
        func put(_ it: QuizItem) { if items[it.key] == nil { order.append(it.key) }; items[it.key] = it }
        for a in all(CachedAttempt.self).sorted(by: { $0.createdAt < $1.createdAt }) where a.grade != "skip" {
            guard let s = sents[a.sentenceId], let fb = try? JSONDecoder.api.decode(Feedback.self, from: a.feedback) else { continue }
            for i in fb.issues where !i.source.isEmpty {
                let key = "\(a.sentenceId)|\(i.source)"; let l = last[key]
                put(QuizItem(key: key, kind: .issue, sentenceId: a.sentenceId, articleId: s.articleId, articleTitle: arts[s.articleId]?.title ?? "", sentenceIdx: s.idx, sentenceText: s.text,
                             source: i.source, mine: i.mine, meaning: i.meaning, why: i.why, issuedAt: a.createdAt,
                             lastCorrect: l?.correct, lastAt: l?.at, tries: l?.n ?? 0, wrong: l?.wrong ?? 0))
            }
        }
        for p in all(CachedPhrase.self).sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = "p|\(p.id)"; let l = last[key]; let s = sents[p.sentenceId]
            put(QuizItem(key: key, kind: .phrase, sentenceId: p.sentenceId, articleId: p.articleId, articleTitle: arts[p.articleId]?.title ?? "", sentenceIdx: s?.idx ?? 0, sentenceText: s?.text ?? "",
                         source: p.phrase, mine: "", meaning: p.meaning, why: "", issuedAt: p.createdAt,
                         lastCorrect: l?.correct, lastAt: l?.at, tries: l?.n ?? 0, wrong: l?.wrong ?? 0))
        }
        return order.compactMap { items[$0] }
    }

    func sessions() -> [StudySession]? {
        guard !isEmpty else { return nil }
        return all(CachedSession.self).sorted { $0.startedAt > $1.startedAt }.map(toSession)
    }

    func activityLog(days: Int) -> ActivityLog? {
        guard !isEmpty else { return nil }
        let since = Date().ms - Int64(days) * 86_400_000
        let sents = Dictionary(uniqueKeysWithValues: all(CachedSentence.self).map { ($0.id, $0) })
        let arts = Dictionary(uniqueKeysWithValues: all(CachedArticle.self).map { ($0.id, $0) })
        let attempts = all(CachedAttempt.self).filter { $0.createdAt >= since }.sorted { $0.createdAt < $1.createdAt }.compactMap { a -> LogAttempt? in
            guard let s = sents[a.sentenceId], let ar = arts[a.articleId] else { return nil }
            return LogAttempt(id: a.id, sentenceId: a.sentenceId, articleId: a.articleId, translation: a.translation, grade: Grade(rawValue: a.grade) ?? .skip, createdAt: a.createdAt, idx: s.idx, text: s.text, title: ar.title)
        }
        let sessions = all(CachedSession.self).filter { $0.endedAt >= since }.sorted { $0.startedAt < $1.startedAt }.map(toSession)
        let reviews = all(CachedReview.self).filter { $0.createdAt >= since }.sorted { $0.createdAt < $1.createdAt }.compactMap { r -> LogReview? in
            guard let ar = arts[r.articleId] else { return nil }
            return LogReview(id: r.id, articleId: r.articleId, title: ar.title, score: r.score, createdAt: r.createdAt, summary: r.summary)
        }
        let quiz = all(CachedQuizResult.self).filter { $0.createdAt >= since }.sorted { $0.createdAt < $1.createdAt }.map {
            LogQuiz(id: $0.id, key: $0.key, source: $0.source, correct: $0.correct, createdAt: $0.createdAt, kind: $0.key.hasPrefix("p|") ? .phrase : .issue)
        }
        return ActivityLog(since: since, attempts: attempts, sessions: sessions, reviews: reviews, quiz: quiz)
    }

    // MARK: 오프라인에서 바뀐 것을 캐시에도 반영 (서버에 보내질 때까지 화면이 맞도록)

    func upsertPhrase(_ p: Phrase) {
        if let e = all(CachedPhrase.self).first(where: { $0.id == p.id }) { e.phrase = p.phrase; e.meaning = p.meaning }
        else { ctx.insert(CachedPhrase(id: p.id, phrase: p.phrase, meaning: p.meaning, sentenceId: p.sentenceId, articleId: p.articleId, createdAt: p.createdAt)) }
        try? ctx.save()
    }
    func removePhrase(id: String) {
        if let e = all(CachedPhrase.self).first(where: { $0.id == id }) { ctx.delete(e); try? ctx.save() }
    }
    func renamePhrase(from tempId: String, to real: Phrase) {
        if let e = all(CachedPhrase.self).first(where: { $0.id == tempId }) { ctx.delete(e) }
        upsertPhrase(real)
    }
    func addQuizResult(key: String, sentenceId: String, source: String, correct: Bool) {
        ctx.insert(CachedQuizResult(id: "local-" + UUID().uuidString, key: key, sentenceId: sentenceId, source: source, correct: correct, createdAt: Date().ms))
        try? ctx.save()
    }

    // MARK: 오프라인 큐

    func enqueue(_ kind: String, _ payload: some Encodable) {
        ctx.insert(PendingOp(kind: kind, payload: (try? JSONEncoder.api.encode(payload)) ?? Data()))
        try? ctx.save()
        AppLog.shared.info("queue", "enqueued \(kind)")
    }
    func pending() -> [PendingOp] { all(PendingOp.self).sorted { $0.createdAt < $1.createdAt } }
    func remove(_ op: PendingOp) { ctx.delete(op); try? ctx.save() }
    var pendingCount: Int { (try? ctx.fetchCount(FetchDescriptor<PendingOp>())) ?? 0 }
}
