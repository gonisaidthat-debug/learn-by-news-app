import Foundation

enum Grade: String, Codable, CaseIterable, Hashable {
    case A, B, C, D, skip
    static let points: [Grade: Int] = [.A: 100, .B: 80, .C: 50, .D: 20]
}

struct Issue: Codable, Hashable {
    var source: String
    var mine: String
    var meaning: String
    var why: String

    init(source: String, mine: String, meaning: String, why: String) { self.source = source; self.mine = mine; self.meaning = meaning; self.why = why }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        mine = try c.decodeIfPresent(String.self, forKey: .mine) ?? ""
        meaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
    }
}

struct Expression: Codable, Hashable {
    var phrase: String
    var meaning: String
}

struct Feedback: Codable, Hashable {
    var grade: Grade
    var issues: [Issue]
    var reference: String
    var expressions: [Expression]

    init(grade: Grade, issues: [Issue], reference: String, expressions: [Expression]) { self.grade = grade; self.issues = issues; self.reference = reference; self.expressions = expressions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grade = try c.decode(Grade.self, forKey: .grade)
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        reference = try c.decodeIfPresent(String.self, forKey: .reference) ?? ""
        expressions = try c.decodeIfPresent([Expression].self, forKey: .expressions) ?? []
    }
}

struct Attempt: Codable, Hashable {
    var translation: String
    var grade: Grade
    var feedback: Feedback
    var createdAt: Int64
}

struct Sentence: Codable, Identifiable, Hashable {
    var id: String
    var idx: Int
    var paragraph: Int
    var text: String
    var attempt: Attempt?
    var history: [Attempt]

    init(id: String, idx: Int, paragraph: Int, text: String, attempt: Attempt?, history: [Attempt]) {
        self.id = id; self.idx = idx; self.paragraph = paragraph; self.text = text; self.attempt = attempt; self.history = history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        idx = try c.decode(Int.self, forKey: .idx)
        paragraph = try c.decodeIfPresent(Int.self, forKey: .paragraph) ?? 0
        text = try c.decode(String.self, forKey: .text)
        attempt = try c.decodeIfPresent(Attempt.self, forKey: .attempt)
        history = try c.decodeIfPresent([Attempt].self, forKey: .history) ?? []
    }
}

struct Phrase: Codable, Identifiable, Hashable {
    var id: String
    var phrase: String
    var meaning: String
    var sentenceId: String
    var articleId: String
    var createdAt: Int64
    var sentenceText: String?
    var articleTitle: String?
    var backlinks: [Backlink]?

    init(id: String, phrase: String, meaning: String, sentenceId: String, articleId: String, createdAt: Int64, sentenceText: String? = nil, articleTitle: String? = nil, backlinks: [Backlink]? = nil) {
        self.id = id; self.phrase = phrase; self.meaning = meaning; self.sentenceId = sentenceId; self.articleId = articleId; self.createdAt = createdAt; self.sentenceText = sentenceText; self.articleTitle = articleTitle; self.backlinks = backlinks
    }
}

struct ReviewPattern: Codable, Hashable {
    var title: String
    var detail: String
}

struct Review: Codable, Identifiable, Hashable {
    var id: String
    var score: Int?
    var createdAt: Int64
    var summary: String
    var patterns: [ReviewPattern]
    var praise: String

    init(id: String, score: Int?, createdAt: Int64, summary: String, patterns: [ReviewPattern], praise: String) {
        self.id = id; self.score = score; self.createdAt = createdAt; self.summary = summary; self.patterns = patterns; self.praise = praise
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        score = try c.decodeIfPresent(Int.self, forKey: .score)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        patterns = try c.decodeIfPresent([ReviewPattern].self, forKey: .patterns) ?? []
        praise = try c.decodeIfPresent(String.self, forKey: .praise) ?? ""
    }
}

struct ArticleSummary: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var source: String?
    var createdAt: Int64
    var sentenceCount: Int
    var doneCount: Int
    var grades: [String: Int]
    var reviewCount: Int?          // 총평 개수 = 완주 회차
    var passDone: [String]?        // 서버에 저장된 다시 쓰기 진행(제출한 문장 id). null이면 진행 중 아님

    var isDone: Bool { doneCount >= sentenceCount }
    var rounds: Int { reviewCount ?? 0 }
    func count(_ g: Grade) -> Int { grades[g.rawValue] ?? 0 }
}

struct ArticleDetail: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var source: String?
    var createdAt: Int64
    var sentences: [Sentence]
    var phrases: [Phrase]
    var reviews: [Review]
    var highlights: [Highlight]
    var drillCounts: [String: Int]     // 표현(포스트잇 phrase·형광펜 span)별 채점 끝난 응용·자유 작문 수

    init(id: String, title: String, source: String?, createdAt: Int64, sentences: [Sentence], phrases: [Phrase], reviews: [Review], highlights: [Highlight] = [], drillCounts: [String: Int] = [:]) {
        self.id = id; self.title = title; self.source = source; self.createdAt = createdAt; self.sentences = sentences; self.phrases = phrases; self.reviews = reviews; self.highlights = highlights; self.drillCounts = drillCounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        sentences = try c.decodeIfPresent([Sentence].self, forKey: .sentences) ?? []
        phrases = try c.decodeIfPresent([Phrase].self, forKey: .phrases) ?? []
        reviews = try c.decodeIfPresent([Review].self, forKey: .reviews) ?? []
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
        drillCounts = try c.decodeIfPresent([String: Int].self, forKey: .drillCounts) ?? [:]
    }

    /// 등급 평균. 건너뜀 제외. 채점된 문장이 없으면 nil (웹 scoreOf와 동일)
    static func score(of sentences: [Sentence]) -> Int? {
        let pts = sentences.compactMap { s -> Int? in
            guard let g = s.attempt?.grade, g != .skip else { return nil }
            return Grade.points[g]
        }
        guard !pts.isEmpty else { return nil }
        return Int((Double(pts.reduce(0, +)) / Double(pts.count)).rounded())
    }
}

struct AttemptResult: Codable {
    var grade: Grade
    var issues: [Issue]
    var reference: String
    var expressions: [Expression]
    var translation: String
    var createdAt: Int64
    var phrases: [Phrase]      // 서버가 이번에 표현장에 새로 저장한 포스트잇

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grade = try c.decode(Grade.self, forKey: .grade)
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        reference = try c.decodeIfPresent(String.self, forKey: .reference) ?? ""
        expressions = try c.decodeIfPresent([Expression].self, forKey: .expressions) ?? []
        translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? Int64(Date().timeIntervalSince1970 * 1000)
        phrases = try c.decodeIfPresent([Phrase].self, forKey: .phrases) ?? []
    }

    var asAttempt: Attempt {
        // Feedback은 커스텀 디코더만 있어서 JSON을 거쳐 만든다
        let fb = try! JSONDecoder.api.decode(Feedback.self, from: try! JSONEncoder.api.encode(FeedbackBody(grade: grade, issues: issues, reference: reference, expressions: expressions)))
        return Attempt(translation: translation, grade: grade, feedback: fb, createdAt: createdAt)
    }
}

struct FeedbackBody: Encodable {
    var grade: Grade; var issues: [Issue]; var reference: String; var expressions: [Expression]
}

struct QuizItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case issue, phrase, highlight }
    var key: String
    var kind: Kind
    var sentenceId: String
    var articleId: String?
    var articleTitle: String?
    var sentenceIdx: Int?
    var sentenceText: String?
    var source: String
    var mine: String?
    var meaning: String
    var why: String?
    var issuedAt: Int64?
    var lastCorrect: Bool?
    var lastAt: Int64?
    var tries: Int
    var wrong: Int
    var id: String { key }
}

/// 세션 총평: 그 시간의 번역·응용을 모아 쓴 세 줄
struct SessionReview: Codable, Hashable {
    var summary: String
    var keep: String
    var next: String
    init(summary: String, keep: String, next: String) { self.summary = summary; self.keep = keep; self.next = next }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keep = try c.decodeIfPresent(String.self, forKey: .keep) ?? ""
        next = try c.decodeIfPresent(String.self, forKey: .next) ?? ""
    }
}

struct StudySession: Codable, Identifiable, Hashable {
    var id: String
    var startedAt: Int64
    var endedAt: Int64
    var attempts: Int          // 번역 + 응용
    var score: Int?
    var articles: [String]
    var createdAt: Int64
    var drills: Int?           // 그중 응용(써 보기·응용 탭) 수
    var review: SessionReview?
    var reviewError: String?   // POST /api/sessions 응답에만: 총평 실패 이유

    init(id: String, startedAt: Int64, endedAt: Int64, attempts: Int, score: Int?, articles: [String], createdAt: Int64, drills: Int? = nil, review: SessionReview? = nil, reviewError: String? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.attempts = attempts; self.score = score; self.articles = articles; self.createdAt = createdAt; self.drills = drills; self.review = review; self.reviewError = reviewError
    }
    enum CodingKeys: String, CodingKey { case id, startedAt, endedAt, attempts, score, articles, createdAt, drills, review, reviewError }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startedAt = try c.decode(Int64.self, forKey: .startedAt)
        endedAt = try c.decode(Int64.self, forKey: .endedAt)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        score = try c.decodeIfPresent(Int.self, forKey: .score)
        articles = try c.decodeIfPresent([String].self, forKey: .articles) ?? []
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        drills = try c.decodeIfPresent(Int.self, forKey: .drills)
        review = try? c.decodeIfPresent(SessionReview.self, forKey: .review)
        reviewError = try c.decodeIfPresent(String.self, forKey: .reviewError)
    }

    var minutes: Int { max(1, Int((Double(endedAt - startedAt) / 60000).rounded())) }
    /// "18문장 (응용 6)" — 응용이 0이면 괄호 생략
    var countLabel: String { "\(attempts)문장" + ((drills ?? 0) > 0 ? " (응용 \(drills!))" : "") }

    /// 웹 fmtSession과 동일: "11/6 14:03–14:40 · 37분 · 18문장 (응용 6) · 85점"
    var line: String {
        let d = Date(ms: startedAt)
        var s = "\(d.monthDay) \(Date(ms: startedAt).hm)–\(Date(ms: endedAt).hm) · \(minutes)분 · \(countLabel)"
        if let score { s += " · \(score)점" }
        return s
    }
}

struct LogAttempt: Codable, Identifiable, Hashable {
    var id: String
    var sentenceId: String
    var articleId: String
    var translation: String
    var grade: Grade
    var createdAt: Int64
    var idx: Int
    var text: String
    var title: String
}

struct LogReview: Codable, Identifiable, Hashable {
    var id: String
    var articleId: String
    var title: String
    var score: Int?
    var createdAt: Int64
    var summary: String
}

struct LogQuiz: Codable, Identifiable, Hashable {
    var id: String
    var key: String
    var source: String
    var correct: Bool
    var createdAt: Int64
    var kind: QuizItem.Kind
    var articleId: String?
    var title: String?

    init(id: String, key: String, source: String, correct: Bool, createdAt: Int64, kind: QuizItem.Kind, articleId: String? = nil, title: String? = nil) {
        self.id = id; self.key = key; self.source = source; self.correct = correct; self.createdAt = createdAt; self.kind = kind; self.articleId = articleId; self.title = title
    }
}

struct LogDrill: Codable, Identifiable, Hashable {
    var id: String
    var phrase: String
    var korean: String
    var kind: String?
    var isFree: Bool { kind == "free" }
    var answer: String?
    var grade: Grade?
    var usedExpression: Bool?
    var answeredAt: Int64?
    var articleId: String?
    var title: String?

    init(id: String, phrase: String, korean: String, kind: String? = nil, answer: String? = nil, grade: Grade? = nil, usedExpression: Bool? = nil, answeredAt: Int64? = nil, articleId: String? = nil, title: String? = nil) {
        self.id = id; self.phrase = phrase; self.korean = korean; self.kind = kind; self.answer = answer; self.grade = grade; self.usedExpression = usedExpression; self.answeredAt = answeredAt; self.articleId = articleId; self.title = title
    }
}

struct ActivityLog: Codable {
    var since: Int64
    var attempts: [LogAttempt]
    var sessions: [StudySession]
    var reviews: [LogReview]
    var quiz: [LogQuiz]
    var drills: [LogDrill]?

    init(since: Int64, attempts: [LogAttempt], sessions: [StudySession], reviews: [LogReview], quiz: [LogQuiz], drills: [LogDrill]? = nil) {
        self.since = since; self.attempts = attempts; self.sessions = sessions; self.reviews = reviews; self.quiz = quiz; self.drills = drills
    }
}

// MARK: - 날짜 도우미

extension Date {
    init(ms: Int64) { self.init(timeIntervalSince1970: Double(ms) / 1000) }
    var ms: Int64 { Int64(timeIntervalSince1970 * 1000) }

    var hm: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm"
        return f.string(from: self)
    }
    var monthDay: String {
        let c = Calendar.current.dateComponents([.month, .day], from: self)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
    var isToday: Bool { Calendar.current.isDateInToday(self) }
    /// "11월 6일 (목)"
    var dayLabel: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M월 d일 (E)"
        return f.string(from: self)
    }
    var fullLabel: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: self)
    }
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()
}
extension JSONEncoder {
    static let api: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }()
}


/// 서버에 저장된 다시 쓰기 진행 (GET /api/articles/:id/pass)
struct PassState: Codable, Hashable { var done: [String]; var updatedAt: Int64? }
/// 서버에 저장된 공부 세션 시작점 (GET /api/session-start)
struct SessionStartState: Codable, Hashable { var startedAt: Int64 }

// MARK: - 책갈피 (서버에 하나)

struct Bookmark: Codable, Hashable {
    var articleId: String
    var sentenceId: String
    var round: Int?
    var createdAt: Int64?
    var articleTitle: String?
    var sentenceIdx: Int?
    var sentenceText: String?

    /// "🔖 책갈피 · 기사 · n번째 문장 · (회차)"
    var line: String {
        var s = "🔖 책갈피 · \(articleTitle ?? "") · \((sentenceIdx ?? 0) + 1)번째 문장"
        if let r = round { s += " · \(r)회차" }
        return s
    }
}

// MARK: - 형광펜

struct HighlightAnswer: Codable, Hashable {
    var meaning: String
    var why: String
    var similar: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        similar = try c.decodeIfPresent(String.self, forKey: .similar) ?? ""
    }
    init(meaning: String, why: String, similar: String) { self.meaning = meaning; self.why = why; self.similar = similar }
}

struct Highlight: Codable, Identifiable, Hashable {
    var id: String
    var sentenceId: String
    var articleId: String
    var startWord: Int
    var endWord: Int
    var span: String
    var answer: HighlightAnswer
    var createdAt: Int64
    var note: String?          // 내 메모 (Claude 답과 별개)
    var links: [HighlightLink] = []
    var backlinks: [Backlink] = []

    init(id: String, sentenceId: String, articleId: String, startWord: Int, endWord: Int, span: String, answer: HighlightAnswer, createdAt: Int64, note: String? = nil) {
        self.id = id; self.sentenceId = sentenceId; self.articleId = articleId; self.startWord = startWord; self.endWord = endWord; self.span = span; self.answer = answer; self.createdAt = createdAt; self.note = note
    }
    enum CodingKeys: String, CodingKey { case id, sentenceId, articleId, startWord, endWord, span, answer, createdAt, note, links, backlinks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentenceId = try c.decode(String.self, forKey: .sentenceId)
        articleId = try c.decodeIfPresent(String.self, forKey: .articleId) ?? ""
        startWord = try c.decodeIfPresent(Int.self, forKey: .startWord) ?? 0
        endWord = try c.decodeIfPresent(Int.self, forKey: .endWord) ?? startWord
        span = try c.decodeIfPresent(String.self, forKey: .span) ?? ""
        answer = (try? c.decode(HighlightAnswer.self, forKey: .answer)) ?? HighlightAnswer(meaning: "", why: "", similar: "")
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
        links = (try? c.decodeIfPresent([HighlightLink].self, forKey: .links)) ?? []
        backlinks = (try? c.decodeIfPresent([Backlink].self, forKey: .backlinks)) ?? []
    }
    var hasAnswer: Bool { !answer.meaning.isEmpty }
}

// MARK: - 형광펜 엮기 (메모를 전에 본 형광펜/표현장 표현에 잇는다)

struct LinkTarget: Codable, Hashable { var toKind: String; var toId: String }

/// 엮을 후보 (GET /api/related)
struct Related: Codable, Identifiable, Hashable {
    var kind: String
    var id: String
    var text: String
    var note: String?
    var sentenceId: String?
    var articleId: String?
    var title: String?
    var createdAt: Int64?
    var key: String { "\(kind):\(id)" }
}

/// 이 형광펜에서 나가는 링크
struct HighlightLink: Codable, Identifiable, Hashable {
    var id: String
    var fromHighlight: String?
    var toKind: String
    var toId: String
    var createdAt: Int64?
    var text: String?
    var sentenceId: String?
    var articleId: String?
    var title: String?
    var key: String { "\(toKind):\(toId)" }
}

/// 거꾸로 링크: 다른 형광펜이 이것을 가리킨다
struct Backlink: Codable, Identifiable, Hashable {
    var id: String
    var toKind: String?
    var toId: String?
    var createdAt: Int64?
    var fromId: String
    var text: String?
    var note: String?
    var sentenceId: String?
    var articleId: String?
    var title: String?
}

/// POST /api/sentences/:id/ask 응답: Highlight & {phrase}
struct AskResult: Decodable {
    var highlight: Highlight
    var phrase: Phrase?
    enum CodingKeys: String, CodingKey { case phrase }
    init(from decoder: Decoder) throws {
        highlight = try Highlight(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrase = try c.decodeIfPresent(Phrase.self, forKey: .phrase)
    }
}

// MARK: - 응용 (표현을 거꾸로 쓰는 한→영 연습)

struct DrillIssue: Codable, Hashable {
    var mine: String
    var better: String
    var why: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mine = try c.decodeIfPresent(String.self, forKey: .mine) ?? ""
        better = try c.decodeIfPresent(String.self, forKey: .better) ?? ""
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
    }
}

struct DrillFeedback: Codable, Hashable {
    var grade: Grade
    var usedExpression: Bool
    var issues: [DrillIssue]
    var reference: String
    var referenceKo: String?     // 참고 영문의 한국어 뜻 한 줄 (예전 기록엔 없을 수 있다)
    var note: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grade = (try? c.decode(Grade.self, forKey: .grade)) ?? .C
        usedExpression = (try? c.decode(Bool.self, forKey: .usedExpression)) ?? (((try? c.decode(Int.self, forKey: .usedExpression)) ?? 0) != 0)
        issues = try c.decodeIfPresent([DrillIssue].self, forKey: .issues) ?? []
        reference = try c.decodeIfPresent(String.self, forKey: .reference) ?? ""
        referenceKo = try c.decodeIfPresent(String.self, forKey: .referenceKo)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
    /// "참고 영문 — 한국어 뜻"
    var referenceLine: String { reference + ((referenceKo ?? "").isEmpty ? "" : " — \(referenceKo!)") }
}

struct Drill: Codable, Identifiable, Hashable {
    var id: String
    var phraseId: String?
    var phrase: String
    var meaning: String
    var korean: String
    var createdAt: Int64
    var kind: String?          // "prompt"(한국어 문장 받아 쓰기) | "free"(자유 작문)
    var sentenceId: String?
    var isFree: Bool { kind == "free" }

    init(id: String, phraseId: String?, phrase: String, meaning: String, korean: String, createdAt: Int64, kind: String? = nil, sentenceId: String? = nil, answer: String? = nil, grade: Grade? = nil, feedback: DrillFeedback? = nil, answeredAt: Int64? = nil, reference: String? = nil) {
        self.id = id; self.phraseId = phraseId; self.phrase = phrase; self.meaning = meaning; self.korean = korean; self.createdAt = createdAt; self.kind = kind; self.sentenceId = sentenceId; self.answer = answer; self.grade = grade; self.feedback = feedback; self.answeredAt = answeredAt; self.reference = reference
    }
    enum CodingKeys: String, CodingKey { case id, phraseId, phrase, meaning, korean, createdAt, kind, sentenceId, answer, grade, feedback, answeredAt, reference }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        phraseId = try c.decodeIfPresent(String.self, forKey: .phraseId)
        phrase = try c.decodeIfPresent(String.self, forKey: .phrase) ?? ""
        meaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
        korean = try c.decodeIfPresent(String.self, forKey: .korean) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        sentenceId = try c.decodeIfPresent(String.self, forKey: .sentenceId)
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        grade = try? c.decodeIfPresent(Grade.self, forKey: .grade)
        feedback = try? c.decodeIfPresent(DrillFeedback.self, forKey: .feedback)
        answeredAt = try c.decodeIfPresent(Int64.self, forKey: .answeredAt)
        reference = try c.decodeIfPresent(String.self, forKey: .reference)
    }
    var answer: String?
    var grade: Grade?
    var feedback: DrillFeedback?
    var answeredAt: Int64?
    var reference: String?
}

// MARK: - 오프라인 내보내기 (GET /api/export)

struct ExportPayload: Decodable {
    struct Article: Decodable { var id: String; var title: String; var source: String?; var createdAt: Int64 }
    struct Sentence: Decodable { var id: String; var articleId: String; var idx: Int; var paragraph: Int?; var text: String }
    struct Attempt: Decodable { var id: String; var sentenceId: String; var articleId: String; var translation: String; var grade: Grade; var feedback: Feedback; var createdAt: Int64 }
    struct ReviewBody: Decodable { var summary: String?; var patterns: [ReviewPattern]?; var praise: String? }
    struct Review: Decodable { var id: String; var articleId: String; var score: Int?; var review: ReviewBody; var createdAt: Int64 }
    struct QuizResult: Decodable {
        var id: String; var key: String; var sentenceId: String; var source: String; var correct: Bool; var createdAt: Int64
        enum CodingKeys: String, CodingKey { case id, key, sentenceId, source, correct, createdAt }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); key = try c.decode(String.self, forKey: .key)
            sentenceId = try c.decodeIfPresent(String.self, forKey: .sentenceId) ?? ""
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            if let b = try? c.decode(Bool.self, forKey: .correct) { correct = b }
            else { correct = ((try? c.decode(Int.self, forKey: .correct)) ?? 0) != 0 }
            createdAt = try c.decode(Int64.self, forKey: .createdAt)
        }
    }
    var exportedAt: Int64
    var since: Int64
    var articles: [Article]
    var sentences: [Sentence]
    var attempts: [Attempt]
    var phrases: [Phrase]
    var reviews: [Review]
    var quizResults: [QuizResult]
    var sessions: [StudySession]
    var highlights: [Highlight]?
    var bookmark: BookmarkRow?
    var drills: [Drill]?          // 푼 것만, answered_at 기준 증분
    struct BookmarkRow: Decodable { var articleId: String; var sentenceId: String; var round: Int?; var createdAt: Int64? }
}
