import SwiftUI
import LocalAuthentication

/// 로그인 상태. 웹 App.tsx의 authed + Face ID 잠금
@MainActor
final class AuthModel: ObservableObject {
    enum State { case unknown, loggedOut, locked, loggedIn }
    @Published var state: State = .unknown
    @Published var lockErr: String?
    private var backgroundedAt: Date?
    /// 백그라운드에 이보다 오래 있었으면 돌아올 때 다시 잠근다
    static let relockAfter: TimeInterval = 120

    static let biometricKey = "lbn_biometric_lock"
    /// Face ID로 잠그기 (기본 켬)
    var biometricEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.biometricKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.biometricKey); objectWillChange.send() }
    }
    static var biometricAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
    static var biometricName: String {
        let c = LAContext(); _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType { case .faceID: return "Face ID"; case .touchID: return "Touch ID"; case .opticID: return "Optic ID"; default: return "기기 암호" }
    }

    init() {
        NotificationCenter.default.addObserver(forName: .lbnUnauthorized, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state = .loggedOut }
        }
    }

    func check() async {
        Keychain.selfTest()
        API.token = Keychain.get()
        guard API.token != nil else { state = .loggedOut; return }
        if biometricEnabled && Self.biometricAvailable {
            state = .locked
            // 맥: 프롬프트를 자동으로 띄우지 않고 잠금 화면만 둔다 (버튼을 누르면 Touch ID/암호). 아이폰: Face ID 자동
            if !Self.isMac { await unlock() }
            return
        }
        await enter()
    }

    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// 저장된 비밀번호로 서버 확인 후 들어간다
    private func enter() async {
        do { try await API.shared.checkAuth(); state = .loggedIn }
        catch APIError.unauthorized { state = .loggedOut }
        catch {
            // 네트워크 실패면 비밀번호는 그대로 두고 들어간다 (화면에서 오류를 보여준다)
            state = .loggedIn
        }
    }

    /// Face ID(안 되면 기기 암호)로 본인 확인
    func unlock() async {
        guard state == .locked else { return }
        lockErr = nil
        let ctx = LAContext()
        ctx.localizedCancelTitle = "비밀번호로 들어가기"
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "저장된 비밀번호로 들어갑니다")
            if ok { AppLog.shared.info("auth", "biometric ok"); await enter() }
        } catch let e as LAError where e.code == .userCancel || e.code == .userFallback {
            // 비밀번호 직접 입력으로
            state = .loggedOut
        } catch {
            AppLog.shared.warn("auth", "biometric failed: \(error.localizedDescription)")
            lockErr = error.localizedDescription
        }
    }

    /// 백그라운드 전환 추적. 오래 비웠으면 돌아올 때 다시 잠근다
    func didEnterBackground() { backgroundedAt = Date() }
    func willEnterForeground() {
        guard state == .loggedIn, biometricEnabled, Self.biometricAvailable, let t = backgroundedAt, Date().timeIntervalSince(t) > Self.relockAfter else { return }
        backgroundedAt = nil
        state = .locked
        // 맥은 화면이 켜질 때마다 프롬프트가 뜨면 성가시다 → 잠금 화면만 보여 주고 기다린다
        if !Self.isMac { Task { await unlock() } }
    }

    /// 비밀번호로 로그인. 앞뒤 공백·개행은 잘라낸다. 값은 로그에 남기지 않고 길이만 남긴다
    func login(_ raw: String) async -> String? {
        let pw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        API.token = pw
        let saved = Keychain.set(pw)
        AppLog.shared.info("auth", "login try", ["chars": "\(pw.count)", "utf8": "\(pw.utf8.count)", "trimmed": "\(pw.count != raw.count)", "keychainSaved": "\(saved)"])
        do { try await API.shared.checkAuth(); state = .loggedIn; AppLog.shared.info("auth", "login ok"); return nil }
        catch APIError.unauthorized { API.token = nil; return "비밀번호가 틀렸습니다" }
        catch let e as APIError where e.isNetwork { API.token = nil; Keychain.delete(); AppLog.shared.error("auth", "login network failure: \(e.localizedDescription)"); return "서버에 연결할 수 없다: \(e.localizedDescription)" }
        catch { API.token = nil; Keychain.delete(); AppLog.shared.error("auth", "login failed: \(error.localizedDescription)"); return "서버 오류: \(error.localizedDescription)" }
    }

    func logout() { API.token = nil; Keychain.delete(); state = .loggedOut }
}

enum Route: Hashable {
    /// restartAfter: 처음부터 다시 쓰기 순회로 연다. 0이면 첫 문장부터, n이면 앞 n문장은 끝난 것으로 두고 n+1번째부터
    /// browse: 열람 모드(전체 문장 + 최신 번역·첨삭·이전 시도, 입력 없음). focus가 있으면 그 문장으로 스크롤
    /// round: 회차 열람(n번째 총평 시각까지의 마지막 시도로 보여준다). browse와 함께 쓴다
    case notebook(id: String, focus: String? = nil, restartAfter: Int? = nil, browse: Bool = false, round: Int? = nil)
    /// newReview: 기존 총평이 있어도 새 총평을 자동 요청한다 (처음부터 다시 쓰기가 끝났을 때)
    case done(id: String, newReview: Bool = false)
}

/// 탭·화면 이동. 시험지·기록에서 "공책에서 보기"처럼 탭을 건너 이동할 때 쓴다
@MainActor
final class Router: ObservableObject {
    enum Tab: Hashable { case shelf, phrases, quiz, drills, log }
    /// 설정은 탭이 아니라 기사 탭 오른쪽 위 톱니 → 시트 (탭이 6개면 iPhone에서 "More"로 밀린다)
    @Published var showSettings = false
    @Published var tab: Tab = .shelf
    @Published var shelfPath: [Route] = []
    /// ⌘N: 공책 목록의 붙여넣기 칸으로 포커스
    @Published var newNotebookRequest = 0

    func newNotebook() { tab = .shelf; shelfPath = []; newNotebookRequest += 1 }

    init() {
        #if DEBUG
        // 화면 확인용: LBN_ROUTE=notebook:a1 | notebook:a1:s2 | done:a2 | restart:a2 | phrases | quiz | drills | log | settings
        if ProcessInfo.processInfo.environment["LBN_SESSION"] == "1" { SessionStore.start = Date().ms - 600_000; SessionModel.shared.start = SessionStore.start }
        if let r = ProcessInfo.processInfo.environment["LBN_ROUTE"] {
            let p = r.split(separator: ":").map(String.init)
            switch p[0] {
            case "notebook": shelfPath = [.notebook(id: p[1], focus: p.count > 2 ? p[2] : nil)]
            case "done": shelfPath = [.done(id: p[1])]
            case "browse": shelfPath = [.notebook(id: p[1], browse: true, round: p.count > 2 ? Int(p[2]) : nil)]
            case "restart": shelfPath = [.notebook(id: p[1], restartAfter: Int(p.count > 2 ? p[2] : "0") ?? 0)]
            case "phrases": tab = .phrases
            case "quiz": tab = .quiz
            case "drills": tab = .drills
            case "log": tab = .log
            case "settings": showSettings = true
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
            case .locked: LockView()
            case .loggedIn: MainTabs()
            }
        }
        .task { await auth.check() }
        .onAppear { Self.applyMacWindowSize() }
        .onChange(of: auth.state) { _, st in if st == .loggedIn { Task { await SyncManager.shared.autoSync() } } }
    }

    /// 맥(Catalyst): 창 최소 크기 720×600
    static func applyMacWindowSize() {
        #if targetEnvironment(macCatalyst)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 720, height: 600)
            scene.titlebar?.titleVisibility = .hidden
        }
        #endif
    }
}

/// Face ID 확인 중 화면. 실패하면 다시 시도하거나 비밀번호로.
struct LockView: View {
    @EnvironmentObject var auth: AuthModel
    var body: some View {
        ZStack {
            Theme.desk.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Learn by News").font(Theme.hand(34)).foregroundStyle(Theme.ink)
                Image(systemName: "faceid").font(.system(size: 44)).foregroundStyle(Theme.pencil)
                if let e = auth.lockErr { ErrorText(message: e) }
                Tiny(title: "\(AuthModel.biometricName)로 열기", color: Theme.red, size: 24) { Task { await auth.unlock() } }
                    .keyboardShortcut(.defaultAction)   // 맥: Enter로도 연다
                Tiny(title: "비밀번호로 들어가기", size: 20) { auth.state = .loggedOut }
            }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var router: Router
    var body: some View {
        TabView(selection: $router.tab) {
            ShelfView().tabItem { Label("기사", systemImage: "book.closed") }.tag(Router.Tab.shelf)
            PhrasesView().tabItem { Label("표현장", systemImage: "note.text") }.tag(Router.Tab.phrases)
            QuizView().tabItem { Label("시험지", systemImage: "questionmark.square") }.tag(Router.Tab.quiz)
            DrillsView().tabItem { Label("응용", systemImage: "pencil.and.outline") }.tag(Router.Tab.drills)
            ActivityLogView().tabItem { Label("기록", systemImage: "calendar") }.tag(Router.Tab.log)
        }
        .tint(Theme.red)
        .sheet(isPresented: $router.showSettings) { SettingsView() }
    }
}
