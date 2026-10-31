import Foundation

/// Just enough HTML for confirmation emails: the visible text, the JSON-LD blocks and the schema.org
/// microdata items. Tolerant of the broken markup mail templates are full of; no network, no scripts run.
enum HTMLText {
    // MARK: Tokens

    enum Token {
        case open(name: String, attributes: [String: String], selfClosing: Bool)
        case close(name: String)
        case text(String)
    }

    static let voidElements: Set<String> = ["br", "img", "meta", "link", "hr", "input", "col", "area", "base", "wbr", "source"]

    /// The markup as tags and text. `<script>` and `<style>` contents come back as one text token each,
    /// comments are dropped.
    static func tokens(_ html: String) -> [Token] {
        var out: [Token] = []
        var i = html.startIndex
        var text = ""
        func flushText() {
            if !text.isEmpty { out.append(.text(text)); text = "" }
        }
        while i < html.endIndex {
            let c = html[i]
            guard c == "<" else { text.append(c); i = html.index(after: i); continue }
            let rest = html[i...]
            if rest.hasPrefix("<!--") {
                flushText()
                if let end = rest.range(of: "-->") { i = end.upperBound } else { i = html.endIndex }
                continue
            }
            guard let close = rest.firstIndex(of: ">") else { text.append(contentsOf: rest); break }
            let inner = html[html.index(after: i)..<close]
            i = html.index(after: close)
            if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }
            flushText()
            if inner.hasPrefix("/") {
                out.append(.close(name: tagName(inner.dropFirst())))
                continue
            }
            let name = tagName(inner)
            guard !name.isEmpty else { text.append("<" + inner + ">"); continue }
            let selfClosing = inner.hasSuffix("/") || voidElements.contains(name)
            out.append(.open(name: name, attributes: attributes(inner.dropFirst(name.count)), selfClosing: selfClosing))
            if name == "script" || name == "style", !selfClosing {
                let endTag = "</" + name
                if let end = html[i...].range(of: endTag, options: .caseInsensitive) {
                    out.append(.text(String(html[i..<end.lowerBound])))
                    i = html[end.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                    out.append(.close(name: name))
                }
            }
        }
        flushText()
        return out
    }

    private static func tagName(_ s: Substring) -> String {
        String(s.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }).lowercased()
    }

    /// `a="1" b='2' c=3 d` as lower-cased names to entity-decoded values.
    static func attributes(_ s: Substring) -> [String: String] {
        var out: [String: String] = [:]
        for m in s.matches(of: /([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>\/]+)))?/) {
            let raw: Substring? = m.2 ?? m.3 ?? m.4
            let value = raw.map { String($0) } ?? ""
            out[String(m.1).lowercased()] = decodeEntities(value)
        }
        return out
    }

    // MARK: Text

    static let blockElements: Set<String> = ["p", "div", "tr", "table", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5",
                                             "h6", "section", "article", "header", "footer", "tbody", "thead", "center",
                                             "blockquote", "dl", "dt", "dd", "title"]

    /// The visible text: block ends and `<br>` as new lines, table cells apart by two spaces, entities
    /// decoded, runs of blank lines collapsed.
    static func visibleText(_ html: String) -> String {
        var out = ""
        var skip = 0
        for token in tokens(html) {
            switch token {
            case .open(let name, _, let selfClosing):
                if (name == "script" || name == "style" || name == "head") && !selfClosing { skip += 1 }
                if name == "br" || blockElements.contains(name) { out += "\n" }
                if name == "td" || name == "th" { out += "  " }
            case .close(let name):
                if (name == "script" || name == "style" || name == "head"), skip > 0 { skip -= 1 }
                if blockElements.contains(name) { out += "\n" }
                if name == "td" || name == "th" { out += "  " }
            case .text(let t):
                if skip == 0 { out += decodeEntities(t.replacingOccurrences(of: "\n", with: " ")) }
            }
        }
        return tidy(out)
    }

    /// Spaces collapsed inside each line, empty lines dropped.
    static func tidy(_ text: String) -> String {
        text.split(separator: "\n").map {
            $0.replacing(/[ \t\u{00A0}]+/, with: " ").trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "rarr": "\u{2192}",
        "larr": "\u{2190}", "harr": "\u{2194}", "ndash": "-", "mdash": "-", "middot": "\u{00B7}", "bull": "\u{2022}",
        "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç", "uuml": "ü", "ouml": "ö", "auml": "ä",
        "szlig": "ß", "rsquo": "'", "lsquo": "'", "ldquo": "\"", "rdquo": "\"", "hellip": "...", "copy": "©",
        "reg": "®", "trade": "™", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "aacute": "á", "iacute": "í",
        "oacute": "ó", "uacute": "ú", "ntilde": "ñ",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacing(/&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z]+);/) { m in
            let body = String(m.1)
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(m.0)
            }
            if body.hasPrefix("#") {
                return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(m.0)
            }
            return namedEntities[body.lowercased()] ?? String(m.0)
        }
    }

    // MARK: JSON-LD

    /// The contents of every `<script type="application/ld+json">`.
    static func jsonLD(_ html: String) -> [String] {
        var out: [String] = []
        var inside = false
        for token in tokens(html) {
            switch token {
            case .open(let name, let attrs, _):
                inside = name == "script" && (attrs["type"]?.lowercased().contains("ld+json") ?? false)
            case .text(let t):
                if inside { out.append(t) }
            case .close:
                inside = false
            }
        }
        return out
    }

    // MARK: Microdata

    /// A schema.org microdata item: its type's last path part ("FlightReservation") and its properties,
    /// each a text value or a nested item.
    final class Item {
        var type: String
        var properties: [(name: String, value: Value)] = []
        init(type: String) { self.type = type }

        enum Value {
            case text(String)
            case item(Item)
        }

        func text(_ name: String) -> String? {
            for p in properties where p.name == name { if case .text(let t) = p.value { return t } }
            return nil
        }
        func item(_ name: String) -> Item? {
            for p in properties where p.name == name { if case .item(let i) = p.value { return i } }
            return nil
        }
        func items(_ name: String) -> [Item] {
            properties.compactMap { p in
                guard p.name == name, case .item(let i) = p.value else { return nil }
                return i
            }
        }

        /// As JSON-LD would give it, so one reader serves both.
        var json: [String: Any] {
            var out: [String: Any] = ["@type": type]
            for p in properties where out[p.name] == nil {
                switch p.value {
                case .text(let t): out[p.name] = t
                case .item(let i): out[p.name] = i.json
                }
            }
            return out
        }
    }

    /// The top-level microdata items of the page (an `itemscope` not itself an `itemprop` of another).
    static func microdata(_ html: String) -> [Item] {
        struct Frame {
            var name: String
            var item: Item?
            /// The property this element's text feeds, with the text so far.
            var property: (owner: Item, name: String)?
            var text: String = ""
        }
        var stack: [Frame] = []
        var roots: [Item] = []
        func currentItem() -> Item? { stack.last(where: { $0.item != nil })?.item }

        func closeTop() {
            guard let frame = stack.popLast() else { return }
            if let (owner, name) = frame.property, frame.item == nil {
                let value = tidy(decodeEntities(frame.text)).replacingOccurrences(of: "\n", with: " ")
                owner.properties.append((name, .text(value)))
            }
            // The text inside also belongs to the elements around it (a property may wrap others).
            if !stack.isEmpty { stack[stack.count - 1].text += frame.text }
        }

        for token in tokens(html) {
            switch token {
            case .open(let name, let attrs, let selfClosing):
                let owner = currentItem()
                var frame = Frame(name: name)
                let prop = attrs["itemprop"]?.split(separator: " ").first.map(String.init)
                if attrs["itemscope"] != nil {
                    let type = (attrs["itemtype"] ?? "").split(separator: "/").last.map(String.init) ?? ""
                    let item = Item(type: type)
                    frame.item = item
                    if let prop, let owner {
                        owner.properties.append((prop, .item(item)))
                    } else {
                        roots.append(item)
                    }
                } else if let prop, let owner {
                    if let content = attrs["content"] ?? attrs["datetime"] ?? (name == "link" || name == "a" ? attrs["href"] : nil)
                        ?? (name == "meta" ? "" : nil) {
                        owner.properties.append((prop, .text(content)))
                    } else if selfClosing {
                        owner.properties.append((prop, .text("")))
                    } else {
                        frame.property = (owner, prop)
                    }
                }
                if !selfClosing { stack.append(frame) }
            case .close(let name):
                guard let at = stack.lastIndex(where: { $0.name == name }) else { continue }
                while stack.count > at { closeTop() }
            case .text(let t):
                if !stack.isEmpty { stack[stack.count - 1].text += t }
            }
        }
        while !stack.isEmpty { closeTop() }
        return roots
    }
}
