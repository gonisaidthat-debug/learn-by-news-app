import Foundation
import Security

/// 비밀번호 보관. 웹의 localStorage(lbn_token) 역할.
/// 맥(Catalyst)에서는 데이터 보호 키체인을 먼저 쓰고, 안 되면 파일 키체인으로 떨어진다. 실패하면 상태 코드를 로그에 남긴다.
enum Keychain {
    private static let service = "com.goni.learn-by-news"
    private static let account = "app-password"

    private static func base(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if targetEnvironment(macCatalyst)
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    static func get() -> String? {
        for dp in [true, false] {
            var q = base(dataProtection: dp)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            let st = SecItemCopyMatching(q as CFDictionary, &out)
            if st == errSecSuccess, let d = out as? Data { return String(data: d, encoding: .utf8) }
            #if !targetEnvironment(macCatalyst)
            break
            #endif
        }
        return nil
    }

    /// 저장. 성공하면 true. 실패하면 상태 코드를 로그에 남긴다 (값은 남기지 않는다)
    @discardableResult
    static func set(_ value: String) -> Bool {
        delete()
        var last: OSStatus = errSecSuccess
        for dp in [true, false] {
            var q = base(dataProtection: dp)
            q[kSecValueData as String] = Data(value.utf8)
            #if targetEnvironment(macCatalyst)
            if dp { q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
            #else
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            #endif
            last = SecItemAdd(q as CFDictionary, nil)
            if last == errSecSuccess { return true }
            AppLog.shared.warn("keychain", "SecItemAdd failed", ["status": "\(last)", "dataProtection": "\(dp)"])
            #if !targetEnvironment(macCatalyst)
            break
            #endif
        }
        AppLog.shared.error("keychain", "save failed", ["status": "\(last)"])
        return false
    }

    static func delete() {
        for dp in [true, false] {
            SecItemDelete(base(dataProtection: dp) as CFDictionary)
            #if !targetEnvironment(macCatalyst)
            break
            #endif
        }
    }

    /// 시작 때 한 번: 이 환경에서 키체인 저장·읽기가 되는지 다른 계정(probe)으로 시험해 로그로 남긴다
    static func selfTest() {
        let has = get() != nil
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "probe"]
        #if targetEnvironment(macCatalyst)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = Data("x".utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(add as CFDictionary, nil)
        var read = q; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let rd = SecItemCopyMatching(read as CFDictionary, &out)
        SecItemDelete(q as CFDictionary)
        AppLog.shared.info("keychain", "startup", ["hasPassword": "\(has)", "probeAdd": "\(st)", "probeRead": "\(rd)"])
    }
}
