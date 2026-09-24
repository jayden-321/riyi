import SwiftUI

struct PasswordResetView: View {
    @Bindable var store: AppStore
    @State var email: String
    @State private var code = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var codeRequested = false
    @State private var completed = false
    @State private var busy = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("注册邮箱") {
                    TextField("邮箱", text: $email).textContentType(.emailAddress)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("发送找回验证码") { Task { await requestCode() } }
                        .disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if codeRequested && !completed {
                    Section("设置新密码") {
                        TextField("邮件中的 10 位验证码", text: $code)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        AccountSecureField(placeholder: "新密码（12–72 字节）", text: $password,
                                           contentType: .newPassword).frame(height: 36)
                        AccountSecureField(placeholder: "再次输入新密码", text: $confirmation,
                                           contentType: .newPassword).frame(height: 36)
                        Button("重置密码") { Task { await confirmReset() } }
                            .disabled(busy || code.trimmingCharacters(in: .whitespacesAndNewlines).count != 10
                                      || !(12...72).contains(password.utf8.count) || password != confirmation)
                    }
                }
                if let message { Section { Text(message).foregroundStyle(completed ? Theme.green : Color.secondary) } }
                Section {
                    Link("收不到邮件？联系日益支持", destination: URL(string: "https://health.gzqy.xyz/support")!)
                    Text("验证码 15 分钟内有效。邮件只会发往已注册的邮箱；重置成功后所有设备需要重新登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("找回密码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                if completed { ToolbarItem(placement: .confirmationAction) { Button("返回登录") { dismiss() } } }
            }
        }
    }

    private func requestCode() async {
        busy = true; defer { busy = false }
        do {
            let body = try Wire.data(["email": email.trimmingCharacters(in: .whitespacesAndNewlines)])
            _ = try await store.network.request("/v1/auth/password-reset/request", method: "POST",
                                                body: body, authenticated: false, timeout: 30)
            codeRequested = true
            message = "若邮箱已注册，稍后会收到验证码。"
        } catch { message = error.localizedDescription }
    }

    private func confirmReset() async {
        busy = true; defer { busy = false }
        do {
            let body = try Wire.data(["email": email.trimmingCharacters(in: .whitespacesAndNewlines),
                                      "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
                                      "new_password": password])
            _ = try await store.network.request("/v1/auth/password-reset/confirm", method: "POST",
                                                body: body, authenticated: false, timeout: 30)
            completed = true; password = ""; confirmation = ""; code = ""
            message = "密码已更新，请返回登录。"
        } catch { message = error.localizedDescription }
    }
}
