import SwiftUI

/// 표현장 시험 (웹 PhraseTest.tsx, goni 2026-11-18). 방식 셋(웹 50680bb·71126bc):
/// - 표현 쓰기: 뜻 → 영어 표현. Enter로 확인 — 소문자·구두점·공백·앞의 to/a/an/the 무시하고 같으면 바로 "맞았다 ○"(기록), 아니면 답 포스트잇 + 내 답(취소선) + 스스로 ○/×. key "pr|<id>"
/// - 뜻 쓰기: 표현 → 한국어 뜻. Enter로 답 공개(글자 비교 없음) → 알았다/몰랐다. key "pm|<id>", 기록·순서도 그 기록(m_*)으로
/// - 고급 ✎: 뜻만 보고 그 표현으로 내 문장 하나(영어) → POST /api/drills/free(멈추기 가능) → 결과를 써 보기 상자처럼. used_expression && A·B면 맞았다, 아니면 몰랐다 → key "pr|<id>"로 기록
/// 순서는 시험지와 같이 안 본 것 → 틀린 것 → 맞힌 것. 묶음 아직/습득 완료/전체(기억). 습득 완료 묶음을 고르면 고급이 기본. 오프라인이면 캐시 표현으로 카드, 결과는 큐
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
        let pool = basePool().filter { $0.stars >= minStars }
        // 같은 묶음 안에서는 별 많은 것부터, 그다음 오래된 순 (중요도 별, 2026-11-19)
        items = pool.shuffled().sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if a.stars != b.stars { return a.stars > b.stars }
            return (lastAt(a) ?? 0) < (lastAt(b) ?? 0)
        }
    }
    func restart() { i = 0; right = 0; wrong = 0; revokedPrev = nil; resetCard(); rebuild() }
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
    /// Enter: 표현 쓰기는 맞으면 바로 기록, 아니면 답 공개 후 ○/× 대기. 뜻 쓰기는 답만 공개. 고급은 자유 작문 채점
    func check() {
        guard let it = current, revealed == nil, !grading else { return }
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        switch mode {
        case .write:
            if Self.norm(a) == Self.norm(it.phrase) { revealed = .right; right += 1; record(it, true) } else { revealed = .wrong }
        case .meaning:
            revealed = .shown
        case .advanced:
            submitFree(it, a)
        }
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
        let k = key(it)
        AppLog.shared.info("phrasetest", correct ? "right" : "wrong", ["key": k, "mode": mode.rawValue])
        Task {
            do {
                let revoked = try await SyncManager.shared.answerQuiz(key: k, sentenceId: it.sentenceId ?? "", source: it.phrase, correct: correct)
                if revoked {
                    revokedPrev = it.phrase
                    if let j = all?.firstIndex(where: { $0.id == it.id }) { all?[j].masteredAt = nil }
                    if let j = items.firstIndex(where: { $0.id == it.id }) { items[j].masteredAt = nil }
                }
            } catch { err = error.localizedDescription }
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NotebookHead(tab: "\(min(m.i + 1, m.items.count)) / \(m.items.count)") {
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
                    }
                }
                Paper { paper }
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
            if let v = ProcessInfo.processInfo.environment["LBN_TESTANSWER"], let it = m.current {
                switch m.mode {
                case .write: m.answer = v == "right" ? it.phrase : "keep the rate"
                case .meaning: m.answer = v == "right" ? it.meaning : "금리를 올리다"
                case .advanced: m.answer = v == "right" ? "The central bank decided to \(it.phrase) this quarter." : "The bank kept everything as it was."
                }
                m.check()
                if v == "wrongmark" { m.mark(false) }   // 몰랐다까지 → 다음 카드 위 "⟲ 앞 표현…" 확인용
            }
            #endif
        }
        .refreshable { await m.load(); m.restart() }
    }

    /// 원문에서 그 표현만 빈칸으로 (대소문자 무시). 없으면 원문 그대로
    private func blank(_ text: String, _ phrase: String) -> Text {
        guard !phrase.isEmpty, let r = text.range(of: phrase, options: .caseInsensitive) else { return Text(text) }
        let n = max(6, min(18, phrase.count))
        return Text(text[..<r.lowerBound]) + Text(String(repeating: "_", count: n)).foregroundColor(Theme.red) + Text(text[r.upperBound...])
    }

    @ViewBuilder
    private var paper: some View {
        if let e = m.err, m.all == nil {
            Entry { ErrorText(message: e) }
        } else if m.all == nil {
            Entry { Text("…").pencil() }
        } else if m.items.isEmpty {
            Entry {
                Text("시험 볼 표현이 없다").font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
                Text(m.minStars > 0 ? "이 별 개수 이상인 표현이 이 묶음·범위에 없다." : m.range != nil ? "이 번호 범위에 시험 볼 표현이 없다." : m.bucket == .mastered ? "습득 완료 도장이 찍힌 표현이 없다." : "표현장에 붙은 표현이 문제가 된다.").pencil()
            }
        } else if m.done {
            Entry {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("\(m.right) / \(m.right + m.wrong)")
                        .font(Theme.hand(56)).foregroundStyle(Theme.red)
                        .padding(.horizontal, 14).padding(.vertical, 2)
                        .overlay(Ellipse().strokeBorder(Theme.red, lineWidth: 3)).rotationEffect(.degrees(-6))
                    Text("맞았다 \(m.right) · 몰랐다 \(m.wrong)").font(Theme.hand(22)).foregroundStyle(Theme.pencil)
                }
                .frame(minHeight: Theme.lh * 2)
                Tiny(title: "다시 풀기 ↻\u{FE0E}") { m.restart(); focused = true }.frame(height: Theme.lh).padding(.top, 8)
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
                        (m.revealed != nil ? Text(markSource(t, it.phrase)) : blank(t, it.phrase)).enLine()
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
