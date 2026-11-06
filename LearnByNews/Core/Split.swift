import Foundation
import NaturalLanguage

struct SplitSentence: Hashable { var paragraph: Int; var text: String }
struct SplitResult { var title: String; var source: String; var sentences: [SplitSentence] }

/// 기사 본문 → 제목·링크·문장. 웹 split.ts와 같은 규칙.
enum Split {
    private static let urlLine = "^https?://\\S+$"
    /// 마침표로 끝나지만 문장 끝이 아닌 약어들. 뒤 조각을 붙인다
    private static let abbrev = "\\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|Mr|Mrs|Ms|Dr|Jr|Sr|St|No|Nos|vs|Gov|Sen|Rep|Gen|Lt|Col|Capt|Sgt|Prof|Inc|Ltd|Co|Corp|Mt|Ft|Ave|Blvd|approx|est|etc|U\\.S|U\\.K|D\\.C|a\\.m|p\\.m|[A-Z])\\.[\"”’)]?$"

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression]) != nil
    }

    /// 분리기가 끊어 놓은 조각을 다시 붙여야 하는지
    static func shouldJoin(prev: String, next: String) -> Bool {
        if matches(prev, abbrev) { return true }          // "until Nov." + "15."
        if matches(next, "^[a-z]") { return true }         // 소문자로 시작하는 문장은 없다
        if matches(next, "^[,;:)\\]”’]") { return true }   // 구두점으로 시작하면 앞에 붙는다
        return false
    }

    static func sentences(in paragraph: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence)
        tok.setLanguage(.english)
        tok.string = paragraph
        var parts: [String] = []
        tok.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { r, _ in
            let t = paragraph[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(t) }
            return true
        }
        var joined: [String] = []
        for t in parts {
            if let last = joined.last, shouldJoin(prev: last, next: t) { joined[joined.count - 1] = last + " " + t }
            else { joined.append(t) }
        }
        return joined
    }

    /// 첫 줄 = 제목. URL만 있는 줄은 링크로 빼낸다. 나머지 줄 = 문단
    static func article(_ raw: String) -> SplitResult {
        let all = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let source = all.first { matches($0, urlLine) } ?? ""
        let lines = all.filter { !matches($0, urlLine) }
        guard let firstIdx = lines.firstIndex(where: { !$0.isEmpty }) else { return SplitResult(title: "", source: source, sentences: []) }
        let title = lines[firstIdx]
        let paragraphs = lines[(firstIdx + 1)...].filter { !$0.isEmpty }
        var out: [SplitSentence] = []
        for (pi, p) in paragraphs.enumerated() {
            for t in sentences(in: p) { out.append(SplitSentence(paragraph: pi, text: t)) }
        }
        return SplitResult(title: title, source: source, sentences: out)
    }
}
