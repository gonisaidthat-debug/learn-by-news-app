import SwiftUI

/// 표현장: 포스트잇 벽 (웹 Phrases.tsx)
struct PhrasesView: View {
    @State private var q = ""
    @State private var list: [Phrase] = []
    @State private var flipped: String?
    @State private var err: String?
    @State private var searchTask: Task<Void, Never>?

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
                    if list.isEmpty {
                        MutedText(text: q.isEmpty ? "아직 붙인 표현이 없다. 첨삭에서 포스트잇을 누르면 여기 붙는다." : "없음")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], alignment: .leading, spacing: 22) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                                wallSticky(p, i)
                            }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 10)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 40, trailing: 10))
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.desk.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: q) { _, _ in
                searchTask?.cancel()
                searchTask = Task { try? await Task.sleep(for: .milliseconds(150)); if !Task.isCancelled { await load() } }
            }
        }
    }

    private func wallSticky(_ p: Phrase, _ i: Int) -> some View {
        let back = flipped == p.id
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
            .padding(EdgeInsets(top: 18, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(back ? Theme.stickyBack : Theme.stickyColors[i % 3])
            .overlay(alignment: .top) { Pin().offset(y: -6) }
            .overlay(alignment: .topTrailing) {
                Button { Task { await remove(p) } } label: { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(8) }
                    .buttonStyle(.plain)
            }
            .shadow(color: .black.opacity(0.15), radius: 2, x: 1, y: 2)
            .rotationEffect(.degrees(Double((i * 7) % 5) - 2))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        do { list = try await API.shared.phrases(q: q); err = nil } catch { err = error.localizedDescription }
    }
    private func remove(_ p: Phrase) async {
        do { try await API.shared.deletePhrase(p.id); list.removeAll { $0.id == p.id }; AppLog.shared.info("phrases", "removed", ["id": p.id]) }
        catch { err = error.localizedDescription }
    }
}
