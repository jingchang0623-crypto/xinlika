import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("reading.appearance") private var appearance = ReadingAppearance.system
    @State private var showAdvanced = false
    @State private var confirmSignOut = false
    @FocusState private var focusedField: LoginField?

    private enum LoginField { case email, password }

    var body: some View {
        NavigationStack {
            Form {
                Section("深脑账号") {
                    Group {
                        if model.isSignedIn {
                            LabeledContent("已登录", value: model.email)
                            Button("退出登录", role: .destructive) { confirmSignOut = true }
                        } else {
                            TextField("邮箱", text: $model.email).textContentType(.username)
                                .textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                            SecureField("密码", text: $model.password).textContentType(.password)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { model.signIn() }
                            Button("登录") { model.signIn() }
                                .disabled(model.accountLocked || model.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.password.isEmpty)
                        }
                    }
                    if !model.accountMessage.isEmpty {
                        Text(model.accountMessage).font(.footnote).foregroundStyle(ShennaoTheme.supportingText)
                    }
                }
                Section {
                    Picker("外观", selection: $appearance) {
                        ForEach(ReadingAppearance.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("文字大小", value: "跟随系统")
                } header: { Text("阅读") }
                if model.isSignedIn {
                    Section {
                        Picker("短录音待确认", selection: Binding(get: { model.minimumRecordingSeconds }, set: model.setMinimumRecordingSeconds)) {
                            Text("关闭").tag(0)
                            Text("不足 30 秒").tag(30)
                            Text("不足 1 分钟").tag(60)
                            Text("不足 2 分钟").tag(120)
                        }
                        LabeledContent("长录音待确认", value: "2 小时及以上")
                        LabeledContent("批量录音待确认", value: "一次新增 5 条及以上")
                    } header: { Text("导入保护") } footer: {
                        Text("待确认录音不会自动下载或分析。")
                    }
                }
                #if DEBUG
                Section {
                    DisclosureGroup("连接参数", isExpanded: $showAdvanced) {
                        TextField("API 地址", text: $model.config.apiBase).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Supabase 地址", text: $model.config.supabaseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Supabase anon key", text: $model.config.supabaseAnonKey)
                        Button("保存连接参数") { model.saveConfiguration() }
                    }
                } header: { Text("开发与诊断") } footer: {
                    Text("修改连接参数会退出当前账号。非排障需要，请保留原有配置。")
                }.disabled(model.accountLocked)
                #endif
                Section {
                    LabeledContent("版本", value: version)
                    NavigationLink("开源许可") { OpenSourceNoticesView() }
                } header: { Text("关于深脑") }
            }
            .navigationTitle("设置")
            .confirmationDialog("退出当前账号？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { model.signOut() }
                Button("取消", role: .cancel) {}
            } message: { Text("已保存的录音不会被删除，重新登录原账号后可继续查看。") }
        }
    }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}

private struct OpenSourceNoticesView: View {
    @State private var notices = "正在读取许可…"
    var body: some View {
        ScrollView {
            Text(verbatim: notices).font(.footnote).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
        .task {
            guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
                notices = "许可文件暂不可用。"; return
            }
            notices = await Task.detached(priority: .utility) {
                (try? String(contentsOf: url, encoding: .utf8)) ?? "许可文件暂不可用。"
            }.value
        }
    }
}
