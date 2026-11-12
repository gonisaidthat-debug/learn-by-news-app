import SwiftUI

/// 내 번역에서 틀린 구간(issue.mine)을 찾아 빨간 밑줄로 표시 (웹 markWrong)
func markWrong(_ text: String, _ issues: [Issue]) -> AttributedString {
    var out = AttributedString(text)
    var marks: [(Int, Int)] = []
    for i in issues where !i.mine.isEmpty {
        if let r = text.range(of: i.mine) {
            marks.append((text.distance(from: text.startIndex, to: r.lowerBound), i.mine.count))
        }
    }
    var pos = 0
    for (start, len) in marks.sorted(by: { $0.0 < $1.0 }) where start >= pos {
        let a = out.index(out.startIndex, offsetByCharacters: start)
        let b = out.index(a, offsetByCharacters: len)
        out[a..<b].underlineStyle = Text.LineStyle(pattern: .dot, color: Theme.red)
        pos = start + len
    }
    return out
}

/// 원문 문장에서 시험 구간을 빨간 밑줄로 (대소문자 무시, 웹 markSource)
func markSource(_ text: String, _ source: String) -> AttributedString {
    var out = AttributedString(text)
    guard !source.isEmpty, let r = text.range(of: source, options: .caseInsensitive) else { return out }
    let a = out.index(out.startIndex, offsetByCharacters: text.distance(from: text.startIndex, to: r.lowerBound))
    let b = out.index(a, offsetByCharacters: source.count)
    out[a..<b].underlineStyle = Text.LineStyle(pattern: .dot, color: Theme.red)
    return out
}

/// 이전 시도 한 줄: 작은 도장 + 연필로 줄 그은 글씨 + 시각. 누르면 그때의 첨삭이 펼쳐진다
struct HistoryLine: View {
    var attempt: Attempt
    @State private var open = false

    private var when: String {
        let d = Date(ms: attempt.createdAt)
        return "\(d.monthDay) \(d.hm)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Stamp(kind: .grade(attempt.grade), small: true).opacity(0.6)
                    Text(attempt.translation.isEmpty ? "건너뜀" : attempt.translation)
                        .strikethrough(true, color: Theme.pencil)
                        .pencil()
                    Spacer(minLength: 6)
                    Text(when).font(Theme.hand(15)).foregroundStyle(Theme.pencil).opacity(0.8).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                let fb = attempt.feedback
                Group {
                    if fb.issues.isEmpty, fb.grade != .skip {
                        Text("지적 없음").pencil(size: 20)
                    }
                    ForEach(Array(fb.issues.enumerated()), id: \.offset) { _, i in
                        (Text(i.source).underline(true, color: Theme.red) + Text(" →\u{FE0E} \(i.meaning)") + Text(i.why.isEmpty ? "" : " (\(i.why))").font(Theme.hand(19)).foregroundColor(Color(hex: 0xC0565A)))
                            .redpen(size: 21)
                    }
                    if !fb.reference.isEmpty {
                        (Text("참고 ").font(Theme.hand(17)) + Text(fb.reference)).pencil(size: 21)
                    }
                }
                .padding(.leading, 32)
                .opacity(0.85)
            }
        }
    }
}

/// 채점된 문장 한 항목 (웹 Entry.tsx)
struct EntryView: View {
    var s: Sentence
    var expanded: Bool
    var onToggle: (() -> Void)?
    var showRef: Bool
    var onToggleRef: () -> Void
    var savedPhrases: [Phrase]
    var onTogglePhrase: (Expression) -> Void
    var onRemove: (() -> Void)?
    var onRedo: (() -> Void)?
    var highlight = false
    var bookmarked = false
    var onBookmark: (() -> Void)?
    /// 형광펜: 이 문장의 메모들, 묻기(start, end, span), 삭제
    var highlights: [Highlight] = []
    var onAsk: ((Int, Int, String) async throws -> Void)?
    var onDeleteHighlight: ((Highlight) async -> Void)?
    /// 내 메모: 새로 (start, end, span, note) / 기존 형광펜에 (highlight, note)
    var onMemo: ((Int, Int, String, String) async throws -> Void)?
    var onNote: ((Highlight, String) async -> Void)?
    /// 포스트잇에서 바로 "써 보기": 자유 작문 채점(nil이면 큐에 들어감), 문제 내줘(표현장에 없으면 nil), 문제 답 채점
    var onFree: ((Expression, String) async throws -> Drill?)?
    var onDrillFor: ((Expression) async throws -> Drill?)?
    var onAnswerDrill: ((String, String) async throws -> Drill)?
    @State private var tryExpr: Expression?

    var body: some View {
        let a = s.attempt!
        let fb = a.feedback
        Entry(stamp: AnyView(Stamp(kind: .grade(fb.grade))), highlight: highlight) {
            if expanded, let onAsk { MarkerWords(text: s.text, highlights: highlights, onAsk: onAsk, onMemo: onMemo) }
            else { Text(markHighlights(s.text, highlights)).enLine() }
            if expanded {
                ForEach(highlights) { h in
                    MarkerMemo(h: h, onDelete: onDeleteHighlight, onNote: onNote,
                               onTry: onFree == nil ? nil : { tryExpr = Expression(phrase: h.span, meaning: h.hasAnswer ? h.answer.meaning : (h.note ?? "")) })
                }
            }
            if fb.grade == .skip {
                HStack(spacing: 10) {
                    Text("건너뜀").handLine(size: 21, color: Theme.pencil)
                    if let onRedo { Tiny(title: "써 보기 ↻\u{FE0E}", action: onRedo) }
                }
                ForEach(Array(s.history.enumerated()), id: \.offset) { _, h in HistoryLine(attempt: h) }
            } else {
                if a.translation.isEmpty { Text("건너뜀").handLine(size: 21, color: Theme.pencil) }
                else { Text(markWrong(a.translation, fb.issues)).koLine() }
                if expanded { marks(fb) }
            }
        }
        .overlay(alignment: .topLeading) {
            // 책갈피 리본 = 토글 버튼. 왼쪽 여백(빨간 세로선 왼쪽), 도장 바로 아래. 평소엔 흐리게, 꽂히면 빨강
            if let onBookmark {
                Button(action: onBookmark) {
                    Ribbon(active: bookmarked).padding(.horizontal, 10).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bookmarked ? "책갈피 빼기" : "여기에 책갈피")
                .offset(x: Theme.marginW / 2 - 16, y: Theme.lh * 0.25 + 30)
            } else if bookmarked {
                Ribbon(active: true).offset(x: Theme.marginW / 2 - 6, y: Theme.lh * 0.25 + 34)
            }
        }
        .overlay(alignment: .topTrailing) {
            // 문장 ×(공책에서 뺀다)는 오른쪽 위, 책갈피와는 반대쪽
            if let onRemove, fb.grade == .skip {
                Button(action: onRemove) { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(.horizontal, 8).frame(height: Theme.lh) }
                    .buttonStyle(.plain).opacity(0.5)
                    .accessibilityLabel("공책에서 뺀다").help("공책에서 뺀다")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
        .contextMenu {
            if let onBookmark { Button(bookmarked ? "책갈피 빼기" : "책갈피 꽂기", systemImage: "bookmark", action: onBookmark) }
            if let onRedo { Button("다시 쓰기 ↻\u{FE0E}", action: onRedo) }
            if let onRemove { Button("제거 (공책에서 뺀다)", systemImage: "trash", role: .destructive, action: onRemove) }
        }
    }

    @ViewBuilder
    private func marks(_ fb: Feedback) -> some View {
        ForEach(Array(fb.issues.enumerated()), id: \.offset) { _, i in
            (Text(i.source).underline(true, color: Theme.red) + Text(" →\u{FE0E} \(i.meaning)") + Text(i.why.isEmpty ? "" : " (\(i.why))").font(Theme.hand(19)).foregroundColor(Color(hex: 0xC0565A)))
                .redpen()
        }
        if showRef {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (Text("참고 ").font(Theme.hand(17)) + Text(fb.reference)).pencil()
                Tiny(title: "접기", action: onToggleRef)
            }
        } else {
            Tiny(title: "참고 번역 보기", action: onToggleRef).frame(height: Theme.lh)
        }
        ForEach(Array(s.history.enumerated()), id: \.offset) { _, h in HistoryLine(attempt: h) }
        if let onRedo { Tiny(title: "다시 쓰기 ↻\u{FE0E}", action: onRedo).frame(height: Theme.lh) }
        if !fb.expressions.isEmpty {
            StickyRow(items: fb.expressions.enumerated().map { (i, e) in (e, savedPhrases.contains { $0.phrase == e.phrase }, i) }, onTap: onTogglePhrase,
                      onTry: onFree == nil ? nil : { e in tryExpr = e })
        }
        if let e = tryExpr, let onFree {
            TryBox(expr: e, onFree: onFree, onDrillFor: onDrillFor, onAnswerDrill: onAnswerDrill, onClose: { tryExpr = nil })
        }
    }
}

/// 포스트잇 줄 (가로로 흐르고 넘치면 줄바꿈). 포스트잇마다 작은 "써 보기 ✎"
struct StickyRow: View {
    var items: [(Expression, Bool, Int)]
    var onTap: (Expression) -> Void
    var onTry: ((Expression) -> Void)? = nil
    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach(items, id: \.0) { e, saved, i in
                VStack(alignment: .leading, spacing: 2) {
                    Button { onTap(e) } label: { Sticky(phrase: e.phrase, meaning: e.meaning, index: i, pinned: saved) }
                        .buttonStyle(.plain)
                    if let onTry { Tiny(title: "써 보기 ✎\u{FE0E}", size: 17) { onTry(e) }.padding(.leading, 6) }
                }
            }
        }
        .padding(.vertical, 10)
    }
}

/// 포스트잇에서 바로 써 보기: "<표현> — 이 표현으로 네 문장 하나" + 영어 입력 → 채점. "문제 내줘"면 한국어 문장을 받아 같은 상자에서 푼다
struct TryBox: View {
    var expr: Expression
    var onFree: (Expression, String) async throws -> Drill?
    var onDrillFor: ((Expression) async throws -> Drill?)?
    var onAnswerDrill: ((String, String) async throws -> Drill)?
    var onClose: () -> Void
    @State private var answer = ""
    @State private var result: Drill?
    @State private var prompt: Drill?       // "문제 내줘"로 받은 한국어 문장
    @State private var busy = false
    @State private var queued = false
    @State private var msg: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let p = prompt, result == nil {
                (Text(expr.phrase).fontWeight(.bold) + Text(" — 이 문장을 영어로")).handLine(size: 20, color: Theme.pencil)
                Text(p.korean).handLine(size: 23, color: Theme.ink)
            } else if result == nil {
                (Text(expr.phrase).fontWeight(.bold) + Text(" — 이 표현으로 네 문장 하나")).handLine(size: 20, color: Theme.pencil)
            }
            if let r = result, let fb = r.feedback {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Stamp(kind: .grade(fb.grade), small: true)
                    Text(r.answer ?? answer).koLine()
                }
                if fb.usedExpression { Text("✓\u{FE0E} \"\(expr.phrase)\" 사용").handLine(size: 21, color: Theme.grade(.A)) }
                else { Text("✗\u{FE0E} \"\(expr.phrase)\"를 쓰지 않았다").redpen(size: 21) }
                ForEach(Array(fb.issues.enumerated()), id: \.offset) { _, i in
                    (Text(i.mine).strikethrough(true, color: Theme.red) + Text(" →\u{FE0E} \(i.better)") + Text(i.why.isEmpty ? "" : " (\(i.why))").font(Theme.hand(18)).foregroundColor(Color(hex: 0xC0565A))).redpen(size: 21)
                }
                if !fb.reference.isEmpty { (Text("참고 ").font(Theme.hand(17)) + Text(fb.reference)).pencil(size: 21) }
                if !fb.note.isEmpty { Text(fb.note).pencil(size: 21) }
            } else if queued {
                HStack(spacing: 10) { Stamp(kind: .waiting, small: true); Text(answer).koLine() }
                Text("연결되면 채점").pencil(size: 20)
            } else {
                TextField(busy ? "채점 중…" : "영어로 쓴다", text: $answer, axis: .vertical)
                    .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                    .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                    .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                    .focused($focused).disabled(busy)
                    .onChange(of: answer) { _, v in if v.contains("\n") { answer = v.replacingOccurrences(of: "\n", with: " "); Task { await submit() } } }
                if busy { Text("선생님이 보는 중… ✎\u{FE0E}").pencil(size: 20) }
            }
            HStack(spacing: 16) {
                if result != nil || queued {
                    Tiny(title: "한 번 더", color: Theme.red, size: 19) { result = nil; queued = false; answer = ""; prompt = nil; focused = true }
                } else if !busy {
                    if onDrillFor != nil, prompt == nil { Tiny(title: "문제 내줘", size: 19) { Task { await askPrompt() } } }
                }
                Tiny(title: "닫기", size: 19) { onClose() }
                if let msg { ErrorText(message: msg) }
            }
            .frame(minHeight: Theme.lh)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.tab.opacity(0.25))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.tab).frame(width: 3) }
        .padding(.vertical, 6)
        .onAppear { focused = true }
    }

    private func submit() async {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !busy else { return }
        busy = true; msg = nil
        do {
            if let p = prompt, let onAnswerDrill { result = try await onAnswerDrill(p.id, a) }
            else if let r = try await onFree(expr, a) { result = r }
            else { queued = true }
        } catch { msg = error.localizedDescription }
        busy = false
    }
    private func askPrompt() async {
        guard let onDrillFor else { return }
        busy = true; msg = nil
        do {
            if let d = try await onDrillFor(expr) { prompt = d; focused = true }
            else { msg = "포스트잇을 먼저 붙여 줘" }
        } catch { msg = error.localizedDescription }
        busy = false
    }
}

/// 간단한 flow 레이아웃
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: w, height: nil))
            if x + s.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: w, height: nil))
            if x + s.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .init(width: s.width, height: s.height))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// 제목 옆 원문 링크. 없으면 "링크 넣기", 있으면 "원문 ↗\u{FE0E}" + ✎\u{FE0E}
struct SourceLink: View {
    var source: String
    var onSet: (String) async -> Void
    @State private var asking = false
    @State private var draft = ""
    @State private var bad = false

    var body: some View {
        HStack(spacing: 6) {
            if source.isEmpty {
                Tiny(title: "링크 넣기", size: 18) { draft = "https://"; asking = true }
            } else {
                if let u = URL(string: source) { Link("원문 ↗\u{FE0E}", destination: u).font(Theme.hand(18)).foregroundStyle(Theme.blueInk) }
                Tiny(title: "✎\u{FE0E}", size: 16) { draft = source; asking = true }.opacity(0.6)
            }
        }
        .alert("기사 링크", isPresented: $asking) {
            TextField("https://", text: $draft).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("저장") {
                let v = draft.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty, !(v.lowercased().hasPrefix("http://") || v.lowercased().hasPrefix("https://")) { bad = true; return }
                Task { await onSet(v) }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("http(s)://로 시작하는 주소여야 한다", isPresented: $bad) { Button("확인") {} }
    }
}


/// 책갈피 리본. active면 빨강, 아니면 거의 안 보이는 흐린 띠(탭 자리 안내)
struct Ribbon: View {
    var active = true
    var body: some View {
        Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 14, y: 0)); p.addLine(to: CGPoint(x: 14, y: 24))
            p.addLine(to: CGPoint(x: 7, y: 18)); p.addLine(to: CGPoint(x: 0, y: 24)); p.closeSubpath()
        }
        .fill(active ? Theme.red : Theme.pencil.opacity(0.18))
        .frame(width: 14, height: 24)
        .shadow(color: active ? .black.opacity(0.2) : .clear, radius: 1, y: 1)
    }
}


// MARK: - 형광펜

/// 공백 분리 단어 조각과 문자 범위 (인덱스 0부터)
func wordPieces(_ text: String) -> [(word: String, range: Range<String.Index>)] {
    var out: [(String, Range<String.Index>)] = []
    var i = text.startIndex
    while i < text.endIndex {
        while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
        guard i < text.endIndex else { break }
        var j = i
        while j < text.endIndex, text[j] != " " { j = text.index(after: j) }
        out.append((String(text[i..<j]), i..<j)); i = j
    }
    return out
}

/// 접힌 상태: 칠해진 단어를 노란 배경으로
func markHighlights(_ text: String, _ hs: [Highlight]) -> AttributedString {
    var out = AttributedString(text)
    guard !hs.isEmpty else { return out }
    let pieces = wordPieces(text)
    for h in hs {
        let lo = max(0, h.startWord), hi = min(pieces.count - 1, h.endWord)
        guard lo <= hi else { continue }
        let r = pieces[lo].range.lowerBound..<pieces[hi].range.upperBound
        let a = out.index(out.startIndex, offsetByCharacters: text.distance(from: text.startIndex, to: r.lowerBound))
        let b = out.index(out.startIndex, offsetByCharacters: text.distance(from: text.startIndex, to: r.upperBound))
        out[a..<b].backgroundColor = Theme.marker
    }
    return out
}

/// 펼친 상태: 단어 조각을 탭해 구간을 고르고 "이게 뭐야? 🖍"로 묻는다 (첫 단어·끝 단어 두 번 누르기)
struct MarkerWords: View {
    var text: String
    var highlights: [Highlight]
    var onAsk: (Int, Int, String) async throws -> Void
    var onMemo: ((Int, Int, String, String) async throws -> Void)? = nil
    @State private var anchor: Int?
    @State private var range: ClosedRange<Int>?
    @State private var asking = false
    @State private var err: String?
    @State private var writing = false      // "메모 ✎" 입력란 열림
    @State private var noteText = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        let pieces = wordPieces(text)
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 0) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { i, p in
                    // 같은 형광펜(또는 같은 선택)에 속한 이웃 단어와는 사이 공백까지 한 덩어리로, 모서리는 양끝만 둥글게
                    let picking = range.map { $0.contains(i) } ?? false
                    let savedRun = highlights.first { i >= $0.startWord && i <= $0.endWord }
                    let color: Color? = picking ? Theme.markerSelecting : (savedRun != nil ? Theme.marker : nil)
                    let joinNext: Bool = picking ? (range?.contains(i + 1) ?? false) : (savedRun.map { i + 1 <= $0.endWord } ?? false)
                    let joinPrev: Bool = picking ? (range?.contains(i - 1) ?? false) : (savedRun.map { i - 1 >= $0.startWord } ?? false)
                    HStack(spacing: 0) {
                        Text(p.word).font(Theme.print(16)).foregroundStyle(Theme.ink).padding(.vertical, 2)
                            .background(color ?? .clear, in: UnevenRoundedRectangle(topLeadingRadius: joinPrev ? 0 : 4, bottomLeadingRadius: joinPrev ? 0 : 4, bottomTrailingRadius: joinNext ? 0 : 4, topTrailingRadius: joinNext ? 0 : 4))
                        Text(" ").font(Theme.print(16)).padding(.vertical, 2).background(joinNext ? (color ?? .clear) : .clear)
                    }
                    .frame(height: Theme.lh)
                    .contentShape(Rectangle())
                    .onTapGesture { tap(i) }
                }
            }
            if let r = range {
                let span = pieces[r].map(\.word).joined(separator: " ")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) {
                        if asking {
                            Text("묻는 중… 🖍").font(Theme.hand(20)).foregroundStyle(Theme.pencil)
                        } else if writing {
                            // 내가 느낀 걸 적는다. Enter 저장, Esc 취소
                            TextField("내 메모", text: $noteText)
                                .font(Theme.hand(21)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                                .focused($noteFocused).submitLabel(.done)
                                .onSubmit { Task { await saveMemo(r, span) } }
                                .autocorrectionDisabled()
                            Tiny(title: "저장") { Task { await saveMemo(r, span) } }
                            Tiny(title: "취소") { writing = false; noteText = "" }
                                .keyboardShortcut(.escape, modifiers: [])
                        } else {
                            Tiny(title: "이게 뭐야? 🖍", color: Theme.red) { Task { await ask(r, span) } }
                            if onMemo != nil { Tiny(title: "메모 ✎\u{FE0E}") { writing = true; noteText = ""; noteFocused = true } }
                            Tiny(title: "취소") { anchor = nil; range = nil; err = nil }
                        }
                    }
                    if let err { ErrorText(message: err) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.marker.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    Triangle().fill(Theme.marker.opacity(0.6)).frame(width: 12, height: 8).offset(x: 16, y: -7)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func tap(_ i: Int) {
        guard !asking else { return }
        err = nil
        if let a = anchor, let r = range, r.count == 1, r.lowerBound == a {
            range = min(a, i)...max(a, i)          // 두 번째 탭: 그 사이를 한 덩어리로 (앞 단어여도 됨)
        } else {
            anchor = i; range = i...i              // 첫 탭 또는 세 번째 탭: 새 시작
        }
    }

    private func ask(_ r: ClosedRange<Int>, _ span: String) async {
        asking = true; err = nil
        do { try await onAsk(r.lowerBound, r.upperBound, span); anchor = nil; range = nil }
        catch { err = error.localizedDescription }
        asking = false
    }
    private func saveMemo(_ r: ClosedRange<Int>, _ span: String) async {
        let n = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let onMemo else { return }
        err = nil
        do { try await onMemo(r.lowerBound, r.upperBound, span, n); writing = false; noteText = ""; anchor = nil; range = nil }
        catch { err = error.localizedDescription }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p }
}

/// 형광펜 메모: "구절 → 뜻 (이유) · 비슷한 말: …" (Claude 답, 있으면) + "✎ 내 메모"(파란 손글씨) + 메모 넣기/고치기 + ×
struct MarkerMemo: View {
    var h: Highlight
    var onDelete: ((Highlight) async -> Void)?
    var onNote: ((Highlight, String) async -> Void)? = nil
    var onTry: (() -> Void)? = nil
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if h.hasAnswer {
                    (Text(h.span).fontWeight(.bold).foregroundColor(Color(hex: 0x2A2412)) + Text(" →\u{FE0E} \(h.answer.meaning)")
                     + Text(h.answer.why.isEmpty ? "" : " (\(h.answer.why))").font(Theme.hand(18))
                     + Text(h.answer.similar.isEmpty ? "" : " · 비슷한 말: \(h.answer.similar)").font(Theme.hand(18)))
                        .font(Theme.hand(20)).foregroundStyle(Color(hex: 0x5B5440))
                } else {
                    Text(h.span).font(Theme.hand(20)).fontWeight(.bold).foregroundStyle(Color(hex: 0x2A2412))
                }
                Spacer(minLength: 0)
                if let onDelete {
                    Button { Task { await onDelete(h) } } label: { Text("×").font(.system(size: 16)).foregroundStyle(Theme.pencil).padding(.horizontal, 4) }
                        .buttonStyle(.plain).accessibilityLabel("형광펜 지우기")
                }
            }
            if editing {
                HStack(spacing: 10) {
                    TextField("내 메모", text: $text).font(Theme.hand(20)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                        .focused($focused).submitLabel(.done).autocorrectionDisabled()
                        .onSubmit { Task { await save() } }
                    Tiny(title: "저장", size: 18) { Task { await save() } }
                    Tiny(title: "취소", size: 18) { editing = false }.keyboardShortcut(.escape, modifiers: [])
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let n = h.note, !n.isEmpty { Text("✎\u{FE0E} \(n)").font(Theme.hand(20)).foregroundStyle(Theme.blueInk) }
                    if onNote != nil {
                        Tiny(title: (h.note ?? "").isEmpty ? "내 메모 ✎\u{FE0E}" : "메모 고치기", size: 17) { text = h.note ?? ""; editing = true; focused = true }
                    }
                    if let onTry { Tiny(title: "써 보기 ✎\u{FE0E}", size: 17, action: onTry) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.marker.opacity(0.55))
        .padding(.vertical, 3)
    }
    private func save() async {
        guard let onNote else { return }
        await onNote(h, text.trimmingCharacters(in: .whitespacesAndNewlines)); editing = false
    }
}
