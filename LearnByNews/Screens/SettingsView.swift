import SwiftUI

/// 설정: 로그 보내기·보기·지우기, 로그아웃
struct SettingsView: View {
    @EnvironmentObject var auth: AuthModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = SyncManager.shared
    @ObservedObject private var net = Connectivity.shared
    @ObservedObject private var drills = DrillStore.shared
    @State private var drillMsg: String?
    @State private var msg: String?
    @State private var busy = false
    @State private var showLogs = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Task { await sync.sync(full: true) } } label: {
                        Label(sync.syncing ? "내려받는 중…" : "오프라인용 내려받기", systemImage: "arrow.down.circle").foregroundStyle(Theme.ink)
                    }
                    .disabled(sync.syncing || !net.isOnline)
                    HStack { Text("마지막 동기화"); Spacer(); Text(sync.lastSyncAt.map { Date(ms: $0).fullLabel } ?? "아직 없음").foregroundStyle(Theme.muted) }
                    HStack { Text("연결"); Spacer(); Text(net.isOnline ? "온라인" : "오프라인").foregroundStyle(net.isOnline ? Theme.grade(.A) : Theme.red) }
                    if sync.pendingAttempts > 0 {
                        HStack { Text("대기 중 채점"); Spacer(); Text("\(sync.pendingAttempts)개 · 연결되면 보낸다").foregroundStyle(Theme.muted) }
                    }
                    if sync.pendingCount > sync.pendingAttempts {
                        HStack { Text("보낼 것"); Spacer(); Text("\(sync.pendingCount - sync.pendingAttempts)개 대기 중").foregroundStyle(Theme.muted) }
                    }
                    if let e = sync.lastError { Text(e).font(.footnote).foregroundStyle(Theme.red) }
                    Button {
                        Task {
                            do { let n = try await drills.prefetch(count: drills.setSize); drillMsg = "\(n)문장 받아 둠" } catch { drillMsg = error.localizedDescription }
                        }
                    } label: { Label("응용 문제 미리 받기 (\(drills.setSize)문장)", systemImage: "square.and.arrow.down").foregroundStyle(Theme.ink) }
                    .disabled(!net.isOnline)
                    if drills.remainingOffline > 0 || drillMsg != nil {
                        HStack { Text("받아 둔 응용 문제"); Spacer(); Text(drillMsg ?? "\(drills.remainingOffline)문장").foregroundStyle(Theme.muted) }
                    }
                } header: { Text("오프라인") } footer: {
                    Text("공책 열람·이전 시도·총평·표현장·시험지·기록은 저장해 두고 오프라인에서도 본다. 번역 제출·건너뛰기·다시 쓰기·새 공책·포스트잇·시험 결과·책갈피는 오프라인에서도 되고, 연결되면 순서대로 보내 채점된다(채점 시각은 보낸 시각). 총평·형광펜 묻기·응용 채점은 온라인에서만. 앱을 열 때 자동으로 보내고 증분 동기화하며 하루에 한 번 전체를 다시 받는다.")
                }
                Section("로그 (버그 추적용)") {
                    Button { Task { await upload() } } label: { Label(busy ? "보내는 중…" : "로그 보내기", systemImage: "paperplane").foregroundStyle(Theme.ink) }.disabled(busy)
                    Button { showLogs = true } label: { Label("로컬 로그 보기", systemImage: "doc.text.magnifyingglass").foregroundStyle(Theme.ink) }
                    Button(role: .destructive) { confirmClear = true } label: { Label("로컬 로그 지우기", systemImage: "trash") }
                    if let msg { Text(msg).font(.footnote).foregroundStyle(Theme.muted) }
                }
                Section {
                    Toggle(isOn: Binding(get: { auth.biometricEnabled }, set: { auth.biometricEnabled = $0 })) {
                        Label("\(AuthModel.biometricName)로 잠금", systemImage: "faceid").foregroundStyle(Theme.ink)
                    }
                    .disabled(!AuthModel.biometricAvailable)
                } footer: {
                    Text("켜면 앱을 열 때 \(AuthModel.biometricName)로 확인한 뒤 저장된 비밀번호로 들어간다. \(Int(AuthModel.relockAfter / 60))분 넘게 비웠다 돌아와도 다시 확인한다.")
                }
                Section {
                    Button(role: .destructive) { auth.logout() } label: { Label("로그아웃 (비밀번호 지우기)", systemImage: "rectangle.portrait.and.arrow.right") }
                } footer: {
                    Text("Learn by News \(AppLog.appVersion) · \(AppLog.deviceName)\n서버 \(API.base.host ?? "")")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.desk.ignoresSafeArea())
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.desk, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .sheet(isPresented: $showLogs) { LocalLogView() }
            .confirmationDialog("로컬 로그를 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("지우기", role: .destructive) { AppLog.shared.clear(); msg = "지웠다" }
            }
        }
    }

    private func upload() async {
        busy = true; msg = nil
        do { let n = try await AppLog.shared.upload(reason: "manual"); msg = "보냈다 · \(n)개" }
        catch { msg = "실패: \(error.localizedDescription)" }
        busy = false
    }
}

struct LocalLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AppLog.Entry] = []
    @State private var level: AppLog.Level? = nil

    private var shown: [AppLog.Entry] {
        let xs = level.map { l in entries.filter { $0.level == l } } ?? entries
        return xs.reversed()
    }

    var body: some View {
        NavigationStack {
            List(Array(shown.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(e.level.rawValue.uppercased()).font(.caption2.bold()).foregroundStyle(color(e.level))
                        Text(e.tag).font(.caption2).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(Date(ms: e.at).fullLabel).font(.caption2).foregroundStyle(Theme.muted)
                    }
                    Text(e.message).font(.footnote)
                    if let c = e.context, !c.isEmpty {
                        Text(c.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  ")).font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("로컬 로그 \(shown.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu(level?.rawValue ?? "전부") {
                        Button("전부") { level = nil }
                        ForEach(AppLog.Level.allCases, id: \.self) { l in Button(l.rawValue) { level = l } }
                    }
                }
            }
            .onAppear { entries = AppLog.shared.entries() }
        }
    }

    private func color(_ l: AppLog.Level) -> Color {
        switch l {
        case .debug: return Theme.muted
        case .info: return Theme.blueInk
        case .warn: return Theme.grade(.B)
        case .error, .fatal: return Theme.red
        }
    }
}
