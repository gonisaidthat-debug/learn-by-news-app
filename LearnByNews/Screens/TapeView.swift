import SwiftUI

/// 표현장 테이프 화면 (웹 /phrases/tape): 목록(지금 읽는 줄 빨갛게) + ⏮ ▶/⏸ ⏭ + 묶음·순서·속도·사이·반복·원문 설정. 재생은 TapePlayer.shared(화면을 떠나도 계속)
struct TapeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var t = TapePlayer.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookHead(tab: t.items.isEmpty ? "0" : "\(t.index + 1) / \(t.items.count)") {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("표현장 테이프")
                                Tiny(title: "←\u{FE0E} 표현장", size: 17) { dismiss() }
                            }
                            HStack(spacing: 10) {
                                ForEach(TapePlayer.Bucket.allCases, id: \.self) { b in
                                    let label = b == .pending ? "아직 \(t.pendingCount)" : b == .mastered ? "습득 완료 \(t.masteredCount)" : "전체"
                                    Tiny(title: label, color: t.bucket == b ? Theme.ink : Theme.pencil, size: 19) { t.set(bucket: b) }
                                        .overlay(alignment: .bottom) { if t.bucket == b { Rectangle().fill(Theme.red).frame(height: 2) } }
                                }
                            }
                        }
                    }
                    RangePick(range: Binding(get: { t.range }, set: { t.set(range: $0) }), max: t.maxSeq).padding(.horizontal, 4).padding(.bottom, 8)
                    controls.padding(.bottom, 10)
                    settings.padding(.bottom, 14)
                    if let e = t.err { ErrorText(message: e).padding(.bottom, 8) }
                    list
                }
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 40, trailing: 10))
                .readableWidth()
            }
            .onChange(of: t.index) { _, i in withAnimation { proxy.scrollTo("tape-\(i)", anchor: .center) } }
        }
        .background(Theme.desk.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if t.items.isEmpty { await t.load() }
            #if DEBUG
            if let r = ProcessInfo.processInfo.environment["LBN_RANGE"] { let p = r.split(separator: "-").compactMap { Int($0) }; if p.count == 2 { t.set(range: p[0]...p[1]) } }
            if ProcessInfo.processInfo.environment["LBN_TAPEPLAY"] == "1" { t.play() }   // 화면 확인용
            #endif
        }
    }

    /// ⏮ ▶/⏸ ⏭ + 지금 읽는 표현
    private var controls: some View {
        HStack(spacing: 22) {
            Button { t.prev() } label: { Text("⏮\u{FE0E}").font(.system(size: 22)).foregroundStyle(Theme.ink) }.buttonStyle(.plain).disabled(t.items.isEmpty)
            Button { t.toggle() } label: {
                Text(t.playing ? "⏸\u{FE0E}" : "▶\u{FE0E}").font(.system(size: 26)).foregroundStyle(Theme.paper)
                    .frame(width: 52, height: 52).background(Circle().fill(Theme.red))
            }.buttonStyle(.plain).disabled(t.items.isEmpty)
            Button { t.next() } label: { Text("⏭\u{FE0E}").font(.system(size: 22)).foregroundStyle(Theme.ink) }.buttonStyle(.plain).disabled(t.items.isEmpty)
            VStack(alignment: .leading, spacing: 0) {
                if let p = t.current {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(p.phrase).font(Theme.hand(22)).fontWeight(.bold).foregroundStyle(t.playing ? Theme.red : Theme.ink).lineLimit(1)
                        if let n = p.seq { Text("#\(n)").font(Theme.hand(15)).foregroundStyle(Theme.pencil) }
                    }
                    Text(p.meaning).font(Theme.hand(18)).foregroundStyle(Theme.pencil).lineLimit(1)
                } else { MutedText(text: t.range != nil ? "이 번호 범위에 들을 표현이 없다" : "읽을 표현이 없다") }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// 순서 · 속도 · 사이 · 반복 · 원문
    private var settings: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 14) {
                MutedText(text: "순서")
                Tiny(title: "섞음", color: t.order == .shuffle ? Theme.ink : Theme.pencil, size: 18) { t.set(order: .shuffle) }
                Tiny(title: "최근 순", color: t.order == .recent ? Theme.ink : Theme.pencil, size: 18) { t.set(order: .recent) }
                MutedText(text: "· 속도")
                ForEach([0.8, 1.0, 1.25], id: \.self) { r in Tiny(title: "\(r == 1.0 ? "1" : String(r))×", color: t.rate == r ? Theme.ink : Theme.pencil, size: 18) { t.rate = r } }
            }
            FlowLayout(spacing: 14) {
                MutedText(text: "사이")
                ForEach([0.6, 1.5, 3.0], id: \.self) { g in Tiny(title: "\(g == 3.0 ? "3" : String(g))초", color: t.gap == g ? Theme.ink : Theme.pencil, size: 18) { t.gap = g } }
                MutedText(text: "· 표현")
                ForEach([1, 2, 3], id: \.self) { n in Tiny(title: "\(n)번", color: t.repeats == n ? Theme.ink : Theme.pencil, size: 18) { t.repeats = n } }
                MutedText(text: "· 원문")
                Tiny(title: t.sentence ? "읽음" : "안 읽음", color: t.sentence ? Theme.ink : Theme.pencil, size: 18) { t.sentence.toggle() }
            }
        }
        .padding(.horizontal, 4)
    }

    /// 목록: 지금 읽는 줄 빨갛게, 탭하면 거기부터
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(t.items.enumerated()), id: \.element.id) { i, p in
                let now = i == t.index
                Button { t.jump(to: i) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(now ? (t.playing ? "▶\u{FE0E}" : "▸") : " ").font(.system(size: 13)).foregroundStyle(Theme.red).frame(width: 14)
                        if let n = p.seq { Text("#\(n)").font(Theme.hand(14)).foregroundStyle(Theme.pencil).frame(width: 34, alignment: .trailing) }
                        Text(p.phrase).font(Theme.hand(20)).fontWeight(now ? .bold : .regular).foregroundStyle(now ? Theme.red : Theme.ink).lineLimit(1).fixedSize()
                        Text(p.meaning).font(Theme.hand(18)).foregroundStyle(now ? Theme.red : Theme.pencil).lineLimit(1)
                        Spacer(minLength: 0)
                        if p.isMastered { Text("습득 완료").font(Theme.hand(14)).foregroundStyle(Theme.grade(.A)) }
                    }
                    .padding(.horizontal, 16).frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id("tape-\(i)")
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
