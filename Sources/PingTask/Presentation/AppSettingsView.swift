import SwiftUI
import AppKit

struct AppSettingsView: View {
    @AppStorage(AppPresence.preferenceKey) private var menuBarOnly = false
    @ObservedObject var store: Store
    @ObservedObject var desktop: DesktopPingController
    let openPractice: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "设置", subtitle: "让 Ping 适应你的习惯。")
                VStack(alignment: .leading, spacing: 12) {
                    Label("应用显示", systemImage: "menubar.rectangle").font(.headline)
                    Toggle("仅在菜单栏显示（隐藏 Dock 图标）", isOn: $menuBarOnly)
                        .toggleStyle(.switch)
                        .onChange(of: menuBarOnly) { value in
                            if !store.isolated { AppPresence.apply(menuBarOnly: value) }
                        }
                    Text("保留屏幕顶部的小图标，可随时打开窗口。关闭窗口后继续运行；关闭此选项可恢复 Dock 图标。")
                        .font(.caption).foregroundStyle(.secondary)
                }.appSurface()
                VStack(alignment: .leading, spacing: 14) {
                    Label("触发方式", systemImage: "keyboard").font(.headline)
                    PingTriggerPicker(model: desktop)
                    Text("按住触发键，移动选择，松手触发。回到中心、Esc 或右键取消。其他组合键继续交给当前应用。").font(.callout).foregroundStyle(.secondary)
                }.appSurface()
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("系统权限", systemImage: "lock.shield").font(.headline)
                        Spacer()
                        Button("刷新状态") { desktop.permissions() }
                    }
                    permission("辅助功能", detail: "用于识别全局手势；所有 Ping 都需要。", granted: desktop.accessibilityGranted, action: desktop.requestAccessibility)
                    Divider()
                    permission("屏幕录制", detail: "仅任务意图截图时需要，纯特效无需开启。", granted: desktop.screenGranted, action: desktop.requestScreen)
                    DisclosureGroup("已授权但仍无法开启？") {
                        Text("先退出并重新打开 PingTask。如果仍未生效，在系统设置中核对当前应用的位置；本地开发版本更新后可能需要重新添加。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        Button("在 Finder 中显示当前应用") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.padding(.top, 6)
                    }.font(.callout)
                }.appSurface()
                EnterpriseChatSettingsView().appSurface()
                CodexSettingsView(store: store).appSurface()
                WorkBuddySettingsView(store: store).appSurface()
                VStack(alignment: .leading, spacing: 14) {
                    Label("本地数据", systemImage: "internaldrive").font(.headline)
                    Text("截图和任务记录保存在这台 Mac。删除记录时，未被其他任务引用的截图会移入废纸篓。").font(.callout).foregroundStyle(.secondary)
                    Button("打开数据文件夹") {
                        let directory = DesktopCapture.directory.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    }
                }.appSurface()
                HStack {
                    BrandMark(size: 26)
                    Text("PingTask").fontWeight(.medium)
                    Text("0.1").foregroundStyle(.secondary)
                    Spacer()
                    Button("交互练习（虚构消息）", action: openPractice)
                }.font(.caption).padding(.vertical, 4)
            }.padding(28)
        }.onAppear { desktop.permissions() }
    }
    func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(granted ? Color.green : AppStyle.gold).font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted { Text("已授权").font(.caption).foregroundStyle(.secondary) }
            else { Button("前往授权", action: action) }
        }
    }
}
