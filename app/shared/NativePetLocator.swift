import AppKit
import CoreGraphics
import SQLite3

struct NativePetLocation: Equatable {
    // Global AppKit points, with the origin at the bottom left of the primary display.
    let frame: CGRect
    let windowID: CGWindowID
    let displayID: CGDirectDisplayID
}

final class NativePetLocator {
    private static let ownerBundleID = "com.openai.codex"
    private let databaseURL: URL
    private let nativeSettings: NativePetSizeReader
    private var openStateCheckedAt: TimeInterval?
    private var cachedOpenState: OpenState?
    private var database: OpaquePointer?
    private var stateQuery: OpaquePointer?
    private var databaseFileID: [UInt64]?
    private var fileCheckedAt: TimeInterval?

    init(codexHome: URL = ActivityMonitor.defaultCodexHome) {
        databaseURL = codexHome.appendingPathComponent(".codex-global-state.sqlite")
        nativeSettings = NativePetSizeReader(configURL: codexHome.appendingPathComponent("config.toml"))
    }

    deinit { closeDatabase() }

    // AppKit display information is collected on the main thread.
    func current(mascotWidth: CGFloat? = nil, matchingAvatarIDs: Set<String>? = nil) -> NativePetLocation? {
        let settings = nativeSettings.settings()
        guard settings.petVisible else { return nil }
        if let allowed = matchingAvatarIDs {
            guard let selected = settings.selectedAvatarID, allowed.contains(selected) else { return nil }
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ownerBundleID)
        guard applications.count == 1, let app = applications.first, !app.isTerminated,
              let (top, displays) = Self.displays(),
              let state = recentOpenState(),
              let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        let level = CGWindowLevelForKey(.floatingWindow)
        let candidates = metadata.compactMap { window -> Window? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  window[kCGWindowLayer as String] as? Int32 == level,
                  window[kCGWindowIsOnscreen as String] as? Bool == true,
                  window[kCGWindowAlpha as String] as? Double == 1,
                  let id = window[kCGWindowNumber as String] as? CGWindowID, id != kCGNullWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.isUsable else { return nil }
            return Window(id: id, frame: frame)
        }

        let width = mascotWidth ?? CGFloat(settings.width)
        guard width.isFinite, (80...224).contains(width) else { return nil }
        let size = CGSize(width: width.rounded(), height: ceil(width.rounded() * 208 / 192))
        return Self.locate(candidates: candidates, displays: displays, state: state, size: size, top: top)
    }

    struct Display {
        let id: CGDirectDisplayID
        let frame: CGRect
        let workTop: CGFloat
    }

    struct Window {
        let id: CGWindowID
        let frame: CGRect
    }

    struct OpenState {
        let savedAnchor: CGPoint?
        let savedDisplay: CGRect?
    }

    // In the verified build, the regular Mini window has two known backing
    // sizes for a single screen. With multiple screens it covers its display.
    // Both cases must uniquely match a visible owned floating window.
    static func locate(candidates: [Window], displays: [Display], state: OpenState,
                       size: CGSize, top: CGFloat) -> NativePetLocation? {
        let matches: [(Window, Display, CGRect)]
        if displays.count == 1, let display = displays.first {
            matches = candidates.compactMap { window in
                guard let frame = singleDisplayMascot(in: window.frame, display: display, size: size) else {
                    return nil
                }
                return (window, display, frame)
            }
        } else {
            guard let anchor = state.savedAnchor, let savedDisplay = state.savedDisplay,
                  savedDisplay.isUsable else { return nil }
            let possibleDisplays = displays.filter { $0.frame.matches(savedDisplay) }
            guard possibleDisplays.count == 1, let display = possibleDisplays.first else { return nil }
            let frame = CGRect(origin: anchor, size: size)
            guard frame.isUsable, display.frame.contains(frame) else { return nil }
            matches = candidates.compactMap { window in
                window.frame.matches(display.frame) ? (window, display, frame) : nil
            }
        }
        guard matches.count == 1, let (window, display, frame) = matches.first else { return nil }
        return NativePetLocation(frame: appKitRect(frame, top: top), windowID: window.id, displayID: display.id)
    }

    private static func displays() -> (CGFloat, [Display])? {
        let identifier = NSDeviceDescriptionKey("NSScreenNumber")
        let appKitScreens = NSScreen.screens
        let screens = appKitScreens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let id = screen.deviceDescription[identifier] as? NSNumber else { return nil }
            return (id.uint32Value, screen)
        }
        guard screens.count == appKitScreens.count,
              let main = screens.first(where: { $0.0 == CGMainDisplayID() })?.1 else { return nil }
        let top = main.frame.maxY
        return (top, screens.map { id, screen in
            Display(id: id, frame: appKitRect(screen.frame, top: top), workTop: top - screen.visibleFrame.maxY)
        })
    }

    private static func appKitRect(_ rect: CGRect, top: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func singleDisplayMascot(in window: CGRect, display: Display, size: CGSize) -> CGRect? {
        let backingAnchorWidth: CGFloat = 80
        let backingAnchorHeight: CGFloat = 87
        let padding: CGFloat = 28
        let expectedHeight = 2 * (display.frame.maxY - display.workTop + padding) - backingAnchorHeight
        guard abs(window.height - expectedHeight) <= 1 else { return nil }
        for viewportWidth: CGFloat in [384, 386] {
            let (width, left) = backingWindowWidth(
                displayWidth: display.frame.width, viewportWidth: viewportWidth,
                anchorWidth: backingAnchorWidth, padding: padding
            )
            guard abs(window.width - width) <= 1 else { continue }
            let anchor = CGPoint(x: window.minX - left, y: window.midY - backingAnchorHeight / 2)
            let frame = CGRect(
                x: anchor.x - ((size.width / 2).rounded() - backingAnchorWidth / 2),
                y: anchor.y - ((size.height / 2).rounded() - (backingAnchorHeight / 2).rounded()),
                width: size.width, height: size.height
            )
            if display.frame.contains(frame) { return frame }
        }
        return nil
    }

    // Layout constants and the transparent backing margins from the verified
    // owner's Mini layout. Quartz metadata never includes the mascot subview.
    private static func backingWindowWidth(displayWidth: CGFloat, viewportWidth: CGFloat,
                                           anchorWidth: CGFloat, padding: CGFloat) -> (CGFloat, CGFloat) {
        let contentWidth = viewportWidth - padding
        let inset: CGFloat = 16
        let minControlsWidth = min(displayWidth, max(188, 2 * anchorWidth))
        let springDamping: CGFloat = 37.7
        let springStiffness: CGFloat = 720
        let overshoot = exp(-.pi * springDamping / sqrt(4 * springStiffness - springDamping * springDamping))
        let extrema = [CGFloat.zero, contentWidth].flatMap { controlWidth in
            [CGFloat.zero, displayWidth - anchorWidth].map { origin in
                let upper = displayWidth - controlWidth - inset
                let centered = origin + (anchorWidth - controlWidth) / 2
                let clamped = upper < inset ? ((inset + upper) / 2).rounded()
                    : min(max(centered.rounded(), inset), upper)
                return clamped - origin
            }
        }
        let lower = extrema.min() ?? 0
        let upper = extrema.max() ?? 0
        let travel = ceil((upper - lower) * overshoot / (1 - overshoot))
        let left = floor(min(0, lower - contentWidth - travel - padding,
                             min((anchorWidth - minControlsWidth) / 2, anchorWidth - minControlsWidth) - padding))
        let right = ceil(max(anchorWidth + padding, upper + contentWidth + travel + padding,
                             max((anchorWidth + minControlsWidth) / 2, minControlsWidth) + padding))
        return (right - left, left)
    }

    private struct SavedBounds: Decodable {
        let x: CGFloat
        let y: CGFloat
        let displayBounds: SavedDisplay
    }

    private func recentOpenState() -> OpenState? {
        let now = ProcessInfo.processInfo.systemUptime
        if let checked = openStateCheckedAt, now - checked < 0.20 { return cachedOpenState }
        openStateCheckedAt = now
        cachedOpenState = readOpenState()
        return cachedOpenState
    }

    private struct SavedDisplay: Decodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    private func closeDatabase() {
        sqlite3_finalize(stateQuery)
        sqlite3_close(database)
        stateQuery = nil
        database = nil
        databaseFileID = nil
    }

    private func readStatement() -> OpaquePointer? {
        let now = ProcessInfo.processInfo.systemUptime
        if let checked = fileCheckedAt, now - checked < 1 { return stateQuery }
        fileCheckedAt = now
        let url = databaseURL.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            closeDatabase()
            return nil
        }
        let identity = [device.uint64Value, inode.uint64Value]
        if let query = stateQuery, databaseFileID == identity { return query }
        closeDatabase()
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else { closeDatabase(); return nil }
        let sql = """
            SELECT key, value FROM settings WHERE scope = 'global'
            AND key IN ('electron-avatar-overlay-open', 'electron-avatar-overlay-bounds')
            """
        guard sqlite3_prepare_v2(database, sql, -1, &stateQuery, nil) == SQLITE_OK else {
            closeDatabase()
            return nil
        }
        databaseFileID = identity
        return stateQuery
    }

    private func readOpenState() -> OpenState? {
        guard let statement = readStatement() else { return nil }
        // End each short read transaction while retaining the read-only handle.
        defer { sqlite3_reset(statement) }

        var open = false
        var stored: SavedBounds?
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                switch String(cString: key) {
                case "electron-avatar-overlay-open":
                    open = String(cString: value) == "true"
                case "electron-avatar-overlay-bounds":
                    let data = Data(String(cString: value).utf8)
                    stored = try? JSONDecoder().decode(SavedBounds.self, from: data)
                default:
                    break
                }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE, open else { return nil }
        return OpenState(savedAnchor: stored.map { CGPoint(x: $0.x, y: $0.y) },
                         savedDisplay: stored?.displayBounds.rect)
    }
}

private extension CGRect {
    var isUsable: Bool {
        [minX, minY, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }

    func matches(_ other: CGRect) -> Bool {
        abs(minX - other.minX) <= 1 && abs(minY - other.minY) <= 1
            && abs(width - other.width) <= 1 && abs(height - other.height) <= 1
    }
}
