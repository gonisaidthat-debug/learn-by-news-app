import SwiftUI

/// 붙인 순서 번호 범위 "번호 [101] – [150]" (웹 RangePick, goni 2026-11-18): 비우면 전부. 범위가 있으면 ←/→로 같은 크기만큼 앞뒤 구간, ×로 해제.
/// 값은 호출 쪽이 UserDefaults에 "from-to"로 기억한다(`RangePick.load`/`save`)
struct RangePick: View {
    @Binding var range: ClosedRange<Int>?
    var max: Int
    @State private var from = ""
    @State private var to = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            MutedText(text: "번호")
            field($from, placeholder: "1")
            Text("–").font(Theme.hand(18)).foregroundStyle(Theme.pencil)
            field($to, placeholder: max > 0 ? "\(max)" : "")
            if let r = range {
                let size = r.count
                Tiny(title: "←\u{FE0E}", size: 18) { shift(r, -size) }.disabled(r.lowerBound <= 1).opacity(r.lowerBound <= 1 ? 0.4 : 1)
                Tiny(title: "→\u{FE0E}", size: 18) { shift(r, size) }.disabled(r.upperBound >= max).opacity(r.upperBound >= max ? 0.4 : 1)
                Tiny(title: "×", size: 18) { range = nil; from = ""; to = "" }
            }
            if focused { Tiny(title: "확인", color: Theme.red, size: 18) { focused = false } }
        }
        .onAppear { sync() }
        .onChange(of: range) { _, _ in if !focused { sync() } }
        .onChange(of: focused) { _, f in if !f { apply() } }
    }
    private func field(_ text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .font(Theme.hand(18)).foregroundStyle(Theme.blueInk).tint(Theme.blueInk)
            .keyboardType(.numberPad).multilineTextAlignment(.center)
            .frame(width: 52).padding(.vertical, 2)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xD6CFC0)))
            .focused($focused)
            .onSubmit { apply() }
            .onChange(of: text.wrappedValue) { _, v in let d = v.filter(\.isNumber); if d != v { text.wrappedValue = d } }
    }
    private func sync() { from = range.map { String($0.lowerBound) } ?? ""; to = range.map { String($0.upperBound) } ?? "" }
    /// 웹과 같은 규칙: 둘 다 비면 해제, 한쪽만 있으면 1·max로 채우고 뒤집혔으면 바로잡는다
    private func apply() {
        guard !(from.isEmpty && to.isEmpty) else { range = nil; return }
        let a = Int(from) ?? 1, b = Int(to) ?? Swift.max(max, 1)
        let lo = Swift.max(1, Swift.min(a, b)), hi = Swift.min(Swift.max(max, 1), Swift.max(a, b))
        range = lo...hi
        sync()
    }
    private func shift(_ r: ClosedRange<Int>, _ d: Int) {
        let size = r.count
        var lo = r.lowerBound + d, hi = r.upperBound + d
        if lo < 1 { lo = 1; hi = size }
        if hi > max { hi = max; lo = Swift.max(1, max - size + 1) }
        range = lo...hi
    }

    static func load(_ key: String) -> ClosedRange<Int>? {
        let p = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "-").compactMap { Int($0) }
        return p.count == 2 && p[0] <= p[1] ? p[0]...p[1] : nil
    }
    static func save(_ r: ClosedRange<Int>?, _ key: String) {
        if let r { UserDefaults.standard.set("\(r.lowerBound)-\(r.upperBound)", forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
