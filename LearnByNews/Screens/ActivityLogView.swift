import SwiftUI

/// 기록 탭 (웹 Log.tsx): 하루 안의 활동을 시간순 블록으로
enum LogBlock: Identifiable {
    case session(at: Int64, session: StudySession, attempts: [LogAttempt])
    case loose(at: Int64, attempts: [LogAttempt])
    case review(at: Int64, review: LogReview)
    case quiz(at: Int64, items: [LogQuiz])

    var at: Int64 {
        switch self {
        case .session(let at, _, _), .loose(let at, _), .review(let at, _), .quiz(let at, _): return at
        }
    }
    var id: String {
        switch self {
        case .session(_, let s, _): return "s-\(s.id)"
        case .loose(let at, _): return "l-\(at)"
        case .review(_, let r): return "r-\(r.id)"
        case .quiz(let at, _): return "q-\(at)"
        }
    }
}

struct LogDay: Identifiable {
    var at: Int64
    var blocks: [LogBlock]
    var id: Int64 { at }
}

/// 세션에 속한 채점은 세션 아래로, 나머지는 '기록 없는 채점'으로 30분 넘게 비면 끊어서 묶는다
func buildDays(_ log: ActivityLog) -> [LogDay] {
    var blocks: [LogBlock] = []
    var used = Set<String>()
    for s in log.sessions {
        let attempts = log.attempts.filter { $0.createdAt >= s.startedAt && $0.createdAt <= s.endedAt }
        attempts.forEach { used.insert($0.id) }
        blocks.append(.session(at: s.startedAt, session: s, attempts: attempts))
    }
    var cur: [LogAttempt] = []
    func flush() { if let f = cur.first { blocks.append(.loose(at: f.createdAt, attempts: cur)) }; cur = [] }
    for a in log.attempts where !used.contains(a.id) {
        if let last = cur.last, a.createdAt - last.createdAt > 30 * 60_000 { flush() }
        cur.append(a)
    }
    flush()
    for r in log.reviews { blocks.append(.review(at: r.createdAt, review: r)) }
    var q: [LogQuiz] = []
    func flushQ() { if let f = q.first { blocks.append(.quiz(at: f.createdAt, items: q)) }; q = [] }
    for x in log.quiz {
        if let last = q.last, x.createdAt - last.createdAt > 30 * 60_000 { flushQ() }
        q.append(x)
    }
    flushQ()

    var days: [String: LogDay] = [:]
    let cal = Calendar.current
    for b in blocks.sorted(by: { $0.at < $1.at }) {
        let d = Date(ms: b.at)
        let c = cal.dateComponents([.year, .month, .day], from: d)
        let k = "\(c.year!)-\(c.month!)-\(c.day!)"
        if days[k] == nil { days[k] = LogDay(at: b.at, blocks: []) }
        days[k]!.blocks.append(b)
    }
    return days.values.sorted { $0.at > $1.at }
}

struct ActivityLogView: View {
    @EnvironmentObject var router: Router
    @State private var log: ActivityLog?
    @State private var err: String?
    @State private var days = 60
    @State private var open: Set<String> = []

    var body: some View {
        let groups = log.map(buildDays) ?? []
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookHead(tab: "\(groups.count)일") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("기록")
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
                        else if groups.isEmpty { Entry { sectionTitle("아직 기록이 없다") } }
                        ForEach(Array(groups.enumerated()), id: \.element.id) { gi, g in
                            if gi > 0 { BlankLine() }
                            Entry { sectionTitle(Date(ms: g.at).dayLabel) }
                            ForEach(g.blocks) { b in block(b) }
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

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
    }

    @ViewBuilder
    private func block(_ b: LogBlock) -> some View {
        switch b {
        case .session(_, let s, let attempts):
            Entry(stamp: AnyView(Stamp(kind: .session))) {
                (Text("\(Date(ms: s.startedAt).hm)–\(Date(ms: s.endedAt).hm) · \(s.minutes)분 · \(s.attempts)문장")
                 + Text(s.score.map { " \($0)점" } ?? "").foregroundColor(Theme.red)
                 + Text(" " + s.articles.joined(separator: ", ")).font(Theme.hand(17)).foregroundColor(Theme.pencil))
                    .koLine()
                attemptLines(attempts, key: b.id)
            }
        case .loose(_, let attempts):
            Entry {
                Text("\(Date(ms: attempts[0].createdAt).hm)부터 · 기록 없이 채점 \(attempts.count)문장").pencil()
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
