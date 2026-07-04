import AppKit

/// Minimal markdown → NSAttributedString renderer for the reading panes
/// (chronicles, meeting summaries). Handles the subset Claude actually emits:
/// `#`/`##`/`###` headings, `-`/`*` and `1.` lists, **bold**, and `code`.
/// Not a general markdown engine — just enough to read comfortably.
enum MarkdownRenderer {

    static func attributed(_ markdown: String) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 14)
        let out = NSMutableAttributedString()

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                out.append(NSAttributedString(
                    string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 5)]))
            } else if line.hasPrefix("### ") {
                out.append(heading(String(line.dropFirst(4)), size: 15, weight: .semibold))
            } else if line.hasPrefix("## ") {
                out.append(heading(String(line.dropFirst(3)), size: 18, weight: .bold))
            } else if line.hasPrefix("# ") {
                out.append(heading(String(line.dropFirst(2)), size: 22, weight: .bold))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(listItem(marker: "•", content: String(line.dropFirst(2)), body: body))
            } else if let r = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let marker = line[line.startIndex..<r.upperBound]
                    .trimmingCharacters(in: .whitespaces)
                out.append(listItem(marker: marker, content: String(line[r.upperBound...]), body: body))
            } else if isRule(line) {
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 5)]))
            } else {
                let para = NSMutableParagraphStyle()
                para.lineSpacing = 4
                para.paragraphSpacing = 8
                let m = NSMutableAttributedString(attributedString: inline(line, base: body, color: .labelColor))
                m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
                m.append(NSAttributedString(string: "\n"))
                out.append(m)
            }
        }
        return out
    }

    /// A small dimmed caption (used for the item's title above its body).
    static func caption(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 10
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ])
    }

    // MARK: - Blocks

    private static func heading(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 14
        para.paragraphSpacing = 5
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let m = NSMutableAttributedString(attributedString: inline(text, base: font, color: .labelColor))
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    private static func listItem(marker: String, content: String, body: NSFont) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.paragraphSpacing = 4
        para.firstLineHeadIndent = 16
        para.headIndent = 32
        para.tabStops = [NSTextTab(textAlignment: .left, location: 32)]
        let m = NSMutableAttributedString(string: "\(marker)\t", attributes: [
            .font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para,
        ])
        let text = NSMutableAttributedString(attributedString: inline(content, base: body, color: .labelColor))
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        m.append(text)
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "-" || $0 == "─" || $0 == "*" || $0 == "_" }
    }

    // MARK: - Inline (**bold** and `code`)

    private static func inline(_ text: String, base: NSFont, color: NSColor) -> NSAttributedString {
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let codeFont = NSFont.monospacedSystemFont(ofSize: max(11, base.pointSize - 1), weight: .regular)
        let codeColor = Theme.accent
        let result = NSMutableAttributedString()
        let chars = Array(text)
        var i = 0
        var isBold = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: [
                .font: isBold ? bold : base, .foregroundColor: color,
            ]))
            buffer = ""
        }

        while i < chars.count {
            if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                flush(); isBold.toggle(); i += 2
            } else if chars[i] == "`" {
                flush()
                var j = i + 1
                var code = ""
                while j < chars.count, chars[j] != "`" { code.append(chars[j]); j += 1 }
                if j < chars.count {
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: codeFont, .foregroundColor: codeColor,
                    ]))
                    i = j + 1
                } else {
                    buffer.append("`"); i += 1
                }
            } else {
                buffer.append(chars[i]); i += 1
            }
        }
        flush()
        return result
    }
}
