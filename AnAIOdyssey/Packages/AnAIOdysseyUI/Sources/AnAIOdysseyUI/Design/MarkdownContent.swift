// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI

/// One block-level element of a markdown document, produced by
/// ``MarkdownBlockParser``. Pure data so parsing stays testable and separate
/// from SwiftUI rendering.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case bulletList(items: [String])
        case orderedList(items: [String])
        case codeBlock(text: String)
        case quote(text: String)
        case divider
    }

    let id: Int
    let kind: Kind
}

/// Minimal block-level markdown parser (headings, lists, fenced code, quotes,
/// dividers, paragraphs). Inline styling (bold/italic/links/code) is left in
/// the text and rendered via `AttributedString(markdown:)`.
enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock.Kind] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var quote: [String] = []
        var codeLines: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushLists() {
            if !bullets.isEmpty {
                blocks.append(.bulletList(items: bullets))
                bullets = []
            }
            if !ordered.isEmpty {
                blocks.append(.orderedList(items: ordered))
                ordered = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(text: quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushLists()
            flushQuote()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if inCodeFence {
                if line.hasPrefix("```") {
                    blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCodeFence = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushAll()
                inCodeFence = true
                continue
            }

            if line.isEmpty {
                flushAll()
                continue
            }

            // Headings: 1–6 leading # characters followed by a space.
            if let headingMatch = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushAll()
                let level = line[headingMatch].filter { $0 == "#" }.count
                let text = String(line[headingMatch.upperBound...])
                blocks.append(.heading(level: level, text: text))
                continue
            }

            // Horizontal rule.
            if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushAll()
                blocks.append(.divider)
                continue
            }

            // Block quote.
            if line.hasPrefix(">") {
                flushParagraph()
                flushLists()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            // Unordered list item.
            if let bulletMatch = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flushParagraph()
                flushQuote()
                bullets.append(String(line[bulletMatch.upperBound...]))
                continue
            }

            // Ordered list item ("1. " or "1) ").
            if let orderedMatch = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                flushQuote()
                ordered.append(String(line[orderedMatch.upperBound...]))
                continue
            }

            flushLists()
            flushQuote()
            paragraph.append(line)
        }

        // An unterminated fence still shows its content as code.
        if inCodeFence, !codeLines.isEmpty {
            blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
        }
        flushAll()

        return blocks.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    /// Inline markdown (bold/italic/links/code) → styled attributed string.
    static func inlineAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

/// Rendered markdown preview: headings, lists, fenced code, quotes, dividers,
/// and inline bold/italic/links — used by the Research and Documents preview
/// modes (``PlainMessageContentView`` remains the literal-source rendering).
struct MarkdownContentView: View {
    let content: String
    var font: Font = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownBlockParser.parse(content)) { block in
                blockView(block.kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .copyableContextMenu(text: content)
    }

    @ViewBuilder
    private func blockView(_ kind: MarkdownBlock.Kind) -> some View {
        switch kind {
        case .heading(let level, let text):
            Text(MarkdownBlockParser.inlineAttributed(text))
                .font(headingFont(level: level))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            Text(MarkdownBlockParser.inlineAttributed(text))
                .font(font)
                .textSelection(.enabled)
        case .bulletList(let items):
            listView(items: items) { _ in "•" }
        case .orderedList(let items):
            listView(items: items) { index in "\(index + 1)." }
        case .codeBlock(let text):
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(MarkdownBlockParser.inlineAttributed(text))
                    .font(font)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .divider:
            Divider()
        }
    }

    private func listView(items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(marker(index))
                        .font(font.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(MarkdownBlockParser.inlineAttributed(item))
                        .font(font)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.bold()
        default: .headline
        }
    }
}

/// Plain, selectable text (markdown source shown literally — not rendered as bold/italic).
struct PlainMessageContentView: View {
    let content: String
    var font: Font = .body

    var body: some View {
        Group {
            #if os(iOS)
            CopyableUITextView(plainText: content)
            #else
            Text(content)
                .font(font)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .copyableContextMenu(text: content)
    }
}

/// Scrollable plain-text area for long outputs (task results, test logs, etc.).
struct ScrollableTextDocumentView: View {
    let text: String
    var font: Font = .body
    /// When nil, the view grows with content (for detail panels). Default caps height in settings rows.
    var maxContentHeight: CGFloat? = 360

    var body: some View {
        Group {
            #if os(iOS)
            CopyableUITextView(plainText: text, isScrollEnabled: maxContentHeight != nil)
                .padding(10)
            #else
            ScrollView {
                PlainMessageContentView(content: text, font: font)
                    .padding(10)
            }
            #endif
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 80,
            maxHeight: maxContentHeight,
            alignment: .leading
        )
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: AnAIOdysseyColor.panelCornerRadius, style: .continuous))
        .copyableContextMenu(text: text)
    }
}
