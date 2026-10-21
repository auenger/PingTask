import SwiftUI

struct EnterpriseChatSettingsView: View {
    @AppStorage("larkPath") private var path = EnterpriseChatSettings().larkPath
    @AppStorage("larkProfile") private var profile = ""
    @AppStorage("dwsPath") private var dwsPath = ""
    @State private var status = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("飞书 / 钉钉来源", systemImage: "bubble.left.and.bubble.right").font(.headline)
            TextField("lark-cli 绝对路径", text: $path)
            TextField("飞书 profile（留空固定本次查询的当前 profile）", text: $profile)
            Button("检查飞书登录") {
                busy = true
                let adapter = LarkContextAdapter(path: path, profile: profile)
                Task {
                    do {
                        _ = try await Task.detached { try adapter.pinned().identity() }.value
                        status = "用户登录可用；消息读取权限将在实际查询时核验。"
                    } catch { status = error.localizedDescription }
                    busy = false
                }
            }.disabled(busy)
            TextField("dws 绝对路径（待校验本机 CLI 契约）", text: $dwsPath)
            Text("飞书支持群名或 chat_id，读取最近一页并由你确认。钉钉已识别窗口，消息适配待本机 dws 可用后校验。不会自动登录或下载附件。")
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.small) }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        }
    }
}

struct EnterpriseCaptureView: View {
    @ObservedObject var model: DesktopPingController
    @ObservedObject var store: Store
    let platform: ChatPlatform
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(platform.label) · 核对消息来源").font(.headline)
            Text("已识别应用窗口；尚未确认指针处属于消息区。请核对会话和正文后附带上下文。")
                .font(.caption).foregroundStyle(.secondary)
            if platform == .lark {
                TextField("精确群名 / 真实 chat_id（oc_…）", text: $model.conversationQuery)
                    .onChange(of: model.conversationQuery) { _ in model.enterpriseContext = nil }
                DatePicker("从", selection: $model.startDate, displayedComponents: .date)
                    .onChange(of: model.startDate) { _ in model.enterpriseContext = nil }
                DatePicker("至", selection: $model.endDate, displayedComponents: .date)
                    .onChange(of: model.endDate) { _ in model.enterpriseContext = nil }
                Button("读取会话最近 50 条") { model.locateEnterprise() }
                Text("范围最多 31 天；仅读取一页，不展开话题。历史消息请调整日期。私聊目前需填写真实 chat_id。")
                    .font(.caption).foregroundStyle(.secondary)
                if let context = model.enterpriseContext {
                    Text(context.hasMore ? "还有更早消息，本次结果有截断。" : "当前查询范围无后续页。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(context.messages) { message in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(message.sender) · \(message.time)").font(.caption)
                                Text(message.text).font(.callout).textSelection(.enabled)
                                Button("确认此消息并附带本页附近上下文") { model.acceptEnterprise(message) }
                                    .disabled(!pending)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                Text("钉钉窗口已识别。当前尚未校验本机 dws 命令及返回协议，暂时保留截图草稿。")
                    .font(.callout)
            }
            Button("仅保留截图草稿") { model.keepScreenshot() }.disabled(!pending)
        }.frame(width: 370)
    }
    private var pending: Bool {
        store.tasks.first(where: { $0.id == model.taskID }).map { $0.requiresSourceConfirmation == true && $0.status == "待确认" } == true
    }
}
