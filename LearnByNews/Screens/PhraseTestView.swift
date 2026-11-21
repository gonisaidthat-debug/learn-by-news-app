import SwiftUI

/// 표현장 시험 (웹 PhraseTest.tsx, goni 2026-11-18). 방식 셋(웹 50680bb·71126bc):
/// - 표현 쓰기: 뜻 → 영어 표현. Enter로 확인 — 소문자·구두점·공백·앞의 to/a/an/the 무시하고 같으면 바로 "맞았다 ○"(기록), 아니면 답 포스트잇 + 내 답(취소선) + 스스로 ○/×. key "pr|<id>"
/// - 뜻 쓰기: 표현 → 한국어 뜻. Enter로 확인 — 저장된 뜻과 느슨하게 비교(meaningHit)해 비슷하면 바로 "맞았다 ○"(기록) + "사실 몰랐다 ×", 아니면 답 공개 → 알았다/몰랐다. key "pm|<id>", 기록·순서도 그 기록(m_*)으로
/// - 고급 ✎: 뜻만 보고 그 표현으로 내 문장 하나(영어) → POST /api/drills/free(멈추기 가능) → 결과를 써 보기 상자처럼. used_expression && A·B면 맞았다, 아니면 몰랐다 → key "pr|<id>"로 기록
/// 순서는 시험지와 같이 안 본 것 → 틀린 것 → 맞힌 것. 묶음 아직/습득 완료/전체(기억). 습득 완료 묶음을 고르면 고급이 기본. 오프라인이면 캐시 표현으로 카드, 결과는 큐
/// 시험지가 기본(goni 2026-11-21, 웹 a0bc6f3): 문제 수 10·20·50·전부(기억, 기본 20) → 거른 뒤 순서대로 앞에서 n개. 시험지 | 카드 토글(기억; 고급은 카드만).
/// 시험지는 `PhraseSheet`(한 장에 다 쓰고 한 번에 채점). 카드도 끝나면 "몰랐던 것 n" 목록 + "몰랐던 것만 다시 ↻"(그 id들만으로 새 시험)
@MainActor
final class PhraseTestModel: ObservableObject {
    enum Reveal { case right, wrong, shown }   // shown: 뜻 쓰기에서 답만 공개(스스로 ○/×)
    /// 묶음: 아직(습득 완료 아닌 것, 기본) / 습득 완료 / 전체 — 선택은 기기에 기억 (goni 2026-11-18, 웹 49a6eb3)
    enum Bucket: String, CaseIterable { case pending, mastered, all }
    enum Mode: String, CaseIterable { case write, meaning, advanced }
    @Published var all: [PhraseTestItem]?
    @Published var bucket: Bucket = Bucket(rawValue: UserDefaults.standard.string(forKey: "lbn_phrase_test_bucket") ?? "") ?? .pending {
        didSet { UserDefaults.standard.set(bucket.rawValue, forKey: "lbn_phrase_test_bucket") }
    }
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "lbn_phrase_test_mode") ?? "") ?? .write {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "lbn_phrase_test_mode") }
    }
    /// 문제 수 (goni 2026-11-21 "문제 수도 정할 수 있게"): 0 = 전부. 기억, 기본 20
    static let counts = [10, 20, 50, 0]
    @Published var count: Int = UserDefaults.standard.object(forKey: "lbn_phrase_test_count").flatMap { $0 as? Int } ?? 20 {
        didSet { UserDefaults.standard.set(count, forKey: "lbn_phrase_test_count") }
    }
    /// 시험지(한 장에 다 쓰고 채점, 기본) / 카드(한 문제씩). 고급은 Claude 채점이라 카드만
    enum Layout: String { case sheet, card }
    @Published var layout: Layout = UserDefaults.standard.string(forKey: "lbn_phrase_test_layout") == "card" ? .card : .sheet {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "lbn_phrase_test_layout") }
    }
    var useSheet: Bool { layout == .sheet && mode != .advanced }
    /// "몰랐던 것만 다시 ↻": 그 id들만으로 (restart()는 지운다)
    @Published var only: Set<String>?
    /// 카드 방식에서 몰랐던 것 (결과 화면 목록 + 몰랐던 것만 다시)
    @Published var wrongs: [PhraseTestItem] = []
    /// 시험지를 새로 깔 때 올린다 (PhraseSheet의 @State를 비우려고 .id로)
    @Published var seed = 0
    /// 번호 범위(붙인 순서 seq). nil이면 전부. 묶음 필터와 겹쳐 적용 (goni 2026-11-18)
    @Published var range: ClosedRange<Int>? = RangePick.load("lbn_phrase_test_range") { didSet { RangePick.save(range, "lbn_phrase_test_range") } }
    var maxSeq: Int { (all ?? []).compactMap(\.seq).max() ?? 0 }
    /// 별 개수 필터(goni 2026-11-19 "별 갯수 필터링도"): 0 = 전부, 1~3 = 그 개수 이상. 묶음·범위와 ∩. 기억
    @Published var minStars: Int = UserDefaults.standard.integer(forKey: "lbn_phrase_test_stars") { didSet { UserDefaults.standard.set(minStars, forKey: "lbn_phrase_test_stars") } }
    /// 묶음·범위 안에서 별이 n개 이상인 수 (필터 버튼의 n)
    func starCount(_ n: Int) -> Int { basePool().filter { $0.stars >= n }.count }
    private func basePool() -> [PhraseTestItem] {
        (all ?? []).filter { self.bucket == .all || ($0.isMastered == (self.bucket == .mastered)) }
            .filter { it in range.map { r in it.seq.map(r.contains) ?? false } ?? true }
    }
    @Published var revokedPrev: String?   // 바로 앞 카드에서 몰랐다고 해 습득 완료가 취소된 표현 → 다음 카드 위 한 줄
    @Published var items: [PhraseTestItem] = []
    @Published var i = 0
    @Published var answer = ""
    @Published var hint = false
    @Published var revealed: Reveal?
    @Published var right = 0
    @Published var wrong = 0
    @Published var mastered: Set<String> = []
    @Published var err: String?
    // 고급: 자유 작문 채점
    @Published var grading = false
    @Published var drill: Drill?           // 채점 결과
    @Published var drillQueued = false     // 끊겨서 큐에 남았다(판정 없음)
    private var gradingTask: Task<Void, Never>?
    private var drillId: String?

    var current: PhraseTestItem? { i < items.count ? items[i] : nil }
    var done: Bool { all != nil && i >= items.count }
    func lastCorrect(_ it: PhraseTestItem) -> Bool? { mode == .meaning ? it.mLastCorrect : it.lastCorrect }
    func lastAt(_ it: PhraseTestItem) -> Int64? { mode == .meaning ? it.mLastAt : it.lastAt }
    func tries(_ it: PhraseTestItem) -> (n: Int, wrong: Int) { mode == .meaning ? (it.mTries ?? 0, it.mWrong ?? 0) : (it.tries, it.wrong) }
    func key(_ it: PhraseTestItem) -> String { mode == .meaning ? it.meaningKey : it.key }
    var fresh: Int { items.filter { lastCorrect($0) == nil }.count }
    var missed: Int { items.filter { lastCorrect($0) == false }.count }
    var pendingCount: Int { (all ?? []).filter { !$0.isMastered }.count }
    var masteredCount: Int { (all ?? []).filter(\.isMastered).count }

    func load() async {
        if all == nil, let c = Cache.shared.phraseTest() { all = c; rebuild() }
        do { all = try await API.shared.phraseTest(); rebuild(); err = nil }
        catch let e as APIError where e.isNetwork { if all == nil { err = e.localizedDescription } }
        catch { err = error.localizedDescription }
    }
    /// 안 본 것 → 틀린 것 → 맞힌 것(오래된 순). 같은 묶음 안에서는 섞는다 (시험지와 같은 규칙). 뜻 쓰기는 m_* 기록으로
    private func rebuild() {
        func rank(_ it: PhraseTestItem) -> Int { lastCorrect(it) == nil ? 0 : (lastCorrect(it)! ? 2 : 1) }
        let pool = basePool().filter { $0.stars >= minStars }.filter { it in only.map { $0.contains(it.id) } ?? true }
        // 같은 묶음 안에서는 별 많은 것부터, 그다음 오래된 순 (중요도 별, 2026-11-19). 문제 수만큼 앞에서
        let sorted = pool.shuffled().sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if a.stars != b.stars { return a.stars > b.stars }
            return (lastAt(a) ?? 0) < (lastAt(b) ?? 0)
        }
        items = count > 0 ? Array(sorted.prefix(count)) : sorted
    }
    func restart() { restart(only: nil) }
    /// only가 있으면 그 id들만으로 (몰랐던 것만 다시)
    func restart(only o: Set<String>?) { only = o; wrongs = []; seed += 1; i = 0; right = 0; wrong = 0; revokedPrev = nil; resetCard(); rebuild() }
    func restart(count n: Int) { count = n; restart() }
    func restart(layout l: Layout) { layout = l; restart() }
    /// 서버가 몰랐다 기록으로 습득 완료를 뗐다 → 목록에도 반영
    func applyRevoked(_ id: String) {
        if let j = all?.firstIndex(where: { $0.id == id }) { all?[j].masteredAt = nil }
        if let j = items.firstIndex(where: { $0.id == id }) { items[j].masteredAt = nil }
    }
    /// 습득 완료 묶음을 고르면 고급이 기본 ("습득 완료는 더 고급 시험으로 자유자재로 쓸 수 있는지"). 다른 묶음에서도 켤 수 있다
    func restart(_ b: Bucket) { bucket = b; if b == .mastered { mode = .advanced }; restart() }
    func restart(_ m: Mode) { mode = m; restart() }
    func restart(stars n: Int) { minStars = n; restart() }
    func next() { i += 1; resetCard() }
    private func resetCard() { answer = ""; hint = false; revealed = nil; drill = nil; drillQueued = false; grading = false; gradingTask = nil; drillId = nil }

    /// 비교용: 소문자, 구두점 제거, 공백 정리, 앞의 to/a/an/the 떼기 (웹 norm과 같다)
    static func norm(_ t: String) -> String {
        var w = t.lowercased().replacingOccurrences(of: "’", with: "'")
        w = String(w.map { ($0.isLetter && $0.isASCII) || ($0.isNumber && $0.isASCII) || $0 == "'" || $0 == " " ? $0 : " " })
        w = w.split(separator: " ").joined(separator: " ")
        for art in ["to ", "a ", "an ", "the "] where w.hasPrefix(art) { w = String(w.dropFirst(art.count)); break }
        return w
    }
    /// 뜻 비교 (goni 2026-11-21 "채점이 바로바로 되는 게 아닌가", 웹 meaningHit과 같다): 한글 뜻은 말이 달라도 같을 수 있어 완전 일치는 못 본다.
    /// 소문자화, 괄호 속 제거, 한글·영문·숫자 외 전부 제거 → 저장된 뜻을 , ， · ; / 또는 " 또는 "으로 쪼갠 갈래(2글자 이상) 중 하나가 내 답에 들어 있거나
    /// 내 답이 그 갈래에 들어 있으면(내 답 2글자 이상), 또는 공통 앞부분 ≥ max(3, min(두 길이) − 2)이면(어미만 다른 것) 맞음
    static func meaningHit(_ answer: String, _ meaning: String) -> Bool {
        func nz(_ t: String) -> [Character] {
            let noParen = t.lowercased().replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
            return noParen.filter { c in
                guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
                return (0xAC00...0xD7A3).contains(u.value) || (c.isLetter && c.isASCII) || (c.isNumber && c.isASCII)
            }.map { $0 }
        }
        let a = nz(answer)
        guard a.count >= 2 else { return false }
        let parts = meaning.replacingOccurrences(of: " 또는 ", with: ",")
            .split(whereSeparator: { ",，·;/".contains($0) }).map { nz(String($0)) }.filter { $0.count >= 2 }
        func prefix(_ x: [Character], _ y: [Character]) -> Int { var i = 0; while i < x.count, i < y.count, x[i] == y[i] { i += 1 }; return i }
        func contains(_ hay: [Character], _ needle: [Character]) -> Bool { String(hay).contains(String(needle)) }
        return parts.contains { x in contains(a, x) || contains(x, a) || prefix(a, x) >= max(3, min(a.count, x.count) - 2) }
    }
    /// Enter: 표현 쓰기는 맞으면 바로 기록, 아니면 답 공개 후 ○/× 대기. 뜻 쓰기는 비슷하면 바로 기록, 아니면 답 공개 후 ○/×. 고급은 자유 작문 채점
    func check() {
        guard let it = current, revealed == nil, !grading else { return }
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        switch mode {
        case .write:
            if Self.norm(a) == Self.norm(it.phrase) { revealed = .right; right += 1; record(it, true) } else { revealed = .wrong }
        case .meaning:
            if Self.meaningHit(a, it.meaning) { revealed = .right; right += 1; record(it, true) } else { revealed = .shown }
        case .advanced:
            submitFree(it, a)
        }
    }
    /// 뜻 쓰기에서 글자가 비슷해 맞음으로 쳤지만 사실 몰랐다: 맞음을 빼고 몰랐다로 다시 기록(도장 뗌 반영) → 다음 카드
    func unhit() {
        guard let it = current, mode == .meaning, revealed == .right else { return }
        right -= 1; wrong += 1
        revokedPrev = nil
        record(it, false); next()
    }
    func giveUp() { if current != nil, revealed == nil, !grading { revealed = mode == .meaning ? .shown : .wrong } }
    /// 스스로 매기기(표현 쓰기 틀렸을 때·뜻 쓰기). 습득 완료 카드에서 몰랐다고 하면 서버가 도장을 뗀다(revoked) → 다음 카드 위에 한 줄
    func mark(_ correct: Bool) {
        guard let it = current, revealed == .wrong || revealed == .shown else { return }
        if correct { right += 1 } else { wrong += 1 }
        revokedPrev = nil
        record(it, correct); next()
    }
    private func record(_ it: PhraseTestItem, _ correct: Bool) {
        if !correct, !wrongs.contains(where: { $0.id == it.id }) { wrongs.append(it) }
        Task {
            if try await recordAnswer(it, correct) { revokedPrev = it.phrase }
        }
    }
    /// 기록(카드·시험지 공용): 캐시 → 서버(오프라인이면 큐). 돌려주는 값: 습득 완료가 떨어졌는지 (목록에 반영한 뒤)
    @discardableResult
    func recordAnswer(_ it: PhraseTestItem, _ correct: Bool) async throws -> Bool {
        let k = key(it)
        AppLog.shared.info("phrasetest", correct ? "right" : "wrong", ["key": k, "mode": mode.rawValue, "layout": useSheet ? "sheet" : "card"])
        do {
            let revoked = try await SyncManager.shared.answerQuiz(key: k, sentenceId: it.sentenceId ?? "", source: it.phrase, correct: correct)
            if revoked { applyRevoked(it.id) }
            return revoked
        } catch { err = error.localizedDescription; throw error }
    }
    /// 고급: 뜻만 보고 쓴 내 문장을 자유 작문으로 채점 → used_expression && A·B면 맞았다, 아니면 몰랐다. 쓴 문장은 응용(free)에 남는다
    private func submitFree(_ it: PhraseTestItem, _ a: String) {
        let did = UUID().uuidString.lowercased()
        drillId = did; grading = true; err = nil
        let body = API.DrillFreeBody(phrase: it.phrase, meaning: it.meaning, phraseId: it.id, sentenceId: it.sentenceId, answer: a, drillId: did)
        gradingTask = Task {
            do {
                let d = try await SyncManager.shared.freeDrill(body)
                guard drillId == did else { return }   // 멈춤
                grading = false
                if let d, let fb = d.feedback {
                    drill = d
                    let ok = fb.usedExpression && (fb.grade == .A || fb.grade == .B)
                    revealed = ok ? .right : .wrong
                    if ok { right += 1 } else { wrong += 1 }
                    revokedPrev = nil
                    record(it, ok)
                } else { drillQueued = true; revealed = .shown }   // 끊겨서 큐에 남음: 판정 없이 다음으로
            } catch {
                guard drillId == did else { return }
                grading = false; err = error.localizedDescription
            }
        }
    }
    /// 멈추기: 요청 취소 + 서버 취소(DELETE drills/:id/grading). 쓰던 문장은 그대로
    func stop() {
        guard grading, let did = drillId else { return }
        drillId = nil; gradingTask?.cancel(); gradingTask = nil; grading = false
        AppLog.shared.info("phrasetest", "stop", ["id": did])
        Task { await SyncManager.shared.stopDrillGrading(id: did) }
    }
    /// 카드에서 중요도 별
    func setWeight(_ w: Int) async {
        guard let it = current else { return }
        do {
            let saved = try await SyncManager.shared.setWeight(it.id, weight: w)
            if let j = all?.firstIndex(where: { $0.id == it.id }) { all?[j].weight = saved }
            if let j = items.firstIndex(where: { $0.id == it.id }) { items[j].weight = saved }
        } catch { err = error.localizedDescription }
    }
    /// 맞힌 김에 습득 완료 (표현장에 남고 응용·시험에서 빠진다)
    func master() async {
        guard let it = current else { return }
        do { _ = try await SyncManager.shared.setMastered(it.id, on: true); mastered.insert(it.id) } catch { err = error.localizedDescription }
    }
}

struct PhraseTestView: View {
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = PhraseTestModel()
    @ObservedObject private var session = SessionModel.shared   // 고급(문장 쓰기, 세션에 셈)은 공부 시작 전엔 StartGate
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NotebookHead(tab: m.useSheet ? "\(m.items.count)문제" : "\(min(m.i + 1, m.items.count)) / \(m.items.count)") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("표현장 시험")
                            Tiny(title: "←\u{FE0E} 표현장", size: 17) { dismiss() }
                        }
                        HStack(spacing: 10) {
                            ForEach(PhraseTestModel.Bucket.allCases, id: \.self) { b in
                                let label = b == .pending ? "아직 \(m.pendingCount)" : b == .mastered ? "습득 완료 \(m.masteredCount)" : "전체"
                                Tiny(title: label, color: m.bucket == b ? Theme.ink : Theme.pencil, size: 19) { m.restart(b); focused = true }
                                    .overlay(alignment: .bottom) { if m.bucket == b { Rectangle().fill(Theme.red).frame(height: 2) } }
                            }
                        }
                        RangePick(range: $m.range, max: m.maxSeq).onChange(of: m.range) { _, _ in m.restart(); focused = true }
                        HStack(spacing: 10) {   // 별 개수 이상 필터
                            ForEach(0...3, id: \.self) { n in
                                let label = n == 0 ? "별 전부" : String(repeating: "★", count: n) + (n < 3 ? "+" : "") + " \(m.starCount(n))"
                                Tiny(title: label, color: m.minStars == n ? (n > 0 ? StarRow.yellow : Theme.ink) : Theme.pencil, size: 18) { m.restart(stars: n); focused = true }
                                    .overlay(alignment: .bottom) { if m.minStars == n { Rectangle().fill(Theme.red).frame(height: 2) } }
                            }
                        }
                        HStack(spacing: 10) {
                            ForEach(PhraseTestModel.Mode.allCases, id: \.self) { md in
                                let label = md == .write ? "표현 쓰기" : md == .meaning ? "뜻 쓰기" : "고급 ✎\u{FE0E}"
                                Tiny(title: label, color: m.mode == md ? Theme.ink : Theme.pencil, size: 19) { m.restart(md); focused = true }
                                    .overlay(alignment: .bottom) { if m.mode == md { Rectangle().fill(Theme.red).frame(height: 2) } }
                            }
                        }
                        FlowLayout(spacing: 10) {   // 문제 수 · 시험지/카드 (goni 2026-11-21)
                            Text("문제").font(Theme.hand(17)).foregroundStyle(Theme.pencil)
                            ForEach(PhraseTestModel.counts, id: \.self) { n in
                                Tiny(title: n == 0 ? "전부" : "\(n)", color: m.count == n ? Theme.ink : Theme.pencil, size: 18) { m.restart(count: n); focused = true }
                                    .overlay(alignment: .bottom) { if m.count == n { Rectangle().fill(Theme.red).frame(height: 2) } }
                            }
                            if m.mode != .advanced {
                                Text("|").font(Theme.hand(17)).foregroundStyle(Theme.pencil.opacity(0.5)).padding(.horizontal, 2)
                                Tiny(title: "시험지", color: m.layout == .sheet ? Theme.ink : Theme.pencil, size: 18) { m.restart(layout: .sheet) }
                                    .overlay(alignment: .bottom) { if m.layout == .sheet { Rectangle().fill(Theme.red).frame(height: 2) } }
                                    .help("한 장에 다 쓰고 한 번에 채점")
                                Tiny(title: "카드", color: m.layout == .card ? Theme.ink : Theme.pencil, size: 18) { m.restart(layout: .card); focused = true }
                                    .overlay(alignment: .bottom) { if m.layout == .card { Rectangle().fill(Theme.red).frame(height: 2) } }
                                    .help("한 문제씩")
                            }
                        }
                    }
                }
                .id("test-top")
                Paper { paper(scrollTop: { withAnimation { proxy.scrollTo("test-top", anchor: .top) } }) }
            }
            .padding(EdgeInsets(top: 14, leading: 10, bottom: 40, trailing: 10))
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.desk.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if m.all == nil { await m.load() }
            focused = true
            #if DEBUG
            // 화면 확인용: LBN_TESTBUCKET·LBN_TESTMODE로 묶음·방식, LBN_TESTANSWER=right|wrong|wrongmark 이면 첫 카드에 답을 넣고 확인한다
            if let b = ProcessInfo.processInfo.environment["LBN_TESTBUCKET"].flatMap(PhraseTestModel.Bucket.init(rawValue:)) { m.restart(b) }
            if let r = ProcessInfo.processInfo.environment["LBN_RANGE"] { let p = r.split(separator: "-").compactMap { Int($0) }; if p.count == 2 { m.range = p[0]...p[1]; m.restart() } }
            if let md = ProcessInfo.processInfo.environment["LBN_TESTMODE"].flatMap(PhraseTestModel.Mode.init(rawValue:)) { m.restart(md) }
            // LBN_TESTLAYOUT=sheet|card. LBN_TESTANSWER(카드 확인용)가 있으면 카드로
            if let l = ProcessInfo.processInfo.environment["LBN_TESTLAYOUT"].flatMap(PhraseTestModel.Layout.init(rawValue:)) { m.restart(layout: l) }
            else if ProcessInfo.processInfo.environment["LBN_TESTANSWER"] != nil, m.layout != .card { m.restart(layout: .card) }
            if let v = ProcessInfo.processInfo.environment["LBN_TESTANSWER"], let it = m.current {
                switch m.mode {
                case .write: m.answer = v == "right" ? it.phrase : "keep the rate"
                case .meaning: m.answer = v == "wrong" ? "금리를 올리다" : String(it.meaning.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression).split(whereSeparator: { ",，·;/".contains($0) }).first ?? "").trimmingCharacters(in: .whitespaces).dropLast(1) + "는"   // 어미만 다르게
                case .advanced: m.answer = v == "right" ? "The central bank decided to \(it.phrase) this quarter." : "The bank kept everything as it was."
                }
                m.check()
                if v == "wrongmark" { m.mark(false) }   // 몰랐다까지 → 다음 카드 위 "⟲ 앞 표현…" 확인용
                if v == "unhit" { m.unhit() }           // 뜻 쓰기: 맞은 뒤 "사실 몰랐다 ×"까지
            }
            #endif
        }
        .refreshable { await m.load(); m.restart() }
        }
    }

    @ViewBuilder
    private func paper(scrollTop: @escaping () -> Void) -> some View {
        if let e = m.err, m.all == nil {
            Entry { ErrorText(message: e) }
        } else if m.all == nil {
            Entry { Text("…").pencil() }
        } else if m.items.isEmpty {
            Entry {
                Text("시험 볼 표현이 없다").font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
                Text(m.minStars > 0 ? "이 별 개수 이상인 표현이 이 묶음·범위에 없다." : m.range != nil ? "이 번호 범위에 시험 볼 표현이 없다." : m.bucket == .mastered ? "습득 완료 도장이 찍힌 표현이 없다." : "표현장에 붙은 표현이 문제가 된다.").pencil()
            }
        } else if m.useSheet {
            PhraseSheet(m: m, items: m.items, meaning: m.mode == .meaning, onGraded: scrollTop, onRestart: { ids in m.restart(only: ids) })
                .id("\(m.seed)-\(m.mode.rawValue)")
        } else if m.done {
            Entry {
                ScoreLine(right: m.right, total: m.right + m.wrong, sub: "맞았다 \(m.right) · 몰랐다 \(m.wrong)")
                if !m.wrongs.isEmpty {   // 카드 방식도 끝나면 몰랐던 것 목록 (goni 2026-11-21 "다 끝나면 전체 시험지처럼 결과도")
                    Text("몰랐던 것 \(m.wrongs.count)").font(Theme.hand(20)).foregroundStyle(Theme.pencil).frame(height: Theme.lh)
                    ForEach(m.wrongs) { w in (Text(w.phrase).font(Theme.print(15)) + Text(" — \(w.meaning)")).pencil() }
                }
                FlowLayout(spacing: 16, rowSpacing: 0) {
                    Tiny(title: "다시 풀기 ↻\u{FE0E}") { m.restart(); focused = true }.frame(height: Theme.lh)
                    if !m.wrongs.isEmpty { Tiny(title: "몰랐던 것만 다시 ↻\u{FE0E}") { m.restart(only: Set(m.wrongs.map(\.id))); focused = true }.frame(height: Theme.lh) }
                }
                .padding(.top, 8)
            }
        } else if let it = m.current {
            Entry(stamp: AnyView(m.drill?.feedback.map { AnyView(Stamp(kind: .grade($0.grade))) } ?? AnyView(Stamp(kind: .pin)))) {
                if let rp = m.revokedPrev { Text("⟲\u{FE0E} 앞 표현(\(rp))의 습득 완료를 취소했다").font(Theme.hand(18)).foregroundStyle(Theme.red) }
                HStack(spacing: 8) {   // 오른쪽 위: 중요도 별 + 붙인 순서 번호
                    Spacer(minLength: 0)
                    StarRow(stars: it.stars, size: 14) { w in Task { await m.setWeight(w) } }
                    if let n = it.seq { Text("#\(n)").font(Theme.hand(15)).foregroundStyle(Theme.pencil) }
                }
                .frame(height: 18)
                // 문제
                switch m.mode {
                case .write:
                    Text(it.meaning.isEmpty ? "(뜻 없음)" : it.meaning).handLine(size: 25, color: Theme.ink)
                    Text("이 뜻의 영어 표현은?").pencil()
                    if let t = it.sentenceText, !t.isEmpty, m.hint || m.revealed != nil {
                        (m.revealed != nil ? Text(markSource(t, it.phrase)) : blankText(t, it.phrase)).enLine()
                    }
                case .meaning:
                    Text(it.phrase).font(Theme.hand(26)).fontWeight(.bold).foregroundStyle(Theme.ink)
                    Text("무슨 뜻?").pencil()
                    if let t = it.sentenceText, !t.isEmpty, m.hint || m.revealed != nil { Text(markSource(t, it.phrase)).enLine() }
                case .advanced:
                    Text(it.meaning.isEmpty ? "(뜻 없음)" : it.meaning).handLine(size: 25, color: Theme.ink)
                    Text("이 뜻의 표현으로 내 문장 하나 (영어)").pencil()
                    if m.hint, m.revealed == nil { (Text("표현 ").font(Theme.hand(17)) + Text(it.phrase).fontWeight(.bold)).pencil() }
                }
                // 입력 / 결과
                if m.revealed == nil, m.mode == .advanced, !session.inSession {
                    StartGate { focused = true }
                } else if m.revealed == nil {
                    TextField(m.mode == .meaning ? "한국어로 쓰고 Enter" : m.grading ? "채점 중…" : "영어로 쓰고 Enter", text: $m.answer, axis: .vertical)
                        .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                        .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                        .textInputAutocapitalization(m.mode == .meaning ? .sentences : .never).autocorrectionDisabled()
                        .focused($focused).disabled(m.grading).opacity(m.grading ? 0.55 : 1)
                        .onChange(of: m.answer) { _, v in
                            if v.contains("\n") { m.answer = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces); m.check() }
                        }
                    if m.grading { HStack(spacing: 14) { Text("선생님이 보는 중… ✎\u{FE0E}").pencil(); Tiny(title: "멈추기 ↩\u{FE0E}") { m.stop(); focused = true } } }
                } else {
                    if let d = m.drill, let fb = d.feedback {
                        // 고급: 써 보기 상자와 같은 결과
                        Text(d.answer ?? m.answer).koLine()
                        if fb.usedExpression { Text("✓\u{FE0E} \"\(it.phrase)\" 사용").handLine(size: 21, color: Theme.grade(.A)) }
                        else { Text("✗\u{FE0E} \"\(it.phrase)\"를 쓰지 않았다").redpen(size: 21) }
                        ForEach(Array(fb.issues.enumerated()), id: \.offset) { _, i in
                            (Text(i.mine).strikethrough(true, color: Theme.red) + Text(" →\u{FE0E} \(i.better)") + Text(i.why.isEmpty ? "" : " (\(i.why))").font(Theme.hand(18)).foregroundColor(Color(hex: 0xC0565A))).redpen(size: 21)
                        }
                        if !fb.reference.isEmpty { (Text("참고 ").font(Theme.hand(17)) + Text(fb.referenceLine)).pencil(size: 21) }
                        if !fb.note.isEmpty { Text(fb.note).pencil(size: 21) }
                        Text(m.revealed == .right ? "○\u{FE0E} 맞았다 — 표현을 써서 A·B" : "✗\u{FE0E} 몰랐다 — 표현을 안 썼거나 C·D").handLine(size: 20, color: m.revealed == .right ? Theme.grade(.A) : Theme.red)
                    } else if m.drillQueued {
                        Text(m.answer).koLine()
                        Text("연결되면 채점 · 큐에 저장됨 (판정은 생략)").pencil(size: 20)
                    } else if !m.answer.isEmpty {
                        if m.revealed == .right { Text("○\u{FE0E} \(m.answer)").handLine(size: 22, color: Theme.grade(.A)) }
                        else if m.revealed == .shown { Text(m.answer).koLine() }
                        else { (Text("✗\u{FE0E} ") + Text(m.answer).strikethrough(true, color: Theme.red)).handLine(size: 22, color: Theme.red) }
                    }
                    Sticky(phrase: it.phrase, meaning: it.meaning, index: 0, mastered: m.mastered.contains(it.id), note: it.note).padding(.vertical, 10)
                    if let aid = it.articleId, !aid.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            (Text("출처 ").font(Theme.hand(17)) + Text("\(it.articleTitle ?? "")" + (it.sentenceIdx.map { " · \($0 + 1)번째 문장" } ?? ""))).pencil()
                            Tiny(title: "공책에서 보기 →\u{FE0E}") { router.open(.notebook(id: aid, focus: it.sentenceId)) }
                        }
                    }
                    let t = m.tries(it)
                    if t.n > 0 { (Text("기록 ").font(Theme.hand(17)) + Text("\(t.n)번 중 \(t.wrong)번 몰랐음")).pencil() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 18) {
                    if m.revealed == nil {
                        if !m.grading {
                            if m.mode == .advanced { if !m.hint { Tiny(title: "표현 보기") { m.hint = true; focused = true } } }
                            else if let t = it.sentenceText, !t.isEmpty, !m.hint { Tiny(title: "문장 힌트") { m.hint = true; focused = true } }
                            if m.mode != .advanced { Tiny(title: m.mode == .meaning ? "답 보기" : "모르겠다 · 답 보기") { m.giveUp() } }
                            MutedText(text: "Enter로 \(m.mode == .advanced ? "채점" : "확인") · 안 본 것 \(m.fresh) · 틀렸던 것 \(m.missed)")
                        }
                    } else if m.drill != nil || m.drillQueued {
                        Tiny(title: "다음 ↵\u{FE0E}", color: m.revealed == .right ? Theme.grade(.A) : Theme.red) { m.next(); focused = true }.keyboardShortcut(.return, modifiers: [])
                        if m.revealed == .right, !m.mastered.contains(it.id), !it.isMastered { Tiny(title: "습득 완료 ✓\u{FE0E}") { Task { await m.master() } } }
                        if m.revealed == .wrong, it.isMastered { MutedText(text: "도장 뗌") }
                    } else if m.revealed == .right {
                        Tiny(title: "맞았다 ○ · 다음 ↵\u{FE0E}", color: Theme.grade(.A)) { m.next(); focused = true }.keyboardShortcut(.return, modifiers: [])
                        if m.mode == .meaning { Tiny(title: "사실 몰랐다 ×", color: Theme.red) { m.unhit(); focused = true }.help("글자가 비슷해서 맞음으로 쳤지만 사실은 몰랐다 → 몰랐다로 기록") }
                        if m.mastered.contains(it.id) { MutedText(text: "습득 완료로 찍었다") }
                        else { Tiny(title: "습득 완료 ✓\u{FE0E}") { Task { await m.master() } }.help("다 익혔다. 표현장에 남고 응용·시험에서 빠진다") }
                    } else {
                        Tiny(title: m.revealed == .shown ? "알았다 ○" : "그래도 알았다 ○", color: Theme.grade(.A)) { m.mark(true); focused = true }.keyboardShortcut("1", modifiers: [])
                        Tiny(title: it.isMastered ? "몰랐다 × · 도장 뗌" : "몰랐다 ×", color: Theme.red) { m.mark(false); focused = true }.keyboardShortcut("2", modifiers: [])
                    }
                }
                if let e = m.err { ErrorText(message: e) }
            }
            .frame(minHeight: Theme.lh).padding(.top, Theme.lh)
            .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
        }
    }
}


/// 원문에서 그 표현만 빈칸으로 (대소문자 무시). 없으면 원문 그대로 (카드·시험지 공용)
func blankText(_ text: String, _ phrase: String) -> Text {
    guard !phrase.isEmpty, let r = text.range(of: phrase, options: .caseInsensitive) else { return Text(text) }
    let n = max(6, min(18, phrase.count))
    return Text(text[..<r.lowerBound]) + Text(String(repeating: "_", count: n)).foregroundColor(Theme.red) + Text(text[r.upperBound...])
}

/// 점수: 빨간 타원 "맞음 / 전체" + 작은 설명 (표현장 시험 결과·시험지 머리)
struct ScoreLine: View {
    var right: Int
    var total: Int
    var sub: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("\(right) / \(total)")
                .font(Theme.hand(56)).foregroundStyle(Theme.red)
                .padding(.horizontal, 14).padding(.vertical, 2)
                .overlay(Ellipse().strokeBorder(Theme.red, lineWidth: 3)).rotationEffect(.degrees(-6))
            Text(sub).font(Theme.hand(22)).foregroundStyle(Theme.pencil)
        }
        .frame(minHeight: Theme.lh * 2)
    }
}

/// 표현장 시험지 (goni 2026-11-21 "애초에 시작부터 시험지 형태도", 웹 Sheet와 같다): 문제를 한 장에 번호(점선 동그라미) + #seq로 다 깔고,
/// 줄마다 입력란(다음 = 다음 줄, 마지막 줄 = 채점) + "문장 힌트"(빈칸 원문), 아래 "채점하기 ✓".
/// 채점: 표현 쓰기는 norm 같으면, 뜻 쓰기는 meaningHit이면 바로 ○ 기록. 아닌 줄(빈칸 포함)은 내 답 + "답" 줄 + 알았다 ○ / 몰랐다 ×를 골라 기록.
/// 자동 ○인 뜻 쓰기 줄엔 "사실 몰랐다 ×". 맨 위 점수(맞았다 · 몰랐다 · 아직 안 매긴 것) + "안 매긴 것은 몰랐다로 ✗" / 다 매기면 "다시 풀기 ↻" · "몰랐던 것만 다시 ↻"
struct PhraseSheet: View {
    @ObservedObject var m: PhraseTestModel
    var items: [PhraseTestItem]
    var meaning: Bool
    var onGraded: () -> Void
    var onRestart: (Set<String>?) -> Void
    @State private var answers: [String: String] = [:]
    @State private var graded = false
    @State private var marks: [String: Bool] = [:]     // 최종 ○× (자동 ○는 채점 때, 나머지는 내가 고른 뒤)
    @State private var hints: Set<String> = []
    @State private var revoked: Set<String> = []
    @State private var err: String?
    @FocusState private var focus: Int?

    private func ans(_ it: PhraseTestItem) -> String { (answers[it.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private func auto(_ it: PhraseTestItem) -> Bool {
        let a = ans(it)
        guard !a.isEmpty else { return false }
        return meaning ? PhraseTestModel.meaningHit(a, it.meaning) : PhraseTestModel.norm(a) == PhraseTestModel.norm(it.phrase)
    }
    private func record(_ it: PhraseTestItem, _ correct: Bool) {
        marks[it.id] = correct
        Task {
            do { if try await m.recordAnswer(it, correct) { revoked.insert(it.id) } }
            catch { err = error.localizedDescription }
        }
    }
    private func grade() {
        guard !graded else { return }
        graded = true; focus = nil
        for it in items where auto(it) { record(it, true) }
        onGraded()
    }
    private var pending: [PhraseTestItem] { items.filter { marks[$0.id] == nil } }
    private var right: Int { items.filter { marks[$0.id] == true }.count }
    private var wrong: Int { items.filter { marks[$0.id] == false }.count }

    var body: some View {
        if graded {
            Entry {
                ScoreLine(right: right, total: items.count, sub: "맞았다 \(right) · 몰랐다 \(wrong)" + (pending.isEmpty ? "" : " · 아직 안 매긴 것 \(pending.count)"))
                FlowLayout(spacing: 16, rowSpacing: 0) {
                    if !pending.isEmpty { Tiny(title: "안 매긴 것은 몰랐다로 ✗\u{FE0E}", color: Theme.red) { for it in pending { record(it, false) } }.frame(height: Theme.lh) }
                    if pending.isEmpty { Tiny(title: "다시 풀기 ↻\u{FE0E}") { onRestart(nil) }.frame(height: Theme.lh) }
                    if pending.isEmpty, wrong > 0 { Tiny(title: "몰랐던 것만 다시 ↻\u{FE0E}") { onRestart(Set(items.filter { marks[$0.id] == false }.map(\.id))) }.frame(height: Theme.lh) }
                }
                .padding(.top, 8)
                if let e = err { ErrorText(message: e) }
            }
        }
        ForEach(Array(items.enumerated()), id: \.element.id) { n, it in
            let mk = marks[it.id]
            let a = ans(it)
            let stamp: Stamp.Kind = (!graded || mk == nil) ? .number(n + 1) : (mk == true ? .ok : .no)
            Entry(stamp: AnyView(Stamp(kind: stamp))) {
                Group {
                    if meaning { Text(it.phrase).enLine() }
                    else { Text(it.meaning.isEmpty ? "(뜻 없음)" : it.meaning).handLine(size: 22, color: Theme.ink) }
                }
                .padding(.trailing, 44).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) { if let s = it.seq { Text("#\(s)").font(Theme.hand(15)).foregroundStyle(Theme.pencil).frame(height: Theme.lh) } }
                if let t = it.sentenceText, !t.isEmpty, hints.contains(it.id) || graded {
                    (graded ? Text(markSource(t, it.phrase)) : blankText(t, it.phrase)).enLine()
                }
                if !graded {
                    HStack(alignment: .top, spacing: 10) {
                        TextField(meaning ? "뜻" : "영어 표현", text: Binding(get: { answers[it.id] ?? "" }, set: { answers[it.id] = $0 }), axis: .vertical)
                            .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                            .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                            .focused($focus, equals: n)
                            .textInputAutocapitalization(meaning ? .sentences : .never).autocorrectionDisabled()
                            .onChange(of: answers[it.id] ?? "") { _, v in
                                // Enter: 다음 줄로, 마지막 줄이면 채점
                                if v.contains("\n") {
                                    answers[it.id] = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                                    if n + 1 < items.count { focus = n + 1 } else { grade() }
                                }
                            }
                        if let t = it.sentenceText, !t.isEmpty, !hints.contains(it.id) { Tiny(title: "문장 힌트", size: 17) { hints.insert(it.id) }.frame(height: Theme.lh) }
                    }
                } else {
                    if a.isEmpty { Text("빈칸").pencil() }
                    else if meaning { Text(a).koLine() }
                    else { Text(a).handLine(size: 22, color: mk == true ? Theme.grade(.A) : Theme.red) }
                    if mk != true {
                        (Text("답 ").font(Theme.hand(17)) + (meaning ? Text(it.meaning) : Text(it.phrase).font(Theme.print(15)))).pencil()
                    }
                    if mk == nil {
                        FlowLayout(spacing: 16, rowSpacing: 0) {
                            Tiny(title: meaning ? "알았다 ○" : "그래도 알았다 ○", color: Theme.grade(.A)) { record(it, true) }.frame(height: Theme.lh)
                            Tiny(title: it.isMastered ? "몰랐다 × · 도장 뗌" : "몰랐다 ×", color: Theme.red) { record(it, false) }.frame(height: Theme.lh)
                        }
                    } else if mk == true, meaning {
                        Tiny(title: "사실 몰랐다 ×", size: 17) { record(it, false) }.frame(height: Theme.lh).help("글자가 비슷해서 맞음으로 쳤지만 사실은 몰랐다 → 몰랐다로 기록")
                    }
                    if revoked.contains(it.id) { Text("⟲\u{FE0E} 습득 완료를 취소했다 — 표현장에 다시 보인다").font(Theme.hand(18)).foregroundStyle(Theme.red) }
                }
            }
            .padding(.bottom, 4)
        }
        if !graded {
            Entry {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Tiny(title: "채점하기 ✓\u{FE0E}", color: Theme.red) { grade() }
                    MutedText(text: "마지막 줄에서 Enter · 빈칸은 답을 보고 매긴다")
                }
                .frame(height: Theme.lh).padding(.top, 8)
            }
            .task {
                focus = 0
                #if DEBUG
                // 화면 확인용: LBN_SHEETGRADE=1 이면 첫 줄 맞게·둘째 줄 틀리게·나머지 빈칸으로 채워 채점한다
                if ProcessInfo.processInfo.environment["LBN_SHEETGRADE"] == "1", !graded {
                    for (n, it) in items.enumerated() {
                        if n == 0 { answers[it.id] = meaning ? it.meaning : it.phrase }
                        else if n == 1 { answers[it.id] = meaning ? "금리를 올리다" : "keep the rate" }
                    }
                    try? await Task.sleep(for: .seconds(0.5)); grade()
                }
                #endif
            }
        }
    }
}
