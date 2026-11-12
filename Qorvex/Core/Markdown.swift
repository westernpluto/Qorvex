import SwiftUI

/// Reddit-flavoured markdown → native blocks. Block structure is parsed here; inline styling
/// (bold, italics, code, links, strikethrough) is handled by Foundation's markdown parser.
struct MDBlock: Identifiable {
    enum Kind {
        case paragraph(AttributedString)
        case heading(Int, AttributedString)
        case quote([MDBlock])
        case listItem(level: Int, marker: String, text: AttributedString)
        case code(String)
        case rule
        case table([[AttributedString]])
    }
    let id: Int
    let kind: Kind
}

enum Markdown {
    static let spoilerOpen: Character = "\u{FFF9}"
    static let spoilerClose: Character = "\u{FFFB}"

    static func parse(_ source: String) -> [MDBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var i = 0
        func add(_ k: MDBlock.Kind) { blocks.append(MDBlock(id: blocks.count, kind: k)) }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { i += 1; continue }

            // fenced code
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                let fence = String(t.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                i += 1
                add(.code(code.joined(separator: "\n")))
                continue
            }
            // indented code
            if line.hasPrefix("    ") || line.hasPrefix("\t"), !isListItem(line) {
                var code: [String] = []
                while i < lines.count, lines[i].hasPrefix("    ") || lines[i].hasPrefix("\t") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let l = lines[i]
                    code.append(l.hasPrefix("\t") ? String(l.dropFirst()) : String(l.dropFirst(min(4, l.count))))
                    i += 1
                }
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                add(.code(code.joined(separator: "\n")))
                continue
            }
            // heading
            if t.hasPrefix("#") {
                let level = min(6, t.prefix(while: { $0 == "#" }).count)
                let text = t.dropFirst(level).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
                add(.heading(level, inline(text)))
                i += 1
                continue
            }
            // horizontal rule
            if isRule(t) { add(.rule); i += 1; continue }
            // block quote (but not a line-leading spoiler)
            if t.hasPrefix(">") && !t.hasPrefix(">!") {
                var inner: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">"), !q.hasPrefix(">!") else { break }
                    var s = q.dropFirst()
                    if s.hasPrefix(" ") { s = s.dropFirst() }
                    inner.append(String(s))
                    i += 1
                }
                add(.quote(parse(inner.joined(separator: "\n"))))
                continue
            }
            // list item
            if let item = listItem(line) {
                var text = item.text
                i += 1
                while i < lines.count {
                    let n = lines[i]
                    let nt = n.trimmingCharacters(in: .whitespaces)
                    if nt.isEmpty || isListItem(n) || nt.hasPrefix(">") || nt.hasPrefix("#") || nt.hasPrefix("```") { break }
                    text += " " + nt
                    i += 1
                }
                add(.listItem(level: item.level, marker: item.marker, text: inline(text)))
                continue
            }
            // table
            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var rows: [[AttributedString]] = [cells(t).map(inline)]
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i]).map(inline))
                    i += 1
                }
                add(.table(rows))
                continue
            }
            // paragraph
            var para = ""
            while i < lines.count {
                let l = lines[i]
                let lt = l.trimmingCharacters(in: .whitespaces)
                if lt.isEmpty { break }
                if !para.isEmpty && (lt.hasPrefix("#") || lt.hasPrefix("```") || isRule(lt) || isListItem(l) || (lt.hasPrefix(">") && !lt.hasPrefix(">!"))) { break }
                if !para.isEmpty { para += (para.hasSuffix("  ") || para.hasSuffix("\\")) ? "\n" : " " }
                var piece = lt
                if l.hasSuffix("  ") { piece += "  " }
                para += piece
                i += 1
            }
            para = para.replacingOccurrences(of: "\\\n", with: "\n").replacingOccurrences(of: "  \n", with: "\n")
            add(.paragraph(inline(para.trimmingCharacters(in: .whitespaces))))
        }
        return blocks
    }

    // MARK: - helpers

    private static let listRE = try! NSRegularExpression(pattern: #"^(\s*)([*+-]|\d{1,3}[.)])\s+(.*)$"#)

    private static func listItem(_ line: String) -> (level: Int, marker: String, text: String)? {
        guard let m = listRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(m.range(at: 1), in: line), let r2 = Range(m.range(at: 2), in: line), let r3 = Range(m.range(at: 3), in: line) else { return nil }
        let marker = String(line[r2])
        if isRule(line.trimmingCharacters(in: .whitespaces)) { return nil }
        let indent = line[r1].reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let isBullet = ["*", "+", "-"].contains(marker)
        return (min(4, indent / 2), isBullet ? "•" : marker.replacingOccurrences(of: ")", with: "."), String(line[r3]))
    }

    private static func isListItem(_ line: String) -> Bool { listItem(line) != nil }

    private static func isRule(_ t: String) -> Bool {
        let chars = t.filter { !$0.isWhitespace }
        guard chars.count >= 3, let f = chars.first, "-*_".contains(f) else { return false }
        return chars.allSatisfy { $0 == f }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.allSatisfy { "|:- ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static let replacements: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #">!(.+?)!<"#), "\u{FFF9}$1\u{FFFB}"),
        (try! NSRegularExpression(pattern: #"\^\((.+?)\)"#), "$1"),
        (try! NSRegularExpression(pattern: #"(^|\s)\^(\S+)"#), "$1$2"),
        (try! NSRegularExpression(pattern: #"(^|[\s(])/?(r|u)/([A-Za-z0-9_]{2,21})\b"#), "$1[$2/$3](qorvex://$2/$3)"),
        (try! NSRegularExpression(pattern: #"(^|[\s(])(https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'"*])"#), "$1<$2>"),
    ]

    static func inline(_ raw: String) -> AttributedString {
        var s = raw
        for (e, v) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&#x200B;", ""), ("&#x200b;", ""), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: e, with: v)
        }
        for (re, tpl) in replacements {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tpl)
        }
        let opts = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    static func plain(_ raw: String) -> String {
        String(inline(raw).characters).replacingOccurrences(of: String(spoilerOpen), with: "").replacingOccurrences(of: String(spoilerClose), with: "")
    }

    /// Hides or reveals spoiler ranges, removing the sentinel characters.
    static func styled(_ input: AttributedString, revealed: Bool) -> (AttributedString, hasSpoiler: Bool) {
        var s = input
        var found = false
        while let open = s.range(of: String(spoilerOpen)) {
            found = true
            guard let close = s[open.upperBound...].range(of: String(spoilerClose)) else { s.removeSubrange(open); break }
            let inner = open.upperBound..<close.lowerBound
            if revealed {
                s[inner].backgroundColor = Color.secondary.opacity(0.18)
            } else {
                s[inner].foregroundColor = Color.clear
                s[inner].backgroundColor = Color.secondary.opacity(0.55)
                s[inner].link = nil
            }
            s.removeSubrange(close)
            if let o = s.range(of: String(spoilerOpen)) { s.removeSubrange(o) }
        }
        return (s, found)
    }
}

// MARK: - Views

struct MarkdownView: View {
    let blocks: [MDBlock]
    var lineLimit: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { MDBlockView(block: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpoilerText: View {
    let text: AttributedString
    var font: Font = .body
    @State private var revealed = false

    var body: some View {
        let styled = Markdown.styled(text, revealed: revealed)
        if styled.hasSpoiler {
            Text(styled.0)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { revealed.toggle() } }
        } else {
            Text(styled.0)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MDBlockView: View {
    let block: MDBlock

    var body: some View {
        switch block.kind {
        case .paragraph(let s):
            SpoilerText(text: s)
        case .heading(let level, let s):
            SpoilerText(text: s, font: level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                MarkdownView(blocks: inner).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .listItem(let level, let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                SpoilerText(text: s)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12)
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r].indices, id: \.self) { c in
                                Text(rows[r][c]).font(r == 0 ? .subheadline.bold() : .subheadline)
                            }
                        }
                        if r == 0 { Divider() }
                    }
                }
                .padding(12)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
