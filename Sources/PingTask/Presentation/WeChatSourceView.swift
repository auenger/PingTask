import SwiftUI
import AppKit

@MainActor final class WeChatSourceModel: ObservableObject {
    @Published var path = UserDefaults.standard.string(forKey: "wxviewPath") ?? ""
    @Published var query = ""
    @Published var kind = "all"
    @Published var recent = true
    private var visitedContacts: [Int: Set<String>] = [:]
    @Published var startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @Published var endDate = Date()
    @Published var account: WxAccount?
    @Published var contacts: [WxContact] = []
    @Published var selectedContact: WxContact?
    @Published var page: WxPage?
    @Published var readAt = Date()
    @Published var busy = false
    @Published var status = "选择本机 wxview；启动时自动连接并加载联系人，不预读聊天正文。"
    @Published var contactOffset = 0
    @Published var messagePage = 0
    @Published var hasNextContacts = false
    var messageArgs: [[String]] = []
    var nextArgs: [String]?
    private var started = false
    private var generation = UUID()

    func start() {
        guard !started else { return }; started = true
        if path.isEmpty {
            let candidates = ["/usr/local/bin/wxview", "/opt/homebrew/bin/wxview", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("mycode/weixincli/wxview/bin/wxview").path]
            path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        }
        if !path.isEmpty { connect() }
    }
    func invalidate() { generation = UUID(); account = nil; contacts = []; visitedContacts = [:]; resetMessages(); started = false }
    func resetMessages() { page = nil; selectedContact = nil; messageArgs = []; nextArgs = nil; messagePage = 0 }
    func perform<T>(_ work: @escaping () throws -> T, receive: @escaping (T) -> Void) {
        guard !busy else { return }
        let token = generation
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try work() }.value
                if generation == token { receive(result) }
            } catch {
                if generation == token { status = (error as? WxFailure)?.message ?? "读取失败，请检查 wxview 与本机缓存。" }
            }
            busy = false
        }
    }
    func connect() {
        guard !busy else { return }
        invalidate()
        let adapter = WxviewAdapter(path: path)
        perform({ () -> (WxAccount,[WxContact],String?) in
            _ = try adapter.execute(adapter.path,["version"])
            try adapter.requireHistoryPagination()
            let account = try adapter.identity()
            try adapter.checkSingleAccount(account)
            do { return (account,try adapter.sessionPage(account: account,query: "",kind: "all",offset: 0),nil) }
            catch { return (account,[],"最近会话读取失败，可切换通讯录；请核对 session 缓存与权限。不会自动初始化。") }
        }, receive: { [self] account, items, warning in
            self.account = account; kind = "all"; recent = true; query = ""; contactOffset = 0; visitedContacts = [0: Set(items.map(\.id))]
            contacts = items; hasNextContacts = items.count == 100
            status = warning ?? "最近会话已加载，最新消息在前；每页 100 个，本地缓存可能延迟。"
            UserDefaults.standard.set(path,forKey: "wxviewPath")
        })
    }
    func search(offset: Int = 0) {
        guard !busy, let account else { return }
        resetMessages()
        let adapter = WxviewAdapter(path: path), query = query, kind = kind, recent = recent
        if offset == 0 { visitedContacts = [:] }
        perform({ try recent ? adapter.sessionPage(account: account, query: query, kind: kind, offset: offset) : adapter.contactPage(account: account, query: query, kind: kind, offset: offset) }, receive: { [self] items in
            let seen = visitedContacts.filter { $0.key < offset }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            contacts = items.filter { !seen.contains($0.id) }; visitedContacts[offset] = Set(contacts.map(\.id))
            contactOffset = offset; hasNextContacts = items.count == 100
            status = "\(recent ? "最近会话" : "通讯录")第 \(offset / 100 + 1) 页 · \(contacts.count) 个；缓存更新时可能重排，刷新从第一页开始。"
        })
    }
    func load(_ contact: WxContact) {
        guard !busy, let account else { return }
        guard startDate <= endDate, endDate.timeIntervalSince(startDate) <= 366 * 86400 else { status = "请选择不超过 366 天的有效时间范围"; return }
        selectedContact = contact; page = nil; nextArgs = nil; messagePage = 0
        let args = WxviewAdapter.historyArgs(username: contact.username, start: startDate, end: endDate)
        messageArgs = [args]
        fetch(account: account, contact: contact, args: args, index: 0)
    }
    func changeMessagePage(_ index: Int) {
        guard !busy, let account, let contact = selectedContact, index >= 0 else { return }
        if index == messageArgs.count, let nextArgs {
            guard !messageArgs.contains(nextArgs) else { status = "分页游标重复，已停止"; return }
            messageArgs.append(nextArgs)
        }
        guard messageArgs.indices.contains(index) else { return }
        fetch(account: account, contact: contact, args: messageArgs[index], index: index)
    }
    private func fetch(account: WxAccount, contact: WxContact, args: [String], index: Int) {
        let adapter = WxviewAdapter(path: path)
        perform({ try adapter.history(account: account, username: contact.username, args: args) }, receive: { [self] result in
            page = result; readAt = Date(); messagePage = index
            do { nextArgs = try WxviewAdapter.nextHistoryArgs(result, requestArgs: args) }
            catch { nextArgs = nil; status = error.localizedDescription; return }
            status = "\(contact.name) · 第 \(index + 1) 页 · \(result.items.count) 条 · \(result.meta.start) — \(result.meta.end)（\(result.meta.timezone)） · \(result.meta.hasMore ? "还有更多" : "范围末页") · 本地缓存可能延迟"
        })
    }
}

struct WeChatSourceView: View {
    @State private var contextMessage: WxMessage?
    @ObservedObject var model: WeChatSourceModel
    let select: (SourceMessage) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: "微信连接", subtitle: "最近会话优先；选中后加载消息，图片和文件按需预览。")
            HStack {
                TextField("wxview 可执行文件的绝对路径", text: $model.path).onChange(of: model.path) { _ in model.invalidate() }
                Button("选择文件") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { model.path = url.path }
                }
                Button("重新连接") { model.connect() }
            }.disabled(model.busy)
            if let account = model.account {
                HStack {
                    Text("当前账号：\(account.displayName)").font(.caption)
                    Spacer()
                    Text("消息只在选中后读取；仅选为任务来源的内容保存。") .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 10) {
                        Picker("列表", selection: $model.recent) {
                            Text("最近会话").tag(true); Text("通讯录").tag(false)
                        }.pickerStyle(.segmented).onChange(of: model.recent) { _ in model.search() }.disabled(model.busy)
                        Picker("类型", selection: $model.kind) {
                            Text("联系人").tag("friend"); Text("群聊").tag("chatroom"); Text("全部").tag("all")
                        }.pickerStyle(.segmented).onChange(of: model.kind) { _ in model.search() }.disabled(model.busy)
                        HStack {
                            TextField("搜索联系人 / 群聊", text: $model.query).onSubmit { model.search() }
                            Button { model.search() } label: { Image(systemName: "magnifyingglass") }
                        }.disabled(model.busy)
                        List(model.contacts) { contact in
                            Button { model.load(contact) } label: {
                                HStack {
                                    Image(systemName: contact.username.hasSuffix("@chatroom") ? "person.2" : "person.crop.circle")
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(contact.name).lineLimit(1)
                                        if let timestamp = contact.lastTimestamp {
                                            Text(Date(timeIntervalSince1970: Double(timestamp)), format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                                            Text(contact.summary ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        } else { Text(contact.username).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if let unread = contact.unreadCount, unread > 0 { Text("\(unread)").font(.caption).foregroundStyle(AppStyle.gold) }
                                    if model.selectedContact?.id == contact.id { Image(systemName: "checkmark").foregroundStyle(AppStyle.gold) }
                                }.padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.busy)
                        }
                        HStack {
                            Button("上一页") { model.search(offset: max(0,model.contactOffset-100)) }.disabled(model.busy || model.contactOffset == 0)
                            Text("\(model.contactOffset / 100 + 1)").font(.caption)
                            Button("下一页") { model.search(offset: model.contactOffset+100) }.disabled(model.busy || !model.hasNextContacts)
                        }
                    }.frame(width: 280)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            DatePicker("起", selection: $model.startDate, displayedComponents: [.date,.hourAndMinute])
                            DatePicker("止", selection: $model.endDate, displayedComponents: [.date,.hourAndMinute])
                            Button("筛选") { if let contact = model.selectedContact { model.load(contact) } }
                        }.disabled(model.busy)
                        HStack {
                            ForEach([1,7,30], id: \.self) { days in
                                Button("近 \(days) 天") {
                                    model.endDate = Date()
                                    model.startDate = Calendar.current.date(byAdding: .day, value: -days, to: model.endDate)!
                                    if let contact = model.selectedContact { model.load(contact) }
                                }
                            }
                            Spacer()
                            Text("每页 100 条 · 最新在前 · 翻页加载更早消息").font(.caption).foregroundStyle(.secondary)
                        }.disabled(model.busy)
                        if let page = model.page {
                            List(page.items) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(message.fromUsername) · \(message.time)").font(.caption).foregroundStyle(.secondary)
                                    Text(message.type == 3 ? "图片消息" : message.text).lineLimit(8).textSelection(.enabled)
                                    WxMediaView(message: message, account: account) { media in
                                        var source = message.source(account: account, page: page, readAt: model.readAt)
                                        source.media = media
                                        source.evidence = (source.evidence ?? "") + "\n用户已核对本机附件候选，选择随任务分析；创建草稿时保存独立副本。"
                                        select(source)
                                    }
                                    HStack {
                                        Button(LocalMedia.candidate(message, account: account) == nil ? "选为 Ping 来源" : "仅选消息记录") { select(message.source(account: account, page: page, readAt: model.readAt)) }
                                        Button("附近上下文") { contextMessage = message }
                                    }.disabled(model.busy)
                                }.padding(.vertical, 8)
                            }.id((model.selectedContact?.id ?? "") + String(model.messagePage))
                            HStack {
                                Button("上一页") { model.changeMessagePage(model.messagePage-1) }.disabled(model.busy || model.messagePage == 0)
                                Text("第 \(model.messagePage+1) 页 · \(page.items.count) 条").font(.caption)
                                Button("更早的 100 条") { model.changeMessagePage(model.messagePage+1) }.disabled(model.busy || model.nextArgs == nil)
                            }
                        } else {
                            QuietEmptyState(symbol: "bubble.left.and.bubble.right", title: model.busy ? "正在加载…" : "选择一个联系人或群聊", message: "只加载当前会话和时间范围，每次最多 100 条。")
                        }
                    }
                }
            } else {
                QuietEmptyState(symbol: "bubble.left.and.bubble.right", title: model.busy ? "正在连接微信…" : "连接本机 wxview", message: "配置路径后自动加载联系人，不会发送微信消息。")
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(28).textFieldStyle(.roundedBorder)
            .sheet(item: $contextMessage) { message in
                if let account = model.account { WxContextView(path: model.path, account: account, message: message, confirm: select) }
            }
    }
}
