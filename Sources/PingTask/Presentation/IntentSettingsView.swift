import SwiftUI

struct IntentSettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var desktop: DesktopPingController
    @State private var selected = "analyze"
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeading(title: "Ping 意图", subtitle: "同一个手势，可以推进一件事，也可以只是表达一下。")
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 8) {
                    ForEach(Array(store.actions.enumerated()), id: \.element.id) { index, action in
                        Button { selected = action.id } label: {
                            HStack(spacing: 14) {
                                if let image = PingArtwork.image(PingArtwork.name(for: action)) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 32, height: 32)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(action.name).fontWeight(.medium)
                                    Text(["上", "右", "下", "左"][index % 4] + " · " + (action.createsTask ? "任务意图" : "仅播放特效"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            }.padding(16).frame(width: 220)
                                .background(selected == action.id ? AppStyle.gold.opacity(0.10) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == action.id ? AppStyle.gold.opacity(0.3) : .clear))
                        }.buttonStyle(.plain)
                    }
                    Text("修改只应用于之后的 Ping，\n已有任务保留原来的内容。").font(.caption).foregroundStyle(.secondary).padding(.top, 16)
                }
                if let index = store.actions.firstIndex(where: { $0.id == selected }) {
                    editor(index)
                }
            }
            Spacer(minLength: 0)
        }.padding(28)
    }
    func editor(_ index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("意图名称").font(.caption).foregroundStyle(.secondary)
                        TextField("给这个动作起个名字", text: $store.actions[index].name)
                            .font(.title2.weight(.semibold)).textFieldStyle(.plain)
                            .onChange(of: store.actions[index].name) { _ in store.save() }
                    }
                    Spacer()
                    Button { desktop.playEffect(store.actions[index]) } label: { Label("预览特效", systemImage: "play.fill") }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("松手之后").font(.headline)
                    Picker("行为", selection: Binding(get: { store.actions[index].effectOnly == true }, set: { store.actions[index].effectOnly = $0; store.save() })) {
                        Text("创建任务草稿").tag(false)
                        Text("仅播放特效").tag(true)
                    }.pickerStyle(.segmented)
                    Text(store.actions[index].createsTask ? "捕获来源，等待你核对后提交。不会自动执行。" : "图标与光圈短暂留在屏幕上，然后淡出。不截图、不查询消息、不创建任务。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if store.actions[index].createsTask {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("任务提示词").font(.headline)
                        Text("描述希望执行器如何理解和处理这次 Ping。").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $store.actions[index].prompt).font(.system(size: 13)).scrollContentBackground(.hidden)
                            .frame(minHeight: 210).padding(12).background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                            .onChange(of: store.actions[index].prompt) { _ in store.save() }
                        Label("任务草稿需明确确认，才会交给设置中的 Codex CLI。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Spacer()
                        if let image = PingArtwork.image(PingArtwork.name(for: store.actions[index])) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 100, height: 100).padding(40)
                        }
                        Spacer()
                    }
                    Text("保留这一刻的表达。约 2.2 秒后，画面恢复如常。").font(.caption).foregroundStyle(.secondary)
                }
                Label("修改自动保存", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }.appSurface()
        }.id(store.actions[index].id)
    }
}
