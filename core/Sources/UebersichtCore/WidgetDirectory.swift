import Foundation

public struct Widget: Sendable {
    public let id: String
    public let path: String
    public let modified: Date

    public var isCoffee: Bool { path.hasSuffix(".coffee") }
}

/// Discovers widgets under a widget directory.
///
/// Ids are the widget-relative path with every non-alphanumeric run collapsed to
/// a dash, matching the ids already baked into saved widget settings.
public enum WidgetDirectory {
    static let sourceExtensions = ["jsx", "js", "coffee"]

    public static func slug(_ relativePath: String) -> String {
        let collapsed = relativePath.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(collapsed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    public static func scan(_ root: String) -> [Widget] {
        let fm = FileManager.default
        guard let bundles = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var found: [Widget] = []
        for bundle in bundles where bundle.hasSuffix(".widget") {
            let bundlePath = (root as NSString).appendingPathComponent(bundle)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: bundlePath, isDirectory: &isDirectory), isDirectory.boolValue,
                  let files = try? fm.contentsOfDirectory(atPath: bundlePath)
            else { continue }

            for file in files {
                let ext = (file as NSString).pathExtension
                guard sourceExtensions.contains(ext), !file.hasSuffix(".disabled") else { continue }
                let full = (bundlePath as NSString).appendingPathComponent(file)
                let attributes = try? fm.attributesOfItem(atPath: full)
                found.append(
                    Widget(
                        id: slug("\(bundle)/\(file)"),
                        path: full,
                        modified: (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                    )
                )
            }
        }
        return found.sorted { $0.id < $1.id }
    }
}
