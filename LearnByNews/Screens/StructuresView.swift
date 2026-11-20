import SwiftUI

/// 구조 분석 모아보기 (goni 2026-11-20 "구조 분석 탭 하나 만들어서 분석한 것만 모아 보기", 웹 /structures와 같음).
/// 탭 바가 5개라 기록 탭의 세그먼트 "구조"로 둔다. `GET /api/structures`(최근 분석 순) → 줄 = 도장 · 원문 · "뼈대: …" · 출처 · "m/d 분석 · 문답 n" · "공책에서 보기 →" · 펼치기.
/// 펼치면 저장본을 `POST /api/sentences/:id/structure`로 받아 공책과 같은 상자(문답·다시 분석·×). 오프라인: 마지막으로 받은 목록(UserDefaults)과 기기 저장본
struct StructureItem: Codable, Identifiable {
    var sentenceId: String; var text: String; var idx: Int; var articleId: String; var title: String
    var createdAt: Int64; var qaCount: Int; var grade: Grade?; var skeleton: String
    var id: String { sentenceId }
}

@MainActor
final class StructuresModel: ObservableObject {
    private static let key = "lbn_structure_list"
    @Published var list: [StructureItem]?
    @Published var err: String?
    @Published var q = ""
    @AppStorage("lbn_structures_by_article") var byArticle = false
    @Published var open: String?
    @Published var full: [String: Structure] = [:]
    @Published var busy: String?

    func load() async {
        if list == nil, let d = UserDefaults.standard.data(forKey: Self.key), let c = try? JSONDecoder.api.decode([StructureItem].self, from: d) { list = c }
        guard Connectivity.shared.isOnline else { return }
        do {
            list = try await API.shared.structures(); err = nil
            UserDefaults.standard.set(try? JSONEncoder.api.encode(list), forKey: Self.key)
        } catch { err = error.localizedDescription }
    }
    /// 검색(문장·뼈대·기사) + 기사별이면 제목 → 문장 순서
    var items: [StructureItem] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        let xs = (list ?? []).filter { t.isEmpty || $0.text.lowercased().contains(t) || $0.skeleton.lowercased().contains(t) || $0.title.lowercased().contains(t) }
        return byArticle ? xs.sorted { $0.title == $1.title ? $0.idx < $1.idx : $0.title < $1.title } : xs
    }
    /// 펼치기/접기. 처음 펼칠 때(또는 다시 분석) 저장본을 받는다 — 서버 저장본이라 Claude 없이 즉시
    func toggle(_ it: StructureItem, force: Bool = false) async {
        if open == it.sentenceId, !force { open = nil; return }
        open = it.sentenceId
        if full[it.sentenceId] != nil, !force { return }
        busy = it.sentenceId
        do {
            let st = try await SyncManager.shared.structure(sentenceId: it.sentenceId, force: force)
            full[it.sentenceId] = st
            if force, let i = list?.firstIndex(where: { $0.sentenceId == it.sentenceId }) { list?[i].skeleton = st.skeleton; list?[i].createdAt = st.createdAt ?? list![i].createdAt }
            err = nil
        } catch { err = error.localizedDescription }
        busy = nil
    }
    func ask(_ sid: String, _ q: String) async throws {
        let r = try await SyncManager.shared.askSentence(sentenceId: sid, question: q)
        full[sid]?.qa = (full[sid]?.qa ?? []) + [r]
        if let i = list?.firstIndex(where: { $0.sentenceId == sid }) { list?[i].qaCount += 1 }
    }
    func setMarks(_ sid: String, _ qid: String, _ marks: [String]) async throws {
        let r = try await SyncManager.shared.setQAMarks(sentenceId: sid, qid: qid, marks: marks)
        if let i = full[sid]?.qa?.firstIndex(where: { $0.id == qid }) { full[sid]?.qa?[i].marks = r }
    }
    func deleteQA(_ sid: String, _ qid: String) async throws {
        try await SyncManager.shared.deleteSentenceQA(sentenceId: sid, qid: qid)
        full[sid]?.qa = (full[sid]?.qa ?? []).filter { $0.id != qid }
        if let i = list?.firstIndex(where: { $0.sentenceId == sid }) { list?[i].qaCount = max(0, list![i].qaCount - 1) }
    }
}

/// 기록 탭 "구조" 세그먼트의 본문 (Paper 안)
struct StructuresSection: View {
    @ObservedObject var m: StructuresModel
    @EnvironmentObject var router: Router
    var body: some View {
        let items = m.items
        Entry {
            TextField("문장·뼈대·기사로 찾기", text: $m.q)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xD6CFC0)))
                .padding(.vertical, 6)
        }
        .task(id: m.list?.count ?? 0) {
            #if DEBUG
            // 화면 확인용: LBN_AUTOEXPAND=<문장 id> 이면 목록이 오자마자 그 줄을 펼친다
            if let sid = ProcessInfo.processInfo.environment["LBN_AUTOEXPAND"], let it = m.list?.first(where: { $0.sentenceId == sid }), m.open == nil { await m.toggle(it) }
            #endif
        }
        if let err = m.err { Entry { ErrorText(message: err) } }
        if m.list == nil { Entry { Text("…").pencil() } }
        else if items.isEmpty {
            Entry { Text(m.q.isEmpty ? "아직 분석한 문장이 없다. 공책의 채점된 문장에서 \"구조 분석 ✦\"을 누르면 여기 모인다." : "없다.").pencil(size: 20) }
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                if m.byArticle, i == 0 || items[i - 1].title != it.title {
                    if i > 0 { BlankLine() }
                    Entry {
                        Button { router.open(.notebook(id: it.articleId, focus: it.sentenceId, browse: true)) } label: {
                            Text(it.title).font(Theme.print(16)).italic().foregroundStyle(Theme.pencil).modifier(RuledText(uiFont: Theme.printUI(16), lh: Theme.lh))
                        }.buttonStyle(.plain)
                    }
                }
                row(it)
            }
        }
    }

    @ViewBuilder
    private func row(_ it: StructureItem) -> some View {
        let isOpen = m.open == it.sentenceId
        Entry(stamp: it.grade.map { AnyView(Stamp(kind: .grade($0))) }, highlight: isOpen) {
            Button { Task { await m.toggle(it) } } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(it.text).enLine()
                    (Text("뼈대 ").font(Theme.hand(17)).foregroundColor(Theme.pencil) + Text(it.skeleton).font(Theme.hand(19)).foregroundColor(Theme.pencil))
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            FlowLayout(spacing: 12, rowSpacing: 0) {
                if !m.byArticle { Text("\(it.title) · \(it.idx + 1)번째").font(Theme.hand(17)).foregroundStyle(Theme.pencil).lineLimit(1).frame(height: Theme.lh) }
                Text("\(Date(ms: it.createdAt).monthDay) 분석" + (it.qaCount > 0 ? " · 문답 \(it.qaCount)" : "")).font(Theme.hand(17)).foregroundStyle(Theme.pencil).frame(height: Theme.lh)
                Tiny(title: "공책에서 보기 →\u{FE0E}", size: 18) { router.open(.notebook(id: it.articleId, focus: it.sentenceId, browse: true)) }.frame(height: Theme.lh)
                Tiny(title: m.busy == it.sentenceId ? "여는 중…" : isOpen ? "접기" : "펼치기", size: 18) { Task { await m.toggle(it) } }.frame(height: Theme.lh)
            }
            if isOpen, let st = m.full[it.sentenceId] {
                StructureView(st: st, busy: m.busy == it.sentenceId, onAgain: { Task { await m.toggle(it, force: true) } }, onClose: { m.open = nil },
                              onAsk: { q in try await m.ask(it.sentenceId, q) }, onDeleteQA: { qid in try await m.deleteQA(it.sentenceId, qid) },
                              onMarks: { qid, ms in try await m.setMarks(it.sentenceId, qid, ms) })
                    .padding(.vertical, 4)
            }
        }
    }
}
