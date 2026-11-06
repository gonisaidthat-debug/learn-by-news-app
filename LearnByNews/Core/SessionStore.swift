import Foundation

/// 공부 세션 시작점. 웹의 localStorage(lbn_session_start) 역할. 기기 간 공유 안 됨.
enum SessionStore {
    private static let key = "lbn_session_start"
    static var start: Int64? {
        get { let v = UserDefaults.standard.object(forKey: key) as? Int64; return v == 0 ? nil : v }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
