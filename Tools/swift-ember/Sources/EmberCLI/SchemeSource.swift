import Foundation

/// Locates the parsed elements in the original source so only the needed
/// insertions and attribute values are written back to the shared scheme.
struct SchemeSource {
    private struct Element {
        let name: String
        let opening: NSRange
        var closing: NSRange?
    }

    private let source: NSString
    private let elements: [String: Element]
    private var edits: [(range: NSRange, text: String)] = []

    private static let unsupported = InitError(
        "cannot edit this Scheme formatting safely. Set up the Ember Build actions manually in Xcode.")

    init(_ data: Data, root: XMLElement) throws {
        guard let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else {
            throw Self.unsupported
        }
        source = text as NSString
        // Comments, CDATA and processing instructions can all contain strings
        // that look like tags. Skip them as units, and match real tags across
        // line breaks without treating a quoted '>' as the end of a tag.
        let markup = try NSRegularExpression(
            pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!|<(/?)([\w:.-]+)(?:[^"'<>]|"[^"]*"|'[^']*')*>"#)
        var tags: [Element] = []
        var open: [Int] = []
        for token in markup.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let raw = source.substring(with: token.range)
            guard raw != "<!" else { throw Self.unsupported }
            guard token.range(at: 2).location != NSNotFound else { continue }
            let name = source.substring(with: token.range(at: 2))
            if token.range(at: 1).length != 0 {
                guard let index = open.popLast(), tags[index].name == name else { throw Self.unsupported }
                tags[index].closing = token.range
            } else {
                if !raw.hasSuffix("/>") { open.append(tags.count) }
                tags.append(Element(name: name, opening: token.range))
            }
        }

        let nodes = try root.nodes(forXPath: "descendant-or-self::*")
        guard open.isEmpty, nodes.count == tags.count else { throw Self.unsupported }
        var positions: [String: Element] = [:]
        for (node, tag) in zip(nodes, tags) {
            guard let path = node.xPath, node.name == tag.name, positions[path] == nil else {
                throw Self.unsupported
            }
            positions[path] = tag
        }
        elements = positions
    }

    mutating func insert(_ node: XMLElement, before anchor: XMLElement, in buildAction: XMLElement,
                         beforeClosingTag: Bool = false) throws {
        let destination = try position(of: anchor)
        guard let tag = beforeClosingTag ? destination.closing : destination.opening else {
            throw Self.unsupported
        }
        let line = try line(at: tag.location)
        let buildIndent = try self.line(at: position(of: buildAction).opening.location).indent
        guard line.indent.hasPrefix(buildIndent), line.indent.count > buildIndent.count else {
            throw Self.unsupported
        }
        let step = String(line.indent.dropFirst(buildIndent.count))
        let indent = beforeClosingTag ? line.indent + step : line.indent
        let lines = try Self.render(node, indent: indent, step: step)
        edits.append((NSRange(location: line.start, length: 0), lines.joined(separator: line.ending) + line.ending))
    }

    mutating func replace(_ name: String, on node: XMLElement, with value: String) throws {
        let opening = try position(of: node).opening
        let attributes = try NSRegularExpression(pattern: #"\s+([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
        let matches = attributes.matches(in: source as String, range: opening)
            .filter { source.substring(with: $0.range(at: 1)) == name }
        guard matches.count == 1, let match = matches.first else { throw Self.unsupported }
        let doubleQuoted = match.range(at: 2).location != NSNotFound
        edits.append((match.range(at: doubleQuoted ? 2 : 3), Self.escape(value, quote: doubleQuoted ? "\"" : "'")))
    }

    func data(validating expected: XMLElement) throws -> Data {
        let edited = NSMutableString(string: source as String)
        // Reverse order also handles two new lists inserted before the same
        // original BuildActionEntries line. PreActions was planned first.
        for (_, edit) in edits.enumerated().sorted(by: { first, second in
            first.element.range.location == second.element.range.location
                ? first.offset > second.offset
                : first.element.range.location > second.element.range.location
        }) {
            edited.replaceCharacters(in: edit.range, with: edit.text)
        }
        let data = Data((edited as String).utf8)
        guard let parsed = try? XMLDocument(data: data, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]),
              let root = parsed.rootElement(), Self.equivalent(expected, root) else {
            throw Self.unsupported
        }
        return data
    }

    private func position(of element: XMLElement) throws -> Element {
        guard let path = element.xPath, let position = elements[path] else { throw Self.unsupported }
        return position
    }

    private func line(at offset: Int) throws -> (start: Int, indent: String, ending: String) {
        var start = 0
        var end = 0
        var contentsEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
        let indent = source.substring(with: NSRange(location: start, length: offset - start))
        let ending = source.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
        guard indent.allSatisfy({ $0 == " " || $0 == "\t" }), ending == "\n" || ending == "\r\n" else {
            throw Self.unsupported
        }
        return (start, indent, ending)
    }

    private static func render(_ element: XMLElement, indent: String, step: String) throws -> [String] {
        guard let name = element.name else { throw unsupported }
        var header = ["\(indent)<\(name)"]
        for attribute in element.attributes ?? [] {
            guard let key = attribute.name, let value = attribute.stringValue else { throw unsupported }
            header.append("\(indent)\(step)\(key) = \"\(escape(value, quote: "\""))\"")
        }
        header[header.count - 1] += ">"
        let children = try significantChildren(of: element).flatMap { node in
            guard let child = node as? XMLElement else { throw unsupported }
            return try render(child, indent: indent + step, step: step)
        }
        return header + children + ["\(indent)</\(name)>"]
    }

    private static func escape(_ value: String, quote: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: quote, with: quote == "\"" ? "&quot;" : "&apos;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\t", with: "&#9;")
    }

    private static func significantChildren(of node: XMLNode) -> [XMLNode] {
        (node.children ?? []).filter {
            $0.kind != .text || $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        }
    }

    private static func equivalent(_ lhs: XMLNode, _ rhs: XMLNode) -> Bool {
        guard lhs.kind == rhs.kind, lhs.name == rhs.name else { return false }
        guard let left = lhs as? XMLElement, let right = rhs as? XMLElement else {
            return lhs.stringValue == rhs.stringValue
        }
        let attributes = left.attributes ?? []
        let a = significantChildren(of: left)
        let b = significantChildren(of: right)
        return attributes.count == (right.attributes?.count ?? 0) && attributes.allSatisfy { attribute in
            guard let name = attribute.name else { return false }
            return attribute.stringValue == right.attribute(forName: name)?.stringValue
        } && a.count == b.count && zip(a, b).allSatisfy { equivalent($0.0, $0.1) }
    }
}
