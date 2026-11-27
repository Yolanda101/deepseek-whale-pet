import Foundation

enum NativePetSize {
    static let minimum = 80
    static let maximum = 224
    static let defaultWidth = 112

    static func clamp(_ width: Int) -> Int {
        min(maximum, max(minimum, width))
    }

    static func height(forWidth width: Int) -> Double {
        Double(width) * 208 / 192
    }
}

final class NativePetSizeReader {
    private struct Revision: Equatable {
        let device: NSNumber?
        let inode: NSNumber?
        let modified: Date?
        let size: NSNumber?

        init(_ attributes: [FileAttributeKey: Any]) {
            device = attributes[.systemNumber] as? NSNumber
            inode = attributes[.systemFileNumber] as? NSNumber
            modified = attributes[.modificationDate] as? Date
            size = attributes[.size] as? NSNumber
        }
    }

    private let configURL: URL
    private var lastRevision: Revision?
    private var cachedSettings = DesktopSettings()

    struct DesktopSettings {
        var width = NativePetSize.defaultWidth
        var petVisible = true
        var selectedAvatarID: String?
    }

    init(configURL: URL = NativePetSizeReader.defaultConfigURL()) {
        self.configURL = configURL
    }

    static func defaultConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let codexHome: URL
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            codexHome = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("config.toml")
    }

    func width() -> Int { settings().width }

    func petVisible() -> Bool { settings().petVisible }

    func settings() -> DesktopSettings {
        let resolvedURL = configURL.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            lastRevision = nil
            cachedSettings = DesktopSettings()
            return cachedSettings
        }
        let revision = Revision(attributes)
        if revision != lastRevision {
            guard let config = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
                return DesktopSettings(petVisible: false)
            }
            cachedSettings = Self.configuredSettings(in: config)
            lastRevision = revision
        }
        return cachedSettings
    }

    private static func configuredSettings(in config: String) -> DesktopSettings {
        var settings = DesktopSettings()
        var scanner = TOMLStatementScanner()
        var inDesktop = false
        for line in config.split(whereSeparator: \.isNewline) {
            guard let statement = scanner.start(of: line) else { continue }
            let text = statement.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") {
                guard text.hasSuffix("]") else { continue }
                let table = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                inDesktop = isKey(table, named: "desktop")
                continue
            }
            guard inDesktop, let equals = text.firstIndex(of: "=") else { continue }
            let key = text[..<equals].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if isKey(key, named: "avatar-overlay-mascot-width-px") {
                if let width = tomlInteger(value), (NativePetSize.minimum...NativePetSize.maximum).contains(width) {
                    settings.width = width
                }
            } else if isKey(key, named: "avatar-overlay-pet-visible") {
                settings.petVisible = value == "true"
            } else if isKey(key, named: "selected-avatar-id") {
                if value.count >= 2, value.first == "'", value.last == "'" {
                    settings.selectedAvatarID = String(value.dropFirst().dropLast())
                } else {
                    settings.selectedAvatarID = try? JSONDecoder().decode(String.self, from: Data(value.utf8))
                }
            }
        }
        return settings
    }

    private static func isKey(_ value: String, named key: String) -> Bool {
        value == key || value == "\"\(key)\"" || value == "'\(key)'"
    }

    private static func tomlInteger(_ value: String) -> Int? {
        let digits: Substring
        let pattern: String
        let radix: Int
        switch value.prefix(2) {
        case "0x":
            (digits, pattern, radix) = (value.dropFirst(2), "^[0-9a-fA-F](?:_?[0-9a-fA-F])*$", 16)
        case "0o":
            (digits, pattern, radix) = (value.dropFirst(2), "^[0-7](?:_?[0-7])*$", 8)
        case "0b":
            (digits, pattern, radix) = (value.dropFirst(2), "^[01](?:_?[01])*$", 2)
        default:
            (digits, pattern, radix) = (value[...], "^[+-]?(?:0|[1-9](?:_?[0-9])*)$", 10)
        }
        guard digits.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return Int(digits.replacingOccurrences(of: "_", with: ""), radix: radix)
    }
}

// A setting can appear only at the start of a statement, outside multiline values.
private struct TOMLStatementScanner {
    private var multilineQuote: Character?
    private var collectionDepth = 0

    mutating func start(of line: Substring) -> Substring? {
        let isContinuation = multilineQuote != nil || collectionDepth > 0
        var quote = multilineQuote
        var remaining = line
        while let next = remaining.first {
            if let closing = quote {
                if closing == "\"", next == "\\" {
                    remaining.removeFirst()
                    if !remaining.isEmpty { remaining.removeFirst() }
                    continue
                }
                if next == closing {
                    if multilineQuote == nil {
                        quote = nil
                    } else if remaining.hasPrefix(String(repeating: closing, count: 3)) {
                        multilineQuote = nil
                        quote = nil
                        while remaining.first == closing { remaining.removeFirst() }
                        continue
                    }
                }
            } else if next == "#" {
                break
            } else if next == "\"" || next == "'" {
                quote = next
                if remaining.hasPrefix("\"\"\"") || remaining.hasPrefix("'''") {
                    multilineQuote = next
                    remaining.removeFirst(3)
                    continue
                }
            } else if next == "[" || next == "{" {
                collectionDepth += 1
            } else if next == "]" || next == "}" {
                collectionDepth = max(0, collectionDepth - 1)
            }
            remaining.removeFirst()
        }
        return isContinuation ? nil : line[..<remaining.startIndex]
    }
}
