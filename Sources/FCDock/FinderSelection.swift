import AppKit

/// Reads the current Finder selection over Apple Events (needs the Automation permission for Finder).
enum FinderSelection {
    static let bundleID = "com.apple.finder"

    enum Failure: LocalizedError {
        case notAuthorized
        case script(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Allow FC Dock to control Finder in System Settings › Privacy & Security › Automation"
            case .script(let message):
                return message
            }
        }
    }

    static var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    private static let script: NSAppleScript? = {
        let script = NSAppleScript(source: """
        tell application id "com.apple.finder"
            set out to ""
            repeat with anItem in (get selection)
                set out to out & POSIX path of (anItem as alias) & linefeed
            end repeat
            return out
        end tell
        """)
        script?.compileAndReturnError(nil)
        return script
    }()

    static func selectedFiles() throws -> [URL] {
        guard let script else { throw Failure.script("Couldn't compile Finder script") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -1743 { throw Failure.notAuthorized }
            throw Failure.script(error[NSAppleScript.errorMessage] as? String ?? "Finder script failed")
        }
        return (result.stringValue ?? "")
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }
}
