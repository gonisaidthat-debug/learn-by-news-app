import SwiftUI

/// 설정: 로그 보내기·보기·지우기, 로그아웃
struct SettingsView: View {
    @EnvironmentObject var auth: AuthModel
    @State private var msg: String?
    @State private var busy = false
    @State private var showLogs = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section("로그 (버그 추적용)") {
                    Button { Task { await upload() } } label: { Label(busy ? "보내는 중…" : "로그 보내기", systemImage: "paperplane").foregroundStyle(Theme.ink) }.disabled(busy)
                    Button { showLogs = true } label: { Label("로컬 로그 보기", systemImage: "doc.text.magnifyingglass").foregroundStyle(Theme.ink) }
                    Button(role: .destructive) { confirmClear = true } label: { Label("로컬 로그 지우기", systemImage: "trash") }
                    if let msg { Text(msg).font(.footnote).foregroundStyle(Theme.muted) }
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
