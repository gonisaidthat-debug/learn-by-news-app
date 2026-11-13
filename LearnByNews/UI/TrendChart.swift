import SwiftUI

/// 하루치 통계: 평균 점수(번역+응용), 등급별 채점 문장 수
struct DayStat: Identifiable, Hashable {
    var at: Int64                 // 그날 첫 활동 시각 (정렬·라벨용)
    var pts: [Int]                // 점수 목록 (평균 계산)
    var counts: [Grade: Int]      // A~D 개수
    var id: Int64 { at }
    var avg: Int? { pts.isEmpty ? nil : Int((Double(pts.reduce(0, +)) / Double(pts.count)).rounded()) }
    var total: Int { counts.values.reduce(0, +) }
    var label: String { Date(ms: at).monthDay }
    /// "11/13 · 81점 · 18문장 (A 5 · B 7 · C 4 · D 2)"
    var tooltip: String {
        let parts = [Grade.A, .B, .C, .D].compactMap { g in (counts[g] ?? 0) > 0 ? "\(g.rawValue) \(counts[g]!)" : nil }
        return "\(label)" + (avg.map { " · \($0)점" } ?? "") + " · \(total)문장" + (parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))")
    }
}

enum Trend {
    /// 등급 → 한 색(잉크)의 밝기 단계. A가 가장 진하다 (순서형이라 한 색 램프, 종이색 위에서 검증)
    static func color(_ g: Grade) -> Color {
        switch g {
        case .A: return Color(hex: 0x26221C)
        case .B: return Color(hex: 0x58514A)
        case .C: return Color(hex: 0x837B70)
        default: return Color(hex: 0xAAA294)
        }
    }

    /// 채점(번역)과 응용을 날짜별로 묶는다 (건너뜀 제외)
    static func days(attempts: [LogAttempt], drills: [LogDrill]) -> [DayStat] {
        let cal = Calendar.current
        var map: [Date: DayStat] = [:]
        func add(_ at: Int64, _ g: Grade) {
            guard g != .skip, let p = Grade.points[g] else { return }
            let day = cal.startOfDay(for: Date(ms: at))
            var d = map[day] ?? DayStat(at: at, pts: [], counts: [:])
            d.at = min(d.at, at); d.pts.append(p); d.counts[g, default: 0] += 1
            map[day] = d
        }
        for a in attempts { add(a.createdAt, a.grade) }
        for d in drills { if let g = d.grade, let t = d.answeredAt { add(t, g) } }
        return map.values.sorted { $0.at < $1.at }
    }
}

/// 평가 추이: 위 = 날짜별 평균 점수 선, 아래 = 등급별로 쌓은 채점 문장 수 막대. 활동이 있던 날만 등간격
struct TrendChart: View {
    var days: [DayStat]
    var compact = false            // 기사별 작은 그래프: 낮게, 범례 없음
    @State private var picked: Int?

    private var lineH: CGFloat { compact ? 70 : 120 }
    private var barH: CGFloat { compact ? 36 : 60 }
    private let leftPad: CGFloat = 30, rightPad: CGFloat = 10, gapY: CGFloat = 10

    var body: some View {
        if days.count < 2 {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { g in
                    let w = g.size.width - leftPad - rightPad
                    let step = w / CGFloat(max(days.count - 1, 1))
                    let x: (Int) -> CGFloat = { leftPad + step * CGFloat($0) }
                    let maxTotal = max(days.map(\.total).max() ?? 1, 1)
                    let barW = min(24, max(6, step * 0.6))
                    let top: CGFloat = 16                      // 맨 위 눈금 글자·점 라벨 여백
                    let barTop = top + lineH + gapY
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in
                            // 눈금 20/50/80/100 (가는 회색)
                            for v in [20, 50, 80, 100] {
                                let y = top + lineH - lineH * CGFloat(v) / 100
                                ctx.stroke(Path { p in p.move(to: CGPoint(x: leftPad, y: y)); p.addLine(to: CGPoint(x: size.width - rightPad, y: y)) }, with: .color(Theme.ink.opacity(0.1)), lineWidth: 1)
                                ctx.draw(Text("\(v)").font(.system(size: 9)).foregroundColor(Theme.pencil), at: CGPoint(x: leftPad - 10, y: y), anchor: .center)
                            }
                            // 평균 점수 선
                            let pts = days.enumerated().compactMap { i, d -> CGPoint? in d.avg.map { CGPoint(x: x(i), y: top + lineH - lineH * CGFloat($0) / 100) } }
                            if pts.count >= 2 {
                                var path = Path(); path.move(to: pts[0]); for p in pts.dropFirst() { path.addLine(to: p) }
                                ctx.stroke(path, with: .color(Theme.red), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                            }
                            // 점: 지름 9, 종이색 테두리 2. 숫자는 처음·끝·최고·최저만
                            let avgs = days.map { $0.avg ?? -1 }
                            let maxV = avgs.max() ?? 0, minV = avgs.filter { $0 >= 0 }.min() ?? 0
                            for (i, d) in days.enumerated() {
                                guard let a = d.avg else { continue }
                                let c = CGPoint(x: x(i), y: top + lineH - lineH * CGFloat(a) / 100)
                                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13)), with: .color(Theme.paper))
                                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)), with: .color(Theme.red))
                                let label = i == 0 || i == days.count - 1 || a == maxV || a == minV
                                if label { ctx.draw(Text("\(a)").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.ink), at: CGPoint(x: c.x, y: c.y - 12), anchor: .center) }
                            }
                            // 등급별 쌓은 막대 (아래부터 A→D), 조각 사이 2pt 종이색 틈, 조각 최소 높이 5
                            for (i, d) in days.enumerated() {
                                var y = barTop + barH
                                for g in [Grade.A, .B, .C, .D] {
                                    let n = d.counts[g] ?? 0
                                    guard n > 0 else { continue }
                                    let h = max(5, barH * CGFloat(n) / CGFloat(maxTotal))
                                    let rect = CGRect(x: x(i) - barW / 2, y: y - h, width: barW, height: h)
                                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Trend.color(g)))
                                    y -= h + 2
                                }
                            }
                            // x 라벨: 겹치지 않을 만큼만
                            let every = max(1, Int(ceil(CGFloat(days.count) * 34 / max(w, 1))))
                            for (i, d) in days.enumerated() where i % every == 0 || i == days.count - 1 {
                                ctx.draw(Text(d.label).font(.system(size: 9)).foregroundColor(Theme.pencil), at: CGPoint(x: x(i), y: barTop + barH + 9), anchor: .center)
                            }
                        }
                        // 탭: 하루 열 고르기
                        HStack(spacing: 0) {
                            ForEach(Array(days.indices), id: \.self) { i in
                                Color.clear.contentShape(Rectangle())
                                    .onTapGesture { picked = picked == i ? nil : i }
                            }
                        }
                        .padding(.leading, leftPad - step / 2).padding(.trailing, rightPad - step / 2)
                        if let i = picked, days.indices.contains(i) {
                            Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: max(barW, 10), height: barTop + barH).offset(x: x(i) - max(barW, 10) / 2)
                        }
                    }
                }
                .frame(height: 16 + lineH + gapY + barH + 16)
                if let i = picked, days.indices.contains(i) {
                    Text(days[i].tooltip).font(.system(size: 12)).foregroundStyle(Theme.ink)
                }
                if !compact {
                    HStack(spacing: 12) {
                        HStack(spacing: 4) { Capsule().fill(Theme.red).frame(width: 14, height: 2); Text("그날 평균 점수") }
                        ForEach([Grade.A, .B, .C, .D], id: \.self) { g in
                            HStack(spacing: 3) { RoundedRectangle(cornerRadius: 1).fill(Trend.color(g)).frame(width: 9, height: 9); Text(g.rawValue) }
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(Theme.pencil)
                }
            }
        }
    }
}
