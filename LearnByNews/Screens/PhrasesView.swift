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

    private var mastered: [Phrase] { list.filter(\.isMastered) }
    private var shown: [Phrase] { showMastered ? list : list.filter { !$0.isMastered } }

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
                    if !mastered.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(list.count - mastered.count)개 · 습득 완료 \(mastered.count)개").font(Theme.hand(19)).foregroundStyle(Theme.pencil)
                            Tiny(title: showMastered ? "습득 완료 숨기기" : "습득 완료도 보기", size: 19) { withAnimation(.easeInOut(duration: 0.15)) { showMastered.toggle() } }
                        }
                        .padding(.top, -8)
                    }
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
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.environment["LBN_SHOWMASTERED"] == "1" { showMastered = true }   // 화면 확인용
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
                    Spacer(minLength: 4)
                    Text(p.articleTitle ?? "").font(Theme.hand(15)).foregroundStyle(Theme.pencil)
                } else {
                    Text(p.phrase).font(Theme.hand(24)).fontWeight(.bold).foregroundStyle(Color(hex: 0x2A2412))
                    Text(p.meaning).font(Theme.hand(18)).foregroundStyle(Color(hex: 0x5B5440))
                    Spacer(minLength: 0)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(EdgeInsets(top: 18, leading: 16, bottom: 34, trailing: 16))   // 아래쪽은 "습득 완료 ✓" 버튼 자리
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(back ? Theme.stickyBack : Theme.stickyColors[i % 3])
            .opacity(done ? 0.62 : 1)
            .overlay(alignment: .top) { Pin().offset(y: -6) }
            .overlay(alignment: .topTrailing) {
                Button { Task { await remove(p) } } label: { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(8) }
                    .buttonStyle(.plain)
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
        if let c = Cache.shared.phrases(q: q) { list = c }
        do { list = try await API.shared.phrases(q: q); err = nil }
        catch let e as APIError where e.isNetwork { err = Cache.shared.isEmpty ? e.localizedDescription : nil }
        catch { err = error.localizedDescription }
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
