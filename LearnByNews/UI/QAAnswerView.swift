import SwiftUI

/// 구조 상자 문답의 답 (goni 2026-11-20 "설명을 보다 보니 밑줄 긋고 싶다", `**굵게**`가 날것으로 보이던 것).
/// 표시 규칙(웹과 같게): `**x**`는 굵게(** 제거), marks의 각 글자는 표시 글자에서 첫 번째 자리에 빨간 밑줄.
/// 긋기: 단어를 탭(첫 단어) → 다른 단어를 탭(끝 단어, 형광펜과 같은 방식) → 아래 "밑줄 긋기: '…'" → 목록에 더해 PUT. 밑줄 친 단어를 탭하면 그 밑줄을 뺀다
struct QAAnswerView: View {
    var answer: String
    var marks: [String]
    var onSet: (([String]) -> Void)?      // nil이면 보기만
    @State private var from: Int?          // 고르는 중: 첫 단어의 토큰 번호
    @State private var to: Int?

    private struct Token: Identifiable { var id: Int; var text: String; var range: Range<Int>; var line: Int; var bold: Bool; var mark: Int? }   // mark = marks 안 번호

    /// `**` 제거한 표시 글자 + 굵은 범위(표시 글자 기준 오프셋)
    static func display(_ raw: String) -> (String, [Range<Int>]) {
        var out = "", bolds: [Range<Int>] = []
        var open: Int? = nil
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "*", raw.index(after: i) < raw.endIndex, raw[raw.index(after: i)] == "*" {
                if let o = open { bolds.append(o..<out.count); open = nil } else { open = out.count }
                i = raw.index(i, offsetBy: 2); continue
            }
            out.append(raw[i]); i = raw.index(after: i)
        }
        return (out, bolds)
    }

    private var tokens: [Token] {
        let (text, bolds) = Self.display(answer)
        let chars = Array(text)
        // marks → 표시 글자에서 첫 번째 자리
        var markRanges: [(Int, Range<Int>)] = []
        for (mi, m) in marks.enumerated() where !m.isEmpty {
            if let r = text.range(of: m) { let s = text.distance(from: text.startIndex, to: r.lowerBound); markRanges.append((mi, s..<(s + m.count))) }
        }
        var toks: [Token] = []
        var line = 0, i = 0
        while i < chars.count {
            if chars[i] == "\n" { line += 1; i += 1; continue }
            if chars[i] == " " { i += 1; continue }
            var j = i
            while j < chars.count, chars[j] != " ", chars[j] != "\n" { j += 1 }
            let r = i..<j
            let bold = bolds.contains { $0.overlaps(r) }
            let mark = markRanges.first { $0.1.overlaps(r) }?.0
            toks.append(Token(id: toks.count, text: String(chars[r]), range: r, line: line, bold: bold, mark: mark))
            i = j
        }
        return toks
    }

    var body: some View {
        let toks = tokens
        let lines = Dictionary(grouping: toks, by: \.line).sorted { $0.key < $1.key }
        let sel: ClosedRange<Int>? = { if let f = from { return min(f, to ?? f)...max(f, to ?? f) }; return nil }()
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.key) { _, ws in
                FlowLayout(spacing: 0, rowSpacing: 2) {
                    ForEach(ws) { t in
                        let picked = sel.map { $0.contains(t.id) } ?? false
                        let next = toks.indices.contains(t.id + 1) ? toks[t.id + 1] : nil
                        let joinUnderline = t.mark != nil && next?.mark == t.mark && next?.line == t.line   // 같은 밑줄이 다음 단어로 이어지면 사이 공백도 긋는다
                        Button {
                            guard onSet != nil else { return }
                            if let mi = t.mark, from == nil { onSet?(marks.enumerated().filter { $0.offset != mi }.map(\.element)); return }   // 밑줄을 탭 → 뺀다
                            if from == nil { from = t.id; to = nil }
                            else if to == nil { if t.id == from { from = nil } else { to = t.id } }
                            else { from = t.id; to = nil }
                        } label: {
                            // 밑줄은 Text.underline이 아니라 아래 빨간 선(2px)으로: 같은 밑줄이 이어지면 사이 공백까지 끊기지 않게
                            HStack(spacing: 0) {
                                word(t.text, bold: t.bold).overlay(alignment: .bottom) { if t.mark != nil { Rectangle().fill(Theme.red).frame(height: 2) } }
                                word(" ", bold: false).overlay(alignment: .bottom) { if joinUnderline { Rectangle().fill(Theme.red).frame(height: 2) } }
                            }
                            .background(picked ? Theme.markerSelecting : .clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let sel, let onSet, let f = from {
                let text = Self.display(answer).0
                let a = toks[sel.lowerBound].range.lowerBound, b = toks[sel.upperBound].range.upperBound
                let chosen = String(Array(text)[a..<b])
                HStack(spacing: 10) {
                    if to == nil { Text("끝 단어를 누른다").font(Theme.hand(16)).foregroundStyle(Theme.pencil) }
                    Tiny(title: "밑줄 긋기: '\(shorten(chosen, 24))'", color: Theme.red, size: 17) { onSet(Array((marks + [chosen]).prefix(50))); from = nil; to = nil }
                    Tiny(title: "취소", size: 16) { from = nil; to = nil }
                }
                .padding(.top, 2)
                .id(f)
            }
        }
        .task {
            #if DEBUG
            // 화면 확인용: LBN_AUTOMARK=1 이면 두 번째~세 번째 단어를 고른 상태로. =2 이면 바로 "밑줄 긋기"까지 (모의 서버는 PUT을 8초 늦춘다 → 응답 전에 그려지는지)
            let am = ProcessInfo.processInfo.environment["LBN_AUTOMARK"]
            if am == "1" || am == "2", onSet != nil, toks.count > 3 { from = 1; to = 2 }
            if am == "2", let onSet, toks.count > 3, marks.count < 2 {
                let text = Self.display(answer).0
                let chosen = String(Array(text)[toks[1].range.lowerBound..<toks[2].range.upperBound])
                onSet(Array((marks + [chosen]).prefix(50))); from = nil; to = nil
            }
            #endif
        }
    }
    /// 굵게는 손글씨 폰트에 굵은 꼴이 없어 잉크색(진하게)으로
    private func word(_ s: String, bold: Bool) -> Text {
        var t = Text(s).font(Theme.hand(18)).foregroundColor(Theme.pencil)
        if bold { t = t.fontWeight(.bold).foregroundColor(Theme.ink) }
        return t
    }
}
