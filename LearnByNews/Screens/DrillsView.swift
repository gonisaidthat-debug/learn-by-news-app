import SwiftUI

/// 응용: 표현장의 표현을 거꾸로 쓰는 한→영 연습 (웹 Drills). 출제·채점 모두 Claude라 온라인 전용
@MainActor
final class DrillsModel: ObservableObject {
    @Published var current: Drill?
    @Published var loading = false        // 문제 내는 중
    @Published var grading = false        // 채점 중
    @Published var answer = ""
    @Published var err: String?
    @Published var recent: [Drill] = []

    func next(phraseId: String? = nil) async {
        guard Connectivity.shared.isOnline else { err = onlineOnlyMessage; return }
        guard !loading else { return }
        loading = true; err = nil; answer = ""
        do { current = try await API.shared.nextDrill(phraseId: phraseId); AppLog.shared.info("drills", "next", ["id": current?.id ?? ""]) }
        catch { err = error.localizedDescription }
        loading = false
    }

    func submit() async {
        guard let d = current, d.feedback == nil, !grading else { return }
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        guard Connectivity.shared.isOnline else { err = onlineOnlyMessage; return }
        grading = true; err = nil
        do {
            let r = try await API.shared.answerDrill(d.id, answer: a)
            current = r
            recent.insert(r, at: 0); if recent.count > 20 { recent.removeLast(recent.count - 20) }
            AppLog.shared.info("drills", "answered", ["id": d.id, "grade": r.grade?.rawValue ?? ""])
        } catch { err = error.localizedDescription }
        grading = false
    }

    /// 안 푼 문제 건너뛰기: 지우고 다음
    func skip() async {
        guard let d = current, d.feedback == nil else { await next(); return }
        guard Connectivity.shared.isOnline else { err = onlineOnlyMessage; return }
        do { try await API.shared.deleteDrill(d.id) } catch { err = error.localizedDescription; return }
        current = nil
        await next()
    }

    func loadRecent() async {
        do { recent = Array(try await API.shared.drills(days: 30).prefix(20)) } catch { /* 목록은 조용히 */ }
    }
}

struct DrillsView: View {
    @StateObject private var m = DrillsModel()
    @ObservedObject private var net = Connectivity.shared
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookHead(tab: "응용") { Text("응용") }
                    Paper { paper }
                    if !m.recent.isEmpty { recentList.padding(.top, 28) }
                }
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 40, trailing: 10))
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.desk.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if m.current == nil { await m.next(); focused = true }
                await m.loadRecent()
            }
            .refreshable { await m.loadRecent() }
        }
    }

    @ViewBuilder
    private var paper: some View {
        if !net.isOnline && m.current == nil {
            Entry { Text(onlineOnlyMessage).redpen(); Text("출제와 채점을 Claude가 하므로 오프라인에서는 쉴 수밖에.").pencil() }
        } else if m.loading {
            Entry { Text("문제 내는 중… ✎\u{FE0E}").pencil() }
        } else if let d = m.current {
            let fb = d.feedback
            Entry(stamp: fb.map { AnyView(Stamp(kind: .grade($0.grade))) }) {
                Sticky(phrase: d.phrase, meaning: d.meaning, index: 0).padding(.vertical, 10)
                Text(d.korean).handLine(size: 25, color: Theme.ink)
                if fb == nil {
                    TextField(m.grading ? "채점 중…" : "영어로 쓴다", text: $m.answer, axis: .vertical)
                        .font(Theme.hand(22)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
                        .modifier(RuledText(uiFont: Theme.handUI(22), lh: Theme.lh))
                        .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                        .focused($focused).disabled(m.grading)
                        .onChange(of: m.answer) { _, v in
                            // 한글 조합 중 Return은 줄바꿈이 안 들어온다 → 줄바꿈이 들어온 뒤에만 제출
                            if v.contains("\n") { m.answer = v.replacingOccurrences(of: "\n", with: " "); Task { await m.submit() } }
                        }
                    if m.grading { Text("선생님이 보는 중… ✎\u{FE0E}").pencil() }
                } else if let fb {
                    Text(d.answer ?? "").koLine()
                    if fb.usedExpression {
                        Text("✓\u{FE0E} \"\(d.phrase)\" 사용").handLine(size: 22, color: Theme.grade(.A))
                    } else {
                        Text("✗\u{FE0E} \"\(d.phrase)\"를 쓰지 않았다").redpen()
                    }
                    ForEach(Array(fb.issues.enumerated()), id: \.offset) { _, i in
                        (Text(i.mine).strikethrough(true, color: Theme.red) + Text(" →\u{FE0E} \(i.better)") + Text(i.why.isEmpty ? "" : " (\(i.why))").font(Theme.hand(19)).foregroundColor(Color(hex: 0xC0565A))).redpen()
                    }
                    if !fb.reference.isEmpty { (Text("참고 ").font(Theme.hand(17)) + Text(fb.reference)).pencil() }
                    if !fb.note.isEmpty { Text(fb.note).pencil() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 18) {
                    if fb == nil {
                        Tiny(title: "건너뛰기") { Task { await m.skip(); focused = true } }
                        MutedText(text: "Enter 제출")
                    } else {
                        Tiny(title: "다음 문장 ↵\u{FE0E}", color: Theme.red) { Task { await m.next(); focused = true } }
                        Tiny(title: "같은 표현 한 번 더") { Task { await m.next(phraseId: d.phraseId); focused = true } }
                    }
                }
                if let e = m.err {
                    HStack(spacing: 10) { ErrorText(message: e); if m.current?.feedback == nil { Tiny(title: "다시 시도") { Task { await m.submit() } } } }
                }
            }
            .frame(minHeight: Theme.lh).padding(.top, Theme.lh)
            .padding(.leading, Theme.paperLeft).padding(.trailing, Theme.paperRight)
        } else {
            Entry {
                if let e = m.err {
                    Text(e).redpen()
                    Tiny(title: "다시 시도") { Task { await m.next() } }.frame(height: Theme.lh)
                } else {
                    Text("표현장에 붙인 표현으로 문제를 낸다.").pencil()
                    Tiny(title: "문제 받기 →\u{FE0E}", color: Theme.red) { Task { await m.next(); focused = true } }.frame(height: Theme.lh)
                }
            }
        }
    }

    /// 최근 응용 20개: 작은 도장 · 표현 · 한국어 · 내 영작
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("최근 응용").font(Theme.hand(24)).foregroundStyle(Theme.pencil)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(m.recent) { d in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let g = d.grade { Stamp(kind: .grade(g), small: true) }
                        Text(d.phrase).font(Theme.hand(19)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                        Text(d.korean).font(Theme.hand(18)).foregroundStyle(Theme.pencil).lineLimit(1)
                        if let a = d.answer, !a.isEmpty { Text(a).font(Theme.hand(18)).foregroundStyle(Theme.blueInk).lineLimit(1) }
                    }
                    .padding(.horizontal, 16).frame(height: 36)
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
    }
}
