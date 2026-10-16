import Foundation

/// fzf-style matching: every query character must appear in order. Matches at word starts and
/// runs of consecutive characters score higher. Space-separated terms must all match, in any order.
enum Fuzzy {
    private static let separators: Set<Character> = [" ", "·", "-", "_", "/", ".", "—", "|", ":", "(", "["]

    static func score(_ query: String, in text: String) -> Int? {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var total = 0
        for term in terms {
            guard let s = score(term: Array(term), in: haystack) else { return nil }
            total += s
        }
        return total
    }

    private static func score(term: [Character], in text: [Character]) -> Int? {
        var qi = 0
        var last = -2
        var score = 0
        for (i, c) in text.enumerated() where qi < term.count {
            guard c == term[qi] else { continue }
            var s = 1
            if i == last + 1 { s += 5 }                               // consecutive
            if i == 0 || separators.contains(text[i - 1]) { s += 8 }  // word start
            score += s
            last = i
            qi += 1
        }
        return qi == term.count ? score : nil
    }
}
