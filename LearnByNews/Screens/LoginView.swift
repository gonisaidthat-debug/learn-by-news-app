import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthModel
    @State private var pw = ""
    @State private var err: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.desk.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("Learn by News").font(Theme.hand(34)).foregroundStyle(Theme.ink).padding(.bottom, 10)
                SecureField("비밀번호", text: $pw)
                    .textContentType(.password)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xD6CFC0)))
                Button { Task { await submit() } } label: {
                    Text(busy ? "확인 중…" : "들어가기")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(10)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Theme.paper)
                }
                .disabled(busy || pw.isEmpty)
                .opacity(busy || pw.isEmpty ? 0.45 : 1)
                if let err { ErrorText(message: err) }
                if Keychain.get() != nil, auth.biometricEnabled, AuthModel.biometricAvailable {
                    Tiny(title: "\(AuthModel.biometricName)로 열기", size: 20) { auth.state = .locked; Task { await auth.unlock() } }.padding(.top, 6)
                }
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 16)
        }
        .onAppear { focused = true }
    }

    private func submit() async {
        guard !pw.isEmpty, !busy else { return }
        busy = true; err = nil
        err = await auth.login(pw)
        busy = false
    }
}
