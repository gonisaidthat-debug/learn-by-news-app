import Foundation

/// 응용 문제 로컬 보관: 미리 받아 둔 문제(pool), 오프라인에서 쓴 답(큐 drill_answer), 돌아온 채점 요약
@MainActor
final class DrillStore: ObservableObject {
    static let shared = DrillStore()
    private static let poolKey = "lbn_drill_pool"
    private static let setKey = "lbn_drill_set_size"
    private static let gradedKey = "lbn_drill_graded"

    /// 미리 받아 둔(아직 안 푼) 문제. 서버에 남아 있는 것과 같은 id
    @Published private(set) var pool: [Drill] = []
    /// 오프라인에서 답을 써 둔 문제 id → 답
    @Published private(set) var pendingAnswers: [String: String] = [:]
    /// 연결 뒤 채점돼 돌아온 결과 (요약 한 번 보여주고 지운다)
    @Published var graded: [Drill] = []
    /// 세트 크기 5/10/20 (기억)
    @Published var setSize: Int {
        didSet { UserDefaults.standard.set(setSize, forKey: Self.setKey) }
    }

    private init() {
        setSize = UserDefaults.standard.object(forKey: Self.setKey) as? Int ?? 10
        if let d = UserDefaults.standard.data(forKey: Self.poolKey), let p = try? JSONDecoder.api.decode([Drill].self, from: d) { pool = p }
        if let d = UserDefaults.standard.data(forKey: Self.gradedKey), let g = try? JSONDecoder.api.decode([Drill].self, from: d) { graded = g }
        pendingAnswers = Dictionary(uniqueKeysWithValues: Cache.shared.pending(kind: "drill_answer").compactMap { op -> (String, String)? in
            guard let b = try? JSONDecoder.api.decode(SyncManager.DrillAnswerOp.self, from: op.payload) else { return nil }
            return (b.id, b.answer)
        })
    }

    private func savePool() { UserDefaults.standard.set(try? JSONEncoder.api.encode(pool), forKey: Self.poolKey) }
    private func saveGraded() { UserDefaults.standard.set(try? JSONEncoder.api.encode(graded), forKey: Self.gradedKey) }

    /// 미리 받기: 서버가 안 푼 문제를 count개까지 채워 전부 돌려준다 → pool 교체
    func prefetch(count: Int) async throws -> Int {
        let r = try await API.shared.batchDrills(count: count)
        pool = r.drills.filter { $0.feedback == nil }
        savePool()
        AppLog.shared.info("drills", "prefetched", ["count": "\(pool.count)", "made": "\(r.made)"])
        return pool.count
    }
    /// 오프라인에서 낼 다음 문제: 아직 답을 안 쓴 것 중 첫 번째
    func nextOffline(excluding: String? = nil) -> Drill? {
        pool.first { pendingAnswers[$0.id] == nil && $0.id != excluding }
    }
    var remainingOffline: Int { pool.filter { pendingAnswers[$0.id] == nil }.count }

    /// 오프라인 답: 큐에 넣고 "채점 대기"로
    func answerOffline(_ d: Drill, answer: String) {
        pendingAnswers[d.id] = answer
        Cache.shared.enqueue("drill_answer", SyncManager.DrillAnswerOp(id: d.id, answer: answer, answeredAtLocal: Date().ms, phrase: d.phrase, korean: d.korean))
    }
    /// 연결 뒤 채점 결과가 돌아왔다
    func didGrade(_ d: Drill) {
        pendingAnswers[d.id] = nil
        pool.removeAll { $0.id == d.id }; savePool()
        graded.append(d); saveGraded()
    }
    func dropPending(_ id: String) { pendingAnswers[id] = nil; pool.removeAll { $0.id == id }; savePool() }
    func clearGraded() { graded = []; saveGraded() }
    func remove(_ id: String) { pool.removeAll { $0.id == id }; savePool() }
}

/// 세트·채점 요약 계산 (웹과 동일: 등급 평균 A100 B80 C50 D20)
enum DrillSummary {
    static func score(_ ds: [Drill]) -> Int? {
        let pts = ds.compactMap { $0.grade.flatMap { Grade.points[$0] } }
        guard !pts.isEmpty else { return nil }
        return Int((Double(pts.reduce(0, +)) / Double(pts.count)).rounded())
    }
    static func used(_ ds: [Drill]) -> Int { ds.filter { $0.feedback?.usedExpression == true }.count }
    static func counts(_ ds: [Drill]) -> [Grade: Int] {
        var c: [Grade: Int] = [:]
        for d in ds { if let g = d.grade { c[g, default: 0] += 1 } }
        return c
    }
}
