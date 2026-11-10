import SwiftUI

@main
struct LearnByNewsApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var auth = AuthModel()
    @StateObject private var router = Router()

    init() {
        #if DEBUG
        if MockServer.enabled { Keychain.set("mock"); UserDefaults.standard.set(false, forKey: AuthModel.biometricKey) }
        #endif
        let needUpload = AppLog.shared.beginRun()
        if needUpload {
            Task {
                // 비밀번호가 없으면 못 보낸다. 다음 로그인 뒤 다시 시도하지 않고 다음 실행에 맡긴다.
                guard Keychain.get() != nil else { AppLog.shared.markDirty(); return }
                do { try await AppLog.shared.upload(reason: "auto") }
                catch { AppLog.shared.warn("log", "auto upload failed: \(error.localizedDescription)") }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(router)
                .onChange(of: phase) { _, p in
                    switch p {
                    case .background: AppLog.shared.markClean(); auth.didEnterBackground()
                    case .active: AppLog.shared.markDirty(); auth.willEnterForeground(); RootView.applyMacWindowSize()
                    default: break
                    }
                }
        }
        .commands {
            // 맥 메뉴바: 파일 > 새 공책 (⌘N). Enter 제출·Esc 취소는 화면 안에서 처리
            CommandGroup(replacing: .newItem) {
                Button("새 공책") { router.newNotebook() }.keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
