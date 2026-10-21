import SwiftUI
import AppKit

/// A local, native reader. Markdown never executes HTML or loads remote images.
struct CodexResponseView: View {
    let markdown: String
    var title = "Codex 返回"
    @State private var raw = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Label(title, systemImage: "doc.text").font(.headline)
                Spacer()
                Picker("显示方式", selection: $raw) {
                    Text("预览").tag(false)
                    Text("原文").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
                MarkdownCopyButton(text: markdown, title: "复制 Markdown")
            }
            Divider()
            if raw {
                Text(markdown).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("展示已保存的最近输出；完整执行记录可通过「查看提交与日志」打开。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18).background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}

private struct MarkdownCopyButton: View {
    let text: String
    let title: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .help(title)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000); copied = false } catch { }
        }
        .onChange(of: text) { _ in copied = false }
    }
}

private enum MarkdownBlock {
    case paragraph(String), heading(Int, String), item(String, String, Int), quote(String)
    case code(String, String), rule, table([[String]])

    static func parse(_ source: String) -> [Self] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [Self] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = trimmed.first!
                let length = trimmed.prefix(while: { $0 == marker }).count
                let language = String(trimmed.dropFirst(length)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.prefix(while: { $0 == marker }).count >= length,
                       candidate.allSatisfy({ $0 == marker }) { break }
                    code.append(lines[index]); index += 1
                }
                blocks.append(.code(language, code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if index + 1 < lines.count, trimmed.contains("|"), isTableDivider(lines[index + 1]) {
                flush()
                var rows = [cells(trimmed)]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index])); index += 1
                }
                blocks.append(.table(rows)); continue
            } else if let heading = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flush()
                blocks.append(.heading(trimmed.prefix(while: { $0 == "#" }).count, String(trimmed[heading.upperBound...])))
            } else if ["---", "***", "___"].contains(trimmed) {
                flush(); blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flush(); blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let prefix = trimmed.range(of: "^(?:[-+*]|[0-9]+[.)])\\s+", options: .regularExpression) {
                flush()
                var text = String(trimmed[prefix.upperBound...])
                var marker = String(trimmed[prefix]).trimmingCharacters(in: .whitespaces)
                if ["-", "+", "*"].contains(marker) { marker = "•" }
                if text.hasPrefix("[ ] ") { marker = "□"; text = String(text.dropFirst(4)) }
                else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text = String(text.dropFirst(4)) }
                blocks.append(.item(marker, text, min(4, line.prefix(while: { $0 == " " || $0 == "\t" }).count / 2)))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }
    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func isTableDivider(_ line: String) -> Bool {
        let row = cells(line)
        return !row.isEmpty && row.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    private func inline(_ value: String) -> Text {
        let text = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(value)
        return Text(text)
    }
    var body: some View {
        Group {
            switch block {
            case .paragraph(let text): inline(text).lineSpacing(4)
            case .heading(let level, let text):
                inline(text).font(.system(size: level == 1 ? 23 : level == 2 ? 19 : 15, weight: .semibold)).padding(.top, 5)
            case .item(let marker, let text, let depth):
                HStack(alignment: .top, spacing: 8) {
                    Text(marker).foregroundStyle(AppStyle.gold).frame(minWidth: 18, alignment: .trailing)
                    inline(text).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, CGFloat(depth * 14))
            case .quote(let text):
                HStack(spacing: 12) {
                    Rectangle().fill(AppStyle.gold.opacity(0.6)).frame(width: 3)
                    inline(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
            case .rule: Divider()
            case .code(let language, let text):
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(language.isEmpty ? "代码" : language).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        MarkdownCopyButton(text: text, title: "复制代码").font(.caption)
                    }
                    ScrollView(.horizontal) {
                        Text(text).font(.system(size: 12, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: true).padding(.bottom, 4)
                    }
                }.padding(12).background(AppStyle.sidebar, in: RoundedRectangle(cornerRadius: 8))
            case .table(let rows):
                ScrollView(.horizontal) {
                    Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 10) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    inline(cell).fontWeight(index == 0 ? .semibold : .regular).frame(maxWidth: 320, alignment: .leading)
                                }
                            }
                            if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                        }
                    }.padding(12)
                }.background(AppStyle.sidebar, in: RoundedRectangle(cornerRadius: 8))
            }
        }.textSelection(.enabled).tint(AppStyle.gold)
    }
}
