import SwiftUI

/// 시험지 (웹 Quiz.tsx)
@MainActor
final class QuizModel: ObservableObject {
    enum Deck: String, CaseIterable { case all, issue, phrase }
    @Published var all: [QuizItem]?
    @Published var deck: Deck = .all
    @Published var items: [QuizItem] = []
    @Published var i = 0
    @Published var answer = ""
    @Published var revealed = false
    @Published var right = 0
    @Published var wrong = 0
    @Published var err: String?

    var current: QuizItem? { i < items.count ? items[i] : nil }
    var done: Bool { all != nil && i >= items.count }
    var issueCount: Int { (all ?? []).filter { $0.kind == .issue }.count }
    var phraseCount: Int { (all ?? []).filter { $0.kind == .phrase }.count }
    var fresh: Int { items.filter { $0.lastCorrect == nil }.count }
    var missed: Int { items.filter { $0.lastCorrect == false }.count }

    func load() async {
        do { all = try await API.shared.quiz(); rebuild() } catch { err = error.localizedDescription }
    }

    /// 안 본 것 → 틀린 것 → 맞힌 것(오래된 순). 같은 묶음 안에서는 섞는다
    private func rebuild() {
        let xs = (all ?? []).filter { deck == .all || $0.kind.rawValue == deck.rawValue }.shuffled()
        func bucket(_ it: QuizItem) -> Int { it.lastCorrect == nil ? 0 : (it.lastCorrect! ? 2 : 1) }
        items = xs.sorted { a, b in
            let (ba, bb) = (bucket(a), bucket(b))
            return ba != bb ? ba < bb : (a.lastAt ?? 0) < (b.lastAt ?? 0)
        }
    }

    func restart(_ d: Deck) {
        deck = d; i = 0; answer = ""; revealed = false; right = 0; wrong = 0
        rebuild()
    }
    func reveal() { if !revealed { revealed = true } }
    func mark(_ correct: Bool) {
        guard let it = current, revealed else { return }
        if correct { right += 1 } else { wrong += 1 }
        revealed = false; answer = ""; i += 1
        AppLog.shared.info("quiz", correct ? "right" : "wrong", ["key": it.key])
        Task {
            do { try await API.shared.answerQuiz(it, correct: correct) } catch { err = error.localizedDescription }
        }
    }
}

struct QuizView: View {
    @EnvironmentObject var router: Router
    @StateObject private var m = QuizModel()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookHead(tab: "\(min(m.i + 1, m.items.count)) / \(m.items.count)") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("시험지")
                            HStack(spacing: 10) {
                                ForEach(QuizModel.Deck.allCases, id: \.self) { d in
                                    let label = d == .all ? "전부" : d == .issue ? "빨간 줄 \(m.issueCount)" : "포스트잇 \(m.phraseCount)"
                                    Tiny(title: label, color: m.deck == d ? Theme.ink : Theme.pencil, size: 19) { m.restart(d); focused = true }
                                        .overlay(alignment: .bottom) { if m.deck == d { Rectangle().fill(Theme.red).frame(height: 2) } }
                                }
                            }
                        }
                    }
                    Paper { paper }
                }
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 40, trailing: 10))
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.desk.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { if m.all == nil { await m.load() } }
            .refreshable { await m.load(); m.restart(m.deck) }
        }
    }

    @ViewBuilder
    private var paper: some View {
        if let e = m.err, m.all == nil {
            Entry { ErrorText(message: e) }
        } else if m.all == nil {
            Entry { Text("…").pencil() }
        } else if m.items.isEmpty {
            Entry {
                Text("아직 문제가 없다").font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
                Text("빨간 줄이 그어지거나 포스트잇을 붙이면 여기 쌓인다.").pencil()
            }
        } else if m.done {
            Entry {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("\(m.right) / \(m.right + m.wrong)")
                        .font(Theme.hand(56)).foregroundStyle(Theme.red)
                        .padding(.horizontal, 14).padding(.vertical, 2)
                        .overlay(Ellipse().strokeBorder(Theme.red, lineWidth: 3)).rotationEffect(.degrees(-6))
                    Text("알았다 \(m.right) · 몰랐다 \(m.wrong)").font(Theme.hand(22)).foregroundStyle(Theme.pencil)
                }
                .frame(minHeight: Theme.lh * 2)
                Tiny(title: "다시 풀기 ↻\u{FE0E}") { m.restart(m.deck); focused = true }.frame(height: Theme.lh).padding(.top, 8)
            }
        } else if let it = m.current {
            let isPhrase = it.kind == .phrase
            Entry(stamp: AnyView(Stamp(kind: isPhrase ? .pin : .question))) {
                if let t = it.sentenceText, !t.isEmpty { Text(markSource(t, it.source)).enLine() }
                else { Text(it.source).enLine() }
                (Text(isPhrase ? "포스트잇 " : "밑줄 친 ") + Text(it.source).foregroundColor(Theme.ink).underline(true, color: Theme.red) + Text(" — 무슨 뜻?")).pencil()
                if !m.revealed {
                    TextField("답을 쓰고 Enter (안 써도 됨)", text: $m.answer, axis: .vertical)
                        .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                        .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                        .focused($focused)
                        .onChange(of: m.answer) { _, v in
                            if v.contains("\n") { m.answer = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces); m.reveal() }
                        }
                } else {
                    if !m.answer.isEmpty { Text(m.answer).koLine() }
                    if isPhrase {
                        Sticky(phrase: it.source, meaning: it.meaning, index: 0).padding(.vertical, 10)
                    } else {
                        (Text(it.source).underline(true, color: Theme.red) + Text(" →\u{FE0E} \(it.meaning)") + Text((it.why ?? "").isEmpty ? "" : " (\(it.why!))").font(Theme.hand(19)).foregroundColor(Color(hex: 0xC0565A))).redpen()
                        if let mine = it.mine, !mine.isEmpty {
                            (Text("그때 내가 쓴 것: ") + Text(mine).strikethrough(true, color: Theme.pencil)).pencil()
                        }
                    }
                    if let aid = it.articleId, !aid.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            (Text("출처 ").font(Theme.hand(17)) + Text("\(it.articleTitle ?? "") · \((it.sentenceIdx ?? 0) + 1)번째 문장")).pencil()
                            Tiny(title: "공책에서 보기 →\u{FE0E}") { router.open(.notebook(id: aid, focus: it.sentenceId)) }
                        }
                    }
                    if it.tries > 0 {
                        (Text("기록 ").font(Theme.hand(17)) + Text("\(it.tries)번 중 \(it.wrong)번 몰랐음")).pencil()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if !m.revealed {
                    HStack(spacing: 18) {
                        Tiny(title: "답 보기") { m.reveal() }
                        MutedText(text: "안 본 것 \(m.fresh) · 틀렸던 것 \(m.missed)")
                    }
                } else {
                    HStack(spacing: 18) {
                        Tiny(title: "알았다 ○", color: Theme.grade(.A)) { m.mark(true); focused = true }
                        Tiny(title: "몰랐다 ×", color: Theme.red) { m.mark(false); focused = true }
                    }
                }
                if let e = m.err { ErrorText(message: e) }
            }
            .frame(minHeight: Theme.lh).padding(.top, Theme.lh)
            .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
        }
    }
}
