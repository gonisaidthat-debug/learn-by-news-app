import SwiftUI

struct Inflight: Hashable {
    var translation: String
    var attemptId: String
    var wasRedo: Bool          // 다시 쓰기 중이던 문장이면 멈출 때 그 자리로 돌아간다
    var error: String?
}

@MainActor
final class NotebookModel: ObservableObject {
    let id: String
    let focusId: String?
    let restart: Bool
    @Published var data: ArticleDetail?
    /// 처음부터 다시 쓰기: 순서대로 다시 쓸 문장 id 목록. 기존 기록은 history로 남는다
    @Published var pass: [String]?
    @Published var finishedPass = false   // 마지막 문장을 제출했다 → 마지막 장으로 (새 총평)
    @Published var input = ""
    @Published var inflight: [String: Inflight] = [:]
    @Published var redo: String?         // 다시 쓰는 중인 문장 id
    @Published var open: String?
    @Published var refOpen: [String: Bool] = [:]
    @Published var lastGraded: String?
    @Published var err: String?
    @Published var scrollTo: String?     // 스크롤 목표 ("bottom" 또는 문장 id)
    @Published var focusRequest = 0      // 입력란에 포커스를 달라는 신호
    var browse: Bool { focusId != nil }
    private var tasks: [String: Task<Void, Never>] = [:]   // 채점 요청. 멈추기 때 cancel
    private var stopped: Set<String> = []                   // 멈춘 attempt_id. 뒤늦은 오류를 무시한다

    init(id: String, focusId: String?, restart: Bool) { self.id = id; self.focusId = focusId; self.restart = restart }

    var frontIdx: Int? {
        guard let d = data else { return nil }
        return d.sentences.firstIndex { $0.attempt == nil && inflight[$0.id] == nil }
    }
    var current: Sentence? {
        guard let d = data else { return nil }
        if let redo { return d.sentences.first { $0.id == redo } }
        return frontIdx.map { d.sentences[$0] }
    }
    var allDone: Bool { data?.sentences.allSatisfy { $0.attempt != nil } ?? false }

    func load(onDone: @escaping () -> Void) async {
        do {
            let d = try await API.shared.article(id)
            if let focusId { data = d; open = focusId; requestScroll(focusId); return }
            if restart, let first = d.sentences.first {
                let ids = d.sentences.map(\.id)
                data = d; pass = ids; redo = first.id; input = ""
                AppLog.shared.info("notebook", "restart pass", ["article": id, "count": "\(ids.count)"])
                requestScroll(first.id); focusRequest += 1
                return
            }
            if d.sentences.allSatisfy({ $0.attempt != nil }) { data = d; onDone(); return }
            data = d; requestScroll("bottom")
        } catch { err = error.localizedDescription }
    }

    /// 레이아웃이 끝난 뒤 스크롤하도록 한 박자 늦게 목표를 올린다
    func requestScroll(_ target: String) {
        Task { try? await Task.sleep(for: .milliseconds(250)); scrollTo = target }
    }

    func reload() async {
        do { data = try await API.shared.article(id) } catch { err = error.localizedDescription }
    }

    func applyResult(_ sid: String, _ r: AttemptResult) {
        guard var d = data, let i = d.sentences.firstIndex(where: { $0.id == sid }) else { inflight[sid] = nil; return }
        var s = d.sentences[i]
        if let prev = s.attempt { s.history.append(prev) }
        s.attempt = r.asAttempt
        d.sentences[i] = s
        data = d
        inflight[sid] = nil
        if r.grade != .skip { open = sid; lastGraded = sid; requestScroll("bottom") }
    }

    func send(_ sid: String, _ translation: String, wasRedo: Bool? = nil) {
        let attemptId = UUID().uuidString.lowercased()
        let redoing = wasRedo ?? (data?.sentences.first { $0.id == sid }?.attempt != nil)
        inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing)
        AppLog.shared.info("notebook", translation.isEmpty ? "skip" : "submit", ["sentence": sid, "attempt": attemptId, "chars": "\(translation.count)"])
        tasks[sid] = Task {
            defer { tasks[sid] = nil }
            do { let r = try await API.shared.attempt(sid, translation: translation, attemptId: attemptId); if !stopped.contains(attemptId) { applyResult(sid, r) } }
            catch {
                // 멈춘 요청의 오류(취소, 409 cancelled)는 보여주지 않는다
                if stopped.contains(attemptId) || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                inflight[sid] = Inflight(translation: translation, attemptId: attemptId, wasRedo: redoing, error: error.localizedDescription)
            }
        }
    }

    /// 멈추기: 요청 취소 → 서버에 DELETE → 그 문장을 다시 입력란으로, 쓰던 번역은 그대로
    func stop(_ sid: String) {
        guard let f = inflight[sid] else { return }
        stopped.insert(f.attemptId)
        tasks[sid]?.cancel(); tasks[sid] = nil
        inflight[sid] = nil
        AppLog.shared.info("notebook", "stop", ["sentence": sid, "attempt": f.attemptId])
        if f.wasRedo { redo = sid } else { redo = nil }
        input = f.translation
        focusRequest += 1
        Task {
            do { let r = try await API.shared.cancelAttempt(f.attemptId); AppLog.shared.info("notebook", "stop ok", ["attempt": f.attemptId, "removed": "\(r.removed ?? false)"]) }
            catch { AppLog.shared.warn("notebook", "stop failed: \(error.localizedDescription)", ["attempt": f.attemptId]) }
        }
    }

    /// 현재 문장을 제출(또는 건너뛰기)하고 즉시 다음 문장으로
    func submit(skip: Bool) {
        guard let cur = current else { return }
        let t = skip ? "" : input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !skip && t.isEmpty { return }
        let wasRedo = redo != nil
        input = ""
        send(cur.id, t, wasRedo: wasRedo)
        if let pass {
            // 처음부터 다시: 다음 문장으로 이어서, 끝나면 새 총평을 받으러 마지막 장으로
            let i = pass.firstIndex(of: cur.id) ?? -1
            if i >= 0, i + 1 < pass.count {
                let next = pass[i + 1]
                redo = next; requestScroll(next); focusRequest += 1
            } else {
                self.pass = nil; redo = nil; finishedPass = true
            }
            return
        }
        redo = nil
        requestScroll("bottom")
    }

    func startRedo(_ s: Sentence) { redo = s.id; open = nil; input = "" }
    func cancelRedo() { redo = nil; pass = nil; input = "" }
    var passLabel: String? {
        guard let pass, let redo, let i = pass.firstIndex(of: redo) else { return nil }
        return "다시 \(i + 1) / \(pass.count)"
    }

    func merge(_ sid: String, dir: String) async {
        do { _ = try await API.shared.merge(sid, dir: dir); AppLog.shared.info("notebook", "merge \(dir)", ["sentence": sid]); await reload(); input = "" }
        catch { err = error.localizedDescription }
    }

    /// 문장을 공책에서 뺀다. 빈 공책이 되면 true
    func remove(_ sid: String) async -> Bool {
        do {
            try await API.shared.deleteSentence(sid)
            AppLog.shared.info("notebook", "remove sentence", ["sentence": sid])
            guard var d = data else { return false }
            d.sentences.removeAll { $0.id == sid }
            if d.sentences.isEmpty { return true }
            data = d
            if redo == sid { redo = nil }
            if current?.id == sid { input = "" }
        } catch { err = error.localizedDescription }
        return false
    }

    func togglePhrase(_ sid: String, _ e: Expression) async {
        guard var d = data else { return }
        do {
            if let ex = d.phrases.first(where: { $0.sentenceId == sid && $0.phrase == e.phrase }) {
                try await API.shared.deletePhrase(ex.id); d.phrases.removeAll { $0.id == ex.id }
            } else {
                let p = try await API.shared.savePhrase(e, sentenceId: sid, articleId: d.id); d.phrases.append(p)
            }
            data = d
        } catch { err = error.localizedDescription }
    }

    func setSource(_ url: String) async {
        do { try await API.shared.setSource(id, url); data?.source = url } catch { err = error.localizedDescription }
    }

    /// 세션마다 이 공책에서 마지막으로 채점한 문장 뒤에 "여기까지" 줄
    func markers(_ sessions: [StudySession]) -> [String: StudySession] {
        guard let d = data else { return [:] }
        var m: [String: StudySession] = [:]
        for s in sessions {
            var best: Sentence?
            for x in d.sentences {
                guard let t = x.attempt?.createdAt, t >= s.startedAt, t <= s.endedAt else { continue }
                if best == nil || t > best!.attempt!.createdAt { best = x }
            }
            if let best { m[best.id] = s }
        }
        return m
    }
}

/// 공책 (웹 Read.tsx)
struct NotebookView: View {
    var articleId: String
    var focusId: String? = nil
    var restart: Bool = false
    @EnvironmentObject var router: Router
    @ObservedObject private var session = SessionModel.shared
    @StateObject private var m: NotebookModel
    @FocusState private var focused: Bool
    @State private var toRemove: Sentence?

    init(articleId: String, focusId: String? = nil, restart: Bool = false) {
        self.articleId = articleId; self.focusId = focusId; self.restart = restart
        _m = StateObject(wrappedValue: NotebookModel(id: articleId, focusId: focusId, restart: restart))
    }

    var body: some View {
        ZStack {
            Theme.desk.ignoresSafeArea()
            if let d = m.data { content(d) }
            else if let e = m.err { ErrorText(message: e).padding() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.desk, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { Text(m.data?.title ?? "").font(Theme.hand(22)).lineLimit(1) }
        }
        .task {
            await m.load { router.shelfPath = [.done(id: articleId)] }
            await session.load()
            if !m.browse { focused = true }
            #if DEBUG
            // 화면 확인용: LBN_AUTOSUBMIT=1 이면 현재 문장에 번역을 넣고 바로 제출한다 (채점 중 상태)
            if ProcessInfo.processInfo.environment["LBN_AUTOSUBMIT"] == "1", session.inSession, m.current != nil {
                m.input = "분석가들은 노동 시장이 더 약해지면 12월 15일까지 인하를 예상한다."; m.submit(skip: false)
            }
            #endif
        }
        .onChange(of: m.allDone) { _, done in
            // 모든 문장이 채점되면 마지막 장으로
            if done, m.inflight.isEmpty, m.redo == nil, !m.browse { router.shelfPath = [.done(id: articleId)] }
        }
        .onChange(of: m.focusRequest) { _, _ in focused = true }
        .onChange(of: m.finishedPass) { _, f in if f { router.shelfPath = [.done(id: articleId, newReview: true)] } }
        .onChange(of: m.inflight.isEmpty) { _, empty in
            if empty, m.allDone, m.redo == nil, !m.browse { router.shelfPath = [.done(id: articleId)] }
        }
    }

    private func content(_ d: ArticleDetail) -> some View {
        let total = d.sentences.count
        let doneCount = d.sentences.filter { $0.attempt != nil }.count
        let upto = m.browse ? total : (m.frontIdx ?? total)
        let waiting = m.inflight.count
        let markers = m.markers(session.sessions)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookHead(tab: m.passLabel ?? "\(doneCount) / \(total)") {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(d.title).lineLimit(2)
                            SourceLink(source: d.source ?? "") { await m.setSource($0) }
                        }
                    }
                    Paper {
                        ForEach(Array(d.sentences.prefix(upto).enumerated()), id: \.element.id) { i, x in
                            if i > 0, d.sentences[i - 1].paragraph != x.paragraph { BlankLine() }
                            row(x, d: d)
                            if let s = markers[x.id] { SessionMark(session: s) }
                        }
                        if m.redo == nil, !m.browse, let cur = m.current {
                            if let f = m.frontIdx, f > 0, d.sentences[f - 1].paragraph != cur.paragraph { BlankLine() }
                            inputBlock(cur)
                        }
                        foot(d, waiting: waiting)
                        SessionBar(model: session, waiting: waiting, hideStart: true)
                            .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 40, trailing: 10))
                Color.clear.frame(height: 1).id("bottom")
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: m.scrollTo) { _, t in
                guard let t else { return }
                withAnimation { proxy.scrollTo(t, anchor: t == "bottom" ? .bottom : .center) }
                m.scrollTo = nil
            }
        }
        .confirmationDialog("이 문장을 공책에서 뺄까요?", isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }), titleVisibility: .visible) {
            Button("빼기", role: .destructive) {
                if let s = toRemove { Task { if await m.remove(s.id) { router.shelfPath = [] } } }
            }
        }
    }

    @ViewBuilder
    private func row(_ x: Sentence, d: ArticleDetail) -> some View {
        if m.redo == x.id {
            inputBlock(x)
        } else if let f = m.inflight[x.id] {
            Entry(stamp: AnyView(Stamp(kind: f.error == nil ? .busy : .error))) {
                Text(x.text).enLine()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if f.translation.isEmpty { Text("건너뜀").handLine(size: 21, color: Theme.pencil) } else { Text(f.translation).koLine() }
                    if f.error == nil { Tiny(title: "멈추기 ↩\u{FE0E}") { m.stop(x.id); focused = true } }
                }
                if let e = f.error {
                    HStack(spacing: 10) {
                        Text(e).redpen()
                        Tiny(title: "다시 시도") { m.send(x.id, f.translation, wasRedo: f.wasRedo) }
                    }
                }
            }
            .id(x.id)
        } else if x.attempt != nil {
            EntryView(
                s: x, expanded: m.open == x.id,
                onToggle: { m.open = m.open == x.id ? nil : x.id },
                showRef: m.refOpen[x.id] ?? true,
                onToggleRef: { m.refOpen[x.id] = !(m.refOpen[x.id] ?? true) },
                savedPhrases: d.phrases.filter { $0.sentenceId == x.id },
                onTogglePhrase: { e in Task { await m.togglePhrase(x.id, e) } },
                onRemove: { toRemove = x },
                onRedo: { m.startRedo(x); focused = true },
                highlight: focusId == x.id
            )
            .id(x.id)
        } else {
            Entry { Text(x.text).enLine(); Text("(아직)").handLine(size: 21, color: Theme.pencil) }.id(x.id)
        }
    }

    private func inputBlock(_ s: Sentence) -> some View {
        let redo = m.redo != nil
        return Entry(stamp: redo ? AnyView(Stamp(kind: .redo)) : nil) {
            Text(s.text).font(Theme.print(16)).foregroundStyle(redo ? Theme.pencil : Theme.ink).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
            if !session.inSession {
                Button { session.begin(); focused = true } label: {
                    Text("공부 시작 ▶\u{FE0E} 을 누르면 여기에 쓸 수 있다").redpen()
                }.buttonStyle(.plain)
            } else {
                TextField(redo ? "다시 쓴다" : "여기에 번역을 쓴다", text: $m.input, axis: .vertical)
                    .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                    .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                    .focused($focused)
                    .submitLabel(.send)
                    .onChange(of: m.input) { _, v in
                        // 한글 조합 중 Enter는 글자 확정이지 제출이 아니다 →\u{FE0E} 조합이 끝나 줄바꿈이 실제로 들어온 뒤에만 제출
                        if v.contains("\n") { m.input = v.replacingOccurrences(of: "\n", with: " "); m.submit(skip: false) }
                    }
            }
        }
        .id(s.id)
    }

    @ViewBuilder
    private func foot(_ d: ArticleDetail, waiting: Int) -> some View {
        let cur = m.current
        VStack(alignment: .leading, spacing: 4) {
            if let e = m.err { ErrorText(message: e) }
            FlowLayout(spacing: 18) {
                if m.browse {
                    Tiny(title: "←\u{FE0E} 돌아가기") { router.shelfPath.removeLast() }
                    if cur != nil { Tiny(title: "이어서 쓰기 →\u{FE0E}", color: Theme.red) { router.shelfPath = [.notebook(id: articleId)] } }
                    else { Tiny(title: "마지막 장 →\u{FE0E}") { router.shelfPath = [.done(id: articleId)] } }
                } else if let cur {
                    if session.inSession { Tiny(title: "건너뛰기") { m.submit(skip: true) } }
                    Tiny(title: "제거") { toRemove = cur }
                    if m.redo != nil {
                        Tiny(title: m.pass != nil ? "다시 쓰기 그만" : "취소") { m.cancelRedo() }
                    } else {
                        let ci = d.sentences.firstIndex { $0.id == cur.id } ?? -1
                        let prev = ci > 0 ? d.sentences[ci - 1] : nil
                        let next = ci >= 0 && ci + 1 < d.sentences.count ? d.sentences[ci + 1] : nil
                        if let prev, prev.paragraph == cur.paragraph { Tiny(title: "↑\u{FE0E} 앞에 붙이기") { Task { await m.merge(cur.id, dir: "prev") } } }
                        if let next, next.attempt == nil, next.paragraph == cur.paragraph { Tiny(title: "↓\u{FE0E} 뒤와 합치기") { Task { await m.merge(cur.id, dir: "next") } } }
                    }
                    if waiting > 0 { MutedText(text: "채점 \(waiting)개 기다리는 중…") }
                } else {
                    MutedText(text: waiting > 0 ? "채점 \(waiting)개 기다리는 중…" : "끝")
                }
            }
        }
        .frame(minHeight: Theme.lh)
        .padding(.top, Theme.lh)
        .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
    }
}

/// "✂\u{FE0E} 여기까지 · 11/6 14:03–14:40 · 37분 · 12문장" 점선
struct SessionMark: View {
    var session: StudySession
    var body: some View {
        ZStack(alignment: .trailing) {
            Line().stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4])).foregroundStyle(Theme.red.opacity(0.55)).frame(height: 2)
            Text("✂\u{FE0E} 여기까지 · \(session.line)")
                .font(Theme.hand(19)).foregroundStyle(Theme.red)
                .padding(.horizontal, 8).background(Theme.paper)
        }
        .frame(height: Theme.lh)
        .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
    }
}

struct Line: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p }
}
