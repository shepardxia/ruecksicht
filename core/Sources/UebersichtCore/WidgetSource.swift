import Foundation

/// Reads the two things the server needs from a widget's source: what to run
/// and how often.
///
/// Only a literal string command can be hoisted. A function command closes over
/// the page -- fetch, WebSocket, geolocation -- so it has to keep running there,
/// and a widget whose command cannot be read here simply keeps its own timer.
public enum WidgetSource {
    public struct Schedule {
        public let command: String
        public let interval: TimeInterval
    }

    public static func schedule(forSourceAt path: String) -> Schedule? {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8),
              let command = literalCommand(in: source)
        else { return nil }
        return Schedule(command: command, interval: refreshFrequency(in: source) ?? 1.0)
    }

    static func literalCommand(in source: String) -> String? {
        for marker in ["export const command", "export var command", "export let command"] {
            if let value = literal(after: marker, assignedWith: "=", in: source) { return value }
        }
        // Classic widgets are an object literal: `command: "..."`.
        return literal(after: "command", assignedWith: ":", in: source)
    }

    static func refreshFrequency(in source: String) -> TimeInterval? {
        for marker in ["export const refreshFrequency", "refreshFrequency"] {
            guard let range = source.range(of: marker) else { continue }
            let rest = source[range.upperBound...].drop { $0 == " " || $0 == "=" || $0 == ":" }
            let digits = rest.prefix { $0.isNumber }
            if let ms = Double(digits), ms > 0 { return ms / 1000 }
        }
        return nil
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
