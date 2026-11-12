import Foundation

/// Subsequence matching for the command palette: "zf" finds "Zoom to Fit".
public enum FuzzyMatch {
    /// A higher score is a better match; nil when the query's letters do not all appear in order.
    public static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        let original = Array(text)

        var score = 0
        var queryIndex = 0
        var previousMatch: Int?
        for (index, char) in haystack.enumerated() where queryIndex < needle.count && char == needle[queryIndex] {
            score += 1
            if previousMatch == index - 1 { score += 5 }
            if index == 0 { score += 10 } else if isWordStart(original, index) { score += 8 }
            previousMatch = index
            queryIndex += 1
        }
        guard queryIndex == needle.count else { return nil }
        return score - haystack.count / 10
    }

    private static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        let previous = text[index - 1]
        return !previous.isLetter && !previous.isNumber || (previous.isLowercase && text[index].isUppercase)
    }
}
