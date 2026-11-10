import Foundation

/// "처음부터 다시 쓰기" 진행 상태. **서버(GET/PUT/DELETE /api/articles/:id/pass)가 진실**이고 여기(UserDefaults)는 캐시다.
struct RedoProgress: Codable, Equatable {
    var ids: [String]      // 다시 쓸 문장 순서
    var done: [String]     // 이번에 제출한 문장 id

    var remaining: [String] { ids.filter { !done.contains($0) } }

    private static func key(_ articleId: String) -> String { "lbn_redo_\(articleId)" }

    static func load(_ articleId: String) -> RedoProgress? {
        guard let d = UserDefaults.standard.data(forKey: key(articleId)) else { return nil }
        return try? JSONDecoder().decode(RedoProgress.self, from: d)
    }
    func save(_ articleId: String) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key(articleId)) }
    }
    static func clear(_ articleId: String) { UserDefaults.standard.removeObject(forKey: key(articleId)) }

    /// 서버 pass_done(제출한 id들)과 공책 문장 순서로 진행 상태를 만든다
    static func from(serverDone: [String], sentenceIds: [String]) -> RedoProgress {
        RedoProgress(ids: sentenceIds, done: sentenceIds.filter(serverDone.contains))
    }

    /// 저장이 없을 때의 추정: 문장 순서대로 "history가 있고 최신 attempt가 24시간 이내"인 앞쪽 연속 문장 수.
    /// 0 < n < 전체 이면 n을 돌려준다 (오늘 다시 쓴 n문장 다음부터 이어서)
    static func estimateRewritten(_ sentences: [Sentence]) -> Int? {
        let since = Date().ms - 24 * 3_600_000
        var n = 0
        for s in sentences {
            guard !s.history.isEmpty, let a = s.attempt, a.createdAt >= since else { break }
            n += 1
        }
        return n > 0 && n < sentences.count ? n : nil
    }
}
