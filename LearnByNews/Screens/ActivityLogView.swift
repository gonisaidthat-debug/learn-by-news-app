import SwiftUI

/// 기록 탭 (웹 Log.tsx): 날짜 보기 / 기사 보기, 평가 추이 그래프
enum LogBlock: Identifiable {
    case session(at: Int64, session: StudySession, attempts: [LogAttempt], drills: [LogDrill])
    case loose(at: Int64, attempts: [LogAttempt])
    case review(at: Int64, review: LogReview)
    case quiz(at: Int64, items: [LogQuiz])
    case drills(at: Int64, items: [LogDrill])

    var at: Int64 {
        switch self {
        case .session(let at, _, _, _), .loose(let at, _), .review(let at, _), .quiz(let at, _), .drills(let at, _): return at
        }
    }
    var id: String {
        switch self {
        case .session(_, let s, _, _): return "s-\(s.id)"
        case .loose(let at, _): return "l-\(at)"
        case .review(_, let r): return "r-\(r.id)"
        case .quiz(let at, _): return "q-\(at)"
        case .drills(let at, _): return "d-\(at)"
        }
    }
}

struct LogDay: Identifiable {
    var at: Int64
    var blocks: [LogBlock]
    var id: Int64 { at }
}

/// 하루 안의 활동을 시간순 블록으로. 세션 안의 채점·응용은 세션 아래로, 나머지는 30분 넘게 비면 끊어서 묶는다
func buildDays(attempts: [LogAttempt], sessions: [StudySession], reviews: [LogReview], quiz: [LogQuiz], drills: [LogDrill]) -> [LogDay] {
    var blocks: [LogBlock] = []
    var used = Set<String>(), usedD = Set<String>()
    for s in sessions {
        let atts = attempts.filter { $0.createdAt >= s.startedAt && $0.createdAt <= s.endedAt }
        let drs = drills.filter { ($0.answeredAt ?? 0) >= s.startedAt && ($0.answeredAt ?? 0) <= s.endedAt }
        atts.forEach { used.insert($0.id) }; drs.forEach { usedD.insert($0.id) }
        blocks.append(.session(at: s.startedAt, session: s, attempts: atts, drills: drs))
    }
    var cur: [LogAttempt] = []
    func flush() { if let f = cur.first { blocks.append(.loose(at: f.createdAt, attempts: cur)) }; cur = [] }
    for a in attempts where !used.contains(a.id) {
        if let last = cur.last, a.createdAt - last.createdAt > 30 * 60_000 { flush() }
        cur.append(a)
    }
    flush()
    for r in reviews { blocks.append(.review(at: r.createdAt, review: r)) }
    var q: [LogQuiz] = []
    func flushQ() { if let f = q.first { blocks.append(.quiz(at: f.createdAt, items: q)) }; q = [] }
    for x in quiz {
        if let last = q.last, x.createdAt - last.createdAt > 30 * 60_000 { flushQ() }
        q.append(x)
    }
    flushQ()
    var dq: [LogDrill] = []
    func flushD() { if let f = dq.first { blocks.append(.drills(at: f.answeredAt ?? 0, items: dq)) }; dq = [] }
    for d in drills.filter({ $0.answeredAt != nil && !usedD.contains($0.id) }).sorted(by: { ($0.answeredAt ?? 0) < ($1.answeredAt ?? 0) }) {
        if let last = dq.last, (d.answeredAt ?? 0) - (last.answeredAt ?? 0) > 30 * 60_000 { flushD() }
        dq.append(d)
    }
    flushD()

    var days: [String: LogDay] = [:]
    let cal = Calendar.current
    for b in blocks.sorted(by: { $0.at < $1.at }) {
        let c = cal.dateComponents([.year, .month, .day], from: Date(ms: b.at))
        let k = "\(c.year!)-\(c.month!)-\(c.day!)"
        if days[k] == nil { days[k] = LogDay(at: b.at, blocks: []) }
        days[k]!.blocks.append(b)
    }
    return days.values.sorted { $0.at > $1.at }
}

/// 기사 보기 한 묶음
struct ArticleGroup: Identifiable {
    var id: String
    var title: String
    var lastAt: Int64
    var attempts: [LogAttempt]
    var drills: [LogDrill]
    var reviews: [LogReview]
    var quiz: [LogQuiz]
    var days: [LogDay] { buildDays(attempts: attempts, sessions: [], reviews: reviews, quiz: quiz, drills: drills) }
    var avg: Int? {
        let pts = attempts.filter { $0.grade != .skip }.compactMap { Grade.points[$0.grade] } + drills.compactMap { $0.grade.flatMap { Grade.points[$0] } }
        return pts.isEmpty ? nil : Int((Double(pts.reduce(0, +)) / Double(pts.count)).rounded())
    }
    /// "n문장 (응용 k) · 평균 p점 · 총평 r"
    var summary: String {
        var s = "\(attempts.count + drills.count)문장" + (drills.isEmpty ? "" : " (응용 \(drills.count))")
        if let a = avg { s += " · 평균 \(a)점" }
        if !reviews.isEmpty { s += " · 총평 \(reviews.count)" }
        return s
    }
}

struct ActivityLogView: View {
    @EnvironmentObject var router: Router
    @State private var log: ActivityLog?
    @State private var err: String?
    @State private var days = 60
    @State private var open: Set<String> = []
    @AppStorage("lbn_log_mode") private var byArticle = false
    @State private var collapsed: Set<String> = []     // 기사 보기에서 접은 기사
    @State private var expanded: Set<String> = []      // 기사 보기에서 펼친 기사 (기본: 최근 2개)

    var body: some View {
        let groups = log.map { buildDays(attempts: $0.attempts, sessions: $0.sessions, reviews: $0.reviews, quiz: $0.quiz, drills: $0.drills ?? []) } ?? []
        let articles = log.map(articleGroups) ?? []
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookHead(tab: byArticle ? "\(articles.count)기사" : "\(groups.count)일") {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 14) {
                                Text("기록")
                                HStack(spacing: 10) {
                                    Tiny(title: "날짜", color: byArticle ? Theme.pencil : Theme.ink, size: 19) { byArticle = false }
                                        .overlay(alignment: .bottom) { if !byArticle { Rectangle().fill(Theme.red).frame(height: 2) } }
                                    Tiny(title: "기사", color: byArticle ? Theme.ink : Theme.pencil, size: 19) { byArticle = true }
                                        .overlay(alignment: .bottom) { if byArticle { Rectangle().fill(Theme.red).frame(height: 2) } }
                                }
                            }
                            HStack(spacing: 10) {
                                ForEach([7, 30, 60, 365], id: \.self) { d in
                                    Tiny(title: d == 365 ? "1년" : "\(d)일", color: days == d ? Theme.ink : Theme.pencil, size: 19) { days = d }
                                        .overlay(alignment: .bottom) { if days == d { Rectangle().fill(Theme.red).frame(height: 2) } }
                                }
                            }
                        }
                    }
                    Paper {
                        if let err { Entry { ErrorText(message: err) } }
                        else if log == nil { Entry { Text("…").pencil() } }
                        else if let log {
                            // 맨 위: 요약 한 줄 + 추이 그래프
                            let all = Trend.days(attempts: log.attempts, drills: log.drills ?? [])
                            Entry {
                                Text(summaryLine(log)).pencil(size: 20)
                                TrendChart(days: all).padding(.vertical, 6)
                            }
                            if byArticle {
                                if articles.isEmpty { Entry { sectionTitle("아직 기록이 없다") } }
                                ForEach(Array(articles.enumerated()), id: \.element.id) { gi, a in
                                    if gi > 0 { BlankLine() }
                                    articleSection(a, isOpen: isOpen(a.id, index: gi))
                                }
                            } else {
                                if groups.isEmpty { Entry { sectionTitle("아직 기록이 없다") } }
                                ForEach(Array(groups.enumerated()), id: \.element.id) { gi, g in
                                    if gi > 0 { BlankLine() }
                                    Entry { sectionTitle(Date(ms: g.at).dayLabel) }
                                    ForEach(g.blocks) { b in block(b, showSession: true) }
                                }
                            }
                        }
                        MutedText(text: "최근 \(days)일").frame(height: Theme.lh).padding(.top, Theme.lh).padding(.leading, Theme.paperLeft)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 40, trailing: 10))
                .readableWidth()
            }
            .background(Theme.desk.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task(id: days) { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: 요약·기사 묶음

    /// "최근 60일 · 123문장 (응용 2) · 평균 62점"
    private func summaryLine(_ log: ActivityLog) -> String {
        let drs = log.drills ?? []
        let pts = log.attempts.filter { $0.grade != .skip }.compactMap { Grade.points[$0.grade] } + drs.compactMap { $0.grade.flatMap { Grade.points[$0] } }
        var s = "최근 \(days)일 · \(log.attempts.count + drs.count)문장" + (drs.isEmpty ? "" : " (응용 \(drs.count))")
        if !pts.isEmpty { s += " · 평균 \(Int((Double(pts.reduce(0, +)) / Double(pts.count)).rounded()))점" }
        return s
    }

    /// 최근 활동이 있는 기사부터. 기사를 모르는 응용·시험은 제외
    private func articleGroups(_ log: ActivityLog) -> [ArticleGroup] {
        var map: [String: ArticleGroup] = [:]
        func g(_ id: String, _ title: String) -> ArticleGroup { map[id] ?? ArticleGroup(id: id, title: title, lastAt: 0, attempts: [], drills: [], reviews: [], quiz: []) }
        for a in log.attempts { var x = g(a.articleId, a.title); x.attempts.append(a); x.lastAt = max(x.lastAt, a.createdAt); map[a.articleId] = x }
        for d in log.drills ?? [] { guard let id = d.articleId else { continue }; var x = g(id, d.title ?? ""); x.drills.append(d); x.lastAt = max(x.lastAt, d.answeredAt ?? 0); map[id] = x }
        for r in log.reviews { var x = g(r.articleId, r.title); x.reviews.append(r); x.lastAt = max(x.lastAt, r.createdAt); map[r.articleId] = x }
        for q in log.quiz { guard let id = q.articleId else { continue }; var x = g(id, q.title ?? ""); x.quiz.append(q); x.lastAt = max(x.lastAt, q.createdAt); map[id] = x }
        return map.values.sorted { $0.lastAt > $1.lastAt }
    }
    private func isOpen(_ id: String, index: Int) -> Bool {
        if collapsed.contains(id) { return false }
        return index < 2 || expanded.contains(id)
    }

    @ViewBuilder
    private func articleSection(_ a: ArticleGroup, isOpen: Bool) -> some View {
        Entry {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Tiny(title: a.title, color: Theme.ink, size: 22) { router.open(.notebook(id: a.id, browse: true)) }.lineLimit(2)
                Spacer(minLength: 0)
                Tiny(title: isOpen ? "접기" : "펼치기", size: 17) {
                    if isOpen { collapsed.insert(a.id); expanded.remove(a.id) } else { collapsed.remove(a.id); expanded.insert(a.id) }
                }
            }
            .frame(minHeight: Theme.lh)
            Text(a.summary).pencil(size: 19)
            if isOpen {
                TrendChart(days: Trend.days(attempts: a.attempts, drills: a.drills), compact: true).padding(.vertical, 4)
            }
        }
        if isOpen {
            ForEach(a.days) { g in
                Entry { sectionTitle(Date(ms: g.at).dayLabel) }
                ForEach(g.blocks) { b in block(b, showSession: false) }
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
    }

    // MARK: 블록

    @ViewBuilder
    private func block(_ b: LogBlock, showSession: Bool) -> some View {
        switch b {
        case .session(_, let s, let attempts, let drills):
            Entry(stamp: AnyView(Stamp(kind: .session))) {
                (Text("\(Date(ms: s.startedAt).hm)–\(Date(ms: s.endedAt).hm) · \(s.minutes)분 · \(s.countLabel)")
                 + Text(s.score.map { " \($0)점" } ?? "").foregroundColor(Theme.red)
                 + Text(" " + s.articles.joined(separator: ", ")).font(Theme.hand(17)).foregroundColor(Theme.pencil))
                    .koLine()
                attemptLines(attempts, key: b.id)
                if !drills.isEmpty { drillLines(drills, head: true) }
            }
        case .loose(_, let attempts):
            Entry {
                Text("\(Date(ms: attempts[0].createdAt).hm)부터 · " + (showSession ? "기록 없이 채점" : "채점") + " \(attempts.count)문장").pencil()
                attemptLines(attempts, key: b.id)
            }
        case .review(_, let r):
            Entry {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    (Text(Date(ms: r.createdAt).hm + " ").font(Theme.hand(17)).foregroundColor(Theme.pencil) + Text("총평" + (r.score.map { " · \($0)점" } ?? "") + " ·")).redpen()
                    Tiny(title: r.title) { router.open(.done(id: r.articleId)) }.lineLimit(1)
                }
                Text(r.summary).redpen()
            }
        case .drills(_, let items):
            Entry { drillLines(items, head: true) }
        case .quiz(let at, let items):
            let right = items.filter(\.correct).count
            let missed = items.filter { !$0.correct }.map(\.source)
            Entry {
                (Text(Date(ms: at).hm + " ").font(Theme.hand(17)) + Text("시험 \(items.count)문제 · 알았다 \(right) · 몰랐다 \(items.count - right)")
                 + Text(missed.isEmpty ? "" : " — 몰랐던 것: " + missed.joined(separator: ", ")).foregroundColor(Theme.red))
                    .pencil()
            }
        }
    }

    /// "응용 n문장 · 평균 x점 · 표현 사용 k/n" + 줄(도장 · 표현 · 한국어/자유 작문 · 내 영작)
    @ViewBuilder
    private func drillLines(_ items: [LogDrill], head: Bool) -> some View {
        let pts = items.compactMap { $0.grade.flatMap { Grade.points[$0] } }
        let avg = pts.isEmpty ? nil : Int((Double(pts.reduce(0, +)) / Double(pts.count)).rounded())
        let used = items.filter { $0.usedExpression == true }.count
        if head {
            (Text((items.first?.answeredAt).map { Date(ms: $0).hm + " " } ?? "").font(Theme.hand(17)) + Text("응용 \(items.count)문장" + (avg.map { " · 평균 \($0)점" } ?? "") + " · 표현 사용 \(used)/\(items.count)")).pencil()
        }
        ForEach(items) { d in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let g = d.grade { Stamp(kind: .grade(g), small: true) }
                Text(d.phrase).font(Theme.hand(18)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                Text(d.isFree ? "자유 작문" : d.korean).font(Theme.hand(17)).foregroundStyle(Theme.pencil).lineLimit(1)
                if let a = d.answer, !a.isEmpty { Text(a).font(Theme.hand(18)).foregroundStyle(Theme.blueInk).lineLimit(1) }
            }
            .frame(height: Theme.lh)
        }
    }

    @ViewBuilder
    private func attemptLines(_ attempts: [LogAttempt], key: String) -> some View {
        let isOpen = open.contains(key)
        let shown = isOpen ? attempts : Array(attempts.prefix(3))
        ForEach(shown) { a in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Stamp(kind: .grade(a.grade), small: true)
                Text(Date(ms: a.createdAt).hm).font(Theme.hand(17)).foregroundStyle(Theme.pencil)
                Button { router.open(.notebook(id: a.articleId, focus: a.sentenceId)) } label: {
                    Text(a.text).font(Theme.print(15)).foregroundStyle(Theme.ink).lineLimit(1)
                }.buttonStyle(.plain)
                if !a.translation.isEmpty { Text(a.translation).font(Theme.hand(20)).foregroundStyle(Theme.blueInk).lineLimit(1) }
            }
            .frame(height: Theme.lh)
        }
        if attempts.count > 3 {
            Tiny(title: isOpen ? "접기" : "\(attempts.count - 3)문장 더 보기") { if isOpen { open.remove(key) } else { open.insert(key) } }.frame(height: Theme.lh)
        }
    }

    private func load() async {
        if let c = Cache.shared.activityLog(days: days) { log = c }
        do { log = try await API.shared.activityLog(days: days); err = nil }
        catch let e as APIError where e.isNetwork { if log == nil { err = e.localizedDescription } }
        catch { err = error.localizedDescription }
    }
}
