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
    var onRestore: (() -> Void)? = nil   // void("잘못 누름")인 시도의 되살리기
    #if DEBUG
    @State private var open = ProcessInfo.processInfo.environment["LBN_AUTOHISTORY"] == "1"   // 화면 확인용: 펼친 채로 시작
    #else
    @State private var open = false
    #endif

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
                    if attempt.isVoid {
                        // "잘못 눌렀다"로 무효 처리된 시도: 흐리게 + 빨간 테두리 표시 + 되살리기
                        Text("잘못 누름").font(Theme.hand(15)).foregroundStyle(Theme.red)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.red, lineWidth: 1))
                        if let onRestore { Tiny(title: "되살리기", size: 17, action: onRestore) }
                    }
                    Spacer(minLength: 6)
                    Text(when).font(Theme.hand(15)).foregroundStyle(Theme.pencil).opacity(0.8).fixedSize()
                }
                .opacity(attempt.isVoid ? 0.55 : 1)
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
                    // "참고" 번역은 문장에 하나뿐이라 위의 참고 줄로 충분 — 이전 시도마다 다시 보이지 않는다 (goni 2026-11-23 "히스토리에서 참고는 필요없잖아")
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
    /// "잘못 눌렀다 ✗": 지금 번역(가장 최근 시도)을 무효로 표시하고 그 문장을 바로 다시 쓴다 (goni 2026-11-16). 다시 쓰기와 달리 집계에서도 빠진다
    var onVoid: (() -> Void)?
    /// 무효 시도 되살리기
    var onRestore: ((Attempt) -> Void)?
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
    /// 붙여 둔 표현(포스트잇·빨간 펜 지적)에서 엮기 (goni 2026-11-18). 후보 찾기는 onRelated 공용
    var onAddPhraseLink: ((Phrase, Related) async -> Void)?
    var onRemovePhraseLink: ((Phrase, HighlightLink) async -> Void)?
    var onOpenSentence: ((String, String) -> Void)?
    /// 포스트잇에서 바로 "써 보기": 자유 작문 채점(nil이면 큐에 들어감), 문제 내줘(표현장에 없으면 nil), 문제 답 채점
    var onFree: ((Expression, String, String) async throws -> Drill?)?   // (표현, 내 문장, drill_id)
    var onDrillFor: ((Expression) async throws -> Drill?)?
    var onAnswerDrill: ((Drill, String) async throws -> Drill?)?   // nil = 큐에 들어감(연결되면 채점)
    var drillCounts: [String: Int] = [:]
    var onDrillGraded: ((String) -> Void)?      // 상자에서 채점이 끝났다 → 그 표현 횟수 +1
    var revoked: [RevokedPhrase] = []           // 이번 채점으로 습득 완료가 취소된 표현 → 첨삭 위 한 줄 (2026-11-18)
    /// 중요도 별(2026-11-19): 형광펜 메모 줄·포스트잇 아래·빨간 펜 지적 줄. 값은 그 문장의 같은 글자 표현(없으면 같은 글자 아무 표현)의 weight, 없는 표현이면 누르는 순간 붙이고 별
    var weightOf: ((Expression) -> Int)? = nil
    var onWeight: ((Expression, Int) async -> Void)? = nil
    /// 표현 내 메모(2026-11-19): 포스트잇 아래·빨간 펜 지적 줄 "내 메모 ✎"(있으면 "메모 고치기") → 한 줄 입력. 없는 표현이면 붙이면서 쓴다
    var noteOf: ((Expression) -> String?)? = nil
    var onPhraseNote: ((Expression, String) async -> Void)? = nil
    /// "표현장 ↗"(2026-11-19): 그 표현의 표현장 id로 표현장을 시트로 열어 스크롤·강조. 🔊는 TapePlayer.speakOnce
    var onOpenPhrases: ((String) -> Void)? = nil
    /// 문장 구조 분석(2026-11-20): 원문 줄 끝 "구조 분석" → 받는 중 "분석 중…" → 원문 줄 바로 아래 점선 상자, 다시 누르면 "구조 접기". force면 다시 분석
    var onStructure: ((Bool) async throws -> Structure)? = nil
    /// 구조 상자 안 질문·답(2026-11-20): 묻기(온라인에서만) · 문답 지우기
    var onAskSentence: ((String) async throws -> SentenceQA)? = nil
    var onDeleteQA: ((String) async throws -> Void)? = nil
    @State private var structure: Structure?
    @State private var structOpen = false
    @State private var structBusy = false
    @State private var structErr: String?
    @State private var notingPhrase: String?      // 메모 입력이 열린 표현(글자)
    @State private var tryExpr: Expression?
    @State private var linkingPhrase: String?     // "엮기"가 열린 표현(표현장 id)
    @State private var moreOpen = false           // 동작 줄 ⋯ (앞/뒤와 합치기)

    var body: some View {
        let a = s.attempt!
        let fb = a.feedback
        Entry(stamp: AnyView(Stamp(kind: .grade(fb.grade))), highlight: highlight) {
            // 원문의 것은 원문 줄 끝에 (goni 2026-11-20 A안): 복사 ⎘ · 듣기 🔊 · "구조 분석". 건너뛴 문장도 ⎘ 🔊는 원문 끝
            let tools = SrcTools(text: s.text, structOpen: structOpen && structure != nil, structBusy: structBusy,
                                 onStructure: (onStructure == nil || fb.grade == .skip) ? nil : { loadStructure() })
            if expanded || fb.grade == .skip, let onAsk { MarkerWords(text: s.text, sentenceId: s.id, highlights: highlights, onAsk: onAsk, onMemo: onMemo, onNote: onNote, onDelete: onDeleteHighlight, onRelated: onRelated, tools: tools) }
            else if expanded || fb.grade == .skip { HStack(alignment: .bottom, spacing: 0) { Text(markHighlights(s.text, highlights)).enLine(); tools } }
            else { Text(markHighlights(s.text, highlights)).enLine() }
            if expanded {
                ForEach(highlights) { h in
                    let he = Expression(phrase: h.span, meaning: h.hasAnswer ? h.answer.meaning : (h.note ?? ""))
                    MarkerMemo(h: h, onDelete: onDeleteHighlight, onNote: onNote,
                               onTry: onFree == nil ? nil : { tryExpr = tryExpr == he ? nil : he },
                               tryTitle: tryExpr?.phrase == h.span ? "접기" : tryTitle(h.span), tryCount: tryExpr?.phrase == h.span ? 0 : (drillCounts[h.span] ?? 0),
                               onRelated: onRelated, onAddLink: onAddLink, onRemoveLink: onRemoveLink, onOpenSentence: onOpenSentence,
                               stars: weightOf?(he) ?? 0, onStars: onWeight == nil ? nil : { w in Task { await onWeight?(he, w) } },
                               onOpen: onOpenPhrases == nil ? nil : phraseId(he).flatMap { pid in SyncManager.isTemp(pid) ? nil : { onOpenPhrases?(pid) } },
                               speakText: he.phrase)
                }
            }
            // 참고 번역 줄은 원문(형광펜 메모) 다음, 구조 분석 상자 위 (goni 2026-11-23 "참고 해석 위치는 구조분석 펼치기보다 위에"; 전에는 지적 다음 → 상자 아래 → 상자 위). 토글·기본 펼침은 그대로
            if expanded, fb.grade != .skip {
                if showRef {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        (Text("참고 ").font(Theme.hand(17)) + Text(fb.reference)).pencil()
                        Tiny(title: "접기", action: onToggleRef)
                    }
                } else {
                    Tiny(title: "참고 번역 보기", action: onToggleRef).frame(height: Theme.lh)
                }
            }
            // 구조 분석 상자는 버튼(원문 줄 끝) 바로 아래, 내 번역 줄 앞 (goni 2026-11-22 "분석 내용이 바로 버튼 하단에 나오면")
            if expanded, let e = structErr {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e).redpen(size: 20)
                    Tiny(title: "다시 시도", size: 18) { loadStructure(force: true) }
                }
            }
            if expanded, structOpen, let st = structure {
                StructureView(st: st, busy: structBusy, onAgain: { loadStructure(force: true) }, onClose: { structOpen = false },
                              onAsk: onAskSentence == nil ? nil : { q in let r = try await onAskSentence!(q); structure?.qa = (structure?.qa ?? []) + [r] },
                              onDeleteQA: onDeleteQA == nil ? nil : { qid in try await onDeleteQA!(qid); structure?.qa = (structure?.qa ?? []).filter { $0.id != qid } },
                              onMarks: { qid, ms in
                                  // 밑줄은 누르는 즉시 그리고 PUT은 뒤에서 (goni 2026-11-23 "빨간 밑줄 업데이트가 느리다"). 오프라인이면 SyncManager가 큐에 넣는다.
                                  // 서버가 거절하면 이전 밑줄로 되돌리고 알린다(throw → askErr)
                                  guard let i = structure?.qa?.firstIndex(where: { $0.id == qid }) else { return }
                                  let before = structure?.qa?[i].marks
                                  structure?.qa?[i].marks = ms
                                  AppLog.shared.info("structure", "qa marks drawn", ["sentence": s.id, "qid": qid, "count": "\(ms.count)"])
                                  do {
                                      let r = try await SyncManager.shared.setQAMarks(sentenceId: s.id, qid: qid, marks: ms)
                                      if let j = structure?.qa?.firstIndex(where: { $0.id == qid }) { structure?.qa?[j].marks = r }
                                  } catch {
                                      if let j = structure?.qa?.firstIndex(where: { $0.id == qid }) { structure?.qa?[j].marks = before }
                                      AppLog.shared.warn("structure", "qa marks rejected; reverted", ["sentence": s.id, "qid": qid, "error": error.localizedDescription])
                                      throw error
                                  }
                              })
                    .padding(.vertical, 4)
            }
            if fb.grade == .skip {
                FlowLayout(spacing: 10, rowSpacing: 0) {   // 버튼이 늘어 한 줄에 안 들어가면 다음 줄로
                    Text("건너뜀").handLine(size: 21, color: Theme.pencil)
                    if let onRedo { Tiny(title: "써 보기 ↻\u{FE0E}", action: onRedo).frame(height: Theme.lh) }
                    if let onVoid { Tiny(title: "잘못 눌렀다 ✗\u{FE0E}", color: Theme.red, action: onVoid).frame(height: Theme.lh) }
                }
                historyBlock
            } else {
                if a.translation.isEmpty { Text("건너뜀").handLine(size: 21, color: Theme.pencil) }
                else { Text(markWrong(a.translation, fb.issues)).koLine() }
                if expanded { marks(fb) }
            }
        }
        #if DEBUG
        // 화면 확인용: LBN_AUTOTRY=<문장 id> 이면 그 문장의 첫 붙은 표현으로 써 보기 상자를 연다 (상자가 열리면 문장을 넣고 제출까지 한다)
        .onChange(of: "\(savedPhrases.count)|\(expanded)", initial: true) { _, _ in
            if ProcessInfo.processInfo.environment["LBN_AUTOTRY"] == s.id, expanded, tryExpr == nil, let p = savedPhrases.first { tryExpr = Expression(phrase: p.phrase, meaning: p.meaning) }
            // LBN_AUTOLINK=<문장 id>: 그 문장의 첫 붙은 표현의 "엮기"를 연다
            if ProcessInfo.processInfo.environment["LBN_AUTOLINK"] == s.id, expanded, linkingPhrase == nil, let p = savedPhrases.first { linkingPhrase = p.id }
        }
        #endif
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

    /// 표현장 ↗ 대상: 그 문장의 같은 글자 표현(없으면 공책의 같은 글자 아무 표현)
    private func phraseId(_ e: Expression) -> String? { savedPhrases.first { $0.phrase == e.phrase }?.id }
    /// 붙여 둔 표현의 "↗ 엮은 것"(풀기 ×) · "← 다시 본 곳" 줄 (형광펜과 같은 줄)
    @ViewBuilder
    private func phraseLinkLines(_ sp: Phrase) -> some View {
        ForEach(sp.links ?? []) { l in LinkLine(l: l, onOpen: onOpenSentence, onRemove: onRemovePhraseLink == nil ? nil : { Task { await onRemovePhraseLink?(sp, l) } }) }
        ForEach(sp.backlinks ?? []) { b in BacklinkLine(b: b, onOpen: onOpenSentence) }
    }
    /// 붙여 둔 표현에서 엮을 후보 칩 (어근 같은 것 → 다른 구절 찾기…). 칩 토글로 잇기/풀기
    @ViewBuilder
    private func phraseLinkPicker(_ sp: Phrase) -> some View {
        if let onRelated, let onAddPhraseLink {
            RelatedChips(span: sp.phrase, excludeSentence: s.id, exclude: sp.id, selectedKeys: Set((sp.links ?? []).map(\.key)),
                         onToggle: { r in
                             Task {
                                 if let l = sp.links?.first(where: { $0.key == r.key }) { await onRemovePhraseLink?(sp, l) }
                                 else { await onAddPhraseLink(sp, r) }
                             }
                         }, load: onRelated)
                .padding(.vertical, 2)
        }
    }

    /// 이전 시도: 동작 줄 밑에 답글처럼 — 왼쪽 연필색 세로줄 2px, 바깥 여백 26pt + 안쪽 14pt, 살짝 흐리게 (goni 2026-11-23 "히스토리는 그 버튼들 밑에 답글처럼 들여쓰기")
    @ViewBuilder
    private var historyBlock: some View {
        if !s.history.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(s.history.enumerated()), id: \.offset) { _, h in HistoryLine(attempt: h, onRestore: h.isVoid ? onRestore.map { f in { f(h) } } : nil) }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.pencil).frame(width: 2).padding(.vertical, 4) }
            .padding(.leading, 26)
            .opacity(0.85)
        }
    }

    @ViewBuilder
    private func marks(_ fb: Feedback) -> some View {
        do {
            // 동작 줄은 내 번역 바로 아래 (goni 2026-11-23 "다시쓰기랑 같이 있는 버튼은 내가 직접 쓴 해석 밑으로"; 전에는 지적·이전 시도 다음, 포스트잇 위): 다시 쓰기 ↻ · 잘못 눌렀다 ✗ · 문장을 표현장에 ＋ · ⋯(앞/뒤와 합치기). 복사·듣기·구조 분석은 원문 줄 끝
            FlowLayout(spacing: 16, rowSpacing: 0) {   // 버튼이 늘어 한 줄에 안 들어가면 다음 줄로
                if let onRedo { Tiny(title: "다시 쓰기 ↻\u{FE0E}", action: onRedo).frame(height: Theme.lh).help("첨삭을 보고 고쳐 쓴다. 이 번역은 이전 시도로 남고 집계에도 남는다") }
                if let onVoid { Tiny(title: "잘못 눌렀다 ✗\u{FE0E}", color: Theme.red, action: onVoid).frame(height: Theme.lh).help("실수로 낸 번역을 무효로 표시한다. 점수·총평·기록에서 빠지고 이전 시도에 '잘못 누름'으로 남는다") }
                do {
                    // 문장 전체를 표현장에 (goni 2026-11-20 "짧은 문장 중 써먹고 싶은 것이 있어서"). 뜻은 참고 번역(없으면 내 번역).
                    // 붙은 뒤 다시 누르면 습득 완료 토글(포스트잇과 같다), 떼는 건 표현장 ×. 응용·시험·테이프에 자연히 들어간다
                    let sp = savedPhrases.first { $0.phrase == s.text && $0.sentenceId == s.id } ?? savedPhrases.first { $0.phrase == s.text }
                    Tiny(title: sp?.isMastered == true ? "문장 습득 완료 ✓\u{FE0E}" : sp != nil ? "문장 붙여 둠 ✓\u{FE0E}" : "문장을 표현장에 ＋", color: sp != nil ? Theme.grade(.A) : Theme.pencil) {
                        onTogglePhrase(Expression(phrase: s.text, meaning: fb.reference.isEmpty ? (s.attempt?.translation ?? "") : fb.reference))
                    }
                    .frame(height: Theme.lh)
                    .help(sp?.isMastered == true ? "습득 완료. 누르면 되돌린다" : sp != nil ? "문장이 표현장에 붙어 있다. 누르면 습득 완료. 떼려면 표현장에서 ×" : "이 문장 통째로 표현장에 붙인다 (뜻 = 참고 번역). 응용·시험·테이프에도 들어간다")
                }
                if onMergePrev != nil || onMergeNext != nil, !moreOpen { Tiny(title: "⋯") { moreOpen = true }.frame(height: Theme.lh).help("드물게 쓰는 것: 잘못 끊긴 문장 합치기") }
                if moreOpen, let onMergePrev { Tiny(title: "↑\u{FE0E} 앞과 합치기", action: onMergePrev).frame(height: Theme.lh).help("두 문장의 기록은 남고, 합쳐진 문장을 다시 쓴다") }
                if moreOpen, let onMergeNext { Tiny(title: "↓\u{FE0E} 뒤와 합치기", action: onMergeNext).frame(height: Theme.lh).help("두 문장의 기록은 남고, 합쳐진 문장을 다시 쓴다") }
            }
            .task {
                #if DEBUG
                // 화면 확인용: LBN_AUTOSTRUCT=<문장 id> 이면 펼치자마자 구조 분석을 받는다 (LBN_AUTOOPEN과 함께)
                if ProcessInfo.processInfo.environment["LBN_AUTOSTRUCT"] == s.id, structure == nil { loadStructure() }
                #endif
            }
        }
        historyBlock
        ForEach(revoked) { rv in
            Text("⟲\u{FE0E} 습득 완료 취소 · \(rv.phrase) — 이 문장에서 틀려서 표현장에 다시 보인다").font(Theme.hand(18)).foregroundStyle(Theme.red)
        }
        ForEach(Array(fb.issues.enumerated()), id: \.offset) { _, i in
            // 빨간 펜으로 지적된 표현도 표현장에 붙여 응용에서 연습할 수 있다 (goni 2026-11-17 "빨간색으로 알려준 표현도 공부하고 싶은데"). 포스트잇과 같은 경로(POST/DELETE phrases)
            let src = i.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let sp = src.isEmpty ? nil : savedPhrases.first { $0.phrase == src }
            let saved = sp != nil
            let e = Expression(phrase: src, meaning: i.meaning)
            // 같은 표현이 포스트잇에도 있으면 엮기 줄은 포스트잇 쪽에서만 보여 준다
            let onSticky = fb.expressions.contains { $0.phrase == src }
            (Text(i.source).underline(true, color: Theme.red) + Text(" →\u{FE0E} \(i.meaning)") + Text(i.why.isEmpty ? "" : " (\(i.why))").font(Theme.hand(19)).foregroundColor(Color(hex: 0xC0565A)))
                .redpen()
            if !src.isEmpty {
                // 버튼은 지적 글 아래에 (글 옆에 두면 글이 좁아져 줄이 늘어난다). 버튼이 늘어 한 줄에 안 들어가면 다음 줄로
                FlowLayout(spacing: 14) {
                    // 붙은 뒤 다시 누르면 습득 완료 토글(떼는 게 아니다, goni 2026-11-18). 찍히면 "습득 완료 ✓"
                    Tiny(title: sp?.isMastered == true ? "습득 완료 ✓\u{FE0E}" : saved ? "붙여 둠 ✓\u{FE0E}" : "표현장에 ＋", color: saved ? Theme.grade(.A) : Theme.pencil, size: 17) { onTogglePhrase(e) }
                        .help(sp?.isMastered == true ? "습득 완료. 누르면 도장을 떼고 다시 본다" : saved ? "붙여 둠. 누르면 습득 완료(표현장에 남고 응용·시험지에서 빠짐). 떼려면 표현장에서 ×" : "이 표현을 표현장에 붙인다 → 응용에서 연습할 수 있다")
                    if saved, onFree != nil {
                        TryButton(title: tryExpr == e ? "접기" : "써 보기 ✎\u{FE0E}", count: tryExpr == e ? 0 : (drillCounts[src] ?? 0)) { tryExpr = tryExpr == e ? nil : e }
                    }
                    if let sp, !onSticky, onAddPhraseLink != nil, onRelated != nil {
                        Tiny(title: linkingPhrase == sp.id ? "접기" : "엮기 ⟷\u{FE0E}", size: 17) { linkingPhrase = linkingPhrase == sp.id ? nil : sp.id }
                    }
                    if onPhraseNote != nil, saved, !onSticky { Tiny(title: (noteOf?(e) ?? "").isEmpty ? "+ 메모" : "메모 고치기", size: 17) { notingPhrase = notingPhrase == src ? nil : src } }
                    if !onSticky, let onOpenPhrases, let pid = phraseId(e), !SyncManager.isTemp(pid) { Tiny(title: "표현장 ⧉\u{FE0E}", size: 17) { onOpenPhrases(pid) } }
                    if !onSticky { SpeakIcon(text: e.phrase) }
                    if let onWeight { StarRow(stars: weightOf?(e) ?? 0, size: 13) { w in Task { await onWeight(e, w) } } }   // 중요도 별
                }
                .frame(minHeight: Theme.lh)
                if !onSticky, let n = noteOf?(e), !n.isEmpty, notingPhrase != src { Text("✎\u{FE0E} \(n)").font(Theme.hand(19)).foregroundStyle(Theme.blueInk) }
                if notingPhrase == src, let onPhraseNote { NoteEditor(initial: noteOf?(e) ?? "", onSave: { t in Task { await onPhraseNote(e, t) }; notingPhrase = nil }, onCancel: { notingPhrase = nil }) }
                if let sp, !onSticky {
                    phraseLinkLines(sp)
                    if linkingPhrase == sp.id { phraseLinkPicker(sp) }
                }
            }
        }
        if !fb.expressions.isEmpty {
            StickyRow(items: fb.expressions.enumerated().map { (i, e) in (e, savedPhrases.contains { $0.phrase == e.phrase }, i) }, onTap: onTogglePhrase,
                      onTry: onFree == nil ? nil : { e in tryExpr = tryExpr == e ? nil : e },
                      tryLabel: { e in tryExpr == e ? "접기" : tryTitle(e.phrase) }, counts: drillCounts, openPhrase: tryExpr?.phrase,
                      backlinks: { e in savedPhrases.first { $0.phrase == e.phrase }?.backlinks ?? [] }, onOpenSentence: onOpenSentence,
                      mastered: { e in savedPhrases.first { $0.phrase == e.phrase }?.isMastered ?? false },
                      links: { e in savedPhrases.first { $0.phrase == e.phrase }?.links ?? [] },
                      onLink: onAddPhraseLink == nil || onRelated == nil ? nil : { e in if let sp = savedPhrases.first(where: { $0.phrase == e.phrase }) { linkingPhrase = linkingPhrase == sp.id ? nil : sp.id } },
                      linkLabel: { e in savedPhrases.first { $0.phrase == e.phrase }.map { linkingPhrase == $0.id ? "접기" : "엮기 ⟷\u{FE0E}" } ?? "엮기 ⟷\u{FE0E}" },
                      onRemoveLink: onRemovePhraseLink == nil ? nil : { e, l in if let sp = savedPhrases.first(where: { $0.phrase == e.phrase }) { Task { await onRemovePhraseLink?(sp, l) } } },
                      stars: weightOf, onStars: onWeight == nil ? nil : { e, w in Task { await onWeight?(e, w) } },
                      note: noteOf, noting: notingPhrase,
                      onNote: onPhraseNote == nil ? nil : { e in notingPhrase = notingPhrase == e.phrase ? nil : e.phrase },
                      onSaveNote: onPhraseNote == nil ? nil : { e, t in Task { await onPhraseNote?(e, t) }; notingPhrase = nil },
                      onOpen: onOpenPhrases == nil ? nil : { e in if let pid = phraseId(e), !SyncManager.isTemp(pid) { onOpenPhrases?(pid) } },
                      onSpeak: { _ in })   // 🔊는 SpeakIcon이 스스로 토글(있음 표시만)
            // 포스트잇 쪽 "엮기"가 열려 있으면 후보 칩은 포스트잇 줄 아래에
            if let id = linkingPhrase, let sp = savedPhrases.first(where: { $0.id == id }), fb.expressions.contains(where: { $0.phrase == sp.phrase }) { phraseLinkPicker(sp) }
        }
        if let e = tryExpr, let onFree {
            TryBox(expr: e, onFree: onFree, onDrillFor: onDrillFor, onAnswerDrill: onAnswerDrill, onClose: { tryExpr = nil }, onGraded: { onDrillGraded?(e.phrase) })
        }
    }

    /// 구조 분석: 이미 받았으면 접기/펴기, 아니면 받는다(서버 저장본이면 즉시). force면 새로 분석(하루 상한에 셈)
    private func loadStructure(force: Bool = false) {
        guard let onStructure, !structBusy else { return }
        if !force, structure != nil { structOpen.toggle(); return }
        structBusy = true; structErr = nil; structOpen = true
        Task {
            do { structure = try await onStructure(force) }
            catch { structErr = error.localizedDescription; if structure == nil { structOpen = false } }
            structBusy = false
        }
    }
}

struct ChunkFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
}

/// 구조 분석 덩어리 위 꾸밈 관계 화살표 (웹 Entry.tsx의 chunk-arrows와 같은 기하, goni 2026-11-23). 상자 자리(frames)는 레이아웃 뒤에 잰 것.
/// 같은 줄이면 상자 위로 호(라벨은 호 꼭대기), 다른 줄이면 줄 사이 틈으로 지나 아랫줄→윗줄은 받는 상자의 아래쪽에, 윗줄→아랫줄은 받는 상자의 위쪽에 화살촉(상자를 가로지르지 않는다, 라벨은 틈 가운데).
/// 갈색 1.6pt, 라벨 손글씨 13pt에 종이색 테두리
struct ChunkArrows: View {
    var links: [Structure.Link]
    var frames: [Int: CGRect]
    private let brown = Color(hex: 0x8A6A2A)
    var body: some View {
        Canvas { ctx, _ in
            for l in links {
                guard let ra = frames[l.from], let rb = frames[l.to] else { continue }
                let x1 = ra.midX, x2 = rb.midX
                let top1 = ra.minY - 2, top2 = rb.minY - 2
                let bot1 = ra.maxY + 2, bot2 = rb.maxY + 2
                var p = Path()
                var end: CGPoint, before: CGPoint, label: CGPoint
                if abs(top1 - top2) < 8 {
                    // 같은 줄: 상자 위로 호. 꼭대기는 top1 - h
                    let h = min(24, 10 + abs(x2 - x1) / 10)
                    let c = CGPoint(x: (x1 + x2) / 2, y: top1 - 2 * h)
                    p.move(to: CGPoint(x: x1, y: top1)); p.addQuadCurve(to: CGPoint(x: x2, y: top2), control: c)
                    end = CGPoint(x: x2, y: top2); before = c; label = CGPoint(x: (x1 + x2) / 2, y: top1 - h - 7)
                } else if top1 > top2 {
                    // 아랫줄 → 윗줄: 줄 사이 틈으로 지나 받는 상자의 아래쪽에
                    let g = (top1 - bot2) / 2
                    let c1 = CGPoint(x: x1, y: top1 - g), c2 = CGPoint(x: x2, y: bot2 + g)
                    p.move(to: CGPoint(x: x1, y: top1)); p.addCurve(to: CGPoint(x: x2, y: bot2), control1: c1, control2: c2)
                    end = CGPoint(x: x2, y: bot2); before = c2; label = CGPoint(x: (x1 + x2) / 2, y: (top1 + bot2) / 2)
                } else {
                    // 윗줄 → 아랫줄: 보내는 상자의 아래에서 나와 받는 상자의 위에
                    let g = (top2 - bot1) / 2
                    let c1 = CGPoint(x: x1, y: bot1 + g), c2 = CGPoint(x: x2, y: top2 - g)
                    p.move(to: CGPoint(x: x1, y: bot1)); p.addCurve(to: CGPoint(x: x2, y: top2), control1: c1, control2: c2)
                    end = CGPoint(x: x2, y: top2); before = c2; label = CGPoint(x: (x1 + x2) / 2, y: (bot1 + top2) / 2)
                }
                ctx.stroke(p, with: .color(brown), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                // 화살촉: 끝점에서 들어오는 방향으로 7pt
                let ang = atan2(end.y - before.y, end.x - before.x)
                var head = Path()
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - 8 * cos(ang - 0.42), y: end.y - 8 * sin(ang - 0.42)))
                head.addLine(to: CGPoint(x: end.x - 8 * cos(ang + 0.42), y: end.y - 8 * sin(ang + 0.42)))
                head.closeSubpath()
                ctx.fill(head, with: .color(brown))
                // 라벨: 종이색 바탕(흰 테두리 대신) 위 갈색 손글씨
                let t = l.label.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty {
                    let r = ctx.resolve(Text(t).font(Theme.hand(13)).foregroundColor(brown))
                    let sz = r.measure(in: CGSize(width: 200, height: 40))
                    let bg = CGRect(x: label.x - sz.width / 2 - 3, y: label.y - sz.height / 2 - 1, width: sz.width + 6, height: sz.height + 2)
                    ctx.fill(Path(roundedRect: bg, cornerRadius: 3), with: .color(Color(red: 1, green: 0.992, blue: 0.965).opacity(0.95)))
                    ctx.draw(r, at: label, anchor: .center)
                }
            }
        }
    }
}

/// 문장 구조 분석 패널 (웹 StructureView와 같은 구성): "뼈대: …" → 덩어리 띠(text 위·role 아래, 역할별 밑줄 색) →
/// 덩어리별 "role text — note" → "읽기: …" → "함정: … · …" → "내 번역은: …"(빨간 펜) → "다시 분석 ↻"
struct StructureView: View {
    var st: Structure
    var busy = false
    var onAgain: (() -> Void)?
    var onClose: (() -> Void)? = nil                       // 오른쪽 위 × 접기 (동작 줄 "구조 접기"와 같다)
    var onAsk: ((String) async throws -> Void)? = nil      // 상자 맨 아래 입력란 → 서버 → 문답이 목록에 붙는다
    var onDeleteQA: ((String) async throws -> Void)? = nil
    var onMarks: ((String, [String]) async throws -> Void)? = nil   // 답에 밑줄 (qid, 목록 통째)
    @ObservedObject private var net = Connectivity.shared
    @State private var question = ""
    @State private var asking = false
    @State private var askErr: String?
    @State private var chunkFrames: [Int: CGRect] = [:]   // 덩어리 상자 자리(화살표용)
    @FocusState private var qFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("뼈대", st.skeleton, color: Theme.pencil).padding(.trailing, onClose == nil ? 0 : 22)
            // 덩어리 띠. 꾸밈 관계(links)가 있으면 상자 위 30pt·줄 사이 32pt를 띄우고 상자들의 실제 자리를 재서 화살표를 덧그린다 (goni 2026-11-23 "꾸밈 관계를 화살표로도")
            let links = (st.links ?? []).filter { $0.from != $0.to && st.chunks.indices.contains($0.from) && st.chunks.indices.contains($0.to) }
            FlowLayout(spacing: 8, rowSpacing: links.isEmpty ? nil : 32) {
                ForEach(Array(st.chunks.enumerated()), id: \.offset) { i, ch in
                    VStack(alignment: .center, spacing: 1) {
                        Text(ch.text).font(Theme.print(16)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                        Text(ch.role).font(Theme.hand(15)).foregroundStyle(Structure.color(ch.role))
                    }
                    .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.025)))
                    .overlay(alignment: .bottom) { Rectangle().fill(Structure.color(ch.role)).frame(height: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
                    .help(ch.note)
                    .background(GeometryReader { g in Color.clear.preference(key: ChunkFrames.self, value: [i: g.frame(in: .named("chunks"))]) })
                }
            }
            .padding(.top, links.isEmpty ? 0 : 30)
            .coordinateSpace(name: "chunks")
            .onPreferenceChange(ChunkFrames.self) { chunkFrames = $0 }
            .overlay { if !links.isEmpty { ChunkArrows(links: links, frames: chunkFrames).allowsHitTesting(false) } }
            let noted = st.chunks.filter { !$0.note.isEmpty }
            if !noted.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(noted.enumerated()), id: \.offset) { _, ch in
                        (Text(ch.role).fontWeight(.bold).foregroundColor(Structure.color(ch.role)) + Text(" \(ch.text) — \(ch.note)").foregroundColor(Theme.ink))
                            .font(Theme.hand(18))
                    }
                }
            }
            labeled("읽기", st.reading, color: Theme.pencil)
            if !st.pitfalls.isEmpty { labeled("함정", st.pitfalls.joined(separator: " · "), color: Theme.pencil) }
            if !st.mine.isEmpty { labeled("내 번역은", st.mine, color: Theme.red, size: 20) }
            // 문답 (goni 2026-11-20 "그 컨텍스트에 대해 추가로 질문하고 답변도"): 점선 위에 "Q. 질문"(남색) + 답(연필색, 줄바꿈 유지), 옆 × 지우기
            let qa = st.qa ?? []
            if !qa.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(qa) { x in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Q. \(x.question)").font(Theme.hand(19)).foregroundStyle(Theme.blueInk).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if let onDeleteQA { Tiny(title: "×", size: 18) { Task { do { try await onDeleteQA(x.id) } catch { askErr = error.localizedDescription } } }.help("이 문답 지우기") }
                            }
                            QAAnswerView(answer: x.answer, marks: x.marks ?? [], onSet: onMarks == nil ? nil : { ms in Task { do { try await onMarks?(x.id, ms) } catch { askErr = error.localizedDescription } } })
                        }
                    }
                }
                .padding(.top, 6)
                .overlay(alignment: .top) { Rectangle().fill(Theme.pencil.opacity(0.35)).frame(height: 1) }
            }
            if onAsk != nil {
                if net.isOnline {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TextField("이 문장에 대해 물어볼 것 (Enter)", text: $question, axis: .vertical).font(Theme.hand(20)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                            .focused($qFocused).submitLabel(.send).autocorrectionDisabled().disabled(asking)
                            .onSubmit { ask() }
                        if asking { Text("답 쓰는 중… ✎\u{FE0E}").font(Theme.hand(18)).foregroundStyle(Theme.placeholder) }
                        else if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Tiny(title: "묻기", size: 18) { ask() } }
                    }
                } else {
                    Text("연결되면 물어볼 수 있다").font(Theme.hand(18)).foregroundStyle(Theme.placeholder)
                }
                if let e = askErr { Text(e).font(Theme.hand(18)).foregroundStyle(Theme.red) }
            }
            if let onAgain {
                HStack(spacing: 10) {
                    Tiny(title: busy ? "분석 중… ✎\u{FE0E}" : "다시 분석 ↻\u{FE0E}", color: busy ? Theme.placeholder : Theme.pencil, size: 18, action: onAgain).disabled(busy)
                    if let at = st.createdAt { Text(Date(timeIntervalSince1970: Double(at) / 1000).formatted(.dateTime.month(.defaultDigits).day().hour().minute())).font(Theme.hand(15)).foregroundStyle(Theme.placeholder) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.pencil))
        .overlay(alignment: .topTrailing) {
            if let onClose { Tiny(title: "×", size: 22, action: onClose).padding(.horizontal, 10).padding(.top, 4).help("접기").accessibilityLabel("구조 접기") }
        }
        .task {
            #if DEBUG
            // 화면 확인용: LBN_AUTOASK=<질문> 이면 상자가 뜨자마자 그 질문을 보낸다
            if let q = ProcessInfo.processInfo.environment["LBN_AUTOASK"], onAsk != nil, (st.qa ?? []).isEmpty { question = q; ask() }
            #endif
        }
    }
    /// 질문 보내기: 비면 무시, 답이 오면 입력란을 비운다(문답은 st.qa에 붙어 다시 열어도 남는다)
    private func ask() {
        let t = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !asking, let onAsk else { return }
        asking = true; askErr = nil
        Task {
            do { try await onAsk(t); question = "" }
            catch { askErr = error.localizedDescription }
            asking = false
        }
    }
    private func labeled(_ label: String, _ text: String, color: Color, size: CGFloat = 19) -> some View {
        (Text(label + " ").font(Theme.hand(size - 2)).foregroundColor(Theme.pencil) + Text(text).font(Theme.hand(size)).foregroundColor(color))
            .fixedSize(horizontal: false, vertical: true)
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
    var mastered: ((Expression) -> Bool)? = nil     // 표현장에서 습득 완료 도장이 찍힌 표현이면 공책 포스트잇에도 도장
    /// 붙여 둔 표현에서 엮기 (2026-11-18): "써 보기 ✎" 옆 "엮기 ↗"(접기), 그 아래 "↗ 엮은 것"(풀기 ×)
    var links: ((Expression) -> [HighlightLink])? = nil
    var onLink: ((Expression) -> Void)? = nil
    var linkLabel: ((Expression) -> String)? = nil
    var onRemoveLink: ((Expression, HighlightLink) -> Void)? = nil
    var stars: ((Expression) -> Int)? = nil           // 중요도 별 (안 붙은 포스트잇도 누르면 붙이고 별)
    var onStars: ((Expression, Int) -> Void)? = nil
    var note: ((Expression) -> String?)? = nil        // 표현 내 메모: 포스트잇 안 "✎ 메모" + 아래 "내 메모 ✎/메모 고치기"
    var noting: String? = nil                         // 메모 입력이 열린 표현(글자)
    var onNote: ((Expression) -> Void)? = nil
    var onSaveNote: ((Expression, String) -> Void)? = nil
    var onOpen: ((Expression) -> Void)? = nil         // "표현장 ↗" (붙은 포스트잇만)
    var onSpeak: ((Expression) -> Void)? = nil        // 🔊 한 번 읽기
    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach(items, id: \.0) { e, saved, i in
                VStack(alignment: .leading, spacing: 2) {
                    // A안(goni 2026-11-20): 🔊 ★★★ 메모는 포스트잇 안으로. 본체 탭은 전처럼 붙이기/습득 완료(안의 버튼이 먼저 받는다)
                    Sticky(phrase: e.phrase, meaning: e.meaning, index: i, pinned: saved, mastered: saved && (mastered?(e) ?? false), note: note?(e),
                           speak: onSpeak != nil, stars: stars?(e) ?? 0, onStars: onStars == nil ? nil : { w in onStars?(e, w) }, onNote: onNote == nil ? nil : { onNote?(e) })
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(e) }
                        .help(saved ? "붙여 둠. 누르면 습득 완료(표현장에 남고 응용·시험지에서 빠짐). 떼려면 표현장에서 ×" : "누르면 표현장에 붙인다")
                    if onTry != nil || (saved && (onLink != nil || onOpen != nil)) {
                        FlowLayout(spacing: 12) {   // 아래 줄은 써 보기 ✎ · 엮기 ⟷ · 표현장 ⧉ 셋
                            if let onTry { TryButton(title: openPhrase == e.phrase ? "접기" : "써 보기 ✎\u{FE0E}", count: openPhrase == e.phrase ? 0 : (counts[e.phrase] ?? 0)) { onTry(e) } }
                            if saved, let onLink { Tiny(title: linkLabel?(e) ?? "엮기 ⟷\u{FE0E}", size: 17) { onLink(e) } }
                            if saved, let onOpen { Tiny(title: "표현장 ⧉\u{FE0E}", size: 17) { onOpen(e) } }
                        }
                        .padding(.leading, 6)
                    }
                    if noting == e.phrase, let onSaveNote {
                        NoteEditor(initial: note?(e) ?? "", onSave: { t in onSaveNote(e, t) }, onCancel: { onNote?(e) }).padding(.leading, 6)
                    }
                    // 엮은 것 (풀기 ×)
                    ForEach(links?(e) ?? []) { l in
                        LinkLine(l: l, onOpen: onOpenSentence, onRemove: onRemoveLink == nil ? nil : { onRemoveLink?(e, l) }).padding(.leading, 6)
                    }
                    // 이 표현을 가리키는 형광펜·표현들 (거꾸로 링크)
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

/// 원문 문장 듣기 (goni 2026-11-20 "문장 자체도 소리를 들을 수 있게"). 영어만 한 번(TapePlayer.speakOnce — 테이프 재생 중이면 멈춘다).
/// 읽는 동안은 빨간 "멈춤 ■"(작은 버튼은 ■)로 바뀌고 누르면 즉시 멈춤(goni "바로 멈출 수도 있게"). 다른 🔊를 누르면 끊고 그것을 읽는다
struct SpeakButton: View {
    var text: String
    var label = "듣기 🔊\u{FE0E}"
    var stopLabel = "멈춤 ■\u{FE0E}"
    var size: CGFloat = 20
    @ObservedObject private var tape = TapePlayer.shared
    var body: some View {
        let on = tape.speakingOnce == text
        Tiny(title: on ? stopLabel : label, color: on ? Theme.red : Theme.pencil, size: size) { tape.toggleOnce(text) }
            .help(on ? "읽기를 멈춘다" : "원문을 영어로 읽어 준다")
            .accessibilityLabel(on ? "멈춤" : "원문 듣기")
    }
}

/// 작은 🔊 아이콘 토글 (포스트잇·형광펜 메모·빨간 펜 지적·표현장): 읽는 중이면 빨간 ■
struct SpeakIcon: View {
    var text: String
    var size: CGFloat = 13
    var padding = EdgeInsets()
    var color: Color = Theme.ink
    @ObservedObject private var tape = TapePlayer.shared
    var body: some View {
        let on = tape.speakingOnce == text
        Button { tape.toggleOnce(text) } label: {
            Text(on ? "■\u{FE0E}" : "🔊").font(.system(size: size)).foregroundStyle(on ? Theme.red : color).padding(padding)
        }
        .buttonStyle(.plain).accessibilityLabel(on ? "멈춤" : "읽어 주기")
    }
}

/// 영어 원문 복사 (goni 2026-11-17, 사전·다른 앱에 붙여 넣으려고). 누르면 1.5초 "복사됨 ✓"
struct CopyButton: View {
    var text: String
    var label = "원문 복사 ⎘\u{FE0E}"
    var doneLabel = "복사됨 ✓\u{FE0E}"
    var size: CGFloat = 20
    @State private var done = false
    var body: some View {
        Tiny(title: done ? doneLabel : label, color: done ? Theme.grade(.A) : Theme.pencil, size: size) {
            UIPasteboard.general.string = text
            done = true
            Task { try? await Task.sleep(for: .seconds(1.5)); done = false }
        }
        .help("영어 원문을 클립보드에 복사한다")
        .accessibilityLabel("원문 복사")
    }
}

/// 원문 줄 끝 도구 (goni 2026-11-20 A안 "원문의 것은 원문 옆에"): 복사 ⎘ · 듣기 🔊(읽는 중 ■) · "구조 분석"(글자, goni 2026-11-22 "아이콘을 알아보기 힘들어서 한글로"; 열려 있으면 "구조 접기", 분석 중 "분석 중…")
struct SrcTools: View {
    var text: String
    var structOpen = false
    var structBusy = false
    var onStructure: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 10) {
            CopyButton(text: text, label: "⎘\u{FE0E}", doneLabel: "✓\u{FE0E}", size: 18)
            SpeakIcon(text: text, size: 14, color: Theme.pencil)
            if let onStructure {
                Tiny(title: structBusy ? "분석 중…" : structOpen ? "구조 접기" : "구조 분석", color: structOpen ? Theme.ink : Theme.pencil, size: 18, action: onStructure)
                    .disabled(structBusy)
                    .help(structOpen ? "구조 분석 접기" : "문장의 뼈대와 덩어리, 읽는 순서, 내 번역이 구조를 어떻게 읽었는지. 처음 한 번만 Claude가 분석하고 저장한다")
            }
        }
        .padding(.leading, 10).frame(height: Theme.lh)
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
    var onFree: (Expression, String, String) async throws -> Drill?   // (표현, 내 문장, drill_id) — drill_id는 멈추기·재전송 중복 방지용 클라이언트 UUID
    var onDrillFor: ((Expression) async throws -> Drill?)?
    var onAnswerDrill: ((Drill, String) async throws -> Drill?)?   // nil = 큐에 들어감(연결되면 채점)
    var onClose: () -> Void
    var onGraded: (() -> Void)? = nil
    @ObservedObject private var session = SessionModel.shared   // 공부 시작 전엔 입력란 대신 StartGate
    @State private var answer = ""
    @State private var result: Drill?
    @State private var prompt: Drill?       // "문제 내줘"로 받은 한국어 문장
    @State private var busy = false
    @State private var busyLabel = ""          // "채점 중… ✎" | "문제 내는 중… ✎"
    @State private var blink = false
    @State private var queued = false
    @State private var msg: String?
    @State private var past: [Drill] = []      // 같은 표현으로 푼 지난 시도 (최신순, 최대 10)
    @State private var pastLoading = false     // 서버에서 지난 시도를 받는 중 (캐시에 없을 때만 "불러오는 중…")
    @State private var openPast: String?       // 탭해서 펼친 지난 시도
    @State private var gradingTask: Task<Void, Never>?   // 채점 요청. 멈추기 때 cancel
    @State private var gradingId: String?                // 채점 중인 문제 id(출제형) 또는 drill_id(자유 작문). nil이면 채점 중이 아니다
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
            } else if !session.inSession {
                StartGate { focused = true }
            } else {
                TextField("영어로 쓴다", text: $answer, axis: .vertical)
                    .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                    .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                    .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                    .focused($focused).disabled(busy).opacity(busy ? 0.55 : 1)     // 서버가 일하는 동안 입력란은 비활성·반투명, 글은 그대로
                    .onChange(of: answer) { _, v in if v.contains("\n") { answer = v.replacingOccurrences(of: "\n", with: " "); Task { await submit() } } }
            }
            if past.isEmpty, pastLoading {
                Text("지난 시도 불러오는 중…").font(Theme.hand(17)).foregroundStyle(Theme.pencil).padding(.top, 4)
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
                } else {
                    if onDrillFor != nil, prompt == nil { Tiny(title: "문제 내줘", size: 19) { Task { await askPrompt() } }.disabled(busy).opacity(busy ? 0.4 : 1) }
                }
                Tiny(title: "닫기", size: 19) { onClose() }.disabled(busy).opacity(busy ? 0.4 : 1)
                if busy {
                    // 서버가 일하는 동안 깜빡이는 연필색 글씨
                    Text(busyLabel).font(Theme.hand(19)).foregroundStyle(Theme.pencil).opacity(blink ? 0.25 : 1)
                        .onAppear { blink = false; withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { blink = true } }
                    if gradingId != nil { Tiny(title: "멈추기 ↩\u{FE0E}", size: 19) { stop() } }
                }
                if let msg { ErrorText(message: msg) }
            }
            .frame(minHeight: Theme.lh)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.tab.opacity(0.25))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.tab).frame(width: 3) }
        // 오른쪽 위 × 닫기 (goni 2026-11-19 "닫기가 아래 줄에만 있어 찾기 불편"). 채점 중엔 비활성
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(8) }
                .buttonStyle(.plain).disabled(busy).opacity(busy ? 0.4 : 1).accessibilityLabel("써 보기 닫기")
        }
        .padding(.vertical, 6)
        .onAppear { focused = true }
        .task {
            await loadPast()
            #if DEBUG
            // 화면 확인용: LBN_AUTOTRY=<문장 id>로 상자가 열렸으면 문장을 넣고 바로 제출한다 (채점 중·멈추기 확인용)
            if ProcessInfo.processInfo.environment["LBN_AUTOTRY"] != nil, result == nil, !busy, session.inSession {   // 공부 시작 전(StartGate)이면 상자만 연다
                answer = "She will set out a plan for the new policy."
                if ProcessInfo.processInfo.environment["LBN_AUTOSTOP"] == "1" { Task { try? await Task.sleep(for: .seconds(2)); stop() } }   // 2초 뒤 멈추기까지
                await submit()
            }
            #endif
        }
    }

    /// 같은 표현으로 푼 지난 시도: 로컬 캐시 것을 먼저 보여 주고, 서버에서 그 표현만(GET /api/drills?phrase=) 받아 맞춘다.
    /// 전에는 1년치 전체(?days=365, 약 290KB·1.5초+)를 받아 걸러서 "써 보기 · 2"인데 지난 시도가 늦게 나왔다 (goni 2026-11-23, 웹 fb39342)
    private func loadPast() async {
        past = await MainActor.run { Cache.shared.drills(phrase: expr.phrase) }
        pastLoading = true
        defer { pastLoading = false }
        if let r = try? await API.shared.drills(phrase: expr.phrase) {
            past = r.filter { $0.answer != nil }.sorted { ($0.answeredAt ?? 0) > ($1.answeredAt ?? 0) }
        }
    }

    private func submit() async {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !busy else { return }
        busy = true; busyLabel = "채점 중… ✎\u{FE0E}"; msg = nil
        let id = prompt?.id ?? UUID().uuidString.lowercased()
        gradingId = id
        let t = Task {
            do {
                let r: Drill? = if let p = prompt, let onAnswerDrill { try await onAnswerDrill(p, a) } else { try await onFree(expr, a, id) }
                guard gradingId == id else { return }
                if let r { result = r; past.insert(r, at: 0); if r.answeredAt != nil { onGraded?() } }
                else { queued = true }   // 오프라인이거나 끊김: 큐에 남아 연결되면 채점
            } catch {
                guard gradingId == id else { return }   // 멈춘 요청의 오류(취소·409 cancelled)는 보여주지 않는다
                msg = error.localizedDescription
            }
        }
        gradingTask = t
        await t.value
        if gradingId == id { gradingId = nil; gradingTask = nil; busy = false }
    }
    /// 멈추기: 요청 취소 → 서버에 DELETE grading → 쓰던 문장은 입력란에 그대로 두고 이어 쓴다
    private func stop() {
        guard busy, let id = gradingId else { return }
        gradingId = nil
        gradingTask?.cancel(); gradingTask = nil
        busy = false; msg = nil
        focused = true
        AppLog.shared.info("trybox", "stop", ["id": id])
        Task { await SyncManager.shared.stopDrillGrading(id: id) }
    }
    private func askPrompt() async {
        guard let onDrillFor else { return }
        busy = true; busyLabel = "문제 내는 중… ✎\u{FE0E}"; msg = nil
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
    var rowSpacing: CGFloat? = nil   // 줄 사이 간격 (nil이면 spacing과 같게). 동작 줄은 0으로 줄 높이를 괘선에 맞춘다
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: w, height: nil))
            if x + s.width > w, x > 0 { x = 0; y += rowH + (rowSpacing ?? spacing); rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: w, height: nil))
            if x + s.width > w, x > 0 { x = 0; y += rowH + (rowSpacing ?? spacing); rowH = 0 }
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
    var tools: SrcTools? = nil                    // 원문 줄 끝 ⎘ 🔊 구조 분석 (A안)
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
                if let tools { tools }
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
    var stars: Int = 0                         // 중요도 별 (같은 글자 표현의 weight, 없으면 누르면 붙이고 별)
    var onStars: ((Int) -> Void)? = nil
    var onOpen: (() -> Void)? = nil            // "표현장 ↗" (표현장에 있을 때만)
    var speakText: String? = nil               // 🔊 구절만 한 번 (영어), 읽는 중엔 ■
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
                // A안: 오른쪽 위 🔊 ★★★ ×
                HStack(spacing: 2) {
                    if let t = speakText { SpeakIcon(text: t, size: 12) }
                    if let onStars { StarRow(stars: stars, size: 11, onSet: onStars) }
                    if let onDelete {
                        Button { Task { await onDelete(h) } } label: { Text("×").font(.system(size: 16)).foregroundStyle(Theme.pencil).padding(.horizontal, 4) }
                            .buttonStyle(.plain).accessibilityLabel("형광펜 지우기")
                    }
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
                // A안: 내 메모 줄은 눌러서 고치기, 아래 줄은 써 보기 · 엮기 ⟷ · 표현장 ⧉ · (메모 없을 때) + 메모
                if let n = h.note, !n.isEmpty {
                    Button { text = n; editing = true; focused = true } label: { Text("✎\u{FE0E} \(n)").font(Theme.hand(20)).foregroundStyle(Theme.blueInk) }
                        .buttonStyle(.plain).disabled(onNote == nil).help("누르면 메모를 고친다")
                }
                if onTry != nil || (onRelated != nil && onAddLink != nil) || onOpen != nil || (onNote != nil && (h.note ?? "").isEmpty) {
                    FlowLayout(spacing: 10) {   // 버튼이 늘어 한 줄에 안 들어가면 다음 줄로
                        if let onTry { TryButton(title: tryTitle, count: tryCount, action: onTry) }
                        if onRelated != nil, onAddLink != nil { Tiny(title: linking ? "접기" : "엮기 ⟷\u{FE0E}", size: 17) { linking.toggle() } }
                        if let onOpen { Tiny(title: "표현장 ⧉\u{FE0E}", size: 17, action: onOpen) }
                        if onNote != nil, (h.note ?? "").isEmpty { Tiny(title: "+ 메모", size: 17) { text = ""; editing = true; focused = true } }
                    }
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
