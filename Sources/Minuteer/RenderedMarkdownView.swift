import SwiftUI

public enum MarkdownBlock: Identifiable {
    case h1(String)
    case h2(String)
    case h3(String)
    case paragraph(String)
    case bullet(String)
    case taskItem(isDone: Bool, text: String)
    case numbered(number: String, text: String)
    case divider
    case quote(String)

    public var id: UUID { UUID() }
}

public struct RenderedMarkdownView: View {
    public let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(parseBlocks(markdown)) { block in
                renderBlock(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .h1(let text):
            Text(LocalizedStringKey(text))
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top, 10)
                .padding(.bottom, 2)

        case .h2(let text):
            Text(LocalizedStringKey(text))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 12)
                .padding(.bottom, 2)

        case .h3(let text):
            Text(LocalizedStringKey(text))
                .font(.headline)
                .fontWeight(.semibold)
                .padding(.top, 6)

        case .divider:
            Divider()
                .padding(.vertical, 6)

        case .taskItem(let isDone, let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isDone ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isDone ? Color.green : Color.secondary)
                    .font(.body)
                Text(LocalizedStringKey(text))
                    .font(.body)
            }
            .padding(.leading, 4)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)
                Text(LocalizedStringKey(text))
                    .font(.body)
            }
            .padding(.leading, 4)

        case .numbered(let num, let text):
            HStack(alignment: .top, spacing: 6) {
                Text(num)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(text))
                    .font(.body)
            }
            .padding(.leading, 4)

        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                Text(LocalizedStringKey(text))
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

        case .paragraph(let text):
            Text(LocalizedStringKey(text))
                .font(.body)
                .lineSpacing(3)
        }
    }

    private func parseBlocks(_ rawText: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = rawText.components(separatedBy: "\n")
        var currentParagraph = ""

        func flushParagraph() {
            let trimmed = currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(.paragraph(trimmed))
            }
            currentParagraph = ""
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.h3(String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.h2(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.h1(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            // Task list checkboxes: - [ ] or - [x]
            if line.hasPrefix("- [ ] ") || line.hasPrefix("* [ ] ") {
                flushParagraph()
                blocks.append(.taskItem(isDone: false, text: String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") || line.hasPrefix("* [x] ") {
                flushParagraph()
                blocks.append(.taskItem(isDone: true, text: String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            // Unordered bullets: - or *
            if (line.hasPrefix("- ") || line.hasPrefix("* ")) && !line.hasPrefix("- [") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            // Numbered list items: 1. 2. 3.
            if let dotIndex = line.firstIndex(of: "."),
               dotIndex != line.startIndex,
               line.index(after: dotIndex) < line.endIndex,
               line[line.index(after: dotIndex)] == " ",
               Int(line[..<dotIndex]) != nil {
                flushParagraph()
                let num = String(line[...dotIndex])
                let text = String(line[line.index(dotIndex, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(number: num, text: text))
                continue
            }

            if currentParagraph.isEmpty {
                currentParagraph = line
            } else {
                currentParagraph += " " + line
            }
        }

        flushParagraph()
        return blocks
    }
}
