import Foundation
import SwiftUI

/// 문장 구조 분석 (goni 2026-11-20 "문장 구조 첨삭에 대한 분석도 내가 누르면 보여 줄 수 있게").
/// `POST /api/sentences/:id/structure {force?}` 응답. 서버가 문장별로 저장해 두 번째부터는 저장본(cached true, 즉시)
struct Structure: Codable, Equatable {
    struct Chunk: Codable, Equatable { var text: String; var role: String; var note: String }
    /// 꾸밈 관계(2026-11-23): from(꾸미는 쪽) → to(받는 쪽), chunks 번호(0부터), label은 관계 이름 한 단어. 옛 분석엔 없다(→ 화살표 없음)
    /// from_group/to_group(2026-11-24, 옵셔널): groups 배열 번호(0부터, 서버 순서), 묶음이 아니면 -1, 옛 분석엔 없음. from/to는 그때도 덩어리 번호(묶음의 핵심 덩어리)
    struct Link: Codable, Equatable { var from: Int; var to: Int; var label: String; var fromGroup: Int? = nil; var toGroup: Int? = nil }
    /// 묶음 괄호(2026-11-24): chunks from…to(연속 범위, 겹침 가능, 최대 6)를 밑줄 아래 ⌊__⌋로. 분사구문 전체·관계절 전체·병렬 묶음 등
    struct Group: Codable, Equatable { var from: Int; var to: Int; var label: String }
    var skeleton: String
    var chunks: [Chunk]
    var reading: String
    var pitfalls: [String]
    var mine: String
    var links: [Link]?
    var groups: [Group]?
    var createdAt: Int64?
    var cached: Bool?
    /// 구조 상자 안 문답(2026-11-20, 오래된 순). 서버 sentence_qa
    var qa: [SentenceQA]?

    /// 역할 이름 → 색 묶음 (웹 roleKind와 같은 규칙): 주어 파랑 / 동사·술어 빨강 / 목적·보어 초록 / 접속·관계·종속·조건·시간 보라 / 나머지 회색
    static func color(_ role: String) -> Color {
        if role.contains("주어") { return Color(hex: 0x2F6FD6) }
        if role.contains("동사") || role.contains("술어") { return Theme.red }
        if role.contains("목적") || role.contains("보어") { return Color(hex: 0x2F9E44) }
        if ["접속", "관계", "종속", "조건", "시간"].contains(where: { role.contains($0) }) { return Color(hex: 0x7A3FB8) }
        return Theme.pencil
    }
}

/// 구조 상자 안 질문·답 (goni 2026-11-20 "그 컨텍스트에 대해 추가로 질문하고 답변도 볼 수 있게"). `POST /api/sentences/:id/ask {question}` 응답
struct SentenceQA: Codable, Equatable, Identifiable { var id: String; var question: String; var answer: String; var createdAt: Int64?; var marks: [String]? }

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
    /// 문답을 저장본에 더하기 / 빼기 (서버가 받아 준 뒤)
    func addQA(_ sentenceId: String, _ q: SentenceQA) { guard var s = map[sentenceId] else { return }; s.qa = (s.qa ?? []) + [q]; map[sentenceId] = s; save() }
    func setMarks(_ sentenceId: String, _ qid: String, _ marks: [String]) { guard var s = map[sentenceId], let i = s.qa?.firstIndex(where: { $0.id == qid }) else { return }; s.qa?[i].marks = marks; map[sentenceId] = s; save() }
    func removeQA(_ sentenceId: String, _ qid: String) { guard var s = map[sentenceId] else { return }; s.qa = (s.qa ?? []).filter { $0.id != qid }; map[sentenceId] = s; save() }
    private func save() { UserDefaults.standard.set(try? JSONEncoder.api.encode(map), forKey: Self.key) }
}
