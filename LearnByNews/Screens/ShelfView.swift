import SwiftUI

/// 공책 목록 + 붙여넣기 + 공부 기록 (웹 Paste.tsx)
struct ShelfView: View {
    @EnvironmentObject var router: Router
    @ObservedObject private var session = SessionModel.shared
    @State private var raw = ""
    @State private var link = ""
    @State private var busy = false
    @State private var err: String?
    @State private var list: [ArticleSummary] = []
    /// 다시 쓰기 진행 중인 공책의 이번 회차 등급 (article id → 등급별 개수)
    @State private var roundGrades: [String: [String: Int]] = [:]
    @State private var loaded = false
    @State private var toDelete: ArticleSummary?
    @State private var sessionToDelete: StudySession?

    private var parsed: SplitResult { Split.article(raw) }

    var body: some View {
        NavigationStack(path: $router.shelfPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sheet
                    SessionBar(model: session).padding(.horizontal, 4).padding(.top, 14)
                    if !list.isEmpty { notebooks.padding(.top, 36) }
                    if !session.sessions.isEmpty { ledger.padding(.top, 40) }
                }
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 60, trailing: 10))
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.desk.ignoresSafeArea())
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .notebook(let id, let focus, let restartAfter, let browse): NotebookView(articleId: id, focusId: focus, restartAfter: restartAfter, browseAll: browse)
                case .done(let id, let newReview): DoneView(articleId: id, newReview: newReview)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: router.shelfPath) { _, p in if p.isEmpty { Task { await load() } } }
        }
    }

    // MARK: 붙여넣기 종이
    private var sheet: some View {
        let p = parsed
        let paragraphs = Set(p.sentences.map(\.paragraph)).count
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if raw.isEmpty {
                    Text("첫 줄에 제목, 아래에 본문을 붙여넣는다.")
                        .font(Theme.hand(22)).foregroundStyle(Theme.placeholder)
                        .padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $raw)
                    .font(Theme.print(16))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 9 * 28)
                    .lineSpacing(8)
            }
            TextField("기사 링크 (선택)", text: Binding(get: { link.isEmpty ? p.source : link }, set: { link = $0 }))
                .font(Theme.hand(20)).foregroundStyle(Theme.blueInk)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .frame(height: 28)
            HStack {
                MutedText(text: p.sentences.isEmpty ? " " : "문단 \(paragraphs) · 문장 \(p.sentences.count)")
                Spacer()
                Tiny(title: busy ? "공책 만드는 중…" : "새 공책 만들기 →\u{FE0E}", color: Theme.red) { Task { await create() } }
                    .disabled(p.sentences.isEmpty || busy)
                    .opacity(p.sentences.isEmpty || busy ? 0.45 : 1)
            }
            if let err { ErrorText(message: err) }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 12, trailing: 20))
        .background(
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.paper))
                var y: CGFloat = 18 + 28
                while y < size.height - 12 { ctx.fill(Path(CGRect(x: 0, y: y - 1, width: size.width, height: 1)), with: .color(Theme.rule)); y += 28 }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
    }

    // MARK: 공책들
    private var notebooks: some View {
        VStack(spacing: 12) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                // 이 기기에 다시 쓰기 진행 상태가 있으면 "n회차 진행 중"으로, 누르면 공책에서 이어진다
                let prog = RedoProgress.load(a.id).flatMap { $0.remaining.isEmpty ? nil : $0 }
                let status: String = prog.map { "\($0.ids.count - $0.remaining.count) / \(a.sentenceCount)" }
                    .map { "\(a.rounds + 1)회차 진행 중 \($0)" }
                    ?? (a.isDone ? (a.rounds >= 2 ? "완료 · \(a.rounds)회차" : "완료") : "\(a.doneCount) / \(a.sentenceCount)")
                HStack(spacing: 0) {
                    Button {
                        router.shelfPath = [(a.isDone && prog == nil) ? .done(id: a.id) : .notebook(id: a.id)]
                    } label: {
                        HStack(alignment: .center, spacing: 16) {
                            Text(a.title).font(Theme.hand(24)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 6) {
                                MutedText(text: status).fixedSize()
                                // 진행 중이면 이번 회차에 다시 쓴 문장의 등급만, 아니면 문장별 최신 채점
                                GradeBar(grades: prog != nil ? (roundGrades[a.id] ?? [:]) : a.grades, total: a.sentenceCount)
                            }
                        }
                        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if let s = a.source, let url = URL(string: s), !s.isEmpty {
                        Link(destination: url) { Text("↗\u{FE0E}").font(.system(size: 16)).foregroundStyle(Theme.pencil).padding(.horizontal, 10) }
                    }
                    Button { toDelete = a } label: { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(.horizontal, 14) }
                        .buttonStyle(.plain)
                }
                .background(Theme.paper)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.coverColors[i % 4]).frame(width: 14) }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 8, topTrailingRadius: 8))
                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.08), radius: 5, y: 4)
            }
        }
        .confirmationDialog("\"\(toDelete?.title ?? "")\" 공책을 버릴까요?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
            Button("버리기", role: .destructive) { if let a = toDelete { Task { await remove(a) } } }
        }
    }

    // MARK: 공부 기록
    private var ledger: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("공부 기록").font(Theme.hand(24)).foregroundStyle(Theme.pencil)
            VStack(spacing: 0) {
                ForEach(session.sessions) { s in
                    HStack(spacing: 14) {
                        Text(s.line).font(Theme.hand(22)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                        MutedText(text: s.articles.joined(separator: ", ")).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { sessionToDelete = s } label: { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(.horizontal, 4) }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                }
            }
            .background(
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.paper))
                    var y: CGFloat = 36
                    while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y - 1, width: size.width, height: 1)), with: .color(Theme.rule)); y += 36 }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
        }
        .confirmationDialog("\(sessionToDelete?.line ?? "") 기록을 지울까요?", isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }), titleVisibility: .visible) {
            Button("지우기", role: .destructive) { if let s = sessionToDelete { Task { await session.remove(s) } } }
        }
    }

    // MARK: 동작
    private func load() async {
        async let a: Void = loadList()
        async let b: Void = session.load()
        _ = await (a, b)
        session.start = SessionStore.start
    }
    private func loadList() async {
        do { list = try await API.shared.articles(); err = nil }
        catch { err = error.localizedDescription }
        loaded = true
        await loadRoundGrades()
    }

    /// 진행 상태가 있는 공책만 상세를 받아 done 문장의 등급을 센다
    private func loadRoundGrades() async {
        var out: [String: [String: Int]] = [:]
        for a in list {
            guard let p = RedoProgress.load(a.id), !p.remaining.isEmpty else { continue }
            guard let d = try? await API.shared.article(a.id) else { continue }
            var g: [String: Int] = [:]
            for s in d.sentences where p.done.contains(s.id) {
                if let gr = s.attempt?.grade { g[gr.rawValue, default: 0] += 1 }
            }
            out[a.id] = g
        }
        roundGrades = out
    }
    private func create() async {
        let p = parsed
        guard !p.sentences.isEmpty, !busy else { return }
        busy = true; err = nil
        do {
            let source = (link.isEmpty ? p.source : link).trimmingCharacters(in: .whitespaces)
            let id = try await API.shared.createArticle(title: p.title, sentences: p.sentences, source: source)
            AppLog.shared.info("shelf", "article created", ["id": id, "sentences": "\(p.sentences.count)"])
            raw = ""; link = ""
            router.shelfPath = [.notebook(id: id)]
        } catch { err = error.localizedDescription }
        busy = false
    }
    private func remove(_ a: ArticleSummary) async {
        do { try await API.shared.deleteArticle(a.id); await loadList() }
        catch { err = error.localizedDescription }
    }
}
