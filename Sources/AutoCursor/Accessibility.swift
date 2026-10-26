import AppKit
import ApplicationServices
import Foundation
import Security

struct Configuration: Sendable {
    var appName = "Cursor"
    var interval: TimeInterval = 0.35
    var dryRun = false
    var once = false
    var verbose = false
    var mode = "full-access"

    init(arguments: [String]) throws {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--app":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--app") }
                appName = arguments[index]
            case "--interval":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value >= 0.05 else {
                    throw CLIError.invalidValue("--interval")
                }
                interval = value
            case "--mode":
                index += 1
                guard index < arguments.count, arguments[index] == "full-access" else {
                    throw CLIError.invalidValue("--mode (only full-access is supported)")
                }
                mode = arguments[index]
            case "--dry-run": dryRun = true
            case "--once": once = true
            case "--verbose": verbose = true
            case "--help", "-h":
                printUsage()
                exit(EXIT_SUCCESS)
            default:
                throw CLIError.unknownOption(arguments[index])
            }
            index += 1
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String)
    case unknownOption(String)

    var description: String {
        switch self {
        case .missingValue(let option): return "Missing value for \(option)."
        case .invalidValue(let option): return "Invalid value for \(option)."
        case .unknownOption(let option): return "Unknown option \(option)."
        }
    }
}

enum CodeIdentity {
    static let trustedHashKey = "trustedCodeHash"

    /// Code directory hash of the running app. Ad-hoc rebuilds change it, so an old Accessibility grant no longer matches.
    static func currentHash() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let hash = information[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

enum CursorLocator {
    static let bundleIdentifier = "com.todesktop.230313mzl4w4u92"

    static func application(named appName: String) -> NSRunningApplication? {
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame || $0.bundleIdentifier == bundleIdentifier
        }
        return matches.first(where: { $0.isActive }) ?? matches.first
    }

    /// Electron only exposes its web-content accessibility tree once this attribute is set.
    static func enableManualAccessibility(_ root: AXUIElement) {
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

final class AccessibilityReader {
    func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    func elementsAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    /// Window frame in global top-left-origin coordinates (same space as CGWindowList bounds).
    func frame(of element: AXUIElement) -> CGRect? {
        guard let origin: CGPoint = axValue(element, kAXPositionAttribute, .cgPoint, .zero),
              let size: CGSize = axValue(element, kAXSizeAttribute, .cgSize, .zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func axValue<T: BitwiseCopyable>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ initial: T) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = initial
        return AXValueGetValue(value as! AXValue, type, &result) ? result : nil
    }
}

/// Headless mode used when AutoCursor is launched with command-line options.
final class AutoClicker {
    private let configuration: Configuration
    private let reader = AccessibilityReader()
    private let scanner = PromptScanner()

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func run() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            fputs("Accessibility permission is required. Enable AutoCursor in System Settings > Privacy & Security > Accessibility, then run it again.\n", stderr)
            exit(EXIT_FAILURE)
        }

        print("AutoCursor started: app=\(configuration.appName), mode=\(configuration.mode), interval=\(configuration.interval)s\(configuration.dryRun ? ", dry-run" : "")")
        if configuration.once { scanAndClick(); return }

        while true {
            scanAndClick()
            RunLoop.current.run(until: Date().addingTimeInterval(configuration.interval))
        }
    }

    private func scanAndClick() {
        guard let app = CursorLocator.application(named: configuration.appName) else {
            if configuration.verbose { print("[scan] \(configuration.appName) is not running") }
            return
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        CursorLocator.enableManualAccessibility(root)
        for window in reader.elementsAttribute(root, kAXWindowsAttribute) {
            _ = scanner.scan(windowID: UInt64(CFHash(window)), root: window, clickEnabled: true, disabledAgents: [], clickInterval: 1,
                             dryRun: configuration.dryRun, verbose: configuration.verbose)
        }
    }
}
