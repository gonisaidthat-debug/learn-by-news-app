import SwiftUI

/// 줄노트 종이. 내용은 왼쪽 여백 오른쪽부터 놓인다.
struct Paper<Content: View>: View {
    var minHeight: CGFloat = 480
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.lh)
        .frame(minHeight: minHeight, alignment: .top)
        .background(PaperBackground())
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 15, y: 10)
    }
}

struct PaperBackground: View {
    var lh: CGFloat = Theme.lh
    var marginW: CGFloat = Theme.marginW
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.paper))
            var y = lh
            while y <= size.height {
                ctx.fill(Path(CGRect(x: 0, y: y - 1, width: size.width, height: 1)), with: .color(Theme.rule))
                y += lh
            }
            ctx.fill(Path(CGRect(x: marginW, y: 0, width: 2, height: size.height)), with: .color(Theme.margin))
        }
    }
}

/// 종이 안 한 항목. 여백만큼 왼쪽 패딩을 주고, 왼쪽 여백에 도장 자리를 둔다.
struct Entry<Content: View>: View {
    var stamp: AnyView? = nil
    var highlight = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Theme.paperLeft)
            .padding(.trailing, Theme.paperRight)
            .background(highlight ? Theme.tab.opacity(0.28) : .clear)
            .overlay(alignment: .leading) {
                if highlight { Rectangle().fill(Theme.tab).frame(width: 4) }
            }
            .overlay(alignment: .topLeading) {
                if let stamp { stamp.offset(x: 2, y: Theme.lh * 0.25) }
            }
    }
}

struct BlankLine: View { var body: some View { Color.clear.frame(height: Theme.lh) } }

/// 등급 도장. 왼쪽 여백의 동그라미
struct Stamp: View {
    enum Kind { case grade(Grade), busy, error, redo, question, pin, session, marker, waiting }
    var kind: Kind
    var small = false

    private var label: String {
        switch kind {
        case .grade(let g): return g == .skip ? "—" : g.rawValue
        case .busy: return "✎\u{FE0E}"
        case .error: return "!"
        case .redo: return "↻\u{FE0E}"
        case .question: return "?"
        case .pin: return "📌\u{FE0E}"
        case .marker: return "🖍"
        case .session: return "✂\u{FE0E}"
        case .waiting: return "⏱\u{FE0E}"
        }
    }
    private var color: Color {
        switch kind {
        case .grade(let g): return Theme.grade(g)
        case .busy, .error, .session: return Theme.red
        case .redo, .question, .waiting: return Theme.pencil
        case .pin, .marker: return Theme.ink
        }
    }
    private var dash: [CGFloat]? {
        switch kind {
        case .redo, .session: return [5, 3]
        case .question, .waiting: return [2, 3]
        default: return nil
        }
    }
    @State private var wiggle = false

    var body: some View {
        let size: CGFloat = small ? 26 : 30
        let fs: CGFloat = small ? 20 : 22
        ZStack {
            if case .pin = kind {
                RoundedRectangle(cornerRadius: 3).fill(Theme.stickyColors[0]).shadow(color: .black.opacity(0.15), radius: 2, x: 1, y: 2)
                Text(label).font(.system(size: 16))
            } else if case .marker = kind {
                RoundedRectangle(cornerRadius: 3).fill(Theme.marker).shadow(color: .black.opacity(0.15), radius: 2, x: 1, y: 2)
                Text(label).font(.system(size: 16))
            } else if case .waiting = kind {
                Circle().fill(Color.white.opacity(0.4))
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
                Image(systemName: "clock").font(.system(size: small ? 12 : 14, weight: .semibold))
            } else {
                if case .busy = kind {} else {
                    Circle().fill(Color.white.opacity(0.4))
                    Circle().strokeBorder(style: StrokeStyle(lineWidth: small ? 2 : 2.5, dash: dash ?? []))
                }
                Text(label).font(Theme.hand(fs)).fontWeight(.bold)
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .rotationEffect(.degrees({ if case .busy = kind { return wiggle ? 6 : -12 } else { return -8 } }()))
        .onAppear { if case .busy = kind { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { wiggle = true } } }
    }
}

/// 포스트잇
struct Sticky: View {
    var phrase: String
    var meaning: String
    var index: Int
    var pinned = true
    var big = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(phrase).font(Theme.hand(big ? 24 : 22)).foregroundStyle(Color(hex: 0x2A2412)).fontWeight(.bold)
            Text(meaning).font(Theme.hand(18)).foregroundStyle(Color(hex: 0x5B5440))
        }
        .multilineTextAlignment(.leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(minWidth: big ? 0 : 150, maxWidth: big ? .infinity : 260, minHeight: big ? 150 : 0, alignment: .topLeading)
        .background(Theme.stickyColors[index % 3])
        .opacity(pinned ? 1 : 0.85)
        .overlay {
            if !pinned { Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.black.opacity(0.15)) }
        }
        .overlay(alignment: .top) { if pinned { Pin().offset(y: -6) } }
        .shadow(color: pinned ? .black.opacity(0.15) : .clear, radius: 2, x: 1, y: 2)
        .rotationEffect(.degrees(-1.5))
    }
}

struct Pin: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(hex: 0xFF7B7B), Theme.red], center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: 7))
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 2)
    }
}

/// 손글씨 작은 버튼 (.tiny)
struct Tiny: View {
    var title: String
    var color: Color = Theme.pencil
    var size: CGFloat = 20
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.hand(size)).foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}

/// 공책 등급 분포 막대. grades는 등급별 개수, total은 전체 문장 수(나머지는 빈 칸)
struct GradeBar: View {
    var grades: [String: Int]
    var total: Int
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Grade.allCases, id: \.self) { gr in
                    let n = grades[gr.rawValue] ?? 0
                    if n > 0 { Rectangle().fill(Theme.grade(gr)).frame(width: g.size.width * CGFloat(n) / CGFloat(max(total, 1))) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 90, height: 6)
        .background(Color(hex: 0xE7E1D4))
        .clipShape(Capsule())
    }
}

/// 노트 머리: 제목(손글씨) + 오른쪽 노란 탭
struct NotebookHead<Label: View>: View {
    var tab: String
    @ViewBuilder var label: () -> Label
    var body: some View {
        HStack(alignment: .bottom) {
            label().font(Theme.hand(26)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Text(tab)
                .font(Theme.hand(20)).foregroundStyle(Theme.tabInk)
                .padding(.horizontal, 12).padding(.vertical, 2)
                .background(Theme.tab, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
        }
        .padding(.horizontal, 8).padding(.bottom, 6)
    }
}

struct ErrorText: View {
    var message: String
    var body: some View { Text(message).font(.system(size: 13)).foregroundStyle(Theme.red) }
}
struct MutedText: View {
    var text: String
    var body: some View { Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted) }
}
