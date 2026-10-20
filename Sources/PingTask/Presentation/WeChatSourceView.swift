import SwiftUI
import AppKit

@MainActor final class WeChatSourceModel: ObservableObject {
    @Published var path = UserDefaults.standard.string(forKey: "wxviewPath") ?? ""
    @Published var query = ""
    @Published var kind = "chatroom"
    @Published var date = Date()
    @Published var account: WxAccount?
    @Published var contacts: [WxContact] = []
    @Published var page: WxPage?
    @Published var readAt = Date()
    @Published var busy = false
    @Published var status = "尚未连接。选择本机 wxview，然后检查连接。"

    func perform<T>(_ work: @escaping () throws -> T, receive: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try work() }.value
                receive(result)
            } catch {
                // Decode failures can include raw content in diagnostics; show only a safe explanation.
                status = (error as? WxFailure)?.message ?? "wxview 数据读取失败，请检查版本、文件路径与本地缓存。"
            }
            busy = false
        }
    }
    func connect() {
        account = nil; contacts = []; page = nil
        let adapter = WxviewAdapter(path: path)
        perform({ () -> (WxAccount, String) in
            let version = try adapter.execute(adapter.path, ["version"])
            let account = try adapter.identity()
            try adapter.checkSingleAccount(account)
            struct Cache: Decodable {
                struct Item: Decodable { let account: String; let status: String; let keyStatus: String }
                let items: [Item]
            }
            let cache = try WxviewAdapter.decode(Cache.self, adapter.checked(account, args: ["cache", "status", "--format", "json"]))
            guard cache.items.allSatisfy({ $0.account == account.account }) else { throw WxFailure(message: "缓存账号不一致") }
            let available = cache.items.filter { $0.status == "fresh" }.count
            let unavailable = cache.items.filter { $0.keyStatus != "available" }.count
            return (account, "wxview \(String(decoding: version.prefix(80), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) · 缓存新鲜 \(available)/\(cache.items.count) · 密钥不可用 \(unavailable)；仅反映本地缓存，不保证实时。")
        }, receive: { [self] account, status in
            self.account = account; self.status = status
            UserDefaults.standard.set(path, forKey: "wxviewPath")
        })
    }
    func search() {
        guard let account else { return }
        contacts = []; page = nil
        let adapter = WxviewAdapter(path: path), query = query, kind = kind
        perform({ try adapter.contacts(account: account, query: query, kind: kind) }, receive: { [self] items in
            contacts = items
            status = "找到 \(items.count) 个候选（最多 20 个），请明确选择会话。"
        })
    }
    func load(_ contact: WxContact) {
        guard let account else { return }
        page = nil
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date), adapter = WxviewAdapter(path: path)
        perform({ try adapter.messages(account: account, contact: contact, date: day) }, receive: { [self] result in
            page = result; readAt = Date()
            status = "\(contact.name) · \(day) · \(result.meta.timezone) · \(result.items.count) 条\(result.meta.hasMore ? " · 有更多，已截断（首 100 条）" : " · 该范围已读完")。缓存可能延迟。"
        })
    }
}

struct WeChatSourceView: View {
    @ObservedObject var model: WeChatSourceModel
    let select: (SourceMessage) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeading(title: "微信连接", subtitle: "连接本机 wxview，让 Ping 找到消息的完整来源。")
            Text("按需查找本机缓存消息。只有选为任务来源的正文会保存；缓存内容可能存在延迟。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("wxview 可执行文件的绝对路径", text: $model.path)
                    .onChange(of: model.path) { _ in model.account = nil; model.contacts = []; model.page = nil }
                Button("选择文件") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { model.path = url.path }
                }
                Button("检查连接") { model.connect() }
            }
            if let account = model.account {
                Text("当前账号：\(account.displayName)（\(account.username)）").font(.caption)
                HStack {
                    Picker("类型", selection: $model.kind) {
                        Text("群聊").tag("chatroom"); Text("联系人").tag("friend")
                    }.frame(width: 170)
                    .onChange(of: model.kind) { _ in model.contacts = []; model.page = nil }
                    TextField("输入群名或联系人，核对候选后查询", text: $model.query)
                    Button("查找会话") { model.search() }.disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    DatePicker("消息日期", selection: $model.date, displayedComponents: .date)
                        .onChange(of: model.date) { _ in model.page = nil }
                }
                HStack(alignment: .top) {
                    List(model.contacts) { contact in
                        Button { model.load(contact) } label: {
                            VStack(alignment: .leading) {
                                Text(contact.name)
                                Text(contact.username).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }.frame(width: 270)
                    if let page = model.page {
                        List(page.items) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(message.fromUsername) · \(message.time)").font(.caption).foregroundStyle(.secondary)
                                Text(message.text).lineLimit(5)
                                Button("选为 Ping 来源") { select(message.source(account: account, page: page, readAt: model.readAt)) }
                            }.padding(.vertical, 5)
                        }
                    } else {
                        Text("点击会话，读取所选日期最早的 100 条消息。\n不会猜测屏幕消息，也不会自动读取其他日期。")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                QuietEmptyState(symbol: "bubble.left.and.bubble.right", title: "从一条消息开始", message: "选择本机 wxview，检查连接后查找会话。只按你的操作读取缓存，不会发送微信消息。")
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).textSelection(.enabled)
            }
        }.padding(28).textFieldStyle(.roundedBorder).disabled(model.busy)
    }
}
