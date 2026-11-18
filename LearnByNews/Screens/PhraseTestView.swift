import SwiftUI

/// 표현장 시험 (웹 PhraseTest.tsx, goni 2026-11-18): 시험지의 포스트잇 카드(영어→뜻)와 반대로 **뜻 → 영어 표현을 떠올려 쓴다**.
/// Enter로 확인 — 소문자·구두점·공백·앞의 to/a/an/the를 무시하고 같으면 바로 "맞았다 ○"(기록), 아니면 답 포스트잇 + 내 답(취소선) + 스스로 ○/×.
/// 순서는 시험지와 같이 안 본 것 → 틀린 것 → 맞힌 것. 기록은 POST /api/quiz/results에 key "pr|<id>"(오프라인이면 큐). 오프라인이면 캐시 표현(습득 완료 제외)으로 카드
@MainActor
final class PhraseTestModel: ObservableObject {
    enum Reveal { case right, wrong }
    @Published var all: [PhraseTestItem]?
    @Published var items: [PhraseTestItem] = []
    @Published var i = 0
    @Published var answer = ""
    @Published var hint = false
    @Published var revealed: Reveal?
    @Published var right = 0
    @Published var wrong = 0
    @Published var mastered: Set<String> = []
    @Published var err: String?

    var current: PhraseTestItem? { i < items.count ? items[i] : nil }
    var done: Bool { all != nil && i >= items.count }
    var fresh: Int { items.filter { $0.lastCorrect == nil }.count }
    var missed: Int { items.filter { $0.lastCorrect == false }.count }

    func load() async {
        if all == nil, let c = Cache.shared.phraseTest() { all = c; rebuild() }
        do { all = try await API.shared.phraseTest(); rebuild(); err = nil }
        catch let e as APIError where e.isNetwork { if all == nil { err = e.localizedDescription } }
        catch { err = error.localizedDescription }
    }
    /// 안 본 것 → 틀린 것 → 맞힌 것(오래된 순). 같은 묶음 안에서는 섞는다 (시험지와 같은 규칙)
    private func rebuild() {
        func bucket(_ it: PhraseTestItem) -> Int { it.lastCorrect == nil ? 0 : (it.lastCorrect! ? 2 : 1) }
        items = (all ?? []).shuffled().sorted { a, b in
            let (ba, bb) = (bucket(a), bucket(b))
            return ba != bb ? ba < bb : (a.lastAt ?? 0) < (b.lastAt ?? 0)
        }
    }
    func restart() { i = 0; answer = ""; hint = false; revealed = nil; right = 0; wrong = 0; rebuild() }
    func next() { i += 1; answer = ""; hint = false; revealed = nil }

    /// 비교용: 소문자, 구두점 제거, 공백 정리, 앞의 to/a/an/the 떼기 (웹 norm과 같다)
    static func norm(_ t: String) -> String {
        var w = t.lowercased().replacingOccurrences(of: "’", with: "'")
        w = String(w.map { ($0.isLetter && $0.isASCII) || ($0.isNumber && $0.isASCII) || $0 == "'" || $0 == " " ? $0 : " " })
        w = w.split(separator: " ").joined(separator: " ")
        for art in ["to ", "a ", "an ", "the "] where w.hasPrefix(art) { w = String(w.dropFirst(art.count)); break }
        return w
    }
    /// 제출: 맞으면 바로 기록하고 보여 준다. 아니면 답을 보여 주고 ○/×를 기다린다
    func check() {
        guard let it = current, revealed == nil else { return }
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        if Self.norm(a) == Self.norm(it.phrase) { revealed = .right; right += 1; record(it, true) }
        else { revealed = .wrong }
    }
    func giveUp() { if current != nil, revealed == nil { revealed = .wrong } }
    /// 틀렸을 때 스스로 매기기
    func mark(_ correct: Bool) {
        guard let it = current, revealed == .wrong else { return }
        if correct { right += 1 } else { wrong += 1 }
        record(it, correct); next()
    }
    private func record(_ it: PhraseTestItem, _ correct: Bool) {
        AppLog.shared.info("phrasetest", correct ? "right" : "wrong", ["key": it.key])
        Task { do { try await SyncManager.shared.answerQuiz(key: it.key, sentenceId: it.sentenceId ?? "", source: it.phrase, correct: correct) } catch { err = error.localizedDescription } }
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
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NotebookHead(tab: "\(min(m.i + 1, m.items.count)) / \(m.items.count)") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("표현장 시험")
                        Tiny(title: "←\u{FE0E} 표현장", size: 17) { dismiss() }
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
            // 화면 확인용: LBN_TESTANSWER=right|wrong 이면 첫 카드에 답을 넣고 확인한다
            if let v = ProcessInfo.processInfo.environment["LBN_TESTANSWER"], let it = m.current { m.answer = v == "right" ? it.phrase : "keep the rate"; m.check() }
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
                Text("표현장에 붙은 표현 중 습득 완료가 아닌 것이 문제가 된다.").pencil()
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
            Entry(stamp: AnyView(Stamp(kind: .pin))) {
                Text(it.meaning.isEmpty ? "(뜻 없음)" : it.meaning).handLine(size: 25, color: Theme.ink)
                Text("이 뜻의 영어 표현은?").pencil()
                if let t = it.sentenceText, !t.isEmpty, m.hint || m.revealed != nil {
                    (m.revealed != nil ? Text(markSource(t, it.phrase)) : blank(t, it.phrase)).enLine()
                }
                if m.revealed == nil {
                    TextField("영어로 쓰고 Enter", text: $m.answer, axis: .vertical)
                        .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                        .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                        .onChange(of: m.answer) { _, v in
                            if v.contains("\n") { m.answer = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces); m.check() }
                        }
                } else {
                    if !m.answer.isEmpty {
                        if m.revealed == .right { Text("○\u{FE0E} \(m.answer)").handLine(size: 22, color: Theme.grade(.A)) }
                        else { (Text("✗\u{FE0E} ") + Text(m.answer).strikethrough(true, color: Theme.red)).handLine(size: 22, color: Theme.red) }
                    }
                    Sticky(phrase: it.phrase, meaning: it.meaning, index: 0, mastered: m.mastered.contains(it.id)).padding(.vertical, 10)
                    if let aid = it.articleId, !aid.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            (Text("출처 ").font(Theme.hand(17)) + Text("\(it.articleTitle ?? "")" + (it.sentenceIdx.map { " · \($0 + 1)번째 문장" } ?? ""))).pencil()
                            Tiny(title: "공책에서 보기 →\u{FE0E}") { router.open(.notebook(id: aid, focus: it.sentenceId)) }
                        }
                    }
                    if it.tries > 0 { (Text("기록 ").font(Theme.hand(17)) + Text("\(it.tries)번 중 \(it.wrong)번 몰랐음")).pencil() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 18) {
                    switch m.revealed {
                    case nil:
                        if let t = it.sentenceText, !t.isEmpty, !m.hint { Tiny(title: "문장 힌트") { m.hint = true; focused = true } }
                        Tiny(title: "모르겠다 · 답 보기") { m.giveUp() }
                        MutedText(text: "Enter로 확인 · 안 본 것 \(m.fresh) · 틀렸던 것 \(m.missed)")
                    case .right:
                        Tiny(title: "맞았다 ○ · 다음 ↵\u{FE0E}", color: Theme.grade(.A)) { m.next(); focused = true }.keyboardShortcut(.return, modifiers: [])
                        if m.mastered.contains(it.id) { MutedText(text: "습득 완료로 찍었다") }
                        else { Tiny(title: "습득 완료 ✓\u{FE0E}") { Task { await m.master() } }.help("다 익혔다. 표현장에 남고 응용·시험에서 빠진다") }
                    case .wrong:
                        Tiny(title: "그래도 알았다 ○", color: Theme.grade(.A)) { m.mark(true); focused = true }.keyboardShortcut("1", modifiers: [])
                        Tiny(title: "몰랐다 ×", color: Theme.red) { m.mark(false); focused = true }.keyboardShortcut("2", modifiers: [])
                    }
                }
                if let e = m.err { ErrorText(message: e) }
            }
            .frame(minHeight: Theme.lh).padding(.top, Theme.lh)
            .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
        }
    }
}
