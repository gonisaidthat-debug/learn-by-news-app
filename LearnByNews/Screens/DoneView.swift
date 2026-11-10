import SwiftUI

/// 마지막 장: 점수·총평·다시 볼 문장·붙여 둔 표현 (웹 Done.tsx)
@MainActor
final class DoneModel: ObservableObject {
    let id: String
    let newReview: Bool   // 처음부터 다시 쓰기가 끝나면 기존 총평이 있어도 새로 받는다
    @Published var data: ArticleDetail?
    @Published var err: String?
    @Published var open: String?
    @Published var refOpen: [String: Bool] = [:]
    @Published var reviewing = false
    @Published var reviewErr: String?
    @Published var showOld = false
    @Published var bookmark: Bookmark?
    @Published var progress: RedoProgress?     // 저장된 다시 쓰기 진행 상태
    @Published var estimated: Int?             // 저장이 없을 때 추정한 "오늘 다시 쓴 앞쪽 문장 수"
    private var autoTried = false

    init(id: String, newReview: Bool) { self.id = id; self.newReview = newReview }

    func load() async {
        if data == nil, let c = Cache.shared.article(id) { data = c; progress = RedoProgress.load(id) }
        do {
            let d: ArticleDetail
            do { d = try await API.shared.article(id) }
            catch let e as APIError where e.isNetwork { if let c = Cache.shared.article(id) { d = c } else { throw e } }
            data = d
            progress = RedoProgress.load(id)
            if let server = try? await API.shared.pass(id) { progress = RedoProgress.from(serverDone: server.done, sentenceIds: d.sentences.map(\.id)); progress?.save(id) }
            else if Connectivity.shared.isOnline, (try? await API.shared.pass(id)) == nil, progress == nil { RedoProgress.clear(id) }
            bookmark = Cache.shared.bookmark()
            if let b = try? await API.shared.bookmark() { bookmark = b; Cache.shared.setBookmark(b) }
            estimated = progress == nil ? RedoProgress.estimateRewritten(d.sentences) : nil
            // 다시 쓰기가 진행 중이면 총평을 자동 요청하지 않는다
            if progress != nil { return }
            if newReview, !autoTried { autoTried = true; await requestReview(); return }
            // 다 끝났는데 총평이 없으면 한 번 자동으로 받는다
            if !autoTried, d.reviews.isEmpty, d.sentences.allSatisfy({ $0.attempt != nil }), d.sentences.contains(where: { $0.attempt != nil && $0.attempt!.grade != .skip }) {
                autoTried = true
                await requestReview()
            }
        } catch { err = error.localizedDescription }
    }

    func requestReview() async {
        guard let d = data, !reviewing else { return }
        guard Connectivity.shared.isOnline else { reviewErr = onlineOnlyMessage; return }
        reviewing = true; reviewErr = nil
        AppLog.shared.info("done", "review request", ["article": d.id])
        do {
            let r = try await API.shared.review(d.id, score: ArticleDetail.score(of: d.sentences))
            data?.reviews.insert(r, at: 0)
        } catch { reviewErr = error.localizedDescription }
        reviewing = false
    }

    func togglePhrase(_ sid: String, _ e: Expression) async {
        guard var d = data else { return }
        do {
            if let ex = d.phrases.first(where: { $0.sentenceId == sid && $0.phrase == e.phrase }) {
                try await SyncManager.shared.deletePhrase(id: ex.id); d.phrases.removeAll { $0.id == ex.id }
            } else {
                let p = try await SyncManager.shared.savePhrase(e, sentenceId: sid, articleId: d.id, articleTitle: d.title, sentenceText: d.sentences.first { $0.id == sid }?.text)
                d.phrases.append(p)
            }
            data = d
        } catch { err = error.localizedDescription }
    }

    func setSource(_ url: String) async {
        guard Connectivity.shared.isOnline else { err = onlineOnlyMessage; return }
        do { try await API.shared.setSource(id, url); data?.source = url } catch { err = error.localizedDescription }
    }

    func ask(_ sid: String, start: Int, end: Int, span: String) async throws {
        guard Connectivity.shared.isOnline else { throw APIError.server(onlineOnlyMessage) }
        let r = try await API.shared.ask(sid, startWord: start, endWord: end, span: span)
        data?.highlights.append(r.highlight); Cache.shared.upsertHighlight(r.highlight)
        if let p = r.phrase, !(data?.phrases.contains { $0.id == p.id } ?? true) { data?.phrases.append(p); Cache.shared.upsertPhrase(p) }
    }
    func deleteHighlight(_ h: Highlight) async {
        guard Connectivity.shared.isOnline else { err = onlineOnlyMessage; return }
        do { try await API.shared.deleteHighlight(h.id); data?.highlights.removeAll { $0.id == h.id }; Cache.shared.removeHighlight(id: h.id) }
        catch { err = error.localizedDescription }
    }

    func toggleBookmark(_ sid: String) async {
        guard Connectivity.shared.isOnline else { err = onlineOnlyMessage; return }
        do {
            if bookmark?.sentenceId == sid { try await API.shared.clearBookmark(); bookmark = nil; Cache.shared.setBookmark(nil) }
            else {
                try await API.shared.setBookmark(articleId: id, sentenceId: sid, round: nil)
                let s = data?.sentences.first { $0.id == sid }
                bookmark = Bookmark(articleId: id, sentenceId: sid, round: nil, createdAt: Date().ms, articleTitle: data?.title, sentenceIdx: s?.idx, sentenceText: s?.text)
                Cache.shared.setBookmark(bookmark)
            }
        } catch { err = error.localizedDescription }
    }
}

struct DoneView: View {
    var articleId: String
    var newReview: Bool = false
    @EnvironmentObject var router: Router
    @StateObject private var m: DoneModel

    init(articleId: String, newReview: Bool = false) {
        self.articleId = articleId; self.newReview = newReview
        _m = StateObject(wrappedValue: DoneModel(id: articleId, newReview: newReview))
    }

    var body: some View {
        ZStack {
            Theme.desk.ignoresSafeArea()
            if let d = m.data { content(d) }
            else if let e = m.err { ErrorText(message: e).padding() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.desk, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .principal) { Text(m.data?.title ?? "").font(Theme.hand(22)).lineLimit(1) } }
        .task { await m.load() }
    }

    private func content(_ d: ArticleDetail) -> some View {
        var counts: [Grade: Int] = [:]
        for s in d.sentences { if let g = s.attempt?.grade { counts[g, default: 0] += 1 } }
        let review = d.sentences.filter { $0.attempt != nil && ($0.attempt!.grade == .C || $0.attempt!.grade == .D) }
        let remaining = d.sentences.filter { $0.attempt == nil }.count
        let score = ArticleDetail.score(of: d.sentences)
        let latest = d.reviews.first
        let older = Array(d.reviews.dropFirst())

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NotebookHead(tab: "마지막 장") {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(d.title).lineLimit(2)
                        SourceLink(source: d.source ?? "") { await m.setSource($0) }
                    }
                }
                Paper {
                    Entry {
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            if let score {
                                Text("\(score)점")
                                    .font(Theme.hand(56)).foregroundStyle(Theme.red)
                                    .padding(.horizontal, 14).padding(.vertical, 2)
                                    .overlay(Ellipse().strokeBorder(Theme.red, lineWidth: 3))
                                    .rotationEffect(.degrees(-6))
                            } else {
                                Text("채점된 문장 없음").font(Theme.hand(22)).foregroundStyle(Theme.pencil)
                            }
                            FlowLayout(spacing: 14) {
                                ForEach(Grade.allCases, id: \.self) { g in
                                    if let n = counts[g], n > 0 {
                                        HStack(spacing: 4) { Stamp(kind: .grade(g), small: true); Text("×\(n)").font(Theme.hand(22)).foregroundStyle(Theme.pencil) }
                                    }
                                }
                            }
                        }
                        .frame(minHeight: Theme.lh * 2)
                        if remaining > 0 {
                            Tiny(title: "남은 \(remaining)문장 이어서 →\u{FE0E}") { router.shelfPath = [.notebook(id: d.id)] }.frame(height: Theme.lh)
                        }
                    }

                    BlankLine()
                    Entry {
                        Text("총평").font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
                        if let latest { reviewBlock(latest) }
                        else if m.reviewing { Text("선생님이 총평 쓰는 중… ✎\u{FE0E}").pencil() }
                        else { Text(remaining > 0 ? "다 끝나면 총평이 나온다" : "총평 없음").pencil() }
                        if let e = m.reviewErr {
                            HStack(spacing: 10) {
                                Text(e).redpen()
                                Tiny(title: "다시 시도") { Task { await m.requestReview() } }
                            }
                        }
                        FlowLayout(spacing: 14) {
                            if latest != nil, !m.reviewing, remaining == 0 {
                                Tiny(title: "총평 다시 받기 ↻\u{FE0E}") { Task { await m.requestReview() } }
                            }
                            if remaining == 0, !m.reviewing {
                                if let p = m.progress {
                                    Tiny(title: "처음부터 다시 쓰기 이어서 (\(p.done.count) / \(p.ids.count)) →\u{FE0E}", color: Theme.red) { router.shelfPath = [.notebook(id: d.id)] }
                                } else {
                                    Tiny(title: "처음부터 다시 쓰기 ↻\u{FE0E}") { router.shelfPath = [.notebook(id: d.id, restartAfter: 0)] }
                                    if let n = m.estimated {
                                        Tiny(title: "오늘 다시 쓴 \(n)문장 다음부터 이어서 →\u{FE0E}") { router.shelfPath = [.notebook(id: d.id, restartAfter: n)] }
                                    }
                                }
                            }
                            if m.reviewing, latest != nil { Text("다시 쓰는 중… ✎\u{FE0E}").font(Theme.hand(22)).foregroundStyle(Theme.pencil) }
                            if !older.isEmpty {
                                Tiny(title: "이전 총평 \(older.count)개 \(m.showOld ? "접기" : "보기")") { m.showOld.toggle() }
                            }
                        }
                        .frame(minHeight: Theme.lh)
                        if m.showOld {
                            ForEach(older) { r in
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 6) {
                                        Text(Date(ms: r.createdAt).fullLabel).font(Theme.hand(17)).padding(.horizontal, 6).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.pencil))
                                        if let s = r.score { Text("\(s)점").font(Theme.hand(22)) }
                                    }
                                    .foregroundStyle(Theme.pencil).frame(height: Theme.lh)
                                    reviewBlock(r)
                                }
                                .padding(.leading, 12)
                                .overlay(alignment: .leading) { Line().rotation(.degrees(90)).stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 4])).foregroundStyle(Theme.pencil).frame(width: 2) }
                                .opacity(0.7)
                            }
                        }
                    }

                    if !review.isEmpty {
                        BlankLine()
                        Entry { Text("다시 볼 문장").font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh)) }
                        ForEach(review) { s in
                            EntryView(
                                s: s, expanded: m.open == s.id,
                                onToggle: { m.open = m.open == s.id ? nil : s.id },
                                showRef: m.refOpen[s.id] ?? true,
                                onToggleRef: { m.refOpen[s.id] = !(m.refOpen[s.id] ?? true) },
                                savedPhrases: d.phrases.filter { $0.sentenceId == s.id },
                                onTogglePhrase: { e in Task { await m.togglePhrase(s.id, e) } },
                                bookmarked: m.bookmark?.sentenceId == s.id,
                                onBookmark: { Task { await m.toggleBookmark(s.id) } },
                                highlights: d.highlights.filter { $0.sentenceId == s.id },
                                onAsk: { st, en, sp in try await m.ask(s.id, start: st, end: en, span: sp) },
                                onDeleteHighlight: { h in await m.deleteHighlight(h) }
                            )
                        }
                    }

                    BlankLine()
                    Entry {
                        Text("붙여 둔 표현" + (d.phrases.isEmpty ? "" : " (\(d.phrases.count))")).font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
                        if d.phrases.isEmpty {
                            Text("없음").handLine(size: 21, color: Theme.pencil)
                        } else {
                            FlowLayout(spacing: 14) {
                                ForEach(Array(d.phrases.enumerated()), id: \.element.id) { i, p in
                                    Sticky(phrase: p.phrase, meaning: p.meaning, index: i)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    HStack(spacing: 18) {
                        Tiny(title: "←\u{FE0E} 공책 목록") { router.shelfPath = [] }
                        Tiny(title: "공책 전체 열람 →\u{FE0E}") { router.shelfPath.append(.notebook(id: d.id, browse: true)) }
                        if let e = m.err { ErrorText(message: e) }
                    }
                    .frame(minHeight: Theme.lh).padding(.top, Theme.lh)
                    .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 40, trailing: 10))
                .readableWidth()
        }
    }

    @ViewBuilder
    private func reviewBlock(_ r: Review) -> some View {
        Text(r.summary).redpen(size: 24)
        ForEach(Array(r.patterns.enumerated()), id: \.offset) { _, p in
            (Text(p.title).underline(true, color: Theme.red) + Text("  ") + Text(p.detail)).redpen()
        }
        if !r.praise.isEmpty { Text(r.praise).handLine(size: 22, color: Theme.grade(.A)) }
    }
}
