import SwiftUI

struct WxContextView: View {
    let path: String
    let account: WxAccount
    let message: WxMessage
    let confirm: (SourceMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var context: WxContext?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("核对附近上下文").font(.title2.bold())
            if let context {
                Text(context.summary).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(context.selected) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(item.id == message.id ? "目标消息 · " : "")\(item.fromUsername) · \(item.time)").font(.caption).foregroundStyle(AppStyle.gold)
                                Text(String(item.text.prefix(2000))).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
                Button("确认原消息及以上上下文") { confirm(context.source(account: account)); dismiss() }
                    .buttonStyle(.borderedProminent)
            } else if let error {
                Text(error).foregroundStyle(.orange)
            } else { ProgressView("只读取此会话在目标消息前后 15 分钟内最多 100 条消息…") }
            Button("返回", action: { dismiss() })
        }.padding(24).frame(width: 680, height: 580).preferredColorScheme(.dark)
            .task {
                do {
                    context = try await Task.detached {
                        try WxviewAdapter(path: path).context(account: account, anchor: message)
                    }.value
                } catch { self.error = (error as? WxFailure)?.message ?? "读取失败，请重新核对来源" }
            }
    }
}
