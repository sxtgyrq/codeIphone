import SwiftUI

@MainActor
struct MapLoginView: View {
    @ObservedObject var model: MapViewModel
    @State private var password = ""
    @FocusState private var focusedField: Field?
    private enum Field { case server, user, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 38)).foregroundStyle(.indigo)
                        Text("让逻辑，随手可见").font(.largeTitle.bold())
                        Text("连接电脑上的 Argument Map，浏览同一张逻辑地图。")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("服务器地址").font(.subheadline.weight(.semibold))
                            TextField("http://192.168.0.100:61011", text: $model.serverAddress)
                                .textContentType(.URL).keyboardType(.URL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focusedField, equals: .server).submitLabel(.next)
                                .onSubmit { focusedField = .user }
                                .accessibilityIdentifier("serverAddress")
                            Text("填写电脑的局域网地址；手机和电脑连接同一 Wi‑Fi。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("用户名").font(.subheadline.weight(.semibold))
                            TextField("与电脑版相同的账号", text: $model.userName)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focusedField, equals: .user).submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .accessibilityIdentifier("userName")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("密码").font(.subheadline.weight(.semibold))
                            SecureField("账号密码", text: $password)
                                .textContentType(.password).focused($focusedField, equals: .password)
                                .submitLabel(.go).onSubmit(submit)
                                .accessibilityIdentifier("password")
                        }
                    }
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .disabled(model.isWorking)

                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.red)
                            .accessibilityIdentifier("loginError")
                    }
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if model.isWorking { ProgressView().tint(.white) }
                            Text(model.isWorking ? "正在连接…" : "登录并打开地图").fontWeight(.semibold)
                            Spacer()
                        }.padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.isWorking || password.isEmpty || model.userName.trimmingCharacters(in: .whitespaces).isEmpty || model.serverAddress.isEmpty)
                    .accessibilityIdentifier("loginButton")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("首次连接时，请允许 App 访问本地网络。电脑上的 Server 需要保持运行。")
                        Text("同一账号在手机登录后，电脑版需要重新登录。密码不会保存在 App 中。")
                    }.font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24).frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Argument Map").navigationBarTitleDisplayMode(.inline)
            .onDisappear { password = "" }
        }
    }

    private func submit() {
        focusedField = nil
        model.login(password: password)
    }
}
