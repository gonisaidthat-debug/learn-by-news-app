import Foundation
import OSLog
import UIKit

/// 버그 추적용 로그. OSLog + 로컬 순환 파일(최근 2000줄, JSON Lines).
/// 기사 원문·번역 전문은 넣지 않는다(문장 id만).
final class AppLog {
    enum Level: String, Codable, CaseIterable { case debug, info, warn, error, fatal }

    struct Entry: Codable, Identifiable, Hashable {
        var level: Level
        var tag: String
        var message: String
        var context: [String: String]?
        var at: Int64
        var id: Int64 { at &* 31 &+ Int64(message.hashValue & 0xffff) }
    }

    static let shared = AppLog()
    static let maxLines = 2000
    private static let hadErrorKey = "lbn_log_had_error"
    private static let dirtyKey = "lbn_log_dirty"

    private let os = Logger(subsystem: "com.goni.learn-by-news", category: "app")
    private let queue = DispatchQueue(label: "lbn.log", qos: .utility)
    private let fileURL: URL
    private var lines: [String] = []

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("app-log.jsonl")
        if let s = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }

    // MARK: 기록

    func log(_ level: Level, _ tag: String, _ message: String, _ context: [String: String]? = nil) {
        let e = Entry(level: level, tag: tag, message: message, context: context, at: Date().ms)
        let ctx = context.map { " \($0)" } ?? ""
        switch level {
        case .debug: os.debug("[\(tag, privacy: .public)] \(message, privacy: .public)\(ctx, privacy: .public)")
        case .info: os.info("[\(tag, privacy: .public)] \(message, privacy: .public)\(ctx, privacy: .public)")
        case .warn: os.warning("[\(tag, privacy: .public)] \(message, privacy: .public)\(ctx, privacy: .public)")
        case .error: os.error("[\(tag, privacy: .public)] \(message, privacy: .public)\(ctx, privacy: .public)")
        case .fatal: os.fault("[\(tag, privacy: .public)] \(message, privacy: .public)\(ctx, privacy: .public)")
        }
        if level == .error || level == .fatal { UserDefaults.standard.set(true, forKey: Self.hadErrorKey) }
        guard let data = try? JSONEncoder().encode(e), let line = String(data: data, encoding: .utf8) else { return }
        queue.async { [self] in
            lines.append(line)
            if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
            flush()
        }
    }
    func debug(_ tag: String, _ m: String, _ c: [String: String]? = nil) { log(.debug, tag, m, c) }
    func info(_ tag: String, _ m: String, _ c: [String: String]? = nil) { log(.info, tag, m, c) }
    func warn(_ tag: String, _ m: String, _ c: [String: String]? = nil) { log(.warn, tag, m, c) }
    func error(_ tag: String, _ m: String, _ c: [String: String]? = nil) { log(.error, tag, m, c) }
    func fatal(_ tag: String, _ m: String, _ c: [String: String]? = nil) { log(.fatal, tag, m, c); queue.sync {} }

    private func flush() {
        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: 읽기·지우기

    func entries() -> [Entry] {
        queue.sync { lines.compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) } }
    }
    func clear() {
        queue.sync { lines = []; try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: 실행 상태 (비정상 종료 감지)

    /// 앱 시작 때 부른다. 직전 실행이 깨끗이 끝나지 않았거나 error/fatal이 있었으면 true.
    func beginRun() -> Bool {
        let ud = UserDefaults.standard
        let dirty = ud.bool(forKey: Self.dirtyKey)
        let hadError = ud.bool(forKey: Self.hadErrorKey)
        ud.set(true, forKey: Self.dirtyKey)
        ud.set(false, forKey: Self.hadErrorKey)
        NSSetUncaughtExceptionHandler { ex in
            AppLog.shared.fatal("crash", "uncaught exception: \(ex.name.rawValue)", ["reason": ex.reason ?? "", "stack": ex.callStackSymbols.prefix(12).joined(separator: "\n")])
        }
        info("app", "launch", ["version": Self.appVersion, "prevDirty": "\(dirty)", "prevError": "\(hadError)"])
        return dirty || hadError
    }
    /// 백그라운드로 갈 때·종료 때: 정상 종료 표시
    func markClean() {
        queue.sync { flush() }
        UserDefaults.standard.set(false, forKey: Self.dirtyKey)
    }
    func markDirty() { UserDefaults.standard.set(true, forKey: Self.dirtyKey) }

    // MARK: 서버 전송

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
    static var deviceName: String {
        let d = UIDevice.current
        return "\(d.model) iOS \(d.systemVersion)"
    }

    struct UploadBody: Encodable {
        var device: String; var appVersion: String; var entries: [Entry]
    }

    /// 최근 500개를 POST /api/logs 로 보낸다. 저장된 개수를 돌려준다.
    @discardableResult
    func upload(reason: String) async throws -> Int {
        let all = entries().suffix(500)
        guard !all.isEmpty else { return 0 }
        let r: UploadResult = try await API.shared.send("POST", "/api/logs", body: UploadBody(device: Self.deviceName, appVersion: Self.appVersion, entries: Array(all)))
        info("log", "uploaded", ["reason": reason, "saved": "\(r.saved)"])
        return r.saved
    }
    struct UploadResult: Decodable { var ok: Bool; var saved: Int }
}
