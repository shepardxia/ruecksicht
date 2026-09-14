import Foundation

/// Reads the two things the server needs from a widget's source: what to run
/// and how often.
///
/// Only a literal string command on a plainly readable interval can be hoisted.
/// A function command closes over the page -- fetch, WebSocket, geolocation --
/// so it has to keep running there. Hoisting is an optimization, never a
/// requirement: anything this cannot read with certainty keeps its own timer on
/// the page, where the compiled value is the real one.
public enum WidgetSource {
    public struct Schedule {
        public let command: String
        public let interval: TimeInterval
    }

    public static func schedule(forSourceAt path: String) -> Schedule? {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8),
              let command = literalCommand(in: source),
              case .every(let interval) = refreshFrequency(in: source)
        else { return nil }
        return Schedule(command: command, interval: interval)
    }

    static func literalCommand(in source: String) -> String? {
        for marker in ["export const command", "export var command", "export let command"] {
            if let value = literal(after: marker, assignedWith: "=", in: source) { return value }
        }
        // Classic widgets are an object literal: `command: "..."`.
        return literal(after: "command", assignedWith: ":", in: source)
    }

    /// What a widget's `refreshFrequency` says, as far as reading the text can
    /// tell. `never` is an explicit `false`; `unreadable` covers everything this
    /// scan cannot evaluate with certainty, which includes any expression
    /// referring to a name.
    enum Frequency: Equatable {
        case every(TimeInterval)
        case never
        case unreadable
    }

    static func refreshFrequency(in source: String) -> Frequency {
        guard let range = source.range(of: "refreshFrequency") else { return .unreadable }

        let rest = source[range.upperBound...]
            .drop { $0 == " " || $0 == "=" || $0 == ":" }
            .prefix { $0 != "," && $0 != "\n" && $0 != ";" && $0 != "}" }
        let expression = rest.trimmingCharacters(in: .whitespaces)

        if expression == "false" { return .never }
        if let quoted = duration(inQuoted: expression) { return .every(quoted) }
        if let milliseconds = arithmetic(expression), milliseconds > 0 {
            return .every(milliseconds / 1000)
        }
        return .unreadable
    }

    /// The `ms` package's shorthand, which a widget may write as `'10s'`.
    private static func duration(inQuoted expression: String) -> TimeInterval? {
        let quotes: Set<Character> = ["\"", "'", "`"]
        guard let first = expression.first, quotes.contains(first),
              let last = expression.last, last == first, expression.count > 2
        else { return nil }

        let body = expression.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        let digits = body.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(digits), amount > 0 else { return nil }

        switch body.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "ms", "msec", "msecs", "millisecond", "milliseconds": return amount / 1000
        case "s", "sec", "secs", "second", "seconds": return amount
        case "m", "min", "mins", "minute", "minutes": return amount * 60
        case "h", "hr", "hrs", "hour", "hours": return amount * 3600
        case "d", "day", "days": return amount * 86400
        default: return nil
        }
    }

    /// Products and sums of numeric literals, so that a widget spelling its
    /// interval `5 * 60 * 1000` is read as five minutes rather than as five.
    private static func arithmetic(_ expression: String) -> Double? {
        var total = 0.0
        for term in expression.split(separator: "+") {
            var product = 1.0
            for factor in term.split(separator: "*") {
                guard let value = Double(factor.trimmingCharacters(in: .whitespaces))
                else { return nil }
                product *= value
            }
            total += product
        }
        return expression.isEmpty ? nil : total
    }

    /// Reads the quoted value following `marker <assignment>`, handling single,
    /// double and backtick quotes and backslash escapes.
    private static func literal(
        after marker: String,
        assignedWith assignment: Character,
        in source: String
    ) -> String? {
        guard let markerRange = source.range(of: marker) else { return nil }

        var index = markerRange.upperBound
        while index < source.endIndex, source[index] == " " { index = source.index(after: index) }
        guard index < source.endIndex, source[index] == assignment else { return nil }
        index = source.index(after: index)
        while index < source.endIndex, source[index] == " " || source[index] == "\n" {
            index = source.index(after: index)
        }
        guard index < source.endIndex else { return nil }

        let quote = source[index]
        guard quote == "\"" || quote == "'" || quote == "`" else { return nil }
        index = source.index(after: index)

        var value = ""
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                // Only the escapes that change meaning inside a shell command
                // are unescaped; the rest reach the shell as written.
                switch character {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "\\": value.append("\\")
                case quote: value.append(quote)
                default: value.append("\\"); value.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return value.isEmpty ? nil : value
            } else {
                value.append(character)
            }
            index = source.index(after: index)
        }
        return nil
    }
}
