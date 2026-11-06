import SwiftUI
struct SettingsView: View {
    @EnvironmentObject var auth: AuthModel
    var body: some View { Button("로그아웃") { auth.logout() } }
}
