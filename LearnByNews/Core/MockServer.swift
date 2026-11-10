#if DEBUG
import Foundation

/// 시뮬레이터 화면 확인용 모의 서버. 환경변수 LBN_MOCK=1 일 때만 켜진다 (simctl: SIMCTL_CHILD_LBN_MOCK=1).
/// 실제 서버 계약과 같은 모양의 JSON을 메모리에서 돌려준다. 릴리스 빌드에는 들어가지 않는다.
final class MockServer: URLProtocol {
    static var enabled: Bool { ProcessInfo.processInfo.environment["LBN_MOCK"] == "1" }

    private static var state = MockState()
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        enabled && request.url?.host == API.base.host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        // LBN_OFFLINE=1: 모든 요청이 네트워크 오류로 끝난다 (오프라인 캐시 확인용)
        if ProcessInfo.processInfo.environment["LBN_OFFLINE"] == "1" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let path = req.url?.path ?? ""
        let query = req.url?.query ?? ""
        let method = req.httpMethod ?? "GET"
        var body: [String: Any] = [:]
        if let d = req.httpBody ?? req.httpBodyStream.map({ s -> Data in
            s.open(); var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n > 0 { out.append(buf, count: n) } else { break } }
            s.close(); return out
        }), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { body = j }
        let slow = ProcessInfo.processInfo.environment["LBN_AUTOSUBMIT"] == "1" ? 8.0 : 1.5
        let delay: Double = (path.hasSuffix("/attempts") && body["skip"] == nil) ? slow : path.hasSuffix("/review") ? 2 : 0.15
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            Self.lock.lock()
            let (code, json) = Self.state.handle(method: method, path: path, query: query, body: body)
            Self.lock.unlock()
            let data = try! JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
            let res = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private let now = Date().ms
private func fb(_ grade: String, issues: [[String: String]] = [], ref: String, expr: [[String: String]] = []) -> [String: Any] {
    ["grade": grade, "issues": issues, "reference": ref, "expressions": expr]
}
private func attempt(_ tr: String, _ f: [String: Any], at: Int64) -> [String: Any] {
    ["translation": tr, "grade": f["grade"]!, "feedback": f, "created_at": at]
}

struct MockState {
    var articles: [[String: Any]] = []
    var sentences: [[String: Any]] = []
    var phrases: [[String: Any]] = []
    var reviews: [[String: Any]] = []
    var sessions: [[String: Any]] = []
    var quizResults: [[String: Any]] = []
    var logs: [[String: Any]] = []
    var bookmark: [String: Any]? = nil
    var drills: [[String: Any]] = []
    var passes: [String: [String]] = [:]
    var sessionStart: Int64? = nil
    var highlights: [[String: Any]] = []
    var seq = 100

    init() {
        let h = now - 3_600_000
        articles = [
            ["id": "a1", "title": "Fed holds rates steady as inflation cools", "source": "https://example.com/fed", "created_at": now - 86_400_000],
            ["id": "a2", "title": "Seoul to expand bike lanes along Han River", "source": "", "created_at": now - 3 * 86_400_000],
        ]
        let f1 = fb("B", issues: [["source": "held rates steady", "mine": "금리를 유지했다", "meaning": "금리를 동결했다", "why": "경제 기사에서는 '동결'이 관용 표현"]],
                    ref: "연준은 수요일 기준금리를 동결하며 물가 상승세가 계속 둔화하고 있다고 밝혔다.",
                    expr: [["phrase": "hold rates steady", "meaning": "금리를 동결하다"], ["phrase": "cool", "meaning": "(물가 등이) 둔화하다"]])
        let f2 = fb("A", ref: "파월 의장은 위원회가 서두르지 않는다고 말했다.", expr: [["phrase": "in no hurry", "meaning": "서두르지 않는"]])
        let f3 = fb("D", issues: [["source": "weighed on", "mine": "무게를 실었다", "meaning": "부담을 주었다", "why": "weigh on은 압박·부담의 뜻"]],
                    ref: "높은 차입 비용은 주택 시장에 부담을 주었다.", expr: [["phrase": "weigh on", "meaning": "~에 부담을 주다"]])
        sentences = [
            ["id": "s1", "article_id": "a1", "idx": 0, "paragraph": 0, "text": "The Federal Reserve held rates steady on Wednesday, saying inflation continued to cool.",
             "attempt": attempt("연준은 수요일 금리를 유지했다, 물가가 계속 식고 있다고 말하면서.", f1, at: h), "history": []],
            ["id": "s2", "article_id": "a1", "idx": 1, "paragraph": 0, "text": "Chair Powell said the committee was in no hurry.",
             "attempt": attempt("파월 의장은 위원회가 서두르지 않는다고 말했다.", f2, at: h + 60_000),
             "history": [attempt("파월은 위원회가 급하지 않다고 했다.", fb("C", ref: "파월 의장은 위원회가 서두르지 않는다고 말했다."), at: h - 86_400_000)]],
            ["id": "s3", "article_id": "a1", "idx": 2, "paragraph": 1, "text": "Higher borrowing costs have weighed on the housing market.",
             "attempt": attempt("높은 차입 비용이 주택 시장에 무게를 실었다.", f3, at: h + 120_000), "history": []],
            ["id": "s4", "article_id": "a1", "idx": 3, "paragraph": 1, "text": "Mortgage applications fell for a third straight week, according to the Mortgage Bankers Association.",
             "attempt": attempt("", fb("skip", ref: ""), at: h + 130_000), "history": []],
            ["id": "s5", "article_id": "a1", "idx": 4, "paragraph": 1, "text": "Analysts expect a cut by Dec. 15 if the labor market softens further.", "attempt": NSNull(), "history": []],
            ["id": "s6", "article_id": "a1", "idx": 5, "paragraph": 2, "text": "Markets rose modestly after the announcement.", "attempt": NSNull(), "history": []],
            ["id": "s7", "article_id": "a2", "idx": 0, "paragraph": 0, "text": "Seoul will add 40 km of bike lanes along the Han River by 2027.",
             "attempt": attempt("서울시는 2027년까지 한강을 따라 자전거 도로 40km를 추가한다.", fb("A", ref: "서울시는 2027년까지 한강변 자전거도로 40km를 늘린다.", expr: [["phrase": "add ~ km of", "meaning": "~km를 늘리다"]]), at: now - 600_000),
             "history": [attempt("서울은 2027년까지 한강 자전거길 40km를 더한다.", fb("B", ref: "서울시는 2027년까지 한강변 자전거도로 40km를 늘린다."), at: now - 2 * 86_400_000)]],
            ["id": "s8", "article_id": "a2", "idx": 1, "paragraph": 0, "text": "The city said the plan would ease congestion on weekends.",
             "attempt": attempt("시는 이 계획이 주말 혼잡을 완화할 것이라고 말했다.", fb("B", issues: [["source": "ease congestion", "mine": "혼잡을 완화할", "meaning": "혼잡을 덜어 줄", "why": "자연스러운 어감"]], ref: "시는 이 계획이 주말 혼잡을 덜어 줄 것이라고 밝혔다."), at: now - 2 * 86_400_000 + 90_000), "history": []],
        ]
        phrases = [
            ["id": "p1", "phrase": "hold rates steady", "meaning": "금리를 동결하다", "sentence_id": "s1", "article_id": "a1", "created_at": h, "sentence_text": sentences[0]["text"]!, "article_title": articles[0]["title"]!],
            ["id": "p2", "phrase": "add ~ km of", "meaning": "~km를 늘리다", "sentence_id": "s7", "article_id": "a2", "created_at": now - 2 * 86_400_000, "sentence_text": sentences[6]["text"]!, "article_title": articles[1]["title"]!],
        ]
        reviews = [["id": "r1", "article_id": "a2", "score": 90, "created_at": now - 2 * 86_400_000 + 200_000,
                    "summary": "짧은 기사였지만 두 문장 모두 뜻을 정확히 옮겼다.", "patterns": [["title": "어감", "detail": "'완화하다'보다 '덜어 주다'처럼 우리말다운 표현을 고르면 좋다."]], "praise": "숫자와 단위를 빠뜨리지 않은 점이 좋다."]]
        sessions = [["id": "ss1", "started_at": now - 2 * 86_400_000 - 300_000, "ended_at": now - 2 * 86_400_000 + 90_000, "attempts": 2, "score": 90, "articles": ["Seoul to expand bike lanes along Han River"], "created_at": now - 2 * 86_400_000 + 100_000]]
        bookmark = ["article_id": "a1", "sentence_id": "s3", "round": NSNull(), "created_at": now - 1000]
        passes = ["a2": ["s7"]]   // 서버에 저장된 다시 쓰기 진행(2회차 1/2)
        highlights = [["id": "h1", "sentence_id": "s1", "article_id": "a1", "start_word": 3, "end_word": 5, "span": "held rates steady",
                       "answer": ["meaning": "금리를 동결했다", "why": "hold steady = 변동 없이 유지", "similar": "kept rates unchanged"], "created_at": h]]
        quizResults = [["id": "q1", "key": "s8|ease congestion", "source": "ease congestion", "correct": false, "created_at": now - 86_400_000, "kind": "issue"]]
    }

    private mutating func nextId(_ p: String) -> String { seq += 1; return "\(p)\(seq)" }
    private func sents(of aid: String) -> [[String: Any]] { sentences.filter { $0["article_id"] as? String == aid }.sorted { ($0["idx"] as! Int) < ($1["idx"] as! Int) } }

    mutating func handle(method: String, path: String, query: String, body: [String: Any]) -> (Int, Any) {
        let known: Set<String> = ["api", "auth", "articles", "sentences", "phrases", "quiz", "results", "sessions", "log", "logs", "review", "attempts", "merge", "export", "bookmark", "ask", "highlights", "drills", "next", "answer", "pass", "session-start"]
        let parts = path.split(separator: "/").map(String.init)   // ["api", ...]
        let id = parts.first { !known.contains($0) } ?? ""
        let route = method + " /" + parts.map { known.contains($0) ? $0 : ":id" }.joined(separator: "/")
        switch route {
        case "GET /api/auth": return (200, ["ok": true])
        case "GET /api/articles":
            return (200, articles.sorted { ($0["created_at"] as! Int64) > ($1["created_at"] as! Int64) }.map { a -> [String: Any] in
                let ss = sents(of: a["id"] as! String)
                var g: [String: Int] = [:]
                for s in ss { if let at = s["attempt"] as? [String: Any], let gr = at["grade"] as? String { g[gr, default: 0] += 1 } }
                var o = a; o["sentence_count"] = ss.count; o["done_count"] = g.values.reduce(0, +); o["grades"] = g
                o["review_count"] = reviews.filter { $0["article_id"] as? String == a["id"] as? String }.count
                o["pass_done"] = passes[a["id"] as! String] ?? NSNull()
                return o
            })
        case "POST /api/articles":
            let id = nextId("a")
            articles.append(["id": id, "title": body["title"] ?? "", "source": body["source"] ?? "", "created_at": Date().ms])
            for (i, s) in ((body["sentences"] as? [[String: Any]]) ?? []).enumerated() {
                sentences.append(["id": nextId("s"), "article_id": id, "idx": i, "paragraph": s["paragraph"] ?? 0, "text": s["text"] ?? "", "attempt": NSNull(), "history": []])
            }
            return (200, ["id": id])
        case "GET /api/articles/:id":
            guard var a = articles.first(where: { $0["id"] as? String == id }) else { return (404, ["error": "없는 공책"]) }
            a["sentences"] = sents(of: id)
            a["phrases"] = phrases.filter { $0["article_id"] as? String == id }
            a["reviews"] = reviews.filter { $0["article_id"] as? String == id }.sorted { ($0["created_at"] as! Int64) > ($1["created_at"] as! Int64) }
            a["highlights"] = highlights.filter { $0["article_id"] as? String == id }
            return (200, a)
        case "PATCH /api/articles/:id":
            if let i = articles.firstIndex(where: { $0["id"] as? String == id }) { for (k, v) in body { articles[i][k] = v } }
            return (200, ["ok": true])
        case "DELETE /api/articles/:id":
            articles.removeAll { $0["id"] as? String == id }; sentences.removeAll { $0["article_id"] as? String == id }
            return (200, ["ok": true])
        case "POST /api/articles/:id/review":
            let r: [String: Any] = ["id": nextId("r"), "article_id": id, "score": body["score"] ?? NSNull(), "created_at": Date().ms,
                                    "summary": "전체적으로 뜻은 잘 잡았다. 관용 표현을 직역하는 버릇만 고치면 된다.",
                                    "patterns": [["title": "관용구 직역", "detail": "weigh on, hold steady 같은 구는 사전 뜻보다 기사에서 쓰는 우리말 표현을 찾자."], ["title": "분사구문", "detail": "saying ~ 은 '~라고 말하며'로 앞 절에 붙인다."]],
                                    "praise": "숫자·고유명사를 정확히 옮겼다."]
            reviews.append(r); return (200, r)
        case "POST /api/sentences/:id/attempts":
            guard let i = sentences.firstIndex(where: { $0["id"] as? String == id }) else { return (404, ["error": "없는 문장"]) }
            let at = Date().ms
            let tr = body["translation"] as? String ?? ""
            let f: [String: Any]
            if body["skip"] != nil { f = fb("skip", ref: "") }
            else if tr.count < 6 { f = fb("D", issues: [["source": sentences[i]["text"] as! String, "mine": tr, "meaning": "문장 전체", "why": "너무 짧다"]], ref: "(참고 번역)") }
            else { f = fb(["A", "B", "C"][seq % 3], issues: seq % 3 == 0 ? [] : [["source": "modestly", "mine": String(tr.prefix(4)), "meaning": "소폭", "why": "정도 부사"]], ref: "(참고 번역) " + tr, expr: [["phrase": "rise modestly", "meaning": "소폭 오르다"]]) }
            seq += 1
            var hist = sentences[i]["history"] as? [[String: Any]] ?? []
            if let prev = sentences[i]["attempt"] as? [String: Any] { hist.append(prev) }
            sentences[i]["history"] = hist
            sentences[i]["attempt"] = attempt(tr, f, at: at)
            // 첨삭 표현은 서버가 표현장에 저장하고 새로 저장된 것을 돌려준다 (같은 문장·같은 표현은 한 번만)
            var saved: [[String: Any]] = []
            let a = articles.first { $0["id"] as? String == sentences[i]["article_id"] as? String }
            for e in (f["expressions"] as? [[String: String]]) ?? [] {
                if phrases.contains(where: { $0["sentence_id"] as? String == id && $0["phrase"] as? String == e["phrase"] }) { continue }
                let p: [String: Any] = ["id": nextId("p"), "phrase": e["phrase"]!, "meaning": e["meaning"]!, "sentence_id": id, "article_id": sentences[i]["article_id"]!, "created_at": at, "sentence_text": sentences[i]["text"]!, "article_title": a?["title"] ?? ""]
                phrases.append(p); saved.append(p)
            }
            var out = f; out["translation"] = tr; out["created_at"] = at; out["phrases"] = saved
            return (200, out)
        case "POST /api/sentences/:id/merge":
            guard let i = sentences.firstIndex(where: { $0["id"] as? String == id }) else { return (404, ["error": "없는 문장"]) }
            let aid = sentences[i]["article_id"] as! String
            let ss = sents(of: aid); let pos = ss.firstIndex { $0["id"] as? String == id }!
            let dir = body["dir"] as? String ?? "prev"
            let otherPos = dir == "prev" ? pos - 1 : pos + 1
            guard ss.indices.contains(otherPos) else { return (400, ["error": "붙일 문장이 없습니다"]) }
            let keep = dir == "prev" ? ss[otherPos] : ss[pos]; let drop = dir == "prev" ? ss[pos] : ss[otherPos]
            let text = (keep["text"] as! String) + " " + (drop["text"] as! String)
            let ki = sentences.firstIndex { $0["id"] as? String == keep["id"] as? String }!
            sentences[ki]["text"] = text; sentences[ki]["attempt"] = NSNull(); sentences[ki]["history"] = []
            sentences.removeAll { $0["id"] as? String == drop["id"] as? String }
            for (n, s) in sents(of: aid).enumerated() { let j = sentences.firstIndex { $0["id"] as? String == s["id"] as? String }!; sentences[j]["idx"] = n }
            return (200, ["ok": true, "kept": keep["id"]!, "text": text])
        case "DELETE /api/attempts/:id":
            return (200, ["ok": true, "removed": true])
        case "DELETE /api/sentences/:id":
            sentences.removeAll { $0["id"] as? String == id }; return (200, ["ok": true])
        case "GET /api/phrases":
            let q = query.split(separator: "=").dropFirst().joined().removingPercentEncoding?.lowercased() ?? ""
            return (200, phrases.filter { q.isEmpty || ($0["phrase"] as! String).lowercased().contains(q) || ($0["meaning"] as! String).lowercased().contains(q) }.reversed() as [[String: Any]])
        case "POST /api/phrases":
            let sid = body["sentence_id"] as? String ?? ""
            let s = sentences.first { $0["id"] as? String == sid }
            let a = articles.first { $0["id"] as? String == body["article_id"] as? String }
            let p: [String: Any] = ["id": nextId("p"), "phrase": body["phrase"] ?? "", "meaning": body["meaning"] ?? "", "sentence_id": sid, "article_id": body["article_id"] ?? "", "created_at": Date().ms, "sentence_text": s?["text"] ?? "", "article_title": a?["title"] ?? ""]
            phrases.append(p); return (200, p)
        case "DELETE /api/phrases/:id":
            phrases.removeAll { $0["id"] as? String == id }; return (200, ["ok": true])
        case "GET /api/quiz":
            var items: [[String: Any]] = []
            var last: [String: (Bool, Int64, Int, Int)] = [:]
            for r in quizResults { let k = r["key"] as! String; let p = last[k]; let c = r["correct"] as! Bool; last[k] = (c, r["created_at"] as! Int64, (p?.2 ?? 0) + 1, (p?.3 ?? 0) + (c ? 0 : 1)) }
            for s in sentences {
                guard let at = s["attempt"] as? [String: Any], let f = at["feedback"] as? [String: Any], at["grade"] as? String != "skip" else { continue }
                let a = articles.first { $0["id"] as? String == s["article_id"] as? String }
                for iss in (f["issues"] as? [[String: String]]) ?? [] {
                    let key = "\(s["id"]!)|\(iss["source"]!)"; let l = last[key]
                    items.append(["key": key, "kind": "issue", "sentence_id": s["id"]!, "article_id": s["article_id"]!, "article_title": a?["title"] ?? "", "sentence_idx": s["idx"]!, "sentence_text": s["text"]!,
                                  "source": iss["source"]!, "mine": iss["mine"]!, "meaning": iss["meaning"]!, "why": iss["why"]!, "issued_at": at["created_at"]!,
                                  "last_correct": l.map { $0.0 } ?? NSNull(), "last_at": l.map { $0.1 } ?? NSNull(), "tries": l?.2 ?? 0, "wrong": l?.3 ?? 0])
                }
            }
            for p in phrases {
                let key = "\(p["sentence_id"]!)|\(p["phrase"]!)"; let l = last[key]
                let s = sentences.first { $0["id"] as? String == p["sentence_id"] as? String }
                items.append(["key": key, "kind": "phrase", "sentence_id": p["sentence_id"]!, "article_id": p["article_id"]!, "article_title": p["article_title"]!, "sentence_idx": s?["idx"] ?? 0, "sentence_text": s?["text"] ?? "",
                              "source": p["phrase"]!, "mine": "", "meaning": p["meaning"]!, "why": "", "issued_at": p["created_at"]!,
                              "last_correct": l.map { $0.0 } ?? NSNull(), "last_at": l.map { $0.1 } ?? NSNull(), "tries": l?.2 ?? 0, "wrong": l?.3 ?? 0])
            }
            for h in highlights {
                let key = "h|\(h["id"]!)"; let l = last[key]
                let s = sentences.first { $0["id"] as? String == h["sentence_id"] as? String }
                let a = articles.first { $0["id"] as? String == h["article_id"] as? String }
                let ans = h["answer"] as! [String: Any]
                items.append(["key": key, "kind": "highlight", "sentence_id": h["sentence_id"]!, "article_id": h["article_id"]!, "article_title": a?["title"] ?? "", "sentence_idx": s?["idx"] ?? 0, "sentence_text": s?["text"] ?? "",
                              "source": h["span"]!, "mine": "", "meaning": ans["meaning"]!, "why": ans["why"]!, "issued_at": h["created_at"]!,
                              "last_correct": l.map { $0.0 } ?? NSNull(), "last_at": l.map { $0.1 } ?? NSNull(), "tries": l?.2 ?? 0, "wrong": l?.3 ?? 0])
            }
            return (200, items)
        case "POST /api/quiz/results":
            quizResults.append(["id": nextId("q"), "key": body["key"] ?? "", "source": body["source"] ?? "", "correct": body["correct"] ?? false, "created_at": Date().ms, "kind": (body["key"] as? String ?? "").contains("|") ? "issue" : "phrase"])
            return (200, ["ok": true])
        case "GET /api/sessions":
            return (200, sessions.sorted { ($0["started_at"] as! Int64) > ($1["started_at"] as! Int64) })
        case "POST /api/sessions":
            let start = (body["started_at"] as? NSNumber)?.int64Value ?? 0
            let done = sentences.compactMap { s -> (Int64, String, String)? in
                guard let at = s["attempt"] as? [String: Any], let t = at["created_at"] as? Int64, t >= start else { return nil }
                return (t, at["grade"] as! String, s["article_id"] as! String)
            }
            guard !done.isEmpty else { return (400, ["error": "시작 이후 채점한 문장이 없습니다"]) }
            let pts: [String: Int] = ["A": 100, "B": 80, "C": 50, "D": 20]
            let g = done.compactMap { pts[$0.1] }
            let titles = Array(Set(done.map { $0.2 })).compactMap { id in articles.first { $0["id"] as? String == id }?["title"] as? String }
            let s: [String: Any] = ["id": nextId("ss"), "started_at": start, "ended_at": done.map(\.0).max()!, "attempts": done.count, "score": g.isEmpty ? NSNull() : Int((Double(g.reduce(0, +)) / Double(g.count)).rounded()), "articles": titles, "created_at": Date().ms]
            sessions.append(s); return (200, s)
        case "DELETE /api/sessions/:id":
            sessions.removeAll { $0["id"] as? String == id }; return (200, ["ok": true])
        case "GET /api/log":
            var attempts: [[String: Any]] = []
            for s in sentences {
                let a = articles.first { $0["id"] as? String == s["article_id"] as? String }
                let all = ((s["history"] as? [[String: Any]]) ?? []) + [s["attempt"] as? [String: Any]].compactMap { $0 }
                for at in all {
                    attempts.append(["id": "\(s["id"]!)-\(at["created_at"]!)", "sentence_id": s["id"]!, "article_id": s["article_id"]!, "translation": at["translation"]!, "grade": at["grade"]!, "created_at": at["created_at"]!, "idx": s["idx"]!, "text": s["text"]!, "title": a?["title"] ?? ""])
                }
            }
            attempts.sort { ($0["created_at"] as! Int64) < ($1["created_at"] as! Int64) }
            let revs = reviews.map { r -> [String: Any] in
                let a = articles.first { $0["id"] as? String == r["article_id"] as? String }
                return ["id": r["id"]!, "article_id": r["article_id"]!, "title": a?["title"] ?? "", "score": r["score"]!, "created_at": r["created_at"]!, "summary": r["summary"]!]
            }
            return (200, ["since": now - 60 * 86_400_000, "attempts": attempts, "sessions": sessions, "reviews": revs, "quiz": quizResults])
        case "GET /api/articles/:id/pass":
            return (200, passes[id].map { ["done": $0, "updated_at": Date().ms] as [String: Any] } ?? NSNull())
        case "PUT /api/articles/:id/pass":
            passes[id] = body["done"] as? [String] ?? []; return (200, ["ok": true])
        case "DELETE /api/articles/:id/pass":
            passes[id] = nil; return (200, ["ok": true])
        case "GET /api/session-start":
            return (200, sessionStart.map { ["started_at": $0] as [String: Any] } ?? NSNull())
        case "PUT /api/session-start":
            sessionStart = (body["started_at"] as? NSNumber)?.int64Value; return (200, ["ok": true])
        case "DELETE /api/session-start":
            sessionStart = nil; return (200, ["ok": true])
        case "POST /api/drills/next":
            if let open = drills.last(where: { $0["feedback"] is NSNull }), body["phrase_id"] == nil { return (200, open) }
            let p = phrases.first { $0["id"] as? String == body["phrase_id"] as? String } ?? phrases.randomElement()
            guard let p else { return (400, ["error": "표현장이 비어 있습니다"]) }
            let d: [String: Any] = ["id": nextId("d"), "phrase_id": p["id"]!, "phrase": p["phrase"]!, "meaning": p["meaning"]!,
                                    "korean": "(모의) '\(p["meaning"]!)'를 써서 한 문장을 영어로 옮겨 보자.", "created_at": Date().ms,
                                    "answer": NSNull(), "grade": NSNull(), "feedback": NSNull(), "answered_at": NSNull()]
            drills.append(d); return (200, d)
        case "POST /api/drills/:id/answer":
            guard let i = drills.firstIndex(where: { $0["id"] as? String == id }) else { return (404, ["error": "없는 문제"]) }
            let a = body["answer"] as? String ?? ""
            let used = a.lowercased().contains((drills[i]["phrase"] as! String).lowercased().split(separator: " ").first.map(String.init) ?? "")
            drills[i]["answer"] = a; drills[i]["grade"] = used ? "B" : "C"; drills[i]["answered_at"] = Date().ms
            let ref = "(모의 참고 영문) " + a
            drills[i]["feedback"] = ["grade": used ? "B" : "C", "used_expression": used, "issues": [["mine": String(a.prefix(6)), "better": "(better)", "why": "관사·시제"]],
                                     "reference": ref, "note": used ? "표현은 잘 썼다." : "표현을 꼭 넣어 보자."] as [String: Any]
            drills[i]["reference"] = ref
            return (200, drills[i])
        case "DELETE /api/drills/:id":
            drills.removeAll { $0["id"] as? String == id }; return (200, ["ok": true])
        case "GET /api/drills":
            return (200, drills.filter { !($0["feedback"] is NSNull) }.reversed() as [[String: Any]])
        case "POST /api/sentences/:id/ask":
            guard let sent = sentences.first(where: { $0["id"] as? String == id }) else { return (404, ["error": "없는 문장"]) }
            let span = body["span"] as? String ?? ""
            let h: [String: Any] = ["id": nextId("h"), "sentence_id": id, "article_id": sent["article_id"]!, "start_word": body["start_word"] ?? 0, "end_word": body["end_word"] ?? 0, "span": span,
                                    "answer": ["meaning": "(모의) \(span)의 뜻", "why": "문맥상 이런 뜻", "similar": "similar phrase"], "created_at": Date().ms]
            highlights.append(h)
            let a = articles.first { $0["id"] as? String == sent["article_id"] as? String }
            let p: [String: Any] = ["id": nextId("p"), "phrase": span, "meaning": "(모의) \(span)의 뜻", "sentence_id": id, "article_id": sent["article_id"]!, "created_at": Date().ms, "sentence_text": sent["text"]!, "article_title": a?["title"] ?? ""]
            phrases.append(p)
            var out = h; out["phrase"] = p
            return (200, out)
        case "DELETE /api/highlights/:id":
            highlights.removeAll { $0["id"] as? String == id }; return (200, ["ok": true])
        case "GET /api/bookmark":
            guard let b = bookmark, let s = sentences.first(where: { $0["id"] as? String == b["sentence_id"] as? String }) else { return (200, NSNull()) }
            let a = articles.first { $0["id"] as? String == b["article_id"] as? String }
            var o = b; o["article_title"] = a?["title"] ?? ""; o["sentence_idx"] = s["idx"]!; o["sentence_text"] = s["text"]!
            return (200, o)
        case "PUT /api/bookmark":
            bookmark = ["article_id": body["article_id"] ?? "", "sentence_id": body["sentence_id"] ?? "", "round": body["round"] ?? NSNull(), "created_at": Date().ms]
            return (200, ["ok": true])
        case "DELETE /api/bookmark":
            bookmark = nil; return (200, ["ok": true])
        case "GET /api/export":
            let since = Int64(query.split(separator: "=").dropFirst().joined()) ?? 0
            var attempts: [[String: Any]] = []
            for s in sentences {
                let all = ((s["history"] as? [[String: Any]]) ?? []) + [s["attempt"] as? [String: Any]].compactMap { $0 }
                for at in all where (at["created_at"] as! Int64) > since {
                    attempts.append(["id": "\(s["id"]!)-\(at["created_at"]!)", "sentence_id": s["id"]!, "article_id": s["article_id"]!, "translation": at["translation"]!, "grade": at["grade"]!, "feedback": at["feedback"]!, "created_at": at["created_at"]!])
                }
            }
            let revs = reviews.filter { ($0["created_at"] as! Int64) > since }.map { r -> [String: Any] in
                ["id": r["id"]!, "article_id": r["article_id"]!, "score": r["score"]!, "created_at": r["created_at"]!, "review": ["summary": r["summary"]!, "patterns": r["patterns"]!, "praise": r["praise"]!]]
            }
            return (200, ["exported_at": Date().ms, "since": since,
                          "articles": articles.map { a in var o = a; o["sentence_count"] = sents(of: a["id"] as! String).count; o["done_count"] = 0; return o },
                          "sentences": sentences.map { ["id": $0["id"]!, "article_id": $0["article_id"]!, "idx": $0["idx"]!, "paragraph": $0["paragraph"]!, "text": $0["text"]!] },
                          "attempts": attempts,
                          "phrases": phrases.filter { ($0["created_at"] as! Int64) > since },
                          "reviews": revs,
                          "quiz_results": quizResults.filter { ($0["created_at"] as! Int64) > since }.map { ["id": $0["id"]!, "key": $0["key"]!, "sentence_id": "", "source": $0["source"]!, "correct": ($0["correct"] as! Bool) ? 1 : 0, "created_at": $0["created_at"]!] },
                          "sessions": sessions.filter { ($0["created_at"] as! Int64) > since },
                          "highlights": highlights.filter { ($0["created_at"] as! Int64) > since },
                          "bookmark": bookmark ?? NSNull()])
        case "POST /api/logs":
            let n = (body["entries"] as? [Any])?.count ?? 0
            return (200, ["ok": true, "saved": n])
        default:
            return (404, ["error": "not found: \(method) \(path)"])
        }
    }
}
#endif
