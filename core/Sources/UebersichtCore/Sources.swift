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
    /// A literal command on a readable interval, which the daemon runs itself.
    public let schedule: WidgetSource.Schedule?

    public var isCoffee: Bool { path.hasSuffix(".coffee") }
}

/// Where widgets come from: the default widgets folder, then the directories
/// listed in the registry, one absolute path per line.
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
        let text = (try? String(contentsOfFile: registry, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n").map(String.init) where !sources.contains(line) {
            sources.append(line)
        }
        return sources
    }

    public static func slug(_ relativePath: String) -> String {
        String(relativePath.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    public static func scan(_ sources: [String]) -> [Widget] {
        sources.flatMap(widgetDirectories).flatMap(widgets).sorted { $0.id < $1.id }
    }

    private static func widgetDirectories(in source: String) -> [(directory: String, workingDirectory: String)] {
        let fm = FileManager.default
        let bundles = ((try? fm.contentsOfDirectory(atPath: source)) ?? []).filter { entry in
            var isDirectory: ObjCBool = false
            return entry.hasSuffix(".widget")
                && fm.fileExists(atPath: (source as NSString).appendingPathComponent(entry), isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        if bundles.isEmpty { return [(source, source)] }
        return bundles.map { ((source as NSString).appendingPathComponent($0), source) }
    }

    private static func widgets(in directory: String, workingDirectory: String) -> [Widget] {
        let fm = FileManager.default
        let name = (directory as NSString).lastPathComponent
        return ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).compactMap { file in
            guard sourceExtensions.contains((file as NSString).pathExtension), !file.hasSuffix(".disabled")
            else { return nil }
            let full = (directory as NSString).appendingPathComponent(file)
            let attributes = try? fm.attributesOfItem(atPath: full)
            return Widget(
                id: slug("\(name)/\(file)"),
                path: full,
                modified: (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0),
                directory: directory,
                name: name,
                workingDirectory: workingDirectory,
                schedule: WidgetSource.schedule(forSourceAt: full)
            )
        }
    }
}
