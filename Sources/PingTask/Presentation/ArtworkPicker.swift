import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ArtworkPicker: View {
    @ObservedObject var store: Store
    let current: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var group = "Ping 图标"
    @State private var search = ""
    @State private var custom: [ArtworkItem] = []
    @State private var importing = false
    @State private var error = ""
    private var items: [ArtworkItem] {
        (PingArtwork.catalog + custom).filter {
            $0.group == group && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("选择图片").font(.title2.bold())
                Spacer()
                Button(importing ? "正在导入…" : "上传图片", action: importImage).disabled(importing)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(importing)
            }
            Picker("素材分类", selection: $group) {
                ForEach(["Ping 图标", "表情", "界面素材", "自定义"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            TextField("搜索图片名称", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                    ForEach(items) { item in
                        VStack(spacing: 6) {
                            Button {
                                choose(item.id); dismiss()
                            } label: {
                                VStack(spacing: 8) {
                                    if let image = PingArtwork.image(item.id) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 64)
                                    }
                                    Text(item.title).font(.caption).lineLimit(2).frame(height: 30)
                                }.frame(maxWidth: .infinity).padding(10)
                                    .background(current == item.id ? AppStyle.gold.opacity(0.2) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).help(item.title).disabled(importing)
                            if item.group == "自定义" {
                                Button("删除图片") { remove(item.id) }.font(.caption2)
                            }
                        }
                    }
                }
                if items.isEmpty { Text("暂无图片，可上传或尝试其他搜索词。").foregroundStyle(.secondary).padding(40) }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("上传后保存本机副本，最长边缩放至 512 像素；动图使用第一帧。选中的图片沿用 Ping 弹出与淡出效果。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 700, height: 620).background(AppStyle.canvas).preferredColorScheme(.dark)
            .onAppear { custom = PingArtwork.customItems(directory: store.artworkDirectory) }
            .interactiveDismissDisabled(importing)
    }
    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .webP, .tiff]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let directory = store.artworkDirectory
        importing = true; error = ""
        Task {
            do {
                let ref = try await Task.detached { try PingArtwork.importImage(at: url, directory: directory) }.value
                custom = PingArtwork.customItems(directory: directory)
                group = "自定义"; search = ""
                choose(ref); dismiss()
            } catch { self.error = error.localizedDescription }
            importing = false
        }
    }
    private func remove(_ ref: String) {
        guard store.centerArtwork != ref, store.defaultArtwork != ref,
              !store.actions.contains(where: { PingArtwork.name(for: $0) == ref }) else {
            error = "此图片仍被意图、中心图片或新意图默认图标使用，请先更换后再删除。"; return
        }
        guard let url = PingArtwork.customURL(ref, directory: store.artworkDirectory) else { return }
        do {
            _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            PingArtwork.cache.removeObject(forKey: ref as NSString)
            custom = PingArtwork.customItems(directory: store.artworkDirectory)
            error = ""
        } catch { self.error = "无法删除图片：\(error.localizedDescription)" }
    }
}
