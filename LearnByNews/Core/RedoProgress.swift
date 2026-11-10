import Foundation

/// "처음부터 다시 쓰기" 진행 상태. 공책별로 UserDefaults에 저장해 화면을 벗어났다 와도 그 자리에서 잇는다.
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
