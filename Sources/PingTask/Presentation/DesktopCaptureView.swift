import SwiftUI
import ImageIO

struct CapturePreview: View {
    let capture: DesktopCapture
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            let point = CaptureGeometry.normalizedPointer(capture.target)
                            Circle().stroke(Color.orange, lineWidth: 2).background(Circle().fill(Color.orange.opacity(0.15)))
                                .frame(width: 18, height: 18)
                                .position(x: point.x * geometry.size.width, y: (1 - point.y) * geometry.size.height)
                        }
                    }
            } else { Text("截图加载中或文件已移除").foregroundStyle(.secondary) }
        }
        .task(id: capture.id) {
            let url = capture.imageURL
            image = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary)
            }.value
        }
    }
}

struct DesktopCaptureView: View {
    @State private var contextMessage: WxMessage?
    @ObservedObject var model: DesktopPingController
    @ObservedObject var store: Store
    var openSettings: () -> Void = {}
    var openTasks: () -> Void = {}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    PageHeading(title: "桌面 Ping", subtitle: "指向屏幕上的信息，让一个手势表达你的意图。")
                    Spacer()
                    Toggle("全局 Ping", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                        .toggleStyle(.switch).padding(.top, 5)
                }
                HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.enabled ? "checkmark.circle" : "cursorarrow.rays").foregroundStyle(AppStyle.gold) }
                    Text(model.status).font(.callout)
                    Spacer()
                    Button("权限与快捷键", action: openSettings).font(.caption)
                }.appSurface()
                if let id = model.taskID { TaskRecordControls(store: store, desktop: model, taskID: id) }
                if let capture = model.capture {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            CapturePreview(capture: capture)
                            Text(capture.evidence).font(.caption).foregroundStyle(.secondary)
                            Text("橙圈是按下时的指针位置；不是消息已匹配的标记。").font(.caption)
                            DisclosureGroup("查看 OCR 线索（仅本地证据）") {
                                ForEach(Array(capture.lines.enumerated()), id: \.offset) { _, line in
                                    Button(line.text) { model.messageQuery = MessageClues.keyword(line.text); model.results = nil }
                                        .buttonStyle(.plain).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.frame(maxWidth: .infinity)
                        if let platform = ChatPlatform.detect(capture.target.bundleID), platform != .wechat {
                            EnterpriseCaptureView(model: model, store: store, platform: platform)
                        } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("核对消息来源").font(.headline)
                            TextField("会话标题 / 群名", text: $model.conversationQuery)
                                .onChange(of: model.conversationQuery) { _ in model.contacts = []; model.chosenContact = nil; model.results = nil }
                            TextField("指针附近的消息文字（至少 3 字）", text: $model.messageQuery)
                                .onChange(of: model.messageQuery) { _ in model.results = nil }
                            HStack {
                                DatePicker("从", selection: $model.startDate, displayedComponents: .date)
                                DatePicker("至", selection: $model.endDate, displayedComponents: .date)
                            }.onChange(of: model.startDate) { _ in model.results = nil }
                                .onChange(of: model.endDate) { _ in model.results = nil }
                            Text("默认检索最近 30 天，最多返回 20 条；历史消息请调整日期，不会默认认定为今天。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("重新定位会话") { model.locateConversation() }
                                if let contact = model.chosenContact { Button("检索消息") { model.search(in: contact) } }
                            }
                            ForEach(model.contacts) { contact in
                                Button { model.search(in: contact) } label: {
                                    HStack {
                                        Image(systemName: model.chosenContact?.id == contact.id ? "checkmark.circle" : "bubble.left")
                                        VStack(alignment: .leading) { Text(contact.name); Text(contact.id).font(.caption2).foregroundStyle(.secondary) }
                                    }
                                }.buttonStyle(.plain)
                            }
                            if let page = model.results {
                                ForEach(page.items) { message in
                                    GroupBox {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("\(message.fromUsername) · \(message.time)").font(.caption)
                                            Text(message.text).font(.callout).textSelection(.enabled)
                                            Button("确认是这条消息") { model.accept(message) }
                                                .disabled(!pending)
                                            Button("查看附近上下文") { contextMessage = message }.disabled(!pending)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            Divider()
                            Button("未定位会话，仅保留截图草稿") { model.keepScreenshot() }.disabled(!pending)
                            if !pending { Button("查看任务草稿", action: openTasks).buttonStyle(.borderedProminent) }
                        }.frame(width: 370)
                        }
                    }.disabled(model.busy)
                } else {
                    HStack(spacing: 24) {
                        DesktopWheelView(actions: store.wheelActions, selected: nil, trigger: model.trigger, centerArtwork: store.centerArtwork)
                        VStack(alignment: .leading, spacing: 22) {
                            Text(store.wheelActions.isEmpty ? "在意图页启用轮盘动作" : "一个手势，\(store.wheelActions.count) 种意图").font(.title3.weight(.semibold))
                            ForEach(store.wheelActions) { action in
                                HStack(spacing: 14) {
                                    if let image = PingArtwork.image(PingArtwork.name(for: action)) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(action.name).fontWeight(.medium)
                                        Text(action.createsTask ? "截图 · 核对来源 · 保存草稿" : "仅播放特效 · 不创建任务").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button { model.playEffect(action) } label: { Image(systemName: "play.circle").font(.title3) }
                                        .buttonStyle(.plain).foregroundStyle(AppStyle.gold).help("仅预览特效，不创建任务")
                                }
                            }
                            Divider()
                            Text("按住 \(model.triggerLabel) → 移动选择 → 松手\n\(model.trigger.cancellationHint)").font(.caption).foregroundStyle(.secondary).lineSpacing(5)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 12)
                    HStack(alignment: .top, spacing: 20) {
                        Label("任务需要你确认", systemImage: "checkmark.bubble")
                        Text("任务意图先保存草稿；仅特效意图不会截图或查询消息。你的资料保存在本机。")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.callout).appSurface()
                    HStack {
                        Text("最近任务").font(.headline)
                        Spacer()
                        Button("查看全部", action: openTasks).buttonStyle(.plain).foregroundStyle(AppStyle.gold)
                    }.padding(.top, 12)
                    if store.tasks.isEmpty {
                        Text("还没有任务。对屏幕上的一条信息试试 Ping。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        ForEach(store.tasks.prefix(3)) { task in
                            Button { store.selected = task.id; openTasks() } label: {
                                HStack {
                                    Text(task.actionName).fontWeight(.medium)
                                    Text(task.chat).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text(task.status).font(.caption).foregroundStyle(AppStyle.gold)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                }.padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }.padding(28)
        }
        .onAppear { model.permissions() }
        .sheet(item: $contextMessage) { message in
            if let account = model.account {
                WxContextView(path: UserDefaults.standard.string(forKey: "wxviewPath") ?? "", account: account, message: message) { source in
                    model.acceptContext(source, anchor: message)
                }
            }
        }
    }
    private var pending: Bool { store.tasks.first(where: { $0.id == model.taskID }) .map { $0.requiresSourceConfirmation == true && $0.status == "待确认" } == true }
}
