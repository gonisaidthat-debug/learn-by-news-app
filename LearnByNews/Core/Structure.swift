import Foundation
import SwiftUI

/// 문장 구조 분석 (goni 2026-11-20 "문장 구조 첨삭에 대한 분석도 내가 누르면 보여 줄 수 있게").
/// `POST /api/sentences/:id/structure {force?}` 응답. 서버가 문장별로 저장해 두 번째부터는 저장본(cached true, 즉시)
struct Structure: Codable, Equatable {
    struct Chunk: Codable, Equatable { var text: String; var role: String; var note: String }
    var skeleton: String
    var chunks: [Chunk]
    var reading: String
    var pitfalls: [String]
    var mine: String
    var createdAt: Int64?
    var cached: Bool?

    /// 역할 이름 → 색 묶음 (웹 roleKind와 같은 규칙): 주어 파랑 / 동사·술어 빨강 / 목적·보어 초록 / 접속·관계·종속·조건·시간 보라 / 나머지 회색
    static func color(_ role: String) -> Color {
        if role.contains("주어") { return Color(hex: 0x2F6FD6) }
        if role.contains("동사") || role.contains("술어") { return Theme.red }
        if role.contains("목적") || role.contains("보어") { return Color(hex: 0x2F9E44) }
        if ["접속", "관계", "종속", "조건", "시간"].contains(where: { role.contains($0) }) { return Color(hex: 0x7A3FB8) }
        return Theme.pencil
    }
}

/// 받은 분석의 기기 저장본(문장 id별, UserDefaults). 오프라인에서는 이것만 보여 주고, 없으면 "연결되면 분석" —
/// 큐에 넣지 않는다(결과를 바로 봐야 의미가 있다, goni 2026-11-20)
@MainActor
final class StructureStore {
    static let shared = StructureStore()
    private static let key = "lbn_structures"
    private var map: [String: Structure]
    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let m = try? JSONDecoder.api.decode([String: Structure].self, from: d) { map = m } else { map = [:] }
    }
    func get(_ sentenceId: String) -> Structure? { map[sentenceId] }
    func put(_ sentenceId: String, _ s: Structure) { map[sentenceId] = s; save() }
    func remove(_ sentenceId: String) { map[sentenceId] = nil; save() }
    private func save() { UserDefaults.standard.set(try? JSONEncoder.api.encode(map), forKey: Self.key) }
}
