import Foundation

/// The text helpers search ranks with: one folded form for what people type and what the lists hold,
/// its words, and a small edit distance for typos.
enum SearchText {
    /// Lower case, accents folded ("Zürich" reads "zurich"), punctuation as spaces, runs of spaces as one.
    static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var out = ""
        out.reserveCapacity(folded.count)
        var space = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch); space = false
            } else if ch == "'" || ch == "\u{2019}" {
                // "O'Hare" reads "ohare".
                continue
            } else if !space {
                out.append(" "); space = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// The words of folded text.
    static func words(_ folded: String) -> [Substring] {
        folded.split(separator: " ")
    }

    /// A flight number as the lists compare it: upper case, no spaces or dashes ("af 84" reads "AF84").
    static func ident(_ s: String) -> String {
        String(s.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The typos a query of this length may carry: none under 4 characters (codes and short words would
    /// match half the list), one up to 6, two from 7.
    static func allowedTypos(_ count: Int) -> Int {
        count < 4 ? 0 : count < 7 ? 1 : 2
    }

    /// The fewest edits (insert, delete, substitute, swap two neighbours) that turn `query` into some
    /// prefix of `word`, or nil when it takes more than `limit`. "zurih" is 1 from "zurich", "frnace" 1
    /// from "france".
    static func prefixDistance(_ query: some StringProtocol, _ word: some StringProtocol, limit: Int) -> Int? {
        prefixDistance(Array(query.unicodeScalars), Array(word.unicodeScalars), limit: limit)
    }

    /// The same over scalars the caller already split (the suggester keeps its names that way).
    static func prefixDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int? {
        guard !a.isEmpty, limit >= 0 else { return a.isEmpty ? 0 : nil }
        // The prefixes of `word` worth trying are those within `limit` of the query's length.
        let maxLen = min(b.count, a.count + limit)
        guard maxLen + limit >= a.count else { return nil }
        // d[i][j]: edits from a[..<i] to b[..<j]; three rows for the swap.
        var prev2 = [Int](repeating: 0, count: maxLen + 1)
        var prev = Array(0...maxLen)
        var cur = [Int](repeating: 0, count: maxLen + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            if maxLen >= 1 {
                for j in 1...maxLen {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                    if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                    cur[j] = v
                    rowMin = min(rowMin, v)
                }
            }
            if rowMin > limit { return nil }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        // After the swap above, `prev` holds the last row: the best prefix of `word` the query reaches.
        let best = prev[0...maxLen].min() ?? Int.max
        return best <= limit ? best : nil
    }
}
