import Foundation

public struct Widget: Sendable {
    public let id: String
    /// The source file.
    public let path: String
    public let modified: Date
    /// The widget's own directory: its files are served under `name`.
    public let directory: String
    public let name: String
    /// Where the widget's command runs.
    public let workingDirectory: String

    public var isCoffee: Bool { path.hasSuffix(".coffee") }
}

/// Where widgets come from: the directories listed in the registry, one per
/// line, and the default widgets folder before them.
///
/// A source that holds `*.widget` subdirectories is a folder of widgets, each
/// served under its own subdirectory's name and run from the folder, so
/// `art.widget/cat.gif` keeps meaning what it always did. Any other source is
/// itself one widget, served under its basename and run from inside it.
///
/// Ids are the widget-relative path with every non-alphanumeric run collapsed
/// to a dash, matching the ids already baked into saved widget settings.
public enum Sources {
    public static let sourceExtensions = ["jsx", "js", "coffee"]

    public static func read(registry: String, defaultDirectory: String) -> [String] {
        var sources = [defaultDirectory]
        if let text = try? String(contentsOfFile: registry, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let path = line.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty, !path.hasPrefix("#"), !sources.contains(path) else { continue }
                sources.append((path as NSString).expandingTildeInPath)
            }
        }
        return sources
    }

    public static func slug(_ relativePath: String) -> String {
        let collapsed = relativePath.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(collapsed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    public static func scan(_ sources: [String]) -> [Widget] {
        var found: [Widget] = []
        for source in sources {
            let bundles = subdirectories(of: source).filter { $0.hasSuffix(".widget") }
            if bundles.isEmpty {
                found += widgets(in: source, name: (source as NSString).lastPathComponent, workingDirectory: source)
            } else {
                for bundle in bundles {
                    let directory = (source as NSString).appendingPathComponent(bundle)
                    found += widgets(in: directory, name: bundle, workingDirectory: source)
                }
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    private static func subdirectories(of path: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return entries.filter { entry in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: (path as NSString).appendingPathComponent(entry), isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private static func widgets(in directory: String, name: String, workingDirectory: String) -> [Widget] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var found: [Widget] = []
        for file in files {
            let ext = (file as NSString).pathExtension
            guard sourceExtensions.contains(ext), !file.hasSuffix(".disabled") else { continue }
            let full = (directory as NSString).appendingPathComponent(file)
            let attributes = try? fm.attributesOfItem(atPath: full)
            found.append(Widget(
                id: slug("\(name)/\(file)"),
                path: full,
                modified: (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0),
                directory: directory,
                name: name,
                workingDirectory: workingDirectory
            ))
        }
        return found
    }
}
