import Foundation

/// An email as the reader needs it: when it was sent, its text and HTML bodies and its PDF attachments.
/// Reads a raw message (`.eml`, RFC 5322 with MIME parts in quoted-printable or base64) or, when the
/// input has no headers, takes it as pasted text (HTML when it looks like HTML). Only the headers it
/// needs are kept: the sender's name and address and the recipients are never read.
public struct EmailMessage: Sendable, Hashable {
    /// The `Date:` header; years left out of the flights' dates are read near it.
    public var sent: Date?
    public var subject: String?
    public var plainParts: [String]
    public var htmlParts: [String]
    /// The bytes of each PDF attached (an e-ticket or itinerary); the platform layer reads their text.
    public var pdfs: [Data]

    public init(sent: Date? = nil, subject: String? = nil, plainParts: [String] = [], htmlParts: [String] = [],
                pdfs: [Data] = []) {
        self.sent = sent; self.subject = subject; self.plainParts = plainParts; self.htmlParts = htmlParts; self.pdfs = pdfs
    }

    /// The message in `data`: a raw email when it starts with headers, else pasted text.
    public static func parse(_ data: Data) -> EmailMessage {
        parse(decodeText(data))
    }

    public static func parse(_ text: String) -> EmailMessage {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard looksLikeRawEmail(normalized) else {
            return looksLikeHTML(normalized) ? EmailMessage(htmlParts: [normalized]) : EmailMessage(plainParts: [normalized])
        }
        var message = EmailMessage()
        let (headers, body) = splitHeaders(normalized)
        message.sent = headers["date"].flatMap(parseDate)
        message.subject = headers["subject"].map(decodeEncodedWords)
        collect(headers: headers, body: body, into: &message, depth: 0)
        return message
    }

    // MARK: Detection

    /// True when the text opens with header lines ("Name: value") and has a header the reader knows.
    static func looksLikeRawEmail(_ text: String) -> Bool {
        let head = text.prefix(4000)
        guard let blank = head.range(of: "\n\n") else { return false }
        let lines = head[..<blank.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.wholeMatch(of: /[A-Za-z][A-Za-z0-9-]*:.*/) != nil else { return false }
        let names = Set(lines.compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            return line[..<colon].lowercased()
        })
        return !names.isDisjoint(with: ["content-type", "mime-version", "subject", "date", "from", "received", "message-id"])
    }

    static func looksLikeHTML(_ text: String) -> Bool {
        let t = text.prefix(2000).lowercased()
        return t.contains("<html") || t.contains("<body") || t.contains("<div") || t.contains("<table")
            || t.contains("<script") || t.contains("<p>") || t.contains("<br")
    }

    // MARK: MIME

    /// Header names in lower case to their unfolded values (the first of a repeated header wins), and
    /// the body after the blank line.
    static func splitHeaders(_ text: String) -> ([String: String], String) {
        let parts = text.components(separatedBy: "\n\n")
        let headerText = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\n\n")
        var headers: [String: String] = [:]
        var current: (String, String)?
        func flush() {
            if let (k, v) = current, headers[k] == nil { headers[k] = v.trimmingCharacters(in: .whitespaces) }
        }
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                current?.1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                current = (line[..<colon].lowercased().trimmingCharacters(in: .whitespaces), String(line[line.index(after: colon)...]))
            }
        }
        flush()
        return (headers, body)
    }

    /// The parts a message carries, in order: text bodies decoded to strings, PDFs kept as bytes.
    private static func collect(headers: [String: String], body: String, into message: inout EmailMessage, depth: Int) {
        guard depth < 8 else { return }
        let type = headers["content-type"] ?? "text/plain"
        let mime = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        let params = parameters(type)
        let encoding = headers["content-transfer-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let disposition = headers["content-disposition"] ?? ""
        let filename = parameters(disposition)["filename"] ?? params["name"] ?? ""

        if mime.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for part in splitMultipart(body, boundary: boundary) {
                let (h, b) = splitHeaders(part)
                collect(headers: h, body: b, into: &message, depth: depth + 1)
            }
            return
        }
        if mime == "message/rfc822" {
            let (h, b) = splitHeaders(body)
            collect(headers: h, body: b, into: &message, depth: depth + 1)
            return
        }
        let bytes = decodeBody(body, encoding: encoding)
        if mime == "application/pdf" || filename.lowercased().hasSuffix(".pdf") {
            message.pdfs.append(bytes)
            return
        }
        guard mime.hasPrefix("text/") else { return }
        let charset = params["charset"]?.lowercased()
        let text = decodeText(bytes, charset: charset)
        if mime == "text/html" { message.htmlParts.append(text) } else if mime == "text/plain" { message.plainParts.append(text) }
    }

    /// `type/sub; name="value"; other=value` as lower-cased names to unquoted values.
    static func parameters(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        for piece in header.split(separator: ";").dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            out[name] = value
        }
        return out
    }

    static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let marker = "--" + boundary
        var parts: [String] = []
        var current: [Substring]?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == marker || trimmed == marker + "--" {
                if let current { parts.append(current.joined(separator: "\n")) }
                current = trimmed == marker ? [] : nil
                if trimmed != marker { break }
            } else {
                current?.append(line)
            }
        }
        if let current, !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    static func decodeBody(_ body: String, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let compact = body.filter { !$0.isWhitespace }
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters) ?? Data(body.utf8)
        case "quoted-printable":
            return quotedPrintable(body)
        default:
            return Data(body.utf8)
        }
    }

    /// RFC 2045 quoted-printable: "=XX" bytes and "=" soft line breaks.
    static func quotedPrintable(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: b - 48
            case 65...70: b - 55
            case 97...102: b - 87
            default: nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\n") { i += 2; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l); i += 3; continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    static func decodeText(_ data: Data, charset: String? = nil) -> String {
        if let charset, charset.contains("8859-1") || charset.contains("latin1") || charset.contains("1252") {
            return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047 words in a header ("=?UTF-8?Q?Votre_vol?=", "=?utf-8?B?...?=").
    static func decodeEncodedWords(_ s: String) -> String {
        var out = s
        for m in s.matches(of: /=\?([^?]+)\?([QqBb])\?([^?]*)\?=/) {
            let charset = String(m.1).lowercased(), payload = String(m.3)
            let data: Data
            if m.2.uppercased() == "B" {
                data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
            } else {
                data = quotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
            }
            out = out.replacingOccurrences(of: String(m.0), with: decodeText(data, charset: charset))
        }
        return out.replacingOccurrences(of: "?= =?", with: "")
    }

    /// An RFC 5322 date ("Tue, 14 Mar 2027 09:12:00 +0100").
    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let cleaned = s.replacing(/\s*\([^)]*\)\s*$/, with: "").trimmingCharacters(in: .whitespaces)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z"] {
            f.dateFormat = format
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }
}
