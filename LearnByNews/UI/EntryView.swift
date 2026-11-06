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

/// 이전 시도 한 줄: 작은 도장 + 연필로 줄 그은 글씨
struct HistoryLine: View {
    var attempt: Attempt
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Stamp(kind: .grade(attempt.grade), small: true).opacity(0.6).padding(.top, 3)
            Text(attempt.translation.isEmpty ? "건너뜀" : attempt.translation)
                .strikethrough(true, color: Theme.pencil)
                .pencil()
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

    var body: some View {
        let a = s.attempt!
        let fb = a.feedback
        Entry(stamp: AnyView(Stamp(kind: .grade(fb.grade))), highlight: highlight) {
            Text(s.text).enLine()
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
        .overlay(alignment: .topTrailing) {
            if let onRemove, fb.grade == .skip {
                Button(action: onRemove) { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(.horizontal, 8).frame(height: Theme.lh) }
                    .buttonStyle(.plain).opacity(0.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
        .contextMenu {
            if let onRedo { Button("다시 쓰기 ↻\u{FE0E}", action: onRedo) }
            if let onRemove { Button("공책에서 빼기", role: .destructive, action: onRemove) }
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
            StickyRow(items: fb.expressions.enumerated().map { (i, e) in (e, savedPhrases.contains { $0.phrase == e.phrase }, i) }, onTap: onTogglePhrase)
        }
    }
}

/// 포스트잇 줄 (가로로 흐르고 넘치면 줄바꿈)
struct StickyRow: View {
    var items: [(Expression, Bool, Int)]
    var onTap: (Expression) -> Void
    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach(items, id: \.0) { e, saved, i in
                Button { onTap(e) } label: { Sticky(phrase: e.phrase, meaning: e.meaning, index: i, pinned: saved) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
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
