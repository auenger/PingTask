import SwiftUI
import Quartz

struct LocalPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}

struct WxMediaView: View {
    let message: WxMessage
    let account: WxAccount
    let choose: (LocalMedia) -> Void
    @State private var thumbnail: CGImage?
    @State private var preview: URL?
    @State private var showingPreview = false
    @State private var status = ""
    @State private var confirmed = false
    var body: some View {
        if let media = LocalMedia.candidate(message, account: account) {
            VStack(alignment: .leading, spacing: 8) {
                if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 150) }
                Label(media.name, systemImage: media.isImage ? "photo" : "doc").lineLimit(2)
                Text(media.isThumbnail ? "当前仅找到缩略图" : "本机附件候选，请先预览核对内容").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("预览") {
                        Task {
                            do { preview = try await MediaIO.shared.validate(media); showingPreview = true }
                            catch { status = "文件不可读取、已移动或超出允许范围" }
                        }
                    }
                    Button("在 Finder 中显示") {
                        Task {
                            do { let url = try await MediaIO.shared.validate(media); NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            catch { status = "文件不可读取或已移动" }
                        }
                    }
                }
                Toggle("已核对附件，附带给 Agent 分析", isOn: $confirmed)
                Button("选为来源并附带附件") { choose(media) }.disabled(!confirmed)
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .task(id: media.id) {
                guard media.isImage else { return }
                do { let value = try await MediaIO.shared.thumbnail(media); if !Task.isCancelled { thumbnail = value } }
                catch { status = "本机图片不可读取或无法解码" }
            }
            .sheet(isPresented: $showingPreview) {
                VStack {
                    if let preview { LocalPreview(url: preview).frame(width: 760, height: 540) }
                    Button("关闭") { showingPreview = false }
                }.padding()
            }
        } else if message.type == 3 || message.contentDetail?["type"] == "file" {
            Text("本机未找到可用附件；可先在微信中下载，再刷新消息。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
