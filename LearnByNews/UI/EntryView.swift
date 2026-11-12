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
    /// 채점된 문장끼리 합치기 (같은 문단의 앞/뒤 문장이 있을 때만). 두 문장의 기록은 남고, 합쳐진 문장을 다시 쓴다
    var onMergePrev: (() -> Void)?
    var onMergeNext: (() -> Void)?
    var highlight = false
    var bookmarked = false
    var onBookmark: (() -> Void)?
    /// 형광펜: 이 문장의 메모들, 묻기(start, end, span), 삭제
    var highlights: [Highlight] = []
    var onAsk: ((Int, Int, String) async throws -> Void)?
    var onDeleteHighlight: ((Highlight) async -> Void)?
    /// 내 메모: 새로 (start, end, span, note) / 기존 형광펜에 (highlight, note)
    var onMemo: ((Int, Int, String, String, [Related]) async throws -> Void)?
    var onNote: ((Highlight, String) async -> Void)?
    /// 엮기: 후보 찾기, 링크 추가/풀기, 다른 문장으로 이동
    var onRelated: ((String?, String?, String?, String?) async -> [Related])?
    var onAddLink: ((Highlight, Related) async -> Void)?
    var onRemoveLink: ((Highlight, HighlightLink) async -> Void)?
    var onOpenSentence: ((String, String) -> Void)?
    /// 포스트잇에서 바로 "써 보기": 자유 작문 채점(nil이면 큐에 들어감), 문제 내줘(표현장에 없으면 nil), 문제 답 채점
    var onFree: ((Expression, String) async throws -> Drill?)?
    var onDrillFor: ((Expression) async throws -> Drill?)?
    var onAnswerDrill: ((String, String) async throws -> Drill)?
    var drillCounts: [String: Int] = [:]
    var onDrillGraded: ((String) -> Void)?      // 상자에서 채점이 끝났다 → 그 표현 횟수 +1
    @State private var tryExpr: Expression?

    var body: some View {
        let a = s.attempt!
        let fb = a.feedback
        Entry(stamp: AnyView(Stamp(kind: .grade(fb.grade))), highlight: highlight) {
            if expanded, let onAsk { MarkerWords(text: s.text, sentenceId: s.id, highlights: highlights, onAsk: onAsk, onMemo: onMemo, onNote: onNote, onDelete: onDeleteHighlight, onRelated: onRelated) }
            else { Text(markHighlights(s.text, highlights)).enLine() }
            if expanded {
                ForEach(highlights) { h in
                    MarkerMemo(h: h, onDelete: onDeleteHighlight, onNote: onNote,
                               onTry: onFree == nil ? nil : { let e = Expression(phrase: h.span, meaning: h.hasAnswer ? h.answer.meaning : (h.note ?? "")); tryExpr = tryExpr == e ? nil : e },
                               tryTitle: tryExpr?.phrase == h.span ? "접기" : tryTitle(h.span), tryCount: tryExpr?.phrase == h.span ? 0 : (drillCounts[h.span] ?? 0),
                               onRelated: onRelated, onAddLink: onAddLink, onRemoveLink: onRemoveLink, onOpenSentence: onOpenSentence)
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

    /// "써 보기 ✎" 또는 "써 보기 ✎ · n"
    private func tryTitle(_ phrase: String) -> String {
        let n = drillCounts[phrase] ?? 0
        return n > 0 ? "써 보기 ✎\u{FE0E} · \(n)" : "써 보기 ✎\u{FE0E}"
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
        if onRedo != nil || onMergePrev != nil || onMergeNext != nil {
            HStack(spacing: 16) {
                if let onRedo { Tiny(title: "다시 쓰기 ↻\u{FE0E}", action: onRedo) }
                if let onMergePrev { Tiny(title: "↑\u{FE0E} 앞과 합치기", action: onMergePrev).help("두 문장의 기록은 남고, 합쳐진 문장을 다시 쓴다") }
                if let onMergeNext { Tiny(title: "↓\u{FE0E} 뒤와 합치기", action: onMergeNext).help("두 문장의 기록은 남고, 합쳐진 문장을 다시 쓴다") }
            }
            .frame(height: Theme.lh)
        }
        if !fb.expressions.isEmpty {
            StickyRow(items: fb.expressions.enumerated().map { (i, e) in (e, savedPhrases.contains { $0.phrase == e.phrase }, i) }, onTap: onTogglePhrase,
                      onTry: onFree == nil ? nil : { e in tryExpr = tryExpr == e ? nil : e },
                      tryLabel: { e in tryExpr == e ? "접기" : tryTitle(e.phrase) }, counts: drillCounts, openPhrase: tryExpr?.phrase,
                      backlinks: { e in savedPhrases.first { $0.phrase == e.phrase }?.backlinks ?? [] }, onOpenSentence: onOpenSentence)
        }
        if let e = tryExpr, let onFree {
            TryBox(expr: e, onFree: onFree, onDrillFor: onDrillFor, onAnswerDrill: onAnswerDrill, onClose: { tryExpr = nil }, onGraded: { onDrillGraded?(e.phrase) })
        }
    }
}

/// 포스트잇 줄 (가로로 흐르고 넘치면 줄바꿈). 포스트잇마다 작은 "써 보기 ✎"
struct StickyRow: View {
    var items: [(Expression, Bool, Int)]
    var onTap: (Expression) -> Void
    var onTry: ((Expression) -> Void)? = nil
    var tryLabel: ((Expression) -> String)? = nil
    var counts: [String: Int] = [:]
    var openPhrase: String? = nil
    var backlinks: ((Expression) -> [Backlink])? = nil
    var onOpenSentence: ((String, String) -> Void)? = nil
    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach(items, id: \.0) { e, saved, i in
                VStack(alignment: .leading, spacing: 2) {
                    Button { onTap(e) } label: { Sticky(phrase: e.phrase, meaning: e.meaning, index: i, pinned: saved) }
                        .buttonStyle(.plain)
                    if let onTry {
                        TryButton(title: openPhrase == e.phrase ? "접기" : "써 보기 ✎\u{FE0E}", count: openPhrase == e.phrase ? 0 : (counts[e.phrase] ?? 0)) { onTry(e) }
                            .padding(.leading, 6)
                    }
                    // 이 표현을 가리키는 형광펜들 (거꾸로 링크)
                    ForEach(backlinks?(e) ?? []) { b in
                        BacklinkLine(b: b, onOpen: onOpenSentence).padding(.leading, 6)
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }
}

/// "← text · 기사제목" (연필색). 탭하면 그 문장으로
struct BacklinkLine: View {
    var b: Backlink
    var onOpen: ((String, String) -> Void)?
    var body: some View {
        Button {
            if let a = b.articleId, let sid = b.sentenceId { onOpen?(a, sid) }
        } label: {
            Text("←\u{FE0E} \(b.text ?? "") · \(shorten(b.title ?? ""))").font(Theme.hand(16)).foregroundStyle(Theme.pencil).lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(b.title ?? "")에서 다시 봄")
        .help("\(b.title ?? "")에서 다시 봄")
    }
}

/// "↗ text · 기사제목" (남색, 점선 밑줄) + × 풀기
struct LinkLine: View {
    var l: HighlightLink
    var onOpen: ((String, String) -> Void)?
    var onRemove: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let a = l.articleId, let sid = l.sentenceId { onOpen?(a, sid) }
            } label: {
                Text("↗\u{FE0E} \(l.text ?? "") · \(shorten(l.title ?? ""))").font(Theme.hand(17)).foregroundStyle(Theme.blueInk).underline(true, pattern: .dot, color: Theme.blueInk).lineLimit(1)
            }
            .buttonStyle(.plain)
            if let onRemove {
                Button(action: onRemove) { Text("×").font(.system(size: 13)).foregroundStyle(Theme.pencil).padding(.horizontal, 3) }
                    .buttonStyle(.plain).accessibilityLabel("엮기 풀기")
            }
        }
    }
}

func shorten(_ t: String, _ n: Int = 22) -> String { t.count > n ? String(t.prefix(n)) + "…" : t }

/// 엮을 후보 칩들: "전에 본 것 (누르면 엮임)" + 점선 노란 알약, "다른 구절 찾기…"
struct RelatedChips: View {
    var span: String
    var excludeSentence: String?
    var exclude: String?
    var selectedKeys: Set<String>
    var onToggle: (Related) -> Void
    var load: (String?, String?, String?, String?) async -> [Related]
    @State private var items: [Related] = []
    @State private var loaded = false
    @State private var searching = false
    @State private var q = ""
    @FocusState private var qFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("전에 본 것 (누르면 엮임)").font(Theme.hand(16)).foregroundStyle(Theme.pencil)
                Tiny(title: searching ? "닫기" : "다른 구절 찾기…", size: 16) { searching.toggle(); if searching { qFocused = true } }
            }
            if searching {
                TextField("구절·메모·뜻으로 찾기", text: $q).font(Theme.hand(19)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                    .focused($qFocused).submitLabel(.search).autocorrectionDisabled()
                    .onSubmit { Task { items = await load(nil, q, excludeSentence, exclude) } }
            }
            if !loaded {
                Text("찾는 중…").font(Theme.hand(16)).foregroundStyle(Theme.pencil)
            } else if items.isEmpty {
                Text(searching && !q.isEmpty ? "없다" : "어근이 같은 구절은 없다").font(Theme.hand(16)).foregroundStyle(Theme.pencil)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(items) { r in
                        let on = selectedKeys.contains(r.key)
                        Button { onToggle(r) } label: {
                            Text("\(on ? "✓" : "↗\u{FE0E}") \(r.text) · \(shorten(r.title ?? ""))")
                                .font(Theme.hand(16)).foregroundStyle(on ? Theme.ink : Color(hex: 0x5B5440)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(on ? Theme.marker : Theme.marker.opacity(0.35), in: Capsule())
                                .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: on ? [] : [3, 2])).foregroundStyle(Theme.ink.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { items = await load(span, nil, excludeSentence, exclude); loaded = true }
    }
}

/// "써 보기 ✎ · 2" — 횟수는 잉크색 굵게, 0이면 안 붙임
struct TryButton: View {
    var title: String
    var count: Int
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            (Text(title).foregroundColor(Theme.pencil) + Text(count > 0 ? " · " : "").foregroundColor(Theme.pencil) + Text(count > 0 ? "\(count)" : "").fontWeight(.bold).foregroundColor(Theme.ink))
                .font(Theme.hand(17))
        }
        .buttonStyle(.plain)
    }
}

/// 포스트잇에서 바로 써 보기: "<표현> — 이 표현으로 네 문장 하나" + 영어 입력 → 채점. "문제 내줘"면 한국어 문장을 받아 같은 상자에서 푼다
struct TryBox: View {
    var expr: Expression
    var onFree: (Expression, String) async throws -> Drill?
    var onDrillFor: ((Expression) async throws -> Drill?)?
    var onAnswerDrill: ((String, String) async throws -> Drill)?
    var onClose: () -> Void
    var onGraded: (() -> Void)? = nil
    @State private var answer = ""
    @State private var result: Drill?
    @State private var prompt: Drill?       // "문제 내줘"로 받은 한국어 문장
    @State private var busy = false
    @State private var queued = false
    @State private var msg: String?
    @State private var past: [Drill] = []      // 같은 표현으로 푼 지난 시도 (최신순, 최대 10)
    @State private var openPast: String?       // 탭해서 펼친 지난 시도
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
                if !fb.reference.isEmpty { (Text("참고 ").font(Theme.hand(17)) + Text(fb.referenceLine)).pencil(size: 21) }
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
            if !past.isEmpty {
                Text("지난 시도 \(past.count)").font(Theme.hand(17)).foregroundStyle(Theme.pencil).padding(.top, 4)
                ForEach(past.prefix(10)) { d in
                    let isOpen = openPast == d.id
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let g = d.grade { Stamp(kind: .grade(g), small: true) } else { Stamp(kind: .waiting, small: true) }
                            Text(d.answer ?? "").font(Theme.hand(19)).foregroundStyle(Theme.blueInk).lineLimit(isOpen ? nil : 1)
                            if !d.isFree, !d.korean.isEmpty { Text("· \(d.korean)").font(Theme.hand(17)).foregroundStyle(Theme.pencil).lineLimit(isOpen ? nil : 1) }
                            Spacer(minLength: 4)
                            if let t = d.answeredAt { let dt = Date(ms: t); Text("\(dt.monthDay) \(dt.hm)").font(Theme.hand(15)).foregroundStyle(Theme.pencil).fixedSize() }
                        }
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { openPast = isOpen ? nil : d.id } }   // 탭하면 첨삭 전체
                        if isOpen, let fb = d.feedback {
                            VStack(alignment: .leading, spacing: 0) {
                                if fb.usedExpression { Text("✓\u{FE0E} \"\(d.phrase)\" 사용").handLine(size: 20, color: Theme.grade(.A)) }
                                else { Text("✗\u{FE0E} \"\(d.phrase)\"를 쓰지 않았다").redpen(size: 20) }
                                ForEach(Array(fb.issues.enumerated()), id: \.offset) { _, i in
                                    (Text(i.mine).strikethrough(true, color: Theme.red) + Text(" →\u{FE0E} \(i.better)") + Text(i.why.isEmpty ? "" : " (\(i.why))").font(Theme.hand(17)).foregroundColor(Color(hex: 0xC0565A))).redpen(size: 20)
                                }
                                if !fb.reference.isEmpty { (Text("참고 ").font(Theme.hand(16)) + Text(fb.referenceLine)).pencil(size: 20) }
                                if !fb.note.isEmpty { Text(fb.note).pencil(size: 20) }
                            }
                            .padding(.leading, 32).padding(.bottom, 4)
                        } else if isOpen {
                            Text("채점 대기 중이거나 첨삭이 없다").pencil(size: 19).padding(.leading, 32)
                        }
                    }
                }
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
        .task { await loadPast() }
    }

    /// 같은 표현으로 푼 지난 시도: 서버(1년), 안 되면 캐시
    private func loadPast() async {
        if let all = try? await API.shared.drills(days: 365) {
            past = all.filter { $0.phrase == expr.phrase && $0.answer != nil }.sorted { ($0.answeredAt ?? 0) > ($1.answeredAt ?? 0) }
        } else {
            past = await MainActor.run { Cache.shared.drills(phrase: expr.phrase) }
        }
    }

    private func submit() async {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !busy else { return }
        busy = true; msg = nil
        do {
            if let p = prompt, let onAnswerDrill { let r = try await onAnswerDrill(p.id, a); result = r; past.insert(r, at: 0); if r.answeredAt != nil { onGraded?() } }
            else if let r = try await onFree(expr, a) { result = r; past.insert(r, at: 0); if r.answeredAt != nil { onGraded?() } }
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
    var sentenceId: String = ""
    var highlights: [Highlight]
    var onAsk: (Int, Int, String) async throws -> Void
    var onMemo: ((Int, Int, String, String, [Related]) async throws -> Void)? = nil
    var onNote: ((Highlight, String) async -> Void)? = nil
    var onDelete: ((Highlight) async -> Void)? = nil
    var onRelated: ((String?, String?, String?, String?) async -> [Related])? = nil
    @State private var chosen: [Related] = []     // 메모와 함께 엮을 것
    @State private var anchor: Int?
    @State private var range: ClosedRange<Int>?
    @State private var asking = false
    @State private var err: String?
    @State private var writing = false      // "메모 ✎" 입력란 열림
    @State private var noteText = ""
    @FocusState private var noteFocused: Bool
    @State private var picked: Highlight?   // 칠해진 단어를 탭해 고른 기존 형광펜
    @State private var pickedWord = 0
    @State private var editingPicked = false

    var body: some View {
        let pieces = wordPieces(text)
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 0) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { i, p in
                    // 같은 형광펜(또는 같은 선택)에 속한 이웃 단어와는 사이 공백까지 한 덩어리로, 모서리는 양끝만 둥글게
                    let savedRun = highlights.first { i >= $0.startWord && i <= $0.endWord }
                    let picking = (range.map { $0.contains(i) } ?? false) || (picked != nil && savedRun?.id == picked?.id)
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
            if let h = picked, range == nil {
                // 기존 형광펜을 골랐다: 내 메모 · 새로 칠하기 · 지우기 · 닫기
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) {
                        if editingPicked {
                            TextField("내 메모", text: $noteText).font(Theme.hand(21)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                                .focused($noteFocused).submitLabel(.done).autocorrectionDisabled()
                                .onSubmit { Task { await savePickedNote(h) } }
                            Tiny(title: "저장") { Task { await savePickedNote(h) } }
                            Tiny(title: "취소") { editingPicked = false }.keyboardShortcut(.escape, modifiers: [])
                        } else {
                            if onNote != nil { Tiny(title: (h.note ?? "").isEmpty ? "내 메모 ✎\u{FE0E}" : "메모 고치기 ✎\u{FE0E}") { noteText = h.note ?? ""; editingPicked = true; noteFocused = true } }
                            Tiny(title: "새로 칠하기") { let w = pickedWord; picked = nil; anchor = w; range = w...w }
                            if let onDelete { Tiny(title: "지우기 ×", color: Theme.red) { Task { await onDelete(h); picked = nil } } }
                            Tiny(title: "닫기") { picked = nil; editingPicked = false }
                        }
                    }
                    if let err { ErrorText(message: err) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.markerSelecting.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    Triangle().fill(Theme.markerSelecting.opacity(0.6)).frame(width: 12, height: 8).offset(x: 16, y: -7)
                }
                .padding(.vertical, 4)
            }
            if let r = range {
                let span = pieces[r].map(\.word).joined(separator: " ")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) {
                        if asking {
                            Text("묻는 중… 🖍").font(Theme.hand(20)).foregroundStyle(Theme.pencil)
                        } else if writing {
                            // 내가 느낀 걸 적는다. Enter 저장. 아래 "저장 / 취소"(취소는 선택까지 지워 처음 상태로, 맥 Esc도 같음)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(span).font(Theme.hand(18)).foregroundStyle(Color(hex: 0x2A2412)).padding(.horizontal, 6).background(Theme.marker, in: RoundedRectangle(cornerRadius: 4))
                                if let onRelated {
                                    RelatedChips(span: span, excludeSentence: sentenceId, exclude: nil, selectedKeys: Set(chosen.map(\.key)),
                                                 onToggle: { r in if let i = chosen.firstIndex(where: { $0.key == r.key }) { chosen.remove(at: i) } else { chosen.append(r) } },
                                                 load: onRelated)
                                }
                                HStack(spacing: 8) {
                                    TextField("내 메모", text: $noteText)
                                        .font(Theme.hand(21)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                                        .focused($noteFocused).submitLabel(.done)
                                        .onSubmit { Task { await saveMemo(r, span) } }
                                        .autocorrectionDisabled()
                                }
                                HStack(spacing: 16) {
                                    Tiny(title: "저장", color: Theme.red, size: 18) { Task { await saveMemo(r, span) } }
                                        .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                                        .opacity(noteText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                                    Tiny(title: "취소", size: 18) { cancelAll() }
                                        .keyboardShortcut(.escape, modifiers: [])
                                }
                            }
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
            range = min(a, i)...max(a, i)          // 두 번째 탭(선택 중): 그 사이를 한 덩어리로 (앞 단어여도 됨)
            return
        }
        // 선택 중이 아닐 때 이미 칠해진 단어를 탭하면 그 형광펜을 고른다 (다시 탭하면 해제)
        if range == nil, let h = highlights.first(where: { i >= $0.startWord && i <= $0.endWord }) {
            editingPicked = false
            if picked?.id == h.id { picked = nil } else { picked = h; pickedWord = i }
            return
        }
        picked = nil; editingPicked = false
        anchor = i; range = i...i                  // 첫 탭 또는 세 번째 탭: 새 시작
    }
    private func savePickedNote(_ h: Highlight) async {
        guard let onNote else { return }
        await onNote(h, noteText.trimmingCharacters(in: .whitespacesAndNewlines)); editingPicked = false; picked = nil
    }

    private func ask(_ r: ClosedRange<Int>, _ span: String) async {
        asking = true; err = nil
        do { try await onAsk(r.lowerBound, r.upperBound, span); anchor = nil; range = nil }
        catch { err = error.localizedDescription }
        asking = false
    }
    /// 취소: 메모 상자와 노란 선택, 고른 엮기 후보를 모두 지워 처음 상태로
    private func cancelAll() { writing = false; noteText = ""; anchor = nil; range = nil; err = nil; chosen = [] }

    private func saveMemo(_ r: ClosedRange<Int>, _ span: String) async {
        let n = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let onMemo else { return }
        err = nil
        do { try await onMemo(r.lowerBound, r.upperBound, span, n, chosen); writing = false; noteText = ""; anchor = nil; range = nil; chosen = [] }
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
    var tryTitle: String = "써 보기 ✎\u{FE0E}"
    var tryCount: Int = 0
    var onRelated: ((String?, String?, String?, String?) async -> [Related])? = nil
    var onAddLink: ((Highlight, Related) async -> Void)? = nil
    var onRemoveLink: ((Highlight, HighlightLink) async -> Void)? = nil
    var onOpenSentence: ((String, String) -> Void)? = nil
    @State private var linking = false
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
                    if let onTry { TryButton(title: tryTitle, count: tryCount, action: onTry) }
                    if onRelated != nil, onAddLink != nil { Tiny(title: linking ? "접기" : "엮기 ↗\u{FE0E}", size: 17) { linking.toggle() } }
                }
            }
            if linking, let onRelated, let onAddLink {
                RelatedChips(span: h.span, excludeSentence: h.sentenceId, exclude: h.id, selectedKeys: Set(h.links.map(\.key)),
                             onToggle: { r in
                                 Task {
                                     if let l = h.links.first(where: { $0.key == r.key }) { await onRemoveLink?(h, l) }
                                     else { await onAddLink(h, r) }
                                 }
                             }, load: onRelated)
                    .padding(.top, 2)
            }
            // 엮은 것 / 거꾸로 링크
            ForEach(h.links) { l in LinkLine(l: l, onOpen: onOpenSentence, onRemove: onRemoveLink == nil ? nil : { Task { await onRemoveLink?(h, l) } }) }
            ForEach(h.backlinks) { b in BacklinkLine(b: b, onOpen: onOpenSentence) }
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
