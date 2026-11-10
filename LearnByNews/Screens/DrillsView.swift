import SwiftUI

/// 응용: 표현장의 표현을 거꾸로 쓰는 한→영 연습 (웹 Drills). 출제·채점은 Claude.
/// 온라인: 즉시 출제·채점, 다음 문제는 쓰는 동안 미리 받아 둔다. 오프라인: 미리 받아 둔 문제를 내고 답은 큐에("채점 대기").
@MainActor
final class DrillsModel: ObservableObject {
    @Published var current: Drill?
    @Published var loading = false        // 문제 내는 중
    @Published var grading = false        // 채점 중
    @Published var answer = ""
    @Published var err: String?
    @Published var recent: [Drill] = []
    /// 이번 세트에서 푼 문제 (채점 대기 포함)
    @Published var setDone: [Drill] = []
    @Published var setFinished = false
    @Published var pendingCurrent = false  // 지금 문제의 답이 큐에 있다(채점 대기)
    private var prefetched: Drill?
    private var observers: [NSObjectProtocol] = []
    let store = DrillStore.shared

    var setSize: Int { store.setSize }
    var position: Int { min(setDone.count + (current != nil ? 1 : 0), setSize) }

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: .lbnDrillGraded, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in
                guard let self, let d = n.userInfo?["drill"] as? Drill else { return }
                if self.current?.id == d.id { self.current = d; self.pendingCurrent = false }
                if let i = self.setDone.firstIndex(where: { $0.id == d.id }) { self.setDone[i] = d }
                if !self.recent.contains(where: { $0.id == d.id }) { self.recent.insert(d, at: 0) }
            }
        })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func start() async {
        if current == nil, !setFinished { await next() }
        await loadRecent()
    }

    /// 다음 문제. 온라인이면 미리 받아 둔 것 → 서버, 오프라인이면 로컬 pool
    func next(phraseId: String? = nil) async {
        guard !loading else { return }
        if setDone.count >= setSize { setFinished = true; current = nil; return }
        loading = true; err = nil; answer = ""; pendingCurrent = false
        defer { loading = false }
        if Connectivity.shared.isOnline {
            if phraseId == nil, let p = prefetched { current = p; prefetched = nil; prefetchIfNeeded(); return }
            do {
                current = try await API.shared.nextDrill(phraseId: phraseId)
                AppLog.shared.info("drills", "next", ["id": current?.id ?? ""])
                prefetchIfNeeded()
            } catch let e as APIError where e.isNetwork { nextOffline() }
            catch { err = error.localizedDescription }
        } else { nextOffline() }
    }
    private func nextOffline() {
        if let d = store.nextOffline() { current = d; AppLog.shared.info("drills", "next (offline pool)", ["id": d.id]) }
        else { current = nil; err = store.pool.isEmpty ? "\(onlineOnlyMessage) · 미리 받아 둔 문제가 없다" : "미리 받아 둔 문제를 다 풀었다 · 연결되면 채점된다" }
    }
    /// 마지막 문장이 아니면 다음 문제를 미리 받아 둔다 (batch 2 → 지금 것 말고 하나)
    private func prefetchIfNeeded() {
        guard setDone.count + 1 < setSize, prefetched == nil, Connectivity.shared.isOnline, let cur = current else { return }
        Task {
            if let r = try? await API.shared.batchDrills(count: 2), let n = r.drills.first(where: { $0.id != cur.id && $0.feedback == nil }) { prefetched = n }
        }
    }

    func submit() async {
        guard let d = current, d.feedback == nil, !grading, !pendingCurrent else { return }
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        if !Connectivity.shared.isOnline { answerOffline(d, a); return }
        grading = true; err = nil
        do {
            let r = try await API.shared.answerDrill(d.id, answer: a)
            current = r; setDone.append(r)
            recent.insert(r, at: 0); if recent.count > 20 { recent.removeLast(recent.count - 20) }
            store.remove(d.id)
            AppLog.shared.info("drills", "answered", ["id": d.id, "grade": r.grade?.rawValue ?? ""])
        } catch let e as APIError where e.isNetwork { answerOffline(d, a) }
        catch { err = error.localizedDescription }
        grading = false
    }
    private func answerOffline(_ d: Drill, _ a: String) {
        store.answerOffline(d, answer: a)
        var p = d; p.answer = a
        current = p; pendingCurrent = true; setDone.append(p)
        AppLog.shared.info("drills", "answered offline (queued)", ["id": d.id])
    }

    /// 안 푼 문제 건너뛰기: 지우고 다음 (오프라인이면 pool에서만 뺀다)
    func skip() async {
        guard let d = current, d.feedback == nil, !pendingCurrent else { await next(); return }
        if Connectivity.shared.isOnline { do { try await API.shared.deleteDrill(d.id) } catch { err = error.localizedDescription; return } }
        store.remove(d.id)
        current = nil
        await next()
    }

    func newSet() async { setDone = []; setFinished = false; current = nil; await next() }
    func changeSet(_ n: Int) async { store.setSize = n; if setDone.count >= n { setFinished = true; current = nil } else if setFinished { setFinished = false; await next() } }

    func loadRecent() async {
        do { recent = Array(try await API.shared.drills(days: 30).prefix(20)) } catch { /* 목록은 조용히 */ }
    }

    /// 미리 받기 (설정과 공유)
    @Published var prefetchMsg: String?
    func prefetch() async {
        guard Connectivity.shared.isOnline else { prefetchMsg = onlineOnlyMessage; return }
        do { let n = try await store.prefetch(count: setSize); prefetchMsg = "\(n)문장 받아 둠" }
        catch { prefetchMsg = error.localizedDescription }
    }
}

struct DrillsView: View {
    @StateObject private var m = DrillsModel()
    @ObservedObject private var store = DrillStore.shared
    @ObservedObject private var net = Connectivity.shared
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookHead(tab: "\(m.position) / \(m.setSize)") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("응용")
                            HStack(spacing: 10) {
                                ForEach([5, 10, 20], id: \.self) { n in
                                    Tiny(title: "\(n)문장", color: m.setSize == n ? Theme.ink : Theme.pencil, size: 19) { Task { await m.changeSet(n) } }
                                        .overlay(alignment: .bottom) { if m.setSize == n { Rectangle().fill(Theme.red).frame(height: 2) } }
                                }
                                Tiny(title: "미리 받기", size: 17) { Task { await m.prefetch() } }
                                if store.remainingOffline > 0 { MutedText(text: "받아 둔 \(store.remainingOffline)") }
                                if let msg = m.prefetchMsg { MutedText(text: msg) }
                            }
                        }
                    }
                    if !store.graded.isEmpty { gradedSummary.padding(.bottom, 10) }
                    Paper { paper }
                    if !m.recent.isEmpty { recentList.padding(.top, 28) }
                }
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 40, trailing: 10))
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.desk.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { await m.start(); focused = true }
            .refreshable { await m.loadRecent() }
        }
    }

    /// 연결 뒤 돌아온 채점 요약 (한 번 보여주고 닫는다)
    private var gradedSummary: some View {
        let ds = store.graded
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            (Text("\(ds.count)문장 채점 완료").fontWeight(.bold) + Text(DrillSummary.score(ds).map { " · \($0)점" } ?? "") + Text(" · 표현 사용 \(DrillSummary.used(ds))/\(ds.count)"))
                .font(Theme.hand(21)).foregroundStyle(Theme.ink)
            gradeCounts(DrillSummary.counts(ds))
            Spacer(minLength: 0)
            Button { store.clearGraded() } label: { Text("×").font(.system(size: 18)).foregroundStyle(Theme.pencil).padding(.horizontal, 6) }.buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 8))
        .background(Theme.tab.opacity(0.55))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.red).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func gradeCounts(_ c: [Grade: Int]) -> some View {
        HStack(spacing: 8) {
            ForEach(Grade.allCases, id: \.self) { g in
                if let n = c[g], n > 0 { HStack(spacing: 2) { Stamp(kind: .grade(g), small: true); Text("×\(n)").font(Theme.hand(18)).foregroundStyle(Theme.pencil) } }
            }
        }
    }

    @ViewBuilder
    private var paper: some View {
        if m.setFinished {
            let ds = m.setDone
            Entry {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    if let sc = DrillSummary.score(ds) {
                        Text("\(sc)점").font(Theme.hand(56)).foregroundStyle(Theme.red)
                            .padding(.horizontal, 14).padding(.vertical, 2)
                            .overlay(Ellipse().strokeBorder(Theme.red, lineWidth: 3)).rotationEffect(.degrees(-6))
                    } else {
                        Text("채점 대기 중").font(Theme.hand(26)).foregroundStyle(Theme.pencil)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        gradeCounts(DrillSummary.counts(ds))
                        Text("표현 사용 \(DrillSummary.used(ds))/\(ds.count)" + (ds.contains { $0.feedback == nil } ? " · 채점 대기 \(ds.filter { $0.feedback == nil }.count)" : "")).font(Theme.hand(20)).foregroundStyle(Theme.pencil)
                    }
                }
                .frame(minHeight: Theme.lh * 2)
                Tiny(title: "한 세트 더 ↻\u{FE0E}", color: Theme.red) { Task { await m.newSet(); focused = true } }.frame(height: Theme.lh).padding(.top, 8)
            }
        } else if m.loading {
            Entry { Text("문제 내는 중… ✎\u{FE0E}").pencil() }
        } else if let d = m.current {
            let fb = d.feedback
            Entry(stamp: fb.map { AnyView(Stamp(kind: .grade($0.grade))) } ?? (m.pendingCurrent ? AnyView(Stamp(kind: .waiting)) : nil)) {
                Sticky(phrase: d.phrase, meaning: d.meaning, index: 0).padding(.vertical, 10)
                Text(d.korean).handLine(size: 25, color: Theme.ink)
                if m.pendingCurrent {
                    Text(d.answer ?? "").koLine()
                    Text("연결되면 채점 · 큐에 저장됨").pencil(size: 20)
                } else if fb == nil {
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
                    if fb == nil && !m.pendingCurrent {
                        Tiny(title: "건너뛰기") { Task { await m.skip(); focused = true } }
                        MutedText(text: net.isOnline ? "Enter 제출" : "오프라인 · Enter로 저장, 연결되면 채점")
                    } else {
                        Tiny(title: "다음 문장 ↵\u{FE0E}", color: Theme.red) { Task { await m.next(); focused = true } }
                        if net.isOnline { Tiny(title: "같은 표현 한 번 더") { Task { await m.next(phraseId: d.phraseId); focused = true } } }
                    }
                }
                if let e = m.err {
                    HStack(spacing: 10) { ErrorText(message: e); if m.current?.feedback == nil, !m.pendingCurrent { Tiny(title: "다시 시도") { Task { await m.submit() } } } }
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
                        if let g = d.grade { Stamp(kind: .grade(g), small: true) } else { Stamp(kind: .waiting, small: true) }
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
