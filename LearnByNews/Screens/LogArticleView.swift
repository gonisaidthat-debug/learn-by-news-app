import SwiftUI

// 기록 탭 "기사" 보기: 날짜가 아니라 문장들이 회차를 거듭하며 어떻게 변해 가는지 (goni 2026-11-16, 웹 Log.tsx runs()/rounds()와 같은 규칙)

/// 한 문장의 흐름. 회차 = n번째 총평 시각 기준(공책의 회차 열람과 같은 기준): 1회차는 첫 총평까지, 마지막 총평 뒤는 진행 중인 회차.
/// stages = 회차마다 그 회차의 **첫** 번역 하나(도장 사슬·분포; 같은 회차 안의 다시 쓰기는 첨삭 직후라 실력 변화로 안 친다, goni 2026-11-16), attempts = 그 문장의 모든 시도(펼치면 보인다).
/// 건너뛴 시도와 "잘못 눌렀다"(void) 시도는 빼고 센다
struct SentenceRun: Identifiable {
    enum Dir { case up, down, same, once }
    struct Stage { var round: Int; var attempt: LogAttempt }
    var sentenceId: String
    var idx: Int
    var text: String
    var attempts: [LogAttempt] = []
    var stages: [Stage] = []
    var chain: [LogAttempt] = []
    var dir: Dir = .once
    var id: String { sentenceId }
    var last: LogAttempt? { attempts.last }
}

/// 회차별 등급 분포: 각 문장의 그 회차 첫 번역으로 센다
struct RoundStat: Identifiable {
    var n: Int
    var live: Bool          // 마지막 총평 뒤 = 진행 중
    var count: Int
    var score: Int
    var counts: [Grade: Int]
    var id: Int { n }
}

enum LogRuns {
    static func runs(attempts: [LogAttempt], reviews: [LogReview]) -> [SentenceRun] {
        let bounds = reviews.map(\.createdAt).sorted()
        func roundOf(_ t: Int64) -> Int { 1 + bounds.filter { $0 < t }.count }
        var map: [String: SentenceRun] = [:]
        for a in attempts.sorted(by: { $0.createdAt < $1.createdAt }) where Grade.points[a.grade] != nil && !a.isVoid {
            var r = map[a.sentenceId] ?? SentenceRun(sentenceId: a.sentenceId, idx: a.idx, text: a.text)
            r.attempts.append(a)
            let rn = roundOf(a.createdAt)
            if r.stages.last?.round != rn { r.stages.append(.init(round: rn, attempt: a)) }   // 회차의 첫 시도만
            map[a.sentenceId] = r
        }
        return map.values.map { r0 in
            var r = r0
            // 사슬은 회차별 하나. 회차가 하나뿐인데 여러 번 썼으면(한 회차 안의 다시 쓰기) 시도마다
            r.chain = r.stages.count > 1 ? r.stages.map(\.attempt) : r.attempts
            if r.chain.count >= 2, let a = Grade.points[r.chain[0].grade], let b = Grade.points[r.chain[r.chain.count - 1].grade] {
                r.dir = b > a ? .up : b < a ? .down : .same
            }
            return r
        }.sorted { $0.idx < $1.idx }
    }

    static func rounds(_ rs: [SentenceRun], reviewCount: Int) -> [RoundStat] {
        var by: [Int: [LogAttempt]] = [:]
        for r in rs { for s in r.stages { by[s.round, default: []].append(s.attempt) } }
        return by.keys.sorted().map { n in
            let as_ = by[n]!
            var counts: [Grade: Int] = [:]
            for a in as_ { counts[a.grade, default: 0] += 1 }
            let pts = as_.compactMap { Grade.points[$0.grade] }
            return RoundStat(n: n, live: n > reviewCount, count: as_.count, score: Int((Double(pts.reduce(0, +)) / Double(max(pts.count, 1))).rounded()), counts: counts)
        }
    }

    static func mark(_ d: SentenceRun.Dir) -> String { switch d { case .up: return "↑"; case .down: return "↓"; case .same: return "="; case .once: return "" } }
    static func color(_ d: SentenceRun.Dir) -> Color { switch d { case .up: return Theme.grade(.A); case .down: return Theme.red; default: return Theme.pencil } }
    static func md(_ t: Int64) -> String { Date(ms: t).monthDay }
}

/// 기사 하나: 머리(제목 · 문장 수 · 응용 수 · 총평 점수 흐름) → 회차별 분포 줄 → 오르내림 요약 → 문장 순서대로 한 줄씩 → 응용은 표현별
struct LogArticleSection: View {
    @EnvironmentObject var router: Router
    let group: ArticleGroup
    let isOpen: Bool
    let onToggle: () -> Void
    @Binding var open: Set<String>

    private var key: String { "a-\(group.id)" }
    private var reviews: [LogReview] { group.reviews.sorted { $0.createdAt < $1.createdAt } }

    var body: some View {
        let reviews = reviews
        let rs = LogRuns.runs(attempts: group.attempts, reviews: reviews)
        let multi = rs.filter { $0.chain.count > 1 }
        let once = rs.filter { $0.chain.count == 1 }
        let rd = LogRuns.rounds(rs, reviewCount: reviews.count)
        let onceOpen = open.contains(key + "-once")
        let drills = Dictionary(grouping: group.drills.sorted { ($0.answeredAt ?? 0) < ($1.answeredAt ?? 0) }, by: \.phrase)
        let phrases = drills.keys.sorted { (drills[$0]!.first?.answeredAt ?? 0) < (drills[$1]!.first?.answeredAt ?? 0) }

        Entry {
            // 머리
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Tiny(title: group.title, color: Theme.ink, size: 22) { router.open(.notebook(id: group.id, focus: rs.first?.sentenceId, browse: true)) }.lineLimit(2)
                Spacer(minLength: 0)
                Tiny(title: isOpen ? "접기" : "펼치기", size: 17, action: onToggle)
            }
            .frame(minHeight: Theme.lh)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(rs.count)문장" + (group.drills.isEmpty ? "" : " · 응용 \(group.drills.count)") + (reviews.isEmpty ? "" : " · 총평")).font(Theme.hand(19)).foregroundStyle(Theme.pencil)
                if !reviews.isEmpty {
                    Tiny(title: reviews.enumerated().map { i, r in r.score.map { "\($0)점" } ?? "\(i + 1)회차" }.joined(separator: " → "), color: Theme.red, size: 19) { router.open(.done(id: group.id)) }
                }
            }
            .frame(height: Theme.lh)
            if isOpen {
                ForEach(rd) { r in roundLine(r) }
                if !multi.isEmpty {
                    let up = multi.filter { $0.dir == .up }.count, down = multi.filter { $0.dir == .down }.count, same = multi.filter { $0.dir == .same }.count
                    (Text("회차를 거듭 쓴 \(multi.count)문장 중 ") + Text("↑").foregroundColor(LogRuns.color(.up)) + Text(" 올라갔다 \(up) · ") + Text("↓").foregroundColor(LogRuns.color(.down)) + Text(" 내려갔다 \(down) · ") + Text("=").foregroundColor(LogRuns.color(.same)) + Text(" 그대로 \(same)"))
                        .font(Theme.hand(19)).foregroundStyle(Theme.pencil).fixedSize(horizontal: false, vertical: true)
                    Text("회차마다 처음 쓴 것으로 센다 · 줄을 누르면 시도마다 쓴 번역이 보인다").font(Theme.hand(17)).foregroundStyle(Theme.placeholder).lineLimit(1).frame(height: Theme.lh)
                }
            }
        }
        if isOpen {
            Entry {
                ForEach(multi) { r in runLine(r) }
                if !once.isEmpty {
                    Tiny(title: onceOpen ? "접기" : "한 번 쓴 \(once.count)문장 보기") { toggle(key + "-once") }.frame(height: Theme.lh)
                    if onceOpen { ForEach(once) { r in runLine(r) } }
                }
            }
            if !phrases.isEmpty {
                Entry {
                    Text("응용 · 표현 \(phrases.count)개").font(Theme.hand(19)).foregroundStyle(Theme.pencil).frame(height: Theme.lh)
                    ForEach(phrases, id: \.self) { p in drillLine(p, drills[p] ?? []) }
                }
            }
        }
    }

    private func toggle(_ k: String) { if open.contains(k) { open.remove(k) } else { open.insert(k) } }

    /// "n회차 · 진행 중  ▬▬▬  81점" / "110문장 · A 41 B 48 C 17 D 4"
    private func roundLine(_ r: RoundStat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(r.n)회차" + (r.live ? " · 진행 중" : "")).font(Theme.hand(19)).foregroundStyle(Theme.ink)
                InkBar(counts: r.counts, total: r.count)
                Text("\(r.score)점").font(Theme.hand(20)).foregroundStyle(Theme.red)
            }
            .frame(height: Theme.lh)
            Text("\(r.count)문장 · " + [Grade.A, .B, .C, .D].map { "\($0.rawValue) \(r.counts[$0] ?? 0)" }.joined(separator: " "))
                .font(Theme.hand(17)).foregroundStyle(Theme.pencil).lineLimit(1).frame(height: Theme.lh)
        }
    }

    /// 문장 한 줄: 번호 · 도장 사슬 → 방향 · 원문(공책 열람) / 마지막 번역. 누르면 시도마다
    private func runLine(_ r: SentenceRun) -> some View {
        let rk = key + "-" + r.sentenceId
        let isOpen = open.contains(rk)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(r.idx + 1)").font(Theme.hand(17)).foregroundStyle(Theme.pencil).frame(minWidth: 22, alignment: .trailing)
                chain(r.chain.map(\.grade))
                if r.dir != .once { Text(LogRuns.mark(r.dir)).font(Theme.hand(20)).fontWeight(.bold).foregroundStyle(LogRuns.color(r.dir)) }
                Button { router.open(.notebook(id: group.id, focus: r.sentenceId, browse: true)) } label: {
                    Text(r.text).font(Theme.print(15)).foregroundStyle(Theme.ink).lineLimit(1)
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .frame(height: Theme.lh)
            if let t = r.last?.translation, !t.isEmpty {
                Text(t).font(Theme.hand(20)).foregroundStyle(Theme.blueInk).lineLimit(1).padding(.leading, 30).frame(height: Theme.lh)
            }
            if isOpen {
                ForEach(r.attempts) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Stamp(kind: .grade(a.grade), small: true)
                        Text("\(LogRuns.md(a.createdAt)) \(Date(ms: a.createdAt).hm)").font(Theme.hand(17)).foregroundStyle(Theme.pencil)
                        if a.translation.isEmpty { Text("건너뜀").font(Theme.hand(18)).foregroundStyle(Theme.placeholder) }
                        else { Text(a.translation).font(Theme.hand(19)).foregroundStyle(Theme.blueInk).lineLimit(2) }
                    }
                    .padding(.leading, 30).frame(minHeight: Theme.lh)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if r.attempts.count > 1 { toggle(rk) } }
    }

    /// 응용 표현 한 줄: 도장 사슬 · 표현 · 마지막 답. 누르면 시도마다(날짜 · 한국어 문제 · 답)
    private func drillLine(_ phrase: String, _ items: [LogDrill]) -> some View {
        let dk = key + "-p-" + phrase
        let isOpen = open.contains(dk)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                chain(items.compactMap(\.grade))
                Text(phrase).font(Theme.hand(18)).foregroundStyle(Theme.ink).lineLimit(1).layoutPriority(1)
                if let a = items.last?.answer, !a.isEmpty { Text(a).font(Theme.hand(18)).foregroundStyle(Theme.blueInk).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .frame(height: Theme.lh)
            if isOpen {
                ForEach(items) { x in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let g = x.grade { Stamp(kind: .grade(g), small: true) }
                        Text((x.answeredAt.map { "\(LogRuns.md($0)) \(Date(ms: $0).hm)" } ?? "")).font(Theme.hand(17)).foregroundStyle(Theme.pencil)
                        Text(x.isFree ? "자유 작문" : x.korean).font(Theme.hand(17)).foregroundStyle(Theme.pencil).lineLimit(1)
                        if let a = x.answer, !a.isEmpty { Text(a).font(Theme.hand(18)).foregroundStyle(Theme.blueInk).lineLimit(2) }
                    }
                    .padding(.leading, 30).frame(minHeight: Theme.lh)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(dk) }
    }

    /// 도장 사슬 "B → A"
    private func chain(_ grades: [Grade]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(grades.enumerated()), id: \.offset) { i, g in
                if i > 0 { Text("→").font(.system(size: 12)).foregroundStyle(Theme.pencil) }
                Stamp(kind: .grade(g), small: true).scaleEffect(0.8).frame(width: 22, height: 22)
            }
        }
    }
}

/// 회차 등급 분포 한 줄 막대 (TrendChart와 같은 잉크 램프: A 진함 → D 연함)
struct InkBar: View {
    var counts: [Grade: Int]
    var total: Int
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach([Grade.A, .B, .C, .D], id: \.self) { gr in
                    let n = counts[gr] ?? 0
                    if n > 0 { Rectangle().fill(Trend.color(gr)).frame(width: max(g.size.width * CGFloat(n) / CGFloat(max(total, 1)) - 1, 1)) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 110, height: 8)
        .background(Color(hex: 0xE7E1D4))
        .clipShape(Capsule())
    }
}
