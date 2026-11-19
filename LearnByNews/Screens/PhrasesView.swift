import SwiftUI

/// 표현장: 포스트잇 벽 (웹 Phrases.tsx)
struct PhrasesView: View {
    @State private var q = ""
    @State private var list: [Phrase] = []
    @State private var flipped: String?
    @State private var err: String?
    @State private var searchTask: Task<Void, Never>?
    /// 습득 완료는 기본으로 숨긴다 (goni 2026-11-18). 보기로 바꾸면 기기에 기억
    @AppStorage("lbn_phrases_show_mastered") private var showMastered = false
    @State private var showTest = false     // 표현장 시험 (뜻 → 영어 표현)
    @State private var showTape = false     // 표현장 테이프 (읽어 주기)
    @State private var starredOnly = false  // "★ n": 별 붙은 것만

    private var mastered: [Phrase] { list.filter(\.isMastered) }
    /// 벽도 번호(붙인 순서) 큰 것부터. 서버의 created_at 최신순은 같은 채점에서 함께 붙은 표현들의 순서가 임의라서
    private static func byNumber(_ xs: [Phrase]) -> [Phrase] { xs.sorted { ($0.seq ?? 0, $0.createdAt) > ($1.seq ?? 0, $1.createdAt) } }
    private var shown: [Phrase] { (showMastered ? list : list.filter { !$0.isMastered }).filter { !starredOnly || $0.stars > 0 } }
    private var starredCount: Int { list.filter { $0.stars > 0 }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("검색", text: $q)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xD6CFC0)))
                    if let err { ErrorText(message: err) }
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        // 표현장 시험: 뜻을 보고 영어 표현을 떠올려 쓴다 (goni 2026-11-18 "표현장 시험 기능도 만들어줘")
                        if !list.isEmpty || !mastered.isEmpty {
                            Tiny(title: "시험 보기 ✎\u{FE0E}", color: Theme.red, size: 19) { showTest = true }
                            Tiny(title: "테이프 ▶\u{FE0E}", color: Theme.red, size: 19) { showTape = true }
                            if starredCount > 0 || starredOnly {
                                Tiny(title: "★ \(starredCount)", color: starredOnly ? StarRow.yellow : Theme.pencil, size: 19) { withAnimation(.easeInOut(duration: 0.15)) { starredOnly.toggle() } }
                                    .help("별 붙은 표현만 보기")
                            }
                        }
                        if !mastered.isEmpty {
                            Text("\(list.count - mastered.count)개 · 습득 완료 \(mastered.count)개").font(Theme.hand(19)).foregroundStyle(Theme.pencil)
                            Tiny(title: showMastered ? "습득 완료 숨기기" : "습득 완료도 보기", size: 19) { withAnimation(.easeInOut(duration: 0.15)) { showMastered.toggle() } }
                        }
                    }
                    .padding(.top, -8)
                    if shown.isEmpty {
                        MutedText(text: !q.isEmpty ? "없음" : !mastered.isEmpty ? "남은 표현이 없다. 모두 습득 완료." : "아직 붙인 표현이 없다. 첨삭에서 포스트잇을 누르면 여기 붙는다.")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], alignment: .leading, spacing: 22) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                                wallSticky(p, i)
                            }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 10)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 40, trailing: 10))
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.desk.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showTest) { PhraseTestView() }
            .navigationDestination(isPresented: $showTape) { TapeView() }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.environment["LBN_SHOWMASTERED"] == "1" { showMastered = true }   // 화면 확인용
                if ProcessInfo.processInfo.environment["LBN_PHRASETEST"] == "1" { showTest = true }         // 화면 확인용: 표현장 시험으로 바로
                if ProcessInfo.processInfo.environment["LBN_TAPE"] == "1" { showTape = true }               // 화면 확인용: 테이프로 바로
                if let f = ProcessInfo.processInfo.environment["LBN_FLIP"] { flipped = f }   // 화면 확인용: 그 표현의 뒷면
                #endif
                await load()
            }
            .refreshable { await load() }
            .onChange(of: q) { _, _ in
                searchTask?.cancel()
                searchTask = Task { try? await Task.sleep(for: .milliseconds(150)); if !Task.isCancelled { await load() } }
            }
        }
    }

    private func wallSticky(_ p: Phrase, _ i: Int) -> some View {
        let back = flipped == p.id
        let done = p.isMastered
        return Button { withAnimation(.easeInOut(duration: 0.15)) { flipped = back ? nil : p.id } } label: {
            VStack(alignment: .leading, spacing: 4) {
                if back {
                    Text(p.sentenceText ?? "").font(Theme.hand(17)).foregroundStyle(Color(hex: 0x3B3627)).lineSpacing(-2)
                    // 엮은 것 · 다시 본 곳 (읽기만, 2026-11-18)
                    ForEach(p.links ?? []) { l in Text("↗\u{FE0E} \(l.text ?? "") · \(shorten(l.title ?? ""))").font(Theme.hand(15)).foregroundStyle(Theme.blueInk).lineLimit(1) }
                    ForEach(p.backlinks ?? []) { b in Text("←\u{FE0E} \(b.text ?? "") · \(shorten(b.title ?? ""))").font(Theme.hand(15)).foregroundStyle(Theme.pencil).lineLimit(1) }
                    // 습득 완료 기록 최근 4개: 찍음 / 도장 뗌 / 번역에서 틀려 자동 취소 (2026-11-18)
                    ForEach((p.masteryLog ?? []).prefix(4)) { e in
                        Text(Self.logLine(e)).font(Theme.hand(14)).foregroundStyle(e.action == "revoked" ? Theme.red : Theme.pencil).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(p.articleTitle ?? "").font(Theme.hand(15)).foregroundStyle(Theme.pencil)
                } else {
                    Text(p.phrase).font(Theme.hand(24)).fontWeight(.bold).foregroundStyle(Color(hex: 0x2A2412))
                    Text(p.meaning).font(Theme.hand(18)).foregroundStyle(Color(hex: 0x5B5440))
                    Spacer(minLength: 0)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(EdgeInsets(top: 30, leading: 16, bottom: 34, trailing: 16))   // 위쪽은 "#n·★★★·×" 줄, 아래쪽은 "습득 완료 ✓" 버튼 자리
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(back ? Theme.stickyBack : Theme.stickyColors[i % 3])
            .opacity(done ? 0.62 : 1)
            .overlay(alignment: .top) { Pin().offset(y: -6) }
            .overlay(alignment: .topLeading) { if let n = p.seq { Text("#\(n)").font(Theme.hand(14)).foregroundStyle(Theme.pencil).padding(EdgeInsets(top: 5, leading: 8, bottom: 0, trailing: 0)) } }   // 붙인 순서 번호
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    StarRow(stars: p.stars, size: 14) { w in Task { await weight(p, w) } }
                    Button { Task { await remove(p) } } label: { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(8) }
                        .buttonStyle(.plain)
                }
            }
            // 아래 왼쪽: 습득 완료 ✓ / 다시 보기 ↻ (지우지 않고 도장만). 아래 오른쪽: 도장
            .overlay(alignment: .bottomLeading) {
                Tiny(title: done ? "다시 보기 ↻\u{FE0E}" : "습득 완료 ✓\u{FE0E}", size: 16) { Task { await master(p, !done) } }
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 0))
            }
            .overlay(alignment: .bottomTrailing) { if done { MasteredStamp().padding(EdgeInsets(top: 0, leading: 0, bottom: 30, trailing: 10)) } }
            .shadow(color: .black.opacity(0.15), radius: 2, x: 1, y: 2)
            .rotationEffect(.degrees(Double((i * 7) % 5) - 2))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        if let c = Cache.shared.phrases(q: q) { list = Self.byNumber(c) }
        do { list = Self.byNumber(try await API.shared.phrases(q: q)); err = nil }
        catch let e as APIError where e.isNetwork { err = Cache.shared.isEmpty ? e.localizedDescription : nil }
        catch { err = error.localizedDescription }
    }
    static func logLine(_ e: MasteryLogEntry) -> String {
        let d = Date(ms: e.createdAt).monthDay
        switch e.action {
        case "mastered": return "✓\u{FE0E} 습득 완료 · \(d)"
        case "unmastered": return "↻\u{FE0E} 도장 뗌 · \(d)"
        default: return "⟲\u{FE0E} 취소 · \((e.note ?? "").isEmpty ? "" : (e.note! + " · "))\(d)"
        }
    }
    /// 중요도 별 0~3
    private func weight(_ p: Phrase, _ w: Int) async {
        do {
            let saved = try await SyncManager.shared.setWeight(p.id, weight: w)
            if let i = list.firstIndex(where: { $0.id == p.id }) { list[i].weight = saved }
            AppLog.shared.info("phrases", "weight", ["id": p.id, "weight": "\(saved)"])
        } catch { err = error.localizedDescription }
    }
    /// 습득 완료 도장: 지우지 않고 표시만. 기본 보기·응용 출제·시험지에서 빠진다
    private func master(_ p: Phrase, _ on: Bool) async {
        do {
            let at = try await SyncManager.shared.setMastered(p.id, on: on)
            if let i = list.firstIndex(where: { $0.id == p.id }) { withAnimation(.easeInOut(duration: 0.15)) { list[i].masteredAt = at } }
            AppLog.shared.info("phrases", on ? "mastered" : "unmastered", ["id": p.id])
        } catch { err = error.localizedDescription }
    }
    private func remove(_ p: Phrase) async {
        do { try await SyncManager.shared.deletePhrase(id: p.id); list.removeAll { $0.id == p.id }; AppLog.shared.info("phrases", "removed", ["id": p.id]) }
        catch { err = error.localizedDescription }
    }
}
