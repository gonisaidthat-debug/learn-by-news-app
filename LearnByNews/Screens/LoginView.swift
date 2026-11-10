import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthModel
    @State private var pw = ""
    @State private var err: String?
    @State private var busy = false
    @State private var hidden = false   // SecureField는 한글 조합 입력을 막아서 일반 TextField + 가리기 토글
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.desk.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("Learn by News").font(Theme.hand(34)).foregroundStyle(Theme.ink).padding(.bottom, 10)
                HStack(spacing: 8) {
                    TextField("비밀번호", text: $pw)
                        .keyboardType(.default)            // 한글 비밀번호 허용
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                        .foregroundStyle(hidden ? .clear : Theme.ink)
                        .overlay(alignment: .leading) {
                            if hidden, !pw.isEmpty { Text(String(repeating: "•", count: pw.count)).foregroundStyle(Theme.ink).allowsHitTesting(false) }
                        }
                    Button { hidden.toggle() } label: {
                        Image(systemName: hidden ? "eye.slash" : "eye").foregroundStyle(Theme.pencil)
                    }
                    .buttonStyle(.plain)
                }
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
        guard !busy else { return }
        // 한글 조합 중인 글자를 먼저 확정한다: 포커스를 내리면 마크된 텍스트가 커밋된 뒤 값이 읽힌다
        focused = false
        try? await Task.sleep(for: .milliseconds(80))
        let value = pw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { focused = true; return }
        busy = true; err = nil
        err = await auth.login(value)
        busy = false
        if err != nil { focused = true }
    }
}
