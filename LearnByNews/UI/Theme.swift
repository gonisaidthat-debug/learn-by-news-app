import SwiftUI
import UIKit

/// 웹 styles.css의 :root 변수
enum Theme {
    static let desk = Color(hex: 0xE9E2D3)
    static let paper = Color(hex: 0xFFFDF6)
    static let rule = Color(hex: 0xCFE0EE)
    static let margin = Color(hex: 0xF0A3A3)
    static let ink = Color(hex: 0x26221C)
    static let pencil = Color(hex: 0x8A8378)
    static let red = Color(hex: 0xD7262C)
    static let muted = Color(hex: 0x8A8378)
    static let blueInk = Color(hex: 0x1F2F6B)
    static let placeholder = Color(hex: 0xB9B3A6)
    static let tab = Color(hex: 0xF6D365)
    static let tabInk = Color(hex: 0x5A4A12)

    static func grade(_ g: Grade) -> Color {
        switch g {
        case .A: return Color(hex: 0x2F9E44)
        case .B: return Color(hex: 0xD9A400)
        case .C: return Color(hex: 0xE8590C)
        case .D: return Color(hex: 0xD7262C)
        case .skip: return Color(hex: 0xA9A39A)
        }
    }
    static let stickyColors: [Color] = [Color(hex: 0xFFF59B), Color(hex: 0xFFD6E7), Color(hex: 0xCDEAFF)]
    static let stickyBack = Color(hex: 0xF3EFE3)
    static let marker = Color(hex: 0xFFF176)          // 형광펜
    static let markerSelecting = Color(hex: 0xFFE082) // 고르는 중
    static let coverColors: [Color] = [Color(hex: 0xC0392B), Color(hex: 0x2C6FBB), Color(hex: 0x2E8B57), Color(hex: 0x8E5BBD)]

    /// 줄 간격(한 줄 높이)과 왼쪽 여백 폭. 웹 모바일 값
    static let lh: CGFloat = 32
    static let marginW: CGFloat = 36
    static let paperLeft: CGFloat = marginW + 10
    static let paperRight: CGFloat = 12

    static let handName = "NanumPen-Regular"
    static func hand(_ size: CGFloat) -> Font { .custom(handName, size: size) }
    static func handUI(_ size: CGFloat) -> UIFont { UIFont(name: handName, size: size) ?? .systemFont(ofSize: size) }
    static func print(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
    static func printUI(_ size: CGFloat) -> UIFont {
        let d = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor
        return UIFont(descriptor: d, size: size)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// 글줄을 공책 줄(lh)에 맞춘다: 각 줄이 정확히 lh 높이를 차지하게 line spacing과 상하 패딩을 준다
struct RuledText: ViewModifier {
    let uiFont: UIFont
    let lh: CGFloat
    func body(content: Content) -> some View {
        let extra = max(0, lh - uiFont.lineHeight)
        content
            .lineSpacing(extra)
            .padding(.vertical, extra / 2)
    }
}

extension View {
    /// 넓은 화면(아이패드·맥)에서 종이 폭을 웹 .shell(820px)처럼 제한하고 가운데 둔다
    func readableWidth() -> some View {
        self.frame(maxWidth: 820).frame(maxWidth: .infinity)
    }
    /// 인쇄체 원문 줄
    func enLine(size: CGFloat = 16) -> some View {
        self.font(Theme.print(size)).foregroundStyle(Theme.ink).modifier(RuledText(uiFont: Theme.printUI(size), lh: Theme.lh))
    }
    /// 손글씨 줄 (번역은 파란 잉크, 빨간펜, 연필)
    func handLine(size: CGFloat, color: Color) -> some View {
        self.font(Theme.hand(size)).foregroundStyle(color).modifier(RuledText(uiFont: Theme.handUI(size), lh: Theme.lh))
    }
    func koLine() -> some View { handLine(size: 22, color: Theme.blueInk) }
    func redpen(size: CGFloat = 22) -> some View { handLine(size: size, color: Theme.red) }
    func pencil(size: CGFloat = 22) -> some View { handLine(size: size, color: Theme.pencil) }
}
