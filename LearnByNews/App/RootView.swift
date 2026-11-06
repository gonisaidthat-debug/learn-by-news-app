import SwiftUI

/// 로그인 상태. 웹 App.tsx의 authed
@MainActor
final class AuthModel: ObservableObject {
    enum State { case unknown, loggedOut, loggedIn }
    @Published var state: State = .unknown

    init() {
        NotificationCenter.default.addObserver(forName: .lbnUnauthorized, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state = .loggedOut }
        }
    }

    func check() async {
        guard Keychain.get() != nil else { state = .loggedOut; return }
        do { try await API.shared.checkAuth(); state = .loggedIn }
        catch APIError.unauthorized { state = .loggedOut }
        catch {
            // 네트워크 실패면 비밀번호는 그대로 두고 들어간다 (화면에서 오류를 보여준다)
            state = .loggedIn
        }
    }

    func login(_ pw: String) async -> String? {
        Keychain.set(pw)
        do { try await API.shared.checkAuth(); state = .loggedIn; AppLog.shared.info("auth", "login ok"); return nil }
        catch APIError.unauthorized { return "비밀번호가 틀렸습니다" }
        catch { return error.localizedDescription }
    }

    func logout() { Keychain.delete(); state = .loggedOut }
}

enum Route: Hashable {
    case notebook(id: String, focus: String? = nil)
    case done(id: String)
}

/// 탭·화면 이동. 시험지·기록에서 "공책에서 보기"처럼 탭을 건너 이동할 때 쓴다
@MainActor
final class Router: ObservableObject {
    enum Tab: Hashable { case shelf, phrases, quiz, log, settings }
    @Published var tab: Tab = .shelf
    @Published var shelfPath: [Route] = []

    init() {
        #if DEBUG
        // 화면 확인용: LBN_ROUTE=notebook:a1 | notebook:a1:s2 | done:a2 | phrases | quiz | log | settings
        if ProcessInfo.processInfo.environment["LBN_SESSION"] == "1" { SessionStore.start = Date().ms - 600_000; SessionModel.shared.start = SessionStore.start }
        if let r = ProcessInfo.processInfo.environment["LBN_ROUTE"] {
            let p = r.split(separator: ":").map(String.init)
            switch p[0] {
            case "notebook": shelfPath = [.notebook(id: p[1], focus: p.count > 2 ? p[2] : nil)]
            case "done": shelfPath = [.done(id: p[1])]
            case "phrases": tab = .phrases
            case "quiz": tab = .quiz
            case "log": tab = .log
            case "settings": tab = .settings
            default: break
            }
        }
        #endif
    }

    func open(_ r: Route) {
        tab = .shelf
        shelfPath = [r]
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var router: Router

    var body: some View {
        Group {
            switch auth.state {
            case .unknown: Theme.desk.ignoresSafeArea()
            case .loggedOut: LoginView()
            case .loggedIn: MainTabs()
            }
        }
        .task { await auth.check() }
    }
}

struct MainTabs: View {
    @EnvironmentObject var router: Router
    var body: some View {
        TabView(selection: $router.tab) {
            ShelfView().tabItem { Label("기사", systemImage: "book.closed") }.tag(Router.Tab.shelf)
            PhrasesView().tabItem { Label("표현장", systemImage: "note.text") }.tag(Router.Tab.phrases)
            QuizView().tabItem { Label("시험지", systemImage: "questionmark.square") }.tag(Router.Tab.quiz)
            ActivityLogView().tabItem { Label("기록", systemImage: "calendar") }.tag(Router.Tab.log)
            SettingsView().tabItem { Label("설정", systemImage: "gearshape") }.tag(Router.Tab.settings)
        }
        .tint(Theme.red)
    }
}
