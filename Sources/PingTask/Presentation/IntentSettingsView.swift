import SwiftUI

struct IntentSettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var desktop: DesktopPingController
    @State private var selected = "analyze"
    @State private var search = ""
    @State private var picker: ImageTarget?
    @State private var deleting: String?
    private enum ImageTarget: String, Identifiable {
        case intent, center, defaultIcon
        var id: String { rawValue }
    }
    private var action: PingAction? { store.actions.first { $0.id == selected } }
    private var results: [PingAction] {
        store.actions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.prompt.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "Ping 意图", subtitle: "配置你的表达方式。轮盘最多启用 8 个意图，其他意图保留在库中。")
            HStack(alignment: .top, spacing: 24) {
                sidebar.frame(width: 240)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        wheelSettings
                        if let action { editor(action) }
                        else { QuietEmptyState(symbol: "sparkles", title: "创建一个 Ping 意图", message: "选择图标、行为与提示词，组合成你自己的轮盘。") }
                    }
                }
            }
        }.padding(28)
            .onAppear { if action == nil { selected = store.actions.first?.id ?? "" } }
            .sheet(item: $picker) { target in
                ArtworkPicker(store: store, current: target == .center ? store.centerArtwork : target == .defaultIcon ? store.defaultArtwork : action.map { PingArtwork.name(for: $0) } ?? store.defaultArtwork) { ref in
                    switch target {
                    case .intent: store.updateIntent(selected) { $0.artwork = ref }
                    case .center: store.changeIntents { store.centerArtwork = ref }
                    case .defaultIcon: store.changeIntents { store.defaultArtwork = ref }
                    }
                }
            }
            .confirmationDialog("删除此意图？已有任务保留原来的名称与提示词。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除意图", role: .destructive) {
                    if let id = deleting, store.deleteIntent(id) { selected = store.actions.first?.id ?? "" }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            }
    }
    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack {
                Text("意图库 · \(store.actions.count)").font(.headline)
                Spacer()
                Button {
                    if let id = store.addIntent() { selected = id; search = "" }
                } label: { Image(systemName: "plus") }.help("新增意图")
            }
            TextField("搜索名称或提示词", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(results) { item in
                        Button { selected = item.id } label: {
                            HStack(spacing: 12) {
                                artwork(PingArtwork.name(for: item), size: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name.isEmpty ? "未命名意图" : item.name).fontWeight(.medium).lineLimit(1)
                                    Text(position(item) + " · " + (item.createsTask ? "任务" : "仅特效"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected == item.id ? AppStyle.gold.opacity(0.12) : Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == item.id ? AppStyle.gold.opacity(0.35) : .clear))
                        }.buttonStyle(.plain)
                    }
                }
                if results.isEmpty { Text("没有匹配的意图").font(.caption).foregroundStyle(.secondary).padding() }
            }
            Text("修改仅用于之后的 Ping，\n已有任务内容保持不变。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var wheelSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("轮盘与默认图片").font(.headline)
                Spacer()
                Text("\(store.wheelActions.count) / 8 已启用").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                artwork(store.centerArtwork, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("轮盘中心图片")
                    Text("每次触发使用此图；回中心仍取消 Ping。") .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("更换") { picker = .center }
                Button("恢复默认") { store.changeIntents { store.centerArtwork = PingArtwork.centerDefault } }
            }
            Divider()
            HStack(spacing: 16) {
                artwork(store.defaultArtwork, size: 32)
                Text("新意图默认图标").font(.callout)
                Spacer()
                Button("设置默认图标") { picker = .defaultIcon }
            }
        }.appSurface()
    }
    private func editor(_ value: PingAction) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Button { picker = .intent } label: { artwork(PingArtwork.name(for: value), size: 64).padding(12).background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).help("更换意图图片")
                VStack(alignment: .leading, spacing: 8) {
                    TextField("意图名称", text: binding(value, \.name)).font(.title2.weight(.semibold)).textFieldStyle(.plain)
                    HStack {
                        Button("更换图片") { picker = .intent }
                        Button("设为新意图默认图标") { store.changeIntents { store.defaultArtwork = PingArtwork.name(for: value) } }
                    }.font(.caption)
                }
                Spacer()
                Button { desktop.playEffect(value) } label: { Label("预览", systemImage: "play.fill") }
            }
            HStack {
                Toggle("显示在轮盘", isOn: Binding(get: { value.onWheel != false }, set: { store.setOnWheel(value.id, enabled: $0) }))
                    .toggleStyle(.switch)
                Spacer()
                Button { store.moveIntent(value.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("向前移动")
                    .disabled(store.actions.first?.id == value.id)
                Button { store.moveIntent(value.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("向后移动")
                    .disabled(store.actions.last?.id == value.id)
                Text("从上方顺时针排列").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Picker("松手之后", selection: Binding(get: { value.effectOnly == true }, set: { setEffect(value.id, $0) })) {
                Text("创建任务草稿").tag(false)
                Text("仅播放特效").tag(true)
            }.pickerStyle(.segmented)
            Text(value.createsTask ? "捕获来源，等待核对与确认后交给执行器。" : "播放图片、弹出光圈和留存淡出，不截图、不查询消息、不创建任务。")
                .font(.callout).foregroundStyle(.secondary)
            if value.createsTask {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("处理 Agent", selection: Binding(get: { value.executor ?? "Codex" }, set: { chosen in store.updateIntent(value.id) { $0.executor = chosen } })) {
                        Text("Codex CLI").tag("Codex")
                        Text("WorkBuddy Agent").tag("WorkBuddy")
                    }
                    Toggle("自动查询聊天上下文（微信 / 飞书）", isOn: Binding(get: { value.automaticContext == true }, set: { enabled in
                        store.updateIntent(value.id) { $0.automaticContext = enabled; if !enabled { $0.automaticSubmit = false } }
                    }))
                    Toggle("定位成功后自动提交给 Agent", isOn: Binding(get: { value.automaticSubmit == true }, set: { enabled in
                        store.updateIntent(value.id) { $0.automaticSubmit = enabled }
                    })).disabled(value.automaticContext != true)
                    Text("飞书仍需手动确认消息，不自动提交；钉钉查询待接入。微信开启自动提交即授权后续此意图的 Ping：唯一匹配后，将正文、附近上下文与 OCR 交给所选 Agent；Codex 还接收截图。沿用设置中的工作目录和权限。歧义、低置信度、截断或失败时保留草稿，不重复派发已有任务。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("任务提示词").font(.headline)
                    TextEditor(text: binding(value, \.prompt)).font(.system(size: 13)).scrollContentBackground(.hidden)
                        .frame(minHeight: 160).padding(12).background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack {
                Label("修改自动保存", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认图片") { store.updateIntent(value.id) { $0.artwork = PingAction.defaults.contains(where: { $0.id == value.id }) ? nil : store.defaultArtwork } }
                Button("删除意图", role: .destructive) { deleting = value.id }
            }
        }.appSurface().id(value.id)
    }
    private func setEffect(_ id: String, _ enabled: Bool) { store.updateIntent(id) { $0.effectOnly = enabled } }
    private func binding(_ value: PingAction, _ path: WritableKeyPath<PingAction, String>) -> Binding<String> {
        Binding(get: { store.actions.first(where: { $0.id == value.id })?[keyPath: path] ?? value[keyPath: path] },
                set: { text in store.updateIntent(value.id) { $0[keyPath: path] = text } })
    }
    private func position(_ value: PingAction) -> String {
        guard let index = store.wheelActions.firstIndex(where: { $0.id == value.id }) else { return "仅保留在库" }
        return store.wheelActions.count == 4 ? ["上", "右", "下", "左"][index] : "轮盘 \(index + 1)"
    }
    private func artwork(_ name: String, size: CGFloat) -> some View {
        Group { if let image = PingArtwork.image(name) { Image(nsImage: image).resizable().scaledToFit() } }
            .frame(width: size, height: size)
    }
}
