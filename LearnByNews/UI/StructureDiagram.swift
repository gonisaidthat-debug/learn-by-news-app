import SwiftUI
import UIKit

/// 구조 분석 덩어리 줄 (goni 2026-11-24 "가로로 우선하고 안되면 세로", "부연이 그전 문장 전체에 걸리는 걸 표현").
/// 수치·경로의 기준 구현은 웹 `web/src/structureLayout.ts` drawStructure 하나이고 여기는 그 포팅이다:
/// - 한 줄에 들어가는 묶음은 가로로 붙이고 아래 괄호. 들어가게 하려고 글씨를 17 → 15까지만 줄인다(0.5씩, 분석 하나에 크기 하나)
/// - 그래도 안 들어가는 묶음은 세로 묶음: 여러 줄에 걸치고 왼쪽에 세로 괄호 + 세로쓰기 라벨. 높이가 늘지 않으면 앞 덩어리 옆에 붙는다
/// - 화살표(한 색): 같은 줄은 위로 호, 이웃 줄은 줄 사이로 S자, 두 줄 넘게 떨어지면 오른쪽 가장자리 레일, 세로 묶음에 닿는 건 왼쪽 레일
/// 상자 자리를 실제로 재 가며 배치해야 해서 SwiftUI 레이아웃에 맡기지 않고 폭을 재서 직접 놓는다(UIFont로 글자 폭 측정). 폭이 바뀌면 처음부터 다시
struct StructureDiagram: View {
    var st: Structure
    @State private var width: CGFloat = 0
    var body: some View {
        let layout = width > 0 ? StructureLayout.make(chunks: st.chunks, rawGroups: st.groups ?? [], rawLinks: st.links ?? [], width: width) : nil
        ZStack(alignment: .topLeading) {
            if let layout {
                Canvas { ctx, _ in layout.paint(ctx) }.allowsHitTesting(false)
                ForEach(Array(layout.boxes.enumerated()), id: \.offset) { _, b in
                    VStack(alignment: .center, spacing: 1) {
                        Text(b.text).font(Theme.print(layout.fs)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                        Text(b.role).font(Theme.hand(layout.roleFs)).foregroundStyle(Structure.color(b.role))
                    }
                    .padding(.horizontal, layout.pad).padding(.top, 2).padding(.bottom, 6)
                    .frame(width: b.rect.width, height: b.rect.height)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.025)))
                    .overlay(alignment: .bottom) { Rectangle().fill(Structure.color(b.role)).frame(height: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
                    .help(b.note)
                    .offset(x: b.rect.minX, y: b.rect.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: layout?.height ?? 44)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
    }
}

/// 배치·그림 결과. `make`가 계산하고 `paint`가 Canvas에 그린다
struct StructureLayout {
    struct Box { var text: String; var role: String; var note: String; var rect: CGRect }
    fileprivate struct Line { var path: Path; var color: Color; var width: CGFloat; var head: Path? }
    fileprivate struct Label { var text: String; var at: CGPoint; var color: Color; var font: UIFont; var vertical: Bool }   // at = 가로 라벨은 (가운데 x, 기준선 y), 세로 라벨은 (열 가운데 x, 위 y)
    var boxes: [Box] = []
    var fs: CGFloat = 17
    var roleFs: CGFloat = 14
    var pad: CGFloat = 8
    var height: CGFloat = 0
    fileprivate var lines: [Line] = []
    fileprivate var labels: [Label] = []

    static let BASE: CGFloat = 17, FLOOR: CGFloat = 15   // 글씨 크기와 하한 (goni 값)
    static let INDENT: CGFloat = 18   // 세로 묶음 들여쓰기 (세로 괄호·라벨 자리)
    static let PAD: CGFloat = 16      // 좌우 여백 = 가장자리로 도는 화살표의 길
    static let GAP: CGFloat = 32      // 줄 사이 여백 (아래 괄호가 있는 줄은 그 층 높이만큼 더)
    static let TOP: CGFloat = 30      // 첫 줄 위 여백 (위로 도는 호 자리. 다 그린 뒤 실제 높이에 맞춘다)
    static let BR: CGFloat = 15       // 가로 괄호 한 층 높이
    static let arrow = Color(hex: 0x8A6A2A), bracket = Color(hex: 0x8A8378), bracketText = Color(hex: 0x6F6960)
    static let labelFont = Theme.handUI(13)

    // MARK: 글자 폭
    fileprivate struct Metrics {
        let fs: CGFloat
        var k: CGFloat { fs / StructureLayout.BASE }
        var pad: CGFloat { max(3, (8 * k).rounded()) }
        var roleFs: CGFloat { max(10, (14 * k).rounded()) }
        var textFont: UIFont { Theme.printUI(fs) }
        var roleFont: UIFont { Theme.handUI(roleFs) }
        var boxH: CGFloat { ceil(textFont.lineHeight) + 1 + ceil(roleFont.lineHeight) + 2 + 3 + 3 }
        var gap: CGFloat { max(4, (8 * fs / StructureLayout.BASE).rounded()) }
    }
    private static func textWidth(_ s: String, _ f: UIFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }
    private static func textHeight(_ s: String, _ f: UIFont, width: CGFloat) -> CGFloat {
        ceil((s as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: f], context: nil).height)
    }

    private struct G: Hashable { var id: Int; var from: Int; var to: Int; var label: String }
    private indirect enum Atom { case chunk(Int, CGFloat, CGFloat); case unit(G, CGFloat); case vgroup(G, [Atom], CGFloat) }   // chunk(i, 폭, 높이) / unit(묶음, 폭) / vgroup(묶음, 안, 자연 폭)
    private struct Placed { var rects: [Int: CGRect] = [:]; var vrects: [Int: CGRect] = [:]; var height: CGFloat = 0 }

    // MARK: 만들기
    static func make(chunks: [Structure.Chunk], rawGroups: [Structure.Group], rawLinks: [Structure.Link], width: CGFloat) -> StructureLayout {
        var out = StructureLayout()
        let n = chunks.count
        let W = width - 2 * PAD
        guard n > 0, W > 40 else { return out }
        let groups: [G] = rawGroups.enumerated().compactMap { i, g in g.from >= 0 && g.to < n && g.to > g.from ? G(id: i, from: g.from, to: g.to, label: g.label) : nil }

        // 1. 덩어리 폭 재기
        var cache: [String: CGFloat] = [:]
        func widthAt(_ i: Int, _ fs: CGFloat) -> CGFloat {
            let key = "\(i):\(fs)"
            if let w = cache[key] { return w }
            let m = Metrics(fs: fs)
            let w = max(textWidth(chunks[i].text, m.textFont), textWidth(chunks[i].role, m.roleFont)) + 2 * m.pad
            cache[key] = w; return w
        }
        func spanAt(_ from: Int, _ to: Int, _ fs: CGFloat) -> CGFloat { (from...to).reduce(0) { $0 + widthAt($1, fs) } + Metrics(fs: fs).gap * CGFloat(to - from) }

        // 2. 묶음마다 가로/세로: 하한 글씨로도 한 줄에 안 들어가면 세로. 세로 묶음 안은 들여쓴 폭으로 다시
        let bySize = groups.sorted { ($0.to - $0.from) > ($1.to - $1.from) }
        var vert = Set<Int>(), availOf: [Int: CGFloat] = [:]
        func classify(_ from: Int, _ to: Int, _ avail: [G], _ w: CGFloat) {
            var i = from
            while i <= to {
                guard let g = avail.first(where: { $0.from == i && $0.to <= to }) else { i += 1; continue }
                availOf[g.id] = w
                if spanAt(g.from, g.to, FLOOR) > w { vert.insert(g.id); classify(g.from, g.to, avail.filter { $0.id != g.id }, w - INDENT) }
                i = g.to + 1
            }
        }
        classify(0, n - 1, bySize, W)
        var fs = BASE
        for g in groups where !vert.contains(g.id) {
            guard let w = availOf[g.id] else { continue }
            var f = BASE
            while f >= FLOOR { if spanAt(g.from, g.to, f) <= w { fs = min(fs, f); break }; f -= 0.5 }
        }
        let m = Metrics(fs: fs)
        out.fs = fs; out.roleFs = m.roleFs; out.pad = m.pad

        // 3. 원자 나무: 가로 묶음은 줄바꿈 없는 한 덩이(unit), 세로 묶음은 안에서 줄바꿈하는 상자(vgroup)
        func chunkAtom(_ i: Int) -> Atom {
            let cap = W - 2 * INDENT
            let nat = widthAt(i, fs)
            if nat <= cap { return .chunk(i, nat, m.boxH) }
            let h = textHeight(chunks[i].text, m.textFont, width: cap - 2 * m.pad) + 1 + ceil(m.roleFont.lineHeight) + 2 + 3 + 3
            return .chunk(i, cap, h)
        }
        func atomWidth(_ a: Atom) -> CGFloat { switch a { case .chunk(_, let w, _): return w; case .unit(_, let w): return w; case .vgroup(_, _, let w): return w } }
        var vlist: [G] = []
        func atoms(_ from: Int, _ to: Int, _ avail: [G]) -> [Atom] {
            var res: [Atom] = []
            var i = from
            while i <= to {
                guard let g = avail.first(where: { $0.from == i && $0.to <= to }) else { res.append(chunkAtom(i)); i += 1; continue }
                if vert.contains(g.id) {
                    let kids = atoms(g.from, g.to, avail.filter { $0.id != g.id })
                    let w = INDENT + (kids.map(atomWidth).max() ?? 0)
                    vlist.append(g); res.append(.vgroup(g, kids, w))
                } else {
                    res.append(.unit(g, spanAt(g.from, g.to, fs)))
                }
                i = g.to + 1
            }
            return res
        }
        let tree = atoms(0, n - 1, bySize)
        // 가로 괄호 층: 품지 않은 묶음이 0층, 품은 묶음은 그 아래. 괄호 자리는 그 덩어리의 아래 여백
        let hgroups = groups.filter { !vert.contains($0.id) }
        func inside(_ o: G, _ g: G) -> Bool { o.id != g.id && o.from >= g.from && o.to <= g.to && (o.to - o.from) < (g.to - g.from) }
        func level(_ g: G) -> Int { let inner = hgroups.filter { inside($0, g) }; return inner.isEmpty ? 0 : 1 + (inner.map(level).max() ?? 0) }
        func bracketBelow(_ i: Int) -> CGFloat { let gg = hgroups.filter { $0.from <= i && i <= $0.to }; return gg.isEmpty ? 0 : CGFloat((gg.map(level).max() ?? 0) + 1) * BR + 2 }
        let rowGap = GAP + 2

        // 4. 배치 (flex-wrap과 같은 규칙). fullLine에 든 세로 묶음은 한 줄을 통째로, 아니면 앞 덩어리 옆 남은 폭을 다 쓴다
        func place(_ items: [Atom], x0: CGFloat, y0: CGFloat, width: CGFloat, fullLine: Set<Int>, into p: inout Placed) -> CGFloat {
            var x = x0, y = y0, rowH: CGFloat = 0
            func newline() { y += rowH + rowGap; x = x0; rowH = 0 }
            for a in items {
                switch a {
                case .chunk(let i, let w, let h):
                    if x > x0, x + w > x0 + width { newline() }
                    p.rects[i] = CGRect(x: x, y: y, width: w, height: h)
                    rowH = max(rowH, h + bracketBelow(i)); x += w + m.gap
                case .unit(let g, let w):
                    if x > x0, x + w > x0 + width { newline() }
                    var cx = x, outer: CGFloat = 0
                    for k in g.from...g.to {
                        let cw = widthAt(k, fs)
                        p.rects[k] = CGRect(x: cx, y: y, width: cw, height: m.boxH)
                        outer = max(outer, m.boxH + bracketBelow(k)); cx += cw + m.gap
                    }
                    rowH = max(rowH, outer); x += w + m.gap
                case .vgroup(let g, let kids, let nat):
                    let full = fullLine.contains(g.id)
                    if full, x > x0 { newline() }
                    if !full, x > x0, x + nat > x0 + width { newline() }
                    let vw = (x0 + width) - x   // 줄의 남은 폭을 다 쓴다 (혼자면 전체)
                    var inner = Placed()
                    let h = place(kids, x0: x + INDENT, y0: y, width: vw - INDENT, fullLine: fullLine, into: &inner)
                    p.rects.merge(inner.rects) { $1 }; p.vrects.merge(inner.vrects) { $1 }
                    p.vrects[g.id] = CGRect(x: x, y: y, width: vw, height: h)
                    rowH = max(rowH, h); x = x0 + width + m.gap   // 뒤 덩어리는 다음 줄로
                }
            }
            return y + rowH - y0
        }
        func layout(_ fullLine: Set<Int>) -> Placed { var p = Placed(); p.height = place(tree, x0: PAD, y0: TOP, width: W, fullLine: fullLine, into: &p); return p }
        var fullLine = Set(vlist.map(\.id))
        var placed = layout(fullLine)
        var H = placed.height
        // 세로 묶음을 앞 덩어리 옆에 붙일지: 붙여서 전체 높이가 늘지 않을 때만 (큰 묶음부터)
        for v in vlist.sorted(by: { ($0.to - $0.from) > ($1.to - $1.from) }) {
            var trial = fullLine; trial.remove(v.id)
            let t = layout(trial)
            if t.height <= H { fullLine = trial; placed = t; H = t.height }
        }
        guard (0..<n).allSatisfy({ placed.rects[$0] != nil }) else { return out }

        // 5. 괄호와 화살표 (웹 paint)
        struct R { var l, r, t, b, cx: CGFloat }
        let rects: [R] = (0..<n).map { let f = placed.rects[$0]!; return R(l: f.minX, r: f.maxX, t: f.minY, b: f.maxY + 2, cx: f.midX) }
        var tops: [CGFloat] = []
        for r in rects where !tops.contains(where: { abs($0 - r.t) < 8 }) { tops.append(r.t) }
        tops.sort()
        func rowOf(_ r: R) -> Int { tops.firstIndex { abs($0 - r.t) < 8 } ?? 0 }
        func rowBottom(_ row: Int) -> CGFloat { rects.filter { rowOf($0) == row }.map(\.b).max() ?? 0 }
        func rowDepth(_ row: Int) -> CGFloat { max(2, (0..<n).filter { rowOf(rects[$0]) == row }.map(bracketBelow).max() ?? 0) }
        var lines: [Line] = [], labels: [Label] = []
        var taken: [CGRect] = rects.map { CGRect(x: $0.l, y: $0.t, width: $0.r - $0.l, height: $0.b - $0.t) }
        func hits(_ b: CGRect) -> Bool { taken.contains { b.minX < $0.maxX + 2 && $0.minX < b.maxX + 2 && b.minY < $0.maxY && $0.minY < b.maxY } }
        func labelBox(_ t: String, _ x: CGFloat, _ y: CGFloat) -> CGRect {
            let w = textWidth(t, labelFont); let f = labelFont
            return CGRect(x: x - w / 2, y: y - f.ascender, width: w, height: f.ascender - f.descender)
        }
        func stroke(_ path: Path, _ color: Color, arrow: Bool = false, head: Path? = nil) { lines.append(Line(path: path, color: color, width: arrow ? 1.6 : 1.4, head: head)) }
        /// 라벨. 화살표 라벨(avoid)은 상자·먼저 놓인 라벨·가로로 지나는 선과 겹치면 위·아래·옆으로 비껴 놓는다 (다 겹치면 제자리)
        func label(_ x: CGFloat, _ y: CGFloat, _ t: String, _ color: Color, avoid: Bool = false) {
            guard !t.isEmpty else { return }
            var b = labelBox(t, x, y), at = CGPoint(x: x, y: y)
            if avoid, hits(b) {
                let w = b.width / 2 + 10
                let cands: [(CGFloat, CGFloat)] = [(0, -12), (0, 14), (0, 26), (-w, 0), (w, 0), (-w, 14), (w, 14), (-w, -12), (w, -12), (-2 * w, 0), (2 * w, 0), (0, -24)]
                if let free = cands.first(where: { !hits(labelBox(t, x + $0.0, y + $0.1)) }) { at = CGPoint(x: x + free.0, y: y + free.1); b = labelBox(t, at.x, at.y) }
            }
            taken.append(b)
            labels.append(Label(text: t, at: at, color: color, font: labelFont, vertical: false))
        }
        /// 꺾은선이 가로로 길게 지나는 자리도 라벨이 피하게 적어 둔다
        func track(_ pts: [CGPoint]) -> [CGPoint] {
            for i in 1..<max(1, pts.count) where pts[i].y == pts[i - 1].y && abs(pts[i].x - pts[i - 1].x) > 20 {
                taken.append(CGRect(x: min(pts[i].x, pts[i - 1].x), y: pts[i].y - 1, width: abs(pts[i].x - pts[i - 1].x), height: 2))
            }
            return pts
        }
        /// 꺾이는 곳을 둥글린 꺾은선
        func rp(_ pts: [CGPoint], _ r: CGFloat = 7) -> Path {
            var p = Path(); guard let f = pts.first else { return p }
            p.move(to: f)
            if pts.count > 2 {
                for i in 1..<(pts.count - 1) {
                    let (pv, c, nx) = (pts[i - 1], pts[i], pts[i + 1])
                    let d1 = hypot(c.x - pv.x, c.y - pv.y), d2 = hypot(nx.x - c.x, nx.y - c.y)
                    guard d1 > 0, d2 > 0 else { continue }
                    let rr = min(r, d1 / 2, d2 / 2)
                    p.addLine(to: CGPoint(x: c.x - (c.x - pv.x) / d1 * rr, y: c.y - (c.y - pv.y) / d1 * rr))
                    p.addQuadCurve(to: CGPoint(x: c.x + (nx.x - c.x) / d2 * rr, y: c.y + (nx.y - c.y) / d2 * rr), control: c)
                }
            }
            p.addLine(to: pts[pts.count - 1])
            return p
        }
        /// 화살촉: 끝점 end에 before→end 방향으로 (웹 marker 7×7)
        func head(_ end: CGPoint, _ before: CGPoint) -> Path {
            let ang = atan2(end.y - before.y, end.x - before.x)
            var h = Path(); h.move(to: end)
            h.addLine(to: CGPoint(x: end.x - 7 * cos(ang) + 3.5 * sin(ang), y: end.y - 7 * sin(ang) - 3.5 * cos(ang)))
            h.addLine(to: CGPoint(x: end.x - 7 * cos(ang) - 3.5 * sin(ang), y: end.y - 7 * sin(ang) + 3.5 * cos(ang)))
            h.closeSubpath(); return h
        }
        func arrowLine(_ pts: [CGPoint]) { guard pts.count >= 2 else { return }; stroke(rp(track(pts)), arrow, arrow: true, head: head(pts[pts.count - 1], pts[pts.count - 2])) }

        // 가로 괄호 (엇갈린 묶음이 줄을 넘으면 줄마다 토막, 라벨은 첫 토막에만)
        for g in hgroups {
            let byRow = Dictionary(grouping: Array(rects[g.from...g.to]), by: rowOf)
            let firstRow = byRow.keys.min() ?? 0
            for (row, ms) in byRow.sorted(by: { $0.key < $1.key }) {
                let x1 = (ms.map(\.l).min() ?? 0) + 2, x2 = (ms.map(\.r).max() ?? 0) - 2
                let y = rowBottom(row) + 4 + BR * CGFloat(level(g))
                var p = Path(); p.move(to: CGPoint(x: x1, y: y - 4)); p.addLine(to: CGPoint(x: x1, y: y)); p.addLine(to: CGPoint(x: x2, y: y)); p.addLine(to: CGPoint(x: x2, y: y - 4))
                stroke(p, bracket)
                if row == firstRow { label((x1 + x2) / 2, y + 11, g.label, bracketText) }
            }
        }
        // 세로 괄호: 묶음의 첫 줄 위에서 마지막 줄 괄호 아래까지, 라벨은 세로쓰기
        struct V { var x, y1, y2: CGFloat; var r1, r2, from, to: Int }
        var vinfo: [Int: V] = [:]
        for v in vlist {
            guard let vr = placed.vrects[v.id] else { continue }
            let ms = Array(rects[v.from...v.to]); let rws = ms.map(rowOf)
            let r1 = rws.min() ?? 0, r2 = rws.max() ?? 0
            let y1 = ms.map(\.t).min() ?? 0, y2 = rowBottom(r2) + rowDepth(r2) + 2
            let x = vr.minX + 13
            vinfo[v.id] = V(x: x, y1: y1, y2: y2, r1: r1, r2: r2, from: v.from, to: v.to)
            var p = Path(); p.move(to: CGPoint(x: x + 5, y: y1)); p.addLine(to: CGPoint(x: x, y: y1)); p.addLine(to: CGPoint(x: x, y: y2)); p.addLine(to: CGPoint(x: x + 5, y: y2))
            stroke(p, bracket)
            if !v.label.isEmpty {
                let chars = Array(v.label); let step = labelFont.lineHeight
                taken.append(CGRect(x: x - 7 - 7, y: y1 + 2, width: 14, height: step * CGFloat(chars.count)))
                labels.append(Label(text: v.label, at: CGPoint(x: x - 7, y: y1 + 2), color: bracketText, font: labelFont, vertical: true))
            }
        }
        // 화살표 끝: 덩어리 하나(c) / 가로 묶음(h) / 세로 묶음(v)
        enum Ref: Hashable { case c(Int), g(Int) }
        enum Anchor {
            case c(x: CGFloat, top: CGFloat, bot: CGFloat, l: CGFloat, r: CGFloat, mid: CGFloat, row: Int, first: Bool, last: Bool)
            case h(x: CGFloat, top: CGFloat, bot: CGFloat, l: CGFloat, mid: CGFloat, row: Int, first: Bool)
            case v(V)
            var isV: Bool { if case .v = self { return true }; return false }
            var isH: Bool { if case .h = self { return true }; return false }
            var isC: Bool { if case .c = self { return true }; return false }
            var x: CGFloat { switch self { case .c(let x, _, _, _, _, _, _, _, _): return x; case .h(let x, _, _, _, _, _, _): return x; case .v(let v): return v.x } }
            var top: CGFloat { switch self { case .c(_, let t, _, _, _, _, _, _, _): return t; case .h(_, let t, _, _, _, _, _): return t; case .v(let v): return v.y1 } }
            var bot: CGFloat { switch self { case .c(_, _, let b, _, _, _, _, _, _): return b; case .h(_, _, let b, _, _, _, _): return b; case .v(let v): return v.y2 } }
            var l: CGFloat { switch self { case .c(_, _, _, let l, _, _, _, _, _): return l; case .h(_, _, _, let l, _, _, _): return l; case .v(let v): return v.x } }
            var r: CGFloat { switch self { case .c(_, _, _, _, let r, _, _, _, _): return r; default: return x } }
            var mid: CGFloat { switch self { case .c(_, _, _, _, _, let m, _, _, _): return m; case .h(_, _, _, _, let m, _, _): return m; case .v(let v): return (v.y1 + v.y2) / 2 } }
            var row: Int { switch self { case .c(_, _, _, _, _, _, let r, _, _): return r; case .h(_, _, _, _, _, let r, _): return r; case .v(let v): return v.r1 } }
            var first: Bool { switch self { case .c(_, _, _, _, _, _, _, let f, _): return f; case .h(_, _, _, _, _, _, let f): return f; case .v: return true } }
            var last: Bool { if case .c(_, _, _, _, _, _, _, _, let l) = self { return l }; return false }
        }
        func leftmost(_ i: Int) -> Bool { !rects.indices.contains { $0 != i && rowOf(rects[$0]) == rowOf(rects[i]) && rects[$0].l < rects[i].l } }
        func rightmost(_ i: Int) -> Bool { !rects.indices.contains { $0 != i && rowOf(rects[$0]) == rowOf(rects[i]) && rects[$0].r > rects[i].r } }
        let gById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        func anchor(_ ref: Ref) -> Anchor {
            switch ref {
            case .c(let i):
                let r = rects[i]
                return .c(x: r.cx, top: r.t - 2, bot: r.b + bracketBelow(i), l: r.l, r: r.r, mid: (r.t + r.b) / 2, row: rowOf(r), first: leftmost(i), last: rightmost(i))
            case .g(let id):
                if let v = vinfo[id] { return .v(v) }
                let g = gById[id]!
                let ms = Array(rects[g.from...g.to]); let row = rowOf(ms[0])
                let x1 = (ms.map(\.l).min() ?? 0) + 2, x2 = (ms.map(\.r).max() ?? 0) - 2, y = rowBottom(row) + 4 + BR * CGFloat(level(g))
                return .h(x: (x1 + x2) / 2, top: (ms.map(\.t).min() ?? 0) - 2, bot: y + 14, l: x1, mid: y, row: row, first: leftmost(g.from))   // 괄호 라벨 아래에 닿는다
            }
        }
        // 화살표 끝이 묶음이면 그 묶음, 아니면 덩어리 번호. 묶음 번호는 서버가 준 groups 순서 그대로
        func end(_ c: Int, _ gi: Int?, _ other: Int) -> Ref? {
            if let gi, gi >= 0, let g = gById[gi], !(g.from <= other && other <= g.to) { return .g(gi) }
            return (0..<n).contains(c) ? .c(c) : nil
        }
        func span(_ r: Ref) -> (Int, Int) { switch r { case .c(let i): return (i, i); case .g(let id): let g = gById[id]!; return (g.from, g.to) } }
        func overlap(_ a: Ref, _ b: Ref) -> Bool { let (a1, a2) = span(a), (b1, b2) = span(b); return a1 <= b2 && b1 <= a2 }
        let links: [(Ref, Ref, String)] = rawLinks.compactMap { l in
            guard let a = end(l.from, l.fromGroup, l.to), let b = end(l.to, l.toGroup, l.from), !overlap(a, b) else { return nil }
            return (a, b, l.label)
        }
        // 줄 아래로 가로질러 갈 때의 높이: 그 줄의 괄호·라벨을 다 지난 아래
        func under(_ a: Anchor) -> CGFloat { max(a.bot, rowBottom(a.row) + rowDepth(a.row)) + 8 }
        let railR = width - 5
        var laneL = 0, laneR = 0
        var arrivals: [Ref: Int] = [:]
        var pending: [(CGFloat, CGFloat, String)] = []   // 화살표 라벨은 길을 다 그린 뒤에 놓는다
        for (fromRef, toRef, text) in links {
            let A = anchor(fromRef), B = anchor(toRef)
            if A.isV || B.isV {
                // 세로 묶음에 닿는(에서 나오는) 화살표: 왼쪽 가장자리로 돌아 세로 괄호에 옆에서 닿는다
                let toV = B.isV
                let Vn = toV ? B : A, S = toV ? A : B
                guard case .v(let V) = Vn else { continue }
                let rx = 9 - 4 * CGFloat(laneL); laneL += 1
                let sRow: Int = { if case .v(let sv) = S { return sv.r1 }; return S.row }()
                let yv: CGFloat = sRow > V.r2 ? V.y2 - 18 : sRow < V.r1 ? V.y1 + 18 : (V.y1 + V.y2) / 2
                var sp: [CGPoint]
                if case .v(let sv) = S {
                    let ys: CGFloat = sv.r1 > V.r2 ? sv.y1 + 18 : sv.r2 < V.r1 ? sv.y2 - 18 : (sv.y1 + sv.y2) / 2
                    sp = [CGPoint(x: sv.x - 2, y: ys), CGPoint(x: rx, y: ys)]
                } else if S.first { sp = [CGPoint(x: S.l, y: S.mid), CGPoint(x: rx, y: S.mid)] }
                else { let up = S.row > V.r2; let ya = up ? S.top - (GAP - 4) : under(S); sp = [CGPoint(x: S.x, y: up ? S.top : S.bot), CGPoint(x: S.x, y: ya), CGPoint(x: rx, y: ya)] }
                // 세로 묶음이 앞 덩어리 옆에 붙어 있고 상대가 위에 있으면 괄호 머리로 위에서 닿는다
                let beside = rects.indices.contains { j in (j < V.from || j > V.to) && rowOf(rects[j]) == V.r1 && rects[j].l < V.x }
                let vp: [CGPoint] = beside && sRow < V.r1 ? [CGPoint(x: rx, y: V.y1 - 12), CGPoint(x: V.x, y: V.y1 - 12), CGPoint(x: V.x, y: V.y1 - 1)] : [CGPoint(x: rx, y: yv), CGPoint(x: V.x - 2, y: yv)]
                arrowLine(toV ? sp + vp : vp.reversed() + sp.reversed())
                pending.append((max(15, (rx + V.x) / 2 - 1), vp[1].y - 6, text))
            } else if (B.isH && A.row < B.row) || (A.isH && B.row < A.row) {
                // 가로 묶음과 그 윗줄 사이: 괄호에 닿는다. 묶음이 줄 맨 앞이면 왼쪽 레일로 괄호 왼쪽 끝에, 아니면 오른쪽 레일로 괄호 아래에서
                let toH = B.isH && A.row < B.row
                let Hh = toH ? B : A, S = toH ? A : B
                let left = Hh.first
                let rx: CGFloat
                if left { rx = 9 - 4 * CGFloat(laneL); laneL += 1 } else { rx = railR - 4 * CGFloat(laneR); laneR += 1 }
                let sp: [CGPoint] = left && S.first ? [CGPoint(x: S.l, y: S.mid), CGPoint(x: rx, y: S.mid)]
                    : (!left && S.isC && S.last) ? [CGPoint(x: S.r, y: S.mid - 7), CGPoint(x: rx, y: S.mid - 7)]
                    : [CGPoint(x: S.x, y: S.bot), CGPoint(x: S.x, y: under(S)), CGPoint(x: rx, y: under(S))]
                let hp: [CGPoint] = left ? [CGPoint(x: rx, y: Hh.mid), CGPoint(x: Hh.l, y: Hh.mid)] : [CGPoint(x: rx, y: under(Hh)), CGPoint(x: Hh.x, y: under(Hh)), CGPoint(x: Hh.x, y: Hh.bot)]
                arrowLine(toH ? sp + hp : hp.reversed() + sp.reversed())
                pending.append(left ? (max(15, rx + 8), (sp[sp.count - 1].y + Hh.mid) / 2 + 4, text) : ((rx + Hh.x) / 2, under(Hh) + 13, text))
            } else if abs(A.row - B.row) >= 2 {
                // 두 줄 넘게 떨어짐: 오른쪽 가장자리로 돈다. 줄 끝 덩어리는 옆구리에서 바로 나가고 들어온다
                let rx = railR - 4 * CGFloat(laneR); laneR += 1
                let up = A.row > B.row
                var pts: [CGPoint] = []
                if A.isC, A.last { pts += [CGPoint(x: A.r, y: A.mid - 7), CGPoint(x: rx, y: A.mid - 7)] }
                else { let ya = up ? A.top - (GAP - 4) : under(A); pts += [CGPoint(x: A.x, y: up ? A.top : A.bot), CGPoint(x: A.x, y: ya), CGPoint(x: rx, y: ya)] }
                let k = CGFloat(arrivals[toRef] ?? 0); arrivals[toRef] = Int(k) + 1
                var lx: CGFloat, ly: CGFloat
                if B.isC, B.last {
                    let ym = B.mid + 6 + k * 7
                    pts += [CGPoint(x: rx, y: ym), CGPoint(x: B.r, y: ym)]
                    if rx - B.r >= 34 { lx = (rx + B.r) / 2 + 2; ly = ym - 6 } else { lx = rx - 15; ly = ((A.isC ? A.mid : A.bot) + ym) / 2 }
                } else {
                    let yb = up ? under(B) + k * 5 : B.top - (GAP - 4) - k * 5, bx = B.x + k * 8
                    pts += [CGPoint(x: rx, y: yb), CGPoint(x: bx, y: yb), CGPoint(x: bx, y: up ? B.bot : B.top)]
                    lx = (rx + bx) / 2; ly = up ? yb + 13 : yb - 6
                }
                arrowLine(pts)
                pending.append((lx, ly, text))
            } else if A.row == B.row, A.isH || B.isH {
                // 같은 줄의 가로 묶음과: 괄호 아래로 U자
                let y = max(A.bot, B.bot) + 22
                var p = Path(); p.move(to: CGPoint(x: A.x, y: A.bot))
                let c2 = CGPoint(x: B.x, y: y + 10)
                p.addCurve(to: CGPoint(x: B.x, y: B.bot), control1: CGPoint(x: A.x, y: y + 10), control2: c2)
                stroke(p, arrow, arrow: true, head: head(CGPoint(x: B.x, y: B.bot), c2))
                pending.append(((A.x + B.x) / 2, y + 2, text))
            } else if A.row == B.row {
                // 같은 줄: 위로 호
                let h = min(GAP - 8, 10 + abs(B.x - A.x) / 10)
                let c = CGPoint(x: (A.x + B.x) / 2, y: A.top - 2 * h)
                var p = Path(); p.move(to: CGPoint(x: A.x, y: A.top)); p.addQuadCurve(to: CGPoint(x: B.x, y: B.top), control: c)
                stroke(p, arrow, arrow: true, head: head(CGPoint(x: B.x, y: B.top), c))
                pending.append(((A.x + B.x) / 2, A.top - h - 3, text))
            } else {
                // 이웃 줄: 줄 사이 여백으로 S자
                let (from, to) = A.row > B.row ? (A.top, B.bot) : (A.bot, B.top)
                let g = (to - from) / 2
                let c2 = CGPoint(x: B.x, y: to - g)
                var p = Path(); p.move(to: CGPoint(x: A.x, y: from)); p.addCurve(to: CGPoint(x: B.x, y: to), control1: CGPoint(x: A.x, y: from + g), control2: c2)
                stroke(p, arrow, arrow: true, head: head(CGPoint(x: B.x, y: to), c2))
                pending.append(((A.x + B.x) / 2, (from + to) / 2 + 4, text))
            }
        }
        for (x, y, t) in pending { label(x, y, t, arrow, avoid: true) }

        // 6. 위·아래 여백은 그림이 실제로 차지한 만큼
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for l in lines { let b = l.path.boundingRect; minY = min(minY, b.minY); maxY = max(maxY, b.maxY); if let h = l.head { maxY = max(maxY, h.boundingRect.maxY); minY = min(minY, h.boundingRect.minY) } }
        for b in taken { minY = min(minY, b.minY); maxY = max(maxY, b.maxY) }
        let drew = !lines.isEmpty
        let above: CGFloat = drew ? max(4, ceil(TOP - minY + 4)) : 4
        let below: CGFloat = drew ? max(6, ceil(maxY - (TOP + placed.height) + 6)) : 6
        let dy = above - TOP
        let shift = CGAffineTransform(translationX: 0, y: dy)
        out.lines = lines.map { Line(path: $0.path.applying(shift), color: $0.color, width: $0.width, head: $0.head?.applying(shift)) }
        out.labels = labels.map { var l = $0; l.at.y += dy; return l }
        out.boxes = (0..<n).map { Box(text: chunks[$0].text, role: chunks[$0].role, note: chunks[$0].note, rect: placed.rects[$0]!.offsetBy(dx: 0, dy: dy)) }
        out.height = above + placed.height + below
        return out
    }

    // MARK: 그리기
    func paint(_ ctx: GraphicsContext) {
        for l in lines {
            ctx.stroke(l.path, with: .color(l.color), style: StrokeStyle(lineWidth: l.width, lineCap: .round, lineJoin: .round))
            if let h = l.head { ctx.fill(h, with: .color(l.color)) }
        }
        let paper = Color(red: 1, green: 0.992, blue: 0.965).opacity(0.95)
        for l in labels {
            if l.vertical {
                var y = l.at.y
                for ch in l.text {
                    let r = ctx.resolve(Text(String(ch)).font(Theme.hand(13)).foregroundColor(l.color))
                    let sz = r.measure(in: CGSize(width: 40, height: 40))
                    ctx.fill(Path(roundedRect: CGRect(x: l.at.x - sz.width / 2 - 2, y: y, width: sz.width + 4, height: sz.height), cornerRadius: 2), with: .color(paper))
                    ctx.draw(r, at: CGPoint(x: l.at.x, y: y + sz.height / 2), anchor: .center)
                    y += l.font.lineHeight
                }
            } else {
                let r = ctx.resolve(Text(l.text).font(Theme.hand(13)).foregroundColor(l.color))
                let sz = r.measure(in: CGSize(width: 300, height: 40))
                let center = CGPoint(x: l.at.x, y: l.at.y - (l.font.ascender + l.font.descender) / 2)
                ctx.fill(Path(roundedRect: CGRect(x: center.x - sz.width / 2 - 3, y: center.y - sz.height / 2 - 1, width: sz.width + 6, height: sz.height + 2), cornerRadius: 3), with: .color(paper))
                ctx.draw(r, at: center, anchor: .center)
            }
        }
    }
}
