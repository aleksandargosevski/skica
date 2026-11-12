import Foundation

public enum InputError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// Arithmetic typed into number fields: `100/3`, `(20+4)*2`. A leading `+`, `*` or `/` applies
/// to the current value (`+20` adds 20, `*2` doubles); a leading `-` is a negative number.
public enum NumericExpression {
    public static func evaluate(_ text: String, current: Double? = nil) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { throw InputError.invalid("Enter a number.") }

        if let first = trimmed.first, "+*/×÷".contains(first) {
            guard let current else { throw InputError.invalid("\"\(trimmed)\" needs a current value.") }
            return try evaluate(formatted(current) + trimmed)
        }
        var parser = Parser(text: trimmed)
        let value = try parser.parseExpression()
        guard parser.isAtEnd else { throw InputError.invalid("Unexpected \"\(parser.rest)\".") }
        guard value.isFinite else { throw InputError.invalid("The result is not a number.") }
        return value
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.10g", value)
    }

    /// expression := term (("+" | "-") term)*; term := factor (("*" | "/") factor)*;
    /// factor := number | "(" expression ")" | "-" factor
    private struct Parser {
        let characters: [Character]
        var position = 0

        init(text: String) {
            characters = Array(text.filter { !$0.isWhitespace })
        }

        var isAtEnd: Bool { position >= characters.count }
        var rest: String { String(characters[position...]) }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while let op = peek, op == "+" || op == "-" {
                position += 1
                let rhs = try parseTerm()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() throws -> Double {
            var value = try parseFactor()
            while let op = peek, "*/×÷".contains(op) {
                position += 1
                let rhs = try parseFactor()
                if op == "*" || op == "×" {
                    value *= rhs
                } else {
                    guard rhs != 0 else { throw InputError.invalid("Division by zero.") }
                    value /= rhs
                }
            }
            return value
        }

        mutating func parseFactor() throws -> Double {
            guard let char = peek else { throw InputError.invalid("The expression is incomplete.") }
            if char == "-" {
                position += 1
                return -(try parseFactor())
            }
            if char == "(" {
                position += 1
                let value = try parseExpression()
                guard peek == ")" else { throw InputError.invalid("Missing \")\".") }
                position += 1
                return value
            }
            let start = position
            while let digit = peek, digit.isNumber || digit == "." { position += 1 }
            guard position > start, let value = Double(String(characters[start..<position])) else {
                throw InputError.invalid("\"\(rest)\" is not a number.")
            }
            return value
        }

        var peek: Character? { isAtEnd ? nil : characters[position] }
    }
}
