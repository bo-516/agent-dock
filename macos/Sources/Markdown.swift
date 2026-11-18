// Block markdown for the hover preview: headings, lists, tables, code, quotes
// and rules, each laid out as its own view. Inline styles (bold, italics,
// inline code, links) inside every block come from AttributedString.

import SwiftUI

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case lead(String)                                   // a line that is all bold: a small heading
    case paragraph(String)
    case item(depth: Int, marker: String, text: String) // "•", "1.", or "" for an item's continued text
    case table(header: [String], rows: [[String]])
    case code(String)
    case quote(String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if trimmed.isEmpty { flush(); continue }

            // ``` fenced code, to the closing fence or the end of the text.
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // A table: a | row followed by a |---| separator row.
            if trimmed.hasPrefix("|"), index < lines.count, isTableSeparator(lines[index]) {
                flush()
                let header = cells(trimmed)
                index += 1
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let heading = trimmed.firstMatch(of: #/^(#{1,6})\s+(.+)$/#) {
                flush()
                blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
                continue
            }
            if trimmed.wholeMatch(of: #/(-{3,}|\*{3,}|_{3,})/#) != nil {
                flush()
                blocks.append(.rule)
                continue
            }
            let depth = min(line.prefix { $0 == " " || $0 == "\t" }.count / 2, 3)
            if let bullet = trimmed.firstMatch(of: #/^[-*+]\s+(.+)$/#) {
                flush()
                blocks.append(.item(depth: depth, marker: "•", text: String(bullet.1)))
                continue
            }
            if let numbered = trimmed.firstMatch(of: #/^(\d{1,3})[.)]\s+(.+)$/#) {
                flush()
                blocks.append(.item(depth: depth, marker: "\(numbered.1).", text: String(numbered.2)))
                continue
            }
            if let quote = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                flush()
                blocks.append(.quote(String(quote.1)))
                continue
            }
            if trimmed.wholeMatch(of: #/\*\*[^*]+\*\*[:：]?/#) != nil {
                flush()
                blocks.append(.lead(trimmed))
                continue
            }
            // Indented text under a list item continues that item.
            if depth > 0, paragraph.isEmpty, case .item = blocks.last {
                blocks.append(.item(depth: depth - 1, marker: "", text: trimmed))
                continue
            }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("-") && trimmed.wholeMatch(of: #/\|?(\s*:?-+:?\s*\|)+\s*(:?-+:?\s*)?\|?/#) != nil
    }

    private static func cells(_ row: String) -> [String] {
        var body = Substring(row)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// Bold, italics, inline code and links; block syntax is handled by MarkdownView.
func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let width: CGFloat
    var fontSize: CGFloat = 12

    init(_ text: String, width: CGFloat, fontSize: CGFloat = 12) {
        blocks = MarkdownBlock.parse(text)
        self.width = width
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(.system(size: level <= 2 ? fontSize + 1 : fontSize + 0.5, weight: .semibold))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        case .lead(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: fontSize))
                .foregroundStyle(Color.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        case .item(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: fontSize).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(marker == "•" ? 0.45 : 0.55))
                    .frame(minWidth: marker == "•" || marker.isEmpty ? 8 : 14, alignment: .trailing)
                Text(inlineMarkdown(text))
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, width: width, fontSize: fontSize - 0.5)
                .padding(.vertical, 2)
        case .code(let code):
            Text(code.components(separatedBy: "\n").prefix(12).joined(separator: "\n"))
                .font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(width: width, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        case .quote(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: fontSize))
                .foregroundStyle(Color.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.2)).frame(width: 2) }
        case .rule:
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.vertical, 4)
        }
    }
}

// A table that fits the card: short columns keep their natural width, the
// rest share what is left in proportion to their content.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let width: CGFloat
    let fontSize: CGFloat

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        let widths = columnWidths(columns)
        VStack(alignment: .leading, spacing: 0) {
            row(header, widths: widths, isHeader: true)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                row(cells, widths: widths, isHeader: false)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
                    }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(widths.indices, id: \.self) { column in
                Text(inlineMarkdown(column < cells.count ? cells[column] : ""))
                    .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(Color.white.opacity(isHeader ? 0.92 : 0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(width: widths[column], alignment: .topLeading)
            }
        }
    }

    private func columnWidths(_ count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        // Natural width: the widest cell (CJK counts double), capped, plus padding.
        let natural: [CGFloat] = (0..<count).map { column in
            let units = ([header] + rows).map { cells -> Int in
                column < cells.count ? cells[column].reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E7F ? 2 : 1) } : 0
            }.max() ?? 0
            return CGFloat(min(max(units, 2), 40)) * fontSize * 0.52 + 12
        }
        let total = natural.reduce(0, +)
        if total <= width {
            var widths = natural
            if let widest = natural.indices.max(by: { natural[$0] < natural[$1] }) { widths[widest] += width - total }
            return widths
        }
        var widths = natural
        var flexible = Set(natural.indices)
        var remaining = width
        while !flexible.isEmpty {
            let share = remaining / CGFloat(flexible.count)
            let short = flexible.filter { natural[$0] <= share }
            if short.isEmpty {
                let sum = flexible.reduce(CGFloat(0)) { $0 + natural[$1] }
                for column in flexible { widths[column] = remaining * natural[column] / sum }
                break
            }
            for column in short {
                widths[column] = natural[column]
                remaining -= natural[column]
                flexible.remove(column)
            }
        }
        return widths
    }
}
